(** Current Board vote persistence contract.

    Append and snapshot writers preserve the cast timestamp, a flip records a
    new cast timestamp, and restart accepts only the exact row shape emitted by
    those writers. *)

open Masc

let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

let fresh_test_base_path () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-vote-ts-%06x" (Random.bits ()))
  in
  Fs_compat.mkdir_p dir;
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

(* Deny board writes through permissions instead of breaking the workspace
   boundary: the store files lose their write bits (append fails) and the
   workspace directory loses create/rename rights (the rewrite stage fails),
   while reads and workspace observation keep working. The earlier fixture
   replaced .masc with a regular file, which made the posts source re-observe
   a refused workspace and latch Posts_refused — every write then stayed
   refused even after the fixture restored the directory (#47727). Same
   fixture as [test_board_dispatch.ml]'s [with_blocked_board_masc_dir];
   duplicated locally per this suite's existing per-file fixture convention
   (see [fresh_test_base_path] above). *)
let with_blocked_board_masc_dir f =
  (* Root ignores file permission bits, so a permission-denied fixture would
     silently stop denying writes and the blocked-phase assertions would
     fail for the opposite reason. The previous regular-file fixture stayed
     effective under root; this one skips instead of lying. *)
  if Unix.geteuid () = 0 then Alcotest.skip ();
  let store = Board.global () in
  let masc_dir = (Board.workspace_masc_dir store) in
  let paths =
    [ Board.persist_path store; Board.comments_path store; Board.vote_log_path store
    ; Board.reactions_path store; Board.sub_boards_path store ]
  in
  List.iter Fs_compat.invalidate_cached_writer paths;
  let file_modes =
    List.filter_map
      (fun path ->
         if Sys.file_exists path then Some (path, (Unix.stat path).Unix.st_perm) else None)
      paths
  in
  let dir_mode = (Unix.stat masc_dir).Unix.st_perm in
  List.iter (fun (path, _) -> Unix.chmod path 0o444) file_modes;
  Unix.chmod masc_dir 0o555;
  Fun.protect
    ~finally:(fun () ->
      Unix.chmod masc_dir dir_mode;
      List.iter (fun (path, mode) -> Unix.chmod path mode) file_modes;
      List.iter Fs_compat.invalidate_cached_writer paths)
    f

let with_eio f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (fresh_test_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  f ()

let read_ts_rows path =
  (* Read each jsonl row as (target, voter, ts). *)
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
    let rec loop acc =
      match try Some (input_line ic) with End_of_file -> None with
      | None -> List.rev acc
      | Some line ->
        let json = Yojson.Safe.from_string line in
        let target =
          match Safe_ops.json_string_opt "target" json with
          | Some s -> s
          | None -> ""
        in
        let voter =
          match Safe_ops.json_string_opt "voter" json with
          | Some s -> s
          | None -> ""
        in
        let ts =
          match Safe_ops.json_float_opt "ts" json with
          | Some t -> t
          | None -> nan
        in
        loop ((target, voter, ts) :: acc)
    in
    loop [])

let find_row ~target ~voter rows =
  List.find_opt (fun (t, v, _) -> t = target && v = voter) rows

let remove_key json key =
  match json with
  | `Assoc fields ->
    `Assoc (List.filter (fun (name, _) -> not (String.equal name key)) fields)
  | other -> other

let prepend_field json field =
  match json with
  | `Assoc fields -> `Assoc (field :: fields)
  | other -> other

let replace_key json key value =
  match json with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (name, current) ->
            if String.equal name key then name, value else name, current)
         fields)
  | other -> other

