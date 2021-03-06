%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
%% @doc Web server for menelaus.

-module(menelaus_stats).
-author('NorthScale <info@northscale.com>').

-include("ns_stats.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([handle_bucket_stats/3,
         handle_bucket_node_stats/4,
         handle_specific_stat_for_buckets/4,
         handle_specific_stat_for_buckets_group_per_node/4,
         handle_overview_stats/2,
         basic_stats/1,
         basic_stats/2, basic_stats/3,
         bucket_disk_usage/1,
         bucket_ram_usage/1,
         serve_stats_directory/3]).

%% External API

bucket_disk_usage(BucketName) ->
    bucket_disk_usage(BucketName, ns_bucket:live_bucket_nodes(BucketName)).

bucket_disk_usage(BucketName, Nodes) ->
    {Res, _} = rpc:multicall(Nodes, ns_storage_conf, local_bucket_disk_usage, [BucketName], 1000),
    lists:sum([case is_number(X) of
                   true -> X;
                   _ -> 0
               end || X <- Res]).

bucket_ram_usage(BucketName) ->
    element(1, last_membase_sample(BucketName, ns_bucket:live_bucket_nodes(BucketName))).

extract_stat(StatName, Sample) ->
    case orddict:find(StatName, Sample#stat_entry.values) of
        error -> 0;
        {ok, V} -> V
    end.

last_membase_sample(BucketName, Nodes) ->
    lists:foldl(fun ({_Node, []}, Acc) -> Acc;
                    ({_Node, [Sample|_]}, {AccMem, AccItems, AccOps, AccFetches}) ->
                        {extract_stat(mem_used, Sample) + AccMem,
                         extract_stat(curr_items, Sample) + AccItems,
                         extract_stat(ops, Sample) + AccOps,
                         extract_stat(ep_bg_fetched, Sample) + AccFetches}
                end, {0, 0, 0, 0}, invoke_archiver(BucketName, Nodes, {1, minute, 1})).

last_memcached_sample(BucketName, Nodes) ->
    {MemUsed,
     CurrItems,
     Ops,
     CmdGet,
     GetHits} = lists:foldl(fun ({_Node, []}, Acc) -> Acc;
                                ({_Node, [Sample|_]}, {AccMem, AccItems, AccOps, AccGet, AccGetHits}) ->
                                    {extract_stat(mem_used, Sample) + AccMem,
                                     extract_stat(curr_items, Sample) + AccItems,
                                     extract_stat(ops, Sample) + AccOps,
                                     extract_stat(cmd_get, Sample) + AccGet,
                                     extract_stat(get_hits, Sample) + AccGetHits}
                            end, {0, 0, 0, 0, 0}, invoke_archiver(BucketName, Nodes, {1, minute, 1})),
    {MemUsed,
     CurrItems,
     Ops,
     case CmdGet of
         0 -> 0;
         _ -> GetHits / CmdGet
     end}.

last_bucket_stats(membase, BucketName, Nodes) ->
    {MemUsed, ItemsCount, Ops, Fetches} = last_membase_sample(BucketName, Nodes),
    [{opsPerSec, Ops},
     {diskFetches, Fetches},
     {itemCount, ItemsCount},
     {diskUsed, bucket_disk_usage(BucketName, Nodes)},
     {memUsed, MemUsed}];
last_bucket_stats(memcached, BucketName, Nodes) ->
    {MemUsed, ItemsCount, Ops, HitRatio} = last_memcached_sample(BucketName, Nodes),
    [{opsPerSec, Ops},
     {hitRatio, HitRatio},
     {itemCount, ItemsCount},
     {diskUsed, bucket_disk_usage(BucketName, Nodes)},
     {memUsed, MemUsed}].

basic_stats(BucketName, Nodes) ->
    basic_stats(BucketName, Nodes, undefined).

basic_stats(BucketName, Nodes, MaybeBucketConfig) ->
    {ok, BucketConfig} = ns_bucket:maybe_get_bucket(BucketName, MaybeBucketConfig),
    QuotaBytes = ns_bucket:ram_quota(BucketConfig),
    Stats = last_bucket_stats(ns_bucket:bucket_type(BucketConfig), BucketName, Nodes),
    MemUsed = proplists:get_value(memUsed, Stats),
    QuotaPercent = try (MemUsed * 100.0 / QuotaBytes) of
                       X -> X
                   catch
                       error:badarith -> 0
                   end,
    [{quotaPercentUsed, lists:min([QuotaPercent, 100])}
     | Stats].

basic_stats(BucketName) ->
    basic_stats(BucketName, ns_bucket:live_bucket_nodes(BucketName)).

handle_overview_stats(PoolId, Req) ->
    Names = lists:sort(menelaus_web_buckets:all_accessible_bucket_names(PoolId, Req)),
    AllSamples = lists:map(fun (Name) ->
                                   element(1, grab_aggregate_op_stats(Name, all, [{"zoom", "hour"}]))
                           end, Names),
    MergedSamples = case AllSamples of
                        [FirstBucketSamples | RestSamples] ->
                            merge_all_samples_normally(FirstBucketSamples, RestSamples);
                        [] -> []
                    end,
    TStamps = [X#stat_entry.timestamp || X <- MergedSamples],
    Ops = [extract_stat(ops, X) || X <- MergedSamples],
    DiskReads = [extract_stat(ep_io_num_read, X) || X <- MergedSamples],
    menelaus_util:reply_json(Req, {struct, [{timestamp, TStamps},
                                            {ops, Ops},
                                            {ep_io_num_read, DiskReads}]}).

%% GET /pools/default/stats
%% Supported query params:
%%  resampleForUI - pass 1 if you need 60 samples
%%  zoom - stats zoom level (minute | hour | day | week | month | year)
%%  haveTStamp - omit samples earlier than given
%%
%% Response:
%%  {hot_keys: [{name: "key, ops: 12.4}, ...],
%%   op: {lastTStamp: 123343434, // last timestamp in served samples. milliseconds
%%        tstampParam: 123342434, // haveTStamp param is given, understood and found
%%        interval: 1000, // samples interval in milliseconds
%%        samplesCount: 60, // number of samples that cover selected zoom level
%%        samples: {timestamp: [..tstamps..],
%%                  ops: [..ops samples..],
%%                  ...}
%%        }}

handle_bucket_stats(PoolId, all, Req) ->
    BucketNames = menelaus_web_buckets:all_accessible_bucket_names(PoolId, Req),
    handle_buckets_stats(PoolId, BucketNames, Req);

%% GET /pools/{PoolID}/buckets/{Id}/stats
handle_bucket_stats(PoolId, Id, Req) ->
    handle_buckets_stats(PoolId, [Id], Req).

handle_buckets_stats(PoolId, BucketIds, Req) ->
    Params = Req:parse_qs(),
    {struct, PropList1} = build_buckets_stats_ops_response(PoolId, all, BucketIds, Params),
    {struct, PropList2} = build_buckets_stats_hks_response(PoolId, BucketIds),
    menelaus_util:reply_json(Req, {struct, PropList1 ++ PropList2}).

%% Per-Node Stats
%% GET /pools/{PoolID}/buckets/{Id}/nodes/{NodeId}/stats
%%
%% Per-node stats match bucket stats with the addition of a 'hostname' key,
%% stats specific to the node (obviously), and removal of any cross-node stats
handle_bucket_node_stats(PoolId, BucketName, HostName, Req) ->
    menelaus_web:checking_bucket_hostname_access(
      PoolId, BucketName, HostName, Req,
      fun (_Req, _BucketInfo, HostInfo) ->
              Node = binary_to_atom(proplists:get_value(otpNode, HostInfo), latin1),
              Params = Req:parse_qs(),
              {struct, [{op, {struct, OpsPropList}}]} = build_buckets_stats_ops_response(PoolId, [Node], [BucketName], Params),

              SystemStatsSamples =
                  case grab_aggregate_op_stats("@system", [Node], Params) of
                      {SystemRawSamples, _, _, _} ->
                          samples_to_proplists(SystemRawSamples)
                  end,
              {samples, {struct, OpsSamples}} = lists:keyfind(samples, 1, OpsPropList),

              ModifiedOpsPropList = lists:keyreplace(samples, 1, OpsPropList, {samples, {struct, SystemStatsSamples ++ OpsSamples}}),
              Ops = [{op, {struct, ModifiedOpsPropList}}],

              {struct, HKS} = jsonify_hks(hot_keys_keeper:bucket_hot_keys(BucketName, Node)),
              menelaus_util:reply_json(
                Req,
                {struct, [{hostname, list_to_binary(HostName)}
                          | HKS ++ Ops]})
      end).

%% Specific Stat URL for all buckets
%% GET /pools/{PoolID}/buckets/{Id}/stats/{StatName}
handle_specific_stat_for_buckets(PoolId, Id, StatName, Req) ->
    Params = Req:parse_qs(),
    case proplists:get_value("per_node", Params, "true") of
        undefined ->
            Req:respond({501, [], []});
        "true" ->
            handle_specific_stat_for_buckets_group_per_node(PoolId, Id, StatName, Req)
    end.

%% Specific Stat URL grouped by nodes
%% GET /pools/{PoolID}/buckets/{Id}/stats/{StatName}?per_node=true
%%
%% Req:ok({"application/json",
%%         menelaus_util:server_header(),
%%         <<"{
%%     \"timestamp\": [1,2,3,4,5],
%%     \"nodeStats\": [{\"127.0.0.1:9000\": [1,2,3,4,5]},
%%                     {\"127.0.0.1:9001\": [1,2,3,4,5]}]
%%   }">>}).
handle_specific_stat_for_buckets_group_per_node(PoolId, BucketName, StatName, Req) ->
    menelaus_web_buckets:checking_bucket_access(
      PoolId, BucketName, Req,
      fun (_Pool, _BucketConfig) ->
              Params = Req:parse_qs(),
              try
                  menelaus_util:reply_json(
                    Req,
                    build_per_node_stats(BucketName, StatName, Params, menelaus_util:local_addr(Req)))
              catch throw:bad_stat_name ->
                      menelaus_util:reply_json(Req, <<"unknown stat">>, 404)
              end
      end).

build_simple_stat_extractor(StatAtom) ->
    fun (#stat_entry{timestamp = TS, values = VS}) ->
            {TS, dict_safe_fetch(StatAtom, VS, undefined)}
    end.

build_stat_extractor(StatName) ->
    ExtraStats = computed_stats_lazy_proplist(),
    StatAtom = try list_to_existing_atom(StatName)
               catch error:badarg ->
                       erlang:throw(bad_stat_name)
               end,
    case lists:keyfind(StatAtom, 1, ExtraStats) of
        {_K, {F, Meta}} ->
            fun (#stat_entry{timestamp = TS, values = VS}) ->
                    Args = [dict_safe_fetch(Name, VS, undefined) || Name <- Meta],
                    case lists:member(undefined, Args) of
                        true -> {TS, undefined};
                        _ -> {TS, erlang:apply(F, Args)}
                    end
            end;
        false ->
            build_simple_stat_extractor(StatAtom)
    end.

dict_safe_fetch(K, Dict, Default) ->
    case orddict:find(K, Dict) of
        error -> Default;
        {ok, V} -> V
    end.

build_per_node_stats(BucketName, StatName, Params, LocalAddr) ->
    {MainSamples, Replies, ClientTStamp, {Step, _, Window}}
        = gather_op_stats(BucketName, all, Params),

    StatExtractor = build_stat_extractor(StatName),

    RestSamplesRaw = lists:keydelete(node(), 1, Replies),
    Nodes = [node() | [N || {N, _} <- RestSamplesRaw]],
    AllNodesSamples = [{node(), lists:reverse(MainSamples)} | RestSamplesRaw],

    NodesSamples = [lists:map(StatExtractor, NodeSamples) || {_, NodeSamples} <- AllNodesSamples],

    Config = ns_config:get(),
    Hostnames = [list_to_binary(menelaus_web:build_node_hostname(Config, N, LocalAddr)) || N <- Nodes],

    Timestamps = [TS || {TS, _} <- hd(NodesSamples)],
    MainValues = [VS || {_, VS} <- hd(NodesSamples)],

    AllignedRestValues
        = lists:map(fun (undefined) -> [undefined || _ <- Timestamps];
                        (Samples) ->
                            Dict = orddict:from_list(Samples),
                            [dict_safe_fetch(T, Dict, 0) || T <- Timestamps]
                    end, tl(NodesSamples)),
    OpPropList0 = [{samplesCount, Window},
                   {isPersistent, ns_bucket:is_persistent(BucketName)},
                   {lastTStamp, case Timestamps of
                                    [] -> 0;
                                    L -> lists:last(L)
                                end},
                   {interval, Step * 1000},
                   {timestamp, Timestamps},
                   {nodeStats, {struct, lists:zipwith(fun (H, VS) ->
                                                              {H, VS}
                                                      end,
                                                      Hostnames, [MainValues | AllignedRestValues])}}],
    OpPropList = case ClientTStamp of
                     undefined -> OpPropList0;
                     _ -> [{tstampParam, ClientTStamp}
                           | OpPropList0]
                 end,
    {struct, OpPropList}.

%% ops SUM(cmd_get, cmd_set,
%%         incr_misses, incr_hits,
%%         decr_misses, decr_hits,
%%         cas_misses, cas_hits, cas_badval,
%%         delete_misses, delete_hits,
%%         cmd_flush)
%% cmd_get (cmd_get)
%% get_misses (get_misses)
%% get_hits (get_hits)
%% cmd_set (cmd_set)
%% evictions (evictions)
%% replacements (if available in time)
%% misses SUM(get_misses, delete_misses, incr_misses, decr_misses,
%%            cas_misses)
%% updates SUM(cmd_set, incr_hits, decr_hits, cas_hits)
%% bytes_read (bytes_read)
%% bytes_written (bytes_written)
%% hit_ratio (get_hits / cmd_get)
%% curr_items (curr_items)

%% Implementation

merge_all_samples_normally(MainSamples, ListOfLists) ->
    ETS = ets:new(ok, [{keypos, #stat_entry.timestamp}]),
    try do_merge_all_samples_normally(ETS, MainSamples, ListOfLists)
    after
        ets:delete(ETS)
    end.

do_merge_all_samples_normally(ETS, MainSamples, ListOfLists) ->
    ets:insert(ETS, MainSamples),
    lists:foreach(
      fun (OtherSamples) ->
              lists:foreach(
                fun (OtherS) ->
                        TS = OtherS#stat_entry.timestamp,
                        case ets:lookup(ETS, TS) of
                            [S|_] ->
                                ets:insert(ETS, aggregate_stat_entries(S, OtherS));
                            _ ->
                                nothing
                        end
                end, OtherSamples)
      end, ListOfLists),
    [hd(ets:lookup(ETS, T)) || #stat_entry{timestamp = T} <- MainSamples].

grab_aggregate_op_stats(Bucket, Nodes, Params) ->
    {MainSamples, Replies, ClientTStamp, {Step, _, Window}} = gather_op_stats(Bucket, Nodes, Params),
    RV = merge_all_samples_normally(MainSamples, [S || {N,S} <- Replies, N =/= node()]),
    V = lists:reverse(RV),
    case V =/= [] andalso (hd(V))#stat_entry.timestamp of
        ClientTStamp -> {V, ClientTStamp, Step, Window};
        _ -> {V, undefined, Step, Window}
    end.

gather_op_stats(Bucket, Nodes, Params) ->
    ClientTStamp = case proplists:get_value("haveTStamp", Params) of
                       undefined -> undefined;
                       X -> try list_to_integer(X) of
                                XI -> XI
                            catch
                                _:_ -> undefined
                            end
                   end,
    {Step0, Period, Window0} = case proplists:get_value("zoom", Params) of
                         "minute" -> {1, minute, 60};
                         "hour" -> {60, hour, 900};
                         "day" -> {1440, day, 1440};
                         "week" -> {11520, week, 1152};
                         "month" -> {44640, month, 1488};
                         "year" -> {527040, year, 1464};
                         undefined -> {1, minute, 60}
                     end,
    {Step, Window} = case proplists:get_value("resampleForUI", Params) of
                         undefined -> {1, Window0};
                         _ -> {Step0, 60}
                     end,
    Self = self(),
    Ref = make_ref(),
    Subscription = ns_pubsub:subscribe(ns_stats_event, fun (_, done) -> done;
                                                           ({sample_archived, Name, _}, _) when Name =:= Bucket ->
                                                               Self ! Ref,
                                                               done;
                                                           (_, X) -> X
                                                       end, []),
    %% don't wait next sample for anything other than real-time stats
    RefToPass = case Period of
                    minute -> Ref;
                    _ -> []
                end,
    try gather_op_stats_body(Bucket, Nodes, ClientTStamp, RefToPass,
                             {Step, Period, Window}) of
        Something -> Something
    after
        ns_pubsub:unsubscribe(ns_stats_event, Subscription),
        misc:flush(Ref)
    end.

invoke_archiver(Bucket, NodeS, {Step, Period, Window}) ->
    RV = case Step of
             1 ->
                 catch stats_reader:latest(Period, NodeS, Bucket, Window);
             _ ->
                 catch stats_reader:latest(Period, NodeS, Bucket, Step, Window)
         end,
    case is_list(NodeS) of
        true -> [{K, V} || {K, {ok, V}} <- RV];
        _ ->
            case RV of
                {ok, List} -> List;
                _ -> []
            end
    end.

gather_op_stats_body(Bucket, Nodes, ClientTStamp,
                   Ref, PeriodParams) ->
    FirstNode = case Nodes of
                    all -> node();
                    [X] -> X
                end,
    RV = invoke_archiver(Bucket, FirstNode, PeriodParams),
    case RV of
        [] -> {[], [], ClientTStamp, PeriodParams};
        [_] -> {[], [], ClientTStamp, PeriodParams};
        _ ->
            %% we throw out last sample 'cause it might be missing on other nodes yet
            %% previous samples should be ok on all live nodes
            Samples = tl(lists:reverse(RV)),
            LastTStamp = (hd(Samples))#stat_entry.timestamp,
            case LastTStamp of
                %% wait if we don't yet have fresh sample
                ClientTStamp when Ref =/= [] ->
                    receive
                        Ref ->
                            gather_op_stats_body(Bucket, Nodes, ClientTStamp, [], PeriodParams)
                    after 2000 ->
                            {[], [], ClientTStamp, PeriodParams}
                    end;
                _ ->
                    %% cut samples up-to and including ClientTStamp
                    CutSamples = lists:dropwhile(fun (Sample) ->
                                                         Sample#stat_entry.timestamp =/= ClientTStamp
                                                 end, lists:reverse(Samples)),
                    MainSamples = case CutSamples of
                                      [] -> Samples;
                                      _ -> lists:reverse(CutSamples)
                                  end,
                    OtherNodes = case Nodes of
                                     all -> ns_bucket:live_bucket_nodes(Bucket);
                                     [_] -> []
                                 end,
                    Replies = invoke_archiver(Bucket, OtherNodes, PeriodParams),
                    {MainSamples, Replies, ClientTStamp, PeriodParams}
            end
    end.

computed_stats_lazy_proplist() ->
    Z2 = fun (StatNameA, StatNameB, Combiner) ->
                 {Combiner, [StatNameA, StatNameB]}
         end,
    HitRatio = Z2(cmd_get, get_hits,
                  fun (null, _Hits) -> 0;
                      (_Gets, null) -> 0;
                      (Gets, _Hits) when Gets == 0 -> 0; % this handles int and float 0
                      (Gets, Hits) -> Hits * 100/Gets
                  end),
    EPCacheMissRatio = Z2(ep_bg_fetched, cmd_get,
                         fun (BGFetches, Gets) ->
                                 try (100 - (Gets - BGFetches) * 100 / Gets)
                                 catch error:badarith -> 0
                                 end
                         end),
    ResidentItemsRatio = Z2(ep_num_non_resident, curr_items_tot,
                            fun (NonResident, CurrItems) ->
                                    try (CurrItems - NonResident) * 100 / CurrItems
                                    catch error:badarith -> 100
                                    end
                            end),
    AvgActiveQueueAge = Z2(vb_active_queue_age, curr_items,
                           fun (ActiveAge, ActiveCount) ->
                                   try ActiveAge / ActiveCount / 1000
                                   catch error:badarith -> 0
                                   end
                           end),
    AvgReplicaQueueAge = Z2(vb_replica_queue_age, vb_replica_curr_items,
                            fun (ReplicaAge, ReplicaCount) ->
                                    try ReplicaAge / ReplicaCount / 1000
                                    catch error:badarith -> 0
                                    end
                            end),
    AvgPendingQueueAge = Z2(vb_pending_queue_age, vb_pending_curr_items,
                            fun (PendingAge, PendingCount) ->
                                    try PendingAge / PendingCount / 1000
                                    catch error:badarith -> 0
                                    end
                            end),
    AvgTotalQueueAge = Z2(vb_total_queue_age, curr_items_tot,
                          fun (TotalAge, TotalCount) ->
                                  try TotalAge / TotalCount / 1000
                                  catch error:badarith -> 0
                                  end
                          end),
    ResidenceCalculator = fun (NonResident, Total) ->
                                  try (Total - NonResident) * 100 / Total
                                  catch error:badarith -> 0
                                  end
                          end,
    ActiveResRate = Z2(vb_active_num_non_resident, curr_items,
                       ResidenceCalculator),
    ReplicaResRate = Z2(vb_active_num_non_resident, vb_replica_curr_items,
                        ResidenceCalculator),
    PendingResRate = Z2(vb_active_num_non_resident, vb_pending_curr_items,
                        ResidenceCalculator),
    [{hit_ratio, HitRatio},
     {ep_cache_miss_rate, EPCacheMissRatio},
     {ep_resident_items_rate, ResidentItemsRatio},
     {vb_avg_active_queue_age, AvgActiveQueueAge},
     {vb_avg_replica_queue_age, AvgReplicaQueueAge},
     {vb_avg_pending_queue_age, AvgPendingQueueAge},
     {vb_avg_total_queue_age, AvgTotalQueueAge},
     {vb_active_resident_items_ratio, ActiveResRate},
     {vb_replica_resident_items_ratio, ReplicaResRate},
     {vb_pending_resident_items_ratio, PendingResRate}].

%% converts list of samples to proplist of stat values
-spec samples_to_proplists([#stat_entry{}]) -> [{atom(), [null | number()]}].
samples_to_proplists([]) -> [{timestamp, []}];
samples_to_proplists(Samples) ->
    %% we're assuming that last sample has currently supported stats,
    %% that's why we are folding from backward and why we're ignoring
    %% other keys of other samples
    [LastSample | ReversedRest] = lists:reverse(Samples),
    InitialAcc0 = orddict:map(fun (_, V) -> [V] end, LastSample#stat_entry.values),
    InitialAcc = orddict:store(timestamp, [LastSample#stat_entry.timestamp], InitialAcc0),
    Dict = lists:foldl(fun (Sample, Acc) ->
                               orddict:map(fun (timestamp, AccValues) ->
                                                [Sample#stat_entry.timestamp | AccValues];
                                            (K, AccValues) ->
                                                case orddict:find(K, Sample#stat_entry.values) of
                                                    {ok, ThisValue} -> [ThisValue | AccValues];
                                                    _ -> [null | AccValues]
                                                end
                                        end, Acc)
                       end, InitialAcc, ReversedRest),

    ExtraStats = lists:map(fun ({K, {F, [StatNameA, StatNameB]}}) ->
                                   ResA = orddict:find(StatNameA, Dict),
                                   ResB = orddict:find(StatNameB, Dict),
                                   ValR = case {ResA, ResB} of
                                              {{ok, ValA}, {ok, ValB}} ->
                                                  lists:zipwith(F, ValA, ValB);
                                              _ -> undefined
                                          end,
                                   {K, ValR}
                           end, computed_stats_lazy_proplist()),

    lists:filter(fun ({_, undefined}) -> false;
                     ({_, _}) -> true
                 end, ExtraStats)
        ++ orddict:to_list(Dict).

build_buckets_stats_ops_response(_PoolId, Nodes, [BucketName], Params) ->
    {Samples, ClientTStamp, Step, TotalNumber} = grab_aggregate_op_stats(BucketName, Nodes, Params),
    PropList2 = samples_to_proplists(Samples),
    OpPropList0 = [{samples, {struct, PropList2}},
                   {samplesCount, TotalNumber},
                   {isPersistent, ns_bucket:is_persistent(BucketName)},
                   {lastTStamp, case proplists:get_value(timestamp, PropList2) of
                                    [] -> 0;
                                    L -> lists:last(L)
                                end},
                   {interval, Step * 1000}],
    OpPropList = case ClientTStamp of
                     undefined -> OpPropList0;
                     _ -> [{tstampParam, ClientTStamp}
                           | OpPropList0]
                 end,
    {struct, [{op, {struct, OpPropList}}]}.

is_safe_key_name(Name) ->
    lists:all(fun (C) ->
                      C >= 16#20 andalso C =< 16#7f
              end, Name).

build_buckets_stats_hks_response(_PoolId, [BucketName]) ->
    BucketsTopKeys = case hot_keys_keeper:bucket_hot_keys(BucketName) of
                         undefined -> [];
                         X -> X
                     end,
    jsonify_hks(BucketsTopKeys).

jsonify_hks(BucketsTopKeys) ->
    HotKeyStructs = lists:map(fun ({Key, PList}) ->
                                      EscapedKey = case is_safe_key_name(Key) of
                                                       true -> Key;
                                                       _ -> "BIN_" ++ base64:encode_to_string(Key)
                                                   end,
                                      {struct, [{name, list_to_binary(EscapedKey)},
                                                {ops, proplists:get_value(ops, PList)}]}
                              end, BucketsTopKeys),
    {struct, [{hot_keys, HotKeyStructs}]}.

aggregate_stat_kv_pairs([], _BValues, Acc) ->
    lists:reverse(Acc);
aggregate_stat_kv_pairs(APairs, [], Acc) ->
    lists:reverse(Acc, APairs);
aggregate_stat_kv_pairs([{AK, AV} = APair | ARest] = A,
                        [{BK, BV} | BRest] = B,
                        Acc) ->
    case AK of
        BK ->
            NewAcc = [{AK,
                       try AV+BV
                       catch error:badarith ->
                               case ([X || X <- [AV,BV],
                                           X =/= undefined]) of
                                   [] -> 0;
                                   [X|_] -> X
                               end
                       end} | Acc],
            aggregate_stat_kv_pairs(ARest, BRest, NewAcc);
        _ when AK < BK ->
            case AV of
                undefined ->
                    aggregate_stat_kv_pairs(ARest, B, [{AK, 0} | Acc]);
                _ ->
                    aggregate_stat_kv_pairs(ARest, B, [APair | Acc])
            end;
        _ ->
            aggregate_stat_kv_pairs(A, BRest, Acc)
    end.

aggregate_stat_kv_pairs_test() ->
    ?assertEqual([{a, 3}, {b, 0}, {c, 1}, {d,1}],
                 aggregate_stat_kv_pairs([{a, 1}, {b, undefined}, {c,1}, {d, 1}],
                                         [{a, 2}, {b, undefined}, {d, undefined}, {e,1}],
                                         [])),
    ?assertEqual([{a, 3}, {b, 0}, {c, 1}, {d,1}],
                 aggregate_stat_kv_pairs([{a, 1}, {b, undefined}, {c,1}, {d, 1}],
                                         [{a, 2}, {b, undefined}, {ba, 123}],
                                         [])),
    ?assertEqual([{a, 3}, {b, 0}, {c, 1}, {d,1}],
                 aggregate_stat_kv_pairs([{a, 1}, {b, undefined}, {c,1}, {d, 1}],
                                         [{a, 2}, {c,0}, {d, undefined}, {e,1}],
                                         [])).


aggregate_stat_entries(A, B) ->
    true = (B#stat_entry.timestamp =:= A#stat_entry.timestamp),
    NewValues = aggregate_stat_kv_pairs(A#stat_entry.values,
                                        B#stat_entry.values,
                                        []),
    A#stat_entry{values = NewValues}.

membase_stats_description() ->
    [{struct,[{blockName,<<"Summary">>},
              {stats,
               [{struct,[{desc,<<"ops per second">>},
                         {name,<<"ops">>},
                         {default,true}]},
                {struct,[{desc,<<"cache miss %">>},
                         {name,<<"ep_cache_miss_rate">>},
                         {maxY,100}]},
                {struct,[{desc,<<"creates per second">>},
                         {name,<<"ep_ops_create">>}]},
                {struct,[{desc,<<"updates per second">>},
                         {name,<<"ep_ops_update">>}]},
                {struct,[{desc,<<"disk reads">>},
                         {name,<<"ep_bg_fetched">>}]},
                {struct,[{desc,<<"back-offs per second">>},
                         {name,<<"ep_tap_total_queue_backoff">>}]}]}]},
     {struct,[{blockName,<<"vBucket Resources">>},
              {extraCSSClasses,<<"withtotal closed">>},
              {columns,
               [<<"Active">>,<<"Replica">>,<<"Pending">>,<<"Total">>]},
              {stats,
               [{struct,[{desc,<<"active vBuckets">>},
                         {name,<<"vb_active_num">>}]},
                {struct,[{desc,<<"replica vBuckets">>},
                         {name,<<"vb_replica_num">>}]},
                {struct,[{desc,<<"pending vBuckets">>},
                         {name,<<"vb_pending_num">>}]},
                {struct,[{desc,<<"total vBuckets">>},
                         {name,<<"ep_vb_total">>}]},
                {struct,[{desc,<<"active items">>},
                         {name,<<"curr_items">>}]},
                {struct,[{desc,<<"replica items">>},
                         {name,<<"vb_replica_curr_items">>}]},
                {struct,[{desc,<<"pending items">>},
                         {name,<<"vb_pending_curr_items">>}]},
                {struct,[{desc,<<"total items">>},
                         {name,<<"curr_items_tot">>}]},
                {struct,[{desc,<<"% resident items">>},
                         {name,
                          <<"vb_active_resident_items_ratio">>},
                         {maxY,100}]},
                {struct,[{desc,<<"% resident items">>},
                         {name,
                          <<"vb_replica_resident_items_ratio">>},
                         {maxY,100}]},
                {struct,[{desc,<<"% resident items">>},
                         {name,
                          <<"vb_pending_resident_items_ratio">>},
                         {maxY,100}]},
                {struct,[{desc,<<"% resident items">>},
                         {name,<<"ep_resident_items_rate">>},
                         {maxY,100}]},
                {struct,[{desc,<<"new items per sec">>},
                         {name,<<"vb_active_ops_create">>}]},
                {struct,[{desc,<<"new items per sec">>},
                         {name,<<"vb_replica_ops_create">>}]},
                {struct,[{desc,<<"new items per sec">>},
                         {name,<<"vb_pending_ops_create">>},
                         {missing,true}]},
                {struct,[{desc,<<"new items per sec">>},
                         {name,<<"ep_ops_create">>}]},
                {struct,[{desc,<<"ejections per sec">>},
                         {name,<<"vb_active_eject">>}]},
                {struct,[{desc,<<"ejections per sec">>},
                         {name,<<"vb_replica_eject">>}]},
                {struct,[{desc,<<"ejections per sec">>},
                         {name,<<"vb_pending_eject">>}]},
                {struct,[{desc,<<"ejections per sec">>},
                         {name,<<"ep_num_value_ejects">>}]},
                {struct,[{desc,<<"user data in RAM">>},
                         {name,<<"vb_active_itm_memory">>}]},
                {struct,[{desc,<<"user data in RAM">>},
                         {name,<<"vb_replica_itm_memory">>}]},
                {struct,[{desc,<<"user data in RAM">>},
                         {name,<<"vb_pending_itm_memory">>}]},
                {struct,[{desc,<<"user data in RAM">>},
                         {name,<<"ep_kv_size">>}]},
                {struct,[{desc,<<"metadata in RAM">>},
                         {name,<<"vb_active_ht_memory">>}]},
                {struct,[{desc,<<"metadata in RAM">>},
                         {name,<<"vb_replica_ht_memory">>}]},
                {struct,[{desc,<<"metadata in RAM">>},
                         {name,<<"vb_pending_ht_memory">>}]},
                {struct,[{desc,<<"metadata in RAM">>},
                         {name,<<"ep_ht_memory">>}]}]}]},
     {struct,[{blockName,<<"Disk Queues">>},
              {extraCSSClasses,<<"withtotal closed">>},
              {columns,
               [<<"Active">>,<<"Replica">>,<<"Pending">>,<<"Total">>]},
              {stats,
               [{struct,[{desc,<<"items">>},
                         {name,<<"vb_active_queue_size">>}]},
                {struct,[{desc,<<"items">>},
                         {name,<<"vb_replica_queue_size">>}]},
                {struct,[{desc,<<"items">>},
                         {name,<<"vb_pending_queue_size">>}]},
                {struct,[{desc,<<"items">>},
                         {name,<<"ep_diskqueue_items">>}]},
                {struct,[{desc,<<"fill rate">>},
                         {name,<<"vb_active_queue_fill">>}]},
                {struct,[{desc,<<"fill rate">>},
                         {name,<<"vb_replica_queue_fill">>}]},
                {struct,[{desc,<<"fill rate">>},
                         {name,<<"vb_pending_queue_fill">>}]},
                {struct,[{desc,<<"fill rate">>},
                         {name,<<"ep_diskqueue_fill">>}]},
                {struct,[{desc,<<"drain rate">>},
                         {name,<<"vb_active_queue_drain">>}]},
                {struct,[{desc,<<"drain rate">>},
                         {name,<<"vb_replica_queue_drain">>}]},
                {struct,[{desc,<<"drain rate">>},
                         {name,<<"vb_pending_queue_drain">>}]},
                {struct,[{desc,<<"drain rate">>},
                         {name,<<"ep_diskqueue_drain">>}]},
                {struct,[{desc,<<"average age">>},
                         {name,<<"vb_avg_active_queue_age">>}]},
                {struct,[{desc,<<"average age">>},
                         {name,<<"vb_avg_replica_queue_age">>}]},
                {struct,[{desc,<<"average age">>},
                         {name,<<"vb_avg_pending_queue_age">>}]},
                {struct,[{desc,<<"average age">>},
                         {name,<<"vb_avg_total_queue_age">>}]}]}]},
     {struct,[{blockName,<<"Tap Queues">>},
              {extraCSSClasses,<<"withtotal closed">>},
              {columns,
               [<<"Replication">>,<<"Rebalance">>,<<"Clients">>,
                <<"Total">>]},
              {stats,
               [{struct,[{desc,<<"# tap senders">>},
                         {name,<<"ep_tap_replica_count">>}]},
                {struct,[{desc,<<"# tap senders">>},
                         {name,<<"ep_tap_rebalance_count">>}]},
                {struct,[{desc,<<"# tap senders">>},
                         {name,<<"ep_tap_user_count">>}]},
                {struct,[{desc,<<"# tap senders">>},
                         {name,<<"ep_tap_total_count">>}]},
                {struct,[{desc,<<"# items">>},
                         {name,<<"ep_tap_replica_qlen">>}]},
                {struct,[{desc,<<"# items">>},
                         {name,<<"ep_tap_rebalance_qlen">>}]},
                {struct,[{desc,<<"# items">>},
                         {name,<<"ep_tap_user_qlen">>}]},
                {struct,[{desc,<<"# items">>},
                         {name,<<"ep_tap_total_qlen">>}]},
                {struct,[{desc,<<"fill rate">>},
                         {name,<<"ep_tap_replica_queue_fill">>}]},
                {struct,[{desc,<<"fill rate">>},
                         {name,
                          <<"ep_tap_rebalance_queue_fill">>}]},
                {struct,[{desc,<<"fill rate">>},
                         {name,<<"ep_tap_user_queue_fill">>}]},
                {struct,[{desc,<<"fill rate">>},
                         {name,<<"ep_tap_total_queue_fill">>}]},
                {struct,[{desc,<<"drain rate">>},
                         {name,<<"ep_tap_replica_queue_drain">>}]},
                {struct,[{desc,<<"drain rate">>},
                         {name,
                          <<"ep_tap_rebalance_queue_drain">>}]},
                {struct,[{desc,<<"drain rate">>},
                         {name,<<"ep_tap_user_queue_drain">>}]},
                {struct,[{desc,<<"drain rate">>},
                         {name,<<"ep_tap_total_queue_drain">>}]},
                {struct,[{desc,<<"back-off rate">>},
                         {name,
                          <<"ep_tap_replica_queue_backoff">>}]},
                {struct,[{desc,<<"back-off rate">>},
                         {name,
                          <<"ep_tap_rebalance_queue_backoff">>}]},
                {struct,[{desc,<<"back-off rate">>},
                         {name,<<"ep_tap_user_queue_backoff">>}]},
                {struct,[{desc,<<"back-off rate">>},
                         {name,<<"ep_tap_total_queue_backoff">>}]},
                {struct,[{desc,<<"# backfill remaining">>},
                         {name,
                          <<"ep_tap_replica_queue_backfillremaining">>}]},
                {struct,[{desc,<<"# backfill remaining">>},
                         {name,
                          <<"ep_tap_rebalance_queue_backfillremaining">>}]},
                {struct,[{desc,<<"# backfill remaining">>},
                         {name,
                          <<"ep_tap_user_queue_backfillremaining">>}]},
                {struct,[{desc,<<"# backfill remaining">>},
                         {name,
                          <<"ep_tap_total_queue_backfillremaining">>}]},
                {struct,[{desc,<<"# remaining on disk">>},
                         {name,
                          <<"ep_tap_replica_queue_itemondisk">>}]},
                {struct,[{desc,<<"# remaining on disk">>},
                         {name,
                          <<"ep_tap_rebalance_queue_itemondisk">>}]},
                {struct,[{desc,<<"# remaining on disk">>},
                         {name,
                          <<"ep_tap_user_queue_itemondisk">>}]},
                {struct,[{desc,<<"# remaining on disk">>},
                         {name,
                          <<"ep_tap_total_queue_itemondisk">>}]}]}]}].


memcached_stats_description() ->
    [{struct,[{blockName,<<"Memcached">>},
              {stats,
               [{struct,[{name,<<"ops">>},
                         {desc,<<"Operations per sec.">>},
                         {default,true}]},
                {struct,[{name,<<"hit_ratio">>},
                         {desc,<<"Hit ratio (%)">>},
                         {maxY,100}]},
                {struct,[{name,<<"mem_used">>},
                         {desc,<<"Memory bytes used">>}]},
                {struct,[{name,<<"curr_items">>},
                         {desc,<<"Items count">>}]},
                {struct,[{name,<<"evictions">>},
                         {desc,<<"RAM evictions per sec.">>}]},
                {struct,[{name,<<"cmd_set">>},
                         {desc,<<"Sets per sec.">>}]},
                {struct,[{name,<<"cmd_get">>},
                         {desc,<<"Gets per sec.">>}]},
                {struct,[{name,<<"bytes_written">>},
                         {desc,<<"Net. bytes TX per sec.">>}]},
                {struct,[{name,<<"bytes_read">>},
                         {desc,<<"Net. bytes RX per sec.">>}]},
                {struct,[{name,<<"get_hits">>},
                         {desc,<<"Get hits per sec.">>}]},
                {struct,[{name,<<"delete_hits">>},
                         {desc,<<"Delete hits per sec.">>}]},
                {struct,[{name,<<"incr_hits">>},
                         {desc,<<"Incr hits per sec.">>}]},
                {struct,[{name,<<"decr_hits">>},
                         {desc,<<"Decr hits per sec.">>}]},
                {struct,[{name,<<"delete_misses">>},
                         {desc,<<"Delete misses per sec.">>}]},
                {struct,[{name,<<"decr_misses">>},
                         {desc,<<"Decr misses per sec.">>}]},
                {struct,[{name,<<"get_misses">>},
                         {desc,<<"Get Misses per sec.">>}]},
                {struct,[{name,<<"incr_misses">>},
                         {desc,<<"Incr misses per sec.">>}]},
                {struct,[{name,<<"curr_connections">>},
                         {desc,<<"Connections count.">>}]},
                {struct,[{name,<<"cas_hits">>},
                         {desc,<<"CAS hits per sec.">>}]},
                {struct,[{name,<<"cas_badval">>},
                         {desc,<<"CAS badval per sec.">>}]},
                {struct,[{name,<<"cas_misses">>},
                         {desc,
                          <<"CAS misses per sec.">>}]}]}]}].

server_resources_stats_description() ->
    [{blockName,<<"Server Resources">>},
     {serverResources, true},
     {extraCSSClasses,<<"server_resources">>},
     {stats,
      [{struct,[{name,<<"swap_used">>},
                {desc,<<"swap usage">>}]},
       {struct,[{name,<<"mem_actual_free">>},
                {desc,<<"free memory">>}]},
       {struct,[{name,<<"cpu_utilization_rate">>},
                {desc,<<"CPU utilization %">>},
                {maxY,100}]}]}].

serve_stats_directory(_PoolId, BucketId, Req) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(BucketId),
    BaseDescription = case ns_bucket:bucket_type(BucketConfig) of
                          membase -> membase_stats_description();
                          memcached -> memcached_stats_description()
                      end,
    BaseDescription1 = [{struct, server_resources_stats_description()} | BaseDescription],
    Prefix = menelaus_util:concat_url_path(["pools", "default", "buckets", BucketId, "stats"]),
    Desc = [{struct, add_specific_stats_url(BD, Prefix)} || {struct, BD} <- BaseDescription1],
    menelaus_util:reply_json(Req, {struct, [{blocks, Desc}]}).

add_specific_stats_url(BlockDesc, Prefix) ->
    {stats, Infos} = lists:keyfind(stats, 1, BlockDesc),
    NewInfos =
        [{struct, [{specificStatsURL, begin
                                          {name, Name} = lists:keyfind(name, 1, KV),
                                          iolist_to_binary(Prefix ++ "/" ++ mochiweb_util:quote_plus(Name))
                                      end} |
                   KV]} || {struct, KV} <- Infos],
    lists:keyreplace(stats, 1, BlockDesc, {stats, NewInfos}).
