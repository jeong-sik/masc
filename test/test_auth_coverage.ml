(** Auth Module Coverage Tests

    Tests for MASC Authentication & Authorization:
    - generate_token: random token generation
    - sha256_hash: cryptographic hashing
    - auth_dir, agents_dir, room_secret_file, auth_config_file: path helpers
*)

(* Initialize RNG for crypto operations *)
let () = Mirage_crypto_rng_unix.use_default ()

open Alcotest

module Auth = Masc_mcp.Auth
module Prometheus = Masc_mcp.Prometheus
module Types = Types

(* ============================================================
   generate_token Tests
   ============================================================ *)

let test_generate_token_nonempty () =
  let token = Auth.generate_token () in
  check bool "nonempty" true (String.length token > 0)

let test_generate_token_length () =
  let token = Auth.generate_token () in
  (* 32 bytes -> 64 hex chars *)
  check int "64 chars" 64 (String.length token)

let test_generate_token_hex () =
  let token = Auth.generate_token () in
  let is_hex = String.for_all (fun c ->
    (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
  ) token in
  check bool "all hex" true is_hex

let test_generate_token_unique () =
  let t1 = Auth.generate_token () in
  let t2 = Auth.generate_token () in
  check bool "unique" true (t1 <> t2)

let setup_test_room () =
  let unique_id =
    Printf.sprintf "masc-auth-coverage-%d-%d"
      (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))
  in
  let tmp = Filename.concat (Filename.get_temp_dir_name ()) unique_id in
  Unix.mkdir tmp 0o755;
  let masc_dir = Filename.concat tmp Common.masc_dirname in
  Unix.mkdir masc_dir 0o755;
  tmp

