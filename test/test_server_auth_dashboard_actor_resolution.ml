(** Dashboard actor attribution keeps endpoint authorization separate while
    refusing to reinterpret a rejected bearer token as an anonymous hint. *)

open Alcotest

let with_temp_base_path f =
  let path = Filename.temp_file "masc-dashboard-actor-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () ->
      let rec remove path =
        match (Unix.lstat path).Unix.st_kind with
        | Unix.S_DIR ->
            Array.iter
              (fun entry -> remove (Filename.concat path entry))
              (Sys.readdir path);
            Unix.rmdir path
        | _ -> Unix.unlink path
      in
      remove path)
    (fun () -> f path)

let request ?token ~actor () =
  let headers =
    ("x-masc-agent", actor)
    :: (match token with
        | None -> []
        | Some token -> [ ("authorization", "Bearer " ^ token) ])
  in
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list headers)
    `GET
    "/api/v1/dashboard/briefing"

let resolve ~base_path request =
  Server_auth.dashboard_actor_resolution_for_request ~base_path request

let project ~base_path request =
  Server_auth.dashboard_actor_for_request ~base_path request

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"

let test_anonymous_public_read_preserves_hint () =
  with_temp_base_path @@ fun base_path ->
  let request = request ~actor:"public-reader" () in
  (match resolve ~base_path request with
   | Server_auth.Anonymous_actor_hint (Some actor) ->
       check string "anonymous hint" "public-reader" actor
   | _ -> fail "expected Anonymous_actor_hint");
  check (option string) "public projection" (Some "public-reader")
    (project ~base_path request)

let test_rejected_credential_cannot_supply_actor_hint () =
  with_temp_base_path @@ fun base_path ->
  let request = request ~token:"stale-token" ~actor:"forged-actor" () in
  (match resolve ~base_path request with
   | Server_auth.Rejected_credential
       (Auth_error_kind.Outcome_error
          { err_kind = Auth_error_kind.Token_mismatch
          ; actor_hint = Some actor_hint
          ; _
          }) ->
       check string "hint retained only as diagnostic" "forged-actor" actor_hint
   | _ -> fail "expected typed token-mismatch rejection");
  check (option string) "rejected credential has no actor" None
    (project ~base_path request);
  (match
     Server_auth.authorize_tool_request_with_actor
       ~base_path
       ~tool_name:"masc_broadcast"
       ~request_authority:(loopback_request_authority ())
       request
   with
   | Error (Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken _)) -> ()
   | Error err ->
       failf "unexpected endpoint auth error: %s"
         (Masc_domain.masc_error_to_string err)
   | Ok actor -> failf "endpoint auth unexpectedly admitted %s" actor)

let test_malformed_credential_cannot_become_anonymous () =
  with_temp_base_path @@ fun base_path ->
  Auth.save_auth_config
    base_path
    { Masc_domain.default_auth_config with enabled = true; require_token = false };
  let request =
    Httpun.Request.create
      ~headers:
        (Httpun.Headers.of_list
           [ ("authorization", "Basic malformed")
           ; ("x-masc-agent", "forged-actor")
           ])
      `GET
      "/api/v1/dashboard/briefing"
  in
  (match resolve ~base_path request with
   | Server_auth.Rejected_credential
       (Auth_error_kind.Outcome_error
          { err_kind = Auth_error_kind.Unauthorized
          ; actor_hint = Some actor_hint
          ; _
          }) ->
       check string "hint retained only as diagnostic" "forged-actor" actor_hint
   | _ -> fail "expected typed malformed-credential rejection");
  check (option string) "malformed credential has no actor" None
    (project ~base_path request);
  (match Server_auth.authorize_read_request ~base_path request with
   | Error (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized _)) -> ()
   | Error err ->
       failf "unexpected read auth error: %s"
         (Masc_domain.masc_error_to_string err)
   | Ok () -> fail "malformed credential admitted to read authorization");
  (match Server_auth.verify_mcp_auth ~base_path request with
   | Error _ -> ()
   | Ok _ -> fail "malformed credential admitted to optional MCP authorization");
  (match
     Server_auth.authorize_tool_request_with_actor
       ~base_path
       ~tool_name:"masc_broadcast"
       ~request_authority:(loopback_request_authority ())
       request
   with
   | Error (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized _)) -> ()
   | Error err ->
       failf "unexpected endpoint auth error: %s"
         (Masc_domain.masc_error_to_string err)
   | Ok actor -> failf "malformed credential admitted as %s" actor)

