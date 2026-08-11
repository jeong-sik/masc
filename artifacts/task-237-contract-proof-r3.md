# task-237 verification proof (exact bounded source and build evidence)

Task contract evidence:

- artifact:lib/dune shows the Keeper_github_identity module is included in the built library
- artifact:lib/server/server_dashboard_http_keeper_api_post.ml shows handle_keeper_github_login_post is exported to the API module
- artifact:bin/main_eio.ml shows the exact CLI call compiles against the library

Producer revision: branch sangsu/task-237-github-identity-build, current source revision after the evidence-file rename.

## 1. Library module inclusion

Source: lib/dune, lines 1-8

    1 (include_subdirs unqualified)
    2 (library
    3  (name masc)
    4  (flags :standard)
    5  (modules
    6   (:standard
    7    keeper_github_identity))
    8  (public_name masc)

The explicit modules stanza includes keeper_github_identity in the masc library while retaining :standard.

Generated module evidence from the successful build:

    _build-task237-explicit/default/lib/masc.ml-gen:483-484:
    module Keeper_github_identity = Masc__Keeper_github_identity

## 2. Server API handler, export, and route

Source: lib/server/server_dashboard_http_keeper_api_post.ml, lines 44-66 and 97-135

    44 let handle_keeper_github_login_post state req reqd =
    45   let req_path = Http.Request.path req in
    46   let name = extract_keeper_name_for_suffix req_path keeper_suffix_github_login in
    47   let config = Mcp_server.workspace_config state in
    48   if name = "" then respond_error reqd "keeper name is required"
    49   else
    50     match Keeper_meta_store.read_meta config name with
    51     | Error message -> respond_error ~status:`Internal_server_error reqd message
    52     | Ok None ->
    53       respond_error ~status:`Not_found reqd (Printf.sprintf "keeper %S not found" name)
    54     | Ok (Some _) ->
    55       let hostname =
    56         match Server_utils.query_param req "hostname" with
    57         | Some hostname -> hostname
    58         | None -> "github.com"
    59       in
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
    104              finish_redacted_output "stdout" stdout_redaction;
    105              finish_redacted_output "stderr" stderr_redaction;
    106              let stderr = Keeper_secret_redaction.redact_text redaction stderr in
    107              match status with
    108              | Unix.WEXITED 0 ->
    109                (match
    110                   Keeper_github_identity.secure_config_files
    111                     ~base_path:config.base_path
    112                     ~keeper_name:name
    113                 with
    114                 | Error message ->
    115                   github_login_stream_send
    116                     writer
    117                     "error"
    118                     (`Assoc [ "message", `String message ])
    119                 | Ok () ->
    120                   (match
    121                      Keeper_github_identity.observe
    122                        ~base_path:config.base_path
    123                        ~keeper_name:name
    124                        ~hostname
    125                    with
    126                    | Ok observation ->
    127                      github_login_stream_send
    128                        writer
    129                        "complete"
    130                        (`Assoc
    131                           [ ( "observation"
    132                             , Keeper_github_identity.observation_to_yojson
    133                                 observation )
    134                           ])

Public export: lib/server/server_dashboard_http_keeper_api.mli, lines 177-179

    177 val handle_keeper_github_login_post :
    178   Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
    179 (** Stream an isolated GitHub CLI login for the selected keeper. *)

Public post-module export: lib/server/server_dashboard_http_keeper_api_post.mli, lines 105-106

    105 val handle_keeper_github_login_post :
    106   Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit

Authenticated route call: lib/server/server_routes_http_routes_dashboard.ml, lines 1851-1855

    1851       | Keeper_api.Keeper_post_github_login ->
    1852           with_token_permission_auth ~permission:Masc_domain.CanAdmin
    1853             (fun state _agent_name req reqd ->
    1854               Keeper_api.handle_keeper_github_login_post state req reqd)
    1855             request reqd

## 3. CLI/library integration

Source: bin/main_eio.ml, lines 23 and 1200-1221

    23 module Keeper_github_identity = Masc.Keeper_github_identity

    1200 let keeper_github_cmd =
    1201   let login =
    1202     keeper_github_action_cmd
    1203       "login"
    1204       "Log a Keeper into GitHub CLI."
    1205       Keeper_github_identity.run_cli_login
    1206   in
    1207   let status =
    1208     keeper_github_action_cmd
    1209       "status"
    1210       "Observe stored and effective Keeper GitHub identities."
    1211       Keeper_github_identity.run_cli_status
    1212   in
    1213   let logout =
    1214     keeper_github_action_cmd
    1215       "logout"
    1216       "Remove a Keeper GitHub CLI login."
    1217       Keeper_github_identity.run_cli_logout
    1218   in
    1219   Cmd.group
    1220     (Cmd.info "keeper-github" ~doc:"Manage Keeper-specific GitHub CLI identity.")
    1221     [ login; status; logout ]

## Verification commands and results

Exact integration build:

    dune build --root . --build-dir _build-task237-explicit lib/masc.cmxa bin/main_eio.exe

Result: exit 0.

Focused identity suite:

    dune exec --root . --build-dir _build-task237-explicit test/keeper_github_identity/test_keeper_github_identity.exe

Result: exit 0, Test Successful, 8 tests run.

Formatting check:

    git diff --check

Result: exit 0.