let cleanup_test_room dir =
  let rec rm_rf path =
    if Sys.is_directory path then begin
      Array.iter (fun f -> rm_rf (Filename.concat path f)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Sys.remove path
  in
  try rm_rf dir with _ -> ()

(* ============================================================
   sha256_hash Tests
   ============================================================ *)

let test_sha256_hash_nonempty () =
  let hash = Auth.sha256_hash "test" in
  check bool "nonempty" true (String.length hash > 0)

let test_sha256_hash_length () =
  let hash = Auth.sha256_hash "test" in
  (* SHA256 produces 64 hex chars *)
  check int "64 chars" 64 (String.length hash)

let test_sha256_hash_hex () =
  let hash = Auth.sha256_hash "test" in
  let is_hex = String.for_all (fun c ->
    (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
  ) hash in
  check bool "all hex" true is_hex

let test_sha256_hash_deterministic () =
  let h1 = Auth.sha256_hash "hello" in
  let h2 = Auth.sha256_hash "hello" in
  check string "same hash" h1 h2

let test_sha256_hash_different_inputs () =
  let h1 = Auth.sha256_hash "hello" in
  let h2 = Auth.sha256_hash "world" in
  check bool "different hashes" true (h1 <> h2)

let test_sha256_hash_empty () =
  let hash = Auth.sha256_hash "" in
  check int "64 chars for empty" 64 (String.length hash)

(* ============================================================
   Path Helper Tests
   ============================================================ *)

let test_auth_dir_nonempty () =
  let path = Auth.auth_dir "/tmp/test" in
  check bool "nonempty" true (String.length path > 0)

let test_auth_dir_contains_masc () =
  let path = Auth.auth_dir "/tmp/test" in
  check bool "contains .masc" true
    (try
       let _ = Str.search_forward (Str.regexp "\\.masc") path 0 in
       true
     with Not_found -> false)

let test_auth_dir_contains_auth () =
  let path = Auth.auth_dir "/tmp/test" in
  check bool "contains auth" true
    (try
       let _ = Str.search_forward (Str.regexp "auth") path 0 in
       true
     with Not_found -> false)

let test_agents_dir_nonempty () =
  let path = Auth.agents_dir "/tmp/test" in
  check bool "nonempty" true (String.length path > 0)

let test_agents_dir_contains_agents () =
  let path = Auth.agents_dir "/tmp/test" in
  check bool "contains agents" true
    (try
       let _ = Str.search_forward (Str.regexp "agents") path 0 in
       true
     with Not_found -> false)

let test_room_secret_file_nonempty () =
  let path = Auth.room_secret_file "/tmp/test" in
  check bool "nonempty" true (String.length path > 0)

let test_room_secret_file_contains_hash () =
  let path = Auth.room_secret_file "/tmp/test" in
  check bool "contains .hash" true
    (try
       let _ = Str.search_forward (Str.regexp "\\.hash") path 0 in
       true
     with Not_found -> false)

let test_auth_config_file_nonempty () =
  let path = Auth.auth_config_file "/tmp/test" in
  check bool "nonempty" true (String.length path > 0)

let test_auth_config_file_json () =
  let path = Auth.auth_config_file "/tmp/test" in
  check bool "ends with .json" true
    (String.length path >= 5 &&
     String.sub path (String.length path - 5) 5 = ".json")

(* ============================================================
   permission_for_tool Tests
   ============================================================ *)

let test_permission_for_tool_init () =
  match Auth.permission_for_tool "masc_init" with
  | None -> ()  (* tool removed in registry pruning *)
  | _ -> fail "expected None (removed tool)"

let test_permission_for_tool_reset () =
  match Auth.permission_for_tool "masc_reset" with
  | Some Types.CanReset -> ()
  | _ -> fail "expected CanReset"

let test_permission_for_tool_join () =
  match Auth.permission_for_tool "masc_join" with
  | Some Types.CanJoin -> ()
  | _ -> fail "expected CanJoin"

let test_permission_for_tool_leave () =
  match Auth.permission_for_tool "masc_leave" with
  | Some Types.CanLeave -> ()
  | _ -> fail "expected CanLeave"

let test_permission_for_tool_status () =
  match Auth.permission_for_tool "masc_status" with
  | Some Types.CanReadState -> ()
  | _ -> fail "expected CanReadState"

let test_permission_for_tool_runtime_verify () =
  (* Tool schema was pruned but the permission map still maps the name
     to CanReadState. Keep the legacy permission contract. *)
  match Auth.permission_for_tool "masc_runtime_verify" with
  | Some Types.CanReadState -> ()
  | _ -> fail "expected CanReadState"

let test_permission_for_tool_who () =
  match Auth.permission_for_tool "masc_who" with
  | Some Types.CanReadState -> ()
  | _ -> fail "expected CanReadState"

let test_permission_for_tool_tasks () =
  match Auth.permission_for_tool "masc_tasks" with
  | Some Types.CanReadState -> ()
  | _ -> fail "expected CanReadState"

let test_permission_for_tool_add_task () =
  match Auth.permission_for_tool "masc_add_task" with
  | Some Types.CanAddTask -> ()
  | _ -> fail "expected CanAddTask"

let test_permission_for_tool_claim () =
  match Auth.permission_for_tool "masc_claim_next" with
  | Some Types.CanClaimTask -> ()
  | _ -> fail "expected CanClaimTask"

let test_permission_for_tool_claim_next () =
  match Auth.permission_for_tool "masc_claim_next" with
  | Some Types.CanClaimTask -> ()
  | _ -> fail "expected CanClaimTask"

let test_permission_for_tool_broadcast () =
  match Auth.permission_for_tool "masc_broadcast" with
  | Some Types.CanBroadcast -> ()
  | _ -> fail "expected CanBroadcast"

let test_permission_for_tool_webrtc_offer () =
  match Auth.permission_for_tool "masc_webrtc_offer" with
  | Some Types.CanBroadcast -> ()
  | _ -> fail "expected CanBroadcast"

let test_permission_for_tool_webrtc_answer () =
  match Auth.permission_for_tool "masc_webrtc_answer" with
  | Some Types.CanBroadcast -> ()
  | _ -> fail "expected CanBroadcast"

let test_permission_for_tool_channel_gate () =
  match Auth.permission_for_tool "channel_gate" with
  | Some Types.CanBroadcast -> ()
  | _ -> fail "expected CanBroadcast"

let test_permission_for_tool_board_list () =
  match Auth.permission_for_tool "masc_board_list" with
  | Some Types.CanReadState -> ()
  | _ -> fail "expected CanReadState"

let test_permission_for_tool_board_post () =
  match Auth.permission_for_tool "masc_board_post" with
  | Some Types.CanBroadcast -> ()
  | _ -> fail "expected CanBroadcast"

let test_permission_for_tool_board_delete () =
  match Auth.permission_for_tool "masc_board_delete" with
  | Some Types.CanAdmin -> ()
  | _ -> fail "expected CanAdmin"

let test_permission_for_tool_worktree_create () =
  match Auth.permission_for_tool "masc_worktree_create" with
  | Some Types.CanCreateWorktree -> ()
  | _ -> fail "expected CanCreateWorktree"

let test_permission_for_tool_worktree_remove () =
  match Auth.permission_for_tool "masc_worktree_remove" with
  | Some Types.CanRemoveWorktree -> ()
  | _ -> fail "expected CanRemoveWorktree"

let test_permission_for_tool_interrupt () =
  match Auth.permission_for_tool "masc_interrupt" with
  | None -> ()
  | _ -> fail "expected None (removed tool)"

(* ============================================================
   HTTP same-origin mutation guard regressions
   ============================================================ *)

let test_same_origin_browser_request_rejects_missing_origin () =
  let module Server_auth = Masc_mcp.Server_auth in
  let headers = Httpun.Headers.of_list [ ("host", "127.0.0.1:8935") ] in
  let request = Httpun.Request.create ~headers `POST "/api/v1/operator/action" in
  match Server_auth.ensure_same_origin_browser_request request with
  | Ok () -> fail "expected Unauthorized when Origin header is missing"
  | Error (Types.Unauthorized _) -> ()
  | Error e -> fail (Printf.sprintf "expected Unauthorized, got %s" (Types.masc_error_to_string e))

let test_same_origin_browser_request_allows_matching_origin () =
  let module Server_auth = Masc_mcp.Server_auth in
  let headers =
    Httpun.Headers.of_list
      [
        ("host", "127.0.0.1:8935");
        ("origin", "http://127.0.0.1:8935");
      ]
  in
  let request = Httpun.Request.create ~headers `POST "/api/v1/operator/action" in
  match Server_auth.ensure_same_origin_browser_request request with
  | Ok () -> ()
  | Error e -> fail (Types.masc_error_to_string e)

let test_same_origin_browser_request_rejects_cross_origin () =
  let module Server_auth = Masc_mcp.Server_auth in
  let headers =
    Httpun.Headers.of_list
      [
        ("host", "127.0.0.1:8935");
        ("origin", "https://evil.example");
      ]
  in
  let request = Httpun.Request.create ~headers `POST "/api/v1/operator/action" in
  match Server_auth.ensure_same_origin_browser_request request with
  | Ok () -> fail "expected cross-origin browser request to be rejected"
  | Error (Types.Forbidden _) -> ()
  | Error e -> fail (Types.masc_error_to_string e)

let test_same_origin_https_tunnel_same_host () =
  let module Server_auth = Masc_mcp.Server_auth in
  let headers =
    Httpun.Headers.of_list
      [
        ("host", "masc.crying.pictures");
        ("origin", "https://masc.crying.pictures");
      ]
  in
  let request = Httpun.Request.create ~headers `POST "/api/v1/operator/action" in
  match Server_auth.ensure_same_origin_browser_request request with
  | Ok () -> ()
  | Error e -> fail (Types.masc_error_to_string e)

let test_same_origin_allows_loopback_alias_same_port () =
  let module Server_auth = Masc_mcp.Server_auth in
  let headers =
    Httpun.Headers.of_list
      [
        ("host", "127.0.0.1:8935");
        ("origin", "http://localhost:8935");
      ]
  in
  let request = Httpun.Request.create ~headers `POST "/api/v1/operator/action" in
  match Server_auth.ensure_same_origin_browser_request request with
  | Ok () -> ()
  | Error e -> fail (Types.masc_error_to_string e)

let test_same_origin_allows_allowlisted_dashboard_dev_origin () =
  let module Server_auth = Masc_mcp.Server_auth in
  let headers =
    Httpun.Headers.of_list
      [
        ("host", "localhost:8935");
        ("origin", "http://localhost:5173");
      ]
  in
  let request = Httpun.Request.create ~headers `POST "/api/v1/operator/action" in
  match Server_auth.ensure_same_origin_browser_request request with
  | Ok () -> ()
  | Error e -> fail (Types.masc_error_to_string e)

let test_same_origin_rejects_non_allowlisted_loopback_cross_port () =
  let module Server_auth = Masc_mcp.Server_auth in
  let headers =
    Httpun.Headers.of_list
      [
        ("host", "localhost:9000");
        ("origin", "http://localhost:8935");
      ]
  in
  let request = Httpun.Request.create ~headers `POST "/api/v1/operator/action" in
  match Server_auth.ensure_same_origin_browser_request request with
  | Ok () -> fail "expected non-allowlisted loopback cross-port request to be rejected"
  | Error (Types.Forbidden _) -> ()
  | Error e -> fail (Types.masc_error_to_string e)

let test_same_origin_rejects_different_explicit_port_on_public_host () =
  let module Server_auth = Masc_mcp.Server_auth in
  let headers =
    Httpun.Headers.of_list
      [
        ("host", "example.com:9000");
        ("origin", "http://example.com:8935");
      ]
  in
  let request = Httpun.Request.create ~headers `POST "/api/v1/operator/action" in
  match Server_auth.ensure_same_origin_browser_request request with
  | Ok () -> fail "expected different-port public host request to be rejected"
  | Error (Types.Forbidden _) -> ()
  | Error e -> fail (Types.masc_error_to_string e)

let test_same_origin_allows_explicit_default_port_https () =
  let module Server_auth = Masc_mcp.Server_auth in
  let headers =
    Httpun.Headers.of_list
      [
        ("host", "example.com:443");
        ("origin", "https://example.com");
      ]
  in
  let request = Httpun.Request.create ~headers `POST "/api/v1/operator/action" in
  match Server_auth.ensure_same_origin_browser_request request with
  | Ok () -> ()
  | Error e -> fail (Types.masc_error_to_string e)

let test_same_origin_allows_explicit_default_port_http () =
  let module Server_auth = Masc_mcp.Server_auth in
  let headers =
    Httpun.Headers.of_list
      [
        ("host", "localhost:80");
        ("origin", "http://localhost");
      ]
  in
  let request = Httpun.Request.create ~headers `POST "/api/v1/operator/action" in
  match Server_auth.ensure_same_origin_browser_request request with
  | Ok () -> ()
  | Error e -> fail (Types.masc_error_to_string e)

(* ============================================================
   HTTP auth extraction regressions
   ============================================================ *)

let test_http_auth_token_from_header_only () =
  let module Server_auth = Masc_mcp.Server_auth in
  let headers =
    Httpun.Headers.of_list [ ("authorization", "Bearer header-token") ]
  in
  let request =
    Httpun.Request.create ~headers `GET
      "/api/v1/tools/masc_board_vote?token=query-token"
  in
  check (option string) "header bearer token extracted" (Some "header-token")
    (Server_auth.auth_token_from_request request)

let test_http_auth_rejects_query_token_fallback () =
  let module Server_auth = Masc_mcp.Server_auth in
  let request =
    Httpun.Request.create `GET "/api/v1/tools/masc_board_vote?token=query-token"
  in
  check (option string) "query token ignored" None
    (Server_auth.auth_token_from_request request)

let test_http_auth_accepts_internal_keeper_header () =
  let module Server_auth = Masc_mcp.Server_auth in
  let headers =
    Httpun.Headers.of_list [ ("x-masc-internal-token", "internal-keeper-token") ]
  in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  check (option string) "internal keeper token extracted"
    (Some "internal-keeper-token")
    (Server_auth.auth_token_from_request request)

let test_observer_sse_auth_accepts_query_token_fallback () =
  let module Server_auth = Masc_mcp.Server_auth in
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.enable_auth dir ~require_token:true ~agent_name:"bootstrap-admin");
      let raw_token =
        match Auth.create_token dir ~agent_name:"stable-admin" ~role:Types.Admin with
        | Ok (token, _cred) -> token
        | Error e -> fail (Types.masc_error_to_string e)
      in
      let request =
        Httpun.Request.create `GET
          ("/mcp?sse_kind=observer&session_id=dash_test&token=" ^ raw_token)
      in
      match Server_auth.verify_mcp_observer_stream_auth ~base_path:dir request with
      | Ok None -> ()
      | Ok (Some _cred) -> fail "observer SSE auth should not surface credential details"
      | Error e -> fail e)

let test_presence_sse_auth_accepts_query_token_fallback () =
  let module Server_auth = Masc_mcp.Server_auth in
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.enable_auth dir ~require_token:true ~agent_name:"bootstrap-admin");
      let raw_token =
        match Auth.create_token dir ~agent_name:"stable-admin" ~role:Types.Admin with
        | Ok (token, _cred) -> token
        | Error e -> fail (Types.masc_error_to_string e)
      in
      let request =
        Httpun.Request.create `GET
          ("/events/presence?session_id=dash_test&token=" ^ raw_token)
      in
      match Server_auth.verify_mcp_observer_stream_auth ~base_path:dir request with
      | Ok None -> ()
      | Ok (Some _cred) -> fail "presence SSE auth should not surface credential details"
      | Error e -> fail e)

