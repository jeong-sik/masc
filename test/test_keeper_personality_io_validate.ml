(** Tests for [Keeper_personality_io.check_byte_caps] — samchon
    harness commit 3.

    Validate is diagnostic-only: warnings are produced but the input
    is never transformed (per Decision Resolution "Both + 입력 경계
    검증" — write raw, soft-warn at boundary). *)

open Alcotest
open Masc_mcp

let make ?(will = "") ?(needs = "") ?(desires = "") ?(instructions = "") ()
  : Keeper_personality_io.raw_personality
  =
  { will; needs; desires; instructions }
;;

let coerce p = Keeper_personality_io.coerce p

(* nick0cave-shaped fixture: deterministic 357-byte string mirroring
   the actual nick0cave will length on disk (Layer 1 fix evidence,
   2026-04-26). Using String.make so the exact byte count is verifiable
   and not dependent on OCaml string-literal line-continuation rules
   (which strip leading whitespace after [\<NL>]). *)
let nick0cave_will = String.make 357 'a'
let nick0cave_desires = String.make 322 'a'
(* exact 322 bytes, only over the 320 cap, simulates nick0cave desires
   structurally without quoting Korean prose. *)

let test_empty_returns_no_warnings () =
  let warnings = Keeper_personality_io.check_byte_caps (coerce (make ())) in
  check int "no warnings on empty" 0 (List.length warnings)
;;

let test_within_cap_returns_no_warnings () =
  let p =
    make
      ~will:(String.make 100 'x')
      ~needs:(String.make 50 'y')
      ~desires:(String.make 200 'z')
      ~instructions:""
      ()
  in
  let warnings = Keeper_personality_io.check_byte_caps (coerce p) in
  check int "no warnings under cap" 0 (List.length warnings)
;;

let test_oversized_will_emits_one_warning () =
  let p = make ~will:nick0cave_will () in
  let warnings = Keeper_personality_io.check_byte_caps (coerce p) in
  check int "one warning" 1 (List.length warnings);
  let w = List.hd warnings in
  check string "field is will" "will" (Keeper_personality_io.field_to_string w.field);
  check int "observed bytes" (String.length nick0cave_will) w.observed_bytes;
  check int "cap bytes" Keeper_config.prompt_render_max_bytes w.cap_bytes
;;

let test_two_oversized_fields_emit_two_warnings () =
  let p = make ~will:nick0cave_will ~desires:nick0cave_desires () in
  let warnings = Keeper_personality_io.check_byte_caps (coerce p) in
  check int "two warnings" 2 (List.length warnings);
  let fields =
    List.map
      (fun (w : Keeper_personality_io.cap_warning) ->
         Keeper_personality_io.field_to_string w.field)
      warnings
    |> List.sort compare
  in
  check (list string) "both fields reported" [ "desires"; "will" ] fields
;;

let test_custom_max_bytes_overrides_default () =
  let p = make ~will:(String.make 50 'x') () in
  let warnings = Keeper_personality_io.check_byte_caps ~max_bytes:30 (coerce p) in
  check int "warning at custom cap" 1 (List.length warnings);
  let w = List.hd warnings in
  check int "cap is custom value" 30 w.cap_bytes;
  check int "observed is byte length" 50 w.observed_bytes
;;

let test_does_not_transform_input () =
  (* Verify the diagnostic-only contract: a value that triggered a
     warning must round-trip unchanged through to_raw. *)
  let p = make ~will:nick0cave_will () in
  let coerced = coerce p in
  let _warnings = Keeper_personality_io.check_byte_caps coerced in
  let raw_after = Keeper_personality_io.to_raw coerced in
  check string "will byte-identical after validate" nick0cave_will raw_after.will
;;

let test_warning_hint_is_human_readable () =
  let p = make ~will:nick0cave_will () in
  let warnings = Keeper_personality_io.check_byte_caps (coerce p) in
  let w = List.hd warnings in
  check
    bool
    "hint mentions will"
    true
    (let prefix = "will " in
     String.length w.hint >= String.length prefix
     && String.sub w.hint 0 (String.length prefix) = prefix);
  check bool "hint is non-empty" true (String.length w.hint > 0)
;;

let () =
  run
    "keeper_personality_io_validate"
    [ ( "no warnings"
      , [ test_case "empty input" `Quick test_empty_returns_no_warnings
        ; test_case "all fields under cap" `Quick test_within_cap_returns_no_warnings
        ] )
    ; ( "warnings"
      , [ test_case
            "one oversized field → 1 warning"
            `Quick
            test_oversized_will_emits_one_warning
        ; test_case
            "two oversized fields → 2 warnings"
            `Quick
            test_two_oversized_fields_emit_two_warnings
        ; test_case
            "custom max_bytes overrides default"
            `Quick
            test_custom_max_bytes_overrides_default
        ] )
    ; ( "diagnostic contract"
      , [ test_case
            "validate does not transform input"
            `Quick
            test_does_not_transform_input
        ; test_case
            "warning hint is human readable"
            `Quick
            test_warning_hint_is_human_readable
        ] )
    ]
;;
