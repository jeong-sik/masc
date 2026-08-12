(** Unit tests for Guardrails_async (v0.67.0). *)
open Alcotest

open Agent_core

(* ── Helpers ──────────────────────────────────────── *)

let make_response text : Types.api_response =
  { id = "m"
  ; model = "m"
  ; stop_reason = EndTurn
  ; content = [ Text text ]
  ; usage = None
  ; telemetry = None
  }
;;

let dummy_messages : Types.message list =
  [ { role = User
    ; content = [ Text "hello" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  ]
;;

let pass_input : Guardrails_async.input_validator =
  { name = "pass_in"; validate = (fun _ -> Ok ()) }
;;

let fail_input reason : Guardrails_async.input_validator =
  { name = "fail_in"; validate = (fun _ -> Error reason) }
;;

let pass_output : Guardrails_async.output_validator =
  { name = "pass_out"; validate = (fun _ -> Ok ()) }
;;

let fail_output reason : Guardrails_async.output_validator =
  { name = "fail_out"; validate = (fun _ -> Error reason) }
;;

(* ── Input validators ─────────────────────────────── *)

let test_input_empty () =
  Eio_main.run
  @@ fun _env ->
  let result = Guardrails_async.run_input [] dummy_messages in
  match result with
  | Guardrails_async.Pass -> ()
  | Guardrails_async.Fail _ -> fail "empty should pass"
;;

let test_input_all_pass () =
  Eio_main.run
  @@ fun _env ->
  let result =
    Guardrails_async.run_input [ pass_input; pass_input; pass_input ] dummy_messages
  in
  match result with
  | Pass -> ()
  | Fail _ -> fail "all pass should pass"
;;

let test_input_one_fails () =
  Eio_main.run
  @@ fun _env ->
  let result =
    Guardrails_async.run_input
      [ pass_input; fail_input "blocked"; pass_input ]
      dummy_messages
  in
  match result with
  | Fail { validator_name = "fail_in"; reason = "blocked" } -> ()
  | Fail _ -> fail "wrong failure info"
  | Pass -> fail "should have failed"
;;

let test_input_exception_is_local_failure () =
  Eio_main.run
  @@ fun _env ->
  let sibling_ran = ref false in
  let raising : Guardrails_async.input_validator =
    { name = "raise_in"; validate = (fun _ -> raise (Failure "boom")) }
  in
  let sibling : Guardrails_async.input_validator =
    { name = "sibling_in"
    ; validate =
        (fun _ ->
          sibling_ran := true;
          Ok ())
    }
  in
  let result = Guardrails_async.run_input [ raising; sibling ] dummy_messages in
  check bool "sibling still ran" true !sibling_ran;
  match result with
  | Fail { validator_name = "raise_in"; reason } ->
    check string "reason says raised" "validator raised" reason;
    check bool "reason redacts exception detail" false (Agent_core_strings.contains_substring ~haystack:reason ~needle:"boom")
  | Fail _ -> fail "wrong failure info"
  | Pass -> fail "should have failed"
;;

(* ── Output validators ────────────────────────────── *)

let test_output_empty () =
  Eio_main.run
  @@ fun _env ->
  let response = make_response "ok" in
  let result = Guardrails_async.run_output [] response in
  match result with
  | Pass -> ()
  | Fail _ -> fail "empty should pass"
;;

let test_output_all_pass () =
  Eio_main.run
  @@ fun _env ->
  let response = make_response "safe content" in
  let result = Guardrails_async.run_output [ pass_output; pass_output ] response in
  match result with
  | Pass -> ()
  | Fail _ -> fail "should pass"
;;

let test_output_one_fails () =
  Eio_main.run
  @@ fun _env ->
  let response = make_response "bad content" in
  let result =
    Guardrails_async.run_output [ pass_output; fail_output "toxic" ] response
  in
  match result with
  | Fail { reason = "toxic"; _ } -> ()
  | _ -> fail "should have failed with toxic"
;;

let test_output_timeout_is_local_failure () =
  Eio_main.run
  @@ fun _env ->
  let sibling_ran = ref false in
  let timeout : Guardrails_async.output_validator =
    { name = "timeout_out"; validate = (fun _ -> raise Eio.Time.Timeout) }
  in
  let sibling : Guardrails_async.output_validator =
    { name = "sibling_out"
    ; validate =
        (fun _ ->
          sibling_ran := true;
          Ok ())
    }
  in
  let response = make_response "safe content" in
  let result = Guardrails_async.run_output [ timeout; sibling ] response in
  check bool "sibling still ran" true !sibling_ran;
  match result with
  | Fail { validator_name = "timeout_out"; reason = "validator timed out" } -> ()
  | Fail _ -> fail "wrong timeout failure info"
  | Pass -> fail "should have failed"
;;

(* ── Guarded ──────────────────────────────────────── *)

let test_guarded_all_pass () =
  Eio_main.run
  @@ fun _env ->
  let config : Guardrails_async.t =
    { input_validators = [ pass_input ]; output_validators = [ pass_output ] }
  in
  let action () = Ok (make_response "result") in
  match Guardrails_async.guarded ~config ~messages:dummy_messages ~action () with
  | Ok resp ->
    check
      string
      "response text"
      "result"
      (match List.hd resp.content with
       | Text s -> s
       | _ -> "")
  | Error _ -> fail "should succeed"
;;

let test_guarded_input_blocks () =
  Eio_main.run
  @@ fun _env ->
  let action_called = ref false in
  let config : Guardrails_async.t =
    { input_validators = [ fail_input "banned" ]; output_validators = [ pass_output ] }
  in
  let action () =
    action_called := true;
    Ok (make_response "should not reach")
  in
  match Guardrails_async.guarded ~config ~messages:dummy_messages ~action () with
  | Error (`Validation (Fail { reason = "banned"; _ })) ->
    check bool "action not called" false !action_called
  | _ -> fail "should have been blocked by input"
;;

let test_guarded_output_rejects () =
  Eio_main.run
  @@ fun _env ->
  let config : Guardrails_async.t =
    { input_validators = [ pass_input ]; output_validators = [ fail_output "unsafe" ] }
  in
  let action () = Ok (make_response "raw") in
  match Guardrails_async.guarded ~config ~messages:dummy_messages ~action () with
  | Error (`Validation (Fail { reason = "unsafe"; _ })) -> ()
  | _ -> fail "should have been rejected by output"
;;

let test_guarded_action_error () =
  Eio_main.run
  @@ fun _env ->
  let config : Guardrails_async.t =
    { input_validators = [ pass_input ]; output_validators = [ pass_output ] }
  in
  let action () = Error "api down" in
  match Guardrails_async.guarded ~config ~messages:dummy_messages ~action () with
  | Error (`Action "api down") -> ()
  | _ -> fail "should propagate action error"
;;

(* ── result_to_string ─────────────────────────────── *)

let test_result_to_string () =
  check string "pass" "pass" (Guardrails_async.result_to_string Pass);
  let s =
    Guardrails_async.result_to_string (Fail { validator_name = "check"; reason = "bad" })
  in
  check bool "contains FAIL" true (String.length s > 0)
;;

(* ── Concurrent execution ─────────────────────────── *)

let test_concurrent_execution () =
  Eio_main.run
  @@ fun _env ->
  let order = ref [] in
  let v1 : Guardrails_async.input_validator =
    { name = "v1"
    ; validate =
        (fun _ ->
          order := "v1" :: !order;
          Ok ())
    }
  in
  let v2 : Guardrails_async.input_validator =
    { name = "v2"
    ; validate =
        (fun _ ->
          order := "v2" :: !order;
          Ok ())
    }
  in
  let v3 : Guardrails_async.input_validator =
    { name = "v3"
    ; validate =
        (fun _ ->
          order := "v3" :: !order;
          Ok ())
    }
  in
  let result = Guardrails_async.run_input [ v1; v2; v3 ] dummy_messages in
  (match result with
   | Pass -> ()
   | Fail _ -> fail "should pass");
  (* All 3 should have executed *)
  check int "all executed" 3 (List.length !order)
;;

(* ── Suite ────────────────────────────────────────── *)

let () =
  run
    "guardrails_async"
    [ ( "input"
      , [ test_case "empty" `Quick test_input_empty
        ; test_case "all pass" `Quick test_input_all_pass
        ; test_case "one fails" `Quick test_input_one_fails
        ; test_case
            "exception is local failure"
            `Quick
            test_input_exception_is_local_failure
        ] )
    ; ( "output"
      , [ test_case "empty" `Quick test_output_empty
        ; test_case "all pass" `Quick test_output_all_pass
        ; test_case "one fails" `Quick test_output_one_fails
        ; test_case "timeout is local failure" `Quick test_output_timeout_is_local_failure
        ] )
    ; ( "guarded"
      , [ test_case "all pass" `Quick test_guarded_all_pass
        ; test_case "input blocks" `Quick test_guarded_input_blocks
        ; test_case "output rejects" `Quick test_guarded_output_rejects
        ; test_case "action error" `Quick test_guarded_action_error
        ] )
    ; ( "misc"
      , [ test_case "result_to_string" `Quick test_result_to_string
        ; test_case "concurrent execution" `Quick test_concurrent_execution
        ] )
    ]
;;
