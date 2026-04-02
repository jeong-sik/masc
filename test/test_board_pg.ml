(** Test Board_pg - PostgreSQL backend for MASC Board

    All tests require MASC_POSTGRES_URL environment variable.
    When absent, tests are skipped (not failed). *)

open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()

(** Check if PG is available (empty string treated as absent) *)
let pg_url () = Env_config_core.postgres_url_opt ()

(** Delete all pg-test-* rows from board tables (votes -> comments -> posts).
    Uses a single connection for all three DELETEs.
    Best-effort: errors are silently ignored (table may not exist yet). *)
let cleanup_test_data pool =
  let open Caqti_request.Infix in
  let del_votes = (Caqti_type.unit ->. Caqti_type.unit)
    "DELETE FROM masc_board_votes WHERE voter LIKE 'pg-test-%' OR voter LIKE 'pg-voter-%' OR voter LIKE 'pg-cv-%'" in
  let del_comments = (Caqti_type.unit ->. Caqti_type.unit)
    "DELETE FROM masc_board_comments WHERE author LIKE 'pg-test-%'" in
  let del_posts = (Caqti_type.unit ->. Caqti_type.unit)
    "DELETE FROM masc_board_posts WHERE author LIKE 'pg-test-%'" in
  match Caqti_eio.Pool.use (fun (module C : Caqti_eio.CONNECTION) ->
    Result.bind (C.exec del_votes ()) (fun () ->
    Result.bind (C.exec del_comments ()) (fun () ->
    C.exec del_posts ()))
  ) pool with
  | Ok () -> ()
  | Error _ -> ()

let insert_legacy_keeper_post t =
  let open Caqti_request.Infix in
  let post_id = Printf.sprintf "pg-test-legacy-%06x" (Random.bits ()) in
  let now = Unix.gettimeofday () in
  let insert_q =
    (Caqti_type.(t3 string float float) ->. Caqti_type.unit)
      "INSERT INTO masc_board_posts \
       (id, author, content, title, body, created_at, updated_at, meta_json) \
       VALUES (?, 'pg-test-keeper', 'keeper', 'Legacy keeper', 'keeper', ?, ?, \
         '{\"source\":\"keeper_board_post\"}')"
  in
  match
    Caqti_eio.Pool.use
      (fun (module C : Caqti_eio.CONNECTION) ->
        C.exec insert_q (post_id, now, now))
      (Board_pg.get_pool t)
  with
  | Ok () -> post_id
  | Error err ->
      Alcotest.fail
        (Printf.sprintf "legacy insert failed: %s" (Caqti_error.show err))

(** {1 Helper: run test inside Eio with PG pool} *)

let with_pg_backend f () =
  match pg_url () with
  | None -> Alcotest.skip ()
  | Some url ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let uri = Uri.of_string url in
      let pool_config = Caqti_pool_config.create ~max_size:2 () in
      let stdenv = (env :> Caqti_eio.stdenv) in
      match Caqti_eio_unix.connect_pool ~sw ~stdenv ~pool_config uri with
      | Error err ->
          Alcotest.fail (Printf.sprintf "Pool creation failed: %s" (Caqti_error.show err))
      | Ok pool ->
      match Board_pg.create pool with
      | Error e ->
          Alcotest.fail (Printf.sprintf "Board_pg.create failed: %s" (Board.show_board_error e))
      | Ok t ->
          cleanup_test_data pool;
          Fun.protect
            (fun () -> f t)
            ~finally:(fun () -> cleanup_test_data pool)

(** {1 Post CRUD} *)

let test_create_and_get_post = with_pg_backend (fun t ->
  match
    Board_pg.create_post t ~author:"pg-test-agent" ~content:"PG test post"
      ~post_kind:Board.Human_post ()
  with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      Alcotest.(check string) "author" "pg-test-agent" (Board.Agent_id.to_string post.author);
      Alcotest.(check string) "content" "PG test post" post.content;
      match Board_pg.get_post t ~post_id:pid with
      | Error e -> Alcotest.fail (Board.show_board_error e)
      | Ok fetched ->
          Alcotest.(check string) "content matches" "PG test post" fetched.content
)

let test_list_posts = with_pg_backend (fun t ->
  ignore (Board_pg.create_post t ~author:"pg-test-lister" ~content:"pg list 1"
            ~post_kind:Board.Human_post ());
  ignore (Board_pg.create_post t ~author:"pg-test-lister" ~content:"pg list 2"
            ~post_kind:Board.Human_post ());
  let posts = Board_pg.list_posts t ~limit:10 () in
  Alcotest.(check bool) "at least 2 posts" true (List.length posts >= 2)
)

