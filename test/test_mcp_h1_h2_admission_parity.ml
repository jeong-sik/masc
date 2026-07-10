(** Focused H1/H2 transport parity and BasePath-scoped lifecycle tests.

    Durable session truth is created only through [Store.open_] and
    [Store.initialize].  Lifecycle coordination always receives that exact
    handle through [Session_lifecycle.create]; this suite deliberately has no
    process-global compatibility registry. *)

open Alcotest

module Store = Server_mcp_transport_session_store
module Session_lifecycle = Server_mcp_transport_http_sse_owner
module Headers = Server_mcp_transport_http_headers

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when Sys.file_exists (Filename.concat root "dune-project") -> root
  | Some _ | None -> Sys.getcwd ()
;;

let source_file relative_path =
  let path = Filename.concat (source_root ()) relative_path in
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let contains ~needle source = String_util.contains_substring source needle

let assert_contains label ~needle source =
  check bool label true (contains ~needle source)
;;

let assert_not_contains label ~needle source =
  check bool label false (contains ~needle source)
;;

let index_of_exn ~needle source =
  Str.search_forward (Str.regexp_string needle) source 0
;;

let assert_order label ~before ~after source =
  let before_index = index_of_exn ~needle:before source in
  let after_index =
    Str.search_forward
      (Str.regexp_string after)
      source
      (before_index + String.length before)
  in
  check bool label true (before_index < after_index)
;;

let source_between ~start_anchor ~end_anchor source =
  let start_index = index_of_exn ~needle:start_anchor source in
  let end_index =
    Str.search_forward
      (Str.regexp_string end_anchor)
      source
      (start_index + String.length start_anchor)
  in
  String.sub source start_index (end_index - start_index)
