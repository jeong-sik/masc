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
       Keeper_shutdown_finalize.register_remove_pending_confirms_by_target
         (fun _config ~target_type:_ ~target_id:_ -> Ok 0);
       Keeper_shutdown_finalize.register_completion_handler
         (fun config operation action ->
           match action with
           | Dashboard_keeper_purged ->
             let toml_path =
               Filename.concat
                 (Config_dir_resolver.keepers_dir_for_base_path
                    ~base_path:config.Workspace.base_path)
                 (operation.Keeper_shutdown_types.keeper_name ^ ".toml")
             in
             (try
                if Fs_compat.file_exists toml_path then Unix.unlink toml_path;
                Ok ()
              with exn -> Error (Printexc.to_string exn))
           | Supervisor_cleaned -> Ok ());
       Fun.protect
         ~finally:(fun () ->
           Keeper_shutdown_finalize.For_testing
           .reset_remove_pending_confirms_by_target ();
           Keeper_shutdown_finalize.For_testing.reset_completion_handler ();
           Keeper_shutdown_blocked_purge_release.For_testing.reset_audit_writer ();
           Fs_compat.clear_fs ())
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

let reissue_store_exn ~config operation =
  match
    Keeper_shutdown_store.reissue_blocked_dashboard_purge
      ~config
      ~keeper_name
      ~operation_id:operation.operation_id
      ~expected_revision:operation.revision
      ~actor:"operator"
      ~reason:"test exact reissue"
      ~now:Masc_domain.now_iso
  with
  | Ok (Purge_reissue_persisted reissued | Purge_reissue_already_persisted reissued) ->
    reissued
  | Error error ->
    failf
      "blocked purge refused exact reissue: %s"
      (Keeper_shutdown_store.error_to_string error)
;;

let test_reissue_keeps_the_admission_fence () =
  with_workspace (fun ~config ->
    let operation = make_operation ~cleanup_intent:purge_intent ~phase:interrupted_lane_join in
    persist_exn ~config operation;
    check bool "a blocked purge holds the fence" true
      (requires_admission_fence operation);
    let reissued = reissue_store_exn ~config operation in
    check bool "exact reissue keeps it" true (requires_admission_fence reissued))
;;

let test_reissue_is_recorded_in_join_evidence () =
  with_workspace (fun ~config ->
    let operation = make_operation ~cleanup_intent:purge_intent ~phase:interrupted_lane_join in
    persist_exn ~config operation;
    let reissued = reissue_store_exn ~config operation in
    match reissued.phase, reissued.join_evidence with
    | ( Joined_idle
      , Some
          { lane_outcome =
              Lane_operator_purge_reissue
                { actor; reason = "test exact reissue"; expected_revision = 1 }
          ; _
          } ) ->
      check string "records the operator" "operator" actor
    | _ -> fail "the exact reissue audit was not persisted")
;;

let test_reissue_survives_a_reload () =
  with_workspace (fun ~config ->
    let operation = make_operation ~cleanup_intent:purge_intent ~phase:interrupted_lane_join in
    persist_exn ~config operation;
    let (_reissued : Keeper_shutdown_types.t) = reissue_store_exn ~config operation in
    match Keeper_shutdown_store.load ~config ~keeper_name operation.operation_id with
    | Error error ->
      failf "reissued purge did not load: %s" (Keeper_shutdown_store.error_to_string error)
    | Ok reloaded ->
      check bool "still fenced after reload" true (requires_admission_fence reloaded))
;;

let test_operator_stop_reissue_is_refused () =
  with_workspace (fun ~config ->
    let operation = make_operation ~cleanup_intent:stop_intent ~phase:interrupted_lane_join in
    persist_exn ~config operation;
    match
      Keeper_shutdown_store.reissue_blocked_dashboard_purge
        ~config
        ~keeper_name
        ~operation_id:operation.operation_id
        ~expected_revision:operation.revision
        ~actor:"operator"
        ~reason:"must fail"
        ~now:Masc_domain.now_iso
    with
    | Error (Supersession_intent_mismatch _) -> ()
    | Error error -> fail (Keeper_shutdown_store.error_to_string error)
    | Ok _ -> fail "operator stop was reissued as a purge")