let test_observer_sse_auth_rejects_query_token_on_non_observer_path () =
  let module Server_auth = Masc_mcp.Server_auth in
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.enable_auth dir ~require_token:true ~agent_name:"bootstrap-admin");
      let raw_token =
        match Auth.create_token dir ~agent_name:"stable-admin" ~role:Types.Admin with
        | Ok (token, _cred) -> token
        | Error e -> fail (Types.masc_error_to_string e)
      in
      let request =
        Httpun.Request.create `GET
          ("/mcp?session_id=dash_test&token=" ^ raw_token)
      in
      match Server_auth.verify_mcp_observer_stream_auth ~base_path:dir request with
      | Ok _ -> fail "expected non-observer query token to be rejected"
      | Error msg ->
          check bool "non-observer path still requires header" true
            (String.starts_with ~prefix:"Authentication required." msg))

(* Regression guard for the silent default removal (PR-2 of the
   AuthIdentityFSM plan). Before this PR, the [Ok None] arm of
   [verify_mcp_auth] was rewritten to "dashboard" via
   [Option.value ~default:"dashboard"]. Today the resolver returns
   [Ok (Some _)] or [Error] for a non-empty bearer so the rewrite was
   a dead-code default; the test pins the positive path so a future
   refactor cannot reintroduce silent fallback without a visible
   test failure. Spec: AuthIdentityFSM.tla I2 NoSilentRewrite. *)
let test_verify_mcp_auth_accepts_valid_bearer () =
  let module Server_auth = Masc_mcp.Server_auth in
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.enable_auth dir ~require_token:true ~agent_name:"bootstrap-admin");
      let raw_token =
        match Auth.create_token dir ~agent_name:"stable-admin" ~role:Types.Admin with
        | Ok (tok, _cred) -> tok
        | Error e -> fail (Types.masc_error_to_string e)
      in
      let auth_value = String.concat " " [ "Bearer"; raw_token ] in
      let headers = Httpun.Headers.of_list [ ("authorization", auth_value) ] in
      let request = Httpun.Request.create ~headers `POST "/mcp" in
      match Server_auth.verify_mcp_auth ~base_path:dir request with
      | Ok None -> ()
      | Ok (Some _) -> fail "verify_mcp_auth should not surface credential details"
      | Error e -> fail e)

