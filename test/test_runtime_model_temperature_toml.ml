(** Tests for the per-model sampling fields in the [[models.<id>]] parser
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
    7. [top-p], [top-k], and [min-p] parse into model sampling fields.
    8. Sampling probability fields are finite numbers in [0.0, 1.0].
    9. [top-k] is a positive integer.
    10. [top-k]/[min-p] fail closed when declared model capabilities say the
        field is unsupported.

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

let parse_string_expect_error_entry label ~path ~message s =
  match Toml.parse_string s with
  | Ok _ -> failf "%s: expected parse error, got Ok" label
  | Error errors ->
    let found =
      List.exists
        (fun (err : Toml.parse_error) ->
           String.equal err.path path && String.equal err.message message)
        errors
    in
    check bool label true found
;;

let model_temperature cfg id =
  match List.find_opt (fun (m : Schema.model_spec) -> String.equal m.id id) cfg.Schema.models with
  | Some m -> m.Schema.temperature
  | None -> failf "model %S absent from parsed config" id
;;

let model_sampling cfg id =
  match List.find_opt (fun (m : Schema.model_spec) -> String.equal m.id id) cfg.Schema.models with
  | Some m -> m.Schema.top_p, m.Schema.top_k, m.Schema.min_p
  | None -> failf "model %S absent from parsed config" id
;;

(* A minimal valid [[models.<id>]] table needs [max-context]; [temperature] is
   optional and appended per case. *)
let model_toml ~extra_lines =
  Printf.sprintf "[models.m]\nmax-context = 200000\n%s" extra_lines
;;

let test_float_temperature_parses () =
  let cfg = parse_string_or_fail (model_toml ~extra_lines:"temperature = 1.0\n") in
  check (option (float 0.0001)) "temperature = 1.0 → Some 1.0" (Some 1.0) (model_temperature cfg "m")
;;

let test_integer_temperature_parses_as_float () =
  let cfg = parse_string_or_fail (model_toml ~extra_lines:"temperature = 1\n") in
  check (option (float 0.0001)) "temperature = 1 → Some 1.0" (Some 1.0) (model_temperature cfg "m")
;;

let test_zero_temperature_is_valid () =
  let cfg = parse_string_or_fail (model_toml ~extra_lines:"temperature = 0.0\n") in
  check (option (float 0.0001)) "temperature = 0.0 → Some 0.0 (greedy is valid)"
    (Some 0.0) (model_temperature cfg "m")
;;

let test_absent_temperature_is_none () =
  let cfg = parse_string_or_fail (model_toml ~extra_lines:"") in
  check (option (float 0.0001)) "absent temperature → None" None (model_temperature cfg "m")
;;

let test_out_of_range_temperature_fails_closed () =
  parse_string_expect_error "temperature = 5.0 (above 2.0 ceiling)"
    (model_toml ~extra_lines:"temperature = 5.0\n");
  parse_string_expect_error "temperature = -1.0 (below 0.0 floor)"
    (model_toml ~extra_lines:"temperature = -1.0\n")
;;

let test_non_number_temperature_fails_closed () =
  parse_string_expect_error "temperature = \"hot\" (not a number)"
    (model_toml ~extra_lines:"temperature = \"hot\"\n")
;;

let test_sampling_fields_parse () =
  let cfg =
    parse_string_or_fail
      (model_toml ~extra_lines:"top-p = 0.91\ntop-k = 42\nmin-p = 0.07\n")
  in
  let top_p, top_k, min_p = model_sampling cfg "m" in
  check (option (float 0.0001)) "top-p parses" (Some 0.91) top_p;
  check (option int) "top-k parses" (Some 42) top_k;
  check (option (float 0.0001)) "min-p parses" (Some 0.07) min_p
;;

let test_sampling_probability_integer_bounds_parse () =
  let cfg =
    parse_string_or_fail (model_toml ~extra_lines:"top-p = 1\nmin-p = 0\n")
  in
  let top_p, top_k, min_p = model_sampling cfg "m" in
  check (option (float 0.0001)) "top-p = 1 parses" (Some 1.0) top_p;
  check (option int) "absent top-k remains None" None top_k;
  check (option (float 0.0001)) "min-p = 0 parses" (Some 0.0) min_p
;;

let test_sampling_fields_parse_with_declared_capabilities () =
  let cfg =
    parse_string_or_fail
      (model_toml
         ~extra_lines:
           "top-k = 42\nmin-p = 0.07\n[models.m.capabilities]\nsupports-top-k = true\nsupports-min-p = true\n")
  in
  let _, top_k, min_p = model_sampling cfg "m" in
  check (option int) "top-k parses when declared supported" (Some 42) top_k;
  check (option (float 0.0001)) "min-p parses when declared supported" (Some 0.07) min_p
;;

let test_absent_sampling_fields_are_none () =
  let cfg = parse_string_or_fail (model_toml ~extra_lines:"") in
  let top_p, top_k, min_p = model_sampling cfg "m" in
  check (option (float 0.0001)) "absent top-p" None top_p;
  check (option int) "absent top-k" None top_k;
  check (option (float 0.0001)) "absent min-p" None min_p
;;

let test_sampling_probability_out_of_range_fails_closed () =
  parse_string_expect_error "top-p = 1.1 (above probability ceiling)"
    (model_toml ~extra_lines:"top-p = 1.1\n");
  parse_string_expect_error "min-p = -0.1 (below probability floor)"
    (model_toml ~extra_lines:"min-p = -0.1\n")
;;

let test_sampling_probability_non_number_fails_closed () =
  parse_string_expect_error "top-p = \"wide\" (not a number)"
    (model_toml ~extra_lines:"top-p = \"wide\"\n");
  parse_string_expect_error "min-p = \"narrow\" (not a number)"
    (model_toml ~extra_lines:"min-p = \"narrow\"\n")
;;

let test_top_k_invalid_values_fail_closed () =
  parse_string_expect_error "top-k = 0 (not positive)"
    (model_toml ~extra_lines:"top-k = 0\n");
  parse_string_expect_error "top-k = 1.5 (not integer)"
    (model_toml ~extra_lines:"top-k = 1.5\n")
;;

let test_sampling_fields_conflicting_declared_capabilities_fail_closed () =
  let content =
    model_toml
      ~extra_lines:
        "top-k = 42\nmin-p = 0.07\n[models.m.capabilities]\nsupports-top-k = false\nsupports-min-p = false\n"
  in
  parse_string_expect_error_entry
    "top-k conflicts with declared capabilities"
    ~path:"models.m.top-k"
    ~message:"top-k is set but models.m.capabilities.supports-top-k is false"
    content;
  parse_string_expect_error_entry
    "min-p conflicts with declared capabilities"
    ~path:"models.m.min-p"
    ~message:"min-p is set but models.m.capabilities.supports-min-p is false"
    content
;;

let () =
  run "runtime_model_temperature_toml"
    [ ( "valid values"
      , [ test_case "float temperature parses" `Quick test_float_temperature_parses
        ; test_case "integer temperature parses as float" `Quick
            test_integer_temperature_parses_as_float
        ; test_case "zero temperature is valid (greedy)" `Quick test_zero_temperature_is_valid
        ; test_case "absent temperature is None" `Quick test_absent_temperature_is_none
        ; test_case "sampling fields parse" `Quick test_sampling_fields_parse
        ; test_case "sampling probability integer bounds parse" `Quick
            test_sampling_probability_integer_bounds_parse
        ; test_case "sampling fields parse with declared capabilities" `Quick
            test_sampling_fields_parse_with_declared_capabilities
        ; test_case "absent sampling fields are None" `Quick
            test_absent_sampling_fields_are_none
        ] )
    ; ( "invalid values fail closed"
      , [ test_case "out-of-range temperature fails parse" `Quick
            test_out_of_range_temperature_fails_closed
        ; test_case "non-number temperature fails parse" `Quick
            test_non_number_temperature_fails_closed
        ; test_case "sampling probability out-of-range fails parse" `Quick
            test_sampling_probability_out_of_range_fails_closed
        ; test_case "sampling probability non-number fails parse" `Quick
            test_sampling_probability_non_number_fails_closed
        ; test_case "top-k invalid values fail parse" `Quick
            test_top_k_invalid_values_fail_closed
        ; test_case "sampling fields conflict with declared capabilities" `Quick
            test_sampling_fields_conflicting_declared_capabilities_fail_closed
        ] )
    ]
;;
