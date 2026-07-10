(** Tests for [Keeper_personality_io.to_prompt_form] — samchon
    harness commit 7. The render layer is the only place in the
    harness where data is shortened (UTF-8 boundary safe truncation).
    RFC-0282 reduced [raw_personality] to the single [instructions]
    field. *)

open Alcotest
open Masc

let make ?(instructions = "") () : Keeper_personality_io.raw_personality =
  { instructions }

(* --------------------------------------------------------------------- *)
(* Trim + truncate semantics                                             *)
(* --------------------------------------------------------------------- *)

let test_under_cap_only_trims () =
  let p = make ~instructions:"  hello world  " () in
  let r =
    Keeper_personality_io.to_prompt_form ~max_bytes:1024 p
  in
  check string "trim only when under cap" "hello world" r.instructions

let test_over_cap_truncates () =
  let p = make ~instructions:(String.make 500 'x') () in
  let r = Keeper_personality_io.to_prompt_form ~max_bytes:200 p in
  check int "truncated to cap" 200 (String.length r.instructions)

let test_empty_stays_empty () =
  let r =
    Keeper_personality_io.to_prompt_form ~max_bytes:320
      Keeper_personality_io.empty
  in
  check string "empty instructions" "" r.instructions

let test_only_whitespace_becomes_empty () =
  let p = make ~instructions:"   \n\t" () in
  let r = Keeper_personality_io.to_prompt_form ~max_bytes:320 p in
  check string "only-whitespace → empty (no garbage cap-applied)" ""
    r.instructions

(* --------------------------------------------------------------------- *)
(* nick0cave 357-byte fixture: matches Layer 1 truncation behaviour      *)
(* --------------------------------------------------------------------- *)

let test_oversized_ascii_truncates_to_exact_cap () =
  let p =
    make
      ~instructions:(String.make (Keeper_config.prompt_render_max_bytes + 100) 'a')
      ()
  in
  let r =
    Keeper_personality_io.to_prompt_form
      ~max_bytes:Keeper_config.prompt_render_max_bytes p
  in
  check int "byte length = cap" Keeper_config.prompt_render_max_bytes
    (String.length r.instructions)

(* --------------------------------------------------------------------- *)
(* Behaviour parity with normalize_prompt_text                           *)
(* --------------------------------------------------------------------- *)

let test_matches_normalize_prompt_text () =
  let cap = Keeper_config.prompt_render_max_bytes in
  let inputs =
    [
      "  ascii_short  ";
      String.make 500 'x';
      "";
      "single line no whitespace";
    ]
  in
  List.iter
    (fun raw ->
      let via_helper =
        Keeper_config.normalize_prompt_text ~max_bytes:cap raw
      in
      let p = make ~instructions:raw () in
      let r = Keeper_personality_io.to_prompt_form ~max_bytes:cap p in
      check string
        (Printf.sprintf "to_prompt_form parity for input of length %d"
           (String.length raw))
        via_helper r.instructions)
    inputs

let () =
  run "keeper_personality_io_render"
    [
      ( "trim + truncate semantics",
        [
          test_case "under cap → trim only" `Quick test_under_cap_only_trims;
          test_case "over cap → truncate" `Quick test_over_cap_truncates;
          test_case "empty stays empty" `Quick test_empty_stays_empty;
          test_case "only whitespace → empty" `Quick
            test_only_whitespace_becomes_empty;
        ] );
      ( "nick0cave fixture",
        [
          test_case "oversized ascii truncates to exact cap" `Quick
            test_oversized_ascii_truncates_to_exact_cap;
        ] );
      ( "behaviour parity",
        [
          test_case "matches normalize_prompt_text" `Quick
            test_matches_normalize_prompt_text;
        ] );
    ]
