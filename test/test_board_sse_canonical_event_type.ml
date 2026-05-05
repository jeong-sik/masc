open Masc_mcp

module Boot = Server_bootstrap_loops.For_testing
module U = Yojson.Safe.Util

let string_field name json = json |> U.member name |> U.to_string

let check_event_type label expected event =
  let json = Boot.board_sse_event_params event in
  Alcotest.(check string) (label ^ " legacy type is preserved") label
    (string_field "type" json);
  Alcotest.(check string) (label ^ " canonical event_type") expected
    (string_field "event_type" json)

let test_post_created_alias () =
  check_event_type "post_created" "post.created"
    (Board_dispatch.Post_created
       {
         post_id = "post-1";
         author = "writer";
         title = "Title";
         content = "Body";
         post_kind = Board.Human_post;
         hearth = None;
       })

let test_comment_created_alias () =
  check_event_type "comment_added" "comment.created"
    (Board_dispatch.Comment_added
       { post_id = "post-1"; comment_id = "comment-1"; author = "reader" })

let test_vote_changed_aliases () =
  let post_vote =
    Boot.board_sse_event_params
      (Board_dispatch.Post_voted
         { post_id = "post-1"; voter = "reader"; direction = Board.Up })
  in
  Alcotest.(check string) "post vote canonical event_type" "vote.changed"
    (string_field "event_type" post_vote);
  Alcotest.(check string) "post vote target_type" "post"
    (string_field "target_type" post_vote);
  let comment_vote =
    Boot.board_sse_event_params
      (Board_dispatch.Comment_voted
         { comment_id = "comment-1"; voter = "reader"; direction = Board.Down })
  in
  Alcotest.(check string) "comment vote canonical event_type" "vote.changed"
    (string_field "event_type" comment_vote);
  Alcotest.(check string) "comment vote target_type" "comment"
    (string_field "target_type" comment_vote)

let test_reaction_changed_alias () =
  let json =
    Boot.board_sse_event_params
      (Board_dispatch.Reaction_changed
         {
           target_type = Board.Reaction_post;
           target_id = "post-1";
           user_id = "reader";
           emoji = "👍";
           reacted = true;
         })
  in
  Alcotest.(check string) "reaction_changed legacy type is preserved"
    "reaction_changed" (string_field "type" json);
  Alcotest.(check string) "reaction.changed canonical event_type"
    "reaction.changed" (string_field "event_type" json);
  Alcotest.(check string) "reaction target_type" "post"
    (string_field "target_type" json);
  Alcotest.(check string) "reaction target_id" "post-1"
    (string_field "target_id" json);
  Alcotest.(check string) "reaction user_id" "reader"
    (string_field "user_id" json);
  Alcotest.(check string) "reaction emoji" "👍" (string_field "emoji" json);
  Alcotest.(check bool) "reaction reacted" true
    (json |> U.member "reacted" |> U.to_bool)

let () =
  Alcotest.run "board_sse_canonical_event_type"
    [
      ( "canonical aliases",
        [
          Alcotest.test_case "post.created" `Quick test_post_created_alias;
          Alcotest.test_case "comment.created" `Quick test_comment_created_alias;
          Alcotest.test_case "vote.changed" `Quick test_vote_changed_aliases;
          Alcotest.test_case "reaction.changed" `Quick test_reaction_changed_alias;
        ] );
    ]