let vote_row ~post_id ~voter ~direction ~ts =
  `Assoc
    [ "target", `String ("post:" ^ post_id ^ ":" ^ voter)
    ; "voter", `String voter
    ; "direction", `String direction
    ; "ts", `Float ts
    ]

let create_post_exn ~author ~content =
  match
    Board_dispatch.create_post ~author ~content
      ~post_kind:Board.Human_post ()
  with
  | Ok post -> post
  | Error e -> Alcotest.fail (Board.Post_publication_failure.to_string e)

let add_comment_exn ~post_id ~author ~content =
  match Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author ~content () with
  | Ok comment -> comment
  | Error e -> Alcotest.fail (Board.show_board_error e)

let expect_io_error label = function
  | Error (Board.Io_error _) -> ()
  | Error error ->
    Alcotest.failf "%s returned the wrong error: %s" label (Board.show_board_error error)
  | Ok _ -> Alcotest.failf "%s mutated an unreadable snapshot" label
;;

let test_flush_preserves_cast_ts () =
  let voter = "ts-preserve-voter" in
  let post =
    create_post_exn ~author:"ts-preserve-author"
      ~content:"preserve my timestamp"
  in
  let pid = Board.Post_id.to_string post.id in
  let target = "post:" ^ pid ^ ":" ^ voter in
  (match Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id:pid ~direction:Board.Up with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  let append_rows = read_ts_rows (Board_votes.vote_log_path (Board.global ())) in
  let cast_ts =
    match find_row ~target ~voter append_rows with
    | Some (_, _, ts) -> ts
    | None -> Alcotest.fail "append jsonl missing cast row"
  in
  Unix.sleepf 0.05;
  let before_flush_now = Time_compat.now () in
  Alcotest.(check bool)
    "wall clock advanced past cast" true
    (before_flush_now > cast_ts +. 0.01);
  Board.flush_dirty (Board_dispatch.backend ());
  let rewrite_rows = read_ts_rows (Board_votes.vote_log_path (Board.global ())) in
  let rewritten_ts =
    match find_row ~target ~voter rewrite_rows with
    | Some (_, _, ts) -> ts
    | None -> Alcotest.fail "rewrite jsonl missing cast row"
  in
  Alcotest.(check (float 1e-9))
    "ts preserved across flush (no wall-clock overwrite)"
    cast_ts rewritten_ts;
  Alcotest.(check bool)
    "ts strictly less than post-flush clock"
    true
    (rewritten_ts < before_flush_now)

let test_flip_inherits_flip_time () =
  let voter = "flip-voter" in
  let post =
    create_post_exn ~author:"flip-author" ~content:"flipper post"
  in
  let pid = Board.Post_id.to_string post.id in
  let target = "post:" ^ pid ^ ":" ^ voter in
  (match Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id:pid ~direction:Board.Up with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  let up_rows = read_ts_rows (Board_votes.vote_log_path (Board.global ())) in
  let up_ts =
    match find_row ~target ~voter up_rows with
    | Some (_, _, ts) -> ts
    | None -> Alcotest.fail "jsonl missing up row"
  in
  Unix.sleepf 0.05;
  (match Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id:pid ~direction:Board.Down with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  let flip_rows = read_ts_rows (Board_votes.vote_log_path (Board.global ())) in
  let last_flip_row =
    List.fold_left (fun acc row ->
      let (t, v, _) = row in
      if t = target && v = voter then Some row else acc)
      None flip_rows
  in
  match last_flip_row with
  | None -> Alcotest.fail "jsonl missing flip row"
  | Some (_, _, flip_ts) ->
      Alcotest.(check bool)
        "flip ts strictly greater than original up ts"
        true (flip_ts > up_ts +. 0.01);
      Board.flush_dirty (Board_dispatch.backend ());
      let rewrite_rows = read_ts_rows (Board_votes.vote_log_path (Board.global ())) in
      let rewritten_ts =
        match find_row ~target ~voter rewrite_rows with
        | Some (_, _, ts) -> ts
        | None -> Alcotest.fail "rewrite jsonl missing flipped row"
      in
      Alcotest.(check (float 1e-9))
        "rewrite persists flip-time (not original up ts, not now)"
        flip_ts rewritten_ts

let test_comment_vote_flips_and_duplicate_survive_restart () =
  let post = create_post_exn ~author:"comment-vote-author" ~content:"vote lifecycle" in
  let post_id = Board.Post_id.to_string post.id in
  let comment =
    add_comment_exn ~post_id ~author:"comment-vote-commenter" ~content:"flip my votes"
  in
  let comment_id = Board.Comment_id.to_string comment.id in
  let voter = "comment-vote-flipper" in
  let check_counts label votes_up votes_down =
    match Board_dispatch.get_comments ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
    | Error error -> Alcotest.fail (Board.show_board_error error)
    | Ok [ loaded ] ->
      Alcotest.(check int) (label ^ " up") votes_up loaded.votes_up;
      Alcotest.(check int) (label ^ " down") votes_down loaded.votes_down
    | Ok comments -> Alcotest.failf "expected one comment, got %d" (List.length comments)
  in
  let cast direction score =
    match Board_dispatch.vote_comment ~reader:Masc_board_handlers.Board_access.Operator ~voter ~comment_id ~direction with
    | Ok actual -> Alcotest.(check int) "comment score after cast" score actual
    | Error error -> Alcotest.fail (Board.show_board_error error)
  in
  cast Board.Down (-1);
  check_counts "first downvote" 0 1;
  cast Board.Up 1;
  check_counts "flip to up" 1 0;
  cast Board.Down (-1);
  check_counts "flip back to down" 0 1;
  let before_duplicate = Fs_compat.load_file (Board_votes.vote_log_path (Board.global ())) in
  (match Board_dispatch.vote_comment ~reader:Masc_board_handlers.Board_access.Operator ~voter ~comment_id ~direction:Board.Down with
   | Error (Board.Already_voted _) -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok _ -> Alcotest.fail "same-direction comment vote was accepted");
  check_counts "rejected duplicate" 0 1;
  Alcotest.(check string) "duplicate does not append a durable row" before_duplicate
    (Fs_compat.load_file (Board_votes.vote_log_path (Board.global ())));
  Board.flush_dirty (Board_dispatch.backend ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  check_counts "restarted comment" 0 1;
  (match Board_dispatch.current_vote_for_comment ~reader:Masc_board_handlers.Board_access.Operator ~voter ~comment_id with
   | Ok (Some Board.Down) -> ()
   | Ok (Some Board.Up) -> Alcotest.fail "restart restored the previous direction"
   | Ok None -> Alcotest.fail "restart lost the comment vote"
   | Error error -> Alcotest.fail (Board.show_board_error error));
  cast Board.Up 1;
  check_counts "flip after restart" 1 0

let test_restart_loads_only_current_vote_rows () =
  let post =
    create_post_exn
      ~author:"vote-row-author"
      ~content:"current vote row schema"
  in
  let post_id = Board.Post_id.to_string post.id in
  let now = Time_compat.now () in
  let canonical = vote_row ~post_id ~voter:"current-voter" ~direction:"up" ~ts:now in
  let distinct voter = vote_row ~post_id ~voter ~direction:"down" ~ts:now in
  let rejected_rows =
    [ remove_key (distinct "missing-ts") "ts"
    ; remove_key (distinct "missing-voter") "voter"
    ; prepend_field (distinct "unknown-field") ("unknown", `Int 1)
    ; prepend_field (distinct "duplicate-field") ("voter", `String "duplicate")
    ; replace_key (distinct "uppercase-direction") "direction" (`String "UP")
    ; replace_key (distinct "integer-ts") "ts" (`Int 1)
    ; replace_key (distinct "zero-ts") "ts" (`Float 0.0)
    ; replace_key (distinct "mismatched-voter") "voter" (`String "other-voter")
    ; replace_key
        (distinct "malformed-target")
        "target"
        (`String "post:not valid:malformed-target")
    ]
  in
  Fs_compat.save_file
    (Board_votes.vote_log_path (Board.global ()))
    (String.concat
       ""
       (List.map
          (fun json -> Yojson.Safe.to_string json ^ "\n")
          (canonical :: rejected_rows)));
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  let store = Board_dispatch.backend () in
  Alcotest.(check int)
    "only one exact current row loaded"
    1
    (Hashtbl.length store.vote_log);
  (* The rejected rows leave the ledger partially read, so the vote source
     stays refused: the canonical row is loaded into memory (checked above)
     but reading a current vote through the store is unavailable. *)
  expect_io_error
    "current vote read after rejected rows"
    (Board_dispatch.current_vote_for_post ~reader:Masc_board_handlers.Board_access.Operator
       ~voter:"current-voter"
       ~post_id)

