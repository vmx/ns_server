%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
-module(ns_mail).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-export([send/5, ns_log_cat/1]).

-include("ns_common.hrl").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    {ok, empty_state}.

handle_call(Request, From, State) ->
    ?log_info("ns_mail: unexpected call ~p from ~p~n", [Request, From]),
    {ok, State}.

handle_cast({send, Sender, Rcpts, Body, Options}, State) ->
    ?log_info("ns_mail: sending email ~p ~p ~p~n", [Sender, Rcpts, Body]),
    gen_smtp_client:send({Sender, Rcpts, Body}, Options),
    {noreply, State}.

handle_info({'EXIT', _Pid, Reason}, State) ->
    case Reason of
        normal ->
            ?log_info("ns_mail: successfully sent mail~n", []);
        Error ->
            ns_log:log(?MODULE, 0001, "error sending mail: ~p", [Error])
    end,
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% API

send(Sender, Rcpts, Subject, Body, Options) ->
    Message = mimemail:encode({<<"text">>, <<"plain">>,
                              make_headers(Sender, Rcpts, Subject), [],
                              list_to_binary(Body)}),
    gen_server:cast(?MODULE, {send, Sender, Rcpts, binary_to_list(Message),
                              Options}).

ns_log_cat(0001) -> warn.

%% Internal functions

format_addr(Rcpts) ->
    string:join(["<" ++ Addr ++ ">" || Addr <- Rcpts], ", ").

make_headers(Sender, Rcpts, Subject) ->
    [{<<"From">>, list_to_binary(format_addr([Sender]))},
     {<<"To">>, list_to_binary(format_addr(Rcpts))},
     {<<"Subject">>, list_to_binary(Subject)}].