let observer_request ?authorization ?internal_token ?query_token () =
  let target =
    match query_token with
    | None -> "/mcp?sse_kind=observer"
    | Some token -> "/mcp?sse_kind=observer&token=" ^ token
  in
  let headers =
    []
    |> (fun headers ->
         match authorization with
         | None -> headers
         | Some value -> ("authorization", value) :: headers)
    |> fun headers ->
    match internal_token with
    | None -> headers
    | Some value -> ("x-masc-internal-token", value) :: headers
  in
  Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET target

let expect_observer_rejected ~base_path request message =
  match Server_auth.verify_mcp_observer_stream_auth ~base_path request with
  | Error _ -> ()
  | Ok _ -> fail message

let expect_observer_admitted ~base_path request message =
  match Server_auth.verify_mcp_observer_stream_auth ~base_path request with
  | Ok _ -> ()
  | Error err ->
      failf "%s: %s" message (Masc_domain.masc_error_to_string err)

let test_mcp_auth_surfaces_preserve_typed_reasons () =
  with_temp_base_path @@ fun base_path ->
  Auth.save_auth_config
    base_path
    { Masc_domain.default_auth_config with enabled = true; require_token = true };
  let observer = observer_request () in
  (match Server_auth.verify_mcp_observer_stream_auth ~base_path observer with
   | Error
       (Masc_domain.Auth
          (Masc_domain.Auth_error.Unauthorized
             { reason = Masc_domain.Auth_error.Missing_token; _ })) ->
       ()
   | Error err ->
       failf "observer error lost its typed reason: %s"
         (Masc_domain.masc_error_to_string err)
   | Ok _ -> fail "observer auth admitted a request without a token");
  let operator =
    Httpun.Request.create `GET "/mcp/operator"
  in
  (match Server_auth.verify_operator_mcp_auth ~base_path operator with
   | Error
       (Masc_domain.Auth
          (Masc_domain.Auth_error.Unauthorized
             { reason = Masc_domain.Auth_error.Missing_token; _ })) ->
       ()
   | Error err ->
       failf "operator error lost its typed reason: %s"
         (Masc_domain.masc_error_to_string err)
   | Ok _ -> fail "operator auth admitted a request without a token");
  let deps = Server_routes_http_common.mcp_transport_http_deps () in
  let expect_transport_code label result =
    match result with
    | Error { Server_mcp_transport_http_types.auth_error_code = Some code; _ } ->
        check string label "missing_token" code
    | Error { auth_error_code = None; message } ->
        failf "%s lost auth_error_code: %s" label message
    | Ok () -> failf "%s admitted a request without a token" label
  in
  expect_transport_code
    "observer transport auth code"
    (deps.verify_mcp_observer_stream_auth ~base_path observer);
  expect_transport_code
    "operator transport auth code"
    (deps.verify_operator_mcp_auth ~base_path operator)

let test_credential_source_precedence_and_observer_query_state () =
  with_temp_base_path @@ fun base_path ->
  Auth.save_auth_config
    base_path
    { Masc_domain.default_auth_config with enabled = true; require_token = false };
  let save_token agent_name raw_token =
    match
      Auth.save_raw_token_credential
        base_path
        ~agent_name
        ~role:Masc_domain.Worker
        ~raw_token
    with
    | Ok _ -> ()
    | Error err -> fail (Masc_domain.masc_error_to_string err)
  in
  save_token "header-owner" "header-token";
  save_token "query-owner" "query-token";
  let internal_only = observer_request ~internal_token:" internal-token " () in
  check
    (option string)
    "internal token trimmed"
    (Some "internal-token")
    (Server_auth.auth_token_from_request internal_only);
  let blank_internal = observer_request ~internal_token:"   " () in
  check
    (option string)
    "blank internal is not parsed"
    None
    (Server_auth.auth_token_from_request blank_internal);
  check bool "blank internal remains explicit" true
    (Server_auth.request_carries_auth_credential blank_internal);
  let internal_after_malformed_authorization =
    observer_request
      ~authorization:"Basic malformed"
      ~internal_token:"internal-token"
      ()
  in
  check
    (option string)
    "supported internal header retains precedence fallback"
    (Some "internal-token")
    (Server_auth.auth_token_from_request internal_after_malformed_authorization);
  expect_observer_rejected
    ~base_path
    (observer_request
       ~authorization:"Basic malformed"
       ~query_token:"query-token"
       ())
    "malformed header must not fall back to a valid query credential";
  expect_observer_admitted
    ~base_path
    (observer_request
       ~authorization:"Bearer header-token"
       ~query_token:""
       ())
    "valid header must take precedence over malformed query credential";
  expect_observer_admitted
    ~base_path
    (observer_request ~query_token:"query-token" ())
    "valid observer query credential should be admitted";
  expect_observer_rejected
    ~base_path
    (observer_request ~query_token:"" ())
    "empty observer query credential must not become anonymous"

let test_authenticated_owner_overrides_request_hint () =
  with_temp_base_path @@ fun base_path ->
  let token = "owner-token" in
  (match
     Auth.save_raw_token_credential
       base_path
       ~agent_name:"credential-owner"
       ~role:Masc_domain.Worker
       ~raw_token:token
   with
   | Ok _ -> ()
   | Error err -> fail (Masc_domain.masc_error_to_string err));
  let request = request ~token ~actor:"forged-actor" () in
  (match resolve ~base_path request with
   | Server_auth.Authenticated_actor actor ->
       check string "credential owner" "credential-owner" actor
   | _ -> fail "expected Authenticated_actor");
  check (option string) "authenticated projection" (Some "credential-owner")
    (project ~base_path request)

(* RFC play-link-for-the-shared-machine: a Player bearer is admitted only
   where CanPlayMachine is asked for. The /mcp transport and the observer
   stream ask for CanReadState, so an invited Player cannot open them. *)
let test_a_player_reaches_only_the_seat () =
  with_temp_base_path @@ fun base_path ->
  Auth.save_auth_config
    base_path
    { Masc_domain.default_auth_config with enabled = true; require_token = true };
  let token =
    match Auth.create_token base_path ~agent_name:"invitee" ~role:Masc_domain.Player with
    | Ok (token, _) -> token
    | Error err -> failf "create_token failed: %s" (Masc_domain.masc_error_to_string err)
  in
  let request target =
    Httpun.Request.create
      ~headers:(Httpun.Headers.of_list [ ("authorization", "Bearer " ^ token) ])
      `POST
      target
  in
  let mcp = request "/mcp" in
  (match Server_auth.verify_mcp_auth ~base_path mcp with
   | Error (Masc_domain.Auth (Masc_domain.Auth_error.Forbidden _)) -> ()
   | Error err ->
       failf "unexpected /mcp refusal: %s" (Masc_domain.masc_error_to_string err)
   | Ok _ -> fail "a player opened /mcp");
  (match Server_auth.verify_mcp_observer_stream_auth ~base_path (request "/mcp?sse_kind=observer") with
   | Error _ -> ()
   | Ok _ -> fail "a player opened the observer stream");
  (match Server_auth.authorize_read_request ~base_path mcp with
   | Error (Masc_domain.Auth (Masc_domain.Auth_error.Forbidden _)) -> ()
   | Error err ->
       failf "unexpected read refusal: %s" (Masc_domain.masc_error_to_string err)
   | Ok () -> fail "a player passed read authorization");
  (match
     Server_auth.authorize_token_bound_permission_request
       ~base_path ~permission:Masc_domain.CanPlayMachine mcp
   with
   | Ok actor -> check string "the seat is bound to the invite's name" "invitee" actor
   | Error err -> failf "the seat refused a player: %s" (Masc_domain.masc_error_to_string err));
  let tool tool_name =
    Server_auth.authorize_tool_request_with_actor
      ~base_path
      ~tool_name
      ~request_authority:(loopback_request_authority ())
      (request "/api/v1/dos/press")
  in
  (match tool "masc_dos_press" with
   | Ok actor -> check string "press is credited to the invite's name" "invitee" actor
   | Error err -> failf "press refused a player: %s" (Masc_domain.masc_error_to_string err));
  List.iter
    (fun tool_name ->
      match tool tool_name with
      | Error (Masc_domain.Auth (Masc_domain.Auth_error.Forbidden _)) -> ()
      | Error err ->
          failf "unexpected %s refusal: %s" tool_name (Masc_domain.masc_error_to_string err)
      | Ok actor -> failf "%s admitted a player as %s" tool_name actor)
    [ "masc_dos_load"; "masc_dos_peek"; "masc_broadcast"; "masc_status" ];
  check bool "the standing is a player's" true
    (Server_auth.request_credential_standing ~base_path mcp = Server_auth.Player_credential)