let test_list_posts_sort_orders = with_pg_backend (fun t ->
  ignore (Board_pg.create_post t ~author:"pg-test-sorter" ~content:"sort test"
            ~post_kind:Board.Human_post ());
  let _hot = Board_pg.list_posts t ~sort_by:Board_pg.Hot ~limit:5 () in
  let _recent = Board_pg.list_posts t ~sort_by:Board_pg.Recent ~limit:5 () in
  let _trending = Board_pg.list_posts t ~sort_by:Board_pg.Trending ~limit:5 () in
  let _updated = Board_pg.list_posts t ~sort_by:Board_pg.Updated ~limit:5 () in
  let _discussed = Board_pg.list_posts t ~sort_by:Board_pg.Discussed ~limit:5 () in
  (* All sort orders should work without error *)
  ()
)

let test_reclassify_posts = with_pg_backend (fun t ->
  let pid = insert_legacy_keeper_post t in
  let dry_run = Board_pg.reclassify_posts t ~dry_run:true () in
  Alcotest.(check int) "dry run changed" 1 dry_run.changed;
  (match Board_pg.get_post t ~post_id:pid with
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok fetched ->
       Alcotest.(check string) "legacy row resolves as automation" "automation"
         (Board.post_kind_to_string fetched.post_kind));
  let applied = Board_pg.reclassify_posts t ~dry_run:false () in
  Alcotest.(check int) "apply changed" 1 applied.changed;
  match Board_pg.get_post t ~post_id:pid with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok fetched ->
      Alcotest.(check string) "persisted as automation" "automation"
        (Board.post_kind_to_string fetched.post_kind)
)

(** {1 Comment Operations} *)

let test_add_and_get_comments = with_pg_backend (fun t ->
  match
    Board_pg.create_post t ~author:"pg-test-commenter" ~content:"post for pg comments"
      ~post_kind:Board.Human_post ()
  with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      (match Board_pg.add_comment t ~post_id:pid ~author:"pg-test-responder" ~content:"pg comment" () with
       | Error e -> Alcotest.fail (Board.show_board_error e)
       | Ok _ -> ());
      match Board_pg.get_comments t ~post_id:pid with
      | Error e -> Alcotest.fail (Board.show_board_error e)
      | Ok comments ->
          Alcotest.(check bool) "has comment" true (List.length comments >= 1)
)

