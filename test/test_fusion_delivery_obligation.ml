open Alcotest
open Masc

module Obligation = Fusion_delivery_obligation

let () = Mirage_crypto_rng_unix.use_default ()

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""
;;

let with_temp_base f =
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "fusion-obligation-%d-%06x" (Unix.getpid ()) (Random.bits ()))
  in
  let old_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  let old_base_path_input = Sys.getenv_opt "MASC_BASE_PATH_INPUT" in
  let old_registry = Fusion_run_registry.global () in
  Unix.mkdir base_path 0o700;
  Unix.putenv "MASC_BASE_PATH" base_path;
  Unix.putenv "MASC_BASE_PATH_INPUT" base_path;
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Fusion_run_registry.set_global (Fusion_run_registry.create ());
  Fun.protect
    ~finally:(fun () ->
      Fusion_run_registry.set_global old_registry;
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      restore_env "MASC_BASE_PATH" old_base_path;
      restore_env "MASC_BASE_PATH_INPUT" old_base_path_input;
      remove_tree base_path)
    (fun () -> f base_path)
;;

let expect_ok = function
  | Ok value -> value
  | Error error -> fail (Obligation.error_to_string error)
;;

let request_id value =
  match Obligation.Request_id.of_string value with
  | Ok request_id -> request_id
  | Error detail -> fail detail
;;

let channel =
  Keeper_continuation_channel.discord
    ~guild_id:(Some "guild-1")
    ~channel_id:"channel-1"
    ~parent_channel_id:None
    ~thread_id:(Some "thread-1")
    ~user_id:"user-1"
  |> function
  | Ok channel -> channel
  | Error detail -> fail detail
;;

let payload ?(prompt = "compare implementations") () : Obligation.accepted_payload =
  { keeper_name = "analyst"
  ; submitted_by = "analyst"
  ; prompt
  ; preset = "council"
  ; web_tools = false
  ; topology = Fusion_types.Judge_of_judges
  ; channel
  }
;;

let test_exact_prepare_load_inventory_remove () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let request_id = request_id "kmsg-fusion-1" in
      let first =
        Obligation.prepare ~base_path ~request_id ~payload:(payload ())
          ~accepted_at:1.0
        |> expect_ok
      in
      let identity =
        match first with
        | Obligation.Prepared identity -> identity
        | Obligation.Already_present _ -> fail "first prepare was not new"
      in
      (match
         Obligation.prepare ~base_path ~request_id ~payload:(payload ())
           ~accepted_at:1.0
         |> expect_ok
       with
       | Obligation.Already_present _ -> ()
       | Obligation.Prepared _ -> fail "exact replay created another obligation");
      let loaded = Obligation.load ~base_path ~request_id |> expect_ok in
      check string
        "request identity roundtrips"
        "kmsg-fusion-1"
        (Obligation.Request_id.to_string loaded.request_id);
      (match
         Obligation.prepare ~base_path ~request_id
           ~payload:(payload ~prompt:"changed request" ()) ~accepted_at:1.0
       with
       | Error (Obligation.Identity_conflict _) -> ()
       | Error error -> fail (Obligation.error_to_string error)
       | Ok _ -> fail "conflicting payload was accepted");
      let inventory = Obligation.inventory ~base_path |> expect_ok in
      check int "one recoverable obligation" 1 (List.length inventory.obligations);
      check int "no inventory failures" 0 (List.length inventory.record_failures);
      Obligation.remove_delivered ~base_path ~identity |> expect_ok;
      Obligation.remove_delivered ~base_path ~identity |> expect_ok;
      match Obligation.load ~base_path ~request_id with
      | Error (Obligation.Not_found _) -> ()
      | Error error -> fail (Obligation.error_to_string error)
      | Ok _ -> fail "delivered obligation was not removed"))
;;

let test_corrupt_peer_is_quarantined_locally () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let request_id = request_id "kmsg-fusion-peer" in
      ignore
        (Obligation.prepare ~base_path ~request_id ~payload:(payload ())
           ~accepted_at:2.0
         |> expect_ok);
      let directory =
        Obligation.For_testing.active_directory ~base_path |> expect_ok
      in
      Fs_compat.save_file (Filename.concat directory "malformed") "not-json";
      let inventory = Obligation.inventory ~base_path |> expect_ok in
      check int "valid peer survives corrupt record" 1
        (List.length inventory.obligations);
      check int "corrupt record is explicit" 1
        (List.length inventory.record_failures)))
;;

