(** Tests for the [[pacing]] section parser in [Runtime_toml] (RFC-0313 W3).

    Pinned invariants:

    1. Missing [[pacing]] section → [Runtime_schema.pacing_default]
       (mode = enforce, base 30s, x2, cap 3600s). The default IS the W3
       behavior flip; shadow is the explicit kill-switch position.

    2. mode = "shadow" / "enforce" parse to the corresponding variant;
       numeric knobs parse verbatim.

    3. An unknown [mode] value fails the whole config parse (fail-closed):
       a typo like "enfoce" must not silently revert the flip to shadow.

    4. A wrong-typed numeric knob falls back to its default field-by-field
       (fail-soft, same contract as [[pause]]). *)

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

let d = Schema.pacing_default

let test_missing_pacing_section_uses_defaults () =
  let cfg =
    parse_string_or_fail
      "[providers.local-ollama]\n\
       protocol = \"ollama-http\"\n\
       endpoint = \"http://127.0.0.1:11434\"\n"
  in
  check bool
    "missing [pacing] defaults to enforce"
    true
    (Schema.equal_pacing_mode cfg.Schema.pacing.pacing_mode Schema.Pacing_enforce);
  check (float 0.0001) "base_sec default" d.pacing_base_sec
    cfg.pacing.pacing_base_sec;
  check (float 0.0001) "multiplier default" d.pacing_multiplier
    cfg.pacing.pacing_multiplier;
  check (float 0.0001) "cap_sec default" d.pacing_cap_sec cfg.pacing.pacing_cap_sec
;;

let test_shadow_mode_and_knobs_parse_verbatim () =
  let cfg =
    parse_string_or_fail
      "[pacing]\n\
       mode = \"shadow\"\n\
       base_sec = 12.5\n\
       multiplier = 3.0\n\
       cap_sec = 900.0\n"
  in
  check bool
    "mode = shadow parses"
    true
    (Schema.equal_pacing_mode cfg.pacing.pacing_mode Schema.Pacing_shadow);
  check (float 0.0001) "base_sec verbatim" 12.5 cfg.pacing.pacing_base_sec;
  check (float 0.0001) "multiplier verbatim" 3.0 cfg.pacing.pacing_multiplier;
  check (float 0.0001) "cap_sec verbatim" 900.0 cfg.pacing.pacing_cap_sec
;;

let test_enforce_mode_parses () =
  let cfg = parse_string_or_fail "[pacing]\nmode = \"enforce\"\n" in
  check bool
    "mode = enforce parses"
    true
    (Schema.equal_pacing_mode cfg.pacing.pacing_mode Schema.Pacing_enforce)
;;

let test_unknown_mode_fails_config_parse () =
  match Toml.parse_string "[pacing]\nmode = \"enfoce\"\n" with
  | Ok _ ->
    fail "unknown pacing mode must abort config parse, not default silently"
  | Error errs ->
    check bool
      "error names pacing.mode"
      true
      (List.exists
         (fun (e : Toml.parse_error) -> String.equal e.path "pacing.mode")
         errs)
;;

let test_wrong_typed_mode_fails_config_parse () =
  match Toml.parse_string "[pacing]\nmode = 3\n" with
  | Ok _ -> fail "wrong-typed pacing mode must abort config parse"
  | Error errs ->
    check bool
      "error names pacing.mode"
      true
      (List.exists
         (fun (e : Toml.parse_error) -> String.equal e.path "pacing.mode")
         errs)
;;

let test_wrong_typed_numeric_knob_falls_back () =
  let cfg =
    parse_string_or_fail
      "[pacing]\n\
       base_sec = \"thirty\"\n\
       multiplier = 3.0\n"
  in
  check (float 0.0001)
    "wrong-typed base_sec → default"
    d.pacing_base_sec
    cfg.pacing.pacing_base_sec;
  check (float 0.0001)
    "neighbor multiplier still parsed"
    3.0
    cfg.pacing.pacing_multiplier
;;

let test_pacing_default_is_pinned () =
  (* Tripwire: these values are mirrored by the fixture policies in
     test_keeper_pacing.ml / test_keeper_pacing_replay.ml, whose asserted
     schedules ([0; 30; 90; 210]) derive from them. Change in lockstep. *)
  check bool
    "default mode = enforce"
    true
    (Schema.equal_pacing_mode d.pacing_mode Schema.Pacing_enforce);
  check (float 0.0001) "default base_sec = 30" 30.0 d.pacing_base_sec;
  check (float 0.0001) "default multiplier = 2" 2.0 d.pacing_multiplier;
  check (float 0.0001) "default cap_sec = 3600" 3600.0 d.pacing_cap_sec
;;

let () =
  run "runtime_pacing_toml"
    [ ( "missing-section fallback"
      , [ test_case "missing [pacing] uses enforce defaults" `Quick
            test_missing_pacing_section_uses_defaults
        ] )
    ; ( "mode parse"
      , [ test_case "shadow mode + knobs verbatim" `Quick
            test_shadow_mode_and_knobs_parse_verbatim
        ; test_case "enforce mode parses" `Quick test_enforce_mode_parses
        ] )
    ; ( "mode fails closed"
      , [ test_case "unknown mode aborts config parse" `Quick
            test_unknown_mode_fails_config_parse
        ; test_case "wrong-typed mode aborts config parse" `Quick
            test_wrong_typed_mode_fails_config_parse
        ] )
    ; ( "numeric knobs fail soft"
      , [ test_case "wrong-typed base_sec falls back" `Quick
            test_wrong_typed_numeric_knob_falls_back
        ] )
    ; ( "defaults pinned"
      , [ test_case "pacing_default field values pinned" `Quick
            test_pacing_default_is_pinned
        ] )
    ]
;;