let test_verify_mcp_auth_rejects_invalid_bearer () =
  let module Server_auth = Masc_mcp.Server_auth in
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.enable_auth dir ~require_token:true ~agent_name:"bootstrap-admin");
      (* Build an invalid bearer header in pieces so source scanners do not
         mistake the literal for a real credential. *)
      let invalid_value = String.concat " " [ "Bearer"; "definitely"; "invalid" ] in
      let headers =
        Httpun.Headers.of_list
          [
            ("authorization", invalid_value);
            (* X-MASC-Agent is set to a real principal name to prove that
               the header alone cannot impersonate identity once the silent
               default is removed -- previously the dashboard rewrite would
               have made an unauthenticated request still pass permission
               as "dashboard". *)
            ("x-masc-agent", "dashboard");
          ]
      in
      let request = Httpun.Request.create ~headers `POST "/mcp" in
      match Server_auth.verify_mcp_auth ~base_path:dir request with
      | Ok _ ->
          fail
            "invalid bearer must not authenticate; silent fallback to \
             \"dashboard\" was removed"
      | Error _ -> ())

let test_permission_for_tool_approve () =
  match Auth.permission_for_tool "masc_approve" with
  | None -> ()
  | _ -> fail "expected None (removed tool)"

let test_permission_for_tool_auth_enable () =
  match Auth.permission_for_tool "masc_auth_enable" with
  | None -> ()  (* tool removed in registry pruning *)
  | _ -> fail "expected None (removed tool)"

let test_permission_for_tool_auth_status () =
  match Auth.permission_for_tool "masc_auth_status" with
  | None -> ()  (* tool removed in registry pruning *)
  | _ -> fail "expected None (removed tool)"

let test_permission_for_tool_stats () =
  match Auth.permission_for_tool "masc_tool_stats" with
  | Some Types.CanReadState -> ()
  | _ -> fail "expected CanReadState"

let test_permission_for_tool_admin_snapshot () =
  match Auth.permission_for_tool "masc_tool_admin_snapshot" with
  | Some Types.CanAdmin -> ()
  | _ -> fail "expected CanAdmin"

let test_permission_for_tool_admin_update () =
  match Auth.permission_for_tool "masc_tool_admin_update" with
  | Some Types.CanAdmin -> ()
  | _ -> fail "expected CanAdmin"

let test_permission_for_tool_help () =
  match Auth.permission_for_tool "masc_tool_help" with
  | Some Types.CanReadState -> ()
  | _ -> fail "expected CanReadState"

let test_permission_for_tool_list () =
  match Auth.permission_for_tool "masc_tool_list" with
  | Some Types.CanReadState -> ()
  | _ -> fail "expected CanReadState"

let test_permission_for_tool_grant () =
  match Auth.permission_for_tool "masc_tool_grant" with
  | Some Types.CanAdmin -> ()
  | _ -> fail "expected CanAdmin"

let test_permission_for_tool_revoke () =
  match Auth.permission_for_tool "masc_tool_revoke" with
  | Some Types.CanAdmin -> ()
  | _ -> fail "expected CanAdmin"

let test_permission_for_tool_operator_snapshot () =
  match Auth.permission_for_tool "masc_operator_snapshot" with
  | Some Types.CanReadState -> ()
  | _ -> fail "expected CanReadState"

let test_permission_for_tool_operator_digest () =
  match Auth.permission_for_tool "masc_operator_digest" with
  | Some Types.CanReadState -> ()
  | _ -> fail "expected CanReadState"

let test_permission_for_tool_surface_audit () =
  match Auth.permission_for_tool "masc_surface_audit" with
  | Some Types.CanReadState -> ()
  | _ -> fail "expected CanReadState"

let test_permission_for_tool_operator_action () =
  match Auth.permission_for_tool "masc_operator_action" with
  | Some Types.CanBroadcast -> ()
  | _ -> fail "expected CanBroadcast"

let test_permission_for_tool_operator_confirm () =
  match Auth.permission_for_tool "masc_operator_confirm" with
  | Some Types.CanBroadcast -> ()
  | _ -> fail "expected CanBroadcast"

let test_permission_for_tool_autoresearch_status () =
  match Auth.permission_for_tool "masc_autoresearch_status" with
  | Some Types.CanReadState -> ()
  | _ -> fail "expected CanReadState"

let test_permission_for_tool_autoresearch_start () =
  match Auth.permission_for_tool "masc_autoresearch_start" with
  | Some Types.CanAdmin -> ()
  | _ -> fail "expected CanAdmin"

let test_permission_for_tool_autoresearch_record_finding () =
  match Auth.permission_for_tool "masc_autoresearch_record_finding" with
  | Some Types.CanAdmin -> ()
  | _ -> fail "expected CanAdmin"

let test_permission_for_tool_autoresearch_search_findings () =
  match Auth.permission_for_tool "masc_autoresearch_search_findings" with
  | Some Types.CanReadState -> ()
  | _ -> fail "expected CanReadState"

let test_permission_for_tool_autoresearch_cycle () =
  match Auth.permission_for_tool "masc_autoresearch_cycle" with
  | Some Types.CanAdmin -> ()
  | _ -> fail "expected CanAdmin"

let test_permission_for_tool_autoresearch_inject () =
  match Auth.permission_for_tool "masc_autoresearch_inject" with
  | Some Types.CanAdmin -> ()
  | _ -> fail "expected CanAdmin"

let test_permission_for_tool_autoresearch_stop () =
  match Auth.permission_for_tool "masc_autoresearch_stop" with
  | Some Types.CanAdmin -> ()
  | _ -> fail "expected CanAdmin"

let test_permission_for_tool_keeper_create_from_persona () =
  match Auth.permission_for_tool "masc_keeper_create_from_persona" with
  | Some Types.CanBroadcast -> ()
  | _ -> fail "expected CanBroadcast"

let test_permission_for_tool_set_param () =
  match Auth.permission_for_tool "masc_set_param" with
  | Some Types.CanAdmin -> ()
  | _ -> fail "expected CanAdmin"

(* keeper policy auth tests removed — policy tools no longer registered in Auth *)

(* ============================================================
   Tunnel-through-loopback auth tests (#3654)
   ============================================================ *)

let with_env name value f =
  let prev = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () ->
    match prev with
    | Some v -> Unix.putenv name v
    | None -> (try Unix.putenv name "" with _ -> ())
  ) f

let clear_env name f =
  let prev = Sys.getenv_opt name in
  (try Unix.putenv name "" with _ -> ());
  Fun.protect ~finally:(fun () ->
    match prev with
    | Some v -> Unix.putenv name v
    | None -> ()
  ) f

let test_base_url_non_loopback_enables_strict () =
  let module SA = Masc_mcp.Server_auth in
  with_env "MASC_HTTP_BASE_URL" "https://masc.crying.pictures" (fun () ->
    with_env "MASC_HOST" "127.0.0.1" (fun () ->
      clear_env "MASC_HTTP_AUTH_STRICT" (fun () ->
        check bool "tunnel base URL forces strict auth" true
          (SA.http_auth_strict_enabled ()))))

let test_base_url_localhost_no_strict () =
  let module SA = Masc_mcp.Server_auth in
  with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:8935" (fun () ->
    with_env "MASC_HOST" "127.0.0.1" (fun () ->
      clear_env "MASC_HTTP_AUTH_STRICT" (fun () ->
        check bool "localhost base URL no forced strict" false
          (SA.http_auth_strict_enabled ()))))

let test_base_url_unset_loopback_no_strict () =
  let module SA = Masc_mcp.Server_auth in
  clear_env "MASC_HTTP_BASE_URL" (fun () ->
    with_env "MASC_HOST" "127.0.0.1" (fun () ->
      with_env "MASC_HTTP_PORT" "8935" (fun () ->
        clear_env "MASC_HTTP_AUTH_STRICT" (fun () ->
          check bool "no base URL + loopback = no strict" false
            (SA.http_auth_strict_enabled ())))))

let test_env_flag_overrides_all () =
  let module SA = Masc_mcp.Server_auth in
  with_env "MASC_HTTP_AUTH_STRICT" "true" (fun () ->
    with_env "MASC_HOST" "127.0.0.1" (fun () ->
      clear_env "MASC_HTTP_BASE_URL" (fun () ->
        check bool "env flag forces strict regardless" true
          (SA.http_auth_strict_enabled ()))))

let test_custom_dev_origin_allows_loopback_cross_port () =
  let module SA = Masc_mcp.Server_auth in
  with_env "MASC_HTTP_DEV_MUTATION_ORIGINS" "http://localhost:4317" (fun () ->
    let headers =
      Httpun.Headers.of_list
        [
          ("host", "localhost:9000");
          ("origin", "http://localhost:4317");
        ]
    in
    let request = Httpun.Request.create ~headers `POST "/api/v1/operator/action" in
    match SA.ensure_same_origin_browser_request request with
    | Ok () -> ()
    | Error e -> fail (Types.masc_error_to_string e))

