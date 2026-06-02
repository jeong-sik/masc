(** Regression test for masc_bind fail-closed identity gate (RFC P3-a).

    Prior to RFC P3-a promotion, [handle_join] logged normalize errors and
    proceeded with the original [agent_name] (fail-open).  The fail-closed
    gate rejects join when [Keeper_identity.normalize_all_names] returns [Error].

    This test verifies the gate function at the unit level.  It does NOT call
    [handle_join] directly (which requires a full
    [Tool_inline_dispatch_types.context] with Eio fiber infrastructure).

    Note on persona path resolution: [normalize_all_names] uses
    [Config_dir_resolver.personas_dir_opt()] first, which returns the global
    config dir and ignores [base_path]. Identity-level rejection tests
    (empty/whitespace/invalid chars) need no filesystem setup because they fail
    before filesystem checks. Full-gate persona-present tests would require a
    known persona in the global config dir, which is machine-dependent and
    excluded from CI. *)

open Alcotest
open Masc_mcp

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let validation_error =
  testable Keeper_identity.pp_validation_error ( = )

let normalize ~input ?base_path ?(check_persona = true) () =
  Keeper_identity.normalize_all_names
    ~input_agent_name:input
    ?base_path
    ~check_persona
    ()

(* Same flags as handle_join uses *)
let join_normalize ~input ?base_path () =
  normalize ~input ?base_path ~check_persona:true ()

(* --------------------------------------------------------------------- *)
(* Identity-level rejections (canonical_keeper_name returns None)         *)
(* --------------------------------------------------------------------- *)

let test_empty_rejected () =
  match join_normalize ~input:"" () with
  | Ok _ -> fail "empty input should be rejected by join gate"
  | Error e ->
      check validation_error "empty -> Empty_input"
        Keeper_identity.Empty_input e

let test_whitespace_rejected () =
  match join_normalize ~input:"   " () with
  | Ok _ -> fail "whitespace input should be rejected by join gate"
  | Error e ->
      check validation_error "whitespace -> Empty_input"
        Keeper_identity.Empty_input e

let test_invalid_chars_rejected () =
  match join_normalize ~input:"bad@name!#%" () with
  | Ok _ -> fail "invalid chars should be rejected by join gate"
  | Error (Keeper_identity.Persona_not_found _) -> ()
  | Error other ->
      fail
        (Printf.sprintf "invalid chars expected Persona_not_found, got %s"
           (Keeper_identity.show_validation_error other))

(* --------------------------------------------------------------------- *)
(* Join gate flags verification — documents the handle_join contract       *)
(* --------------------------------------------------------------------- *)

let test_join_gate_uses_persona_check () =
  (* This is a documentation test: handle_join calls normalize with
     ~check_persona:true.  The join_normalize wrapper mirrors this exactly.
     Empty input must fail. *)
  match join_normalize ~input:"" () with
  | Error _ -> ()
  | Ok _ -> fail "join gate must reject empty input with persona check enabled"

(* --------------------------------------------------------------------- *)
(* Test runner                                                            *)
(* --------------------------------------------------------------------- *)

let () =
  run "workspace_bind_fail_closed"
    [
      ( "identity_rejection",
        [
          test_case "empty input rejected" `Quick test_empty_rejected;
          test_case "whitespace input rejected" `Quick test_whitespace_rejected;
          test_case "invalid chars rejected" `Quick test_invalid_chars_rejected;
        ] );
      ( "join_gate_contract",
        [
          test_case "join gate uses persona check" `Quick
            test_join_gate_uses_persona_check;
        ] );
    ]
