(** Tests for [Keeper_personality_io.to_prompt_form] — samchon
    harness commit 7. The render layer is the only place in the
    harness where data is shortened (UTF-8 boundary safe truncation). *)

open Alcotest
open Masc_mcp

let make ?(will = "") ?(needs = "") ?(desires = "") ?(instructions = "") ()
  : Keeper_personality_io.raw_personality
  =
  { will; needs; desires; instructions }
;;

(* --------------------------------------------------------------------- *)
(* Trim + truncate semantics                                             *)
(* --------------------------------------------------------------------- *)

let test_under_cap_only_trims () =
  let p = make ~will:"  hello world  " () in
  let r = Keeper_personality_io.to_prompt_form ~max_bytes:1024 p in
  check string "trim only when under cap" "hello world" r.will
;;

let test_over_cap_truncates () =
  let p = make ~will:(String.make 500 'x') () in
  let r = Keeper_personality_io.to_prompt_form ~max_bytes:200 p in
  check int "truncated to cap" 200 (String.length r.will)
;;

let test_empty_stays_empty () =
  let r =
    Keeper_personality_io.to_prompt_form ~max_bytes:320 Keeper_personality_io.empty
  in
  check string "empty will" "" r.will;
  check string "empty needs" "" r.needs;
  check string "empty desires" "" r.desires;
  check string "empty instructions" "" r.instructions
;;

let test_only_whitespace_becomes_empty () =
  let p = make ~will:"   \n\t" () in
  let r = Keeper_personality_io.to_prompt_form ~max_bytes:320 p in
  check string "only-whitespace → empty (no garbage cap-applied)" "" r.will
;;

(* --------------------------------------------------------------------- *)
(* nick0cave 357-byte fixture: matches Layer 1 truncation behaviour      *)
(* --------------------------------------------------------------------- *)

let test_oversized_ascii_truncates_to_exact_cap () =
  let p = make ~will:(String.make 357 'a') () in
  let r =
    Keeper_personality_io.to_prompt_form
      ~max_bytes:Keeper_config.prompt_render_max_bytes
      p
  in
  check
    int
    "byte length = cap"
    Keeper_config.prompt_render_max_bytes
    (String.length r.will)
;;

let test_truncate_per_field_independent () =
  (* Each field is checked against the cap independently; needs being
     short doesn't affect will being truncated. *)
  let p = make ~will:(String.make 500 'a') ~needs:"short" ~desires:"" () in
  let r = Keeper_personality_io.to_prompt_form ~max_bytes:200 p in
  check int "will at cap" 200 (String.length r.will);
  check string "needs unchanged" "short" r.needs;
  check string "desires unchanged" "" r.desires
;;

(* --------------------------------------------------------------------- *)
(* Behaviour parity with normalize_self_model_text                       *)
(* --------------------------------------------------------------------- *)

let test_matches_normalize_self_model_text_for_each_field () =
  let cap = Keeper_config.prompt_render_max_bytes in
  let inputs =
    [ "  ascii_short  "; String.make 500 'x'; ""; "single line no whitespace" ]
  in
  List.iter
    (fun raw ->
       let via_helper = Keeper_config.normalize_self_model_text ~max_bytes:cap raw in
       let p = make ~will:raw () in
       let r = Keeper_personality_io.to_prompt_form ~max_bytes:cap p in
       check
         string
         (Printf.sprintf
            "to_prompt_form parity for input of length %d"
            (String.length raw))
         via_helper
         r.will)
    inputs
;;

let () =
  run
    "keeper_personality_io_render"
    [ ( "trim + truncate semantics"
      , [ test_case "under cap → trim only" `Quick test_under_cap_only_trims
        ; test_case "over cap → truncate" `Quick test_over_cap_truncates
        ; test_case "empty stays empty" `Quick test_empty_stays_empty
        ; test_case "only whitespace → empty" `Quick test_only_whitespace_becomes_empty
        ] )
    ; ( "nick0cave fixture"
      , [ test_case
            "oversized ascii truncates to exact cap"
            `Quick
            test_oversized_ascii_truncates_to_exact_cap
        ; test_case
            "per-field truncate independent"
            `Quick
            test_truncate_per_field_independent
        ] )
    ; ( "behaviour parity"
      , [ test_case
            "matches normalize_self_model_text per field"
            `Quick
            test_matches_normalize_self_model_text_for_each_field
        ] )
    ]
;;