let test_list_posts_matches_comment_author = with_pg_backend (fun t ->
  let matching_post =
    match
      Board_pg.create_post t ~author:"pg-test-owner-a"
        ~content:"pg comment author filter match"
        ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let other_post =
    match
      Board_pg.create_post t ~author:"pg-test-owner-b"
        ~content:"pg comment author filter miss"
        ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let matching_post_id = Board.Post_id.to_string matching_post.id in
  let other_post_id = Board.Post_id.to_string other_post.id in
  (match
     Board_pg.add_comment t ~post_id:matching_post_id
       ~author:"pg-test-comment-match" ~content:"visible author match" ()
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  (match
     Board_pg.add_comment t ~post_id:other_post_id
       ~author:"pg-test-comment-miss" ~content:"other author" ()
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  let filtered =
    Board_pg.list_posts t ~sort_by:Board_pg.Recent
      ~author_filter:"COMMENT-MATCH" ~limit:10 ()
  in
  let ids =
    List.map (fun (post : Board.post) -> Board.Post_id.to_string post.id) filtered
  in
  Alcotest.(check bool) "matching comment author includes post" true
    (List.mem matching_post_id ids);
  Alcotest.(check bool) "non matching comment author excluded" false
    (List.mem other_post_id ids)
)

let test_author_filter_treats_wildcards_literally = with_pg_backend (fun t ->
  ignore
    (Board_pg.create_post t ~author:"pg-test-wildcard-alpha"
       ~content:"pg literal wildcard filter" ~post_kind:Board.Human_post ());
  let filtered =
    Board_pg.list_posts t ~sort_by:Board_pg.Recent
      ~author_filter:"%" ~limit:10 ()
  in
  Alcotest.(check int) "percent does not match all authors" 0
    (List.length filtered)
)

(** {1 Vote Operations} *)

let test_vote_post = with_pg_backend (fun t ->
  match
    Board_pg.create_post t ~author:"pg-test-voter" ~content:"pg vote me"
      ~post_kind:Board.Human_post ()
  with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      match Board_pg.vote_post t ~voter:"pg-test-judge" ~post_id:pid ~direction:Board.Up with
      | Error e -> Alcotest.fail (Board.show_board_error e)
      | Ok score ->
          Alcotest.(check int) "score after upvote" 1 score
)

let test_vote_dedup = with_pg_backend (fun t ->
  match
    Board_pg.create_post t ~author:"pg-test-dedup" ~content:"pg dedup vote"
      ~post_kind:Board.Human_post ()
  with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      ignore (Board_pg.vote_post t ~voter:"pg-test-same" ~post_id:pid ~direction:Board.Up);
      match Board_pg.vote_post t ~voter:"pg-test-same" ~post_id:pid ~direction:Board.Up with
      | Ok _ -> Alcotest.fail "Expected Already_voted error"
      | Error (Board.Already_voted _) -> ()
      | Error e -> Alcotest.fail (Board.show_board_error e)
)

let test_vote_flip = with_pg_backend (fun t ->
  match
    Board_pg.create_post t ~author:"pg-test-flipper" ~content:"pg flip vote"
      ~post_kind:Board.Human_post ()
  with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      ignore (Board_pg.vote_post t ~voter:"pg-test-flipper-v" ~post_id:pid ~direction:Board.Up);
      (* Flip from Up to Down *)
      match Board_pg.vote_post t ~voter:"pg-test-flipper-v" ~post_id:pid ~direction:Board.Down with
      | Error e -> Alcotest.fail (Board.show_board_error e)
      | Ok score ->
          (* Was +1 (up), now flipped: -1 (down) = score -1 *)
          Alcotest.(check int) "score after flip" (-1) score
)

(** Verify multiple distinct voters produce correct final score.
    Before the transaction fix, concurrent SELECT+INSERT+UPDATE could
    inflate counters when two votes raced on the same post. *)
let test_vote_multiple_voters = with_pg_backend (fun t ->
  match
    Board_pg.create_post t ~author:"pg-test-multi-voter" ~content:"pg multi vote"
      ~post_kind:Board.Human_post ()
  with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      (* 3 upvotes from distinct voters *)
      (match Board_pg.vote_post t ~voter:"pg-voter-a" ~post_id:pid ~direction:Board.Up with
       | Error e -> Alcotest.fail (Board.show_board_error e)
       | Ok s -> Alcotest.(check int) "score after voter-a" 1 s);
      (match Board_pg.vote_post t ~voter:"pg-voter-b" ~post_id:pid ~direction:Board.Up with
       | Error e -> Alcotest.fail (Board.show_board_error e)
       | Ok s -> Alcotest.(check int) "score after voter-b" 2 s);
      (match Board_pg.vote_post t ~voter:"pg-voter-c" ~post_id:pid ~direction:Board.Down with
       | Error e -> Alcotest.fail (Board.show_board_error e)
       | Ok s -> Alcotest.(check int) "score after voter-c (down)" 1 s);
      (* Verify final post state *)
      (match Board_pg.get_post t ~post_id:pid with
       | Error e -> Alcotest.fail (Board.show_board_error e)
       | Ok p ->
           Alcotest.(check int) "final votes_up" 2 p.votes_up;
           Alcotest.(check int) "final votes_down" 1 p.votes_down)
)

let test_vote_comment_atomic = with_pg_backend (fun t ->
  match
    Board_pg.create_post t ~author:"pg-test-cv" ~content:"pg comment vote"
      ~post_kind:Board.Human_post ()
  with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      (match Board_pg.add_comment t ~post_id:pid ~author:"pg-test-cv-a" ~content:"test" () with
       | Error e -> Alcotest.fail (Board.show_board_error e)
       | Ok cmt ->
           let cid = Board.Comment_id.to_string cmt.id in
           (match Board_pg.vote_comment t ~voter:"pg-cv-1" ~comment_id:cid ~direction:Board.Up with
            | Error e -> Alcotest.fail (Board.show_board_error e)
            | Ok s -> Alcotest.(check int) "comment score" 1 s);
           (* Duplicate vote returns Already_voted *)
           (match Board_pg.vote_comment t ~voter:"pg-cv-1" ~comment_id:cid ~direction:Board.Up with
            | Ok _ -> Alcotest.fail "Expected Already_voted"
            | Error (Board.Already_voted _) -> ()
            | Error e -> Alcotest.fail (Board.show_board_error e)))
)

(** {1 Stats / Search / Hearth} *)

let test_stats = with_pg_backend (fun t ->
  let stats = Board_pg.stats t in
  match stats with
  | `Assoc fields ->
      Alcotest.(check bool) "has post_count" true (List.mem_assoc "post_count" fields);
      Alcotest.(check bool) "has backend" true (List.mem_assoc "backend" fields);
      (match List.assoc_opt "backend" fields with
       | Some (`String "postgresql") -> ()
       | _ -> Alcotest.fail "backend should be 'postgresql'")
  | _ -> Alcotest.fail "stats should be JSON object"
)

