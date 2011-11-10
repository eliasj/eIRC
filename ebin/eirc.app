{application, eirc,
 [
  {description, "eIRC"},
  {vsn, "0.0.33"},
  {id, "eirc"},
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
