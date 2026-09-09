open Alcotest
open Masc
open Keeper_shutdown_types

module Http = Http_server_eio
module Api = Server_dashboard_http_keeper_shutdown_reconciliation

let () = Mirage_crypto_rng_unix.use_default ()

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let require_ok error = function Ok value -> value | Error value -> fail (error value)
let store_ok result = require_ok Keeper_shutdown_store.error_to_string result

let operation_fixture keeper_name =
  let meta = require_ok Fun.id (Masc_test_deps.meta_of_json_fixture
    (`Assoc [ "name", `String keeper_name; "trace_id", `String "http-absence-original" ])) in
  let now = Masc_domain.now_iso () in
  { schema_version; revision = 1; operation_id = Operation_id.generate (); keeper_name
  ; lane_ownership = Dormant_meta
  ; trace_id = require_ok Fun.id (Keeper_id.Trace_id.of_string "http-absence-original")
  ; actor = "original-operator"
  ; cleanup_intent = { reason = Operator_stop_retain_meta; remove_session = false }
  ; turn_disposition = No_inflight_turn; expected_backlog_version = 0; owned_task_ids = []
  ; join_evidence = Some { lane_outcome = Lane_shutdown_requested
      ; terminal = Terminal_stopped; cleanup_error = None }
  ; phase = Finalized
      { cleanup = { settled_task_ids = []; pending_confirms_removed = 0
          ; meta_snapshot_digest = Keeper_meta_json.Snapshot_digest.of_meta meta }
      ; meta_removed = false; session_removed = false; registry_unregistered = true
      ; accumulator_dropped = true; completion = Completion_not_requested }
  ; created_at = now; updated_at = now }
;;

let with_fixture f =
  let base_path = Filename.temp_dir "keeper-shutdown-ack-http" "" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      Keeper_shutdown_intake_fence.For_testing.reset ();
      Fs_compat.clear_fs ();
      remove_tree base_path)
    (fun () -> Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run @@ fun sw ->
      let state = Mcp_server.For_testing.create_state ~base_path in
      let config = Mcp_server.workspace_config state in
      ignore (Workspace.init config ~agent_name:None);
      ignore (require_ok Keeper_owner_registry.install_error_to_string
        (Keeper_owner_registry.install_from_store ~sw ~operation_runner:None
          ~on_turn_slot_released:None config));
      Server_auth.For_testing.restore_server_state (Some state);
      Auth.save_auth_config base_path
        { Masc_domain.default_auth_config with enabled = true; require_token = true };
      let token agent_name role =
        fst (require_ok Masc_domain.masc_error_to_string (Auth.create_token base_path ~agent_name ~role)) in
      let admin = token "ack-admin" Masc_domain.Admin in
      let worker = token "ack-worker" Masc_domain.Worker in
      let router = Server_routes_http_routes_dashboard.add_routes ~sw
        ~clock:(Eio.Stdenv.clock env) (Http.Router.create ()) in
      let operation = operation_fixture "absent-http-owner" in
      store_ok (Keeper_shutdown_store.persist_new ~config operation);
      f ~config ~router ~operation ~admin ~worker)
;;

let path operation = Printf.sprintf
  "/api/v1/keepers/%s/shutdown-operations/%s/absence-acknowledgement"
  operation.keeper_name (Operation_id.to_string operation.operation_id)
;;

let http ~router ?token ~meth ~path ?(body = "") () =
  let output = Buffer.create 1024 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd) in
  let authorization = match token with
    | None -> "" | Some token -> "Authorization: Bearer " ^ token ^ "\r\n" in
  let raw_request = Printf.sprintf
    "%s %s HTTP/1.1\r\nHost: x\r\n%sX-Masc-Agent: spoofed-header-actor\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
    meth path authorization (String.length body) body in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
  let rec drain () = match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let bytes = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
        total + iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result connection (`Ok bytes); drain ()
    | `Yield | `Close _ -> () in
  drain ();
  let raw = Buffer.contents output in
  let status = int_of_string (List.nth (String.split_on_char ' ' raw) 1) in
  let rec body_offset index =
    if index + 4 > String.length raw then fail ("no HTTP body: " ^ raw)
    else if String.sub raw index 4 = "\r\n\r\n" then index + 4 else body_offset (index + 1) in
  let offset = body_offset 0 in
  status, Yojson.Safe.from_string (String.sub raw offset (String.length raw - offset))
;;

let request_fields preview =
  let open Yojson.Safe.Util in
  [ "schema", `String "masc.keeper_shutdown.absence_acknowledgement.request.v1"
  ; "expected_revision", member "expected_revision" preview
  ; "expected_backlog_version", member "expected_backlog_version" preview
  ; "reason", `String "Confirmed this retained shutdown has no remaining owner or work" ]
;;

let load ~config operation = store_ok (Keeper_shutdown_store.load ~config
  ~keeper_name:operation.keeper_name operation.operation_id)
;;

let test_real_router_requires_admin_for_preview_and_commit () =
  with_fixture (fun ~config ~router ~operation ~admin ~worker ->
    let path = path operation in
    List.iter (fun meth ->
      let status, _ = http ~router ~meth ~path () in
      check int "anonymous denied before handler" 401 status;
      let status, _ = http ~router ~token:"invalid-token" ~meth ~path () in
      check int "invalid bearer denied" 401 status;
      let status, _ = http ~router ~token:worker ~meth ~path () in
      check int "worker forbidden" 403 status) [ "GET"; "POST" ];
    let status, preview = http ~router ~token:admin ~meth:"GET" ~path () in
    check int "admin preview" 200 status;
    check bool "preview never authorizes eligibility" false
      Yojson.Safe.Util.(preview |> member "eligibility_checked" |> to_bool);
    check bool "preview is exact original evidence" true
      (Yojson.Safe.Util.member "operation" preview = Keeper_shutdown_store.to_json operation);
    let unknown_path = Printf.sprintf
      "/api/v1/keepers/%s/shutdown-operations/%s/absence-acknowledgement"
      operation.keeper_name (Operation_id.to_string (Operation_id.generate ())) in
    let status, _ = http ~router ~token:admin ~meth:"GET" ~path:unknown_path () in
    check int "preview requires the exact existing operation" 404 status;
    let status, _ = http ~router ~token:admin ~meth:"POST" ~path:unknown_path
      ~body:(Yojson.Safe.to_string (`Assoc (request_fields preview))) () in
    check int "commit cannot redirect an unknown operation identity" 404 status;
    check bool "unauthorized calls and preview do not mutate" true (load ~config operation = operation);
    check bool "suffix not accepted by exact route" true
      (Option.is_none (Api.route (path ^ "/extra"))))
;;

let test_commit_rechecks_preview_and_records_verified_actor () =
  with_fixture (fun ~config ~router ~operation ~admin ~worker:_ ->
    let path = path operation in
    let preview () =
      let status, json = http ~router ~token:admin ~meth:"GET" ~path () in
      check int "preview succeeds" 200 status; json in
    let first = preview () in
    let fields = request_fields first in
    let post fields = http ~router ~token:admin ~meth:"POST" ~path
      ~body:(Yojson.Safe.to_string (`Assoc fields)) () in
    List.iter (fun malformed ->
      let status, _ = post malformed in
      check int "strict body rejected" 400 status)
      [ ("actor", `String "spoofed-body-actor") :: fields
      ; ("expected_revision", `Int 1) :: fields
      ; List.remove_assoc "reason" fields
      ; ("reason", `String "  ") :: List.remove_assoc "reason" fields
      ; ("expected_revision", `String "1") :: List.remove_assoc "expected_revision" fields ];
    let status, _ = post (("expected_revision", `Int 0) :: List.remove_assoc "expected_revision" fields) in
    check int "stale exact operation revision" 409 status;
    let backlog = require_ok Fun.id (Workspace_backlog.read_backlog_r config) in
    Workspace_backlog.write_backlog config backlog;
    let status, _ = post fields in
    check int "stale authoritative backlog version" 409 status;
    let current_fields = request_fields (preview ()) in
    let metadata = Keeper_types_profile.keeper_meta_path config operation.keeper_name in
    Out_channel.with_open_bin metadata (fun channel -> output_string channel "a new physical owner observation");
    let status, _ = post current_fields in
    check int "new metadata after preview refuses commit" 409 status;
    check bool "all refusals preserve original shutdown evidence" true (load ~config operation = operation);
    Unix.unlink metadata;
    let status, response = post current_fields in
    check int "authorized commit" 200 status;
    let acknowledged = load ~config operation in
    check bool "HTTP result matches persisted record" true
      (Yojson.Safe.Util.member "operation" response = Keeper_shutdown_store.to_json acknowledged);
    (match acknowledged.phase, operation.phase with
     | Operator_absence_acknowledged ack, Finalized original ->
       check string "actor is verified bearer owner" "ack-admin" ack.actor;
       check bool "original retained finalization unchanged" true (ack.finalization = original);
       check bool "does not manufacture removal" false ack.finalization.meta_removed
     | _ -> fail "missing durable acknowledgement");
    let status, repeated = post current_fields in
    check int "same operator request can retry" 200 status;
    check string "retry result is explicit" "already_acknowledged"
      Yojson.Safe.Util.(repeated |> member "status" |> to_string);
    check bool "retry leaves evidence unchanged" true (load ~config operation = acknowledged))
;;

let () = run "keeper shutdown acknowledgement HTTP"
  [ "actual router", [ test_case "admin authorization and observational preview" `Quick
        test_real_router_requires_admin_for_preview_and_commit
    ; test_case "preview recheck and verified actor commit" `Quick
        test_commit_rechecks_preview_and_records_verified_actor ] ]