let test_namespaced_voter_survives_snapshot_and_restart () =
  let voter = "keeper:foo" in
  let post =
    create_post_exn
      ~author:"namespaced-voter-author"
      ~content:"namespaced voter snapshot"
  in
  let post_id = Board.Post_id.to_string post.id in
  let target = "post:" ^ post_id ^ ":" ^ voter in
  (match Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id ~direction:Board.Up with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error));
  Board.flush_dirty (Board_dispatch.backend ());
  let rows = read_ts_rows (Board_votes.vote_log_path (Board.global ())) in
  Alcotest.(check bool)
    "snapshot keeps the complete namespaced voter"
    true
    (Option.is_some (find_row ~target ~voter rows));
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  (match Board_dispatch.current_vote_for_post ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id with
   | Ok (Some Board.Up) -> ()
   | Ok (Some Board.Down) -> Alcotest.fail "snapshot changed vote direction"
   | Ok None -> Alcotest.fail "snapshot lost namespaced voter"
   | Error error -> Alcotest.fail (Board.show_board_error error));
  match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok loaded ->
    Alcotest.(check int) "ledger rebuilds post votes_up" 1 loaded.votes_up;
    Alcotest.(check int) "ledger rebuilds post votes_down" 0 loaded.votes_down

let test_restart_uses_last_vote_row_and_rebuilds_counts () =
  let post =
    create_post_exn
      ~author:"counter-rebuild-author"
      ~content:"vote ledger counter rebuild"
  in
  let post_id = Board.Post_id.to_string post.id in
  let comment =
    add_comment_exn
      ~post_id
      ~author:"counter-rebuild-commenter"
      ~content:"comment counter rebuild"
  in
  let comment_id = Board.Comment_id.to_string comment.id in
  let now = Time_compat.now () in
  let rows =
    [ vote_row ~post_id ~voter:"flip-voter" ~direction:"up" ~ts:now
    ; vote_row
        ~post_id
        ~voter:"flip-voter"
        ~direction:"down"
        ~ts:(now +. 0.1)
    ; `Assoc
        [ ( "target"
          , `String ("comment:" ^ comment_id ^ ":comment-ledger-voter") )
        ; "voter", `String "comment-ledger-voter"
        ; "direction", `String "up"
        ; "ts", `Float (now +. 0.2)
        ]
    ]
  in
  Fs_compat.save_file
    (Board_votes.vote_log_path (Board.global ()))
    (String.concat
       ""
       (List.map (fun json -> Yojson.Safe.to_string json ^ "\n") rows));
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  (match
     Board_dispatch.current_vote_for_post ~reader:Masc_board_handlers.Board_access.Operator
       ~voter:"flip-voter"
       ~post_id
   with
   | Ok (Some Board.Down) -> ()
   | Ok (Some Board.Up) -> Alcotest.fail "first row incorrectly won"
   | Ok None -> Alcotest.fail "last vote row was not loaded"
   | Error error -> Alcotest.fail (Board.show_board_error error));
  (match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok loaded ->
     Alcotest.(check int) "post votes_up rebuilt from ledger" 0 loaded.votes_up;
     Alcotest.(check int) "post votes_down rebuilt from ledger" 1 loaded.votes_down);
  match Board_dispatch.get_comments ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok [ loaded ] ->
    Alcotest.(check string)
      "loaded expected comment"
      comment_id
      (Board.Comment_id.to_string loaded.id);
    Alcotest.(check int) "comment votes_up rebuilt from ledger" 1 loaded.votes_up;
    Alcotest.(check int) "comment votes_down rebuilt from ledger" 0 loaded.votes_down
  | Ok comments ->
    Alcotest.failf "expected one comment, got %d" (List.length comments)

let test_missing_ledger_resets_persisted_vote_counts () =
  let post =
    create_post_exn
      ~author:"missing-ledger-author"
      ~content:"missing vote ledger"
  in
  let post_id = Board.Post_id.to_string post.id in
  (match
     Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator
       ~voter:"missing-ledger-voter"
       ~post_id
       ~direction:Board.Up
   with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error));
  Board.flush_dirty (Board_dispatch.backend ());
  Unix.unlink (Board_votes.vote_log_path (Board.global ()));
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok loaded ->
    Alcotest.(check int) "missing ledger clears votes_up" 0 loaded.votes_up;
    Alcotest.(check int) "missing ledger clears votes_down" 0 loaded.votes_down

let test_vote_persistence_failure_leaves_nothing_committed () =
  let voter = "persist-fail-voter" in
  let post =
    create_post_exn ~author:"persist-fail-author"
      ~content:"vote must not survive a failed append"
  in
  let post_id = Board.Post_id.to_string post.id in
  with_blocked_board_masc_dir (fun () ->
  let before_errors = Board.persist_error_count () in
  (match Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id ~direction:Board.Up with
   | Ok _ -> Alcotest.fail "vote must not succeed when the durable append fails"
   | Error (Board.Io_error _) -> ()
   | Error e -> Alcotest.fail ("expected Io_error, got " ^ Board.show_board_error e));
  Alcotest.(check bool)
    "persist error counter incremented"
    true
    (Board.persist_error_count () > before_errors);
  (match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok loaded ->
     Alcotest.(check int) "write-ahead: post keeps votes_up at 0" 0 loaded.votes_up;
     Alcotest.(check int) "write-ahead: post keeps votes_down at 0" 0 loaded.votes_down);
  (match Board_dispatch.current_vote_for_post ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "a failed append must not leave a vote log entry"
   | Error e -> Alcotest.fail (Board.show_board_error e))
  (* Nothing was committed, so the same vote is not blocked by Already_voted
     once the append can actually succeed — the earlier failure left no
     residual state to collide with. *)
  );
  (match Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id ~direction:Board.Up with
   | Ok score -> Alcotest.(check int) "retry after unblock succeeds" 1 score
   | Error e -> Alcotest.fail ("retry must succeed, got " ^ Board.show_board_error e));
  Board.flush_dirty (Board_dispatch.backend ());
  let rows = read_ts_rows (Board_votes.vote_log_path (Board.global ())) in
  let target = "post:" ^ post_id ^ ":" ^ voter in
  Alcotest.(check int)
    "flush snapshot has exactly the retried vote, no ghost from the failed attempt"
    1
    (List.length (List.filter (fun (t, v, _) -> t = target && v = voter) rows))

let test_vote_flip_persistence_failure_leaves_original_direction_committed () =
  let voter = "persist-fail-flip-voter" in
  let post =
    create_post_exn ~author:"persist-fail-flip-author"
      ~content:"flip must not survive a failed append"
  in
  let post_id = Board.Post_id.to_string post.id in
  (match Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id ~direction:Board.Up with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  with_blocked_board_masc_dir (fun () ->
  let before_errors = Board.persist_error_count () in
  (match Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id ~direction:Board.Down with
   | Ok _ -> Alcotest.fail "flip must not succeed when the durable append fails"
   | Error (Board.Io_error _) -> ()
   | Error e -> Alcotest.fail ("expected Io_error, got " ^ Board.show_board_error e));
  Alcotest.(check bool)
    "persist error counter incremented"
    true
    (Board.persist_error_count () > before_errors);
  (match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok loaded ->
     Alcotest.(check int) "write-ahead: flip never applied, votes_up stays 1" 1 loaded.votes_up;
     Alcotest.(check int) "write-ahead: flip never applied, votes_down stays 0" 0 loaded.votes_down);
  (match Board_dispatch.current_vote_for_post ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id with
   | Ok (Some Board.Up) -> ()
   | Ok (Some Board.Down) -> Alcotest.fail "a failed flip must not persist the new direction"
   | Ok None -> Alcotest.fail "a failed flip must not erase the original vote"
   | Error e -> Alcotest.fail (Board.show_board_error e))
  (* The original "up" vote is still the only committed state, so retrying
     the flip once the append can succeed is a normal flip, not a collision. *)
  );
  (match Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id ~direction:Board.Down with
   | Ok score -> Alcotest.(check int) "retried flip after unblock succeeds" (-1) score
   | Error e -> Alcotest.fail ("retried flip must succeed, got " ^ Board.show_board_error e));
  Board.flush_dirty (Board_dispatch.backend ());
  let rows = read_ts_rows (Board_votes.vote_log_path (Board.global ())) in
  let target = "post:" ^ post_id ^ ":" ^ voter in
  Alcotest.(check int)
    "flush snapshot has exactly one row for this voter, no ghost \"down\" from the failed flip"
    1
    (List.length (List.filter (fun (t, v, _) -> t = target && v = voter) rows))

let test_vote_comment_persistence_failure_leaves_nothing_committed () =
  let voter = "persist-fail-comment-voter" in
  let post =
    create_post_exn ~author:"persist-fail-comment-author"
      ~content:"comment vote must not survive a failed append"
  in
  let post_id = Board.Post_id.to_string post.id in
  let comment =
    add_comment_exn ~post_id ~author:"persist-fail-commenter"
      ~content:"comment under test"
  in
  let comment_id = Board.Comment_id.to_string comment.id in
  with_blocked_board_masc_dir (fun () ->
  let before_errors = Board.persist_error_count () in
  (match Board_dispatch.vote_comment ~reader:Masc_board_handlers.Board_access.Operator ~voter ~comment_id ~direction:Board.Up with
   | Ok _ -> Alcotest.fail "comment vote must not succeed when the durable append fails"
   | Error (Board.Io_error _) -> ()
   | Error e -> Alcotest.fail ("expected Io_error, got " ^ Board.show_board_error e));
  Alcotest.(check bool)
    "persist error counter incremented"
    true
    (Board.persist_error_count () > before_errors);
  (match Board_dispatch.get_comments ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok [ loaded ] ->
     Alcotest.(check int) "write-ahead: comment keeps votes_up at 0" 0 loaded.votes_up;
     Alcotest.(check int) "write-ahead: comment keeps votes_down at 0" 0 loaded.votes_down
   | Ok comments -> Alcotest.failf "expected one comment, got %d" (List.length comments));
  (match Board_dispatch.current_vote_for_comment ~reader:Masc_board_handlers.Board_access.Operator ~voter ~comment_id with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "a failed append must not leave a vote log entry"
   | Error e -> Alcotest.fail (Board.show_board_error e))
  );
  (match Board_dispatch.vote_comment ~reader:Masc_board_handlers.Board_access.Operator ~voter ~comment_id ~direction:Board.Up with
   | Ok score -> Alcotest.(check int) "retry after unblock succeeds" 1 score
   | Error e -> Alcotest.fail ("retry must succeed, got " ^ Board.show_board_error e));
  Board.flush_dirty (Board_dispatch.backend ());
  let rows = read_ts_rows (Board_votes.vote_log_path (Board.global ())) in
  let target = "comment:" ^ comment_id ^ ":" ^ voter in
  Alcotest.(check int)
    "flush snapshot has exactly the retried vote, no ghost from the failed attempt"
    1
    (List.length (List.filter (fun (t, v, _) -> t = target && v = voter) rows))

(* Only the vote log write fails here: posts and comments land, so the two
   writers that already re-mark on failure stay quiet and the assertion is
   about the third. A directory sitting where the vote log file goes makes
   [save_file_atomic] fail without disturbing anything else.

   [flush_dirty] clears the dirty flags before writing. Dropping this failure
   left the cast votes out of the log with nothing scheduled to write them
   again -- the shape the posts and comments writers fixed in #26168. *)
(* Why a cancelled shutdown flush does not lose its snapshot.

   [flush_dirty] clears the dirty flags before it writes, so a write that never
   happens would drop the snapshot with nothing scheduled to retry -- the
   #26168 shape. The snapshot writers, including [save_reactions_jsonl_result],
   catch [Sys_error] while cancellation propagates through the batch. The
   caller in [main_stdio_eio] swallows [Eio.Cancel.Cancelled] without a counter
   or a log line.

   The write survives anyway, because [with_persist_lock] holds its mutex with
   [~protect:true] and that covers the whole persist body. Nothing in
   [flush_dirty] itself says so, and the guarantee disappears the moment that
   flag does, which is what this test is for. See masc#30619. *)
let test_flush_under_cancellation_still_writes () =
  let voter = "vote-log-cancel-voter" in
  let post =
    create_post_exn ~author:"vote-log-cancel-author" ~content:"vote log cancel body"
  in
  let post_id = Board.Post_id.to_string post.id in
  let store = Board_dispatch.backend () in
  (match Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id ~direction:Board.Up with
   | Ok _ -> ()
   | Error e -> Alcotest.fail ("vote must succeed: " ^ Board.show_board_error e));
  Alcotest.(check bool) "the vote marked the post dirty" true store.Board.dirty_posts;
  (try
     Eio.Cancel.sub (fun cc ->
       Eio.Cancel.cancel cc (Failure "flush_cancelled_for_test");
       Board.flush_dirty store)
   with
   | Eio.Cancel.Cancelled _ ->
     Alcotest.fail
       "the flush was cut by cancellation; its snapshot is gone and the dirty \
        flags were already cleared");
  Alcotest.(check bool)
    "the flush completed, so nothing stayed scheduled"
    false
    store.Board.dirty_posts;
  let rows = read_ts_rows (Board_votes.vote_log_path (Board.global ())) in
  Alcotest.(check bool)
    "the vote reached the log despite the cancellation"
    true
    (find_row ~target:("post:" ^ post_id ^ ":" ^ voter) ~voter rows <> None)
;;

let test_flush_writes_only_changed_primary_table () =
  let post = create_post_exn ~author:"selective-author" ~content:"selective post" in
  let post_id = Board.Post_id.to_string post.id in
  let comment = add_comment_exn ~post_id ~author:"selective-commenter"
      ~content:"selective comment" in
  let comment_id = Board.Comment_id.to_string comment.id in
  let store = Board_dispatch.backend () in
  Board.flush_dirty store;
  let inode path = (Unix.stat path).Unix.st_ino in
  let comments_before = inode (Board.comments_path (Board.global ())) in
  (match Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter:"selective-post-voter" ~post_id
      ~direction:Board.Up with
   | Ok _ -> () | Error e -> Alcotest.fail (Board.show_board_error e));
  Board.flush_dirty store;
  Alcotest.(check int) "post vote leaves comments file untouched"
    comments_before (inode (Board.comments_path (Board.global ())));
  let posts_before = inode (Board.persist_path (Board.global ())) in
  (match Board_dispatch.vote_comment ~reader:Masc_board_handlers.Board_access.Operator ~voter:"selective-comment-voter" ~comment_id
      ~direction:Board.Up with
   | Ok _ -> () | Error e -> Alcotest.fail (Board.show_board_error e));
  Board.flush_dirty store;
  Alcotest.(check int) "comment vote leaves posts file untouched"
    posts_before (inode (Board.persist_path (Board.global ())));
  (* A new comment changes both tables; the narrower flush must keep the
     parent's reply count as well as the child row across restart. *)
  ignore (add_comment_exn ~post_id ~author:"second-commenter" ~content:"second comment");
  Board.flush_dirty store;
  let persisted_post = Fs_compat.load_file (Board.persist_path (Board.global ()))
    |> String.trim |> Yojson.Safe.from_string in
  Alcotest.(check int) "parent count is persisted before loader reconstruction" 2
    Yojson.Safe.Util.(persisted_post |> member "reply_count" |> to_int);
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  (match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok p ->
       Alcotest.(check int) "post vote survives" 1 p.Board.votes_up;
       Alcotest.(check int) "both comments survive" 2 p.Board.reply_count);
  (match Board_dispatch.get_comments ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok comments ->
       match List.find_opt (fun (c : Board.comment) ->
         String.equal (Board.Comment_id.to_string c.id) comment_id) comments with
       | None -> Alcotest.fail "voted comment missing after reload"
       | Some c -> Alcotest.(check int) "comment vote survives" 1 c.Board.votes_up)

let test_flush_failure_keeps_the_vote_log_scheduled () =
  let voter = "vote-log-retry-voter" in
  let post =
    create_post_exn ~author:"vote-log-retry-author" ~content:"vote log retry body"
  in
  let post_id = Board.Post_id.to_string post.id in
  let store = Board_dispatch.backend () in
  (match Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id ~direction:Board.Up with
   | Ok _ -> ()
   | Error e -> Alcotest.fail ("vote must succeed: " ^ Board.show_board_error e));
  Alcotest.(check bool) "the vote marked the post dirty" true store.Board.dirty_posts;
  let vote_log = Board_votes.vote_log_path (Board.global ()) in
  (try Sys.remove vote_log with Sys_error _ -> ());
  Fs_compat.mkdir_p vote_log;
  let before = Board.persist_error_count () in
  Board.flush_dirty store;
  Alcotest.(check bool)
    "the failed vote log write was counted"
    true
    (Board.persist_error_count () > before);
  Alcotest.(check bool)
    "the vote log write is still scheduled after it failed"
    true
    store.Board.dirty_posts
;;

(* A well-formed vote whose post is not loaded survives the restart and the
   next flush. On 2026-09-19 the posts file had been renamed away, the board
   loaded no posts, the loader skipped all 225 votes as targetless, and the
   first flush wrote the empty ledger over the file. *)
let test_restart_keeps_a_vote_whose_post_is_absent () =
  let present =
    create_post_exn ~author:"present-author" ~content:"a post that loads"
  in
  let absent_post_id = "p-0123456789abcdef0123456789abcdef" in
  Fs_compat.save_file
    (Board_votes.vote_log_path (Board.global ()))
    (Yojson.Safe.to_string
       (vote_row
          ~post_id:absent_post_id
          ~voter:"absent-voter"
          ~direction:"up"
          ~ts:(Time_compat.now ()))
     ^ "\n");
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  let store = Board_dispatch.backend () in
  Alcotest.(check int) "the vote is loaded" 1 (Hashtbl.length store.vote_log);
  (* A vote on the loaded post marks it dirty, so the flush rewrites the
     whole ledger from memory. *)
  (match
     Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator
       ~voter:"present-voter"
       ~post_id:(Board.Post_id.to_string present.id)
       ~direction:Board.Up
   with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error));
  Board_votes.flush_dirty store;
  let rows = read_ts_rows (Board_votes.vote_log_path (Board.global ())) in
  Alcotest.(check bool)
    "the vote is still on disk after the flush"
    true
    (Option.is_some
       (find_row
          ~target:("post:" ^ absent_post_id ^ ":absent-voter")
          ~voter:"absent-voter"
          rows))

(* Vote, reaction, and sub-board files are full snapshots. An unreadable row
   cannot be omitted from memory and then erased by the next rewrite. Keep the
   load failures typed, reject mutations of those snapshots, and let unrelated
   post/comment flushes proceed without touching the unreadable vote source. *)
let test_unreadable_snapshots_reject_mutation_and_survive_flush () =
  let post =
    create_post_exn
      ~author:"unreadable-snapshot-author"
      ~content:"the readable post remains independently writable"
  in
  let post_id = Board.Post_id.to_string post.id in
  let unreadable_row = "{not-json}\n" in
  let vote_path = Board_votes.vote_log_path (Board.global ()) in
  let reaction_path = Board.reactions_path (Board.global ()) in
  let sub_board_path = Board.sub_boards_path (Board.global ()) in
  List.iter
    (fun path -> Fs_compat.save_file path unreadable_row)
    [ vote_path; reaction_path; sub_board_path ];
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  let store = Board_dispatch.backend () in
  List.iter
    (fun (label, result) ->
      match result with
      | Error _ -> ()
      | Ok () -> Alcotest.failf "%s load silently accepted an unreadable row" label)
    [ "votes", (Board.current_vote_for_post store ~voter:"blocked-voter" ~post_id
        |> Result.map (fun _ -> ()) |> Result.map_error Board.show_board_error)
    ; "reactions", (Board.list_reactions_batch store ~targets:[] ()
        |> Result.map (fun _ -> ()) |> Result.map_error Board.show_board_error)
    ; "sub-boards", (Board.read_sub_boards store |> Result.map (fun _ -> ())
        |> Result.map_error Board.show_board_error)
    ];
  let reader = Masc_board_handlers.Board_access.Operator in
  let readable_post = Result.get_ok (Board_dispatch.get_post ~reader ~post_id) in
  let current_vote = Server_utils.board_current_vote_for_post ~reader
      ~voter:(Some "blocked-voter") ~post_id in
  (match Server_utils.board_post_dashboard_json ?current_vote ~author_karma:0 readable_post with
   | `Assoc fields ->
     List.iter (fun name -> Alcotest.(check bool)
       ("unavailable votes do not assert " ^ name) false (List.mem_assoc name fields))
       ["current_vote"; "has_voted"]
   | _ -> Alcotest.fail "post JSON must be an object");
  expect_io_error
    "vote"
    (Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter:"blocked-voter" ~post_id ~direction:Board.Up);
  expect_io_error
    "reaction"
    (Board_dispatch.toggle_reaction ~reader:Masc_board_handlers.Board_access.Operator
       ~target_type:Board.Reaction_post
       ~target_id:post_id
       ~user_id:"blocked-reactor"
       ~emoji:"👍");
  expect_io_error
    "sub-board create"
    (Board_dispatch.create_sub_board ~reader:Masc_board_handlers.Board_access.Operator
       ~slug:"blocked-sub-board"
       ~name:"Blocked"
       ~description:"must not replace the unreadable snapshot"
       ~owner:"blocked-owner"
       ());
  ignore
    (add_comment_exn
       ~post_id
       ~author:"independent-commenter"
       ~content:"this flush must not rewrite votes");
  Board.flush_dirty store;
  List.iter
    (fun (label, path) ->
      Alcotest.(check string)
        (label ^ " unreadable row remains byte-for-byte")
        unreadable_row
        (Fs_compat.load_file path))
    [ "vote", vote_path; "reaction", reaction_path; "sub-board", sub_board_path ]
