(** Tests for the [[pause]] section parser in [Runtime_toml].

    Pinned invariants (RFC-0047 PR-5):

    1. Missing [[pause]] section → every field falls back to
       [Runtime_schema.pause_threshold_default]. The default mirrors the
       legacy hardcoded values in [Keeper_behavioral_regime.ml:46-50],
       which are the in-code fallback only — runtime.toml is the typed
       SSOT going forward.

    2. A complete [[pause]] table → every field is parsed verbatim into
       the corresponding record field; no implicit clamping, no rounding.

    3. A partial [[pause]] table → missing keys fall back to the default
       field value; supplied keys override only that field.

    4. A wrong-typed value (e.g. string for an int field) does NOT
       propagate the bad value: the parser logs a warning and the field
       reverts to the default. The other fields in the same table still
       parse normally. *)

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

let field_defaults = Schema.pause_threshold_default

(* ── 1. Missing [[pause]] section ────────────────────────────── *)

let test_missing_pause_section_uses_defaults () =
  let cfg =
    parse_string_or_fail
      "[providers.local-ollama]\n\
       protocol = \"ollama-http\"\n\
       endpoint = \"http://127.0.0.1:11434\"\n"
  in
  check int
    "turn_fail_streak_threshold default when [pause] missing"
    field_defaults.turn_fail_streak_threshold
    cfg.Schema.pause_threshold.turn_fail_streak_threshold;
  check (float 0.0001)
    "recent_restart_window_sec default when [pause] missing"
    field_defaults.recent_restart_window_sec
    cfg.pause_threshold.recent_restart_window_sec;
  check int
    "recent_restart_count_threshold default when [pause] missing"
    field_defaults.recent_restart_count_threshold
    cfg.pause_threshold.recent_restart_count_threshold;
  check int
    "tool_failure_count_threshold default when [pause] missing"
    field_defaults.tool_failure_count_threshold
    cfg.pause_threshold.tool_failure_count_threshold;
  check (float 0.0001)
    "tool_failure_ratio_threshold default when [pause] missing"
    field_defaults.tool_failure_ratio_threshold
    cfg.pause_threshold.tool_failure_ratio_threshold
;;

let test_empty_pause_section_uses_defaults () =
  (* An empty [[pause]] table — every key absent — must still fall back to
     defaults field-by-field. This is distinct from "section missing"
     only in TOML parse semantics; the runtime result must be
     byte-identical. *)
  let cfg = parse_string_or_fail "[pause]\n" in
  check int
    "empty [pause] turn_fail_streak_threshold"
    field_defaults.turn_fail_streak_threshold
    cfg.pause_threshold.turn_fail_streak_threshold;
  check (float 0.0001)
    "empty [pause] recent_restart_window_sec"
    field_defaults.recent_restart_window_sec
    cfg.pause_threshold.recent_restart_window_sec
;;

(* ── 2. Complete [[pause]] section ───────────────────────────── *)

let test_complete_pause_section_applies_all_fields () =
  let cfg =
    parse_string_or_fail
      "[pause]\n\
       turn_fail_streak_threshold = 7\n\
       recent_restart_window_sec = 600.5\n\
       recent_restart_count_threshold = 4\n\
       tool_failure_count_threshold = 11\n\
       tool_failure_ratio_threshold = 0.42\n"
  in
  let pt = cfg.pause_threshold in
  check int "turn_fail_streak_threshold" 7 pt.turn_fail_streak_threshold;
  check (float 0.0001) "recent_restart_window_sec" 600.5 pt.recent_restart_window_sec;
  check int "recent_restart_count_threshold" 4 pt.recent_restart_count_threshold;
  check int "tool_failure_count_threshold" 11 pt.tool_failure_count_threshold;
  check (float 0.0001) "tool_failure_ratio_threshold" 0.42 pt.tool_failure_ratio_threshold
;;

(* ── 3. Partial [[pause]] section ────────────────────────────── *)

let test_partial_pause_section_falls_back_field_by_field () =
  let cfg =
    parse_string_or_fail
      "[pause]\n\
       turn_fail_streak_threshold = 9\n"
  in
  let pt = cfg.pause_threshold in
  check int "supplied turn_fail_streak_threshold" 9 pt.turn_fail_streak_threshold;
  check (float 0.0001)
    "missing recent_restart_window_sec → default"
    field_defaults.recent_restart_window_sec
    pt.recent_restart_window_sec;
  check int
    "missing recent_restart_count_threshold → default"
    field_defaults.recent_restart_count_threshold
    pt.recent_restart_count_threshold;
  check int
    "missing tool_failure_count_threshold → default"
    field_defaults.tool_failure_count_threshold
    pt.tool_failure_count_threshold;
  check (float 0.0001)
    "missing tool_failure_ratio_threshold → default"
    field_defaults.tool_failure_ratio_threshold
    pt.tool_failure_ratio_threshold
;;

(* ── 4. Wrong-typed value falls back to default ──────────────── *)

