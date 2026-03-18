(** Test Board_dispatch - routing and JSONL backend integration *)

open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()

(** Temp directory for test isolation — set before any Board.global call *)
let test_base_path =
  let dir = Filename.concat (Filename.get_temp_dir_name ()) "masc-test-board-dispatch" in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

(** Wrap test body in Eio runtime with isolated JSONL backend *)
let with_eio f () =
  Eio_main.run @@ fun _env ->
  Unix.putenv "MASC_BASE_PATH" test_base_path;
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  f ()

(** {1 Backend Selection} *)

let test_default_backend () =
  Alcotest.(check string) "default is jsonl"
    "jsonl" (Board_dispatch.backend_name ())

let test_backend_returns_jsonl () =
  match Board_dispatch.backend () with
  | Board_dispatch.Jsonl _ -> ()
  | Board_dispatch.Postgres _ ->
      Alcotest.fail "Expected Jsonl backend"

(** {1 Post CRUD via Dispatch} *)

let test_create_and_get_post () =
  match Board_dispatch.create_post ~author:"test-agent" ~content:"dispatch test post" () with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      Alcotest.(check string) "author" "test-agent" (Board.Agent_id.to_string post.author);
      match Board_dispatch.get_post ~post_id:pid with
      | Error e -> Alcotest.fail (Board.show_board_error e)
      | Ok fetched ->
          Alcotest.(check string) "content matches"
            "dispatch test post" fetched.content

let test_structured_post_roundtrip () =
  let meta = `Assoc [("source", `String "keeper_autonomy")] in
  match Board_dispatch.create_post ~author:"sangsu"
          ~title:"Explicit title"
          ~content:"Visible line\n\n[STATE]\nGoal: keep context\n[/STATE]"
          ~post_kind:Board.Automation_post
          ~meta_json:meta
          () with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      Alcotest.(check string) "title stored" "Explicit title" post.title;
      Alcotest.(check string) "body stripped" "Visible line" post.body;
      let state_block =
        match post.meta_json with
        | Some (`Assoc fields) -> (
            match List.assoc_opt "state_block" fields with
            | Some (`String value) -> value
            | _ -> "")
        | _ -> ""
      in
      Alcotest.(check bool) "state block extracted" true (String.length state_block > 0);
      Board.reset_global_for_test ();
      Board_dispatch.reset_for_test ();
      Board_dispatch.init_jsonl ();
      match Board_dispatch.get_post ~post_id:pid with
      | Error e -> Alcotest.fail (Board.show_board_error e)
      | Ok fetched ->
          Alcotest.(check string) "roundtrip title" "Explicit title" fetched.title;
          Alcotest.(check string) "roundtrip content alias" "Visible line" fetched.content;
          Alcotest.(check string) "roundtrip body" "Visible line" fetched.body;
          Alcotest.(check string) "roundtrip kind" "automation"
            (Board.post_kind_to_string fetched.post_kind)

let test_list_posts () =
  ignore (Board_dispatch.create_post ~author:"lister" ~content:"list test 1" ());
  ignore (Board_dispatch.create_post ~author:"lister" ~content:"list test 2" ());
  let posts = Board_dispatch.list_posts ~limit:10 () in
  Alcotest.(check bool) "at least 2 posts" true (List.length posts >= 2)

let test_list_posts_with_sort () =
  let posts_hot = Board_dispatch.list_posts ~sort_by:Board_dispatch.Hot ~limit:5 () in
  let posts_recent = Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent ~limit:5 () in
  let posts_trending = Board_dispatch.list_posts ~sort_by:Board_dispatch.Trending ~limit:5 () in
  let posts_updated = Board_dispatch.list_posts ~sort_by:Board_dispatch.Updated ~limit:5 () in
  let posts_discussed = Board_dispatch.list_posts ~sort_by:Board_dispatch.Discussed ~limit:5 () in
  let counts = List.map List.length [posts_hot; posts_recent; posts_trending; posts_updated; posts_discussed] in
  let all_same = List.for_all (fun c -> c = List.hd counts) counts in
  Alcotest.(check bool) "all sort orders return same count" true all_same

(** {1 Comment Operations} *)

let test_add_and_get_comments () =
  match Board_dispatch.create_post ~author:"commenter" ~content:"post for comments" () with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      (match Board_dispatch.add_comment ~post_id:pid ~author:"responder" ~content:"nice post" () with
       | Error e -> Alcotest.fail (Board.show_board_error e)
       | Ok _ -> ());
      match Board_dispatch.get_comments ~post_id:pid with
      | Error e -> Alcotest.fail (Board.show_board_error e)
      | Ok comments ->
          Alcotest.(check bool) "has comment" true (List.length comments >= 1)

(** {1 Vote Operations} *)

let test_vote_post () =
  match Board_dispatch.create_post ~author:"voter-test" ~content:"vote me" () with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      match Board_dispatch.vote ~voter:"judge" ~post_id:pid ~direction:Board.Up with
      | Error e -> Alcotest.fail (Board.show_board_error e)
      | Ok score ->
          Alcotest.(check int) "score after upvote" 1 score

let test_vote_dedup () =
  match Board_dispatch.create_post ~author:"dedup-test" ~content:"dedup vote" () with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      ignore (Board_dispatch.vote ~voter:"same-voter" ~post_id:pid ~direction:Board.Up);
      match Board_dispatch.vote ~voter:"same-voter" ~post_id:pid ~direction:Board.Up with
      | Ok _ -> Alcotest.fail "Expected Already_voted error"
      | Error (Board.Already_voted _) -> ()
      | Error e -> Alcotest.fail (Board.show_board_error e)

