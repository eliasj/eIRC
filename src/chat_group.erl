-module(chat_group).
-author("Elias Johansson, eliasj@student.chalmers.se").

-behaviour(gen_server).

-export([start_link/2, stop/1, join/2, message/3, mode/2, mode/3, mode/4, names/2, nick/2, part/2, quit/5, topic/2, topic/3, who/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		terminate/2, code_change/3]).

-record(mode, {
		o=[],	% Channel operators
		p=false,% Private channel
		s=false,% Secret channel
		i=false,% Invite-only channel
		t,		% Topic settable by channel op
		n,		% No message from outside
		m=false,% Moderated channel
		l,		% The channel limit
		b=[],	% Ban mask to keep users out
		v=[],	% Can speak on a moderated channel
		k=[]	% The channel key (password)
	}).

-record(state, 	{
		name,		% name of the chat room
		topic=[], 	% topic in the chat room
		topic_time,	% the time topic was set
		topic_user,	% user who set the topic
		mode=#mode{n=true,t=true},		% mode on the chat room TODO
		users		% users in the chat room
	}).


%% API

start_link(Name, CPid) ->
	Pid = gen_server:start_link({local, list_to_atom(Name)}, ?MODULE, [Name], []),
	join(Name, CPid),
	Pid.

stop(Name) ->
	Name.

join(Name, UserPid) when is_pid(UserPid) ->
	gen_server:cast(list_to_atom(Name), {join, UserPid}).

message(Name, UserPid, Msg) when is_pid(UserPid) -> 
	gen_server:cast(list_to_atom(Name), {message, UserPid, Msg}).

mode(Name, UserPid) when is_pid(UserPid) ->
	gen_server:cast(list_to_atom(Name), {mode, UserPid}).

mode(Name, UserPid, Mode) when is_pid(UserPid) ->
	gen_server:cast(list_to_atom(Name), {mode, UserPid, Mode}).

mode(Name, UserPid, Mode, Param) when is_pid(UserPid) ->
	gen_server:cast(list_to_atom(Name), {mode, UserPid, Mode, Param}).

names(Name, UserPid) when is_pid(UserPid) -> 
	gen_server:cast(list_to_atom(Name), {names, UserPid}).

nick(Name, Msg) ->
	gen_server:cast(list_to_atom(Name), {nick, Msg}).

part(Name, UserPid) when is_pid(UserPid) ->
	gen_server:cast(list_to_atom(Name), {part, UserPid}).

quit(Name, UserPid, Nick, Host, Msg) when is_pid(UserPid) ->
	gen_server:cast(list_to_atom(Name), {quit, UserPid, Nick, Host, Msg}).

topic(Name, UserPid) when is_pid(UserPid) ->
	gen_server:cast(list_to_atom(Name), {topic, UserPid}).

topic(Name, UserPid, Topic) when is_pid(UserPid) ->
 	gen_server:cast(list_to_atom(Name), {topic, UserPid, Topic}).

who(Name, UserPid) when is_pid(UserPid) ->
	gen_server:cast(list_to_atom(Name),{who, UserPid}).

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
handle_cast({invite}, State) ->
	{noreply, State};

