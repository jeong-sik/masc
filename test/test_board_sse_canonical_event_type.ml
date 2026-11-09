open Masc

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
  check_event_type "reaction_changed" "reaction.changed"
    (Board_dispatch.Reaction_changed
       {
         target_type = Board.Reaction_post;
         target_id = "post-1";
         user_id = "reader";
         emoji = "👍";
         reacted = true;
       })

let test_private_mutations_publish_no_identity_or_content () =
  let seen = ref None in
  Board_dispatch.set_board_sse_hook (fun event -> seen := Some event);
  Fun.protect ~finally:(fun () -> Board_dispatch.set_board_sse_hook (fun _ -> ())) @@ fun () ->
  let events =
    [ Board_dispatch.Post_created { post_id="secret-post"; author="secret-author";
        title="secret-title"; content="secret-body"; post_kind=Board.Human_post; hearth=None }
    ; Board_dispatch.Comment_added { post_id="secret-post"; comment_id="secret-comment"; author="secret-author" }
    ; Board_dispatch.Post_voted { post_id="secret-post"; voter="secret-voter"; direction=Board.Up }
    ; Board_dispatch.Comment_voted { comment_id="secret-comment"; voter="secret-voter"; direction=Board.Up }
    ; Board_dispatch.Reaction_changed { target_type=Board.Reaction_comment; target_id="secret-comment";
        user_id="secret-author"; emoji="👍"; reacted=true }
    ; Board_dispatch.Post_changed { post_id="secret-post"; change=Board_dispatch.Post_deleted }
    ] in
  List.iter (fun event ->
    List.iter (fun visibility ->
      seen := None;
      Board_dispatch.emit_board_sse_event ~visibility event;
      match !seen with
      | Some Board_dispatch.Board_changed ->
        Alcotest.(check string) "only a generic invalidation reaches the shared bus"
          {|{"type":"board_changed","event_type":"board.changed"}|}
          (Yojson.Safe.to_string (Boot.board_sse_event_params Board_dispatch.Board_changed))
      | Some _ | None -> Alcotest.fail "private event reached the hook or invalidation was lost")
      [Some Board.Direct; Some Board.Internal; Some Board.Unlisted; None];
    Board_dispatch.emit_board_sse_event ~visibility:(Some Board.Public) event;
    Alcotest.(check bool) "public events retain their payload" true (!seen = Some event)) events

let () =
  Alcotest.run "board_sse_canonical_event_type"
    [
      ( "canonical aliases",
        [
          Alcotest.test_case "post.created" `Quick test_post_created_alias;
          Alcotest.test_case "comment.created" `Quick test_comment_created_alias;
          Alcotest.test_case "vote.changed" `Quick test_vote_changed_aliases;
          Alcotest.test_case "reaction.changed" `Quick test_reaction_changed_alias;
          Alcotest.test_case "private mutations carry no identity" `Quick
            test_private_mutations_publish_no_identity_or_content;
        ] );
    ]
