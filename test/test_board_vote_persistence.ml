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
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

let with_eio f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (fresh_test_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
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
  | Error e -> Alcotest.fail (Board.show_board_error e)

let add_comment_exn ~post_id ~author ~content =
  match Board_dispatch.add_comment ~post_id ~author ~content () with
  | Ok comment -> comment
  | Error e -> Alcotest.fail (Board.show_board_error e)

let test_flush_preserves_cast_ts () =
  let voter = "ts-preserve-voter" in
  let post =
    create_post_exn ~author:"ts-preserve-author"
      ~content:"preserve my timestamp"
  in
  let pid = Board.Post_id.to_string post.id in
  let target = "post:" ^ pid ^ ":" ^ voter in
  (match Board_dispatch.vote ~voter ~post_id:pid ~direction:Board.Up with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  let append_rows = read_ts_rows (Board_votes.vote_log_path ()) in
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
  (match Board_dispatch.backend () with
   | Board_dispatch.Jsonl store -> Board.flush_dirty store);
  let rewrite_rows = read_ts_rows (Board_votes.vote_log_path ()) in
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
  (match Board_dispatch.vote ~voter ~post_id:pid ~direction:Board.Up with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  let up_rows = read_ts_rows (Board_votes.vote_log_path ()) in
  let up_ts =
    match find_row ~target ~voter up_rows with
    | Some (_, _, ts) -> ts
    | None -> Alcotest.fail "jsonl missing up row"
  in
  Unix.sleepf 0.05;
  (match Board_dispatch.vote ~voter ~post_id:pid ~direction:Board.Down with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  let flip_rows = read_ts_rows (Board_votes.vote_log_path ()) in
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
      (match Board_dispatch.backend () with
       | Board_dispatch.Jsonl store -> Board.flush_dirty store);
      let rewrite_rows = read_ts_rows (Board_votes.vote_log_path ()) in
      let rewritten_ts =
        match find_row ~target ~voter rewrite_rows with
        | Some (_, _, ts) -> ts
        | None -> Alcotest.fail "rewrite jsonl missing flipped row"
      in
      Alcotest.(check (float 1e-9))
        "rewrite persists flip-time (not original up ts, not now)"
        flip_ts rewritten_ts

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
    (Board_votes.vote_log_path ())
    (String.concat
       ""
       (List.map
          (fun json -> Yojson.Safe.to_string json ^ "\n")
          (canonical :: rejected_rows)));
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  let store =
    match Board_dispatch.backend () with
    | Board_dispatch.Jsonl store -> store
  in
  Alcotest.(check int)
    "only one exact current row loaded"
    1
    (Hashtbl.length store.vote_log);
  match
    Board_dispatch.current_vote_for_post
      ~voter:"current-voter"
      ~post_id
  with
  | Ok (Some Board.Up) -> ()
  | Ok (Some Board.Down) -> Alcotest.fail "canonical vote direction changed"
  | Ok None -> Alcotest.fail "canonical current vote row was not loaded"
  | Error error -> Alcotest.fail (Board.show_board_error error)

let test_namespaced_voter_survives_snapshot_and_restart () =
  let voter = "keeper:foo" in
  let post =
    create_post_exn
      ~author:"namespaced-voter-author"
      ~content:"namespaced voter snapshot"
  in
  let post_id = Board.Post_id.to_string post.id in
  let target = "post:" ^ post_id ^ ":" ^ voter in
  (match Board_dispatch.vote ~voter ~post_id ~direction:Board.Up with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error));
  (match Board_dispatch.backend () with
   | Board_dispatch.Jsonl store -> Board.flush_dirty store);
  let rows = read_ts_rows (Board_votes.vote_log_path ()) in
  Alcotest.(check bool)
    "snapshot keeps the complete namespaced voter"
    true
    (Option.is_some (find_row ~target ~voter rows));
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  (match Board_dispatch.current_vote_for_post ~voter ~post_id with
   | Ok (Some Board.Up) -> ()
   | Ok (Some Board.Down) -> Alcotest.fail "snapshot changed vote direction"
   | Ok None -> Alcotest.fail "snapshot lost namespaced voter"
   | Error error -> Alcotest.fail (Board.show_board_error error));
  match Board_dispatch.get_post ~post_id with
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
    (Board_votes.vote_log_path ())
    (String.concat
       ""
       (List.map (fun json -> Yojson.Safe.to_string json ^ "\n") rows));
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  (match
     Board_dispatch.current_vote_for_post
       ~voter:"flip-voter"
       ~post_id
   with
   | Ok (Some Board.Down) -> ()
   | Ok (Some Board.Up) -> Alcotest.fail "first row incorrectly won"
   | Ok None -> Alcotest.fail "last vote row was not loaded"
   | Error error -> Alcotest.fail (Board.show_board_error error));
  (match Board_dispatch.get_post ~post_id with
   | Error error -> Alcotest.fail (Board.show_board_error error)
   | Ok loaded ->
     Alcotest.(check int) "post votes_up rebuilt from ledger" 0 loaded.votes_up;
     Alcotest.(check int) "post votes_down rebuilt from ledger" 1 loaded.votes_down);
  match Board_dispatch.get_comments ~post_id with
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
     Board_dispatch.vote
       ~voter:"missing-ledger-voter"
       ~post_id
       ~direction:Board.Up
   with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error));
  (match Board_dispatch.backend () with
   | Board_dispatch.Jsonl store -> Board.flush_dirty store);
  Unix.unlink (Board_votes.vote_log_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  match Board_dispatch.get_post ~post_id with
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok loaded ->
    Alcotest.(check int) "missing ledger clears votes_up" 0 loaded.votes_up;
    Alcotest.(check int) "missing ledger clears votes_down" 0 loaded.votes_down

let () =
  Alcotest.run "board_vote_persistence"
    [
      ( "current contract",
        [
          Alcotest.test_case "flush preserves cast ts" `Quick
            (with_eio test_flush_preserves_cast_ts);
          Alcotest.test_case "flip inherits flip-time" `Quick
            (with_eio test_flip_inherits_flip_time);
          Alcotest.test_case "restart loads only exact current rows" `Quick
            (with_eio test_restart_loads_only_current_vote_rows);
          Alcotest.test_case "namespaced voter survives snapshot and restart" `Quick
            (with_eio test_namespaced_voter_survives_snapshot_and_restart);
          Alcotest.test_case "last row wins and counters rebuild" `Quick
            (with_eio test_restart_uses_last_vote_row_and_rebuilds_counts);
          Alcotest.test_case "missing ledger resets persisted counters" `Quick
            (with_eio test_missing_ledger_resets_persisted_vote_counts);
        ] );
    ]
