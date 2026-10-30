(* Whether a playback repeats the last one is decided on the text itself.

   The dedup used to keep only [Hashtbl.hash message] and compare that. The
   hash is 30 bits, so different lines share it: "voice line 20165" and
   "voice line 66786" hash to 526701624 (found by enumerating
   [Printf.sprintf "voice line %d" i] until two hashes met). With the hash
   as the whole comparison, the second line was reported as a [`Dedup_hit]
   and never spoken. Issue #26238. *)

module Core = Voice_bridge_core

let agent_id = "keeper-dedup-test"
let first_line = "voice line 20165"
let colliding_line = "voice line 66786"

let test_the_two_lines_do_share_a_hash () =
  (* The precondition the next case rests on. If the hash function ever
     changes, this fails first and says why the next case stopped proving
     anything. *)
  Alcotest.(check int)
    "same Hashtbl.hash"
    (Hashtbl.hash first_line)
    (Hashtbl.hash colliding_line);
  Alcotest.(check bool)
    "different text"
    false
    (String.equal first_line colliding_line)

let test_a_line_sharing_the_hash_is_not_a_repeat () =
  Core.record_playback ~agent_id ~message:first_line;
  Alcotest.(check bool)
    "colliding line is spoken"
    false
    (Core.is_dedup_hit ~agent_id ~message:colliding_line)

let test_the_same_line_is_a_repeat () =
  Core.record_playback ~agent_id ~message:first_line;
  Alcotest.(check bool)
    "same line inside the window is skipped"
    true
    (Core.is_dedup_hit ~agent_id ~message:first_line)

let test_the_same_line_from_another_agent_is_not_a_repeat () =
  Core.record_playback ~agent_id ~message:first_line;
  Alcotest.(check bool)
    "another agent's same line is spoken"
    false
    (Core.is_dedup_hit ~agent_id:"keeper-dedup-other" ~message:first_line)

let () =
  Alcotest.run
    "voice playback dedup"
    [ ( "a repeat is the same text, not the same hash"
      , [ Alcotest.test_case "the two lines share a hash" `Quick
            test_the_two_lines_do_share_a_hash
        ; Alcotest.test_case "a line sharing the hash is not a repeat" `Quick
            test_a_line_sharing_the_hash_is_not_a_repeat
        ; Alcotest.test_case "the same line is a repeat" `Quick
            test_the_same_line_is_a_repeat
        ; Alcotest.test_case "another agent's same line is not a repeat" `Quick
            test_the_same_line_from_another_agent_is_not_a_repeat
        ] )
    ]