;;

let test_snapshot_waiting_after_edit_keeps_edited_post
    ?(check_reloaded = fun (_ : Board.post) -> ()) prepare_snapshot () =
  let author = "snapshot-order-author" in
  let post = create_post_exn ~author ~content:"before the edit" in
  let post_id = Board.Post_id.to_string post.id in
  let store = Board_dispatch.backend () in
  let write_snapshot = prepare_snapshot store ~post_id in
  Board.with_lock store (fun () -> store.Board.dirty_posts <- true);
  let completed = ref [] in
  Eio.Switch.run (fun sw ->
    Eio.Mutex.use_rw ~protect:true store.persist_mutex (fun () ->
      let enqueue f =
        let started, signal_started = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
          Eio.Promise.resolve signal_started ();
          f ());
        Eio.Promise.await started;
        (* Both paths do only non-yielding work before the held persistence
           mutex. Yield lets this fiber reach that mutex before the next one
           is started; no wall-clock delay chooses the interleaving. *)
        Eio.Fiber.yield ()
      in
      enqueue (fun () ->
        (match
           Board_dispatch.update_post ~post_id ~editor:author
             ~content:"after the edit" ()
         with
         | Ok _ -> ()
         | Error error -> Alcotest.fail (Board.show_board_error error));
        completed := "edit" :: !completed);
      enqueue (fun () ->
        write_snapshot ();
        completed := "snapshot" :: !completed)));
  Alcotest.(check (list string))
    "edit commits before the queued snapshot writer"
    [ "edit"; "snapshot" ] (List.rev !completed);
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok loaded ->
    Alcotest.(check string)
      "restart retains the committed edit"
      "after the edit" loaded.body;
    check_reloaded loaded

