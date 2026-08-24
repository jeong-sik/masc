(** A rendered comment carries the id its own tools ask for.

    [masc_board_comment_vote] takes a [comment_id], and its rejection points the
    caller here: "the id masc_board_post_get and masc_board_comment return".
    The listing did not carry it. Live tool-call logs (2026-08) show what that
    cost: [masc_board_comment_vote] failed 160 of 239 calls, and the ids sent
    were [c-placeholder] (31), [c-b1] (26), [c-???] (20), and in 28 calls the
    comment's own text — [FUSION_STARTED run_id=], [BUILDER_A_DONE] — in place
    of an id. A caller that cannot read an id guesses one. *)

open Masc
module F = Board_tool_format

let comment ~id ~author ~content ~parent_id : Board.comment =
  { id = Board.Comment_id.of_string id |> Result.get_ok
  ; post_id =
      Board.Post_id.of_string "p-0123456789abcdef0123456789abcdef" |> Result.get_ok
  ; parent_id =
      Option.map (fun p -> Board.Comment_id.of_string p |> Result.get_ok) parent_id
  ; author = Board.Agent_id.of_string author |> Result.get_ok
  ; content
  ; created_at = 0.
  ; expires_at = 0.
  ; votes_up = 0
  ; votes_down = 0
  }
;;

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0
;;

let root_id = "c-0ca32143f0b39bebaab0d8e7d7b723c1"
let reply_id = "c-5f89fad928ec2ef5b94968bf02460ec9"

let rendered comments = F.format_comment_tree comments |> String.concat "\n"

let test_a_rendered_comment_names_its_id () =
  let out =
    rendered
      [ comment ~id:root_id ~author:"analyst" ~content:"FUSION_STARTED" ~parent_id:None ]
  in
  Alcotest.(check bool) "the id is in the line" true (contains ~needle:root_id out);
  Alcotest.(check bool) "the author still reads first" true (contains ~needle:"analyst:" out);
  Alcotest.(check bool) "the content survives" true (contains ~needle:"FUSION_STARTED" out)
;;

(* A reply is the other caller of the id: threading takes the parent's. Both
   ids have to be readable from one listing or a threaded reply is a guess. *)
let test_every_comment_in_a_thread_names_its_id () =
  let out =
    rendered
      [ comment ~id:root_id ~author:"analyst" ~content:"root" ~parent_id:None
      ; comment ~id:reply_id ~author:"largo" ~content:"reply" ~parent_id:(Some root_id)
      ]
  in
  Alcotest.(check bool) "the root id is readable" true (contains ~needle:root_id out);
  Alcotest.(check bool) "the reply id is readable" true (contains ~needle:reply_id out)
;;

let () =
  Alcotest.run
    "board_comment_id_is_visible"
    [ ( "rendered_comment"
      , [ Alcotest.test_case "names its id" `Quick test_a_rendered_comment_names_its_id
        ; Alcotest.test_case
            "every comment in a thread names its id"
            `Quick
            test_every_comment_in_a_thread_names_its_id
        ] )
    ]
;;
