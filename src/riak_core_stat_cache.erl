%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @ doc fetches stats for registered modules and stores them
%% in an ets backed cache.
%% Only ever allows one process at a time to calculate stats.
%% Will always serve the stats that are in the cache.
%% Adds a stat `{stat_mod_ts, timestamp()}' to the stats returned
%% from `get_stats/1' which is the time those stats were calculated.

-module(riak_core_stat_cache).

-behaviour(gen_server).

%% API
-export([start_link/0, get_stats/1, register_app/2, register_app/3,
        clear_cache/1, stop/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).
%% @doc Cache item refresh rate in seconds
-define(REFRESH_RATE, 1).
-define(REFRSH_MILLIS(N), timer:seconds(N)).
-define(ENOTREG(App), {error, {not_registered, App}}).

-record(state, {tab, active=orddict:new(), apps=orddict:new()}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

register_app(App, {M, F, A}) ->
    RefreshRate = app_helper:get_env(riak_core, stat_cache_ttl, ?REFRESH_RATE),
    register_app(App, {M, F, A}, RefreshRate).

register_app(App, {M, F, A}, RefreshRateSecs) ->
    gen_server:call(?SERVER, {register, App, {M, F, A}, ?REFRSH_MILLIS(RefreshRateSecs)}).

get_stats(App) ->
    gen_server:call(?SERVER, {get_stats, App}, infinity).

clear_cache(App) ->
    gen_server:call(?SERVER, {clear, App}, infinity).

stop() ->
    gen_server:cast(?SERVER, stop).

%%% gen server

init([]) ->
    process_flag(trap_exit, true),
    Tab = ets:new(?MODULE, [protected, set, named_table]),
    RefreshRateSecs = app_helper:get_env(riak_core, stat_cache_ttl, ?REFRESH_RATE),
    RefreshRateMillis = ?REFRSH_MILLIS(RefreshRateSecs),
    %% re-register mods, if this is a restart after a crash
    RegisteredMods = lists:foldl(fun({App, Mod}, Registered) ->
                                         register_mod(App, Mod, produce_stats, [], RefreshRateMillis, Registered),
                                         schedule_get_stats(RefreshRateMillis, App, {Mod, produce_stats, []}) end,
                                 orddict:new(),
                                 riak_core:stat_mods()),
    {ok, #state{tab=Tab, apps=orddict:from_list(RegisteredMods)}}.

handle_call({register, App, {Mod, Fun, Args}=MFA, RefreshRateMillis}, _From, State0=#state{apps=Apps0}) ->
    Apps = case registered(App, Apps0) of
               false ->
                   Apps1 = register_mod(App, Mod, Fun, Args, RefreshRateMillis, Apps0),
                   schedule_get_stats(RefreshRateMillis, App, MFA),
                   Apps1;
               {true, _} ->
                   Apps0
           end,
    {reply, ok, State0#state{apps=Apps}};
handle_call({get_stats, App}, From, State0=#state{apps=Apps, active=Active0, tab=Tab}) ->
    Reply = case registered(App, Apps) of
                false ->
                    {reply, ?ENOTREG(App), State0};
                {true, {M, F, A, _RefreshRateMillis}} ->
                    case cache_get(App, Tab) of
                        No when No == miss ->
                            Active = maybe_get_stats(App, From, Active0, {M, F, A}),
                            {noreply, State0#state{active=Active}};
                        {hit, Stats, TS} ->
                            FreshnessStat = make_freshness_stat(App, TS),
                            {reply, {ok, [FreshnessStat | Stats], TS}, State0}
                    end
            end,
    Reply;
handle_call({clear, App}, _From, State=#state{apps=Apps, tab=Tab}) ->
    Reply = case registered(App, Apps) of
                false ->
                    {reply, ?ENOTREG(App), State};
                {true, _} ->
                    true = ets:delete(Tab, App),
                    {reply, ok, State}
            end,
    Reply;
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @doc call back from process executig the stat calculation
handle_cast({stats, App, Stats, TS}, State0=#state{tab=Tab, active=Active, apps=Apps}) ->
    ets:insert(Tab, {App, TS, Stats}),
    State = case orddict:find(App, Active) of
                {ok, {_Pid, Awaiting}} ->
                    [gen_server:reply(From, {ok, [make_freshness_stat(App, TS) |Stats], TS}) || From <- Awaiting, From /= ?SERVER],
                    State0#state{active=orddict:erase(App, Active)};
                error ->
                    State0
            end,
    {ok, {M, F, A, RefreshRateMillis}} = orddict:find(App, Apps),
    schedule_get_stats(RefreshRateMillis, App, {M, F, A}),
    {noreply, State};
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% don't let a crashing stat mod crash the cache
handle_info({'EXIT', FromPid, Reason}, State0=#state{active=Active}) when Reason /= normal ->
     Reply = case awaiting_for_pid(FromPid, Active) of
                 not_found ->
                     {stop, Reason, State0};
                 {ok, {App, Awaiting}} ->
                     [gen_server:reply(From, {error, Reason}) || From <- Awaiting, From /= ?SERVER],
                     {noreply, State0#state{active=orddict:erase(App, Active)}}
             end,
     Reply;
%% @doc callback on timer timeout to keep cache fresh
handle_info({get_stats, {App, MFA}}, State) ->
    Active =  maybe_get_stats(App, ?SERVER, State#state.active, MFA),
    {noreply, State#state{active=Active}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal
schedule_get_stats(After, App, MFA) ->
    erlang:send_after(After, ?SERVER, {get_stats, {App, MFA}}).

make_freshness_stat(App, TS) ->
    {make_freshness_stat_name(App), TS}.

make_freshness_stat_name(App) ->
    list_to_atom(atom_to_list(App) ++ "_stat_ts").

register_mod(App, Mod, Fun, Args, RefreshRateMillis, Apps) ->
    folsom_metrics:new_histogram({?MODULE, Mod}),
    folsom_metrics:new_meter({?MODULE, App}),
    orddict:store(App, {Mod, Fun, Args, RefreshRateMillis}, Apps).

registered(App, Apps) ->
    registered(orddict:find(App, Apps)).

registered(error) ->
    false;
registered({ok, Val}) ->
    {true, Val}.

cache_get(App, Tab) ->
    Res = case ets:lookup(Tab, App) of
              [] ->
                  miss;
              [{App, TStamp, Stats}] ->
                  {hit, Stats, TStamp}
          end,
    Res.

maybe_get_stats(App, From, Active, {M, F, A}) ->
    %% if a get stats is not under way start one
    Awaiting = case orddict:find(App, Active) of
                   error ->
                       Pid = do_get_stats(App, {M, F, A}),
                       {Pid, [From]};
                   {ok, {Pid, Froms}} ->
                       {Pid, [From|Froms]}
               end,
    orddict:store(App, Awaiting, Active).

do_get_stats(App, {M, F, A}) ->
    spawn_link(fun() ->
                       Stats = folsom_metrics:histogram_timed_update({?MODULE, M}, M, F, A),
                       folsom_metrics:notify_existing_metric({?MODULE, App}, 1, meter),
                       gen_server:cast(?MODULE, {stats, App, Stats, folsom_utils:now_epoch()}) end).

awaiting_for_pid(Pid, Active) ->
    case  [{App, Awaiting} || {App, {Proc, Awaiting}} <- orddict:to_list(Active),
                              Proc == Pid] of
        [] ->
            not_found;
        L -> {ok, hd(L)}
    end.

-ifdef(TEST).

-define(MOCKS, [folsom_utils, riak_core_stat, riak_kv_stat]).
-define(STATS, [{stat1, 0}, {stat2, 1}, {stat3, 2}]).

cached(App, Time) ->
    [make_freshness_stat(App, Time) | ?STATS].

cache_test_() ->
    {setup,
     fun() ->
             folsom:start(),
             [meck:new(Mock, [passthrough]) || Mock <- ?MOCKS],
             riak_core_stat_cache:start_link()
     end,
     fun(_) ->
             folsom:stop(),
             [meck:unload(Mock) || Mock <- ?MOCKS],
             riak_core_stat_cache:stop()
     end,

     [{"Register with the cache",
      fun register/0},
      {"Get cached value",
       fun get_cached/0},
      {"Expired cache, re-calculate",
       fun get_expired/0},
      {"Only a single process can calculate stats",
       fun serialize_calls/0},
      {"Crash test",
       fun crasher/0}
      ]}.

register() ->
    [meck:expect(M, produce_stats, fun() -> ?STATS end)
     || M <- [riak_core_stat, riak_kv_stat]],
    Now = tick(1000, 0),
    riak_core_stat_cache:register_app(riak_core, {riak_core_stat, produce_stats, []}, 5),
    riak_core_stat_cache:register_app(riak_kv, {riak_kv_stat, produce_stats, []}, 5),
    NonSuch = riak_core_stat_cache:get_stats(nonsuch),
    ?assertEqual({ok, cached(riak_core, Now), Now}, riak_core_stat_cache:get_stats(riak_core)),
    ?assertEqual({ok, cached(riak_kv, Now), Now}, riak_core_stat_cache:get_stats(riak_kv)),
    ?assertEqual(?ENOTREG(nonsuch), NonSuch),
    %% and check the cache has the correct values
    [?assertEqual([{App, Now, ?STATS}], ets:lookup(riak_core_stat_cache, App))
     || App <- [riak_core, riak_kv]],
    %% and that a meter and histogram has been registered for all registered modules
    [?assertEqual([{{?MODULE, M}, [{type, histogram}]}], folsom_metrics:get_metric_info({?MODULE, M}))
        || M <- [riak_core_stat, riak_kv_stat]],
    [?assertEqual([{{?MODULE, App}, [{type, meter}]}], folsom_metrics:get_metric_info({?MODULE, App}))
     || App <- [riak_core, riak_kv]].

get_cached() ->
    Now = tick(1000, 0),
    [?assertEqual({ok, cached(riak_core, Now), Now}, riak_core_stat_cache:get_stats(riak_core))
     || _ <- lists:seq(1, 20)],
    ?assertEqual(1, meck:num_calls(riak_core_stat, produce_stats, [])).

get_expired() ->
    CalcTime = 1000,
    _Expired = tick(CalcTime, ?REFRESH_RATE+?REFRESH_RATE),
    [?assertEqual({ok, cached(riak_core, CalcTime), CalcTime}, riak_core_stat_cache:get_stats(riak_core))
     || _ <- lists:seq(1, 20)],
    %% Stale stats should no longer trigger a stat calculation
    ?assertEqual(1, meck:num_calls(riak_core_stat, produce_stats, [])).

serialize_calls() ->
    %% many processes can call get stats at once
    %% they should not block the server
    %% but only one call to calculate stats should result
    %% the calling processes should block until they get a response
    %% call get_stats for kv from many processes at the same time
    %% check that they are blocked
    %% call get stats for core to show the server is not blocked
    %% return from the kv call and show a) all have same result
    %% b) only one call to produce_stats
    %% But ONLY in the case that the cache is empty. At any other time,
    %% that cached answer should be returned.
    riak_core_stat_cache:clear_cache(riak_kv),
    Procs = 20,
    Then = 1000,
    Now = tick(2000, 0),
    meck:expect(riak_kv_stat, produce_stats, fun() -> register(blocked, self()), receive release -> ?STATS  end end),
    Coordinator = self(),
    Collector  = spawn_link(fun() -> collect_results(Coordinator, [], Procs) end),
    Pids = [spawn_link(fun() -> Stats = riak_core_stat_cache:get_stats(riak_kv), Collector ! {res, Stats} end) || _ <- lists:seq(1, Procs)],
    ?assertEqual({ok, cached(riak_core, Then), Then}, riak_core_stat_cache:get_stats(riak_core)),
    [?assertEqual({status, waiting}, process_info(Pid, status)) || Pid <- Pids],

    timer:sleep(100), %% time for register

    blocked ! release,

    Results = receive
                  R -> R
              after
                  1000 ->
                        ?assert(false)
              end,

    [?assertEqual(undefined, process_info(Pid)) || Pid <- Pids],
    ?assertEqual(Procs, length(Results)),
    [?assertEqual({ok, cached(riak_kv, Now), Now}, Res) || Res <- Results],
    ?assertEqual(2, meck:num_calls(riak_kv_stat, produce_stats, [])).

crasher() ->
    riak_core_stat_cache:clear_cache(riak_kv),
    Pid = whereis(riak_core_stat_cache),
    Then = tick(1000, 0),
    Now = tick(10000, 0),
    meck:expect(riak_core_stat, produce_stats, fun() ->
                                                       ?STATS end),
    meck:expect(riak_kv_stat, produce_stats, fun() -> erlang:error(boom)  end),
    ?assertMatch({error, {boom, _Stack}}, riak_core_stat_cache:get_stats(riak_kv)),
    ?assertEqual(Pid, whereis(riak_core_stat_cache)),
    ?assertEqual({ok, cached(riak_core, Then), Then}, riak_core_stat_cache:get_stats(riak_core)).

tick(Moment, IncrBy) ->
    meck:expect(folsom_utils, now_epoch, fun() -> Moment + IncrBy end),
    Moment+IncrBy.

collect_results(Pid, Results, 0) ->
    Pid ! Results;
collect_results(Pid, Results, Procs) ->
    receive
        {res, Stats} ->
            collect_results(Pid, [Stats|Results], Procs-1)
    end.

-endif.