let test_vote_survives_snapshot_before_persistence_release
    (kind : Masc_board_handlers.Board_vote_key.target_kind) () =
  let post = create_post_exn ~author:"publication-author" ~content:"vote publication" in
  let post_id = Board.Post_id.to_string post.id in
  let voter = "publication-voter" in
  let cast, query =
    match kind with
    | Masc_board_handlers.Board_vote_key.Post ->
      ( (fun () -> Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter ~post_id ~direction:Board.Up)
      , (fun store -> Board.current_vote_for_post store ~voter ~post_id) )
    | Masc_board_handlers.Board_vote_key.Comment ->
      let comment = add_comment_exn ~post_id ~author:"reply-author" ~content:"reply vote" in
      let comment_id = Board.Comment_id.to_string comment.id in
      ( (fun () -> Board_dispatch.vote_comment ~reader:Masc_board_handlers.Board_access.Operator ~voter ~comment_id ~direction:Board.Up)
      , (fun store -> Board.current_vote_for_comment store ~voter ~comment_id) )
  in
  let store = Board_dispatch.backend () in
  let snapshot_pending = ref true in
  let noop : Board_metrics_hooks.observer =
    { observe_persist_lock_acquire_sec = (fun _ -> ())
    ; observe_persist_lock_held_sec = (fun _ -> ())
    ; inc_dispatch_flusher_start_outcome = (fun () -> ())
    }
  in
  (* The existing completion observer runs as soon as the persistence section
     that did the work is released, before the cast continues.
     Reproduce a competing snapshot from the committed vote identities using
     the actual appended rows and the shared atomic writer. The private vote
     renderer stays private, and no recursive persistence lock is acquired.
     Before the fix the old ledger omits the new append, so this erases it.
     No scheduler or wall-clock delay selects the ordering. *)
  let observer =
    { noop with observe_persist_lock_held_sec = (fun _ ->
        if !snapshot_pending then (
          snapshot_pending := false;
          let path = Board_votes.vote_log_path store in
          let rows = Fs_compat.load_jsonl path in
          let retained = Board.with_lock store (fun () ->
            List.filter (fun row ->
              let target = Yojson.Safe.Util.(row |> member "target" |> to_string) in
              Hashtbl.mem store.Board.vote_log target) rows) in
          let content = retained |> List.map (fun row ->
            Yojson.Safe.to_string row ^ "\n") |> String.concat "" in
          match Fs_compat.save_file_atomic path content with
          | Ok () -> ()
          | Error error -> Alcotest.fail error)) }
  in
  Fun.protect
    ~finally:(fun () -> Board_metrics_hooks.set_observer noop)
    (fun () ->
      Board_metrics_hooks.set_observer observer;
      match cast () with
      | Ok _ -> ()
      | Error error -> Alcotest.fail (Board.show_board_error error));
  Alcotest.(check bool) "the actual snapshot write ran" false !snapshot_pending;
  (* Restart immediately: another flush would repair the old lost row and
     hide the successful-vote durability failure. *)
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  let restored = match query (Board.global ()) with
    | Ok direction -> Option.map Board.vote_direction_to_string direction
    | Error error -> Alcotest.fail (Board.show_board_error error)
  in
  Alcotest.(check (option string))
    "the successfully cast vote survives the intervening snapshot and restart"
    (Some "up") restored

