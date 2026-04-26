(** Tests for [Keeper_personality_io.parse] and [.to_json] —
    samchon harness commit 1.

    Goal: pin the round-trip invariant from day one. parse(to_json(p)) = p
    for any [raw_personality]. The next commits in this PR add coerce,
    validate, merge_with_defaults, compare_normalized; each layer
    extends this test file rather than introducing a new round-trip
    surface. *)

open Alcotest
open Masc_mcp

let p_eq =
  testable
    (fun fmt (p : Keeper_personality_io.raw_personality) ->
      Format.fprintf fmt
        "{ will=%S; needs=%S; desires=%S; instructions=%S }" p.will p.needs
        p.desires p.instructions)
    ( = )

let make ?(will = "") ?(needs = "") ?(desires = "") ?(instructions = "") () :
    Keeper_personality_io.raw_personality =
  { will; needs; desires; instructions }

let json_of (p : Keeper_personality_io.raw_personality) : Yojson.Safe.t =
  `Assoc (Keeper_personality_io.to_json p)

(* nick0cave live data — 357-byte will, 322-byte desires (Layer 1 fix
   confirmed only this keeper exceeds prompt_render_max_bytes; we fix
   it as a regression fixture so the harness preserves byte-for-byte
   even at oversized inputs). *)
let nick0cave_will =
  "Manifest the unsung. Surface threads the room is sliding past—the \
   half-spoken claim, the conflict no one names, the operator note marked \
   stale. When others optimise throughput I optimise legibility: pause \
   the loop, restate the disagreement in plain words, attach the next \
   minimal experiment."

(* --------------------------------------------------------------------- *)
(* parse: defaults                                                       *)
(* --------------------------------------------------------------------- *)

let test_parse_empty_object_defaults_to_empty () =
  check p_eq "empty object → empty record" Keeper_personality_io.empty
    (Keeper_personality_io.parse (`Assoc []))

let test_parse_empty_object_with_defaults () =
  let defaults = make ~will:"d_will" ~needs:"d_needs" () in
  check p_eq "empty object → defaults" defaults
    (Keeper_personality_io.parse ~defaults (`Assoc []))

let test_parse_partial_object_picks_defaults_only_for_missing () =
  let defaults = make ~will:"d_will" ~needs:"d_needs" () in
  let json = `Assoc [ ("will", `String "explicit_will") ] in
  let expected = make ~will:"explicit_will" ~needs:"d_needs" () in
  check p_eq "partial object" expected
    (Keeper_personality_io.parse ~defaults json)

(* --------------------------------------------------------------------- *)
(* round-trip: to_json |> parse                                          *)
(* --------------------------------------------------------------------- *)

let round_trip p = Keeper_personality_io.parse (json_of p)

let test_round_trip_empty () =
  check p_eq "empty round-trip" Keeper_personality_io.empty
    (round_trip Keeper_personality_io.empty)

let test_round_trip_ascii () =
  let p =
    make ~will:"a will" ~needs:"a need" ~desires:"a desire"
      ~instructions:"some inst" ()
  in
  check p_eq "ascii round-trip" p (round_trip p)

let test_round_trip_korean_oversized () =
  let p =
    make ~will:nick0cave_will ~needs:"" ~desires:"another desire"
      ~instructions:"" ()
  in
  check p_eq "oversized utf8 round-trip" p (round_trip p)

let test_round_trip_with_whitespace_and_newlines () =
  let p =
    make ~will:"  trailing space  " ~needs:"\n\nleading newlines"
      ~desires:"trailing newline\n" ~instructions:"" ()
  in
  check p_eq "whitespace preserved on round-trip" p (round_trip p)

(* --------------------------------------------------------------------- *)
(* shape robustness                                                      *)
(* --------------------------------------------------------------------- *)

let test_parse_handles_non_string_field_via_default () =
  (* When a field is the wrong shape, Safe_ops.json_string returns the
     default — this is the existing behaviour we are preserving. *)
  let json =
    `Assoc [ ("will", `Int 42); ("needs", `String "ok needs") ]
  in
  let defaults = make ~will:"d_will" () in
  let expected = make ~will:"d_will" ~needs:"ok needs" () in
  check p_eq "wrong-shape field → default" expected
    (Keeper_personality_io.parse ~defaults json)

let () =
  run "keeper_personality_io_parse"
    [
      ( "parse defaults",
        [
          test_case "empty object → empty record" `Quick
            test_parse_empty_object_defaults_to_empty;
          test_case "empty object → defaults" `Quick
            test_parse_empty_object_with_defaults;
          test_case "partial object" `Quick
            test_parse_partial_object_picks_defaults_only_for_missing;
        ] );
      ( "round-trip",
        [
          test_case "empty" `Quick test_round_trip_empty;
          test_case "ascii" `Quick test_round_trip_ascii;
          test_case "korean oversized (nick0cave fixture)" `Quick
            test_round_trip_korean_oversized;
          test_case "whitespace + newlines preserved" `Quick
            test_round_trip_with_whitespace_and_newlines;
        ] );
      ( "shape robustness",
        [
          test_case "wrong-shape field → default" `Quick
            test_parse_handles_non_string_field_via_default;
        ] );
    ]
