(** Tests for the per-model [temperature] field in the [[models.<id>]] parser
    ([Runtime_toml.parse_model]).

    Pinned invariants:

    1. [temperature = 1.0] (float) parses to [Some 1.0].
    2. [temperature = 1] (integer) parses to [Some 1.0] — an operator writing
       the bare integer is not tripped by "1 vs 1.0".
    3. [temperature = 0.0] (greedy) is a valid value → [Some 0.0]; temperature
       is NOT a positive-only field.
    4. Absent [temperature] → [None]; the caller keeps its fallback
       ([MASC_KEEPER_UNIFIED_TEMP] / the OAS agent_default profile).
    5. An out-of-range value (outside [0.0, 2.0]) fails the parse (fail-closed):
       an invalid temperature is rejected at load rather than sent to the
       provider, which would reject it at request time.
    6. A non-number value fails the parse.

    Motivation: Kimi K2.7 (kimi-for-coding) accepts only [temperature = 1.0] and
    rejects any other value ("only 1 is allowed for this model"). This field lets
    runtime.toml pin that per model; [Runtime_inference.resolve_temperature]
    consumes it via [Runtime.temperature_of_runtime_id]. *)

open Alcotest

module Schema = Runtime_schema
module Toml = Runtime_toml

let parse_string_or_fail s =
  match Toml.parse_string s with
  | Ok cfg -> cfg
  | Error errs ->
    let rendered =
      errs
      |> List.map (fun (e : Toml.parse_error) ->
        Printf.sprintf "[%s] %s" e.path e.message)
      |> String.concat "; "
    in
    failf "parse_string failed: %s" rendered
;;

let parse_string_expect_error label s =
  match Toml.parse_string s with
  | Ok _ -> failf "%s: expected parse error, got Ok" label
  | Error _ -> ()
;;

let model_temperature cfg id =
  match List.find_opt (fun (m : Schema.model_spec) -> String.equal m.id id) cfg.Schema.models with
  | Some m -> m.Schema.temperature
  | None -> failf "model %S absent from parsed config" id
;;

(* A minimal valid [[models.<id>]] table needs [max-context]; [temperature] is
   optional and appended per case. *)
let model_toml ~temperature_line =
  Printf.sprintf "[models.m]\nmax-context = 200000\n%s" temperature_line
;;

let test_float_temperature_parses () =
  let cfg = parse_string_or_fail (model_toml ~temperature_line:"temperature = 1.0\n") in
  check (option (float 0.0001)) "temperature = 1.0 → Some 1.0" (Some 1.0) (model_temperature cfg "m")
;;

let test_integer_temperature_parses_as_float () =
  let cfg = parse_string_or_fail (model_toml ~temperature_line:"temperature = 1\n") in
  check (option (float 0.0001)) "temperature = 1 → Some 1.0" (Some 1.0) (model_temperature cfg "m")
;;

let test_zero_temperature_is_valid () =
  let cfg = parse_string_or_fail (model_toml ~temperature_line:"temperature = 0.0\n") in
  check (option (float 0.0001)) "temperature = 0.0 → Some 0.0 (greedy is valid)"
    (Some 0.0) (model_temperature cfg "m")
;;

let test_absent_temperature_is_none () =
  let cfg = parse_string_or_fail (model_toml ~temperature_line:"") in
  check (option (float 0.0001)) "absent temperature → None" None (model_temperature cfg "m")
;;

let test_out_of_range_temperature_fails_closed () =
  parse_string_expect_error "temperature = 5.0 (above 2.0 ceiling)"
    (model_toml ~temperature_line:"temperature = 5.0\n");
  parse_string_expect_error "temperature = -1.0 (below 0.0 floor)"
    (model_toml ~temperature_line:"temperature = -1.0\n")
;;

let test_non_number_temperature_fails_closed () =
  parse_string_expect_error "temperature = \"hot\" (not a number)"
    (model_toml ~temperature_line:"temperature = \"hot\"\n")
;;

let () =
  run "runtime_model_temperature_toml"
    [ ( "valid values"
      , [ test_case "float temperature parses" `Quick test_float_temperature_parses
        ; test_case "integer temperature parses as float" `Quick
            test_integer_temperature_parses_as_float
        ; test_case "zero temperature is valid (greedy)" `Quick test_zero_temperature_is_valid
        ; test_case "absent temperature is None" `Quick test_absent_temperature_is_none
        ] )
    ; ( "invalid values fail closed"
      , [ test_case "out-of-range temperature fails parse" `Quick
            test_out_of_range_temperature_fails_closed
        ; test_case "non-number temperature fails parse" `Quick
            test_non_number_temperature_fails_closed
        ] )
    ]
;;
