(* #10086: [rewrite_vote_log] must preserve the original vote
   timestamp, not overwrite with [Time_compat.now ()] on every
   flush.  The prior bug caused every [ts] in [board_votes.jsonl]
   to advance on each flush cycle, destroying the information that
   downstream analytics (vote velocity, recency scoring) depend on. *)

open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()

let setup_base_path () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-10086-vote-ts-%d-%06x"
         (Unix.getpid ()) (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

let read_ts_map path =
  let lines = Fs_compat.load_jsonl path in
  List.filter_map (fun json ->
    match
      Safe_ops.json_string_opt "target" json,
      Safe_ops.json_float_opt "ts" json
    with
    | Some target, Some ts -> Some (target, ts)
    | _ -> None) lines

(** Cast a vote, rewrite, cast a different vote, rewrite again.
    The first vote's [ts] must remain unchanged across the second
    rewrite cycle. *)
let test_ts_stable_across_rewrites () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (setup_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  let post_id =
    match
      Board_dispatch.create_post ~author:"ts-author"
        ~content:"ts preservation test" ~post_kind:Board.Human_post ()
    with
    | Ok p -> Board.Post_id.to_string p.id
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  (match Board_dispatch.vote
           ~voter:"ts-voter-1" ~post_id ~direction:Board.Up with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  Board_dispatch.flush ();
  let path = Board.vote_log_path () in
  let ts1_map = read_ts_map path in
  let target_key = "post:" ^ post_id ^ ":ts-voter-1" in
  let ts1 =
    match List.assoc_opt target_key ts1_map with
    | Some ts -> ts
    | None -> Alcotest.failf "expected target %S in ledger" target_key
  in
  (* Add a second vote from a different voter and rewrite again. *)
  Unix.sleep 1;  (* ensure wall-clock advances so a bug would be detectable *)
  (match Board_dispatch.vote
           ~voter:"ts-voter-2" ~post_id ~direction:Board.Up with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  Board_dispatch.flush ();
  let ts2_map = read_ts_map path in
  let ts1_after =
    match List.assoc_opt target_key ts2_map with
    | Some ts -> ts
    | None -> Alcotest.failf "target %S disappeared after rewrite" target_key
  in
  Alcotest.(check (float 1e-9))
    "first vote ts unchanged across rewrite"
    ts1 ts1_after

(** Legacy rows lacking [ts] get a stable load-time fallback — not a
    fresh-per-rewrite [now ()].  Verifies the fallback is captured
    once at load, then preserved like any other [ts]. *)
let test_ts_fallback_stable_for_legacy_rows () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = setup_base_path () in
  Fs_compat.mkdir_p (Filename.concat dir ".masc");
  let path = Filename.concat dir ".masc/board_votes.jsonl" in
  (* Legacy row: no [ts] field. *)
  Fs_compat.append_file path
    "{\"target\":\"post:p-legacy:legacy-voter\",\
      \"voter\":\"legacy-voter\",\"direction\":\"up\"}\n";
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  Board_dispatch.flush ();
  let map1 = read_ts_map path in
  let ts_legacy =
    match List.assoc_opt "post:p-legacy:legacy-voter" map1 with
    | Some ts -> ts
    | None -> Alcotest.fail "legacy row dropped at load"
  in
  Alcotest.(check bool) "legacy got a fallback ts" true (ts_legacy > 0.);
  (* Second flush must not re-stamp the legacy row. *)
  Unix.sleep 1;
  Board_dispatch.flush ();
  let map2 = read_ts_map path in
  let ts_after =
    match List.assoc_opt "post:p-legacy:legacy-voter" map2 with
    | Some ts -> ts
    | None -> Alcotest.fail "legacy row dropped after rewrite"
  in
  Alcotest.(check (float 1e-9))
    "legacy fallback ts stable across rewrite"
    ts_legacy ts_after

let () =
  Random.self_init ();
  Alcotest.run "board_vote_ts_preservation" [
    "rewrite", [
      Alcotest.test_case "ts stable across rewrites" `Slow
        test_ts_stable_across_rewrites;
      Alcotest.test_case "legacy fallback ts stable" `Slow
        test_ts_fallback_stable_for_legacy_rows;
    ];
  ]
