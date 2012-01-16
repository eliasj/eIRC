-module(client).
-author("Elias Johansson, eliasj@student.chalmers.se").

-behavior(gen_fsm).

%-import(list,[split/2]).

%% API to the Interface
%-export([start/4, stop/1, nickC/2, join/2, part/2, quit/2, mode/2, msg_from/3,
%		 whois/3, names/2, topic/2, topic/3]).

%% API to the server
%-export([nickS/1, host_name/1, msg_to/2, reply/2]).

-export([start_link/1, set_socket/2, msg_to/2, nick/1, host_name/1, reply/2, who/1]).

%% gen_fsm callbacks
-export([init/1, handle_event/3,
		 handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

%% FSM States
-export([
		 wait_for_socket/2,
		 connect/2,
		 chat/2
		]).

-record(state, {
				host,		% server hostname
				socket,		% client socket
				addr,		% client address
				uname,		% client user name
				rname,		% client real name
				nick,		% client nickname
				chan=[]		% chat channels
				 }).

-define(TIMEOUT, 120000).

%%%------------------------------------------------------------------------
%%% API
%%%------------------------------------------------------------------------

%%-------------------------------------------------------------------------
%% @spec (Socket) -> {ok,Pid} | ignore | {error,Error}
%% @doc To be called by the supervisor in order to start the server.
%%		If init/1 fails with Reason, the function returns {error,Reason}.
%%		If init/1 returns {stop,Reason} or ignore, the process is
%%		terminated and the function returns {error,Reason} or ignore,
%%		respectively.
%% @end
%%-------------------------------------------------------------------------
start_link(Arg) ->
	gen_fsm:start_link(?MODULE, [Arg], []).

set_socket(Pid, Socket) when is_pid(Pid), is_port(Socket) ->
	gen_fsm:send_event(Pid, {socket_ready, Socket}).

msg_to(Pid, Msg) when is_pid(Pid) ->
	gen_fsm:send_event(Pid, {msg, Msg}).

reply(Pid, Msg) when is_pid(Pid) ->
	gen_fsm:send_event(Pid, {rpl_msg, Msg}).

nick(Pid) when is_pid(Pid) ->
	gen_fsm:sync_send_all_state_event(Pid, nick).

host_name(Pid) when is_pid(Pid) ->
	gen_fsm:sync_send_all_state_event(Pid, host).

error(Msg) ->
	gen_fsm:send_event(self(), {rpl_msg, Msg}).

who(Pid) when is_pid(Pid) ->
	gen_fsm:sync_send_all_state_event(Pid, who).


whois(Pid, FPid, FNick) when is_pid(Pid) and is_pid(FPid) ->
	gen_fsm:send_event(Pid, {whois, FPid, FNick}).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

%%-------------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}			|
%%			{ok, StateName, StateData, Timeout} |
%%			ignore								|
%%			{stop, StopReason}
%% @private
%%-------------------------------------------------------------------------
init([Host]) ->
	process_flag(trap_exit, true),
	{ok, wait_for_socket, #state{host=Host}}.

%%-------------------------------------------------------------------------
%% Func: StateName/2
%% Returns: {next_state, NextStateName, NextStateData}			|
%%			{next_state, NextStateName, NextStateData, Timeout} |
%%			{stop, Reason, NewStateData}
%% @private
%%-------------------------------------------------------------------------

wait_for_socket({socket_ready, Socket}, State) when is_port(Socket) ->
	% Now we own the socket
	inet:setopts(Socket, [{active, once}]),
	gen_tcp:send(
		Socket,
		"NOTICE AUTH :*** Prosessing connection to " ++ 
			State#state.host ++ "\r\n"
				),
	{ok, {IP, _Port}} = inet:peername(Socket),
	{next_state, connect, State#state{socket=Socket, addr=IP}, ?TIMEOUT};

wait_for_socket(Other, State) ->
	error_logger:error_msg("State: 'WAIT_FOR_SOCKET'. Unexpected message: ~p\n", [Other]),
	%% Allow to receive async messages
	{next_state, wait_for_socket, State}.


connect({user, Who, RName, _Host}, #state{socket=S, nick=N} = State)->
	gen_tcp:send(
		S,
		"NOTICE AUTH :*** Checking your identy\r\n"
				),
	case N of
		undefined ->
			{next_state, connect, State#state{rname=RName,uname=Who}};
		_ -> 
			register(State#state{rname=RName,uname=Who})
	end;

connect({nick, Nick}, #state{uname=U} = State) ->
	case U of
		undefined ->
			{next_state, connect, State#state{nick=Nick}};
		_ -> 
			register(State#state{nick=Nick})
	end;

connect(Other, State) ->
	error_logger:error_msg("State: 'WAIT_FOR_SOCKET'. Unexpected message: ~p\n", [Other]),
	%% Allow to receive async messages
	{next_state, connect, State}.


chat({error, Msg}, #state{socket=S, host=H} = State) ->
	gen_tcp:send(S, [":", H, " ", Msg, "\r\n"]),
	{next_state, chat, State};

chat({join, Chan}, #state{chan=C} = State) ->
		group_server:join(Chan),
		{next_state, chat, State#state{chan=[Chan|C]}};

chat({mode, Who, Mode}, #state{socket=S, nick=Who} = State) ->
		gen_tcp:send(S, [":", Who, " MODE ", Who, " :", Mode, "\r\n"]),
		{next_state, chat, State};

chat({mode, Chan}, #state{chan=C} = State) ->
		case lists:member(Chan, C) of
			true ->
					chat_group:mode(Chan, self());
			false ->
			error(["442 ", Chan, " :You're not on that channel"])
	end,
	{next_state, chat, State};

chat({mode, Chan, Mode}, #state{chan=C} = State) ->
		case lists:member(Chan, C) of
			true ->
					chat_group:mode(Chan, self(), Mode);
			false ->
			error(["442 ", Chan, " :You're not on that channel"])
	end,
	{next_state, chat, State};

chat({mode, Chan, Mode, Param}, #state{chan=C} = State) ->
		case lists:member(Chan, C) of
			true ->
					chat_group:mode(Chan, self(), Mode, Param);
			false ->
			error(["442 ", Chan, " :You're not on that channel"])
	end,
	{next_state, chat, State};

chat({msg, Msg}, #state{socket=S} = State) ->
	gen_tcp:send(S, [ Msg, "\r\n"]),
	{next_state, chat, State};

chat({names, Chan}, #state{chan=C} = State) ->
	case lists:member(Chan, C) of
		true ->
			chat_group:names(Chan, self());
		false ->
			error_logger:error_msg("State: chat. Unexpected channel: ~p\n", [Chan])
			%% TODO Add so it can list more then channels
	end,
	{next_state, chat, State};

chat({nick, Nick}, #state{nick=N, chan=C} = State) ->
	case client_server:nick(N, Nick) of
		ok ->
			lists:map(fun(Chan) ->
								chat_group:nick(Chan, [":", N, " NICK ", Nick]) end,
						C),
			{next_state, chat, State#state{nick=Nick}};
		E -> 
			gen_fsm:send_event(self(), E),
			{next_state, chat, State}
	end;
		%%{user, Who, Name, Host}
chat({part, Chan}, #state{chan=C} = State) ->
	case lists:member(Chan, C) of
		true ->
				NChans = lists:delete(Chan, C),	
			chat_group:part(Chan, self()),
			{next_state, chat, State#state{chan=NChans}};
		false ->
			error(["442 ", Chan, " :You're not on that channel"]),
			{next_state, chat, State}
	end;

chat({ping, Host}, #state{socket=S} = State) ->
	gen_tcp:send(S, ["PONG ", Host, "\r\n"]),
	{next_state, chat, State};

chat({privmsg, To, Msg}, #state{chan=C, nick=N, host=H} = State) ->
	case lists:member(To, C) of
		true ->
			chat_group:message(To, self(), Msg);
		false ->
			case client_server:id(To) of
				{ok, Pid} -> 
					msg_to(Pid, [":", N, "!", H, " ",Msg]);
				E -> 
					gen_fsm:send_event(self(), E)
			end
	end,
	{next_state, chat, State};

chat({quit, Reson}, #state{chan=C, nick=N, host=H} = State) ->
	lists:foreach(fun(Chan) ->
							chat_group:quit(Chan, self(), N, H, Reson) end,
					C),
	{stop, normal, State};

chat({rpl_msg, Msg}, #state{socket=S, host=H} = State) ->
	gen_tcp:send(S, [ ":", H, " ", Msg, "\r\n"]),
	{next_state, chat, State};

chat({send, Msg}, #state{socket=S} = State) ->
	gen_tcp:send(S, Msg),
	{next_state, chat, State};

chat({topic, Chan}, #state{chan=C} = State) ->
	case lists:member(Chan, C) of
		true ->
			chat_group:topic(Chan, self());
		false ->
			error(["442 ", Chan, " :You're not on that channel"])
	end,
	{next_state, chat, State};

chat({topic, Chan, Topic}, #state{chan=C} = State) ->
	case lists:member(Chan, C) of
		true ->
			chat_group:topic(Chan, self(), Topic);
		false ->
			error(["442 ", Chan, " :You're not on that channel"])
	end,
	{next_state, chat, State};

chat({who, Who}, #state{chan=_C} = State)->
	chat_group:who(Who, self()),
	{next_state, chat, State};

chat({whois, Who}, #state{nick=N} = State) ->
	case client_server:whois(Who) of
		{ok, {Who, Wid}} ->
			whois(Wid, self(), N);
		_ ->
			error(["401 ", N, " " , Who, " :No such nick/channel\r\n"])
		end,
	{next_state, chat, State};

chat({whois, From, FNick}, #state{chan=C, host=H, nick=N, rname=R, uname=U} = State) ->
	reply(From, ["311 ", FNick, " ", N, " ", U, " ", H, " * :", R]),
	case C of
		[] -> none;
		_ ->
			reply(From, ["319 ", FNick, " ", N, " :",
				string:substr(lists:foldl(fun(A, AccIn) -> AccIn ++ " " ++ A end, " ", C), 3)])
	end,
	reply(From, ["318 ", FNick, " ", N, " :End of /WHOIS list" ]),
	{next_state, chat, State};

chat(Other, State) ->
	error_logger:error_msg("State: 'CHAT'. Unexpected message: ~p\n", [Other]),
	%% Allow to receive async messages
	{next_state, chat, State}.




%%-------------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}			|
%%			{next_state, NextStateName, NextStateData, Timeout}	|
%%			{stop, Reason, NewStateData}
%% @private
%%-------------------------------------------------------------------------
handle_event(Event, StateName, StateData) ->
	{stop, {StateName, undefined_event, Event}, StateData}.

%%-------------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}				|
%%			{next_state, NextStateName, NextStateData, Timeout}		|
%%			{reply, Reply, NextStateName, NextStateData}			|
%%			{reply, Reply, NextStateName, NextStateData, Timeout}	|
%%			{stop, Reason, NewStateData}							|
%%			{stop, Reason, Reply, NewStateData}
%% @private
%%-------------------------------------------------------------------------
% TODO Add functions to recive data from the client
handle_sync_event(nick, _From, StateName, #state{nick=N} = State) ->
	{reply, N, StateName, State};

handle_sync_event(host, _From, StateName, #state{host=H} = State) ->
	{reply, H, StateName, State};

handle_sync_event(who, _From, StateName, #state{host=H, nick=N, rname=R, uname=U} = State) ->
	Reply = [U, " ", H, " locahost ", N ," H :0 ", R],
	{reply, Reply, StateName, State};
% <channel> <user> <host> <server> <nick> <H|G>[*][@|+] :<hopcount> <real name>"
handle_sync_event(Event, _From, StateName, StateData) ->
	{stop, {StateName, undefined_event, Event}, StateData}.


%%-------------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}			|
%%			{next_state, NextStateName, NextStateData, Timeout} |
%%			{stop, Reason, NewStateData}
%% @private
%%-------------------------------------------------------------------------

handle_info({tcp, Socket, Bin}, StateName, #state{socket=Socket} = StateData) ->
	inet:setopts(Socket, [{active, once}]),
	[Cmd] = parse(Bin),
	?MODULE:StateName(Cmd, StateData);

handle_info({tcp_closed, Socket}, _StateName,
			#state{socket=Socket, addr=Addr} = StateData) ->
	error_logger:info_msg("~p Client ~p disconnected.\n", [self(), Addr]),
	{stop, normal, StateData};

handle_info(_Info, StateName, StateData) ->
	{noreply, StateName, StateData}.

%%-------------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%% @private
%%-------------------------------------------------------------------------
terminate(_Reason, _StateName, #state{nick=Nick, socket=Socket}) ->
	(catch client_server:leave(Nick)),
	(catch gen_tcp:close(Socket)),
	ok.

%%-------------------------------------------------------------------------
%% Func: code_change/4
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState, NewStateData}
%% @private
%%-------------------------------------------------------------------------
code_change(_OldVsn, StateName, StateData, _Extra) ->
	{ok, StateName, StateData}.



%% Private functions
register(State) ->
	case client_server:registation(State#state.nick) of
		ok -> 
			inet:setopts(State#state.socket, [{active, once}]),
			gen_tcp:send(
				State#state.socket,
				[":", State#state.host, " 001 ", State#state.nick, " :Welcome to the Internet Relay Chat Network ", State#state.nick, "\r\n",
				 ":", State#state.host, " 002 ", State#state.nick, " :Your host is ", State#state.host, ", running version eIRC-0.0.1\r\n",
				 ":", State#state.host, " 003 ", State#state.nick, " :This server was created ...\r\n",
				 ":", State#state.host, " 004 ", State#state.nick, " ", State#state.host, " eIRC-0.0.1 DOQRSZaghilopswz CFILMPQbcefgijklmnopqrstvz bkloveqjfI\r\n"]
						),
			gen_tcp:send(
				State#state.socket,
				"NOTICE AUTH :*** Ident Okay\r\n"
						),
			{next_state, chat, State};
		{error, Msg} ->
			gen_tcp:send(State#state.socket, [":", State#state.host, " ", Msg, "\r\n"]),
			case lists:nth(1,Msg) of 
				"433" ->
					{next_state, connect, State};
				Error -> io:format("Receive nick ~p~n", [Error])
			end 
	end.


parse(Cmds) ->
	%io:format("Comands ~n ~w~n", Cmds),
	Cmds1 = string:tokens(Cmds, "\r\n"),
	%io:format("Comands ~n ~w~n", Cmds1),
	Cmds2 = lists:map(fun(I) -> string:tokens(I, " ") end, Cmds1),
	%io:format("Comands ~n ~w~n", Cmds2),
	lists:map(fun(I) ->	parser(I) end, Cmds2).

parser(["JOIN"]) ->
	{rpl_msg, "461 JOIN :Not enough parameters"};
parser(["JOIN"|Ds]) ->
	[Chan] = Ds,
	{join, Chan};

parser(["NAMES"|Ds]) ->
	[Chan] = Ds,
	{names, Chan};

parser(["NICK"]) ->
	{rpl_msg, "461 NICK :Not enough parameters"};
parser(["NICK"|Ds]) -> 
	[Who] = Ds,
	{nick, Who};

parser(["MODE", Chan, Mode]) ->
	{mode, Chan, Mode};
parser(["MODE", Chan, Mode|Users]) ->
	{mode, Chan, Mode, Users};
parser(["MODE", Chan])->
	{mode, Chan};

parser(["PART"]) ->
	{rpl_msg, "461 PART :Not enough parameters"};
parser(["PART", Chan]) ->
	{part, Chan};

parser(["PING", Host]) ->
	{ping, Host};

parser(["PRIVMSG"]) ->
	{rpl_msg, "461 PRIVMSG :Not enough parameters"};
parser(["PRIVMSG",To|Msg]) -> 
	Mesg = space("PRIVMSG", [To|Msg]),
	{privmsg, To, Mesg};

parser(["QUIT"|Ds]) ->
	Mesg = string:substr(space(" ", Ds),3),
	{quit, Mesg};

parser(["TOPIC"]) ->
	{rpl_msg, "461 TOPIC :Not enough parameters"};
parser(["TOPIC", Chan]) ->
	{topic, Chan};
parser(["TOPIC", Chan |Topic]) ->
	T = string:substr(space(" ", Topic),3),
	{topic, Chan, T};

parser(["USER", Who, Host, _Server |Name]) -> 
	% <username> <hostname> <servername> <realname>
	RName = string:substr(space(" ", Name),4),
	{user, Who, RName, Host};
parser(["USER"|_]) ->
	{rpl_msg, "461 USER :Not enough parameters"};

parser(["WHOIS"]) ->
	{rpl_msg, "431 : No nickname given"};
parser(["WHOIS", Who]) -> 
	{whois, Who};
parser(["WHOIS", Who, Who]) -> 
	{whois, Who};

parser(["WHO"])->
	{rpl_msg, "402 <server name> :No such server"};
parser(["WHO", Who]) ->
	{who, Who};

parser([D|Ds]) ->
	{rpl_msg, space(D,Ds)}.

space(First, List) ->
	lists:foldl(
		fun(A, AccIn) -> AccIn ++ " " ++ A end, 
		First, List
				 ).


