(** Tests for [Keeper_personality_io.coerce] — samchon harness commit 2. *)

open Alcotest
open Masc_mcp

let p_eq =
  testable
    (fun fmt (p : Keeper_personality_io.raw_personality) ->
       Format.fprintf
         fmt
         "{ will=%S; needs=%S; desires=%S; instructions=%S }"
         p.will
         p.needs
         p.desires
         p.instructions)
    ( = )
;;

let make ?(will = "") ?(needs = "") ?(desires = "") ?(instructions = "") ()
  : Keeper_personality_io.raw_personality
  =
  { will; needs; desires; instructions }
;;

let coerce_to_raw p = Keeper_personality_io.to_raw (Keeper_personality_io.coerce p)

let nick0cave_will =
  "Manifest the unsung. Surface threads the room is sliding past—the half-spoken claim, \
   the conflict no one names, the operator note marked stale. When others optimise \
   throughput I optimise legibility: pause the loop, restate the disagreement in plain \
   words, attach the next minimal experiment."
;;

(* --------------------------------------------------------------------- *)
(* trim semantics                                                        *)
(* --------------------------------------------------------------------- *)

let test_coerce_trims_leading_trailing_whitespace () =
  let p =
    make
      ~will:"  surrounded  "
      ~needs:"\t\ttabbed\t\t"
      ~desires:"\n\nnewlines\n\n"
      ~instructions:""
      ()
  in
  let expected = make ~will:"surrounded" ~needs:"tabbed" ~desires:"newlines" () in
  check p_eq "trim whitespace from all four fields" expected (coerce_to_raw p)
;;

let test_coerce_preserves_inner_whitespace () =
  let p =
    make ~will:"  hello world  " ~needs:"  multi\nline  " ~desires:"  tabs\there  " ()
  in
  let expected = make ~will:"hello world" ~needs:"multi\nline" ~desires:"tabs\there" () in
  check p_eq "inner whitespace preserved" expected (coerce_to_raw p)
;;

let test_coerce_empty_fields_stay_empty () =
  check
    p_eq
    "empty stays empty"
    Keeper_personality_io.empty
    (coerce_to_raw Keeper_personality_io.empty)
;;

let test_coerce_only_whitespace_becomes_empty () =
  let p = make ~will:"   " ~needs:"\t\n  \n" ~desires:"\n" () in
  check
    p_eq
    "only-whitespace fields collapse to empty"
    Keeper_personality_io.empty
    (coerce_to_raw p)
;;

(* --------------------------------------------------------------------- *)
(* idempotency: coerce(coerce(p)) = coerce(p)                            *)
(* --------------------------------------------------------------------- *)

let test_coerce_is_idempotent () =
  let inputs =
    [ Keeper_personality_io.empty
    ; make ~will:"clean" ~needs:"clean" ~desires:"clean" ()
    ; make ~will:"  with whitespace  " ~needs:"\nnewline-prefix" ()
    ; make ~will:nick0cave_will ()
    ]
  in
  List.iter
    (fun p ->
       let once = coerce_to_raw p in
       let twice = coerce_to_raw once in
       check p_eq "coerce idempotent" once twice)
    inputs
;;

(* --------------------------------------------------------------------- *)
(* nick0cave fixture: oversized utf8 trims correctly                     *)
(* --------------------------------------------------------------------- *)

let test_coerce_oversized_utf8_unchanged_when_no_surrounding_whitespace () =
  let p = make ~will:nick0cave_will () in
  let coerced = coerce_to_raw p in
  check
    string
    "oversized utf8 byte-identical when no whitespace"
    nick0cave_will
    coerced.will
;;

let () =
  run
    "keeper_personality_io_coerce"
    [ ( "trim semantics"
      , [ test_case
            "trims leading + trailing whitespace"
            `Quick
            test_coerce_trims_leading_trailing_whitespace
        ; test_case
            "preserves inner whitespace"
            `Quick
            test_coerce_preserves_inner_whitespace
        ; test_case "empty stays empty" `Quick test_coerce_empty_fields_stay_empty
        ; test_case
            "only-whitespace → empty"
            `Quick
            test_coerce_only_whitespace_becomes_empty
        ] )
    ; ( "idempotency"
      , [ test_case "coerce(coerce(p)) = coerce(p)" `Quick test_coerce_is_idempotent ] )
    ; ( "oversized fixture"
      , [ test_case
            "nick0cave will: byte-identical when no surrounding ws"
            `Quick
            test_coerce_oversized_utf8_unchanged_when_no_surrounding_whitespace
        ] )
    ]
;;
