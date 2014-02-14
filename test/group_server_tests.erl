-module(group_server_tests).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").

start_stop_test_() ->
    {"Start and stop test",
     {setup,
      fun start/0,
      fun stop/1,
      fun is_registered/1}}.

%%join_remove_test_() ->
%%    {"Join a channel and leave",
%%     {setup,
%%      fun start/0,
%%      fun stop/1,
%%      fun join_and_remove/1}}.

start() ->
    {ok, Pid} = group_server:start(),
    Pid.

stop(_) ->
    group_server:stop().

is_registered(Pid) ->
    [?_assert(erlang:is_process_alive(Pid)),
     ?_assertEqual(Pid, whereis(group_server))].

join_and_remove(_) ->
    [?_assertEqual(ok, group_server:join("Test")),
     ?_assertEqual(ok, group_server:remove("Test"))].