let test_pin_waiting_after_edit_keeps_edited_post () =
  test_snapshot_waiting_after_edit_keeps_edited_post
    ~check_reloaded:(fun loaded ->
      Alcotest.(check bool) "restart also retains the pin" true loaded.pinned)
    (fun store ~post_id () ->
      match Board.set_pinned store ~post_id ~pinned:true with
      | Ok () -> ()
      | Error error -> Alcotest.fail (Board.show_board_error error))
    ()

let test_delete_waiting_after_edit_keeps_other_edited_post () =
  let victim = create_post_exn ~author:"delete-author" ~content:"delete this post" in
  let victim_id = Board.Post_id.to_string victim.id in
  test_snapshot_waiting_after_edit_keeps_edited_post
    (fun store ~post_id:_ () ->
      match Board.delete_post store ~authorization:Board.Operator_deletion ~post_id:victim_id with
      | Ok Board.Durable_deletion -> ()
      | Ok (Board.Deletion_decision_pending detail) -> Alcotest.fail detail
      | Ok (Board.Deletion_persistence_pending detail) -> Alcotest.fail detail
      | Error error -> Alcotest.fail (Board.show_board_error error))
    ();
  match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id:victim_id with
  | Error (Board.Post_not_found _) -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok _ -> Alcotest.fail "deleted post returned after restart"