(* A credential the store could not be read for is [Unreadable_credential],
   never [No_credential]: the credential may be the operator's, and answering
   "no credential" demoted it to an unnamed caller on the schedule routes and
   to unauthenticated on the lane routes. A mode-0 file stands in for the
   failed open. Root opens a mode-0 file, so there is nothing to make
   unreadable. *)
let test_unreadable_credential_standing_is_not_no_credential () =
  if Unix.geteuid () = 0 then skip ();
  with_temp_base_path @@ fun base_path ->
  let operator_file = Auth.credential_file base_path "operator" in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.chmod operator_file 0o600 with Unix.Unix_error _ -> ()))
    (fun () ->
      let token =
        match Auth.create_token base_path ~agent_name:"operator" ~role:Masc_domain.Admin with
        | Ok (token, _) -> token
        | Error err -> failf "create_token failed: %s" (Masc_domain.masc_error_to_string err)
      in
      let request = request ~token ~actor:"operator" () in
      check bool "a readable operator credential is the operator's" true
        (Server_auth.request_credential_standing ~base_path request
         = Server_auth.Operator_credential);
      Unix.chmod operator_file 0o000;
      check bool "an unreadable credential is unknown, not absent" true
        (Server_auth.request_credential_standing ~base_path request
         = Server_auth.Unreadable_credential))

