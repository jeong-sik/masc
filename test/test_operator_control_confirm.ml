open Masc
open Test_operator_control_support

let test_confirm_rejects_expired_token () =
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let pending_dir = Filename.concat (Workspace.masc_dir config) "operator" in
      Workspace_utils.mkdir_p pending_dir;
      let path = Filename.concat pending_dir "pending_confirms.json" in
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () ->
          output_string oc
            (Yojson.Safe.to_string
               (`List
                 [
                   `Assoc
                     [
                       ("confirm_token", `String "expired-token");
                       ("trace_id", `String "ops_expired");
                       ("actor", `String "operator");
                       ("action_type", `String "broadcast");
                       ( "target_type"
                       , `String Operator_action_constants.workspace_target_type );
                       ("target_id", `Null);
                       ("payload", `Assoc []);
                       ("delegated_tool", `String "masc_broadcast");
                       ("created_at", `String "2026-03-06T00:00:00Z");
                       ("expires_at", `String "2026-03-06T00:00:01Z");
                     ];
                 ])));
      let ctx = operator_ctx env sw config "operator" in
      Operator_control.invalidate_snapshot_cache ();
      ignore
        (Operator_control_snapshot_cache.get_or_compute "expired-sentinel"
           ~ttl:60.0 (fun () -> `String "stale"));
      let projection_computes = ref 0 in
      let projection () =
        Dashboard_projection_cache.get_or_compute_snapshot_json ~config
          ~actor:(Some "operator") (fun _ -> Pool_work.cpu ~name:__FUNCTION__ (fun () ->
            incr projection_computes;
            `Int !projection_computes))
      in
      ignore (projection ());
      match
        Operator_control.confirm_json ctx
          (`Assoc [ ("actor", `String "operator"); ("confirm_token", `String "expired-token") ])
      with
      | Ok _ -> Alcotest.fail "expected expired confirmation error"
      | Error err ->
          Alcotest.(check string) "expired error" "pending confirmation expired" err;
          Alcotest.(check bool) "expired removal clears operator snapshot cache"
            false
            (Option.is_some
               (Operator_control_snapshot_cache.peek "expired-sentinel"));
          ignore (projection ());
          Alcotest.(check int) "expired removal clears dashboard projection" 2
            !projection_computes)

let iso_in_minutes minutes =
  iso_of_unix (Unix.gettimeofday () +. (float_of_int minutes *. 60.0))

(* A confirmed keeper_message reaches masc_keeper_delegate with the Keeper name
   as [target], the shape the delegate decoder takes (#38590). The dispatch is
   captured, so the test reads the exact arguments the operator path sends. *)
let test_confirmed_keeper_message_delegates_by_keeper_name () =
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let pending_dir = Filename.concat (Workspace.masc_dir config) "operator" in
      Workspace_utils.mkdir_p pending_dir;
      let path = Filename.concat pending_dir "pending_confirms.json" in
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () ->
          output_string oc
            (Yojson.Safe.to_string
               (`List
                 [
                   `Assoc
                     [
                       ("confirm_token", `String "keeper-message-token");
                       ("trace_id", `String "ops_keeper_message");
                       ("actor", `String "operator");
                       ("action_type", `String "keeper_message");
                       ( "target_type"
                       , `String Operator_action_constants.keeper_target_type );
                       ("target_id", `String "beta");
                       ("payload", `Assoc [ ("message", `String "hello") ]);
                       ("delegated_tool", `String "masc_keeper_delegate");
                       ("created_at", `String (iso_in_minutes (-5)));
                       ("expires_at", `String (iso_in_minutes 30));
                     ];
                 ])));
      let dispatched = ref [] in
      let capture ~name ~args =
        dispatched := (name, args) :: !dispatched;
        Some
          (Tool_result.make_ok ~tool_name:name ~start_time:(Tool_timing.start ())
             ~data:(`Assoc [ ("operation_id", `String "kmsg-test") ]) ())
      in
      let ctx =
        { (operator_ctx env sw config "operator") with delegated_dispatch = Some capture }
      in
      (match
         Operator_control.confirm_json ctx
           (`Assoc [ ("confirm_token", `String "keeper-message-token") ])
       with
       | Ok _ -> ()
       | Error err -> Alcotest.failf "keeper_message confirm failed: %s" err);
      match !dispatched with
      | [ (name, args) ] ->
        Alcotest.(check string) "dispatches masc_keeper_delegate" "masc_keeper_delegate" name;
        Alcotest.(check bool) "target is the Keeper name" true
          (Yojson.Safe.Util.member "target" args = `String "beta");
        (match Keeper_invocation_contract.request_of_json args with
         | Ok request ->
           Alcotest.(check string) "the delegate decoder reads the same Keeper" "beta"
             (Keeper_invocation_contract.target_name request)
         | Error err ->
           Alcotest.failf "the delegate decoder refused the operator arguments: %s"
             (Keeper_invocation_contract.request_error_to_string err))
      | calls -> Alcotest.failf "expected one dispatch, got %d" (List.length calls))

let contains_substring ~substring hay =
  let hay_len = String.length hay in
  let needle_len = String.length substring in
  let found = ref false in
  let last_start = hay_len - needle_len in
  let i = ref 0 in
  while (not !found) && !i <= last_start do
    if String.sub hay !i needle_len = substring then found := true;
    incr i
  done;
  !found

(* Regression for #27512: a decision value outside {confirm, deny} must be
   rejected before any branch of the gate runs. Previously any string other
   than "deny" fell through to the execute branch and was audited as
   Gate_confirm, so a typo ("Approve", "yes", "1") executed the action. *)
let test_confirm_rejects_unknown_decision () =
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let pending_dir = Filename.concat (Workspace.masc_dir config) "operator" in
      Workspace_utils.mkdir_p pending_dir;
      let path = Filename.concat pending_dir "pending_confirms.json" in
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () ->
          output_string oc
            (Yojson.Safe.to_string
               (`List
                 [
                   `Assoc
                     [
                       ("confirm_token", `String "live-token");
                       ("trace_id", `String "ops_unknown_decision");
                       ("actor", `String "operator");
                       ("action_type", `String "broadcast");
                       ( "target_type"
                       , `String Operator_action_constants.workspace_target_type );
                       ("target_id", `Null);
                       ("payload", `Assoc []);
                       ("delegated_tool", `String "masc_broadcast");
                       ("created_at", `String (iso_in_minutes (-5)));
                       ("expires_at", `String (iso_in_minutes 30));
                     ];
                 ])));
      let ctx = operator_ctx env sw config "operator" in
      let token_still_pending () =
        List.exists
          (fun (entry : Operator_pending_confirm.pending_confirm) ->
            String.equal entry.confirm_token "live-token")
          (Operator_pending_confirm.raw_pending_confirms config)
      in
      Alcotest.(check bool) "fixture token is pending before the call" true
        (token_still_pending ());
      match
        Operator_control.confirm_json ctx
          (`Assoc
            [
              ("actor", `String "operator");
              ("confirm_token", `String "live-token");
              ("decision", `String "Approve");
            ])
      with
      | Ok _ -> Alcotest.fail "unknown decision value must be rejected"
      | Error err ->
          Alcotest.(check bool) "error names the decision field" true
            (contains_substring ~substring:"decision" err);
          Alcotest.(check bool) "error echoes the offending value" true
            (contains_substring ~substring:"Approve" err);
          (* The pending confirm must survive: the execute branch never ran,
             so nothing was consumed or audited as Gate_confirm. *)
          Alcotest.(check bool) "pending confirm not consumed by bad decision"
            true
            (token_still_pending ()))
