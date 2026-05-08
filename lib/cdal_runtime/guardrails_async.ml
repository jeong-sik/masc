(** Async guardrails: parallel input/output validation via Eio fibers.

    Extends {!Guardrails} (tool filtering) with content validation:
    - {b Input validators} run before the LLM call (gate).
    - {b Output validators} run after the LLM call (parallel).

    All validators within a group run concurrently via [Eio.Fiber.all]
    inside a dedicated [Eio.Switch]. Cancellation propagates correctly.

    @since 0.67.0 *)
open Types

let log = Log.create ~module_name:"guardrails_async" ()

(** Input validator: checks messages before sending to the LLM. *)
type input_validator =
  { name : string
  ; validate : message list -> (unit, string) Result.t
  }

(** Output validator: checks the LLM response. *)
type output_validator =
  { name : string
  ; validate : api_response -> (unit, string) Result.t
  }

(** Result of a validation run. *)
type validation_result =
  | Pass
  | Fail of
      { validator_name : string
      ; reason : string
      }

(** Configuration for async guardrails. *)
type t =
  { input_validators : input_validator list
  ; output_validators : output_validator list
  }

let empty = { input_validators = []; output_validators = [] }

let exception_reason ~validator_name = function
  | Eio.Time.Timeout -> "validator timed out"
  | exn ->
    Log.debug
      log
      "validator raised"
      [ Log.S ("validator", validator_name)
      ; Log.S ("exception", Stdlib.Printexc.to_string exn)
      ];
    "validator raised"
;;

(* Per-validator deadline. When supplied the validator is wrapped in
   [Eio.Time.with_timeout_exn], so a stuck validator turns into
   [Fail "validator timed out"] instead of blocking sibling fibers and
   the rest of the turn pipeline. The audit (Kimi 1-3) flagged the
   unguarded [Eio.Fiber.all] as a Silent Failure path: one validator
   hanging would block the entire turn. Default is [None] for backward
   compatibility — call sites opt in by passing [~deadline]. *)
type deadline =
  { clock : float Eio.Time.clock_ty Eio.Resource.t
  ; timeout_sec : float
  }

let run_validator ?deadline ~validator_name f =
  let invoke () =
    match f () with
    | Ok () -> Pass
    | Error reason -> Fail { validator_name; reason }
  in
  try
    match deadline with
    | Some { clock; timeout_sec } when timeout_sec > 0.0 ->
      Eio.Time.with_timeout_exn clock timeout_sec invoke
    | _ -> invoke ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Out_of_memory -> raise Out_of_memory
  | Stack_overflow -> raise Stack_overflow
  | Stdlib.Sys.Break -> raise Stdlib.Sys.Break
  | exn -> Fail { validator_name; reason = exception_reason ~validator_name exn }
;;

(** Run all input validators concurrently.

    Creates a dedicated [Eio.Switch] for parallel execution.
    Returns the first failure found, or [Pass] if all succeed.
    Cancellation exceptions propagate correctly. *)
let run_input ?deadline (validators : input_validator list) (messages : message list)
  : validation_result
  =
  match validators with
  | [] -> Pass
  | _ ->
    let results = Array.make (List.length validators) Pass in
    let fns =
      List.mapi
        (fun i (v : input_validator) ->
           fun () ->
           results.(i)
           <- run_validator ?deadline ~validator_name:v.name (fun () ->
                v.validate messages))
        validators
    in
    Eio.Switch.run ~name:"input_validators" (fun _sw -> Eio.Fiber.all fns);
    Array.to_list results
    |> List.find_opt (function
      | Fail _ -> true
      | Pass -> false)
    |> Option.value ~default:Pass
;;

(** Run all output validators concurrently.

    Same parallel execution pattern as {!run_input}. *)
let run_output ?deadline (validators : output_validator list) (response : api_response)
  : validation_result
  =
  match validators with
  | [] -> Pass
  | _ ->
    let results = Array.make (List.length validators) Pass in
    let fns =
      List.mapi
        (fun i (v : output_validator) ->
           fun () ->
           results.(i)
           <- run_validator ?deadline ~validator_name:v.name (fun () ->
                v.validate response))
        validators
    in
    Eio.Switch.run ~name:"output_validators" (fun _sw -> Eio.Fiber.all fns);
    Array.to_list results
    |> List.find_opt (function
      | Fail _ -> true
      | Pass -> false)
    |> Option.value ~default:Pass
;;

(** Convenience: run input validation, then an action, then output validation.

    If input validation fails, the action is not executed.
    Returns [Ok response] on success, [Error validation_result] on failure. *)
let guarded
      ?deadline
      ~(config : t)
      ~(messages : message list)
      ~(action : unit -> (api_response, 'e) Result.t)
      ()
  : (api_response, [ `Validation of validation_result | `Action of 'e ]) Result.t
  =
  match run_input ?deadline config.input_validators messages with
  | Fail _ as f -> Error (`Validation f)
  | Pass ->
    (match action () with
     | Error e -> Error (`Action e)
     | Ok response ->
       (match run_output ?deadline config.output_validators response with
        | Fail _ as f -> Error (`Validation f)
        | Pass -> Ok response))
;;

(** Format a validation result for logging. *)
let result_to_string = function
  | Pass -> "pass"
  | Fail { validator_name; reason } ->
    Printf.sprintf "FAIL [%s]: %s" validator_name reason
;;
