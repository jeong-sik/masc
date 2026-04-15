(** Test Board_dispatch - routing and JSONL backend integration *)

open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

(** Temp directory for test isolation — set before any Board.global call *)
let fresh_test_base_path () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-board-dispatch-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

(** Wrap test body in Eio runtime with isolated JSONL backend *)
let with_eio f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (fresh_test_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  f ()

let seed_legacy_keeper_post () =
  let now = Time_compat.now () in
  let post_id = Printf.sprintf "legacy-keeper-%06x" (Random.bits ()) in
  let path = Board.persist_path () in
  let dir = Filename.dirname path in
  Fs_compat.mkdir_p dir;
  let json =
    `Assoc
      [
        ("id", `String post_id);
        ("author", `String "dm-keeper");
        ("title", `String "Legacy keeper");
        ("body", `String "keeper");
        ("content", `String "keeper");
        ("visibility", `String "internal");
        ("created_at", `Float now);
        ("updated_at", `Float now);
        ("expires_at", `Float 0.0);
        ("votes_up", `Int 0);
        ("votes_down", `Int 0);
        ("reply_count", `Int 0);
        ("meta", `Assoc [ ("source", `String "keeper_board_post") ]);
      ]
  in
  Fs_compat.append_file path (Yojson.Safe.to_string json ^ "\n");
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  post_id

(** {1 Backend Selection} *)

let test_default_backend () =
  Alcotest.(check string) "default is jsonl"
    "jsonl" (Board_dispatch.backend_name ())

let test_backend_returns_jsonl () =
  match Board_dispatch.backend () with
  | Board_dispatch.Jsonl _ -> ()

(** {1 Post CRUD via Dispatch} *)

let test_create_and_get_post () =
  match
    Board_dispatch.create_post ~author:"test-agent" ~content:"dispatch test post"
      ~post_kind:Board.Human_post ()
  with
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
  ignore (Board_dispatch.create_post ~author:"lister" ~content:"list test 1"
            ~post_kind:Board.Human_post ());
  ignore (Board_dispatch.create_post ~author:"lister" ~content:"list test 2"
            ~post_kind:Board.Human_post ());
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

let test_recent_sort_bypasses_hot_cutoff () =
  let create_post_exn ~author ~content =
    match
      Board_dispatch.create_post ~author ~content
        ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let vote_up_exn ~post_id ~voter =
    match Board_dispatch.vote ~voter ~post_id ~direction:Board.Up with
    | Ok _ -> ()
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  for i = 1 to 101 do
    let hot_post =
      create_post_exn ~author:(Printf.sprintf "hot-author-%03d" i)
        ~content:(Printf.sprintf "hot post %03d" i)
    in
    vote_up_exn ~post_id:(Board.Post_id.to_string hot_post.id)
      ~voter:(Printf.sprintf "hot-voter-%03d" i)
  done;
  let cold_post =
    create_post_exn ~author:"recent-cold-author"
      ~content:"latest cold post should still win recent sort"
  in
  let cold_post_id = Board.Post_id.to_string cold_post.id in
  let recent_posts =
    Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent ~limit:1 ()
  in
  let hot_posts =
    Board_dispatch.list_posts ~sort_by:Board_dispatch.Hot ~limit:1 ()
  in
  let recent_post_id =
    match recent_posts with
    | post :: _ -> Board.Post_id.to_string post.id
    | [] -> Alcotest.fail "expected recent posts"
  in
  let hot_post_id =
    match hot_posts with
    | post :: _ -> Board.Post_id.to_string post.id
    | [] -> Alcotest.fail "expected hot posts"
  in
  Alcotest.(check string) "recent returns latest post beyond hot top 100"
    cold_post_id recent_post_id;
  Alcotest.(check bool) "hot ranking still excludes cold post" false
    (String.equal hot_post_id cold_post_id)

let test_list_posts_with_filters () =
  let keeper_meta = `Assoc [ ("source", `String "keeper_board_post") ] in
  let scoped_authors = [ "filter-human"; "filter-harness-bot"; "filter-keeper" ] in
  let is_scoped_author (p : Board.post) =
    List.mem (Board.Agent_id.to_string p.author) scoped_authors
  in
  ignore (Board_dispatch.create_post ~author:"filter-human" ~content:"human-filter-test"
            ~post_kind:Board.Human_post ());
  ignore (Board_dispatch.create_post ~author:"filter-harness-bot"
            ~content:"automation" ~visibility:Board.Internal ~ttl_hours:1
            ~hearth:"dashboard-harness" ~post_kind:Board.Automation_post ());
  ignore (Board_dispatch.create_post ~author:"filter-keeper" ~content:"keeper"
            ~post_kind:Board.Automation_post ~meta_json:keeper_meta ());
  let all_posts =
    Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent ~limit:50 ()
    |> List.filter is_scoped_author
  in
  let no_system =
    Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent ~exclude_system:true
      ~limit:50 ()
    |> List.filter is_scoped_author
  in
  let no_automation =
    Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent
      ~exclude_automation:true ~limit:50 ()
    |> List.filter is_scoped_author
  in
  let human_only =
    Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent ~exclude_system:true
      ~exclude_automation:true ~limit:50 ()
    |> List.filter is_scoped_author
  in
  Alcotest.(check int) "all posts" 3 (List.length all_posts);
  Alcotest.(check int) "exclude system" 3 (List.length no_system);
  Alcotest.(check int) "exclude automation" 1 (List.length no_automation);
  Alcotest.(check int) "exclude both" 1 (List.length human_only);
  Alcotest.(check string) "human remains" "filter-human"
    (human_only |> List.hd |> fun (p : Board.post) -> Board.Agent_id.to_string p.author)

let test_list_posts_matches_comment_author () =
  let matching_post =
    match
      Board_dispatch.create_post ~author:"post-owner-a"
        ~content:"comment author should surface this post"
        ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let other_post =
    match
      Board_dispatch.create_post ~author:"post-owner-b"
        ~content:"different comment author"
        ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let matching_post_id = Board.Post_id.to_string matching_post.id in
  let other_post_id = Board.Post_id.to_string other_post.id in
  (match
     Board_dispatch.add_comment ~post_id:matching_post_id
       ~author:"comment-match-agent" ~content:"I touched this thread" ()
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  (match
     Board_dispatch.add_comment ~post_id:other_post_id
       ~author:"comment-other-agent" ~content:"Different author" ()
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  let filtered =
    Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent
      ~author_filter:"MATCH-AGENT" ~limit:20 ()
  in
  let ids =
    List.map (fun (post : Board.post) -> Board.Post_id.to_string post.id) filtered
  in
  Alcotest.(check bool) "matching comment author includes post" true
    (List.mem matching_post_id ids);
  Alcotest.(check bool) "non matching comment author excluded" false
    (List.mem other_post_id ids)

let test_author_filter_treats_wildcards_literally () =
  ignore
    (Board_dispatch.create_post ~author:"wildcard-alpha"
       ~content:"literal wildcard filter" ~post_kind:Board.Human_post ());
  let filtered =
    Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent
      ~author_filter:"%" ~limit:20 ()
  in
  Alcotest.(check int) "percent does not match all authors" 0
    (List.length filtered)

let test_reclassify_posts_dry_run_and_apply () =
  let post_id = seed_legacy_keeper_post () in
  let dry_run = Board_dispatch.reclassify_posts ~dry_run:true () in
  Alcotest.(check int) "dry run changed" 1 dry_run.changed;
  (match Board_dispatch.get_post ~post_id with
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok fetched ->
       Alcotest.(check string) "legacy row resolves as automation" "automation"
         (Board.post_kind_to_string fetched.post_kind));
  let applied = Board_dispatch.reclassify_posts ~dry_run:false () in
  Alcotest.(check int) "apply changed" 1 applied.changed;
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  match Board_dispatch.get_post ~post_id with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok fetched ->
      Alcotest.(check string) "persisted as automation" "automation"
        (Board.post_kind_to_string fetched.post_kind)

(** {1 Comment Operations} *)

let test_add_and_get_comments () =
  match
    Board_dispatch.create_post ~author:"commenter" ~content:"post for comments"
      ~post_kind:Board.Human_post ()
  with
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
  match
    Board_dispatch.create_post ~author:"voter-test" ~content:"vote me"
      ~post_kind:Board.Human_post ()
  with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      match Board_dispatch.vote ~voter:"judge" ~post_id:pid ~direction:Board.Up with
      | Error e -> Alcotest.fail (Board.show_board_error e)
      | Ok score ->
          Alcotest.(check int) "score after upvote" 1 score

let test_vote_dedup () =
  match
    Board_dispatch.create_post ~author:"dedup-test" ~content:"dedup vote"
      ~post_kind:Board.Human_post ()
  with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      ignore (Board_dispatch.vote ~voter:"same-voter" ~post_id:pid ~direction:Board.Up);
      match Board_dispatch.vote ~voter:"same-voter" ~post_id:pid ~direction:Board.Up with
      | Ok _ -> Alcotest.fail "Expected Already_voted error"
      | Error (Board.Already_voted _) -> ()
      | Error e -> Alcotest.fail (Board.show_board_error e)

let test_vote_flip () =
  match
    Board_dispatch.create_post ~author:"flip-test" ~content:"flip vote"
      ~post_kind:Board.Human_post ()
  with
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
  ignore (Board_dispatch.create_post ~author:"searcher"
            ~content:"unique_dispatch_search_term" ~post_kind:Board.Human_post ());
  let results = Board_dispatch.search ~query:"unique_dispatch_search_term" ~limit:10 in
  Alcotest.(check bool) "found search result" true (List.length results >= 1)

let test_hearths () =
  ignore (Board_dispatch.create_post ~author:"hearth-test" ~content:"fire topic"
    ~hearth:"test-hearth" ~post_kind:Board.Human_post ());
  let hearths = Board_dispatch.list_hearths () in
  Alcotest.(check bool) "has hearths" true (List.length hearths >= 1)

let test_set_thread_id () =
  match
    Board_dispatch.create_post ~author:"thread-test" ~content:"link me"
      ~post_kind:Board.Human_post ()
  with
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
  match
    Board_dispatch.create_post ~author:"validator" ~content:""
      ~post_kind:Board.Human_post ()
  with
  | Ok _ -> Alcotest.fail "Expected validation error for empty content"
  | Error (Board.Validation_error _) -> ()
  | Error e -> Alcotest.fail (Board.show_board_error e)

let test_invalid_author () =
  match
    Board_dispatch.create_post ~author:"" ~content:"valid content"
      ~post_kind:Board.Human_post ()
  with
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
      Alcotest.test_case "recent bypasses hot cutoff" `Quick
        (with_eio test_recent_sort_bypasses_hot_cutoff);
      Alcotest.test_case "filters" `Quick (with_eio test_list_posts_with_filters);
      Alcotest.test_case "comment author filter" `Quick
        (with_eio test_list_posts_matches_comment_author);
      Alcotest.test_case "literal wildcard filter" `Quick
        (with_eio test_author_filter_treats_wildcards_literally);
      Alcotest.test_case "reclassify dry-run and apply" `Quick
        (with_eio test_reclassify_posts_dry_run_and_apply);
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
