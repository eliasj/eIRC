{application, tcp_server,
 [
  {description, "eIRC"},
  {vsn, "0.1"},
  {id, "tcp_server"},
  {modules,      [tcp_listener, chat_group, client_server, client,
  				group_server]},
  {registered,   [tcp_server_sup, tcp_listener]},
  {applications, [kernel, stdlib]},
  %%
  %% mod: Specify the module name to start the application, plus args
  %%
  {mod, {eirc_app, []}},
  {env, []}
 ]
}.