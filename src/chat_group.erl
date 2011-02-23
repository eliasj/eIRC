-module(chat_group).
-author("Elias Johansson, eliasj@student.chalmers.se").

-export([start_link/2, stop/1, join/2, message/3, mode/2, names/2, nick/2, part/2, quit/5, topic/2, topic/3]).

%% TODO rewrite as a gen_server

%% API

start_link(Name, Pid) ->
    SPid = spawn_link(fun() -> start_up(Name, Pid) end),
	{ok, SPid}.

start_up(Name, Pid) ->
	process_flag(trap_exit, true),
    Users = ets:new(?MODULE, []),
    join(self(), Pid),
    loop(Name, Users, [], []).

stop(Pid) ->
    Pid ! {stop}.

join(Group_id, User_id) ->
    Group_id ! {join, User_id}.

message(Group_id, User_id, Msg) ->
    Group_id ! {message, User_id, Msg}.

mode(Group_id, User_id) ->
    Group_id !{mode, User_id}.

names(Group_id, User_id) ->
    Group_id ! {names, User_id}.

nick(Group_id, Msg) ->
    Group_id ! {nick, Msg}.

part(Group_id, User_id) ->
    Group_id ! {part, User_id}.

quit(Group_id, User_id, Nick, Host, Msg) ->
    Group_id ! {quit, User_id, Nick, Host, Msg}.

topic(Group_id, User_id) ->
    Group_id ! {topic, User_id}.

topic(Group_id, User_id, Topic) ->
    Group_id ! {topic, User_id, Topic}.

%% Hidden functions


loop(Name, Users, Topic, Mode) ->
    receive
        {join, Pid} ->
            Reply = case Topic of 
                        {T,_} -> ["332 ", client:nick(Pid), " ",Name, " ", T];
                        _ -> ["331 ", client:nick(Pid), " ",Name, " :No topic is set"]
                    end,
            client:reply(Pid, Reply),
            ets:insert(Users, {client:nick(Pid), Pid}),
            send(Users, Pid, [ "JOIN ", Name]),
            names(self(), Pid),
            loop(Name, Users, Topic, Mode);			
        
        
        {message, Pid, Msg} ->
            sendrm(Users, Pid, Msg),
            loop(Name, Users, Topic, Mode);
        {mode, Pid} ->
            client:reply(Pid, ["324 ", client:nick(Pid), " ", Name, " +nt"]),
            loop(Name, Users, Topic, Mode);
        {names, Pid} ->
            client:reply(Pid, ["353 ", client:nick(Pid), " = ", Name, " :",
                               string:substr(lists:foldl(fun({A, _}, AccIn) -> AccIn ++ " " ++ A end, " ", ets:tab2list(Users)), 3) ]),
            client:reply(Pid, ["366 ", client:nick(Pid), " ", Name, " :End of NAMES list"]),
            loop(Name, Users, Topic, Mode); 
        {nick, Msg}->
            send(Users, Msg),
            loop(Name, Users, Topic, Mode);
        {part, Pid} ->
            send(Users, Pid, ["PART ", Name]),
            ets:delete(Users, client:nick(Pid)),
            case ets:first(Users) of
                '$end_of_table' -> group_server:remove(Name);
                _ -> loop(Name, Users, Topic, Mode)
            end;
        {quit, _Pid, Nick, Host, Msg} ->
            ets:delete(Users, Nick),
            send(Users, [":", Nick, "!", Host," QUIT ", Msg]),
            case ets:first(Users) of
                '$end_of_table' -> group_server:remove(Name);
                _ -> loop(Name, Users, Topic, Mode)
            end;
        {topic, Pid} ->
            Reply = case Topic of 
                        {T,_} -> ["332 ", client:nick(Pid), " ", Name, " ", T];
                        _ -> ["331 ", client:nick(Pid), " ",Name, " :No topic is set"]
                    end,
            client:reply(Pid, Reply),
            loop(Name, Users, Topic, Mode);
        {topic, Pid, NTopic} ->
            send(Users, Pid, ["TOPIC ", Name, " ", NTopic]),
            loop(Name, Users, {NTopic, client:nick(Pid)}, Mode);
        {invite} ->
            loop(Name, Users, Topic, Mode);
        {stop} ->
            ets:delete(Users);
        _ ->
            loop(Name, Users, Topic, Mode)
    end.


sendrm(Users, Pid, Mesg) ->
    send(lists:keydelete(Pid, 2, ets:tab2list(Users)), [":", client:nick(Pid), "!", client:host_name(Pid), " ", Mesg]).

send(Users, Pid, Mesg) ->
    send(ets:tab2list(Users), [":", client:nick(Pid), "!", client:host_name(Pid), " ", Mesg]).

send([], _Mesg) ->
    done;
send([{_,Pid}|Us], Mesg) ->
    client:msg_to(Pid, Mesg),
    send(Us, Mesg);
send(Users, Mesg) ->
    send(ets:tab2list(Users), Mesg).