let test_vote_flip () =
  match Board_dispatch.create_post ~author:"flip-test" ~content:"flip vote" () with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      ignore (Board_dispatch.vote ~voter:"flipper" ~post_id:pid ~direction:Board.Up);
      match Board_dispatch.vote ~voter:"flipper" ~post_id:pid ~direction:Board.Down with
      | Error e -> Alcotest.fail (Board.show_board_error e)
      | Ok score ->
          Alcotest.(check int) "score after flip" (-1) score

(** {1 Stats / Search / Hearth} *)

let test_stats () =
  let stats = Board_dispatch.stats () in
  match stats with
  | `Assoc fields ->
      Alcotest.(check bool) "has post_count"
        true (List.mem_assoc "post_count" fields)
  | _ -> Alcotest.fail "stats should be JSON object"

let test_search () =
  ignore (Board_dispatch.create_post ~author:"searcher" ~content:"unique_dispatch_search_term" ());
  let results = Board_dispatch.search ~query:"unique_dispatch_search_term" ~limit:10 in
  Alcotest.(check bool) "found search result" true (List.length results >= 1)

let test_hearths () =
  ignore (Board_dispatch.create_post ~author:"hearth-test" ~content:"fire topic"
    ~hearth:"test-hearth" ());
  let hearths = Board_dispatch.list_hearths () in
  Alcotest.(check bool) "has hearths" true (List.length hearths >= 1)

let test_set_thread_id () =
  match Board_dispatch.create_post ~author:"thread-test" ~content:"link me" () with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      match Board_dispatch.set_thread_id ~post_id:pid ~thread_id:"thread-abc" with
      | Error e -> Alcotest.fail (Board.show_board_error e)
      | Ok () ->
          match Board_dispatch.get_post ~post_id:pid with
          | Error e -> Alcotest.fail (Board.show_board_error e)
          | Ok p ->
              Alcotest.(check (option string)) "thread_id set"
                (Some "thread-abc") p.thread_id

let test_flush () =
  Board_dispatch.flush ()

(** {1 Validation} *)

let test_empty_content () =
  match Board_dispatch.create_post ~author:"validator" ~content:"" () with
  | Ok _ -> Alcotest.fail "Expected validation error for empty content"
  | Error (Board.Validation_error _) -> ()
  | Error e -> Alcotest.fail (Board.show_board_error e)

let test_invalid_author () =
  match Board_dispatch.create_post ~author:"" ~content:"valid content" () with
  | Ok _ -> Alcotest.fail "Expected validation error for empty author"
  | Error _ -> ()

(** {1 MASC_BOARD_BACKEND env var} *)

let test_jsonl_forced_default () =
  (try Unix.putenv "MASC_BOARD_BACKEND" "" with _ -> ());
  Alcotest.(check bool) "empty env not forced"
    false (Board_dispatch.jsonl_forced ())

let test_jsonl_forced_explicit () =
  Unix.putenv "MASC_BOARD_BACKEND" "jsonl";
  Alcotest.(check bool) "jsonl is forced"
    true (Board_dispatch.jsonl_forced ());
  Unix.putenv "MASC_BOARD_BACKEND" ""

let test_jsonl_forced_pg () =
  Unix.putenv "MASC_BOARD_BACKEND" "pg";
  Alcotest.(check bool) "pg is not forced"
    false (Board_dispatch.jsonl_forced ());
  Unix.putenv "MASC_BOARD_BACKEND" ""

let test_jsonl_forced_case_insensitive () =
  Unix.putenv "MASC_BOARD_BACKEND" "JSONL";
  Alcotest.(check bool) "JSONL uppercase is forced"
    true (Board_dispatch.jsonl_forced ());
  Unix.putenv "MASC_BOARD_BACKEND" ""

(** {1 Test Runner} *)

let () =
  Alcotest.run "Board_dispatch" [
    "backend", [
      Alcotest.test_case "default backend" `Quick (with_eio test_default_backend);
      Alcotest.test_case "returns jsonl" `Quick (with_eio test_backend_returns_jsonl);
    ];
    "posts", [
      Alcotest.test_case "create and get" `Quick (with_eio test_create_and_get_post);
      Alcotest.test_case "structured roundtrip" `Quick (with_eio test_structured_post_roundtrip);
      Alcotest.test_case "list" `Quick (with_eio test_list_posts);
      Alcotest.test_case "sort orders" `Quick (with_eio test_list_posts_with_sort);
    ];
    "comments", [
      Alcotest.test_case "add and get" `Quick (with_eio test_add_and_get_comments);
    ];
    "votes", [
      Alcotest.test_case "upvote" `Quick (with_eio test_vote_post);
      Alcotest.test_case "dedup" `Quick (with_eio test_vote_dedup);
      Alcotest.test_case "flip" `Quick (with_eio test_vote_flip);
    ];
    "misc", [
      Alcotest.test_case "stats" `Quick (with_eio test_stats);
      Alcotest.test_case "search" `Quick (with_eio test_search);
      Alcotest.test_case "hearths" `Quick (with_eio test_hearths);
      Alcotest.test_case "set_thread_id" `Quick (with_eio test_set_thread_id);
      Alcotest.test_case "flush" `Quick (with_eio test_flush);
    ];
    "validation", [
      Alcotest.test_case "empty content" `Quick (with_eio test_empty_content);
      Alcotest.test_case "invalid author" `Quick (with_eio test_invalid_author);
    ];
    "env_control", [
      Alcotest.test_case "default not forced" `Quick (with_eio test_jsonl_forced_default);
      Alcotest.test_case "jsonl forced" `Quick (with_eio test_jsonl_forced_explicit);
      Alcotest.test_case "pg not forced" `Quick (with_eio test_jsonl_forced_pg);
      Alcotest.test_case "case insensitive" `Quick (with_eio test_jsonl_forced_case_insensitive);
    ];
  ]
