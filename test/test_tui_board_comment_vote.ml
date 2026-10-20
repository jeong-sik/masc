(* Board comment votes in the TUI: the score the thread decodes, the cursor
   that names the comment a vote goes to, the two-press arm over a typed
   target, the request a comment vote sends, and the reading a completed vote
   refreshes. *)

open Masc_tui_types
module Cursor = Masc_tui_board_comment_cursor
module Vote = Masc_tui_board_vote
module Layout = Masc_tui_board_read_layout

let comment_json ?(fields = []) id =
  `Assoc
    ([ "id", `String id
     ; "parent_id", `Null
     ; "author", `String "keeper"
     ; "content", `String ("content of " ^ id)
     ; "created_at", `Float 1_790_000_000.
     ]
     @ fields)

let decode json =
  match Masc_tui_loader.decode_board_comment json with
  | Ok comment -> comment
  | Error err -> Alcotest.failf "comment did not decode: %s" err

(* The two counts land in the record as the server sent them; the score is
   their difference. *)
let test_decoder_reads_both_counts () =
  let comment =
    decode
      (comment_json "c-1"
         ~fields:[ "votes_up", `Int 3; "votes_down", `Int 1 ])
  in
  Alcotest.(check (pair int int)) "up and down counts" (3, 1)
    (comment.bc_votes.bcv_up, comment.bc_votes.bcv_down);
  Alcotest.(check int) "net score" 2 (board_comment_score comment.bc_votes)

(* A post without [votes] is refused, so a comment without its counts is
   refused too, rather than drawn as an unvoted comment. *)
let test_decoder_refuses_missing_counts () =
  List.iter
    (fun (label, fields) ->
      match Masc_tui_loader.decode_board_comment (comment_json "c-1" ~fields) with
      | Ok _ -> Alcotest.failf "%s: decoded without its vote counts" label
      | Error _ -> ())
    [ "no votes_up", [ "votes_down", `Int 0 ]
    ; "no votes_down", [ "votes_up", `Int 0 ]
    ; "neither", []
    ]

let comment ?parent ?(up = 0) ?(down = 0) id =
  { bc_id = id
  ; bc_parent_id = parent
  ; bc_author = "keeper"
  ; bc_content = "content of " ^ id
  ; bc_created_at = "2026-10-20T00:00:00Z"
  ; bc_votes = { bcv_up = up; bcv_down = down }
  }

(* Arrival order a, b, a1 (a reply to a); the thread draws a, a1, b. *)
let thread = [ comment "a"; comment "b"; comment "a1" ~parent:"a" ]

let check_cursor label expected actual =
  Alcotest.(check (option string)) label expected actual

(* j/k walk the order the thread is drawn in, not the order comments arrived,
   and stop at either end. *)
let test_cursor_walks_the_drawn_order () =
  let ids = Cursor.ordered_ids thread in
  Alcotest.(check (list string)) "drawn order" [ "a"; "a1"; "b" ] ids;
  let move cursor delta = Cursor.move ids ~landing:None cursor ~delta in
  check_cursor "first j selects the first drawn comment" (Some "a")
    (move None 1);
  check_cursor "j from a reaches its reply" (Some "a1") (move (Some "a") 1);
  check_cursor "j stops at the last comment" (Some "b") (move (Some "b") 1);
  check_cursor "k stops at the first comment" (Some "a") (move (Some "a") (-1));
  check_cursor "an unselected cursor starts where the read landed"
    (Some "b")
    (Cursor.move ids ~landing:(Some "b") None ~delta:1)

(* A vote refresh rescores, and a refresh can add a comment ahead of the
   selected one. The cursor is the comment's id, so it stays on that comment
   and j/k step from where it is now drawn. *)
let test_cursor_keeps_its_comment_across_a_refresh () =
  let before = Cursor.ordered_ids thread in
  let selected = Cursor.move before ~landing:None (Some "a1") ~delta:1 in
  check_cursor "selected before the refresh" (Some "b") selected;
  let refreshed =
    [ comment "a" ~up:1
    ; comment "a0" ~parent:"a"
    ; comment "b" ~up:2 ~down:1
    ; comment "a1" ~parent:"a"
    ]
  in
  let after = Cursor.ordered_ids refreshed in
  check_cursor "the same comment stays selected" (Some "b")
    (Cursor.resolve after selected);
  check_cursor "k steps to the comment now drawn above it" (Some "a1")
    (Cursor.move after ~landing:None selected ~delta:(-1));
  (* A comment that left the thread selects nothing; the next focus or vote
     press settles on the landing comment, else the first. *)
  let without_b = Cursor.ordered_ids [ comment "a"; comment "a1" ~parent:"a" ] in
  check_cursor "a vanished comment is not selected" None
    (Cursor.resolve without_b selected);
  check_cursor "select settles on the landing comment" (Some "a1")
    (Cursor.select without_b ~landing:(Some "a1") selected);
  check_cursor "select falls to the first drawn comment" (Some "a")
    (Cursor.select without_b ~landing:None selected)