let test_workspace_bound_read_preconditions () =
  with_temp_base_path @@ fun base_path ->
  Unix.mkdir (Filename.concat base_path ".masc") 0o700;
  let config = Masc.Workspace.default_config base_path in
  let base = Unix.realpath base_path in
  let root = Unix.realpath (Filename.concat base_path ".masc") in
  let fields = ["expected_base_path",[base];"expected_masc_root",[root]] in
  let read ?(meth=`GET) path fields =
    let target = Uri.with_query (Uri.of_string path) fields |> Uri.to_string in
    Server_auth.validate_read_workspace_precondition ~config
      (Httpun.Request.create meth target) in
  List.iter (fun path ->
    check bool "the same bound workspace admits each read shape" true
      (read path fields=Ok Server_auth.Workspace_read_matched);
    check bool "a foreign workspace cannot answer under the old identity" true
      (read path ["expected_base_path",[base ^ "/foreign"];"expected_masc_root",[root]]
       =Error Masc.Workspace.Workspace_precondition_failed))
    ["/api/v1/dashboard/planning";"/api/v1/board";"/api/v1/setup/account-emails"];
  List.iter (fun malformed ->
    check bool "partial, duplicate and empty workspace values are refused" true
      (read "/api/v1/dashboard/planning" malformed
       =Error Masc.Workspace.Invalid_workspace_precondition))
    [["expected_base_path",[base]];
     ["expected_base_path",[base;base];"expected_masc_root",[root]];
     ["expected_base_path",[base];"expected_masc_root",[root;root]];
     ["expected_base_path",[""];"expected_masc_root",[root]]];
  check bool "unbound reads retain ordinary query semantics" true
    (read "/api/v1/board" ["hearth",["research & design"]]=Ok Server_auth.Workspace_read_unbound);
  check bool "HEAD uses the same workspace precondition" true
    (read ~meth:`HEAD "/api/v1/board" fields=Ok Server_auth.Workspace_read_matched);
  check bool "POST retains its operation-owned precondition" true
    (read ~meth:`POST "/api/v1/board" ["expected_base_path",[base]]=Ok Server_auth.Workspace_read_unbound)

(* Use the actual admission validator, JSON/cache pipeline and history decoder.
   Response frames are controlled protocol input, not a wire/server fixture. *)
let test_history_read_keeps_original_workspace_through_replacement () =
  with_temp_base_path @@ fun base_a ->
  with_temp_base_path @@ fun base_b ->
  List.iter (fun base -> Unix.mkdir (Filename.concat base ".masc") 0o700)
    [base_a; base_b];
  let config_a = Masc.Workspace.default_config base_a in
  let config_b = Masc.Workspace.default_config base_b in
  let identity base : Masc.Tui_decode.server_identity =
    { sid_version = "0.24.0"; sid_binary_commit = "original-history"
    ; sid_binary_commit_age_s = None; sid_base_path = Masc.Tui_decode.Canonical_path.of_path (Unix.realpath base)
    ; sid_masc_root = Masc.Tui_decode.Canonical_path.of_path (Unix.realpath (Filename.concat base ".masc"))
    ; sid_executable_in_worktree = None; sid_state_ready = Some true
    ; sid_uptime = None; sid_sse_clients = None; sid_gc = None; sid_scheduler = None }
  in
  let identity_a = identity base_a and identity_b = identity base_b in
  let history context =
    `Assoc ["schema",`String "masc.task-history.page/v1";"task_id",`String "task-original";
      "cursor",`Null;"next_cursor",`Null;"events",`List [`Assoc ["type", `String "task_transition";
      "task", `String "task-original"; "agent", `String "original-keeper";
      "ts", `String "2026-10-19T01:00:00Z";
      "from_status", `String "todo"; "to_status", `String "in_progress";
      "handoff_context", `Assoc ["summary", `String context]]]]
  in
  let receipt = Masc.Workspace.read_precondition_admission_header in
  let tag = "\"same-history-tag\"" in
  let frame ?(status=200) ?(receipts=[receipt]) context : Masc_http_client.response =
    { status; headers=("ETag", tag)::receipts
    ; body=(if status=304 then "" else Yojson.Safe.to_string (history context)) }
  in
  let served = ref config_a and response = ref (frame "A original handoff") in
  let send_for config response ~path ~headers =
    Eio.Fiber.yield ();
    let request = Httpun.Request.create
        ~headers:(Httpun.Headers.of_list headers) `GET path in
    match Server_auth.validate_read_workspace_precondition ~config request with
    | Ok Server_auth.Workspace_read_matched -> Ok response
    | Ok Server_auth.Workspace_read_unbound
    | Error (Masc.Workspace.Invalid_workspace_precondition
            | Masc.Workspace.Workspace_precondition_failed) ->
        Ok { Masc_http_client.status=409; headers=[]
           ; body="{\"error\":\"workspace_precondition_failed\"}" }
  in
  let send ~path ~headers = send_for !served !response ~path ~headers in
  let kept_reads = Masc_tui_kept_reads.create () in
  let host = "127.0.0.1" and port = 8935 in
  let path = "/api/v1/dashboard/tasks/history/page?task_id=task-original&limit=1" in
  let read ?(port=port) ~send () =
    Masc_tui_workspace_read.read_json ~kept_reads
      ~address_of:(fun ~path -> Printf.sprintf "http://%s:%d%s" host port path)
      ~send ~decode:Masc.Tui_decode.decode_json_response_body ~host ~port ~path
  in
  let bound ?(port=port) expected load =
    Masc_tui_workspace_read.with_binding ~host ~port ~expected
      ~proof:Masc_tui_workspace_read.Request_precondition load
  in
  let decode_history result = Result.bind result
      (Masc.Tui_decode_task_inspection.history_page
        ~request:(Masc.Tui_decode_task_inspection.history_first ~task_id:"task-original" ~limit:1)) in
  let expect_events context (history : Masc.Tui_decode_task_inspection.history) =
    check bool "decoded original handoff and actor survive the read" true
      (List.exists (fun (event : Masc.Tui_decode.task_history_event) ->
        event.th_note=Some context && event.th_actor=Some "original-keeper"
        && event.th_from_status=Some "todo" && event.th_to_status=Some "in_progress") history.history_events)
  in
  let expect_context context result =
    match decode_history result with
    | Ok events -> expect_events context events
    | Error detail -> failf "original task history unavailable: %s" detail
  in
  let expect_refusal result =
    match result with
    | Error _ -> ()
    | Ok _ -> fail "unadmitted or foreign history became observable"
  in
  let original = bound identity_a (read ~send) in
  expect_context "A original handoff" original;
  let state = Masc_tui_types.create_state ~workspace:"history-protocol"
      ~local_base_path:base_a ~port ~refresh_interval:0. () in
  state.workspace_identity <- Masc_tui_types.Workspace_identity_match;
  state.server_identity <- Some identity_a;
  let begin_read () = match Masc_tui_types.begin_task_history_read state ~task_id:"task-original" ~limit:1 with
    | Some request -> request
    | None -> fail "original history did not acquire its read owner" in
  let complete owner result =
    Masc_tui_types.complete_task_history_read state owner
      (Result.bind result (Masc.Tui_decode_task_inspection.history_page ~request:owner.thr_page)) in
  let initial_owner = begin_read () in
  complete initial_owner original;
  let old_refresh = begin_read () in
  served := config_b;
  response := frame "B independent handoff";
  let refused = bound identity_a (read ~send) in
  expect_refusal refused;
  complete old_refresh refused;
  (match Masc_tui_fetched.view_for ~equal:String.equal state.task_history ~key:"task-original" with
   | Masc_tui_fetched.Stale (events, _) -> expect_events "A original handoff" events
   | Absent | Loading | Ready _ | Failed _ -> fail "refused GET lost its original history or failure");
  check bool "refused actual GET settles the read without a health result" false
    (Masc_tui_fetched.in_flight state.task_history);
  (* Even the same ETag at the same endpoint cannot borrow another root's body. *)
  response := frame ~status:304 "B independent handoff";
  expect_refusal (bound identity_b (read ~send));
  response := frame "B independent handoff";
  let recovered = bound identity_b (read ~send) in
  expect_context "B independent handoff" recovered;
  Masc_tui_types.withdraw_detail_histories state;
  state.workspace_identity <- Masc_tui_types.Workspace_identity_mismatch
    {local_base_path=base_a; server_base_path=base_b};
  state.server_identity <- Some identity_b;
  let replacement_owner = begin_read () in
  complete old_refresh original;
  check bool "late original result cannot settle replacement workspace" true
    (Masc_tui_fetched.is_current ~equal:String.equal state.task_history replacement_owner.thr_ticket
     && Masc_tui_fetched.in_flight state.task_history);
  complete replacement_owner recovered;
  complete initial_owner original;
  (match Masc_tui_fetched.view_for ~equal:String.equal state.task_history ~key:"task-original" with
   | Masc_tui_fetched.Ready events -> expect_events "B independent handoff" events
   | Absent | Loading | Stale _ | Failed _ -> fail "admitted replacement did not keep its own history");
  response := frame ~status:304 "B independent handoff";
  expect_context "B independent handoff" (bound identity_b (read ~send));
  response := frame ~status:304 ~receipts:[] "unattested reuse";
  expect_refusal (bound identity_b (read ~send));
  List.iter (fun receipts ->
    response := frame ~receipts "unadmitted replacement";
    expect_refusal (bound identity_b (read ~send));
    response := frame ~status:304 "B independent handoff";
    expect_context "B independent handoff" (bound identity_b (read ~send)))
    [[]; [receipt; receipt]; [fst receipt, "wrong-workspace-receipt"]];
  response := frame "B independent handoff";
  expect_context "B independent handoff" (bound identity_b (read ~send));
  expect_refusal (bound identity_b (read ~port:(port+1) ~send));
  (* A child retains its asking fiber's identity after the parent leaves that
     binding, while a different collector is reading another endpoint/root. *)
  Eio.Switch.run @@ fun sw ->
  let start, release = Eio.Promise.create () in
  let child, completed = Eio.Promise.create () in
  let send_a = send_for config_a (frame "A original handoff") in
  let send_b = send_for config_b (frame "B independent handoff") in
  bound ~port:(port+1) identity_a (fun () ->
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.await start;
      Eio.Promise.resolve completed (read ~port:(port+1) ~send:send_a ())));
  bound identity_b (fun () ->
    Eio.Promise.resolve release ();
    expect_context "B independent handoff" (read ~send:send_b ()));
  expect_context "A original handoff" (Eio.Promise.await child)

let test_operator_task_cancel_requires_token_bound_admin () =
  with_temp_base_path @@ fun base_path ->
  Auth.save_auth_config base_path
    { Masc_domain.default_auth_config with enabled = true; require_token = true };
  let authorize ?token () =
    let headers = ("x-masc-agent", "forged-owner") ::
      (match token with None -> [] | Some value -> ["authorization", "Bearer " ^ value]) in
    let request = Httpun.Request.create ~headers:(Httpun.Headers.of_list headers)
      `POST "/api/v1/dashboard/tasks/cancel" in
    Server_auth.authorize_token_bound_permission_request ~base_path
      ~permission:Masc_domain.CanAdmin request
  in
  let save role agent_name raw_token =
    match Auth.save_raw_token_credential base_path ~agent_name ~role ~raw_token with
    | Ok _ -> () | Error error -> fail (Masc_domain.masc_error_to_string error)
  in
  save Masc_domain.Worker "worker" "worker-token";
  save Masc_domain.Admin "operator" "operator-token";
  check bool "actor hint alone is refused" true (Result.is_error (authorize ()));
  check bool "worker token is refused" true
    (Result.is_error (authorize ~token:"worker-token" ()));
  match authorize ~token:"operator-token" () with
  | Ok actor -> check string "operator comes from token" "operator" actor
  | Error error -> fail (Masc_domain.masc_error_to_string error)

