(** Tests for State_product — orthogonal state machine composition. *)

open Masc_mcp

module AT = State_product.Agent_turn
module TV = State_product.Tool_validation
module K = State_product.Keeper

let mk ?(keeper=K.Offline) ?(turn=AT.Idle) ?(validation=TV.Unchecked) () : State_product.product =
  { keeper; turn; validation }

(* ── Agent Turn FSM ─────────────────────────────────────── *)

let test_turn_happy_path () =
  let open AT in
  let s = apply_event ~current:Idle Turn_start in
  Alcotest.(check string) "prompting" "prompting" (phase_to_string s);
  let s = apply_event ~current:s Prompt_ready in
  Alcotest.(check string) "awaiting" "awaiting" (phase_to_string s);
  let s = apply_event ~current:s Response_received in
  Alcotest.(check string) "parsing" "parsing" (phase_to_string s);
  let s = apply_event ~current:s Parse_complete in
  Alcotest.(check string) "dispatching" "dispatching" (phase_to_string s);
  let s = apply_event ~current:s Tools_dispatched in
  Alcotest.(check string) "collecting" "collecting" (phase_to_string s);
  let s = apply_event ~current:s Results_collected in
  Alcotest.(check string) "finalizing" "finalizing" (phase_to_string s);
  let s = apply_event ~current:s Turn_complete in
  Alcotest.(check string) "back to idle" "idle" (phase_to_string s)

let test_turn_error_resets () =
  let s = AT.apply_event ~current:Awaiting (Turn_error "timeout") in
  Alcotest.(check string) "error resets" "idle" (AT.phase_to_string s)

(* ── Tool Validation FSM ────────────────────────────────── *)

let test_validation_det_fixed () =
  let s = TV.apply_event ~current:Unchecked Validate_start in
  Alcotest.(check string) "det_correcting" "det_correcting" (TV.phase_to_string s);
  let s = TV.apply_event ~current:s Det_fixed in
  Alcotest.(check string) "det_valid" "det_valid" (TV.phase_to_string s)

let test_validation_nondet_retry () =
  let s = TV.apply_event ~current:Det_invalid (Nondet_attempt 1) in
  Alcotest.(check string) "nondet_retrying" "nondet_retrying" (TV.phase_to_string s);
  let s = TV.apply_event ~current:s Nondet_fixed in
  Alcotest.(check string) "valid" "valid" (TV.phase_to_string s)

let test_validation_rejected () =
  let s = TV.apply_event ~current:Nondet_retrying Nondet_exhausted in
  Alcotest.(check string) "rejected" "rejected" (TV.phase_to_string s)

let test_validation_skip () =
  let s = TV.apply_event ~current:Unchecked Skip_validation in
  Alcotest.(check string) "valid" "valid" (TV.phase_to_string s)

(* ── Product Invariants ─────────────────────────────────── *)

let test_initial_ok () =
  match State_product.check_invariants State_product.initial with
  | Ok () -> ()
  | Error e -> Alcotest.fail e

let test_stopped_idle_ok () =
  match State_product.check_invariants (mk ~keeper:K.Stopped ~turn:AT.Idle ()) with
  | Ok () -> ()
  | Error e -> Alcotest.fail e

let test_stopped_dispatching_fail () =
  match State_product.check_invariants (mk ~keeper:K.Stopped ~turn:AT.Dispatching ()) with
  | Ok () -> Alcotest.fail "expected violation"
  | Error _ -> ()

let test_draining_finalizing_ok () =
  match State_product.check_invariants (mk ~keeper:K.Draining ~turn:AT.Finalizing ()) with
  | Ok () -> ()
  | Error e -> Alcotest.fail e

let test_draining_prompting_fail () =
  match State_product.check_invariants (mk ~keeper:K.Draining ~turn:AT.Prompting ()) with
  | Ok () -> Alcotest.fail "expected violation"
  | Error _ -> ()

let test_nondet_dispatching_ok () =
  let s = mk ~keeper:K.Running ~turn:AT.Dispatching ~validation:TV.Nondet_retrying () in
  match State_product.check_invariants s with
  | Ok () -> ()
  | Error e -> Alcotest.fail e

let test_nondet_idle_fail () =
  let s = mk ~keeper:K.Running ~turn:AT.Idle ~validation:TV.Nondet_retrying () in
  match State_product.check_invariants s with
  | Ok () -> Alcotest.fail "expected violation"
  | Error _ -> ()

let test_compacting_awaiting_fail () =
  match State_product.check_invariants (mk ~keeper:K.Compacting ~turn:AT.Awaiting ()) with
  | Ok () -> Alcotest.fail "expected violation"
  | Error _ -> ()

(* ── Event Application ──────────────────────────────────── *)

let test_apply_turn () =
  let s = mk ~keeper:K.Running () in
  match State_product.apply_turn_event s AT.Turn_start with
  | Ok s -> Alcotest.(check string) "prompting" "prompting" (AT.phase_to_string s.turn)
  | Error e -> Alcotest.fail e

let test_apply_validation () =
  let s = mk ~keeper:K.Running ~turn:AT.Dispatching () in
  match State_product.apply_validation_event s TV.Validate_start with
  | Ok s -> Alcotest.(check string) "det_correcting" "det_correcting"
              (TV.phase_to_string s.validation)
  | Error e -> Alcotest.fail e

(* ── JSON ───────────────────────────────────────────────── *)

let test_json () =
  let json = State_product.product_to_json State_product.initial in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "keeper" "offline" (json |> member "keeper" |> to_string);
  Alcotest.(check string) "turn" "idle" (json |> member "turn" |> to_string)

let () =
  Alcotest.run "State_product" [
    ("agent_turn", [
      Alcotest.test_case "happy path" `Quick test_turn_happy_path;
      Alcotest.test_case "error resets" `Quick test_turn_error_resets;
    ]);
    ("tool_validation", [
      Alcotest.test_case "det fixed" `Quick test_validation_det_fixed;
      Alcotest.test_case "nondet retry" `Quick test_validation_nondet_retry;
      Alcotest.test_case "rejected" `Quick test_validation_rejected;
      Alcotest.test_case "skip" `Quick test_validation_skip;
    ]);
    ("invariants", [
      Alcotest.test_case "initial ok" `Quick test_initial_ok;
      Alcotest.test_case "stopped+idle ok" `Quick test_stopped_idle_ok;
      Alcotest.test_case "stopped+dispatching fail" `Quick test_stopped_dispatching_fail;
      Alcotest.test_case "draining+finalizing ok" `Quick test_draining_finalizing_ok;
      Alcotest.test_case "draining+prompting fail" `Quick test_draining_prompting_fail;
      Alcotest.test_case "nondet+dispatching ok" `Quick test_nondet_dispatching_ok;
      Alcotest.test_case "nondet+idle fail" `Quick test_nondet_idle_fail;
      Alcotest.test_case "compacting+awaiting fail" `Quick test_compacting_awaiting_fail;
    ]);
    ("events", [
      Alcotest.test_case "turn event" `Quick test_apply_turn;
      Alcotest.test_case "validation event" `Quick test_apply_validation;
    ]);
    ("json", [
      Alcotest.test_case "serialize" `Quick test_json;
    ]);
  ]
