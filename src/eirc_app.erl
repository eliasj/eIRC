-module(eirc_app).
-author("Elias Johansson, eliasj@student.chalmers.se").

-behaviour(application).

%% Internal API
-export([start_client/0,start_group/2]).

%% Application and Supervisor callbacks
-export([start/2, stop/1, init/1]).

-define(MAX_RESTART, 5).
-define(MAX_TIME, 60).
-define(DEF_PORT, 6667).
-define(HOST, "localhost").


%% A startup function for spawning new client connection handling FSM
%% To be called by the TCP listenser process

start_client() ->
	supervisor:start_child(client_sup, [?HOST]).

start_group(Chan, CPid) ->
	supervisor:start_child(group_sup, [Chan, CPid]).

%%---------------------------------------------------------------------------
%% Application behaviour callbacks
%%---------------------------------------------------------------------------
start(_Type, _Args) ->
	ListenPort = get_app_env(listen_port, ?DEF_PORT),
	supervisor:start_link({local, ?MODULE}, ?MODULE, [ListenPort, client]).

stop(_State) ->
	ok.

%%---------------------------------------------------------------------------
%% Supervisor behaviour callbacks
%%---------------------------------------------------------------------------

init([Port, Module]) ->
	{ok, 
		{_SupFlags = {one_for_one, ?MAX_RESTART, ?MAX_TIME},
			[
				% TCP Listner
				{	tcp_listner,
					{tcp_listner, start_link,[Port,Module]},
					permanent,
					2000,
					worker,
					[tcp_listener]
				},
				% Client instans supervisor
				{	client_sup,
					{supervisor, start_link,[{local, client_sup}, ?MODULE, [Module]]},
					permanent,
					infinity,
					supervisor,
					[]
				},
				% Group instans supervisor
				{	group_sup,
					{supervisor, start_link,[{local, group_sup}, ?MODULE, [chat_group]]},
					permanent,
					infinity,
					supervisor,
					[]
				},
				% Client server
				{	client_server,
					{client_server, start, []},
					permanent,
					2000,
					worker,
					[client_server]
				},
				% Group server
				{	group_server,
					{group_server, start,[]},
					permanent,
					2000,
					worker,
					[group_server]
				}
			]
		}
	};

init([Module]) ->
	{ok,
		{_SupFlags = {simple_one_for_one, ?MAX_RESTART, ?MAX_TIME},
			[
			  % TCP Client
				{	undefined,							% Id	   = internal id
					{Module,start_link,[]},				% StartFun = {M, F, A}
					temporary,							% Restart  = permanent | transient | temporary
					2000,								% Shutdown = brutal_kill | int() >= 0 | infinity
					worker,								% Type	   = worker | supervisor
					[]									% Modules  = [Module] | dynamic
				}
			]
		}
	}.

%%----------------------------------------------------------------------
%% Internal functions
%%----------------------------------------------------------------------
get_app_env(Opt, Default) ->
	case application:get_env(application:get_application(), Opt) of
	{ok, Val} -> Val;
	_ ->
		case init:get_argument(Opt) of
		[[Val | _]] -> Val;
		error	   -> Default
		end
	end.

