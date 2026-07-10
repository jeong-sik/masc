(** Tests for [Keeper_personality_io.check_byte_caps] — samchon
    harness commit 3.

    Validate is diagnostic-only: warnings are produced but the input
    is never transformed (per Decision Resolution "Both + 입력 경계
    검증" — write raw, soft-warn at boundary). RFC-0282 reduced the
    persona harness to the single [instructions] field. *)

open Alcotest
open Masc

let make ?(instructions = "") () : Keeper_personality_io.raw_personality =
  { instructions }

let coerce p = Keeper_personality_io.coerce p

(* nick0cave-shaped fixture: deterministic 357-byte string mirroring
   the actual nick0cave instructions length on disk (Layer 1 fix
   evidence, 2026-04-26). Sized at [prompt_render_max_bytes + 37] so it
   exceeds whatever cap the runtime resolves (default 4096, override via
   MASC_KEEPER_PROMPT_RENDER_MAX_BYTES). Using String.make so the byte count
   is verifiable and not dependent on OCaml string-literal
   line-continuation rules (which strip leading whitespace after
   [\<NL>]). *)
let nick0cave_instructions =
  String.make (Keeper_config.prompt_render_max_bytes + 37) 'a'

let test_empty_returns_no_warnings () =
  let warnings = Keeper_personality_io.check_byte_caps (coerce (make ())) in
  check int "no warnings on empty" 0 (List.length warnings)

let test_within_cap_returns_no_warnings () =
  let p = make ~instructions:(String.make 100 'x') () in
  let warnings = Keeper_personality_io.check_byte_caps (coerce p) in
  check int "no warnings under cap" 0 (List.length warnings)

let test_oversized_instructions_emits_one_warning () =
  let p = make ~instructions:nick0cave_instructions () in
  let warnings = Keeper_personality_io.check_byte_caps (coerce p) in
  check int "one warning" 1 (List.length warnings);
  let w = List.hd warnings in
  check string "field is instructions" "instructions"
    (Keeper_personality_io.field_to_string w.field);
  check int "observed bytes"
    (String.length nick0cave_instructions) w.observed_bytes;
  check int "cap bytes" Keeper_config.prompt_render_max_bytes w.cap_bytes

let test_custom_max_bytes_overrides_default () =
  let p = make ~instructions:(String.make 50 'x') () in
  let warnings =
    Keeper_personality_io.check_byte_caps ~max_bytes:30 (coerce p)
  in
  check int "warning at custom cap" 1 (List.length warnings);
  let w = List.hd warnings in
  check int "cap is custom value" 30 w.cap_bytes;
  check int "observed is byte length" 50 w.observed_bytes

let test_does_not_transform_input () =
  (* Verify the diagnostic-only contract: a value that triggered a
     warning must round-trip unchanged through to_raw. *)
  let p = make ~instructions:nick0cave_instructions () in
  let coerced = coerce p in
  let _warnings = Keeper_personality_io.check_byte_caps coerced in
  let raw_after = Keeper_personality_io.to_raw coerced in
  check string "instructions byte-identical after validate"
    nick0cave_instructions raw_after.instructions

let test_warning_hint_is_human_readable () =
  let p = make ~instructions:nick0cave_instructions () in
  let warnings = Keeper_personality_io.check_byte_caps (coerce p) in
  let w = List.hd warnings in
  check bool "hint mentions instructions" true
    (let prefix = "instructions " in
     String.length w.hint >= String.length prefix
     && String.sub w.hint 0 (String.length prefix) = prefix);
  check bool "hint is non-empty" true (String.length w.hint > 0)

let () =
  run "keeper_personality_io_validate"
    [
      ( "no warnings",
        [
          test_case "empty input" `Quick test_empty_returns_no_warnings;
          test_case "field under cap" `Quick
            test_within_cap_returns_no_warnings;
        ] );
      ( "warnings",
        [
          test_case "oversized field → 1 warning" `Quick
            test_oversized_instructions_emits_one_warning;
          test_case "custom max_bytes overrides default" `Quick
            test_custom_max_bytes_overrides_default;
        ] );
      ( "diagnostic contract",
        [
          test_case "validate does not transform input" `Quick
            test_does_not_transform_input;
          test_case "warning hint is human readable" `Quick
            test_warning_hint_is_human_readable;
        ] );
    ]