let test_public_read_cors_allows_matching_origin () =
  let module SA = Masc_mcp.Server_auth in
  let headers =
    Httpun.Headers.of_list
      [
        ("host", "localhost:9000");
        ("origin", "http://localhost:9000");
      ]
  in
  let request = Httpun.Request.create ~headers `GET "/api/v1/gate/events" in
  match SA.public_read_cors_origin_opt request with
  | Some origin ->
      Alcotest.(check string) "matching origin reflected" "http://localhost:9000" origin
  | None -> fail "expected public-read cors origin"

let test_public_read_cors_rejects_cross_origin () =
  let module SA = Masc_mcp.Server_auth in
  let headers =
    Httpun.Headers.of_list
      [
        ("host", "localhost:9000");
        ("origin", "https://evil.example");
      ]
  in
  let request = Httpun.Request.create ~headers `GET "/api/v1/gate/events" in
  match SA.public_read_cors_origin_opt request with
  | None -> ()
  | Some origin -> fail ("unexpected reflected origin: " ^ origin)

let test_public_read_cors_allows_allowlisted_loopback_origin () =
  let module SA = Masc_mcp.Server_auth in
  with_env "MASC_HTTP_DEV_MUTATION_ORIGINS" "http://localhost:4317" (fun () ->
    let headers =
      Httpun.Headers.of_list
        [
          ("host", "localhost:9000");
          ("origin", "http://localhost:4317");
        ]
    in
    let request = Httpun.Request.create ~headers `GET "/api/v1/gate/events" in
    match SA.public_read_cors_origin_opt request with
    | Some origin ->
        Alcotest.(check string) "allowlisted loopback origin reflected"
          "http://localhost:4317" origin
    | None -> fail "expected allowlisted public-read cors origin")

let test_public_read_path_allows_generic_connector_status () =
  let module SA = Masc_mcp.Server_auth in
  check bool "generic connector status is public read" true
    (SA.is_public_read_path "/api/v1/gate/connector/status")

let test_public_read_path_rejects_generic_connector_bind () =
  let module SA = Masc_mcp.Server_auth in
  check bool "generic connector bind is not public read" false
    (SA.is_public_read_path "/api/v1/gate/connector/bind")

let test_public_read_path_rejects_generic_connector_unbind () =
  let module SA = Masc_mcp.Server_auth in
  check bool "generic connector unbind is not public read" false
    (SA.is_public_read_path "/api/v1/gate/connector/unbind")

let test_permission_for_tool_unknown () =
  match Auth.permission_for_tool "unknown_tool_xyz" with
  | None -> ()
  | Some _ -> fail "expected None for unknown tool"

let test_permission_for_tool_empty () =
  match Auth.permission_for_tool "" with
  | None -> ()
  | Some _ -> fail "expected None for empty string"

let test_resolve_agent_name_prefers_token_for_generated_actor () =
  let module SA = Masc_mcp.Server_auth in
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.enable_auth dir ~require_token:true ~agent_name:"bootstrap-admin");
      let raw_token =
        match Auth.create_token dir ~agent_name:"stable-admin" ~role:Types.Admin with
        | Ok (token, _cred) -> token
        | Error e -> fail (Types.masc_error_to_string e)
      in
      let headers =
        Httpun.Headers.of_list
          [
            ("authorization", "Bearer " ^ raw_token);
            ("x-masc-agent", "dashboard-eager-manta");
          ]
      in
      let request = Httpun.Request.create ~headers `POST "/mcp" in
      match SA.resolve_agent_name_for_auth ~base_path:dir request ~token:(Some raw_token) with
      | Ok (Some agent_name) ->
          check string "token subject wins for generated actor" "stable-admin" agent_name
      | Ok None -> fail "expected resolved agent name"
      | Error e -> fail (Types.masc_error_to_string e))

