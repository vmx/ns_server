%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%

-module(ns_rebalance_observer).

-behavior(gen_server).

-include("ns_common.hrl").

-export([start_link/1, get_detailed_progress/0]).

%% gen_server callbacks
-export([code_change/3, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-define(DOCS_LEFT_REFRESH_INTERVAL, 5000).

-record(replica_building_stats, {node :: node(),
                                 docs_total :: non_neg_integer(),
                                 docs_left :: non_neg_integer(),
                                 tap_name = <<"">> :: binary()}).

-record(move_state, {vbucket :: vbucket_id(),
                     before_chain :: [node()],
                     after_chain :: [node()],
                     stats :: [#replica_building_stats{}]}).

-record(state, {bucket :: bucket_name() | undefined,
                buckets_count :: pos_integer(),
                bucket_number :: non_neg_integer(),
                done_moves :: [#move_state{}],
                current_moves :: [#move_state{}],
                pending_moves :: [#move_state{}]
               }).

start_link(BucketConfigs) ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, BucketConfigs, []).

get_detailed_progress() ->
    try
        gen_server:call({global, ?MODULE}, get_detailed_progress, 10000)
    catch
        exit:{noproc, _} ->
            not_running;
        exit:{shutdown, _} ->
            not_running
    end.

is_interesting_master_event({_, bucket_rebalance_started, _Bucket, _Pid}) ->
    fun handle_bucket_rebalance_started/2;
is_interesting_master_event({_, set_ff_map, _BucketName, _Diff}) ->
    fun handle_set_ff_map/2;
is_interesting_master_event({_, vbucket_move_start, _Pid, _BucketName, _Node, _VBucketId, _, _}) ->
    fun handle_vbucket_move_start/2;
is_interesting_master_event({_, vbucket_move_done, _BucketName, _VBucketId}) ->
    fun handle_vbucket_move_done/2;
is_interesting_master_event({_, tap_estimate, _, _, _, _}) ->
    fun handle_tap_estimate/2;
is_interesting_master_event(_) ->
    undefined.


init(BucketConfigs) ->
    Self = self(),
    ns_pubsub:subscribe_link(master_activity_events,
                             fun (Event, _Ignored) ->
                                     case is_interesting_master_event(Event) of
                                         undefined ->
                                             [];
                                         Fun ->
                                             gen_server:cast(Self, {note, Fun, Event})
                                     end
                             end, []),

    {ok, _} = timer2:send_interval(5000, log_state),

    proc_lib:spawn_link(erlang, apply, [fun docs_left_updater_init/1, [Self]]),

    {ok, #state{bucket = undefined,
                buckets_count = length(BucketConfigs),
                bucket_number = 0,
                done_moves  = [],
                current_moves = [],
                pending_moves = []}}.

handle_call(get, _From, State) ->
    {reply, State, State};
handle_call(get_detailed_progress, _From, State) ->
    {reply, do_get_detailed_progress(State), State};
handle_call(Req, From, State) ->
    ?log_error("Got unknown request: ~p from ~p", [Req, From]),
    {reply, unknown_request, State}.

handle_cast({note, Fun, Ev}, State) ->
    {noreply, NewState} = Fun(Ev, State),
    {noreply, NewState};

handle_cast({update_stats, VBucket, NodeToDocsLeft}, State) ->
    ?log_debug("Got update_stats: ~p, ~p~n~p", [VBucket, NodeToDocsLeft, State]),
    {noreply, update_move(
                State, VBucket,
                fun (Move) ->
                        NewStats =
                            [case lists:keyfind(Stat#replica_building_stats.node, 1, NodeToDocsLeft) of
                                 {_, NewLeft} ->
                                     #replica_building_stats{docs_total = Total} = Stat,

                                     %% it's possible to get stats update
                                     %% before before we get refined
                                     %% docs_total from ebucketmigrator_srv;
                                     %% so we can end up in a situation where
                                     %% docs_left is greater than docs_total;
                                     %% I've really seen this happen but not
                                     %% sure if it was because of the
                                     %% described or because of something else.
                                     case NewLeft =< Total of
                                         true ->
                                             Stat#replica_building_stats{docs_left = NewLeft};
                                         false ->
                                             Stat#replica_building_stats{docs_left = NewLeft,
                                                                         docs_total = NewLeft}
                                     end;
                                 false ->
                                     Stat
                             end || Stat <- Move#move_state.stats],
                        Move#move_state{stats = NewStats}
                end)};

handle_cast(Req, _State) ->
    ?log_error("Got unknown cast: ~p", [Req]),
    erlang:error({unknown_cast, Req}).

initiate_bucket_rebalance(BucketName, OldState) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(BucketName),
    Map = proplists:get_value(map, BucketConfig),
    FFMap = case proplists:get_value(fastForwardMap, BucketConfig) of
                undefined ->
                    %% yes this is possible if rebalance completes
                    %% faster than we can start observing it's
                    %% progress
                    Map;
                FFMap0 ->
                    FFMap0
            end,
    VBCount = length(Map),
    Diff = [Triple
            || {_, [MasterNode|_] = ChainBefore, ChainAfter} = Triple <- lists:zip3(lists:seq(0, VBCount-1),
                                                                                    Map,
                                                                                    FFMap),
               MasterNode =/= undefined,
               ChainBefore =/= ChainAfter],
    BuildDestinations0 = [{MasterNode, VB} || {VB, [MasterNode|_], _ChainAfter} <- Diff],
    BuildDestinations1 = [{N, VB} || {VB, _, ChainAfter} <- Diff,
                                     N <- ChainAfter, N =/= undefined],

    BuildDestinations =
        %% the following groups vbuckets to per node. [{a, 1}, {a, 2}, {b, 3}] => [{a, [1,2]}, {b, [3]}]
        keygroup_sorted(lists:merge(lists:sort(BuildDestinations0),
                                    lists:sort(BuildDestinations1))),

    SomeEstimates0 = misc:parallel_map(
                       fun ({Node, VBs}) ->
                               {ok, Estimates} = janitor_agent:get_mass_tap_docs_estimate(BucketName, Node, VBs),
                               [{{Node, VB}, {VBEstimate, VBChkItems}} ||
                                   {VB, {VBEstimate, VBChkItems, _}} <- lists:zip(VBs, Estimates)]
                       end, BuildDestinations, infinity),


    SomeEstimates = lists:append(SomeEstimates0),

    ?log_debug("Initial estimates:~n~p", [SomeEstimates]),

    Moves =
        [begin
             {_, {MasterEstimate, MasterChkItems}} = lists:keyfind({MasterNode, VB}, 1, SomeEstimates),
             RBStats =
                 [begin
                      {_, {ReplicaEstimate, _}} = lists:keyfind({Replica, VB}, 1, SomeEstimates),
                      Estimate = case ReplicaEstimate =< MasterEstimate of
                                     true ->
                                         %% in this case we assume no backfill
                                         %% is required; but the number of
                                         %% items to be transferred can't be
                                         %% less than the number of items in
                                         %% open checkpoint
                                         max(MasterChkItems,
                                             MasterEstimate - ReplicaEstimate);
                                     _ ->
                                         MasterEstimate
                                 end,
                      #replica_building_stats{node = Replica,
                                              docs_total = Estimate,
                                              docs_left = Estimate}
                  end || Replica <- ChainAfter,
                         Replica =/= undefined,
                         Replica =/= MasterNode],
             #move_state{vbucket = VB,
                         before_chain = ChainBefore,
                         after_chain = ChainAfter,
                         stats = RBStats}
         end || {VB, [MasterNode|_] = ChainBefore, ChainAfter} <- Diff],

    ?log_debug("Moves:~n~p", [Moves]),

    OldState#state{bucket = BucketName,
                   done_moves = [],
                   current_moves = [],
                   pending_moves = Moves}.

handle_bucket_rebalance_started({_, bucket_rebalance_started, _BucketName, _Pid},
                                #state{bucket_number = Number} = State) ->
    NewState = State#state{bucket_number=Number + 1},
    {noreply, NewState}.

handle_set_ff_map({_, set_ff_map, BucketName, _Diff}, State) ->
    {noreply, initiate_bucket_rebalance(BucketName, State)}.

handle_vbucket_move_start({_, vbucket_move_start, _Pid, _BucketName, _Node, VBucketId, _, _} = Ev, State) ->
    case ensure_not_pending(State, VBucketId) of
        State ->
            ?log_error("Weird vbucket move start for move not in pending moves: ~p", [Ev]),
            {noreply, State};
        NewState ->
            {noreply, NewState}
    end.

handle_tap_estimate({_, tap_estimate, {_Type, _BucketName, VBucket, _Src, Dst}, Estimate, _Pid, TapName} = Ev, State) ->
    ?log_debug("Seeing tap_estimate: ~p", [Ev]),
    State2 = ensure_not_pending(State, VBucket),
    State3 = update_tap_estimate(
               State2, VBucket, Dst,
               fun (Stat) ->
                       Stat#replica_building_stats{docs_left = Estimate,
                                                   docs_total = Estimate,
                                                   tap_name = TapName}
               end),
    {noreply, State3}.

handle_vbucket_move_done({_, vbucket_move_done, _BucketName, VBucket} = Ev, State) ->
    State1 = update_move(State, VBucket,
                         fun (#move_state{stats=Stats} = Move) ->
                                 Stats1 = [S#replica_building_stats{docs_left=0} ||
                                              S <- Stats],
                                 Move#move_state{stats=Stats1}
                         end),
    case ensure_not_current(State1, VBucket) of
        State1 ->
            ?log_error("Weird vbucket_move_done for move not in current_moves: ~p", [Ev]),
            {noreply, State1};
        NewState ->
            {noreply, NewState}
    end.

move_the_move(State, VBucketId, From, To) ->
    case lists:keytake(VBucketId, #move_state.vbucket, erlang:element(From, State)) of
        false ->
            State;
        {value, Move, RestFrom} ->
            OldTo = erlang:element(To, State),
            State1 = erlang:setelement(To, State, [Move | OldTo]),
            erlang:setelement(From, State1, RestFrom)
    end.

ensure_not_pending(State, VBucketId) ->
    move_the_move(State, VBucketId, #state.pending_moves, #state.current_moves).

ensure_not_current(State, VBucketId) ->
    move_the_move(State, VBucketId, #state.current_moves, #state.done_moves).

update_move(#state{current_moves = Moves} = State, VBucket, Fun) ->
    NewCurrent =
        [case Move#move_state.vbucket =:= VBucket of
             false ->
                 Move;
             _ ->
                 Fun(Move)
         end || Move <- Moves],
    State#state{current_moves = NewCurrent}.

update_tap_estimate(State, VBucket, Dst, Fun) ->
    update_move(State, VBucket,
                fun (Move) ->
                        update_tap_estimate_in_move(Move, Dst, Fun)
                end).

update_tap_estimate_in_move(#move_state{stats = RStats} = Move, Dst, Fun) ->
    Move#move_state{
      stats = [case Stat#replica_building_stats.node =:= Dst of
                   false ->
                       Stat;
                   _ ->
                       Fun(Stat)
               end || Stat <- RStats]}.

handle_info(log_state, State) ->
    case State#state.bucket of
        undefined ->
            ok;
        _ ->
            ?log_info("rebalance observer state:~n~p", [State])
    end,
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

docs_left_updater_init(Parent) ->
    {ok, _} = timer2:send_interval(?DOCS_LEFT_REFRESH_INTERVAL, refresh),
    docs_left_updater_loop(Parent).

docs_left_updater_loop(Parent) ->
    #state{current_moves = CurrentMoves,
           bucket = BucketName} = gen_server:call(Parent, get, infinity),
    case BucketName of
        undefined ->
            ok;
        _ ->
            ?log_debug("Starting docs_left_updater_loop:~p~n~p", [BucketName, CurrentMoves])
    end,
    [update_docs_left_for_move(Parent, BucketName, M) || M <- CurrentMoves],
    receive
        refresh ->
            _Lost = misc:flush(refresh),
            docs_left_updater_loop(Parent)
    end.

update_docs_left_for_move(Parent, BucketName,
                          #move_state{vbucket = VBucket,
                                      before_chain = [MasterNode|_],
                                      stats = RStats}) ->
    TapNames = [S#replica_building_stats.tap_name || S <- RStats],
    try janitor_agent:get_tap_docs_estimate_many_taps(BucketName, MasterNode, VBucket, TapNames) of
        NewLefts ->
            Stuff =
                lists:flatmap(
                  fun ({OkE, Stat}) ->
                          {ok, {E, _, Status}} = OkE,

                          %% we expect tap name to exist; if it does not, it
                          %% means that ebucketmigrator has already terminated
                          %% and we will get bad estimate that will corrupt
                          %% our estimates;
                          case Status =:= <<"backfilling">> orelse
                              Status =:= <<"backfill completed">> of
                              true ->
                                  [{Stat#replica_building_stats.node, E}];
                              false ->
                                  []
                          end
                  end, lists:zip(NewLefts, RStats)),

            gen_server:cast(Parent, {update_stats, VBucket, Stuff})
    catch error:{janitor_agent_servant_died, _} ->
            ?log_debug("Apparently move of ~p is already done", [VBucket]),
            ok
    end.

keygroup_sorted(Items) ->
    lists:foldr(
      fun ({K, V}, Acc) ->
              case Acc of
                  [{K, AccVs} | Rest] ->
                      [{K, [V | AccVs]} | Rest];
                  _ ->
                      [{K, [V]} | Acc]
              end
      end, [], Items).


do_get_detailed_progress(#state{bucket=undefined}) ->
    not_running;
do_get_detailed_progress(#state{bucket=Bucket,
                                buckets_count=BucketsCount,
                                bucket_number=BucketNumber,
                                current_moves=CurrentMoves,
                                pending_moves=PendingMoves,
                                done_moves=DoneMoves}) ->
    AllMoves = lists:append([CurrentMoves, PendingMoves, DoneMoves]),
    AllMovesWithMaster = [{N, Move} ||
                             #move_state{before_chain=[N|_]} = Move <- AllMoves],
    MasterToMoves = keygroup_sorted(lists:sort(AllMovesWithMaster)),

    Inc = fun (undefined, Dict) ->
                  Dict;
              (Node, Dict) ->
                  dict:update(Node,
                              fun (C) ->
                                      C + 1
                              end, 1, Dict)
          end,

    {MovesLeftActive, MovesLeftReplica} =
        lists:foldl(
          fun (#move_state{before_chain=[OldMaster|OldReplicas],
                           after_chain=[NewMaster|NewReplicas]}, {AccA, AccR}) ->
                  AccA1 = case OldMaster =:= NewMaster of
                              true ->
                                  AccA;
                              false ->
                                  Inc(OldMaster, Inc(NewMaster, AccA))
                          end,

                  AccR1 = lists:foldl(
                            fun (N, Acc) ->
                                    Inc(N, Acc)
                            end, AccR, lists:usort((OldReplicas -- NewReplicas) ++
                                                       (NewReplicas -- OldReplicas))),

                  {AccA1, AccR1}
          end, {dict:new(), dict:new()}, CurrentMoves ++ PendingMoves),

    NodesProgress =
        lists:foldl(
          fun (N, Acc) ->
                  {Total, Left} = case lists:keyfind(N, 1, MasterToMoves) of
                                      false ->
                                          {0, 0};
                                      {N, Moves} ->
                                         moves_stats(Moves)
                                  end,

                  A = case dict:find(N, MovesLeftActive) of
                          {ok, VA} ->
                              VA;
                          error ->
                              0
                      end,

                  R = case dict:find(N, MovesLeftReplica) of
                          {ok, VR} ->
                              VR;
                          error ->
                              0
                      end,

                  Info = {N, [{docsTotal, Total},
                              {docsTransferred, Total - Left},
                              {activeVBucketsLeft, A},
                              {replicaVBucketsLeft, R}]},
                  [Info | Acc]
          end, [], ns_node_disco:nodes_wanted()),

    GlobalDetails = [{bucket, list_to_binary(Bucket)},
                     {bucketNumber, BucketNumber},
                     {bucketsCount, BucketsCount}],
    {ok, GlobalDetails, NodesProgress}.


moves_stats(Moves) ->
    lists:foldl(
      fun (#move_state{stats=Stats}, Acc) ->
              lists:foldl(
                fun (#replica_building_stats{docs_total=Total,
                                             docs_left=Left},
                     {AccTotal, AccLeft}) ->
                        true = (Left =< Total),

                        {AccTotal + Total, AccLeft + Left}
                end, Acc, Stats)
      end, {0, 0}, Moves).