let test_startup_recovery_projects_canonical_terminal () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run (fun background_sw ->
        let settled, resolve_settled = Eio.Promise.create () in
        let prompt = "recover this fusion result" in
        let evidence : Fusion_types.deliberation_evidence =
          { question = prompt
          ; panel = []
          ; judge = Error (Fusion_types.Internal_error "test terminal")
          ; judges = []
          ; judge_usage = Fusion_types.zero_usage
          }
        in
        let on_accepted request_id =
          match Obligation.Request_id.of_string request_id with
          | Error detail -> Error detail
          | Ok request_id ->
            (match
               Obligation.prepare ~base_path ~request_id
                 ~payload:(payload ~prompt ()) ~accepted_at:3.0
             with
             | Ok (Obligation.Prepared _ | Obligation.Already_present _) -> Ok ()
             | Error error -> Error (Obligation.error_to_string error))
        in
        let outcome =
          Keeper_msg_async.submit_with_request_id ~on_accepted
            ~on_worker_settled:(fun settlement ->
              Eio.Promise.resolve resolve_settled settlement)
            ~background_sw ~base_path ~caller:"analyst" ~keeper_name:"analyst"
            ~f:(fun ~request_id:_ _request_sw ->
              Keeper_types_profile.tool_result_ok_data
                (Fusion_types.deliberation_evidence_to_yojson evidence))
            ()
        in
        let request_id_wire =
          match outcome with
          | Ok { Keeper_msg_async.request_id; acceptance = Durably_accepted } ->
            request_id
          | Ok { acceptance = Reconciliation_required { reason }; _ } ->
            fail ("unexpected reconciliation requirement: " ^ reason)
          | Error error ->
            fail
              (Keeper_msg_async.submit_error_to_json error
               |> Yojson.Safe.to_string)
        in
        (match Eio.Promise.await settled with
         | Keeper_msg_async.Status_settlement
             { durability = Keeper_msg_async.Durable; _ } -> ()
         | _ -> fail "worker did not produce one durable canonical terminal");
        let report =
          Fusion_delivery_projector.recover_startup ~base_path
          |> function
          | Ok report -> report
          | Error error -> fail (Obligation.error_to_string error)
        in
        check int "one obligation examined" 1 report.examined;
        check int "no staging orphan inspected" 0
          report.staging_cleanup.inspected;
        if report.projected <> 1
        then
          fail
            (Printf.sprintf
               "one terminal projected: projected=%d errors=%s"
               report.projected
               (report.record_errors
                |> List.map
                     (fun (error : Fusion_delivery_projector.recovery_record_error) ->
                        error.detail)
                |> String.concat " | "));
        check int "nothing retained" 0 report.pending;
        let request_id = request_id request_id_wire in
        (match Obligation.load ~base_path ~request_id with
         | Error (Obligation.Not_found _) -> ()
         | Error error -> fail (Obligation.error_to_string error)
         | Ok _ -> fail "projected obligation was not removed");
        match
          Keeper_event_queue_persistence.load ~base_path ~keeper_name:"analyst"
          |> Keeper_event_queue.dequeue
        with
        | Some ({ payload = Keeper_event_queue.Fusion_completed completion; _ }, _) ->
          check string "recovered run id" request_id_wire
            completion.Keeper_event_queue.run_id;
          check string "recovered channel" "discord"
            (Keeper_continuation_channel.kind_label completion.channel)
        | Some _ -> fail "startup projection queued the wrong stimulus"
        | None -> fail "startup projection did not durably queue completion")))
;;

let test_startup_cleanup_observes_atomic_orphans () =
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let staging =
        Obligation.For_testing.staging_directory ~base_path |> expect_ok
      in
      Fs_compat.mkdir_p staging;
      Fs_compat.save_file (Filename.concat staging ".atomic_empty.tmp") "";
      Fs_compat.save_file (Filename.concat staging ".atomic_payload.tmp") "payload";
      let report =
        Fusion_delivery_projector.recover_startup ~base_path
        |> function
        | Ok report -> report
        | Error error -> fail (Obligation.error_to_string error)
      in
      check int "two staging orphans inspected" 2
        report.staging_cleanup.inspected;
      check int "empty staging orphan deleted" 1
        report.staging_cleanup.deleted;
      check int "non-empty staging orphan preserved" 1
        report.staging_cleanup.preserved;
      check int "staging cleanup succeeded" 0
        (List.length report.staging_cleanup.failures)))
;;