let () =
  Eio_main.run @@ fun _env ->
  Server_request_authority.with_current
    (loopback_request_authority ())
    (fun () ->
       run "server_auth_dashboard_actor_resolution"
         [ ( "operator-task-cancel"
           , [ test_case "requires token-bound admin" `Quick
                 test_operator_task_cancel_requires_token_bound_admin ] )
         ; ( "resolution"
           , [ test_case "workspace-bound reads preserve exact query authority" `Quick
                 test_workspace_bound_read_preconditions
             ; test_case "original history survives workspace replacement and parallel reads" `Quick
                 test_history_read_keeps_original_workspace_through_replacement
             ; test_case "anonymous public hint is preserved" `Quick
                 test_anonymous_public_read_preserves_hint
             ; test_case "rejected credential fails closed" `Quick
                 test_rejected_credential_cannot_supply_actor_hint
             ; test_case "malformed credential fails closed" `Quick
                 test_malformed_credential_cannot_become_anonymous
             ; test_case "credential precedence and observer query state" `Quick
                 test_credential_source_precedence_and_observer_query_state
             ; test_case "MCP auth surfaces preserve typed reasons" `Quick
                 test_mcp_auth_surfaces_preserve_typed_reasons
             ; test_case "authenticated owner is canonical" `Quick
                 test_authenticated_owner_overrides_request_hint
             ; test_case "a player reaches only the seat" `Quick
                 test_a_player_reaches_only_the_seat
             ; test_case "an unreadable credential is unknown, not absent" `Quick
                 test_unreadable_credential_standing_is_not_no_credential
             ] )
         ])