let test_resolve_agent_name_preserves_explicit_stable_actor () =
  let module SA = Masc_mcp.Server_auth in
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.enable_auth dir ~require_token:true ~agent_name:"bootstrap-admin");
      let raw_token =
        match Auth.create_token dir ~agent_name:"stable-admin" ~role:Types.Admin with
        | Ok (token, _cred) -> token
        | Error e -> fail (Types.masc_error_to_string e)
      in
      let headers =
        Httpun.Headers.of_list
          [
            ("authorization", "Bearer " ^ raw_token);
            ("x-masc-agent", "dashboard-admin");
          ]
      in
      let request = Httpun.Request.create ~headers `POST "/mcp" in
      match SA.resolve_agent_name_for_auth ~base_path:dir request ~token:(Some raw_token) with
      | Ok (Some agent_name) ->
          check string "token owner canonicalized" "stable-admin" agent_name
      | Ok None -> fail "expected token-bound actor"
      | Error e -> fail (Types.masc_error_to_string e))

let test_sanitized_dashboard_actor_for_request_uses_token_owner () =
  let module SA = Masc_mcp.Server_auth in
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.enable_auth dir ~require_token:true ~agent_name:"bootstrap-admin");
      let raw_token =
        match Auth.create_token dir ~agent_name:"stable-admin" ~role:Types.Admin with
        | Ok (token, _cred) -> token
        | Error e -> fail (Types.masc_error_to_string e)
      in
      let headers =
        Httpun.Headers.of_list
          [
            ("authorization", "Bearer " ^ raw_token);
            ("x-masc-agent", "dashboard-admin-ㅊ");
          ]
      in
      let request = Httpun.Request.create ~headers `POST "/api/v1/gate/connector/bind" in
      check (option string) "token owner wins and remains cache-safe"
        (Some "stable-admin")
        (SA.sanitized_dashboard_actor_for_request ~base_path:dir request))

let test_dashboard_actor_invalid_token_fallback_is_counted () =
  let module SA = Masc_mcp.Server_auth in
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.enable_auth dir ~require_token:true ~agent_name:"bootstrap-admin");
      let before =
        Prometheus.metric_value_or_zero
        Prometheus.metric_silent_dashboard_actor_fallback
          ~labels:[ ("outcome", "error"); ("err_kind", "token_mismatch") ]
          ()
      in
      let headers =
        Httpun.Headers.of_list
          [
            ("authorization", "Bearer definitely-invalid-token");
            ("x-masc-agent", "dashboard-admin");
          ]
      in
      let request = Httpun.Request.create ~headers `GET "/dashboard" in
      check (option string) "falls back to actor hint"
        (Some "dashboard-admin")
        (SA.dashboard_actor_for_request ~base_path:dir request);
      let after =
        Prometheus.metric_value_or_zero
        Prometheus.metric_silent_dashboard_actor_fallback
          ~labels:[ ("outcome", "error"); ("err_kind", "token_mismatch") ]
          ()
      in
      check bool "counter increments" true (after > before))

let test_resolve_agent_name_rejects_invalid_token () =
  let module SA = Masc_mcp.Server_auth in
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.enable_auth dir ~require_token:true ~agent_name:"bootstrap-admin");
      let invalid_token = "definitely-invalid-token" in
      let headers =
        Httpun.Headers.of_list
          [
            ("authorization", "Bearer " ^ invalid_token);
            ("x-masc-agent", "dashboard-admin");
          ]
      in
      let request = Httpun.Request.create ~headers `POST "/mcp" in
      match
        SA.resolve_agent_name_for_auth
          ~base_path:dir request ~token:(Some invalid_token)
      with
      | Error (Types.InvalidToken _) -> ()
      | Error e -> failf "expected InvalidToken, got %s" (Types.masc_error_to_string e)
      | Ok _ -> fail "expected invalid token failure")

