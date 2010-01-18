-module(stats_aggregator).

-behaviour(gen_server).

-define(SAMPLE_SIZE, 1800).

%% API
-export([start_link/0,
         monitoring/3,
         received_data/5,
         unmonitoring/3,
         get_stats/4,
         get_stats/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {vals}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    timer:send_after(100, post_startup_init),
    {ok, #state{vals=dict:new()}}.

handle_call({get, Hostname, Port, Bucket, Count}, _From, State) ->
    Reply = ringdict:to_dict(Count,
                             dict:fetch({Hostname, Port, Bucket},
                                        State#state.vals)),
    {reply, Reply, State};
handle_call({get, Bucket, Count}, _From, State) ->
    Reply = (catch dict:fold(fun ({_H, _P, B}, V, A) ->
                                     Rv = case B of
                                              Bucket -> combine_stats(Count, V, A);
                                              _ -> A
                                          end,
                                     Rv
                             end,
                             dict:new(),
                             State#state.vals)),
    {reply, Reply, State}.

handle_cast({received, T, Hostname, Port, Bucket, Stats}, State) ->
    TS = dict:store(t, T, Stats),
    {noreply, State#state{vals=dict:update({Hostname, Port, Bucket},
                                           fun(R) ->
                                                   ringdict:add(TS, R)
                                           end,
                                           State#state.vals)}};
handle_cast({monitoring, Hostname, Port, Bucket}, State) ->
    error_logger:info_msg("Beginning to monitor:  ~s@~s:~p~n",
                          [Bucket, Hostname, Port]),
    {noreply, State#state{vals=dict:store({Hostname, Port, Bucket},
                                          ringdict:new(?SAMPLE_SIZE),
                                          State#state.vals)}};
handle_cast({unmonitoring, Hostname, Port, Bucket}, State) ->
    error_logger:info_msg("No longer monitoring:  ~s@~s:~p~n",
                          [Bucket, Hostname, Port]),
    {noreply, State#state{vals=dict:erase({Hostname, Port},
                                          State#state.vals)}}.

handle_info(post_startup_init, State) ->
    error_logger:info_msg("Performing post-startup stats initialization.~n"),
    initPools(),
    {noreply, State};
handle_info(Info, State) ->
    error_logger:info_msg("Just received ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

combine_stats(N, New, Existing) ->
    dict:merge(fun val_sum/3,
               dict:filter(fun classify/2, ringdict:to_dict(N, New)),
               Existing).

val_sum(_K, L1, L2) ->
    lists:zipwith(fun(V1, V2) -> V1+V2 end, L1, L2).

classify(K, _V) ->
     classify(K).

classify("pid") -> false;
classify("uptime") -> false;
classify("time") -> false;
classify("version") -> false;
classify("pointer_size") -> false;
classify("rusage_user") -> false;
classify("rusage_system") -> false;
classify("tcpport") -> false;
classify("udpport") -> false;
classify("inter") -> false;
classify("verbosity") -> false;
classify("oldest") -> false;
classify("evictions") -> false;
classify("domain_socket") -> false;
classify("umask") -> false;
classify("growth_factor") -> false;
classify("chunk_size") -> false;
classify("num_threads") -> false;
classify("stat_key_prefix") -> false;
classify("detail_enabled") -> false;
classify("reqs_per_event") -> false;
classify("cas_enabled") -> false;
classify("tcp_backlog") -> false;
classify("binding_protocol") -> false;
classify(t) -> false;
classify(_) -> true.

initPools() ->
    % This code assumes each connected server runs all pools and all
    % buckets.
    [Pool | []] = mc_pool:list(), % assume one pool
    Buckets = mc_bucket:list(Pool),
    Servers = lists:usort(lists:flatmap(fun(B) -> bucket_servers(Pool, B)
                                        end, Buckets)),
    % Assuming all servers run all buckets.
    lists:foreach(fun({H, P}) ->
                          stats_collector:monitor(H, P, Buckets)
                  end,
                  Servers).

bucket_servers(Pool, B) ->
    lists:map(fun({mc_addr, HP, _K, _A}) ->
                      [H, P] = string:tokens(HP, ":"),
                      {I, []} = string:to_integer(P),
                      {H, I}
              end,
              mc_bucket:addrs(Pool, B)).

%
% API
%

received_data(T, Hostname, Port, Bucket, Stats) ->
    gen_server:cast(?MODULE, {received, T, Hostname, Port, Bucket, Stats}).

monitoring(Hostname, Port, Bucket) ->
    gen_server:cast(?MODULE, {monitoring, Hostname, Port, Bucket}).

unmonitoring(Hostname, Port, Bucket) ->
    gen_server:cast(?MODULE, {unmonitoring, Hostname, Port, Bucket}).

get_stats(Hostname, Port, Bucket, Count) ->
    gen_server:call(?MODULE, {get, Hostname, Port, Bucket, Count}).

get_stats(Bucket, Count) ->
    gen_server:call(?MODULE, {get, Bucket, Count}).