let test_wrong_type_int_field_falls_back_to_default () =
  (* A string value in an integer-typed field must NOT be coerced, must
     NOT abort the parse, and must NOT bleed into other fields. The
     supplier (Runtime_toml.parse_pause_threshold) emits a Log.Runtime.warn
     line, then falls back to the default for that field only. *)
  let cfg =
    parse_string_or_fail
      "[pause]\n\
       turn_fail_streak_threshold = \"definitely_not_an_int\"\n\
       recent_restart_window_sec = 600.5\n\
       recent_restart_count_threshold = 4\n"
  in
  let pt = cfg.pause_threshold in
  check int
    "wrong-typed turn_fail_streak_threshold → default"
    field_defaults.turn_fail_streak_threshold
    pt.turn_fail_streak_threshold;
  check (float 0.0001)
    "neighbor recent_restart_window_sec still parsed"
    600.5
    pt.recent_restart_window_sec;
  check int
    "neighbor recent_restart_count_threshold still parsed"
    4
    pt.recent_restart_count_threshold
;;

let test_wrong_type_float_field_falls_back_to_default () =
  let cfg =
    parse_string_or_fail
      "[pause]\n\
       recent_restart_window_sec = \"600_seconds\"\n\
       tool_failure_ratio_threshold = 0.42\n"
  in
  let pt = cfg.pause_threshold in
  check (float 0.0001)
    "wrong-typed recent_restart_window_sec → default"
    field_defaults.recent_restart_window_sec
    pt.recent_restart_window_sec;
  check (float 0.0001)
    "neighbor tool_failure_ratio_threshold still parsed"
    0.42
    pt.tool_failure_ratio_threshold
;;

(* ── 5. Round-trip stability ────────────────────────────────── *)

let test_pause_threshold_values_are_byte_stable_across_parses () =
  (* Two parses of the same TOML must yield structurally equal
     [pause_threshold] records. This guards against parser-local mutable
     state leaking across calls (the parser is supposed to be pure). *)
  let toml =
    "[pause]\n\
     turn_fail_streak_threshold = 7\n\
     recent_restart_window_sec = 600.5\n\
     recent_restart_count_threshold = 4\n\
     tool_failure_count_threshold = 11\n\
     tool_failure_ratio_threshold = 0.42\n"
  in
  let cfg1 = parse_string_or_fail toml in
  let cfg2 = parse_string_or_fail toml in
  check bool
    "pause_threshold structurally equal across parses"
    true
    (Schema.equal_pause_threshold cfg1.pause_threshold cfg2.pause_threshold)
;;

let test_pause_threshold_default_is_byte_stable () =
  (* Defensive: the field defaults the parser falls back to must not
     drift silently. If a future PR edits
     [Runtime_schema.pause_threshold_default], the keeper behavioral
     regime's in-code fallback (keeper_behavioral_regime.ml:52-56) must
     change in lockstep — this test is the tripwire. *)
  check int
    "default turn_fail_streak_threshold = 3"
    3
    Schema.pause_threshold_default.turn_fail_streak_threshold;
  check (float 0.0001)
    "default recent_restart_window_sec = 300"
    300.0
    Schema.pause_threshold_default.recent_restart_window_sec;
  check int
    "default recent_restart_count_threshold = 2"
    2
    Schema.pause_threshold_default.recent_restart_count_threshold;
  check int
    "default tool_failure_count_threshold = 3"
    3
    Schema.pause_threshold_default.tool_failure_count_threshold;
  check (float 0.0001)
    "default tool_failure_ratio_threshold = 0.7"
    0.7
    Schema.pause_threshold_default.tool_failure_ratio_threshold
;;

let () =
  run "runtime_pause_threshold_toml"
    [ ( "missing-section fallback"
      , [ test_case "missing [pause] section uses defaults" `Quick
            test_missing_pause_section_uses_defaults
        ; test_case "empty [pause] table uses defaults" `Quick
            test_empty_pause_section_uses_defaults
        ] )
    ; ( "complete-section round-trip"
      , [ test_case "complete [pause] applies all fields verbatim" `Quick
            test_complete_pause_section_applies_all_fields
        ] )
    ; ( "partial-section fallback"
      , [ test_case "partial [pause] falls back field-by-field" `Quick
            test_partial_pause_section_falls_back_field_by_field
        ] )
    ; ( "wrong-typed value fails closed"
      , [ test_case "wrong-typed int field falls back to default" `Quick
            test_wrong_type_int_field_falls_back_to_default
        ; test_case "wrong-typed float field falls back to default" `Quick
            test_wrong_type_float_field_falls_back_to_default
        ] )
    ; ( "stability"
      , [ test_case "pause_threshold byte-stable across parses" `Quick
            test_pause_threshold_values_are_byte_stable_across_parses
        ; test_case "pause_threshold_default field values pinned" `Quick
            test_pause_threshold_default_is_byte_stable
        ] )
    ]
;;