let test_refused_posts_source_blocks_vote_and_reaction_effects () =
  let post = create_post_exn ~author:"source-author" ~content:"source authority" in
  let post_id = Board.Post_id.to_string post.id in
  let comment = add_comment_exn ~post_id ~author:"comment-author" ~content:"comment" in
  let comment_id = Board.Comment_id.to_string comment.id in
  let store = Board.global () in
  let posts = Board.persist_path store in
  let held = posts ^ ".test-held" in
  let signals = ref 0 in
  let snapshot path =
    if not (Sys.file_exists path) then None else
      let ic = open_in_bin path in
      Some (Fun.protect ~finally:(fun () -> close_in_noerr ic)
        (fun () -> really_input_string ic (in_channel_length ic))) in
  let before_votes = snapshot (Board.vote_log_path store) in
  let before_reactions = snapshot (Board.reactions_path store) in
  Board_dispatch.set_board_signal_hook (fun _ -> incr signals);
  Fun.protect ~finally:(fun () ->
    Board_dispatch.set_board_signal_hook (fun _ -> ());
    if Sys.file_exists held then Unix.rename held posts)
  @@ fun () ->
  Unix.rename posts held;
  (match Masc_board_handlers.Board_votes_json.load_persisted_posts store with
   | Error _ -> () | Ok _ -> Alcotest.fail "missing primary was admitted");
  expect_io_error "post vote" (Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter:"blocked-voter" ~post_id ~direction:Board.Up);
  expect_io_error "comment vote" (Board_dispatch.vote_comment ~reader:Masc_board_handlers.Board_access.Operator ~voter:"blocked-voter" ~comment_id ~direction:Board.Up);
  List.iter (fun (target_type,target_id) ->
    expect_io_error "reaction" (Board_dispatch.toggle_reaction
      ~reader:Masc_board_handlers.Board_access.Operator ~target_type ~target_id
      ~user_id:"blocked-reactor" ~emoji:"👍"))
    [Board.Reaction_post,post_id; Board.Reaction_comment,comment_id];
  Alcotest.(check int) "no signal follows a refused write" 0 !signals;
  Alcotest.(check int) "in-memory votes unchanged" 0 (Hashtbl.length store.vote_log);
  Alcotest.(check bool) "vote ledger bytes unchanged" true
    (before_votes = snapshot (Board.vote_log_path store));
  Alcotest.(check bool) "reaction ledger bytes unchanged" true
    (before_reactions = snapshot (Board.reactions_path store));
  Unix.rename held posts;
  (match Masc_board_handlers.Board_votes_json.load_persisted_posts store with
   | Ok _ -> () | Error (_,error) -> Alcotest.fail (Printexc.to_string error));
  ignore (Result.get_ok (Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter:"blocked-voter" ~post_id ~direction:Board.Up));
  ignore (Result.get_ok (Board_dispatch.vote_comment ~reader:Masc_board_handlers.Board_access.Operator ~voter:"blocked-voter" ~comment_id ~direction:Board.Up));
  ignore (Result.get_ok (Board_dispatch.toggle_reaction
    ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Board.Reaction_post
    ~target_id:post_id ~user_id:"blocked-reactor" ~emoji:"👍"));
  Alcotest.(check int) "same operations work after source recovery" 3 !signals