handle_cast({join, Pid}, #state{users=Users, mode=M, name=Name, topic=Topic} = State)->
	#mode{l=L} = M,
	{size, Size} = lists:keyfind(size, 1, ets:info(Users)),
	case (not is_number(L)) or (L>Size) of
		true ->
			case Topic of 
				{T,_} -> 
					client:reply(Pid, ["332 ", client:nick(Pid), " ",Name, " ", T]);
				_ -> none
			end,
			case ets:first(Users) of
				'$end_of_table' -> 
					NewMode = M#mode{o=[client:nick(Pid)]};
				_ -> 
					NewMode = M
			end,
			ets:insert(Users, {client:nick(Pid), Pid}),
			send(Users, Pid, [ "JOIN ", Name]),
			names(Name, Pid),
			{noreply, State#state{mode=NewMode}};
		false ->
			client:reply(Pid, ["471 ", Name, " :Cannot join channel (+l)"])
	end;

handle_cast({kick, _Pid, _Nick}, State) ->
	{noreply, State};

handle_cast({message, Pid, Msg}, #state{mode=Mode, name=Name, users=Users} = State) ->
	#mode{m=M, n=N, o=O, v=V} = Mode,
	Nick = client:nick(Pid),
	case (not (N or M)) or (N and ets:member(Users, Nick) and (not M)) or (M and (lists:member(Nick, O) or lists:member(Nick, V))) of
		true ->
			sendrm(Users, Pid, Msg);
		false ->
			client:reply(Pid, ["404 ", Name, " :Cannot send to channel"])
	end,
	{noreply, State};


handle_cast({mode, Pid}, #state{mode=Mode, name=Name} = State)->
	#mode{i=I, l=L, m=M, n=N, p=P, s=S, t=T} = Mode, %TODO should return the current chan mode
	Match = [{"i",I},{"l",L},{"m",M},{"n",N},{"p",P},{"s",S},{"t",T}],
	Reply = [X || {X, true} <- Match],
	client:reply(Pid, ["324 ", client:nick(Pid), " ", Name, " +", Reply]), % should retun the chan mode
	{noreply, State};

handle_cast({mode, Pid, "b"}, #state{name=Name, mode=M} = State) ->
	#mode{b=B} = M,
	lists:foreach(fun(X) -> client:reply(Pid, ["367 ", Name, " ", X]) end, B),
	client:reply(Pid, ["368 ", client:nick(Pid), " ", Name, " :End of channel ban list"]),
	{noreply, State};

handle_cast({mode, Pid, Mode}, #state{name=Name,mode=M,users=Users} = State) ->
	#mode{o=O} = M,
	case lists:member(client:nick(Pid), O) of
		true ->
			case Mode of
				[$+|ModeT] ->
					Status = true;
				[$-|ModeT] ->
					Status = false;
				Other1 ->
					error_logger:error_msg("Chat gruop: '~w'. Unexpected message: ~p\n", [Name,Other1]),
					ModeT = banMask,
					Status = crap
			end,
			case ModeT of 
				[$p] -> 
					send(Users, Pid, [ "MODE ", Name, " ", Mode]),
					{noreply, State#state{mode = M#mode{p=Status}}};
				[$i] ->
					send(Users, Pid, [ "MODE ", Name, " ", Mode]),
					{noreply, State#state{mode = M#mode{i=Status}}};
				[$t] ->
					send(Users, Pid, [ "MODE ", Name, " ", Mode]),
					{noreply, State#state{mode = M#mode{t=Status}}};
				[$n] ->
					send(Users, Pid, [ "MODE ", Name, " ", Mode]),
					{noreply, State#state{mode = M#mode{n=Status}}};
				[$m] ->
					send(Users, Pid, [ "MODE ", Name, " ", Mode]),
					{noreply, State#state{mode= M#mode{m=Status}}};
				Other2 ->
					error_logger:error_msg("Chat gruop: '~w'. Unexpected message: ~p\n", [Name,Other2]),
					{noreply, State} 
			end;
		false ->
			client:reply(Pid, ["482 ", Name, " :You're not channel operator"]),
			{noreply, State}
	end;

handle_cast({mode, Pid, Mode, Param}, #state{name=Name,mode=M,users=Users} = State) ->
	#mode{o=O} = M,
	case lists:member(client:nick(Pid), O) of
		true ->
			case Mode of
				[$+|ModeT] ->
					Status = true;
				[$-|ModeT] ->
					Status = false;
				Other1 ->
					error_logger:error_msg("Chat gruop: '~w'. Unexpected message: ~p\n", [Name,Other1]),
					ModeT = banMask,
					Status = crap
			end,
			case ModeT of 
				[$o] ->
					send(Users, Pid, [ "MODE ", Name, " ",  Mode, " ", Param]),
					#mode{o=O} = M,
					case Status of
						true ->
							{noreply, State#state{mode=M#mode{o=Param++O}}};
						false ->
							{noreply, State#state{mode=M#mode{o=lists:foldl(fun(U, AccIn) -> lists:delete(U, AccIn) end, O, Param)}}}
					end;
				[$l] ->
					send(Users, Pid, [ "MODE ", Name, " ",  Mode, " ", Param]),
					case Status and is_number(Param) of
						true ->
							{noreply, State#state{mode=M#mode{l=Param}}};
						false ->
							{noreply, State#state{mode=M#mode{l=undefind}}}
					end;

				[$b] ->
					send(Users, Pid, [ "MODE ", Name, " ",  Mode, " ", Param]),
					{noreply, State}; % TODO Handle the ban mask
				[$v] -> 
					send(Users, Pid, [ "MODE ", Name, " ",  Mode, " ", Param]),
					#mode{v=V} = M,
					case Status of
						true ->
							{noreply, State#state{mode=M#mode{v=Param++V}}};
						false -> 
							{noreply, State#state{mode=M#mode{v=lists:foldl(fun(U, AccIn) -> lists:delete(U, AccIn) end, V, Param)}}}
					end;
				[$k] ->
					send(Users, Pid, [ "MODE ", Name, " ",  Mode, " ", Param]),
					{noreply, State} % TODO Add/change the password to the channel
			end;
		false ->
			client:reply(Pid, ["482 ", Name, " :You're not channel operator"]),
			{noreply, State}
	end;

handle_cast({names, Pid}, #state{mode=Mode, name=Name, users=Users} = State) ->
	#mode{o=O, v=V} = Mode,
	client:reply(Pid, ["353 ", client:nick(Pid), " = ", Name, " :",
			string:substr(lists:foldl(fun({A, _}, AccIn) -> AccIn ++ name(A,O,V) end, " ", ets:tab2list(Users)), 3) ]),
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
			{stop, normal, State};
		_ -> {noreply, State}
	end;

handle_cast({quit, _Pid, Nick, Host, Msg}, #state{name=Name, users=Users} = State) ->
	ets:delete(Users, Nick),
	send(Users, [":", Nick, "!", Host," QUIT ", Msg]),
	case ets:first(Users) of
		'$end_of_table' -> group_server:remove(Name),
			{stop, normal, State};
		_ -> {noreply, State}
	end;

handle_cast({topic, Pid}, #state{name=Name, topic=Topic} = State)->
	Reply = case Topic of 
		{T,_} -> ["332 ", client:nick(Pid), " ", Name, " ", T];
		_ -> ["331 ", client:nick(Pid), " ",Name, " :No topic is set"]
	end,
	client:reply(Pid, Reply),
	{noreply, State};

handle_cast({topic, Pid, NTopic}, #state{mode=Mode, name=Name, users=Users} = State) ->
	#mode{t=T, o=O} = Mode,
	case (not T) or (T and lists:member(client:nick(Pid), O)) of
		true ->
			send(Users, Pid, ["TOPIC ", Name, " ", NTopic]),
			{noreply, State#state{topic={NTopic, client:nick(Pid)}}};
		false ->
			client:reply(Pid, ["482 ", Name, " :You're not channel operator"]),
			{noreply, State}
	end;

handle_cast({stop}, State) ->
	{stop, normal, State};

handle_cast({who,Pid}, #state{name=Name,users=Users} = State) ->
	Nick = client:nick(Pid),
	lists:foreach(fun({_,A}) -> client:reply(Pid, ["352 ", Nick, " ", Name , " ", client:who(A)]) end, ets:tab2list(Users)),
	client:reply(Pid, ["315 ", Nick, " ", Name, " :End of WHO list"]),
	{noreply, State};

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
	group_server:remove(Name),
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

%%-------------------------------------------------------------------------
%% @spec (Name, Op, Voice) -> Name
%% @doc  Return operation status + name
%% @end
%% @private
%%-------------------------------------------------------------------------

name(Name, O, V) ->
	case lists:member(Name, O) of
		true -> Op = "@";
		false -> Op = ""
	end,
	case lists:member(Name, V) of
		true -> Vo = "+";
		false -> Vo = ""
	end,
	" " ++ Vo ++ Op ++ Name.