;;

let live_release_command operation =
  { Keeper_shutdown_blocked_purge_release.keeper_id = operation.keeper_name
  ; operation_id = operation.operation_id
  ; expected_revision = operation.revision
  ; reason = "incident rw-e0: recover failed lane join with exact purge reissue"
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

let live_shaped_operation () =
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
;;

let write_live_toml ~config =
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Workspace.base_path
  in
  Fs_compat.mkdir_p keepers_dir;
  let toml_path = Filename.concat keepers_dir (keeper_name ^ ".toml") in
  Fs_compat.save_file
    toml_path
    (Printf.sprintf
       "[keeper]\nname = %S\ninstructions = %S\nsandbox_profile = \"local\"\nautoboot_enabled = true\nproactive_enabled = true\n"
       keeper_name
       "finish the exact blocked purge only");
  toml_path
;;

let persist_live_fixture ~config =
  let operation = live_shaped_operation () in
  let toml_path = write_live_toml ~config in
  persist_exn ~config operation;
  restore_live_fence_exn ~config operation;
  operation, toml_path
;;

(* Mirrors the two live P0 records: revision 2, registered lane, dashboard
   purge, no meta.json, surviving TOML, and an ownerless intake fence. The
   public command must persist revision 3 while keeping that actual fence,
   then release it only after durable finalization. *)
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
    Fs_compat.save_file
      toml_path
      (Printf.sprintf
         "[keeper]\nname = %S\ninstructions = %S\nsandbox_profile = \"local\"\nautoboot_enabled = true\nproactive_enabled = true\n"
         keeper_name
         "finish the exact blocked purge only");
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
    let path = "/api/v1/dashboard/agents/purge/reissue" in
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
         check int "anonymous reissue denied" 401 (status_of_response anonymous);
         let worker =
           dispatch_with_body
             router
             (post_request ~path ~token:worker_token body)
             body
         in
         check int "Worker reissue denied" 403 (status_of_response worker);
         let admin =
           dispatch_with_body
             router
             (post_request ~path ~token:admin_token body)
             body
         in
         if status_of_response admin <> 200
         then failf "Admin reissue response: %s" admin);
    let released =
      match Keeper_shutdown_store.load ~config ~keeper_name operation.operation_id with
      | Ok operation -> operation
      | Error error -> fail (Keeper_shutdown_store.error_to_string error)
    in
    check bool "finalization advanced revisions" true (released.revision > 3);
    (match released.phase, released.join_evidence with
     | ( Finalized _
       , Some
           { lane_outcome =
               Lane_operator_purge_reissue
                 { actor; reason; expected_revision }
           ; _
           } ) ->
       check string "authenticated actor persisted" "purge-operator" actor;
       check string "operator reason persisted" command.reason reason;
       check int "observed revision persisted" 2 expected_revision
     | _ -> fail "reissue did not finalize with its typed audit");
    check
      bool
      "immutable operator audit persisted"
      true
      (Audit_log.read_entries config
       |> List.exists (fun (entry : Audit_log.audit_entry) ->
         match entry.action with
         | Audit_log.Custom "keeper_blocked_purge_reissue" ->
           String.equal entry.agent_id "purge-operator"
           && Yojson.Safe.Util.member "expected_revision" entry.details = `Int 2
           && Yojson.Safe.Util.member "reason" entry.details
              = `String command.reason
         | _ -> false));
    check
      (option string)
      "admission opens only after exact purge finalization"
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
    check bool "exact retry is idempotent" true replayed.already_reissued;
    check bool "surviving TOML was purged" false (Fs_compat.file_exists toml_path);
    match Keeper_meta_store.read_meta config keeper_name with
    | Ok None -> ()
    | Ok (Some _) -> fail "reissued purge left materialized metadata"
    | Error detail -> failf "post-purge meta lookup failed: %s" detail)
