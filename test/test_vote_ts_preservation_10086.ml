(* test/test_vote_ts_preservation_10086.ml

   #10086: pin that [rewrite_vote_log] persists the original cast
   timestamp instead of stamping [Time_compat.now ()] on every
   flush.  Before the fix, each flush cycle rewrote every row's
   [ts] with the wall clock — downstream analytics (hot ranking,
   recency scoring, audit) were fed fabricated timestamps that
   advanced continuously with flush cadence, not with actual vote
   activity.

   The test:

     1. casts a vote,
     2. observes the row's [ts] in the jsonl log,
     3. forces a [flush_dirty] (rewrite path) after wall time has
        advanced,
     4. asserts that the rewritten row carries the ORIGINAL [ts],
        not the post-flush clock.

   Also covers the flip path (Up → Down on same voter/target) to
   verify that a flip updates the stored ts (inherit flip-time),
   since the record is logically a new cast — the sibling invariant
   from the #10086 fix. *)

open Masc_mcp

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

let create_post_exn ~author ~content =
  match
    Board_dispatch.create_post ~author ~content
      ~post_kind:Board.Human_post ()
  with
  | Ok post -> post
  | Error e -> Alcotest.fail (Board.show_board_error e)

(* Core invariant: flush does NOT advance the ts.  Cast a vote,
   snapshot the jsonl row's ts, force a rewrite, verify the ts
   stayed exactly the same (bitwise, modulo float epsilon). *)
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
  (* Force a fresh "now" by spinning Time_compat past the cast — the
     flush path reads Time_compat.now () when it ignores the stored
     ts; we want the ts in the file to stay at cast_ts, NOT advance. *)
  Unix.sleepf 0.05;
  let before_flush_now = Time_compat.now () in
  Alcotest.(check bool)
    "wall clock advanced past cast" true
    (before_flush_now > cast_ts +. 0.01);
  (* Force rewrite via the dispatch backend's Jsonl store. *)
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

(* A flip (Up → Down on same voter/post) logically re-casts the
   vote, so the stored ts DOES update to flip-time.  This is the
   sibling invariant — flush idempotence covers only the absence of
   a re-cast, not a genuine direction change. *)
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
  (* The append-only log has BOTH rows; the latest entry (last in
     file, since we append) carries the flip-time. *)
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
      (* Flush now and verify the latest-in-store ts matches the
         flip row's ts (and not the original up ts). *)
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

let () =
  Alcotest.run "vote_ts_preservation_10086"
    [
      ( "ts_preservation",
        [
          Alcotest.test_case "flush preserves cast ts" `Quick
            (with_eio test_flush_preserves_cast_ts);
          Alcotest.test_case "flip inherits flip-time" `Quick
            (with_eio test_flip_inherits_flip_time);
        ] );
    ]
