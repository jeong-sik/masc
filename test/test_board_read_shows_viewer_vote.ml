(** A board read carries the reading agent's own vote.

    [masc_board_comment_vote] answers a same-direction revote with
    "Already voted (idempotent)", but that answer lives in the turn that made
    it. The next turn re-reads the board, and the listing showed only the
    tallies — no trace of the reader's own vote — so the reader decided to
    vote again. Live tool-call logs (2026-08-28) carry the cost: one keeper
    received "Already voted" 131 times in a day across 66 turns, on comments
    it had already voted for (task-839). The marker puts the durable fact
    where the next decision reads. *)

open Masc
module F = Board_tool_format

let comment ~id ~author ~content : Board.comment =
  { id = Board.Comment_id.of_string id |> Result.get_ok
  ; post_id =
      Board.Post_id.of_string "p-0123456789abcdef0123456789abcdef" |> Result.get_ok
  ; parent_id = None
  ; author = Board.Agent_id.of_string author |> Result.get_ok
  ; content
  ; created_at = 0.
  ; expires_at = 0.
  ; votes_up = 1
  ; votes_down = 0
  }
;;

let post ~id ~author : Board.post =
  { id = Board.Post_id.of_string id |> Result.get_ok
  ; author = Board.Agent_id.of_string author |> Result.get_ok
  ; title = "title"
  ; body = "body"
  ; post_kind = Board.Automation_post
  ; meta_json = None
  ; visibility = Board.Public
  ; created_at = 0.
  ; updated_at = 0.
  ; expires_at = 0.
  ; votes_up = 2
  ; votes_down = 0
  ; reply_count = 0
  ; pinned = false
  ; hearth = None
  ; thread_id = None
  ; origin = None
  }
;;

let contains ~needle haystack =
  let nl = String.length needle
  and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0
;;

let voted_id = "c-0ca32143f0b39bebaab0d8e7d7b723c1"
let unvoted_id = "c-5f89fad928ec2ef5b94968bf02460ec9"

let test_a_voted_comment_carries_the_readers_vote () =
  let lines =
    F.format_comment_tree
      ~viewer_vote_of:(fun cid ->
        if String.equal (Board.Comment_id.to_string cid) voted_id
        then Some Board.Up
        else None)
      [ comment ~id:voted_id ~author:"analyst" ~content:"voted already"
      ; comment ~id:unvoted_id ~author:"largo" ~content:"not yet voted"
      ]
  in
  let voted_line =
    List.find (fun line -> contains ~needle:voted_id line) lines
  in
  let unvoted_line =
    List.find (fun line -> contains ~needle:unvoted_id line) lines
  in
  Alcotest.(check bool)
    "the voted comment names the reader's vote"
    true
    (contains ~needle:"내 투표: 👍" voted_line);
  Alcotest.(check bool)
    "an unvoted comment carries no marker"
    false
    (contains ~needle:"내 투표" unvoted_line)
;;

let test_a_read_without_identity_renders_no_marker () =
  let lines =
    F.format_comment_tree
      [ comment ~id:voted_id ~author:"analyst" ~content:"tallies only" ]
  in
  Alcotest.(check bool)
    "the default lookup renders no marker"
    false
    (contains ~needle:"내 투표" (String.concat "\n" lines))
;;

let test_the_post_header_carries_the_readers_vote () =
  let rendered =
    F.format_post
      ~viewer_vote:Board.Down
      (post ~id:"p-0123456789abcdef0123456789abcdef" ~author:"analyst")
  in
  Alcotest.(check bool)
    "the post header names the reader's vote"
    true
    (contains ~needle:"내 투표: 👎" rendered);
  Alcotest.(check bool)
    "an identityless post render carries no marker"
    false
    (contains
       ~needle:"내 투표"
       (F.format_post (post ~id:"p-0123456789abcdef0123456789abcdef" ~author:"analyst")))
;;

let () =
  Alcotest.run
    "board_read_shows_viewer_vote"
    [ ( "viewer vote projection"
      , [ Alcotest.test_case
            "a voted comment carries the reader's vote"
            `Quick
            test_a_voted_comment_carries_the_readers_vote
        ; Alcotest.test_case
            "a read without identity renders no marker"
            `Quick
            test_a_read_without_identity_renders_no_marker
        ; Alcotest.test_case
            "the post header carries the reader's vote"
            `Quick
            test_the_post_header_carries_the_readers_vote
        ] )
    ]
;;
