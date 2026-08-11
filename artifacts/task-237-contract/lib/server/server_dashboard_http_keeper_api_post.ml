Source: lib/server/server_dashboard_http_keeper_api_post.ml
Commit under test: 23662748a1

Bounded source excerpt (lines 44-66 and 97-122):

    44 let handle_keeper_github_login_post state req reqd =
    45   let req_path = Http.Request.path req in
    46   let name = extract_keeper_name_for_suffix req_path keeper_suffix_github_login in
    47   let config = Mcp_server.workspace_config state in
    48   if name = "" then respond_error reqd "keeper name is required"
    49   else
    50     match Keeper_meta_store.read_meta config name with
    51     | Error message -> respond_error ~status:`Internal_server_error reqd message
    52     | Ok None -> respond_error ~status:`Not_found reqd (...)
    53     | Ok (Some _) ->
    54       ...
    60       (match
    61          Keeper_github_identity.login_env
    62            ~base_path:config.base_path
    63            ~keeper_name:name
    64        with
    65        | Error message -> respond_error reqd message
    66        | Ok env ->

    97              let status, _, stderr =
    98                Process_eio.run_argv_with_status_split_streaming
    99                  ~env
   100                  ~on_stdout_chunk:(send_redacted_output "stdout" stdout_redaction)
   101                  ~on_stderr_chunk:(send_redacted_output "stderr" stderr_redaction)
   102                  (Keeper_github_identity.login_argv ~hostname)
   103              in
   108              | Unix.WEXITED 0 ->
   109                (match
   110                   Keeper_github_identity.secure_config_files
   111                     ~base_path:config.base_path
   112                     ~keeper_name:name
   113                 with
   114                 | Error message -> ...
   119                 | Ok () ->
   120                   (match
   121                      Keeper_github_identity.observe
   122                        ~base_path:config.base_path

API export and route evidence from the same commit:

lib/server/server_dashboard_http_keeper_api.mli:177-179
val handle_keeper_github_login_post :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit

lib/server/server_dashboard_http_keeper_api_post.mli:105-106
val handle_keeper_github_login_post :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit

lib/server/server_routes_http_routes_dashboard.ml:1851-1854
| Keeper_api.Keeper_post_github_login ->
    ...
    Keeper_api.handle_keeper_github_login_post state req reqd
