-module(chat_group).
-author("Elias Johansson, eliasj@student.chalmers.se").

-behaviour(gen_server).

-export([start_link/2, stop/1, join/2, message/3, mode/2, names/2, nick/2, part/2, quit/5, topic/2, topic/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		terminate/2, code_change/3]).


-record(state, 	{
		name,		% name of the chat room
		topic=[], 	% topic in the chat room
		topic_time,	% the time topic was set
		topic_user,	% user who set the topic
		mode,		% mode on the chat room TODO
		users		% users in the chat room
	}).

%% TODO rewrite as a gen_server

%% API

start_link(Name, CPid) ->
	Pid = gen_server:start_link({local, list_to_atom(Name)}, ?MODULE, [Name], []),
	join(Name, CPid),
	Pid.

stop(Name) ->
	Name.

join(Name, User_id) ->
	gen_server:cast(list_to_atom(Name), {join, User_id}).

message(Name, User_id, Msg) ->
	gen_server:cast(list_to_atom(Name), {message, User_id, Msg}).

mode(Name, User_id) ->
	gen_server:cast(list_to_atom(Name), {mode, User_id}).

names(Name, User_id) ->
	gen_server:cast(list_to_atom(Name), {names, User_id}).

nick(Name, Msg) ->
	gen_server:cast(list_to_atom(Name), {nick, Msg}).

part(Name, User_id) ->
	gen_server:cast(list_to_atom(Name), {part, User_id}).

quit(Name, User_id, Nick, Host, Msg) ->
	gen_server:cast(list_to_atom(Name), {quit, User_id, Nick, Host, Msg}).

topic(Name, User_id) ->
	gen_server:cast(list_to_atom(Name), {topic, User_id}).

topic(Name, User_id, Topic) ->
	gen_server:cast(list_to_atom(Name), {topic, User_id, Topic}).


%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

%%-------------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, StopReason}
%% @private
%%-------------------------------------------------------------------------

init([Name]) ->
	process_flag(trap_exit, true),
	Users = ets:new(?MODULE, []),
	{ok,#state{name=Name, users=Users}}.

%%-------------------------------------------------------------------------
%% @spec (Request, From, State) -> {reply, Reply, State}          |
%%                                 {reply, Reply, State, Timeout} |
%%                                 {noreply, State}               |
%%                                 {noreply, State, Timeout}      |
%%                                 {stop, Reason, Reply, State}   |
%%                                 {stop, Reason, State}
%% @doc Callback for synchronous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------



handle_call(Request, _From, State) ->
	{stop, {unknown_call, Request}, State}.

%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for asyncrous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_cast({join, Pid}, #state{users=Users, name=Name, topic=Topic} = State)->
	case Topic of 
		{T,_} -> 
			client:reply(Pid, ["332 ", client:nick(Pid), " ",Name, " ", T]);
		_ -> none
	end,
	ets:insert(Users, {client:nick(Pid), Pid}),
	send(Users, Pid, [ "JOIN ", Name]),
	names(Name, Pid),
	{noreply, State};

handle_cast({message, Pid, Msg}, #state{users=Users} = State) ->
	sendrm(Users, Pid, Msg),
	{noreply, State};

handle_cast({mode, Pid}, #state{name=Name} = State)->
	client:reply(Pid, ["324 ", client:nick(Pid), " ", Name, " +nt"]),
	{noreply, State};

handle_cast({names, Pid}, #state{name=Name, users=Users} = State) ->
	client:reply(Pid, ["353 ", client:nick(Pid), " = ", Name, " :",
			string:substr(lists:foldl(fun({A, _}, AccIn) -> AccIn ++ " " ++ A end, " ", ets:tab2list(Users)), 3) ]),
	client:reply(Pid, ["366 ", client:nick(Pid), " ", Name, " :End of NAMES list"]),
	{noreply, State};

handle_cast({nick, Msg}, #state{users=Users} = State)->
	send(Users, Msg),
	{noreply, State};

handle_cast({part, Pid}, #state{name=Name, users=Users} = State) ->
	send(Users, Pid, ["PART ", Name]),
	ets:delete(Users, client:nick(Pid)),
	case ets:first(Users) of
		'$end_of_table' -> group_server:remove(Name),
			{stop, no_users_in_the_room, State};
		_ -> {noreply, State}
	end;

handle_cast({quit, _Pid, Nick, Host, Msg}, #state{name=Name, users=Users} = State) ->
	ets:delete(Users, Nick),
	send(Users, [":", Nick, "!", Host," QUIT ", Msg]),
	case ets:first(Users) of
		'$end_of_table' -> group_server:remove(Name),
			{stop, no_users_in_the_room, State};
		_ -> {noreply, State}
	end;

handle_cast({topic, Pid}, #state{name=Name, topic=Topic} = State)->
	Reply = case Topic of 
		{T,_} -> ["332 ", client:nick(Pid), " ", Name, " ", T];
		_ -> ["331 ", client:nick(Pid), " ",Name, " :No topic is set"]
	end,
	client:reply(Pid, Reply),
	{noreply, State};

handle_cast({topic, Pid, NTopic}, #state{name=Name, users=Users} = State) ->
	send(Users, Pid, ["TOPIC ", Name, " ", NTopic]),
	{noreply, State#state{topic={NTopic, client:nick(Pid)}}};

handle_cast({invite}, State) ->
	{noreply, State};

handle_cast({stop}, State) ->
	{stop, stop_was_called, State};

handle_cast(_Msg, State) ->
	{noreply, State}.

%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for messages sent directly to server's mailbox.
%%      If `{stop, ...}' tuple is returned, the server is stopped and
%%      `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_info(_Info, State) ->
	{noreply, State}.

%%-------------------------------------------------------------------------
%% @spec (Reason, State) -> any
%% @doc  Callback executed on server shutdown. It is only invoked if
%%       `process_flag(trap_exit, true)' is set by the server process.
%%       The return value is ignored.
%% @end
%% @private
%%-------------------------------------------------------------------------
terminate(_Reason, #state{users=Users, name=Name}) ->
	ets:delete(Users),
	io:format("Terminate chat group ~s~n", [Name]),
	ok.

%%-------------------------------------------------------------------------
%% @spec (OldVsn, State, Extra) -> {ok, NewState}
%% @doc  Convert process state when code is changed.
%% @end
%% @private
%%-------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.



%% Hidden functions



%%-------------------------------------------------------------------------
%% @spec (Users, Pid, Mesg) -> done
%% @doc  Send a message to all exept to Pid
%% @end
%% @private
%%-------------------------------------------------------------------------
sendrm(Users, Pid, Mesg) ->
	send(lists:keydelete(Pid, 2, ets:tab2list(Users)), [":", client:nick(Pid), "!", client:host_name(Pid), " ", Mesg]).


%%-------------------------------------------------------------------------
%% @spec (Users, Pid, Mesg) -> done
%% @doc  Send a message to all
%% @end
%% @private
%%-------------------------------------------------------------------------
send(Users, Pid, Mesg) ->
	send(ets:tab2list(Users), [":", client:nick(Pid), "!", client:host_name(Pid), " ", Mesg]).

send([], _Mesg) ->
	done;
send([{_,Pid}|Us], Mesg) ->
	client:msg_to(Pid, Mesg),
	send(Us, Mesg);
send(Users, Mesg) ->
	send(ets:tab2list(Users), Mesg).