;;

let () =
  Alcotest.run "board_vote_persistence"
    [
      ( "current contract",
        [
          Alcotest.test_case "flush skips unchanged primary tables" `Quick
            (with_eio test_flush_writes_only_changed_primary_table);
          Alcotest.test_case "flush preserves cast ts" `Quick
            (with_eio test_flush_preserves_cast_ts);
          Alcotest.test_case "flip inherits flip-time" `Quick
            (with_eio test_flip_inherits_flip_time);
          Alcotest.test_case "comment flips and duplicate survive restart" `Quick
            (with_eio test_comment_vote_flips_and_duplicate_survive_restart);
          Alcotest.test_case "restart loads only exact current rows" `Quick
            (with_eio test_restart_loads_only_current_vote_rows);
          Alcotest.test_case "namespaced voter survives snapshot and restart" `Quick
            (with_eio test_namespaced_voter_survives_snapshot_and_restart);
          Alcotest.test_case "last row wins and counters rebuild" `Quick
            (with_eio test_restart_uses_last_vote_row_and_rebuilds_counts);
          Alcotest.test_case "missing ledger resets persisted counters" `Quick
            (with_eio test_missing_ledger_resets_persisted_vote_counts);
        ] );
      ( "durability",
        [
          Alcotest.test_case "post vote survives a snapshot before persistence release" `Quick
            (with_eio (test_vote_survives_snapshot_before_persistence_release
               Masc_board_handlers.Board_vote_key.Post));
          Alcotest.test_case "comment vote survives a snapshot before persistence release" `Quick
            (with_eio (test_vote_survives_snapshot_before_persistence_release
               Masc_board_handlers.Board_vote_key.Comment));
          Alcotest.test_case "refused posts block vote and reaction effects" `Quick
            (with_eio test_refused_posts_source_blocks_vote_and_reaction_effects);
          Alcotest.test_case
            "flush queued after an edit preserves it across restart"
            `Quick
            (with_eio (test_snapshot_waiting_after_edit_keeps_edited_post
               (fun store ~post_id:_ () -> Board.flush_dirty store)));
          Alcotest.test_case
            "pin queued after an edit preserves both across restart"
            `Quick
            (with_eio test_pin_waiting_after_edit_keeps_edited_post);
          Alcotest.test_case
            "delete queued after an edit preserves the other post across restart"
            `Quick
            (with_eio test_delete_waiting_after_edit_keeps_other_edited_post);
          Alcotest.test_case "new vote: failed append leaves nothing committed" `Quick
            (with_eio test_vote_persistence_failure_leaves_nothing_committed);
          Alcotest.test_case
            "flip: failed append leaves the original direction committed"
            `Quick
            (with_eio test_vote_flip_persistence_failure_leaves_original_direction_committed);
          Alcotest.test_case
            "comment vote: failed append leaves nothing committed"
            `Quick
            (with_eio test_vote_comment_persistence_failure_leaves_nothing_committed);
          Alcotest.test_case
            "flush: failed vote log write stays scheduled"
            `Quick
            (with_eio test_flush_failure_keeps_the_vote_log_scheduled);
          Alcotest.test_case
            "flush: cancellation cannot cut the write"
            `Quick
            (with_eio test_flush_under_cancellation_still_writes);
          Alcotest.test_case
            "restart keeps a vote whose post is absent"
            `Quick
            (with_eio test_restart_keeps_a_vote_whose_post_is_absent);
          Alcotest.test_case
            "unreadable snapshots reject mutation and survive flush"
            `Quick
            (with_eio test_unreadable_snapshots_reject_mutation_and_survive_flush);
        ] );
    ]
