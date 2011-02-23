-module(client).
-author("Elias Johansson, eliasj@student.chalmers.se").

-behavior(gen_fsm).

%-import(group,[part/2])

%% API to the Interface
%-export([start/4, stop/1, nickC/2, join/2, part/2, quit/2, mode/2, msg_from/3,
%         whois/3, names/2, topic/2, topic/3]).

%% API to the server
%-export([nickS/1, host_name/1, msg_to/2, reply/2]).

-export([start_link/1, set_socket/2, msg_to/2, nick/1, host_name/1, reply/2]).

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
                host,      % server hostname
                socket,    % client socket
                addr,      % client address
                uname,     % client user name
                rname,     % client real name
                nick,      % client nickname
                chan=[]       % chat channels
               }).

-define(TIMEOUT, 120000).

%%%------------------------------------------------------------------------
%%% API
%%%------------------------------------------------------------------------

%%-------------------------------------------------------------------------
%% @spec (Socket) -> {ok,Pid} | ignore | {error,Error}
%% @doc To be called by the supervisor in order to start the server.
%%      If init/1 fails with Reason, the function returns {error,Reason}.
%%      If init/1 returns {stop,Reason} or ignore, the process is
%%      terminated and the function returns {error,Reason} or ignore,
%%      respectively.
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

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

