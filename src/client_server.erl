-module(client_server).
-author("Elias Johansson, eliasj@student.chalmers.se").

-behaviour(gen_server).

%% API
-export([start/0, stop/0, registation/1, nick/2, 
		 whois/1, leave/1, id/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		 terminate/2, code_change/3]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start() ->
	io:format("Starting the client server~n"),
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
	gen_server:call(?MODULE, stop).

registation(Nick) ->
	gen_server:call(?MODULE, {registation, Nick}).

nick(Who, NewNick) ->
	gen_server:call(?MODULE, {nick, Who, NewNick}).

whois(Who) ->
	gen_server:call(?MODULE, {whois, Who}).

leave(Who) ->
	gen_server:call(?MODULE, {leave, Who}).

id(Who) ->
	gen_server:call(?MODULE, {id, Who}).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_server callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([]) ->
	process_flag(trap_exit, true),
	{ok, ets:new(?MODULE, [])}.

handle_call(stop, _From, Tab) ->
	%lists:map(fun({_,P}) -> client:stop(P) end, ets:tab2list(Tab)),
	ets:delete(Tab),
	{stop, normal, stopped, Tab};

handle_call({registation, Nick}, From, Users) ->
	{Pid,_} = From,
	Reply = case ets:insert_new(Users,{Nick, Pid}) of
				true  -> ok;
				false -> {error, ["433", " * ", Nick, " :Nickname is already in use"]}
			end,
	{reply, Reply, Users};


handle_call({nick, Who, Nick}, _, Users) ->
	Pid = ets:lookup_element(Users, Who, 2),
	Reply = case ets:insert_new(Users, {Nick, Pid}) of
				true -> ets:delete(Users, Who),
						ok;
				false -> {error, ["433", " * ", Nick, " :Nickname is already in use"]}
			end,
	{reply, Reply, Users};

handle_call({whois, Who}, _From, Users) ->
	Reply = case ets:lookup(Users, Who) of
				[U] -> {ok, U};
				_   -> error
			end,
	{reply, Reply, Users};

handle_call({leave, Who}, _From, Users) ->
	ets:delete(Users, Who),
	{noreply, Users};

handle_call({id,Who}, _From, Users) ->
	Reply = case ets:lookup(Users, Who) of
				[{Who, Pid}] -> {ok, Pid};
				_ -> {error, ["401 * ", Who, ":No such nick/channel"]}
			 end,
	{reply, Reply, Users};

handle_call(_Message, _From, Tab)->
	{reply, error, Tab}.

handle_cast(_Message, Tab) ->
	{noreply, Tab}.

handle_info(_Message, Tab) ->
	{noreply, Tab}.

terminate(_Reason, Tab) ->
	%%lists:map(fun({_,P}) -> client:stop(P) end, ets:tab2list(Tab)),
	ets:delete(Tab),
	ok.

code_change(_OldVersion, Tab, _Extra) -> 
	{ok, Tab}.