let test_authorize_read_request_canonicalizes_token_owner () =
  let module SA = Masc_mcp.Server_auth in
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.enable_auth dir ~require_token:true ~agent_name:"bootstrap-admin");
      let raw_token =
        match Auth.create_token dir ~agent_name:"stable-admin" ~role:Types.Admin with
        | Ok (token, _cred) -> token
        | Error e -> fail (Types.masc_error_to_string e)
      in
      let headers =
        Httpun.Headers.of_list
          [
            ("authorization", "Bearer " ^ raw_token);
            ("x-masc-agent", "dashboard-admin");
          ]
      in
      let request =
        Httpun.Request.create ~headers `GET "/api/v1/dashboard/shell"
      in
      match SA.authorize_read_request ~base_path:dir request with
      | Ok () -> ()
      | Error e -> fail (Types.masc_error_to_string e))

let test_authorize_tool_request_canonicalizes_token_owner () =
  let module SA = Masc_mcp.Server_auth in
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.enable_auth dir ~require_token:true ~agent_name:"bootstrap-admin");
      let raw_token =
        match Auth.create_token dir ~agent_name:"stable-admin" ~role:Types.Admin with
        | Ok (token, _cred) -> token
        | Error e -> fail (Types.masc_error_to_string e)
      in
      let headers =
        Httpun.Headers.of_list
          [
            ("authorization", "Bearer " ^ raw_token);
            ("x-masc-agent", "dashboard-admin");
          ]
      in
      let request =
        Httpun.Request.create ~headers `POST "/api/v1/operator/action"
      in
      match
        SA.authorize_tool_request
          ~base_path:dir ~tool_name:"masc_operator_action" request
      with
      | Ok () -> ()
      | Error e -> fail (Types.masc_error_to_string e))