;;

let test_crash_after_reissue_keeps_exact_fence_and_retry_finishes () =
  with_workspace (fun ~config ->
    Eio.Switch.run @@ fun sw ->
    install_empty_owner_inventory_exn ~config ~sw;
    let operation, _toml_path = persist_live_fixture ~config in
    let command = live_release_command operation in
    Keeper_shutdown_blocked_purge_release.For_testing.fail_next_after_reissue
      "injected crash after durable reissue";
    (match
       Keeper_shutdown_blocked_purge_release.execute
         ~config
         ~actor:"purge-operator"
         command
     with
     | Error (Injected_after_reissue _) -> ()
     | Error error ->
       failf
         "wrong crash-window result: %s"
         (Keeper_shutdown_blocked_purge_release.error_to_string error)
     | Ok _ -> fail "injected post-reissue crash returned success");
    let current =
      match Keeper_shutdown_store.load ~config ~keeper_name operation.operation_id with
      | Ok operation -> operation
      | Error error -> fail (Keeper_shutdown_store.error_to_string error)
    in
    (match current.phase, current.join_evidence with
     | ( Joined_idle
       , Some { lane_outcome = Lane_operator_purge_reissue _; _ } ) -> ()
     | _ -> fail "crash window did not retain durable reissue intent");
    check
      (option string)
      "same operation remains the fence"
      (Some (Operation_id.to_string operation.operation_id))
      (Keeper_shutdown_intake_fence.shutdown_operation_id
         ~base_path:config.base_path
         ~keeper_name
       |> Option.map Operation_id.to_string);
    (match
       Keeper_owner_registry.get
         ~base_path:config.base_path
         ~keeper_name
     with
     | Error error -> fail (Keeper_owner_registry.lookup_error_to_string error)
     | Ok owner ->
       (match Keeper_owner.exact_projection owner with
        | Ok { meta = Some meta; _ } ->
       check bool "recovery meta is paused" true meta.paused;
       check bool "recovery meta disables proactive" false meta.proactive.enabled;
       check bool "recovery meta disables autoboot" false meta.autoboot_enabled
        | Ok { meta = None; _ } -> fail "crash window lost recovery metadata"
        | Error error -> fail (Keeper_owner.error_to_string error)));
    (match
       Keeper_shutdown_intake_fence.run_durable_intake_if_open
         ~base_path:config.base_path
         ~keeper_name
         (fun _ -> `Unexpectedly_admitted)
     with
     | Keeper_shutdown_intake_fence.Intake_shutdown_reserved existing ->
       check
         string
         "ordinary supervisor/create intake sees exact fence"
         (Operation_id.to_string operation.operation_id)
         (Operation_id.to_string existing)
     | Intake_committed _ -> fail "ordinary intake crossed the reissue fence");
    (match Keeper_runtime.autoboot_exclusion_reason config keeper_name with
     | Some Keeper_runtime.Shutdown_admission_fence
     | Some Keeper_runtime.Paused -> ()
     | Some reason ->
       failf
         "wrong autoboot exclusion: %s"
         (Keeper_runtime.autoboot_exclusion_reason_to_string reason)
     | None -> fail "default autoboot ignored the exact shutdown fence");
    check
      bool
      "supervisor boot set excludes the fenced Keeper"
      false
      (List.mem keeper_name (Keeper_runtime.bootable_keeper_names config));
    match
      Keeper_shutdown_blocked_purge_release.execute
        ~config
        ~actor:"purge-operator"
        command
    with
    | Ok { operation = { phase = Finalized _; _ }; already_reissued = true } ->
      check
        (option string)
        "retry releases only after finalization"
        None
        (Keeper_shutdown_intake_fence.shutdown_operation_id
           ~base_path:config.base_path
           ~keeper_name
         |> Option.map Operation_id.to_string)
    | Ok _ -> fail "crash-window retry did not finalize idempotently"
    | Error error ->
      failf
        "crash-window retry failed: %s"
        (Keeper_shutdown_blocked_purge_release.error_to_string error))
;;

let test_audit_failure_is_http_error_and_identical_retry_repairs () =
  with_workspace (fun ~config ->
    Eio.Switch.run @@ fun sw ->
    install_empty_owner_inventory_exn ~config ~sw;
    let operation, _toml_path = persist_live_fixture ~config in
    let auth_config =
      { Masc_domain.default_auth_config with enabled = true; require_token = true }
    in
    Auth.save_auth_config config.base_path auth_config;
    let admin_token =
      create_token_exn
        config.base_path
        ~agent_name:"purge-audit-operator"
        ~role:Masc_domain.Admin
    in
    let command = live_release_command operation in
    let body = release_command_json command in
    let path = "/api/v1/dashboard/agents/purge/reissue" in
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
         Keeper_shutdown_blocked_purge_release.For_testing.fail_next_audit_write
           "injected immutable audit append failure";
         let first =
           dispatch_with_body
             router
             (post_request ~path ~token:admin_token body)
             body
         in
         check int "audit failure is not success" 500 (status_of_response first);
         check
           bool
           "audit failure response is fail closed"
           true
           (Astring.String.is_infix ~affix:"\"ok\":false" first);
         let durable =
           match Keeper_shutdown_store.load ~config ~keeper_name operation.operation_id with
           | Ok operation -> operation
           | Error error -> fail (Keeper_shutdown_store.error_to_string error)
         in
         (match durable.join_evidence with
          | Some
              { lane_outcome =
                  Lane_operator_purge_reissue
                    { actor = "purge-audit-operator"; expected_revision = 2; _ }
              ; _
              } -> ()
          | _ -> fail "audit failure lost authoritative operation intent");
         let retry =
           dispatch_with_body
             router
             (post_request ~path ~token:admin_token body)
             body
         in
         check int "identical retry repairs audit" 200 (status_of_response retry);
         check
           bool
           "success reports durable audit"
           true
           (Astring.String.is_infix ~affix:"\"audit_durable\":true" retry));
    check
      bool
      "retry persisted immutable audit row"
      true
      (Audit_log.read_entries config
       |> List.exists (fun (entry : Audit_log.audit_entry) ->
         match entry.action with
         | Audit_log.Custom "keeper_blocked_purge_reissue" ->
           String.equal entry.agent_id "purge-audit-operator"
         | _ -> false)))
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
    | Error (Profile_materialization_failed _) ->
      (match Keeper_shutdown_store.load ~config ~keeper_name operation.operation_id with
       | Ok { phase = Blocked _; revision = 2; _ } -> ()
       | Ok _ -> fail "non-purge operation changed despite fail-closed reissue"
       | Error error -> fail (Keeper_shutdown_store.error_to_string error))
    | Error error ->
      failf
        "non-purge failed with wrong error: %s"
        (Keeper_shutdown_blocked_purge_release.error_to_string error)
    | Ok _ -> fail "operator-stop record passed the purge-only reissue")
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
    [ ( "operator reissue"
      , [ test_case "keeps the admission fence" `Quick test_reissue_keeps_the_admission_fence
        ; test_case
            "records exact reissue evidence"
            `Quick
            test_reissue_is_recorded_in_join_evidence
        ; test_case "survives a reload" `Quick test_reissue_survives_a_reload
        ; test_case
            "refuses operator stop"
            `Quick
            test_operator_stop_reissue_is_refused
        ; test_case
            "releases live-shaped missing-meta fence"
            `Quick
            test_missing_meta_live_shape_releases_exact_fence
        ; test_case
            "recovers the post-reissue crash window"
            `Quick
            test_crash_after_reissue_keeps_exact_fence_and_retry_finishes
        ; test_case
            "fails closed and repairs an audit write"
            `Quick
            test_audit_failure_is_http_error_and_identical_retry_repairs
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