;;

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter
      (fun entry -> remove_tree (Filename.concat path entry))
      (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
;;

let with_temp_base_path f =
  let path, channel =
    Filename.open_temp_file "masc-h1-h2-parity-" ".workspace"
  in
  close_out channel;
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let require_store = function
  | Ok store -> store
  | Error error -> fail (Store.open_error_to_string error)
;;

let require_initialize store session =
  match Store.initialize store session with
  | Ok () -> ()
  | Error error -> fail (Store.mutation_error_to_string error)
;;

let owner agent_name : Server_transport_admission.identity =
  { agent_name; role = Masc_domain.Worker }
;;

let session ~session_id ~owner : Store.session =
  { session_id
  ; protocol_version = "2025-11-25"
  ; tool_profile = Server_mcp_transport_http_types.Full
  ; owner
  ; started_at = Time_compat.now ()
  ; transport_context = None
  }
;;

let with_initialized_lifecycle f =
  with_temp_base_path (fun base_path ->
    Eio.Switch.run (fun sw ->
      let sessions = require_store (Store.open_ ~sw ~base_path) in
      let session_owner = owner "parity-session-owner" in
      let session =
        session ~session_id:"h1-h2-explicit-store-session" ~owner:session_owner
      in
      require_initialize sessions session;
      let lifecycle = Session_lifecycle.create ~sessions in
      f ~sessions ~lifecycle ~session ~session_owner))
;;

let require_operation label = function
  | Ok operation -> operation
  | Error error ->
    failf
      "%s: %s"
      label
      (Session_lifecycle.lifecycle_error_to_string error)
;;

let require_prepared_delete label = function
  | Ok (Session_lifecycle.Prepared_delete deletion) -> deletion
  | Ok (Session_lifecycle.Resume_committed_delete _) ->
    failf "%s unexpectedly resumed committed cleanup" label
  | Error message -> failf "%s: %s" label message
;;

let require_ok label = function
  | Ok () -> ()
  | Error message -> failf "%s: %s" label message
;;

let test_explicit_store_is_lifecycle_truth () =
  with_initialized_lifecycle (fun ~sessions ~lifecycle ~session ~session_owner ->
    check bool
      "lifecycle retains the exact Store handle"
      true
      (Session_lifecycle.sessions lifecycle == sessions);
    (match Store.find sessions ~session_id:session.session_id with
     | Some (Store.Stable_state (Store.Active active)) ->
       check string
         "active owner comes from durable Store"
         session_owner.agent_name
         active.owner.agent_name
     | Some (Store.Stable_state (Store.Deleted _)) ->
       fail "initialized session became a tombstone"
     | Some (Store.Pending_state _) ->
       fail "durable initialize remained pending"
     | None -> fail "initialized session is absent from Store");
    let operation =
      Session_lifecycle.begin_operation lifecycle
        ~session_id:session.session_id ~requester:session_owner
        ~require_known:true
      |> require_operation "owner operation"
    in
    Session_lifecycle.finish_operation lifecycle operation;
    match
      Session_lifecycle.begin_operation lifecycle
        ~session_id:session.session_id ~requester:(owner "other-owner")
        ~require_known:true
    with
    | Error (Session_lifecycle.Session_owner_rejected _) -> ()
    | Error error ->
      failf
        "wrong-owner operation returned %s"
        (Session_lifecycle.lifecycle_error_to_string error)
    | Ok operation ->
      Session_lifecycle.finish_operation lifecycle operation;
      fail "wrong owner acquired a lifecycle operation")
;;

let test_retained_delete_retry_is_owner_bound_and_reopenable () =
  with_initialized_lifecycle (fun ~sessions:_ ~lifecycle ~session ~session_owner ->
    let deletion =
      Session_lifecycle.begin_mcp_session_delete_or_resume lifecycle
        ~session_id:session.session_id ~requester:session_owner
      |> require_prepared_delete "initial DELETE"
    in
    Session_lifecycle.await_mcp_session_delete_drain lifecycle deletion;
    require_ok
      "retain durability-pending DELETE"
      (Session_lifecycle.retain_mcp_session_delete_for_retry lifecycle deletion);
    (match
       Session_lifecycle.retained_delete_authorization lifecycle
         ~session_id:session.session_id ~requester:session_owner
     with
     | Session_lifecycle.Retained_delete_authorized -> ()
     | Session_lifecycle.No_retained_delete
     | Session_lifecycle.Retained_delete_rejected _
     | Session_lifecycle.Retained_delete_in_progress ->
       fail "retained DELETE was not available to its owner");
    (match
       Session_lifecycle.retained_delete_authorization lifecycle
         ~session_id:session.session_id ~requester:(owner "retry-intruder")
     with
     | Session_lifecycle.Retained_delete_rejected _ -> ()
     | Session_lifecycle.No_retained_delete
     | Session_lifecycle.Retained_delete_authorized
     | Session_lifecycle.Retained_delete_in_progress ->
       fail "retained DELETE did not preserve its immutable owner");
    let retry_deletion =
      Session_lifecycle.begin_mcp_session_delete_or_resume lifecycle
        ~session_id:session.session_id ~requester:session_owner
      |> require_prepared_delete "retained DELETE retry"
    in
    (match
       Session_lifecycle.retained_delete_authorization lifecycle
         ~session_id:session.session_id ~requester:session_owner
     with
     | Session_lifecycle.Retained_delete_in_progress -> ()
     | Session_lifecycle.No_retained_delete
     | Session_lifecycle.Retained_delete_authorized
     | Session_lifecycle.Retained_delete_rejected _ ->
       fail "claimed retry remained concurrently claimable");
    (match
       Session_lifecycle.begin_operation lifecycle
         ~session_id:session.session_id ~requester:session_owner
         ~require_known:true
     with
     | Error (Session_lifecycle.Session_terminating _) -> ()
     | Error error ->
       failf
         "closed retry gate returned %s"
         (Session_lifecycle.lifecycle_error_to_string error)
     | Ok operation ->
       Session_lifecycle.finish_operation lifecycle operation;
       fail "pending DELETE admitted new session work");
    require_ok
      "re-retain claimed retry"
      (Session_lifecycle.retain_mcp_session_delete_for_retry
         lifecycle retry_deletion);
    require_ok
      "abort retained retry"
      (Session_lifecycle.abort_mcp_session_delete lifecycle retry_deletion);
    let operation =
      Session_lifecycle.begin_operation lifecycle
        ~session_id:session.session_id ~requester:session_owner
        ~require_known:true
      |> require_operation "operation after retry abort"
    in
    Session_lifecycle.finish_operation lifecycle operation)
;;

let header_test_deps : Server_mcp_transport_http_types.deps =
  { get_origin = (fun _ -> "https://client.example")
  ; cors_headers =
      (fun _ -> [ "access-control-allow-origin", "https://client.example" ])
  ; auth_token_from_request = (fun _ -> None)
  ; is_ready = (fun () -> false)
  ; get_runtime_result =
      (fun () -> Error "runtime is intentionally outside this header-only test")
  ; get_mcp_http_transport =
      (fun () -> Error "transport is intentionally outside this header-only test")
  ; get_base_path = (fun () -> "header-only-test")
  }
;;

let header_value name headers = List.assoc_opt name headers

let test_session_header_visibility_contract () =
  let session_id = "server-issued-session" in
  let protocol_version = "2025-11-25" in
  let fresh =
    Headers.session_header_visibility ~session_was_provided:false
      ~initialized:false
  in
  let initialized =
    Headers.session_header_visibility ~session_was_provided:false
      ~initialized:true
  in
  let supplied =
    Headers.session_header_visibility ~session_was_provided:true
      ~initialized:false
  in
  let fresh_json =
    Headers.json_response_headers ~deps:header_test_deps ~visibility:fresh
      ~session_id ~protocol_version ~origin:"https://client.example"
  in
  check (option string) "fresh response omits session id" None
    (header_value "mcp-session-id" fresh_json);
  check (option string) "fresh response keeps protocol" (Some protocol_version)
    (header_value "mcp-protocol-version" fresh_json);
  check (option string) "fresh response keeps JSON content type"
    (Some "application/json")
    (header_value "content-type" fresh_json);
  check (option string) "fresh response keeps CORS"
    (Some "https://client.example")
    (header_value "access-control-allow-origin" fresh_json);
  let initialized_sse =
    Headers.sse_response_headers ~deps:header_test_deps
      ~visibility:initialized ~session_id ~protocol_version
      ~origin:"https://client.example"
  in
  check (option string) "durable initialize exposes session id"
    (Some session_id)
    (header_value "mcp-session-id" initialized_sse);
  check bool "durable initialize emits the legacy cookie" true
    (Option.is_some (header_value "set-cookie" initialized_sse));
  let supplied_headers =
    Headers.mcp_response_headers ~visibility:supplied ~session_id
      ~protocol_version
  in
  check (option string) "supplied session remains visible" (Some session_id)
    (header_value "mcp-session-id" supplied_headers)
;;

let test_origin_projection_is_exact_across_h1_h2 () =
  let h1_request origin =
    Httpun.Request.create
      ~headers:
        (Httpun.Headers.of_list
           [ "host", "127.0.0.1:8935"; "origin", origin ])
      `POST "/mcp"
  in
  check bool "H1 exact same-origin admitted" true
    (Server_routes_http.validate_origin
       (h1_request "http://127.0.0.1:8935"));
  check bool "H1 prefix attacker rejected" false
    (Server_routes_http.validate_origin
       (h1_request "http://127.0.0.1.evil.test:8935"));
  let h2_request origin =
    H2.Headers.of_list
      [ ":authority", "127.0.0.1:8935"; "origin", origin ]
    |> Server_h2_gateway_helpers.httpun_headers_of_h2
    |> fun headers -> Httpun.Request.create ~headers `POST "/mcp"
  in
  check bool "H2 exact same-origin admitted" true
    (Server_routes_http.validate_origin
       (h2_request "http://127.0.0.1:8935"));
  check bool "H2 prefix attacker rejected" false
    (Server_routes_http.validate_origin
       (h2_request "http://127.0.0.1.evil.test:8935"))
;;

let test_h1_h2_post_wiring_uses_one_durable_initialize_boundary () =
  let h1 = source_file "lib/server/server_mcp_transport_http.ml" in
  let h2 = source_file "lib/server/server_h2_gateway.ml" in
  let h1_post =
    source_between ~start_anchor:"let handle_post_mcp"
      ~end_anchor:"let handle_get_mcp" h1
  in
  let h2_post =
    source_between
      ~start_anchor:{|`POST, "/mcp" | `POST, "/mcp/managed" ->|}
      ~end_anchor:{|`DELETE, "/mcp/operator" ->|} h2
  in
  List.iter
    (fun (label, needle) ->
      assert_contains ("H1 " ^ label) ~needle h1_post;
      assert_contains ("H2 " ^ label) ~needle h2_post)
    [ "extracts the explicit Store", "mcp_transport_sessions transport"
    ; "uses the shared request decision", "Server_mcp_request_context.decide_post_body"
    ; "opens the lifecycle operation gate", "begin_mcp_session_operation"
    ; "commits initialize once", "commit_successful_initialize ~sessions"
    ; "classifies session header visibility", "session_header_visibility"
    ; "renders Store failures as typed errors", "mutation_error_to_string"
    ; "uses JSON-RPC Internal_error", "Mcp_error_code.Internal_error"
    ];
  List.iter
    (fun removed ->
      assert_not_contains ("H1 removed " ^ removed) ~needle:removed h1_post;
      assert_not_contains ("H2 removed " ^ removed) ~needle:removed h2_post)
    [ "remember_protocol_version_if_initialize_succeeded"
    ; "bind_mcp_session_owner_if_initialize_succeeded"
    ; "remember_mcp_profile"
    ];
  assert_order "H1 dispatch precedes durable initialize commit"
    ~before:"runtime.handle_request" ~after:"commit_successful_initialize"
    h1_post;
  assert_order "H2 dispatch precedes durable initialize commit"
    ~before:"Mcp_eio.handle_request" ~after:"commit_successful_initialize"
    h2_post;
  assert_order "H1 commit result precedes response session headers"
    ~before:"commit_successful_initialize" ~after:"json_response_headers"
    h1_post;
  assert_order "H2 commit result precedes response session headers"
    ~before:"commit_successful_initialize" ~after:"mcp_response_headers"
    h2_post
;;

let test_h1_h2_delete_wiring_retains_indeterminate_retry () =
  let h1 = source_file "lib/server/server_mcp_transport_http.ml" in
  let h2 = source_file "lib/server/server_h2_gateway.ml" in
  let h1_delete =
    source_between ~start_anchor:"let delete_mcp_session"
      ~end_anchor:"let respond_mcp_session_owner_forbidden" h1
  in
  let h2_delete =
    source_between
      ~start_anchor:{|`DELETE, "/mcp" | `DELETE, "/mcp/managed" ->|}
      ~end_anchor:"(* ─────────────────────────────────────────────────────────────────────\n         Dashboard"
      h2
  in
  assert_contains "shared DELETE uses explicit Store handle"
    ~needle:"mcp_transport_sessions transport" h1_delete;
  assert_contains "shared DELETE calls Store.delete"
    ~needle:"Server_mcp_transport_session_store.delete sessions" h1_delete;
  assert_contains "indeterminate persistence retains exact deletion"
    ~needle:"retain_mcp_session_delete_for_retry" h1_delete;
  assert_contains "H1 routes retained deletion retry"
    ~needle:"retained_mcp_session_delete_authorization" h1;
  assert_contains "H2 routes retained deletion retry"
    ~needle:"retained_mcp_session_delete_authorization" h2_delete;
  assert_not_contains "legacy full-snapshot persistence is absent"
    ~needle:"durably_forget_mcp_session" h1_delete
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run
    "mcp_h1_h2_admission_parity"
    [ ( "explicit-store-lifecycle"
      , [ test_case "Store handle is lifecycle truth" `Quick
            test_explicit_store_is_lifecycle_truth
        ; test_case "retained DELETE retry is owner-bound and reopenable" `Quick
            test_retained_delete_retry_is_owner_bound_and_reopenable
        ] )
    ; ( "response-boundary"
      , [ test_case "session header visibility follows durable initialize" `Quick
            test_session_header_visibility_contract
        ; test_case "Origin projection is exact across H1/H2" `Quick
            test_origin_projection_is_exact_across_h1_h2
        ] )
    ; ( "static-parity"
      , [ test_case "H1/H2 share one durable initialize boundary" `Quick
            test_h1_h2_post_wiring_uses_one_durable_initialize_boundary
        ; test_case "H1/H2 retain indeterminate DELETE retry" `Quick
            test_h1_h2_delete_wiring_retains_indeterminate_retry
        ] )
    ]
;;