let test_resolve_agent_name_uses_internal_keeper_header () =
  let module SA = Masc_mcp.Server_auth in
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.enable_auth dir ~require_token:true ~agent_name:"bootstrap-admin");
      let raw_token = Auth.ensure_internal_keeper_token dir in
      let headers =
        Httpun.Headers.of_list
          [
            ("x-masc-internal-token", raw_token);
            ("x-masc-keeper-name", "sangsu");
          ]
      in
      let request = Httpun.Request.create ~headers `POST "/mcp" in
      match SA.resolve_agent_name_for_auth ~base_path:dir request ~token:(Some raw_token) with
      | Ok (Some agent_name) ->
          check string "internal keeper resolves canonical agent"
            "keeper-sangsu-agent" agent_name
      | Ok None -> fail "expected resolved internal keeper agent"
      | Error e -> fail (Types.masc_error_to_string e))

let test_resolve_agent_name_rejects_internal_keeper_without_name () =
  let module SA = Masc_mcp.Server_auth in
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.enable_auth dir ~require_token:true ~agent_name:"bootstrap-admin");
      let raw_token = Auth.ensure_internal_keeper_token dir in
      let headers =
        Httpun.Headers.of_list [ ("x-masc-internal-token", raw_token) ]
      in
      let request = Httpun.Request.create ~headers `POST "/mcp" in
      match SA.resolve_agent_name_for_auth ~base_path:dir request ~token:(Some raw_token) with
      | Ok _ -> fail "expected missing keeper name header to be rejected"
      | Error (Types.Unauthorized msg) ->
          check bool "mentions keeper header" true
            (Astring.String.is_infix ~affix:"x-masc-keeper-name" msg)
      | Error e -> fail (Types.masc_error_to_string e))

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Auth Coverage" [
    "generate_token", [
      test_case "nonempty" `Quick test_generate_token_nonempty;
      test_case "length" `Quick test_generate_token_length;
      test_case "hex" `Quick test_generate_token_hex;
      test_case "unique" `Quick test_generate_token_unique;
    ];
    "sha256_hash", [
      test_case "nonempty" `Quick test_sha256_hash_nonempty;
      test_case "length" `Quick test_sha256_hash_length;
      test_case "hex" `Quick test_sha256_hash_hex;
      test_case "deterministic" `Quick test_sha256_hash_deterministic;
      test_case "different inputs" `Quick test_sha256_hash_different_inputs;
      test_case "empty input" `Quick test_sha256_hash_empty;
    ];
    "auth_dir", [
      test_case "nonempty" `Quick test_auth_dir_nonempty;
      test_case "contains masc" `Quick test_auth_dir_contains_masc;
      test_case "contains auth" `Quick test_auth_dir_contains_auth;
    ];
    "agents_dir", [
      test_case "nonempty" `Quick test_agents_dir_nonempty;
      test_case "contains agents" `Quick test_agents_dir_contains_agents;
    ];
    "room_secret_file", [
      test_case "nonempty" `Quick test_room_secret_file_nonempty;
      test_case "contains hash" `Quick test_room_secret_file_contains_hash;
    ];
    "auth_config_file", [
      test_case "nonempty" `Quick test_auth_config_file_nonempty;
      test_case "json extension" `Quick test_auth_config_file_json;
    ];
    "permission_for_tool", [
      test_case "init" `Quick test_permission_for_tool_init;
      test_case "reset" `Quick test_permission_for_tool_reset;
      test_case "join" `Quick test_permission_for_tool_join;
      test_case "leave" `Quick test_permission_for_tool_leave;
      test_case "status" `Quick test_permission_for_tool_status;
      test_case "who" `Quick test_permission_for_tool_who;
      test_case "tasks" `Quick test_permission_for_tool_tasks;
      test_case "add_task" `Quick test_permission_for_tool_add_task;
      test_case "claim" `Quick test_permission_for_tool_claim;
      test_case "claim_next" `Quick test_permission_for_tool_claim_next;
      test_case "broadcast" `Quick test_permission_for_tool_broadcast;
      test_case "webrtc_offer" `Quick test_permission_for_tool_webrtc_offer;
      test_case "webrtc_answer" `Quick test_permission_for_tool_webrtc_answer;
      test_case "channel_gate" `Quick test_permission_for_tool_channel_gate;
      test_case "board_list" `Quick test_permission_for_tool_board_list;
      test_case "board_post" `Quick test_permission_for_tool_board_post;
      test_case "board_delete" `Quick test_permission_for_tool_board_delete;
      test_case "worktree_create" `Quick test_permission_for_tool_worktree_create;
      test_case "worktree_remove" `Quick test_permission_for_tool_worktree_remove;
      test_case "interrupt" `Quick test_permission_for_tool_interrupt;
      test_case "approve" `Quick test_permission_for_tool_approve;
      test_case "auth_enable" `Quick test_permission_for_tool_auth_enable;
      test_case "auth_status" `Quick test_permission_for_tool_auth_status;
      test_case "tool_stats" `Quick test_permission_for_tool_stats;
      test_case "tool_help" `Quick test_permission_for_tool_help;
      test_case "tool_list" `Quick test_permission_for_tool_list;
      test_case "tool_grant" `Quick test_permission_for_tool_grant;
      test_case "tool_revoke" `Quick test_permission_for_tool_revoke;
      test_case "tool_admin_snapshot" `Quick test_permission_for_tool_admin_snapshot;
      test_case "tool_admin_update" `Quick test_permission_for_tool_admin_update;
      test_case "runtime_verify" `Quick test_permission_for_tool_runtime_verify;
      test_case "operator_snapshot" `Quick test_permission_for_tool_operator_snapshot;
      test_case "operator_digest" `Quick test_permission_for_tool_operator_digest;
      test_case "surface_audit" `Quick test_permission_for_tool_surface_audit;
      test_case "operator_action" `Quick test_permission_for_tool_operator_action;
      test_case "operator_confirm" `Quick test_permission_for_tool_operator_confirm;
      test_case "autoresearch_status" `Quick
        test_permission_for_tool_autoresearch_status;
      test_case "autoresearch_start" `Quick
        test_permission_for_tool_autoresearch_start;
      test_case "autoresearch_record_finding" `Quick
        test_permission_for_tool_autoresearch_record_finding;
      test_case "autoresearch_search_findings" `Quick
        test_permission_for_tool_autoresearch_search_findings;
      test_case "autoresearch_cycle" `Quick
        test_permission_for_tool_autoresearch_cycle;
      test_case "autoresearch_inject" `Quick
        test_permission_for_tool_autoresearch_inject;
      test_case "autoresearch_stop" `Quick
        test_permission_for_tool_autoresearch_stop;
      test_case "keeper_create_from_persona" `Quick
        test_permission_for_tool_keeper_create_from_persona;
      test_case "set_param" `Quick test_permission_for_tool_set_param;
      test_case "unknown" `Quick test_permission_for_tool_unknown;
      test_case "empty" `Quick test_permission_for_tool_empty;
    ];
    "http_auth", [
      test_case "header token only" `Quick test_http_auth_token_from_header_only;
      test_case "accept internal keeper header" `Quick
        test_http_auth_accepts_internal_keeper_header;
      test_case "reject query token fallback" `Quick
        test_http_auth_rejects_query_token_fallback;
      test_case "observer sse accepts query token fallback" `Quick
        test_observer_sse_auth_accepts_query_token_fallback;
      test_case "presence sse accepts query token fallback" `Quick
        test_presence_sse_auth_accepts_query_token_fallback;
      test_case "observer sse rejects query token on non-observer path" `Quick
        test_observer_sse_auth_rejects_query_token_on_non_observer_path;
      test_case "verify_mcp_auth accepts valid bearer" `Quick
        test_verify_mcp_auth_accepts_valid_bearer;
      test_case "verify_mcp_auth rejects invalid bearer (no silent dashboard)" `Quick
        test_verify_mcp_auth_rejects_invalid_bearer;
      test_case "generated actor prefers token subject" `Quick
        test_resolve_agent_name_prefers_token_for_generated_actor;
      test_case "stable actor canonicalizes to token owner" `Quick
        test_resolve_agent_name_preserves_explicit_stable_actor;
      test_case "internal keeper header resolves canonical agent" `Quick
        test_resolve_agent_name_uses_internal_keeper_header;
      test_case "internal keeper without name is rejected" `Quick
        test_resolve_agent_name_rejects_internal_keeper_without_name;
      test_case "sanitized dashboard actor uses token owner" `Quick
        test_sanitized_dashboard_actor_for_request_uses_token_owner;
      test_case "dashboard actor invalid token fallback is counted" `Quick
        test_dashboard_actor_invalid_token_fallback_is_counted;
      test_case "invalid token fails" `Quick
        test_resolve_agent_name_rejects_invalid_token;
      test_case "read request uses token owner" `Quick
        test_authorize_read_request_canonicalizes_token_owner;
      test_case "tool request uses token owner" `Quick
        test_authorize_tool_request_canonicalizes_token_owner;
      test_case "same-origin rejects missing origin without token" `Quick
        test_same_origin_browser_request_rejects_missing_origin;
      test_case "same-origin allows matching origin" `Quick
        test_same_origin_browser_request_allows_matching_origin;
      test_case "same-origin rejects cross origin" `Quick
      test_same_origin_browser_request_rejects_cross_origin;
      test_case "same-origin allows https tunnel same host" `Quick
        test_same_origin_https_tunnel_same_host;
      test_case "same-origin allows loopback alias same port" `Quick
        test_same_origin_allows_loopback_alias_same_port;
      test_case "same-origin allows allowlisted dashboard dev origin" `Quick
        test_same_origin_allows_allowlisted_dashboard_dev_origin;
      test_case "same-origin rejects non-allowlisted loopback cross-port" `Quick
        test_same_origin_rejects_non_allowlisted_loopback_cross_port;
      test_case "same-origin rejects different explicit port on public host" `Quick
        test_same_origin_rejects_different_explicit_port_on_public_host;
      test_case "same-origin allows explicit default port https" `Quick
        test_same_origin_allows_explicit_default_port_https;
      test_case "same-origin allows explicit default port http" `Quick
        test_same_origin_allows_explicit_default_port_http;
    ];
    "tunnel_auth (#3654)", [
      test_case "non-loopback base URL enables strict" `Quick
        test_base_url_non_loopback_enables_strict;
      test_case "localhost base URL no strict" `Quick
        test_base_url_localhost_no_strict;
      test_case "unset base URL + loopback no strict" `Quick
        test_base_url_unset_loopback_no_strict;
      test_case "env flag overrides all" `Quick
        test_env_flag_overrides_all;
      test_case "custom dev origin allows loopback cross-port" `Quick
        test_custom_dev_origin_allows_loopback_cross_port;
      test_case "public-read cors allows matching origin" `Quick
        test_public_read_cors_allows_matching_origin;
      test_case "public-read cors rejects cross origin" `Quick
        test_public_read_cors_rejects_cross_origin;
      test_case "public-read cors allows allowlisted loopback origin" `Quick
        test_public_read_cors_allows_allowlisted_loopback_origin;
      test_case "generic connector status is public read" `Quick
        test_public_read_path_allows_generic_connector_status;
      test_case "generic connector bind is not public read" `Quick
        test_public_read_path_rejects_generic_connector_bind;
      test_case "generic connector unbind is not public read" `Quick
        test_public_read_path_rejects_generic_connector_unbind;
    ];
  ]
