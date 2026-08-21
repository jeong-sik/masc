(* A dashboard purge whose worker died in [Joining_lanes] is recovered as
   [Blocked Lane_join], which keeps the admission fence. Nothing then moved it:
   the fence stopped the Keeper's meta being materialized, [resolve] needs that
   meta to build a purge target, and supersession admitted no intent but
   [Operator_stop_retain_meta]. Three keepers sat half-purged from 2026-08-19,
   with reconcile re-attempting ~238 times an hour and the dashboard answering
   every retry with "accepted" — the same no-exit shape #25491 fixed for
   [Reconciliation_required], reached through a different pair. *)

open Alcotest
open Masc
open Keeper_shutdown_types

module Http = Http_server_eio

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir path =
  let rec rm p =
    match Unix.lstat p with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> rm (Filename.concat p name)) (Sys.readdir p);
      Unix.rmdir p
    | _ -> Unix.unlink p
    | exception Unix.Unix_error _ -> ()
  in
  rm path
;;

let create_token_exn base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok (raw_token, _) -> raw_token
  | Error error -> fail (Masc_domain.masc_error_to_string error)
;;

let post_request ~path ?token body =
  let headers =
    [ "host", "localhost"
    ; "content-type", "application/json"
    ; "content-length", string_of_int (String.length body)
    ]
  in
  let headers =
    match token with
    | None -> headers
    | Some value -> ("authorization", "Bearer " ^ value) :: headers
  in
  Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `POST path
;;

let dispatch_with_body router request body =
  let response_buf = Buffer.create 1024 in
  let conn =
    Httpun.Server_connection.create (fun reqd ->
      Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
  in
  let request_head =
    Printf.sprintf
      "%s %s HTTP/1.1\r\n%s%s"
      (Httpun.Method.to_string request.Httpun.Request.meth)
      request.Httpun.Request.target
      (Httpun.Headers.to_string request.Httpun.Request.headers)
      body
  in
  let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request_head) request_head in
  let rec feed off =
    let remaining = Bigstringaf.length bytes - off in
    if remaining > 0
    then (
      let consumed = Httpun.Server_connection.read conn bytes ~off ~len:remaining in
      if consumed <= 0 then fail "httpun test feed made no progress";
      feed (off + consumed))
  in
  feed 0;
  let rec flush () =
    match Httpun.Server_connection.next_write_operation conn with
    | `Write iovecs ->
      List.iter
        (fun (iov : Bigstringaf.t Httpun.IOVec.t) ->
           Buffer.add_string
             response_buf
             (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len))
        iovecs;
      let written =
        List.fold_left
          (fun total (iov : Bigstringaf.t Httpun.IOVec.t) -> total + iov.len)
          0
          iovecs
      in
      Httpun.Server_connection.report_write_result conn (`Ok written);
      flush ()
    | `Yield | `Close _ -> ()
  in
  flush ();
  Buffer.contents response_buf
;;

let status_of_response response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | _ -> failf "could not parse response status: %S" response
;;

let with_workspace f =
  let base = temp_dir "keeper_shutdown_blocked_purge_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       Fun.protect
         ~finally:(fun () -> Fs_compat.clear_fs ())
         (fun () ->
            let config = Workspace.default_config base in
            let (_init_msg : string) = Workspace.init config ~agent_name:None in
            f ~config))
;;

let trace_id_exn value =
  match Keeper_id.Trace_id.of_string value with
  | Ok trace_id -> trace_id
  | Error detail -> failf "trace id rejected: %s" detail
;;

let lane_id_exn value =
  match Keeper_lane.Id.of_string value with
  | Ok lane_id -> lane_id
  | Error detail -> failf "lane id rejected: %s" detail
;;

let keeper_name = "rw-e0-blocked-purge"

let purge_intent =
  { reason =
      Dashboard_keeper_purge
        { requested_name = keeper_name
        ; agent_name = Printf.sprintf "keeper-%s-agent" keeper_name
        }
  ; remove_session = true
  }
;;

let stop_intent = { reason = Operator_stop_retain_meta; remove_session = false }

let interrupted_lane_join =
  Blocked
    { stage = Lane_join
    ; detail = "server process ended while joining Keeper and Librarian lanes"
    }
;;

let make_operation ~cleanup_intent ~phase =
  { schema_version = Keeper_shutdown_types.schema_version
  ; revision = 1
  ; operation_id = Operation_id.generate ()
  ; keeper_name
  ; lane_ownership = Dormant_meta
  ; trace_id = trace_id_exn "trace-blocked-purge-release-test"
  ; generation = 1
  ; actor = "dashboard"
  ; cleanup_intent
  ; turn_disposition = No_inflight_turn
  ; expected_backlog_version = 0
  ; owned_task_ids = []
  ; join_evidence = None
  ; phase
  ; created_at = Masc_domain.now_iso ()
  ; updated_at = Masc_domain.now_iso ()
  }
;;

let persist_exn ~config operation =
  match Keeper_shutdown_store.persist_new ~config operation with
  | Ok () -> ()
  | Error error ->
    failf "persist_new failed: %s" (Keeper_shutdown_store.error_to_string error)
;;

let release_exn ~config operation =
  match
    Keeper_shutdown_store.prepare_operator_metadata_supersession
      ~config
      ~keeper_name
      ~operation_id:operation.operation_id
      ~actor:"operator"
  with
  | Error error ->
    failf
      "blocked purge refused a supersession token: %s"
      (Keeper_shutdown_store.error_to_string error)
  | Ok token ->
    (match
       Keeper_shutdown_store.supersede_blocked_operator_stop
         ~config
         ~token
         ~now:Masc_domain.now_iso
     with
     | Ok (Superseded_persisted released | Superseded_already_persisted released) ->
       released
     | Error error ->
       failf
         "supersession did not persist: %s"
         (Keeper_shutdown_store.error_to_string error))
;;

(* The fence is the whole wedge: while it is held nothing else can move, so a
   release that only rewrites the phase would leave the Keeper exactly as
   stuck. *)
let test_release_frees_the_admission_fence () =
  with_workspace (fun ~config ->
    let operation = make_operation ~cleanup_intent:purge_intent ~phase:interrupted_lane_join in
    persist_exn ~config operation;
    check bool "a blocked purge holds the fence" true
      (requires_admission_fence operation);
    let released = release_exn ~config operation in
    check bool "the release frees it" false (requires_admission_fence released))
;;

(* The durable record has to say which release was signed off. Recording a
   purge release as [Operator_metadata_update] would claim an operator updated
   metadata that a purge deletes. *)
let test_release_is_recorded_as_a_purge_release () =
  with_workspace (fun ~config ->
    let operation = make_operation ~cleanup_intent:purge_intent ~phase:interrupted_lane_join in
    persist_exn ~config operation;
    let released = release_exn ~config operation in
    match released.phase with
    | Superseded (Operator_blocked_purge_released { actor; _ }) ->
      check string "records the operator" "operator" actor
    | Superseded (Operator_metadata_update _) ->
      fail "a purge release was recorded as a metadata update"
    | Superseded (Operator_reconciliation_accepted _) ->
      fail "a purge release was recorded as a reconciliation acceptance"
    | Prepared | Joining_lanes | Joined_idle | Finalizing_tasks _ | Cleanup_ready _
    | Reconciliation_required _ | Finalized _ | Blocked _ ->
      fail "the blocked purge was not superseded")
;;

(* Reloading proves the new supersession survives the codec: a release that
   cannot be read back reappears as [Blocked] on the next boot. *)
let test_release_survives_a_reload () =
  with_workspace (fun ~config ->
    let operation = make_operation ~cleanup_intent:purge_intent ~phase:interrupted_lane_join in
    persist_exn ~config operation;
    let (_released : Keeper_shutdown_types.t) = release_exn ~config operation in
    match Keeper_shutdown_store.load ~config ~keeper_name operation.operation_id with
    | Error error ->
      failf "released purge did not load: %s" (Keeper_shutdown_store.error_to_string error)
    | Ok reloaded ->
      (match reloaded.phase with
       | Superseded (Operator_blocked_purge_released _) ->
         check bool "still unfenced after a reload" false
           (requires_admission_fence reloaded)
       | _ -> fail "the reloaded phase was not a purge release"))
;;

(* The release exists for a purge, so it must not become a way around the
   metadata-update route: an operator stop still records its own supersession. *)
let test_operator_stop_release_is_unchanged () =
  with_workspace (fun ~config ->
    let operation = make_operation ~cleanup_intent:stop_intent ~phase:interrupted_lane_join in
    persist_exn ~config operation;
    let released = release_exn ~config operation in
    match released.phase with
    | Superseded (Operator_metadata_update _) -> ()
    | Superseded (Operator_blocked_purge_released _) ->
      fail "an operator stop was recorded as a purge release"
    | _ -> fail "the blocked operator stop was not superseded")
;;

let live_release_command operation =
  { Keeper_shutdown_blocked_purge_release.keeper_id = operation.keeper_name
  ; operation_id = operation.operation_id
  ; expected_revision = operation.revision
  ; reason = "incident rw-e0: release failed lane join before exact purge reissue"
  }
;;

let release_command_json command =
  `Assoc
    [ "schema", `String Keeper_shutdown_blocked_purge_release.command_schema
    ; "keeper_id", `String command.Keeper_shutdown_blocked_purge_release.keeper_id
    ; ( "operation_id"
      , `String (Operation_id.to_string command.operation_id) )
    ; "expected_revision", `Int command.expected_revision
    ; "reason", `String command.reason
    ]
  |> Yojson.Safe.to_string
;;

let install_empty_owner_inventory_exn ~config ~sw =
  match
    Keeper_owner_registry.install_from_store
      ~sw
      ~operation_runner:None
      ~on_turn_slot_released:None
      config
  with
  | Ok 0 -> ()
  | Ok count -> failf "missing-meta fixture unexpectedly installed %d owner(s)" count
  | Error error -> fail (Keeper_owner_registry.install_error_to_string error)
;;

let restore_live_fence_exn ~config operation =
  match Keeper_shutdown_runtime.recover_at_boot ~config with
  | [ Ok recovered ] ->
    check
      string
      "boot recovered exact operation"
      (Operation_id.to_string operation.operation_id)
      (Operation_id.to_string recovered.operation_id)
  | [ Error detail ] -> failf "live-shaped blocked purge recovery failed: %s" detail
  | outcomes -> failf "unexpected recovery outcome count: %d" (List.length outcomes)
;;

(* Mirrors the two live P0 records: revision 2, registered lane, dashboard
   purge, no meta.json, surviving TOML, and an ownerless intake fence. The
   public command must persist revision 3 and release that actual fence; merely
   changing [requires_admission_fence] on an in-memory value is insufficient. *)
let test_missing_meta_live_shape_releases_exact_fence () =
  with_workspace (fun ~config ->
    Eio.Switch.run @@ fun sw ->
    install_empty_owner_inventory_exn ~config ~sw;
    let auth_config =
      { Masc_domain.default_auth_config with enabled = true; require_token = true }
    in
    Auth.save_auth_config config.base_path auth_config;
    let worker_token =
      create_token_exn
        config.base_path
        ~agent_name:"purge-worker"
        ~role:Masc_domain.Worker
    in
    let admin_token =
      create_token_exn
        config.base_path
        ~agent_name:"purge-operator"
        ~role:Masc_domain.Admin
    in
    let operation =
      { (make_operation
           ~cleanup_intent:purge_intent
           ~phase:interrupted_lane_join) with
        revision = 2
      ; lane_ownership =
          Registered_lane
            (lane_id_exn "lane-ec166371-dc82-41dc-81df-1fd9ffcc7c39")
      ; actor = "dashboard"
      ; expected_backlog_version = 3839
      }
    in
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path
        ~base_path:config.Workspace.base_path
    in
    Fs_compat.mkdir_p keepers_dir;
    let toml_path = Filename.concat keepers_dir (keeper_name ^ ".toml") in
    Fs_compat.save_file toml_path (Printf.sprintf "[keeper]\nname = %S\n" keeper_name);
    check bool "live-shaped TOML survives" true (Fs_compat.file_exists toml_path);
    (match Keeper_meta_store.read_meta config keeper_name with
     | Ok None -> ()
     | Ok (Some _) -> fail "live-shaped fixture unexpectedly has meta.json"
     | Error detail -> failf "meta lookup failed: %s" detail);
    persist_exn ~config operation;
    restore_live_fence_exn ~config operation;
    check
      (option string)
      "exact ownerless intake fence is installed"
      (Some (Operation_id.to_string operation.operation_id))
      (Keeper_shutdown_intake_fence.shutdown_operation_id
         ~base_path:config.base_path
         ~keeper_name
       |> Option.map Operation_id.to_string);
    let command = live_release_command operation in
    let body = release_command_json command in
    let path = "/api/v1/dashboard/agents/purge/release" in
    let saved_state = Server_auth.For_testing.snapshot_server_state () in
    Fun.protect
      ~finally:(fun () -> Server_auth.For_testing.restore_server_state saved_state)
      (fun () ->
         Server_auth.For_testing.restore_server_state
           (Some (Mcp_server.For_testing.create_state ~base_path:config.base_path));
         let router =
           Server_dashboard_http_delete_actions.add_delete_action_routes
             (Http.Router.create ())
         in
         let anonymous =
           dispatch_with_body router (post_request ~path body) body
         in
         check int "anonymous release denied" 401 (status_of_response anonymous);
         let worker =
           dispatch_with_body
             router
             (post_request ~path ~token:worker_token body)
             body
         in
         check int "Worker release denied" 403 (status_of_response worker);
         let admin =
           dispatch_with_body
             router
             (post_request ~path ~token:admin_token body)
             body
         in
         check int "Admin release accepted" 200 (status_of_response admin));
    let released =
      match Keeper_shutdown_store.load ~config ~keeper_name operation.operation_id with
      | Ok operation -> operation
      | Error error -> fail (Keeper_shutdown_store.error_to_string error)
    in
    check int "release advances exact revision" 3 released.revision;
    (match released.phase with
     | Superseded
         (Operator_blocked_purge_released
            { actor; reason; expected_revision }) ->
       check string "authenticated actor persisted" "purge-operator" actor;
       check string "operator reason persisted" command.reason reason;
       check int "observed revision persisted" 2 expected_revision
     | _ -> fail "release did not persist its typed audit");
    check
      bool
      "immutable operator audit persisted"
      true
      (Audit_log.read_entries config
       |> List.exists (fun (entry : Audit_log.audit_entry) ->
         match entry.action with
         | Audit_log.Custom "keeper_blocked_purge_release" ->
           String.equal entry.agent_id "purge-operator"
           && Yojson.Safe.Util.member "expected_revision" entry.details = `Int 2
           && Yojson.Safe.Util.member "reason" entry.details
              = `String command.reason
         | _ -> false));
    check
      (option string)
      "ownerless intake fence is actually open"
      None
      (Keeper_shutdown_intake_fence.shutdown_operation_id
         ~base_path:config.base_path
         ~keeper_name
       |> Option.map Operation_id.to_string);
    let replayed =
      match
        Keeper_shutdown_blocked_purge_release.execute
          ~config
          ~actor:"purge-operator"
          command
      with
      | Ok released -> released
      | Error error ->
        failf
          "exact command retry failed: %s"
          (Keeper_shutdown_blocked_purge_release.error_to_string error)
    in
    check bool "exact retry is idempotent" true replayed.already_released)
;;

let test_non_purge_is_refused_and_stays_fenced () =
  with_workspace (fun ~config ->
    let operation =
      { (make_operation
           ~cleanup_intent:stop_intent
           ~phase:interrupted_lane_join) with
        revision = 2
      }
    in
    persist_exn ~config operation;
    match
      Keeper_shutdown_blocked_purge_release.execute
        ~config
        ~actor:"operator"
        (live_release_command operation)
    with
    | Error (Store_release_failed (Keeper_shutdown_store.Supersession_intent_mismatch _)) ->
      (match Keeper_shutdown_store.load ~config ~keeper_name operation.operation_id with
       | Ok { phase = Blocked _; revision = 2; _ } -> ()
       | Ok _ -> fail "non-purge operation changed despite fail-closed release"
       | Error error -> fail (Keeper_shutdown_store.error_to_string error))
    | Error error ->
      failf
        "non-purge failed with wrong error: %s"
        (Keeper_shutdown_blocked_purge_release.error_to_string error)
    | Ok _ -> fail "operator-stop record passed the purge-only release")
;;

let test_command_requires_exact_shape () =
  let json =
    `Assoc
      [ "schema", `String Keeper_shutdown_blocked_purge_release.command_schema
      ; "keeper_id", `String keeper_name
      ; "operation_id", `String (Operation_id.to_string (Operation_id.generate ()))
      ; "expected_revision", `Int 2
      ; "reason", `String "incident release"
      ; "reason", `String "duplicate must fail"
      ]
  in
  match Keeper_shutdown_blocked_purge_release.parse_command json with
  | Error (Duplicate_fields [ "reason" ]) -> ()
  | Error error ->
    failf
      "exact-shape parser returned wrong error: %s"
      (Keeper_shutdown_blocked_purge_release.input_error_to_string error)
  | Ok _ -> fail "duplicate command field was accepted"
;;

let () =
  run
    "keeper-shutdown-blocked-purge-release"
    [ ( "operator release"
      , [ test_case "frees the admission fence" `Quick test_release_frees_the_admission_fence
        ; test_case
            "is recorded as a purge release"
            `Quick
            test_release_is_recorded_as_a_purge_release
        ; test_case "survives a reload" `Quick test_release_survives_a_reload
        ; test_case
            "leaves the operator-stop route alone"
            `Quick
            test_operator_stop_release_is_unchanged
        ; test_case
            "releases live-shaped missing-meta fence"
            `Quick
            test_missing_meta_live_shape_releases_exact_fence
        ; test_case
            "refuses a non-purge operation"
            `Quick
            test_non_purge_is_refused_and_stays_fenced
        ; test_case
            "requires an exact command shape"
            `Quick
            test_command_requires_exact_shape
        ] )
    ]
;;