let test_startup_recovery_remediates_missing_evidence () =
  (* P1 remediation: a durably canonical [Done{ok=true; data=None}] can never
     become projectable, so recovery must deliver a typed failure and clear
     the obligation instead of retrying it on every startup. *)
  with_temp_base (fun base_path ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run (fun background_sw ->
        let settled, resolve_settled = Eio.Promise.create () in
        let prompt = "recover this evidence-less fusion result" in
        let on_accepted request_id =
          match Obligation.Request_id.of_string request_id with
          | Error detail -> Error detail
          | Ok request_id ->
            (match
               Obligation.prepare ~base_path ~request_id
                 ~payload:(payload ~prompt ()) ~accepted_at:3.0
             with
             | Ok (Obligation.Prepared _ | Obligation.Already_present _) -> Ok ()
             | Error error -> Error (Obligation.error_to_string error))
        in
        let outcome =
          Keeper_msg_async.submit_with_request_id ~on_accepted
            ~on_worker_settled:(fun settlement ->
              Eio.Promise.resolve resolve_settled settlement)
            ~background_sw ~base_path ~caller:"analyst" ~keeper_name:"analyst"
            ~f:(fun ~request_id:_ _request_sw ->
              (* A plain string body settles [Done{ok=true; data=None}]. *)
              Keeper_types_profile.tool_result_ok "done without evidence")
            ()
        in
        let request_id_wire =
          match outcome with
          | Ok { Keeper_msg_async.request_id; acceptance = Durably_accepted } ->
            request_id
          | Ok { acceptance = Reconciliation_required { reason }; _ } ->
            fail ("unexpected reconciliation requirement: " ^ reason)
          | Error error ->
            fail
              (Keeper_msg_async.submit_error_to_json error
               |> Yojson.Safe.to_string)
        in
        (match Eio.Promise.await settled with
         | Keeper_msg_async.Status_settlement
             { durability = Keeper_msg_async.Durable; _ } -> ()
         | _ -> fail "worker did not produce one durable canonical terminal");
        let report =
          Fusion_delivery_projector.recover_startup ~base_path
          |> function
          | Ok report -> report
          | Error error -> fail (Obligation.error_to_string error)
        in
        if report.projected <> 1
        then
          fail
            (Printf.sprintf
               "evidence-less terminal remediated: projected=%d errors=%s"
               report.projected
               (report.record_errors
                |> List.map
                     (fun (error : Fusion_delivery_projector.recovery_record_error) ->
                        error.detail)
                |> String.concat " | "));
        check int "nothing retained for retry" 0 report.pending;
        let request_id = request_id request_id_wire in
        (match Obligation.load ~base_path ~request_id with
         | Error (Obligation.Not_found _) -> ()
         | Error error -> fail (Obligation.error_to_string error)
         | Ok _ -> fail "remediated obligation was not removed");
        match
          Keeper_event_queue_persistence.load ~base_path ~keeper_name:"analyst"
          |> Keeper_event_queue.dequeue
        with
        | Some ({ payload = Keeper_event_queue.Fusion_completed completion; _ }, _) ->
          check string "remediated run id" request_id_wire
            completion.Keeper_event_queue.run_id;
          (match completion.Keeper_event_queue.terminal with
           | Keeper_event_queue.Fusion_failed detail ->
             check bool "typed evidence_unavailable failure" true
               (let needle = "evidence_unavailable" in
                let nl = String.length needle and hl = String.length detail in
                let rec go i =
                  i + nl <= hl
                  && (String.equal (String.sub detail i nl) needle || go (i + 1))
                in
                nl = 0 || go 0)
           | other ->
             fail
               (Printf.sprintf "expected Fusion_failed terminal, got %s"
                  (match other with
                   | Keeper_event_queue.Fusion_succeeded _ -> "Fusion_succeeded"
                   | Keeper_event_queue.Fusion_failed _ -> "Fusion_failed"
                   | Keeper_event_queue.Fusion_cancelled -> "Fusion_cancelled")))
        | Some _ -> fail "startup remediation queued the wrong stimulus"
        | None -> fail "startup remediation did not durably queue a failure")))
;;

let () =
  run
    "fusion delivery obligation"
    [ ( "store"
      , [ test_case "exact prepare/load/inventory/remove" `Quick
            test_exact_prepare_load_inventory_remove
        ; test_case "corrupt peer is quarantined locally" `Quick
            test_corrupt_peer_is_quarantined_locally
        ; test_case "startup recovery projects canonical terminal" `Quick
            test_startup_recovery_projects_canonical_terminal
        ; test_case "startup recovery remediates missing evidence" `Quick
            test_startup_recovery_remediates_missing_evidence
        ; test_case "startup cleanup observes atomic orphans" `Quick
            test_startup_cleanup_observes_atomic_orphans
        ] )
    ]
;;