%%-------------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}
%% @private
%%-------------------------------------------------------------------------
init([Host]) ->
    process_flag(trap_exit, true),
    {ok, wait_for_socket, #state{host=Host}}.

%%-------------------------------------------------------------------------
%% Func: StateName/2
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
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
    Pid = group_server:join(Chan),
    {next_state, chat, State#state{chan=[{Chan,Pid}|C]}};

chat({mode, Who, Mode}, #state{socket=S, nick=Who} = State) ->
	gen_tcp:send(S, [":", Who, " MODE ", Who, " :", Mode, "\r\n"]),
	{next_state, chat, State};

chat({mode, Chan}, #state{chan=C} = State) ->
	case lists:keysearch(Chan, 1, C) of
		{value, {Chan, Pid}} ->
			chat_group:mode(Pid, self());
		false ->
			error %% FIX better error message
	end,
	{next_state, chat, State};

chat({msg, Msg}, #state{socket=S} = State) ->
    gen_tcp:send(S, [ Msg, "\r\n"]),
    {next_state, chat, State};

chat({names, Chan}, #state{chan=C} = State) ->
    case lists:keysearch(Chan, 1, C) of
        {value, {Chan, Pid}} ->
            chat_group:names(Pid, self());
        false ->
            error_logger:error_msg("State: chat. Unexpected channel: ~p\n", [Chan])
    end,
    {next_state, chat, State};


chat({nick, Nick}, #state{nick=N, chan=C} = State) ->
    case client_server:nick(N, Nick) of
        ok ->
            lists:map(fun({_,Pid}) ->
                              chat_group:nick(Pid, [":", N, " NICK ", Nick]) end,
                      C),
            {next_state, chat, State#state{nick=Nick}};
        E -> 
            gen_fsm:send_event(self(), E),
            {next_state, chat, State}
    end;
        %%{user, Who, Name, Host}
chat({part, Chan}, #state{chan=C} = State) ->
    case lists:keytake(Chan, 1, C) of
        {value, {Chan, Pid}, NChans} -> 
            chat_group:part(Pid, self()),
            {next_state, chat, State#state{chan=NChans}};
        false -> 
            {next_state, chat, State}
    end;

chat({ping, Host}, #state{socket=S} = State) ->
    gen_tcp:send(S, ["PONG ", Host, "\r\n"]),
    {next_state, chat, State};

chat({privmsg, To, Msg}, #state{chan=C, nick=N, host=H} = State) ->
    case lists:keysearch(To, 1, C) of
        {value, {To, Pid}} ->
            chat_group:message(Pid, self(), Msg);
        false ->
            case client_server:id(To) of
                {ok, Pid} -> 
                    msg_to(Pid, [":", N, "!", H, " ",Msg]);
                E -> 
                    gen_fsm:send_event(self(), E)
            end
    end,
    {next_state, chat, State};

chat({quit, Reson},#state{chan=C, nick=N, host=H} = State) ->
    lists:foreach(fun({_,Pid}) ->
                          chat_group:quit(Pid, self(), N, H, Reson) end,
                  C),
    {next_state, close, State};

chat({rpl_msg, Msg}, #state{socket=S, host=H} = State) ->
    gen_tcp:send(S, [ ":", H, " ", Msg, "\r\n"]),
    {next_state, chat, State};

chat({send, Msg}, #state{socket=S} = State) ->
    gen_tcp:send(S, Msg),
    {next_state, chat, State};

chat({topic, Chan}, #state{chan=C} = State) ->
    case lists:keysearch(Chan, 1, C) of
        {value, {Chan, Pid}} ->
            chat_group:topic(Pid, self());
        false ->
            gen_fsm:send_event(self(), {error,["441 ", Chan, " :You're not on that channel"]})
    end,
    {next_state, chat, State};

chat({topic, Chan, Topic}, #state{chan=C} = State) ->
    case lists:keysearch(Chan, 1, C) of
        {value, {Chan, Pid}} ->
            chat_group:topic(Pid, self(), Topic);
        false ->
            gen_fsm:send_event(self(), {error,["441 ", Chan, " :You're not on that channel"]})
    end,
    {next_state, chat, State};
%        {whois, Who} ->



chat(Other, State) ->
    error_logger:error_msg("State: 'WAIT_FOR_SOCKET'. Unexpected message: ~p\n", [Other]),
    %% Allow to receive async messages
    {next_state, chat, State}.




%%-------------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%% @private
%%-------------------------------------------------------------------------
handle_event(Event, StateName, StateData) ->
    {stop, {StateName, undefined_event, Event}, StateData}.

%%-------------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%% @private
%%-------------------------------------------------------------------------
% TODO Add functions to recive data from the client
handle_sync_event(nick, _From, StateName, #state{nick=N} = State) ->
	{reply, N, StateName, State};
handle_sync_event(host, _From, StateName, #state{host=H} = State) ->
	{reply, H, StateName, State};
handle_sync_event(Event, _From, StateName, StateData) ->
    {stop, {StateName, undefined_event, Event}, StateData}.


%%-------------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
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
terminate(_Reason, _StateName, #state{socket=Socket}) ->
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
            case string:substr(Msg,1,3) of 
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
    lists:map(fun(I) ->  parser(I) end, Cmds2).

parser([D|Ds]) ->
    case D of 
        "JOIN" ->
            case Ds of
                [Chan] ->
                    {join, Chan};
                _ ->
                    {error, "461 JOIN :Not enough parameters"}
            end;
        "NAMES" ->
            [Chan] = Ds,
            {names, Chan};
        "NICK" -> 
            case Ds of
                [Who] ->
                    {nick, Who};
                _ -> 
                    {error, "461 NICK :Not enough parameters"}
            end;
        "MODE" ->
            case Ds of
                [Who, Mode|_] ->
                    {mode, Who, Mode};
                [Chan]->
                    {mode, Chan}
            end;
        "PART" ->
            case Ds of
                [Chan] ->
                    {part, Chan};
                _ ->
                    {error, "461 PART :Not enough parameters"}
            end;
        "PING" ->
            [Host] = Ds,
            {ping, Host};
        "PRIVMSG" -> 
            Mesg = space("PRIVMSG", Ds),
            case Ds of
                [To|_] ->
                    {privmsg, To, Mesg};
                [] -> 
                    {error, "461 PRIVMSG :Not enough parameters"}
            end;
        "QUIT" ->
            Mesg = string:substr(space(" ", Ds),3),
            {quit, Mesg};
        "TOPIC" ->
            case Ds of
                [Chan] -> 
                    {topic, Chan};
                [Chan |Topic] -> 
                    T = string:substr(space(" ", Topic),3),
                    {topic, Chan, T};
                _ ->
                    {error, "461 TOPIC :Not enough parameters"}
            end;
        "USER" ->
            case Ds of
                [Who, Host, _Server |Name] -> 
                    % <username> <hostname> <servername> <realname>
                    RName = string:substr(space(" ", Name),4),
                    {user, Who, RName, Host};
                _ ->
                    {error, "461 USER :Not enough parameters"}
            end;
        "WHOIS" ->
            [Who] = Ds,
            {whois, Who};
        _ ->
            {error, space(D,Ds)}
            
    end.

space(First, List) ->
    lists:foldl(
      fun(A, AccIn) -> AccIn ++ " " ++ A end, 
      First, List
               ).


%%% Old
% TODO Remove the old code
%%start(Nick, Name, Host, Interface) ->
%%     %%Do this with a erlang record instade?
%%     spawn(fun() -> loop(Name, Nick, Host, [], Interface) 
%%           end).
%% 
%% %% API to the Interface
%% 
%% %% @spec stop(pid()).
%% 
%% stop(Pid) ->
%%     Pid ! {stop}.
%% 
%% %% @spec nickC(pid(), string()).
%% nickC(Pid, Nick) ->
%%     Pid ! {nickC, Nick}.
%% 
%% %% @spec join(pid(), string()).
%% join(Pid, Chan) ->
%%     Pid ! {join, Chan}.
%% 
%% %% @spec part(pid(), string()).
%% part(Pid, Chan) ->
%%     Pid ! {part, Chan}.
%% 
%% mode(Pid, Chan) ->
%%     Pid ! {mode, Chan}.
%% 
%% %% @spec msg_from(pid(), string(), string()) .
%% msg_from(Pid, To, Msg) ->
%%     Pid ! {msg_from, To, Msg}.
%% 
%% %% @spec topic(pid(), string()).
%% topic(Pid, Chan) ->
%%     Pid ! {topic, Chan}.
%% 
%% %% @spec topic(pid(), string(), string()).
%% topic(Pid, Chan, Topic) ->
%%     Pid ! {topic, Chan, Topic}.
%% 
%% %% @spec quit(pid(), Reson).
%% quit(Pid, Reson) ->
%%     Pid ! {quit, Reson}.
%% 
%% %% @spec whois(pid(), pid()).
%% whois(Pid, From, Nick) ->
%%     Pid ! {whois, From, Nick}.
%% 
%% names(Pid, Chan) ->
%%     Pid ! {names, Chan}.
%% 
%% % API to the server
%% 
%% %% @spec nickS(pid()) -> string().
%% 
%% nickS(Pid) ->
%%     Pid ! {nickS, self()},
%%     receive
%%         {ok, Nick} ->
%%             Nick
%%     end.
%% 
%% %% @spec host_name(pid()) -> string().
%% host_name(Pid) ->
%%     Pid ! {host_name, self()},
%%     receive
%%         {ok, Host_name} ->
%%             Host_name
%%     end.
%% 
%% %msg_to(Pid, Msg) ->
%% %    Pid ! {msg_to, Msg}.
%% 
%% reply(Pid, Msg) ->
%%     Pid ! {reply, Msg}.
%% 
%% %% hidden functions
%% 
%% loop(Name, Nick, Host, Chans, Interface) ->
%%     receive
%%         {nickC, NewNick} ->
%%             case client_server:nick(Nick, NewNick) of
%%                 ok ->
%%                     lists:map(fun({_,Pid}) ->
%%                                       chat_group:nick(Pid, [":", Nick, " NICK ", NewNick]) end,
%%                               Chans),
%%                     loop(Name, NewNick, Host, Chans, Interface);
%%                 {error, Awnser} ->
%%                     reply(self(), Awnser),
%%                     loop(Name, Nick, Host, Chans, Interface)
%%             end;
%%         {join, Chan} ->
%%             Pid = group_server:join(Chan),
%%             loop(Name, Nick, Host, [{Chan, Pid}|Chans], Interface);
%%         {part, Chan} ->
%%             case lists:keytake(Chan, 1, Chans) of
%%                 {value, {Chan, Pid}, NChans} -> 
%%                     chat_group:part(Pid, self()),
%%                     loop(Name, Nick, Host, NChans, Interface);
%%                 false -> 
%%                     Interface ! {msg, error},%% Fix IRC error message
%%                     loop(Name, Nick, Host, Chans, Interface)
%%             end;
%%         {quit, Reson} ->
%%             lists:foreach(fun({_,Pid}) ->
%%                                   chat_group:quit(Pid, self(), Nick, Host, Reson) end,
%%                           Chans);
%%         {mode, Chan} ->
%%             case lists:keysearch(Chan, 1, Chans) of
%%                 {value, {Chan, Pid}} ->
%%                     chat_group:mode(Pid, self());
%%                 false ->
%%                     error
%%             end,
%%             loop(Name, Nick, Host, Chans, Interface);
%%         {msg_from, To, Msg} ->
%%             case lists:keysearch(To, 1, Chans) of
%%                 {value, {To, Pid}} ->
%%                     chat_group:message(Pid, self(), Msg);
%%                 false ->
%%                     case client_server:id(To) of
%%                         {ok, Pid} -> 
%%                             msg_to(Pid, [":", Nick, "!", Host, " ",Msg]);
%%                         {error, M} -> 
%%                             reply(self(), M)
%%                     end
%%             end,
%%             loop(Name, Nick, Host, Chans, Interface);
%%         {topic, Chan} ->
%%             case lists:keysearch(Chan, 1, Chans) of
%%                 {value, {Chan, Pid}} ->
%%                     chat_group:topic(Pid, self());
%%                 false ->
%%                     reply(self(), ["441 ", Chan, " :You're not on that channel"])
%%             end,
%%             loop(Name, Nick, Host, Chans, Interface);
%%         {topic, Chan, Topic} ->
%%             case lists:keysearch(Chan, 1, Chans) of
%%                 {value, {Chan, Pid}} ->
%%                     chat_group:topic(Pid, self(), Topic);
%%                 false ->
%%                     reply(self(), ["441 ", Chan, " :You're not on that channel"])
%%             end,
%%             loop(Name, Nick, Host, Chans, Interface);
%%         {whois, From, FNick} ->
%%             reply(From, ["311 ", FNick, " ", Nick, " some_shit ", Host, " * :", Name]),
%%             case Chans of
%%                 [] -> none;
%%                 _ ->
%%                     reply(From, ["319 ", FNick, " ", Nick, " :", 
%%                                  string:substr(lists:foldl(fun({A, _}, AccIn) -> AccIn ++ " " ++ A end, " ", Chans), 3)])
%%             end,
%%             reply(From, ["318 ", FNick, " ", Nick, " :End of /WHOIS list" ]),
%%             loop(Name, Nick, Host, Chans, Interface);
%%         {names, Chan} ->
%%             case lists:keysearch(Chan, 1, Chans) of
%%                 {value, {Chan, Pid}} ->
%%                     chat_group:names(Pid, self());
%%                 false ->
%%                     error
%%             end,
%%             loop(Name, Nick, Host, Chans, Interface);
%%         {nickS, Pid} ->
%%             Pid ! {ok, Nick},
%%             loop(Name, Nick, Host, Chans, Interface);
%%         {host_name, Pid} ->
%%             Pid ! {ok, Host},
%%             loop(Name, Nick, Host, Chans, Interface);
%%         {msg_to, Msg} ->
%%             Interface ! {msg, Msg},
%%             loop(Name, Nick, Host, Chans, Interface);
%%         {reply, Msg} ->
%%             Interface ! {rpl_msg, Msg},
%%             loop(Name, Nick, Host, Chans, Interface);
%%         {stop} ->
%%             lists:foreach(fun({_,Pid}) ->
%%                                   chat_group:part(Pid, self()) end,
%%                           Chans);
%%         {'EXIT', Interface, _Reson} ->
%%             stop(self());
%%         M -> io:format("get follow message:~n ~w~n", M)
%%     end.