(* The column moves the least that shows the selected comment, and a comment
   taller than the column shows its first row. *)
let test_reveal_scroll () =
  let reveal ~scroll ~first_row ~row_count =
    Cursor.reveal_scroll ~scroll ~viewport_rows:10 ~first_row ~row_count
  in
  Alcotest.(check int) "on screen: no move" 5
    (reveal ~scroll:5 ~first_row:8 ~row_count:3);
  Alcotest.(check int) "above: its first row at the top" 2
    (reveal ~scroll:5 ~first_row:2 ~row_count:3);
  Alcotest.(check int) "below: its last row at the bottom" 13
    (reveal ~scroll:5 ~first_row:20 ~row_count:3);
  Alcotest.(check int) "taller than the column: its first row" 20
    (reveal ~scroll:5 ~first_row:20 ~row_count:25);
  Alcotest.(check int) "the end-of-reading sentinel does not overflow" 7
    (reveal ~scroll:max_int ~first_row:7 ~row_count:3)

(* The span the frame scrolls to, and the gutter mark, belong to the selected
   comment's rows only. *)
let test_rows_know_their_comment () =
  let rows =
    let cache = Layout.create () in
    let post =
      { bp_id = "p-1"; bp_author = "author"; bp_title = "t"; bp_body = "b"
      ; bp_votes = 0; bp_comment_count = 3; bp_created_at = "2026-10-20"
      ; bp_created_at_unix = None; bp_updated_at = None; bp_hearth = None
      ; bp_kind = None; bp_closed = None; bp_attachments = [] }
    in
    let source : Layout.source =
      { post; detail = Masc_tui_board_detail.Ready (post, thread, None)
      ; related_posts = []; keeper_names = []; columns = 80; styles = []
      ; table_frame = false }
    in
    let owned comment_id text = Layout.Comment_text { comment_id; text } in
    Layout.get cache ~source ~render:(fun () ->
      ( [ "body" ]
      , [ Layout.Thread_note "note"
        ; owned "a" "a heading"; owned "a" "a text"
        ; owned "a1" "a1 heading"
        ; owned "b" "b heading"; owned "b" "b text"; owned "b" "b more"
        ]
      , None ))
  in
  Alcotest.(check (option (pair int int))) "a" (Some (1, 2))
    (Layout.comment_span rows ~comment_id:"a");
  Alcotest.(check (option (pair int int))) "a1" (Some (3, 1))
    (Layout.comment_span rows ~comment_id:"a1");
  Alcotest.(check (option (pair int int))) "b" (Some (4, 3))
    (Layout.comment_span rows ~comment_id:"b");
  Alcotest.(check (option (pair int int))) "not drawn" None
    (Layout.comment_span rows ~comment_id:"gone");
  let marked = ref [] in
  let gutter comment_id =
    marked := comment_id :: !marked;
    if String.equal comment_id "a1" then "*" else ""
  in
  let lines = List.init 7 (Layout.comment_line rows ~gutter) in
  Alcotest.(check (list string)) "only the selected comment's rows are marked"
    [ "note"; "a heading"; "a text"; "*a1 heading"; "b heading"; "b text"; "b more" ]
    lines;
  Alcotest.(check int) "a note row asks for no gutter" 6 (List.length !marked)

let check_press label expected actual =
  let show = function
    | Vote.Arm (target, up) ->
        Printf.sprintf "arm %s %b" (Vote.describe target) up
    | Vote.Send (target, up) ->
        Printf.sprintf "send %s %b" (Vote.describe target) up
  in
  Alcotest.(check string) label (show expected) (show actual)

(* The second press sends only the very target the first one armed. Ids are
   spelled alike on purpose: the kind alone must keep a comment's arm from
   sending a post vote, and a post's arm from sending a comment vote. *)
let test_arm_is_typed_by_kind () =
  let post = Vote_post "x" in
  let on_comment = Vote_comment { post_id = "x"; comment_id = "x" } in
  check_press "a comment arm, then v on the post, re-arms for the post"
    (Vote.Arm (post, true))
    (Vote.press ~armed:(Some (on_comment, true)) ~target:post ~up:true);
  check_press "a post arm, then v on a comment, re-arms for the comment"
    (Vote.Arm (on_comment, true))
    (Vote.press ~armed:(Some (post, true)) ~target:on_comment ~up:true);
  check_press "the same comment and direction sends" (Vote.Send (on_comment, true))
    (Vote.press ~armed:(Some (on_comment, true)) ~target:on_comment ~up:true);
  check_press "the same comment the other way re-arms" (Vote.Arm (on_comment, false))
    (Vote.press ~armed:(Some (on_comment, true)) ~target:on_comment ~up:false);
  let other = Vote_comment { post_id = "x"; comment_id = "y" } in
  check_press "another comment re-arms" (Vote.Arm (other, true))
    (Vote.press ~armed:(Some (on_comment, true)) ~target:other ~up:true);
  check_press "nothing armed arms" (Vote.Arm (post, false))
    (Vote.press ~armed:None ~target:post ~up:false)

(* The body names the comment and the direction in the tool's words and
   carries the workspace guard. The voter is the route's to stamp. *)
let test_comment_vote_body () =
  let identity : Masc.Tui_decode.server_identity =
    { sid_version = "test"; sid_binary_commit = "0"; sid_binary_commit_age_s = None
    ; sid_base_path = Masc.Tui_decode.Canonical_path.of_path "/workspace/base"; sid_masc_root = Masc.Tui_decode.Canonical_path.of_path "/workspace/base/.masc"
    ; sid_executable_in_worktree = None; sid_state_ready = None; sid_uptime = None
    ; sid_sse_clients = None; sid_gc = None; sid_scheduler = None }
  in
  let comment_id = "c-0123456789abcdef0123456789abcdef" in
  let body up =
    Masc_tui_http.board_comment_vote_body ~expected_workspace:identity
      ~comment_id ~up
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "comment_id" comment_id
    (body true |> member "comment_id" |> to_string);
  Alcotest.(check string) "v sends up" "up"
    (body true |> member "direction" |> to_string);
  Alcotest.(check string) "V sends down" "down"
    (body false |> member "direction" |> to_string);
  Alcotest.(check string) "workspace base path"
    (Masc.Tui_decode.Canonical_path.to_string identity.sid_base_path)
    (body true |> member "expected_workspace" |> member "base_path" |> to_string);
  Alcotest.(check string) "workspace masc root"
    (Masc.Tui_decode.Canonical_path.to_string identity.sid_masc_root)
    (body true |> member "expected_workspace" |> member "masc_root" |> to_string);
  Alcotest.(check (list string)) "no other fields"
    [ "comment_id"; "direction"; "expected_workspace" ]
    (body true |> keys |> List.sort String.compare)

(* A finished vote refreshes the reading it landed on while that post is
   still open, so the new score shows on the comment; elsewhere only the
   list is refreshed. *)
let test_completion_refreshes_the_open_post () =
  let run ~mode target result =
    let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
    state.board_mode <- mode;
    state.board_vote_armed <- Some (target, true);
    let lists = ref 0 in
    let details = ref [] in
    Masc_tui_board_updates.vote_done state
      ~report:(fun _ _ -> ())
      ~refresh:(fun () -> incr lists)
      ~refresh_detail:(fun post_id -> details := post_id :: !details)
      target result;
    Alcotest.(check bool) "disarmed" true (Option.is_none state.board_vote_armed);
    (!lists, !details)
  in
  let on_comment = Vote_comment { post_id = "p-1"; comment_id = "c-1" } in
  Alcotest.(check (pair int (list string))) "comment vote on the open post"
    (1, [ "p-1" ])
    (run ~mode:(Board_read "p-1") on_comment (Ok "voted"));
  Alcotest.(check (pair int (list string))) "post vote while reading it"
    (1, [ "p-1" ])
    (run ~mode:(Board_read "p-1") (Vote_post "p-1") (Ok "voted"));
  Alcotest.(check (pair int (list string))) "another post is open"
    (1, [])
    (run ~mode:(Board_read "p-2") on_comment (Ok "voted"));
  Alcotest.(check (pair int (list string))) "from the list"
    (1, [])
    (run ~mode:Board_list (Vote_post "p-1") (Ok "voted"));
  Alcotest.(check (pair int (list string))) "a refused vote refreshes nothing"
    (0, [])
    (run ~mode:(Board_read "p-1") on_comment (Error "refused"))

let () =
  Alcotest.run "Board comment votes"
    [ ( "decode"
      , [ Alcotest.test_case "both vote counts" `Quick test_decoder_reads_both_counts
        ; Alcotest.test_case "missing counts are refused" `Quick
            test_decoder_refuses_missing_counts
        ] )
    ; ( "cursor"
      , [ Alcotest.test_case "walks the drawn order" `Quick
            test_cursor_walks_the_drawn_order
        ; Alcotest.test_case "keeps its comment across a refresh" `Quick
            test_cursor_keeps_its_comment_across_a_refresh
        ; Alcotest.test_case "reveal scroll" `Quick test_reveal_scroll
        ; Alcotest.test_case "rows know their comment" `Quick
            test_rows_know_their_comment
        ] )
    ; ( "vote"
      , [ Alcotest.test_case "the arm is typed by kind" `Quick
            test_arm_is_typed_by_kind
        ; Alcotest.test_case "comment vote body" `Quick test_comment_vote_body
        ; Alcotest.test_case "completion refreshes the open post" `Quick
            test_completion_refreshes_the_open_post
        ] )
    ]