let test_search = with_pg_backend (fun t ->
  ignore (Board_pg.create_post t ~author:"pg-test-searcher"
            ~content:"pg_unique_xyz_search_term" ~post_kind:Board.Human_post ());
  let results = Board_pg.search t ~query:"pg_unique_xyz_search_term" ~limit:10 in
  Alcotest.(check bool) "found search result" true (List.length results >= 1)
)

let test_hearths = with_pg_backend (fun t ->
  ignore (Board_pg.create_post t ~author:"pg-test-hearth" ~content:"pg fire topic"
    ~hearth:"pg-test-hearth" ~post_kind:Board.Human_post ());
  let hearths = Board_pg.list_hearths t in
  Alcotest.(check bool) "has hearths" true (List.length hearths >= 1)
)

let test_set_thread_id = with_pg_backend (fun t ->
  match
    Board_pg.create_post t ~author:"pg-test-thread" ~content:"pg link me"
      ~post_kind:Board.Human_post ()
  with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      let pid = Board.Post_id.to_string post.id in
      match Board_pg.set_thread_id t ~post_id:pid ~thread_id:"pg-thread-abc" with
      | Error e -> Alcotest.fail (Board.show_board_error e)
      | Ok () ->
          match Board_pg.get_post t ~post_id:pid with
          | Error e -> Alcotest.fail (Board.show_board_error e)
          | Ok p ->
              Alcotest.(check (option string)) "thread_id set"
                (Some "pg-thread-abc") p.thread_id
)

(** {1 Validation} *)

let test_empty_content = with_pg_backend (fun t ->
  match
    Board_pg.create_post t ~author:"pg-test-validator" ~content:""
      ~post_kind:Board.Human_post ()
  with
  | Ok _ -> Alcotest.fail "Expected validation error for empty content"
  | Error (Board.Validation_error _) -> ()
  | Error e -> Alcotest.fail (Board.show_board_error e)
)

let test_empty_author = with_pg_backend (fun t ->
  match
    Board_pg.create_post t ~author:"" ~content:"valid content"
      ~post_kind:Board.Human_post ()
  with
  | Ok _ -> Alcotest.fail "Expected validation error for empty author"
  | Error _ -> ()
)

(** {1 Sweep} *)

let test_sweep = with_pg_backend (fun t ->
  let (swept_posts, swept_comments) = Board_pg.sweep t in
  (* Sweep should not error; counts are >= 0 *)
  Alcotest.(check bool) "swept posts >= 0" true (swept_posts >= 0);
  Alcotest.(check bool) "swept comments >= 0" true (swept_comments >= 0)
)

(** {1 Test Runner} *)

let () =
  Alcotest.run "Board_pg" [
    "posts", [
      Alcotest.test_case "create and get" `Quick test_create_and_get_post;
      Alcotest.test_case "list" `Quick test_list_posts;
      Alcotest.test_case "sort orders" `Quick test_list_posts_sort_orders;
      Alcotest.test_case "reclassify posts" `Quick test_reclassify_posts;
    ];
    "comments", [
      Alcotest.test_case "add and get" `Quick test_add_and_get_comments;
      Alcotest.test_case "comment author filter" `Quick
        test_list_posts_matches_comment_author;
      Alcotest.test_case "literal wildcard filter" `Quick
        test_author_filter_treats_wildcards_literally;
    ];
    "votes", [
      Alcotest.test_case "upvote" `Quick test_vote_post;
      Alcotest.test_case "dedup" `Quick test_vote_dedup;
      Alcotest.test_case "flip" `Quick test_vote_flip;
      Alcotest.test_case "multiple voters" `Quick test_vote_multiple_voters;
      Alcotest.test_case "comment vote atomic" `Quick test_vote_comment_atomic;
    ];
    "misc", [
      Alcotest.test_case "stats" `Quick test_stats;
      Alcotest.test_case "search" `Quick test_search;
      Alcotest.test_case "hearths" `Quick test_hearths;
      Alcotest.test_case "set_thread_id" `Quick test_set_thread_id;
      Alcotest.test_case "sweep" `Quick test_sweep;
    ];
    "validation", [
      Alcotest.test_case "empty content" `Quick test_empty_content;
      Alcotest.test_case "empty author" `Quick test_empty_author;
    ];
  ]
