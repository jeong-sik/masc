open Alcotest
open Masc
module Opc = Operator_pending_confirm

let () = Opc.register_target_gate (fun _config _target -> Ok ())

let na = Opc.normalized_actor

let temp_dir () =
  Filename.temp_dir "test_operator_pending_confirm_" ""

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let test_explicit_raw () =
  check string "explicit raw" "alice" (na ~context_actor:"" (Some "alice"))

let test_raw_trimmed () =
  check string "raw trimmed" "bob" (na ~context_actor:"" (Some "  bob  "))

let test_empty_raw_uses_context () =
  check string "empty raw" "ctx-agent" (na ~context_actor:"ctx-agent" (Some ""))

let test_none_uses_context () =
  check string "none" "ctx-agent" (na ~context_actor:"ctx-agent" None)

let test_blank_context_returns_unknown () =
  check string "blank context" "unknown" (na ~context_actor:"" None)

let test_unknown_context_returns_unknown () =
  check string "unknown context" "unknown" (na ~context_actor:"unknown" None)

let test_whitespace_context_returns_unknown () =
  check string "whitespace context" "unknown" (na ~context_actor:"  " None)

let pending_confirm_fixture token =
  { Opc.confirm_token = token
  ; trace_id = "ops_test"
  ; actor = "operator"
  ; action_type = "namespace_pause"
  ; target_type = Operator_action_constants.workspace_target_type
  ; target_id = None
  ; payload = `Assoc []
  ; delegated_tool = "masc_pause"
  ; created_at = Masc_domain.now_iso ()
  ; expires_at = None
  }

let test_upsert_reports_persistence_failure () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      Workspace_utils.mkdir_p (Opc.operator_dir config);
      Unix.mkdir (Opc.pending_confirms_path config) 0o755;
      match Opc.upsert_pending_confirm config (pending_confirm_fixture "token-upsert") with
      | Ok () -> fail "upsert should report persistence failure"
      | Error msg ->
          check bool "error mentions local write" true
            (String.contains msg ':'
            && String.contains msg Filename.dir_sep.[0]
            && String.length msg > 0))

let test_remove_reports_persistence_failure () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      Workspace_utils.mkdir_p (Opc.operator_dir config);
      (match
         Opc.write_pending_confirms config
           [ pending_confirm_fixture "token-remove" ]
       with
      | Ok () -> ()
      | Error msg -> fail msg);
      Sys.remove (Opc.pending_confirms_path config);
      Unix.mkdir (Opc.pending_confirms_path config) 0o755;
      match Opc.remove_pending_confirm config "token-remove" with
      | Ok () -> fail "remove should report persistence failure"
      | Error msg ->
          check bool "error mentions local write" true
            (String.contains msg ':'
            && String.contains msg Filename.dir_sep.[0]
            && String.length msg > 0))

let test_duplicate_confirm_tokens_are_rejected () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      Workspace_utils.mkdir_p (Opc.operator_dir config);
      match
        Opc.write_pending_confirms
          config
          [ pending_confirm_fixture "duplicate-token"
          ; pending_confirm_fixture "duplicate-token"
          ]
      with
      | Error message ->
        check bool "duplicate token is named" true
          (String.length message > 0)
      | Ok () -> fail "duplicate confirm_token should be rejected")

let test_unknown_pending_confirm_action_is_rejected () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      Workspace_utils.mkdir_p (Opc.operator_dir config);
      let invalid =
        { (pending_confirm_fixture "unknown-action") with
          action_type = "unknown_action"
        ; delegated_tool = "unknown_tool"
        }
      in
      match Opc.write_pending_confirms config [ invalid ] with
      | Error message ->
        check bool "unknown action is named" true
          (String.length message > 0)
      | Ok () -> fail "unknown pending-confirm action should be rejected")

let test_change_observer_runs_after_unlock () =
  Eio_main.run (fun env ->
    Eio_guard.enable ();
    let previous_fs = Fs_compat.get_fs_opt () in
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base_dir = temp_dir () in
    Fun.protect
      ~finally:(fun () ->
        Opc.install_change_observer (fun ~base_path:_ -> ());
        (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
        cleanup_dir base_dir)
      (fun () ->
        let config = Workspace.default_config base_dir in
        Workspace_utils.mkdir_p (Opc.operator_dir config);
        let observed = ref [] in
        Opc.install_change_observer (fun ~base_path ->
          check string "matching workspace" base_dir base_path;
          let rows = Opc.read_pending_confirms_result config |> Result.get_ok in
          observed := List.length rows :: !observed);
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0 (fun () ->
          Opc.upsert_pending_confirm config (pending_confirm_fixture "wake") |> Result.get_ok;
          ignore (Opc.read_pending_confirms_result config |> Result.get_ok);
          check int "missing target is a no-op" 0
            (Opc.remove_pending_confirms_by_target config
               ~target_type:Operator_action_constants.keeper_target_type
               ~target_id:(Some "missing") |> Result.get_ok);
          let duplicate = pending_confirm_fixture "duplicate" in
          (match Opc.write_pending_confirms config [ duplicate; duplicate ] with
           | Error _ -> ()
           | Ok () -> fail "duplicate tokens must be rejected");
          Opc.remove_pending_confirm config "wake" |> Result.get_ok;
          check (list int) "one post-unlock observation per write" [ 1; 0 ]
            (List.rev !observed))))
;;

let test_expiry_cleanup_wakes_after_unlock () =
  Eio_main.run (fun env ->
    Eio_guard.enable ();
    let previous_fs = Fs_compat.get_fs_opt () in
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base_dir = temp_dir () in
    Fun.protect
      ~finally:(fun () ->
        Opc.install_change_observer (fun ~base_path:_ -> ());
        (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
        cleanup_dir base_dir)
      (fun () ->
        let config = Workspace.default_config base_dir in
        Workspace_utils.mkdir_p (Opc.operator_dir config);
        let expired =
          { (pending_confirm_fixture "expired") with
            created_at = "2000-01-01T00:00:00Z";
            expires_at = Some "2000-01-02T00:00:00Z" }
        in
        Opc.write_pending_confirms config [ expired ] |> Result.get_ok;
        let calls = ref 0 in
        Opc.install_change_observer (fun ~base_path:_ ->
          incr calls;
          check int "cleanup visible on re-entry" 0
            (List.length (Opc.read_pending_confirms_result config |> Result.get_ok)));
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0 (fun () ->
          check int "expired entry removed" 0
            (List.length (Opc.read_pending_confirms_result config |> Result.get_ok));
          check int "cleanup publishes one observation" 1 !calls)))
;;

let test_change_observer_notices_failed_write () =
  Eio_main.run (fun env ->
    let previous_fs = Fs_compat.get_fs_opt () in
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base_dir = temp_dir () in
    Fun.protect
      ~finally:(fun () ->
        Opc.install_change_observer (fun ~base_path:_ -> ());
        (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
        cleanup_dir base_dir)
      (fun () ->
        let config = Workspace.default_config base_dir in
        Workspace_utils.mkdir_p (Opc.operator_dir config);
        Unix.mkdir (Opc.pending_confirms_path config) 0o755;
        let calls = ref 0 in
        Opc.install_change_observer (fun ~base_path:_ -> incr calls);
        (match Opc.write_pending_confirms config [ pending_confirm_fixture "failed" ] with
         | Error _ -> ()
         | Ok () -> fail "directory target must fail");
        check int "attempted write invalidates" 1 !calls))
;;

let test_change_observer_preserves_caller_cancellation () =
  Eio_main.run (fun env ->
    let previous_fs = Fs_compat.get_fs_opt () in
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base_dir = temp_dir () in
    Fun.protect
      ~finally:(fun () ->
        Opc.install_change_observer (fun ~base_path:_ -> ());
        (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
        cleanup_dir base_dir)
      (fun () ->
        let config = Workspace.default_config base_dir in
        Workspace_utils.mkdir_p (Opc.operator_dir config);
        Opc.install_change_observer (fun ~base_path:_ -> raise (Eio.Cancel.Cancelled Exit));
        Opc.write_pending_confirms config [ pending_confirm_fixture "first" ] |> Result.get_ok;
        check int "callback cancellation leaves committed data" 1
          (List.length (Opc.raw_pending_confirms config));
        let reason = Failure "cancelled caller" in
        (match Eio.Cancel.sub (fun context ->
           Opc.install_change_observer (fun ~base_path:_ ->
             Eio.Cancel.cancel context reason;
             raise (Eio.Cancel.Cancelled Exit));
           Opc.write_pending_confirms config [ pending_confirm_fixture "second" ] |> Result.get_ok) with
         | () -> fail "caller cancellation did not propagate"
         | exception Eio.Cancel.Cancelled actual when actual == reason -> ()
         | exception exn -> fail ("unexpected cancellation: " ^ Printexc.to_string exn));
        check string "caller cancellation occurred after commit" "second"
          (List.hd (Opc.raw_pending_confirms config)).Opc.confirm_token))
;;

let tests =
  [
    test_case "explicit raw" `Quick test_explicit_raw;
    test_case "raw trimmed" `Quick test_raw_trimmed;
    test_case "empty raw uses context" `Quick test_empty_raw_uses_context;
    test_case "none uses context" `Quick test_none_uses_context;
    test_case "blank context returns unknown" `Quick test_blank_context_returns_unknown;
    test_case "unknown context returns unknown" `Quick test_unknown_context_returns_unknown;
    test_case "whitespace context returns unknown" `Quick test_whitespace_context_returns_unknown;
    test_case "upsert reports persistence failure" `Quick test_upsert_reports_persistence_failure;
    test_case "remove reports persistence failure" `Quick test_remove_reports_persistence_failure;
    test_case "duplicate confirm tokens are rejected" `Quick test_duplicate_confirm_tokens_are_rejected;
    test_case "unknown pending confirm action is rejected" `Quick test_unknown_pending_confirm_action_is_rejected;
    test_case "change observer runs after unlock" `Quick test_change_observer_runs_after_unlock;
    test_case "expiry cleanup wakes after unlock" `Quick test_expiry_cleanup_wakes_after_unlock;
    test_case "failed publication wakes observer" `Quick test_change_observer_notices_failed_write;
    test_case "observer preserves caller cancellation" `Quick test_change_observer_preserves_caller_cancellation;
  ]

let () = run "normalized_actor" [ ("normalized_actor", tests) ]
