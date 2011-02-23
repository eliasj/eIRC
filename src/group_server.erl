-module(group_server).
-author("Elias Johansson, eliasj@student.chalmers.se").

-behaviour(gen_server).

%% API
-export([start/0, stop/0, join/1, remove/1, match/1, listchan/0]).

%% gen_serveru callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start() ->
    io:format("Starting the group server~n"),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:call(?MODULE, stop).

join(Chan) ->
    gen_server:call(?MODULE, {join, Chan}).

remove(Chan) ->
    gen_server:call(?MODULE, {remove, Chan}).

match(Chan) ->
    gen_server:call(?MODULE, {match, Chan}).

listchan() ->
    gen_server:call(?MODULE, listchan).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_server callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([]) ->
	process_flag(trap_exit, true),
    {ok, ets:new(?MODULE, [])}.

handle_call(stop, _From, Tab) ->
    do(ets:tab2list(Tab), fun(P) -> chat_group:stop(P) end),
    ets:delete(Tab),
    {stop, normal, stopped, Tab};

handle_call({join, Chan}, From, Chans) ->
	try 
		{CPid,_} = From, 
		Replay = case ets:lookup(Chans, Chan) of
					 []  -> case eirc_app:start_group(Chan, CPid) of
								{ok, Pid} ->
									ets:insert(Chans, {Chan, Pid}),
									Pid;
								{error, Reason} ->
									exit({join_group, Reason})
							end;
					 [{Chan,Pid}] -> chat_group:join(Pid, CPid),
									 Pid
				 end,
		{reply, Replay, Chans}
	catch exit:Why ->
			  error_logger:error_msg("Error in async accept: ~p.\n",[Why]),
			  {stop, Why, Chans}
	end;

handle_call({remove, Chan}, _From, Chans) ->
    Reply = ets:delete(Chans, Chan),
    {reply, Reply, Chans};

handle_call({match, Chan}, _From, Chans) ->
    Reply = ets:match(Chans, {Chan}),
    {reply, Reply, Chans};

handle_call(listchan, _From, Chans)->
    {noreply, Chans};

handle_call(_Message, _From, Tab)->
    {reply, error, Tab}.

handle_cast(_Message, Tab) ->
    {noreply, Tab}.

handle_info(_Message, Tab) ->
    {noreply, Tab}.

terminate(_Reason, Tab) ->
    do(ets:tab2list(Tab), fun(P) -> chat_group:stop(P) end),
    ets:delete(Tab),
    ok.

code_change(_OldVersion, Tab, _Extra) -> 
    {ok, Tab}.

do([], _Fun) ->
    ok;
do([{_Key, Pid}|Chans], Fun) ->
    Fun(Pid),
    do(Chans, Fun).
