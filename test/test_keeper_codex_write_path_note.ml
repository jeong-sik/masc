(** What the developer instructions say about the built-in write path.

    Codex keeps its own file tools whatever posture MASC declares, and under
    [Native_read] it runs them in a read-only sandbox. The model therefore
    holds a working [Write] and a refused [apply_patch] at once. A keeper hit
    the refusal, read it as the workspace being read-only, and stopped for six
    hours with an open write path in its hand.

    The note names which of the two the session refused. These tests hold it
    to the postures that need it and to the tool names that actually reach a
    model, so a renamed tool cannot leave the note pointing at nothing. *)

open Alcotest

module Codex = Masc.Keeper_codex_runtime.For_testing
module Posture = Runtime_native_tools

let note posture = String.concat "\n" (Codex.native_posture_note posture)

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec walk at = at + n <= h && (String.equal (String.sub haystack at n) needle || walk (at + 1)) in
  n = 0 || walk 0

let test_only_the_read_posture_says_anything () =
  check bool "read carries a note" true
    (List.length (Codex.native_posture_note Posture.Native_read) > 0);
  check (list string) "full carries none" []
    (Codex.native_posture_note Posture.Native_full);
  (* Codex refuses this posture as config before a turn is composed, so the
     note has nothing to say about it either. *)
  check (list string) "none carries none" []
    (Codex.native_posture_note Posture.Native_none)

let test_the_note_names_the_refused_call () =
  check bool "apply_patch is named" true
    (contains ~needle:"apply_patch" (note Posture.Native_read))

(* The note is only useful if the tools it points at are the tools a model is
   actually offered. A rename that missed this string would leave the note
   advertising something that is not on the surface. *)
let model_facing_names () =
  Masc.Keeper_tool_descriptor.all_descriptors ()
  |> List.concat_map Masc.Keeper_tool_descriptor.keeper_model_names

let test_the_tools_it_points_at_are_on_the_surface () =
  let names = model_facing_names () in
  let text = note Posture.Native_read in
  List.iter
    (fun tool ->
      check bool
        (Printf.sprintf "%s is projected to models" tool)
        true
        (List.exists (String.equal tool) names);
      check bool
        (Printf.sprintf "the note names %s" tool)
        true
        (contains ~needle:tool text))
    [ "Write"; "Edit" ]

(* The sentence an operator will read back when this goes wrong again. *)
let test_the_note_denies_the_conclusion_that_was_drawn () =
  check bool "it says the workspace is not read-only" true
    (contains ~needle:"does not mean the workspace is read-only"
       (note Posture.Native_read))

let () =
  run "keeper codex write path note"
    [ ( "posture"
      , [ test_case "only the read posture says anything" `Quick
            test_only_the_read_posture_says_anything
        ; test_case "the note names the refused call" `Quick
            test_the_note_names_the_refused_call
        ; test_case "the tools it points at are on the surface" `Quick
            test_the_tools_it_points_at_are_on_the_surface
        ; test_case "the note denies the conclusion that was drawn" `Quick
            test_the_note_denies_the_conclusion_that_was_drawn
        ] )
    ]
