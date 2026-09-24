(* Vision_artifact_store tests — content-addressed durable input store.
   RFC-keeper-vision-delegation-tool §2.5.

   The load-bearing property is round-trip durability: store -> load returns the
   exact bytes. This is precisely what Payload.of_json (Lazy_payload) fails — it
   rebuilds an empty closure — so this store is the durable alternative. *)

module S = Multimodal.Vision_artifact_store

(* Deterministic per-run unique dir (no Random; pid + counter isolates runs). *)
let counter = ref 0

let temp_dir () =
  incr counter;
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "vas_test_%d_%d" (Unix.getpid ()) !counter)

let ok = function
  | Ok v -> v
  | Error e -> failwith e

(* store -> load round-trips arbitrary binary bytes losslessly. *)
let test_round_trip () =
  let dir = temp_dir () in
  let bytes = "\x89PNG\r\n\x1a\n\x00\xffbinary\x00\x00bytes\xfe" in
  let h = ok (S.store ~auto_prune:false ~dir bytes) in
  assert (String.equal (ok (Result.map_error S.load_error_to_string (S.load ~dir h))) bytes)

(* content-addressed: identical bytes -> identical handle. *)
let test_content_addressed () =
  let dir = temp_dir () in
  let h1 = ok (S.store ~auto_prune:false ~dir "abc") in
  let h2 = ok (S.store ~auto_prune:false ~dir "abc") in
  assert (String.equal (S.to_string h1) (S.to_string h2))

(* Repeated reads preserve the durable inode and mtime, while deletion or
   same-length corruption still requires a repair. No timing/sleep assertion. *)
let test_repeated_store_preserves_and_repairs () =
  let dir = temp_dir () in
  let bytes = "original image" in
  let h = ok (S.store ~auto_prune:false ~dir bytes) in
  let path = Filename.concat dir (S.to_string h) in
  Unix.utimes path 1.0 1.0;
  let before = Unix.stat path in
  for _ = 1 to 100 do
    assert (S.to_string (ok (S.store ~auto_prune:false ~dir bytes)) = S.to_string h)
  done;
  let after = Unix.stat path in
  (* Same inode = no rewrite. mtime advances: a re-store is a fresh use,
     and retention evicts by mtime. *)
  assert (before.Unix.st_ino = after.Unix.st_ino);
  assert (after.Unix.st_mtime > before.Unix.st_mtime);
  Out_channel.with_open_bin path (fun oc ->
    output_string oc (String.make (String.length bytes) 'x'));
  ignore (ok (S.store ~auto_prune:false ~dir bytes));
  assert (ok (Result.map_error S.load_error_to_string (S.load ~dir h)) = bytes);
  Unix.unlink path;
  ignore (ok (S.store ~auto_prune:false ~dir bytes));
  assert (ok (Result.map_error S.load_error_to_string (S.load ~dir h)) = bytes);
  (* Matching prefix is not an exact image. The bounded reader must detect
     the extra suffix and repair it instead of accepting truncated content. *)
  Out_channel.with_open_bin path (fun oc ->
    output_string oc bytes;
    output_string oc (String.make 1_000_000 'x'));
  ignore (ok (S.store ~auto_prune:false ~dir bytes));
  assert ((Unix.stat path).Unix.st_size = String.length bytes);
  assert (ok (Result.map_error S.load_error_to_string (S.load ~dir h)) = bytes);
  Unix.unlink path;
  Unix.mkfifo path 0o600;
  (* No writer exists: opening this FIFO with a blocking reader would hang.
     The owned regular-file reader rejects it and atomic storage replaces it. *)
  ignore (ok (S.store ~auto_prune:false ~dir bytes));
  assert ((Unix.lstat path).Unix.st_kind = Unix.S_REG);
  assert (ok (Result.map_error S.load_error_to_string (S.load ~dir h)) = bytes);
  Unix.unlink path;
  Unix.mkdir path 0o700;
  match S.store ~auto_prune:false ~dir bytes with
  | Error _ -> ()
  | Ok _ -> assert false

(* distinct bytes -> distinct handles. *)
let test_distinct () =
  let dir = temp_dir () in
  let h1 = ok (S.store ~auto_prune:false ~dir "abc") in
  let h2 = ok (S.store ~auto_prune:false ~dir "abd") in
  assert (not (String.equal (S.to_string h1) (S.to_string h2)))

(* the handle survives a string round-trip (what a checkpoint persists) and the
   reconstructed handle still loads the original bytes. *)
let test_persisted_handle_reload () =
  let dir = temp_dir () in
  let bytes = "durable-across-checkpoint" in
  let h = ok (S.store ~auto_prune:false ~dir bytes) in
  let persisted = S.to_string h in
  let rewrapped = S.of_string persisted in
  assert (String.equal (ok (Result.map_error S.load_error_to_string (S.load ~dir rewrapped))) bytes)

(* an unknown handle is a typed Error, not a crash or empty success. *)
let test_missing_is_error () =
  let dir = temp_dir () in
  let bogus = S.of_string (String.make 64 'a') in
  match S.load ~dir bogus with
  | Error (S.Missing_artifact _) -> ()
  | Error _ -> assert false
  | Ok _ -> assert false

(* a tampered file (bytes no longer hash to the handle) is rejected on read. *)
let test_corruption_detected () =
  let dir = temp_dir () in
  let h = ok (S.store ~auto_prune:false ~dir "original") in
  let path = Filename.concat dir (S.to_string h) in
  let oc = open_out_bin path in
  output_string oc "tampered-content";
  close_out oc;
  match S.load ~dir h with
  | Error (S.Hash_mismatch _) -> ()
  | Error _ -> assert false
  | Ok _ -> assert false

(* a malformed handle (path-traversal, non-hex, wrong length, uppercase) is
   rejected by the SHAPE guard before any filesystem access — fail closed, no
   read outside [dir]. Asserting the error is specifically [Malformed_handle]
   (not just any Error) pins the guard: with [is_canonical] removed, a traversal
   handle falls through to a not-found / hash-mismatch error instead, and this
   test goes red. The dir is seeded so a non-guarded load would actually reach
   the filesystem. *)
let test_malformed_handle_rejected () =
  let dir = temp_dir () in
  ignore (ok (S.store ~auto_prune:false ~dir "seed so dir exists"));
  List.iter
    (fun bad ->
      match S.load ~dir (S.of_string bad) with
      | Error (S.Malformed_handle _) -> ()
      | Error _ -> assert false
      | Ok _ -> assert false)
    [ "../../etc/passwd";
      "/etc/passwd";
      "a/b";
      "not-hex-string";
      "";
      String.make 63 'a';
      (* one short *)
      String.make 65 'a';
      (* one long *)
      String.make 64 'A' (* uppercase: not canonical *) ]

let test_unreadable_is_not_missing () =
  let dir = temp_dir () in
  ignore (ok (S.store ~auto_prune:false ~dir "seed"));
  let handle = String.make 64 'b' in
  Unix.mkdir (Filename.concat dir handle) 0o700;
  match S.load ~dir (S.of_string handle) with
  | Error (S.Read_failed _) -> ()
  | Error _ | Ok _ -> assert false

(* Bounded retention and rotation tests *)

let test_prune_by_max_entries () =
  let dir = temp_dir () in
  let handles = ref [] in
  for i = 1 to 6 do
    let bytes = Printf.sprintf "frame_data_%d" i in
    let h = ok (S.store ~auto_prune:false ~dir bytes) in
    let path = Filename.concat dir (S.to_string h) in
    let t = float_of_int (i * 100) in
    Unix.utimes path t t;
    handles := (h, bytes, String.length bytes) :: !handles
  done;
  let all_rev = List.rev !handles in
  let res = ok (S.prune ~max_entries:3 ~max_bytes:(1024 * 1024) ~dir ()) in
  assert (res.S.deleted_count = 3);
  assert (res.S.remaining_count = 3);
  (* Oldest 3 (i=1, 2, 3) must be deleted *)
  List.iteri (fun idx (h, _bytes, _len) ->
    let loaded = S.load ~dir h in
    if idx < 3 then
      match loaded with
      | Error (S.Missing_artifact _) -> ()
      | _ -> assert false
    else
      match loaded with
      | Ok b -> assert (String.equal b _bytes)
      | Error _ -> assert false
  ) all_rev

let test_prune_by_max_bytes () =
  let dir = temp_dir () in
  let handles = ref [] in
  (* 4 frames with sizes 100, 200, 300, 400 = total 1000 bytes *)
  for i = 1 to 4 do
    let bytes = String.make (i * 100) (Char.chr (64 + i)) in
    let h = ok (S.store ~auto_prune:false ~dir bytes) in
    let path = Filename.concat dir (S.to_string h) in
    let t = float_of_int (i * 100) in
    Unix.utimes path t t;
    handles := (h, bytes, String.length bytes) :: !handles
  done;
  (* Target 500 bytes: 400 (i=4) fits, 400+300=700 > 500 so i=1, 2, 3 deleted, reclaimed = 600 *)
  let res = ok (S.prune ~max_entries:100 ~max_bytes:500 ~dir ()) in
  assert (res.S.deleted_count = 3);
  assert (res.S.reclaimed_bytes = 600);
  assert (res.S.remaining_count = 1);
  assert (res.S.remaining_bytes = 400)

let test_prune_preserves_non_canonical () =
  let dir = temp_dir () in
  let bytes = "keeper screenshot" in
  let h = ok (S.store ~auto_prune:false ~dir bytes) in
  (* Add non-canonical file and directory *)
  let note_path = Filename.concat dir "notes.txt" in
  Out_channel.with_open_text note_path (fun oc -> output_string oc "important note");
  let sub_dir = Filename.concat dir "sub_dir" in
  Unix.mkdir sub_dir 0o700;
  (* Prune with max_entries: 0 should delete canonical artifact but preserve notes.txt and sub_dir *)
  let res = ok (S.prune ~max_entries:0 ~dir ()) in
  assert (res.S.deleted_count = 1);
  assert (Sys.file_exists note_path);
  assert (Sys.file_exists sub_dir);
  match S.load ~dir h with
  | Error (S.Missing_artifact _) -> ()
  | _ -> assert false

let test_auto_prune_on_store () =
  let dir = temp_dir () in
  let h1 = ok (S.store ~auto_prune:true ~max_entries:2 ~dir "frame 1") in
  let p1 = Filename.concat dir (S.to_string h1) in
  Unix.utimes p1 10.0 10.0;
  let h2 = ok (S.store ~auto_prune:true ~max_entries:2 ~dir "frame 2") in
  let p2 = Filename.concat dir (S.to_string h2) in
  Unix.utimes p2 20.0 20.0;
  let h3 = ok (S.store ~auto_prune:true ~max_entries:2 ~dir "frame 3") in
  let p3 = Filename.concat dir (S.to_string h3) in
  Unix.utimes p3 30.0 30.0;
  (* Only 2 newest should remain *)
  match S.load ~dir h1 with
  | Error (S.Missing_artifact _) ->
      assert (Result.is_ok (S.load ~dir h2));
      assert (Result.is_ok (S.load ~dir h3))
  | _ -> assert false

let test_invalid_limits_cannot_return_a_missing_frame () =
  let dir = temp_dir () in
  let frame = "frame that must survive its own store" in
  assert (Result.is_error (S.store ~auto_prune:true ~max_entries:0 ~dir frame));
  assert (Result.is_error (S.store ~auto_prune:true ~max_entries:(-1) ~dir frame));
  assert (Result.is_error (S.store ~auto_prune:true ~max_bytes:1 ~dir frame));
  assert (Result.is_error (S.prune ~max_entries:(-1) ~dir ()));
  assert (not (Sys.file_exists dir))

let test_re_store_refreshes_mtime_against_eviction () =
  let dir = temp_dir () in
  let a_bytes = "frame-A" in
  let b_bytes = "frame-B" in
  let c_bytes = "frame-C" in
  let h_a = ok (S.store ~auto_prune:false ~dir a_bytes) in
  let path_a = Filename.concat dir (S.to_string h_a) in
  Unix.utimes path_a 1000.0 1000.0;
  let h_b = ok (S.store ~auto_prune:false ~dir b_bytes) in
  let path_b = Filename.concat dir (S.to_string h_b) in
  Unix.utimes path_b 2000.0 2000.0;
  (* Re-store A: refreshes mtime to now *)
  ignore (ok (S.store ~auto_prune:false ~dir a_bytes));
  (* Store C: then prune with max_entries: 2. B (mtime 2000) is oldest, so B is evicted; A and C survive *)
  ignore (ok (S.store ~auto_prune:false ~dir c_bytes));
  let res = ok (S.prune ~max_entries:2 ~max_bytes:(10 * 1024 * 1024) ~dir ()) in
  assert (res.S.deleted_count = 1);
  assert (Result.is_ok (S.load ~dir h_a));
  assert (Result.is_error (S.load ~dir h_b))

let test_prune_stops_on_unlink_failure () =
  let dir = temp_dir () in
  let h1 = ok (S.store ~auto_prune:false ~dir "frame 1") in
  let p1 = Filename.concat dir (S.to_string h1) in
  Unix.utimes p1 10.0 10.0;
  let h2 = ok (S.store ~auto_prune:false ~dir "frame 2") in
  let p2 = Filename.concat dir (S.to_string h2) in
  Unix.utimes p2 20.0 20.0;
  let h3 = ok (S.store ~auto_prune:false ~dir "frame 3") in
  let p3 = Filename.concat dir (S.to_string h3) in
  Unix.utimes p3 30.0 30.0;
  (* Make the directory read-only so unlink fails with EACCES.
     Eviction must abort immediately, protecting newer frames h2 and h3! *)
  Unix.chmod dir 0o555;
  Fun.protect
    ~finally:(fun () -> Unix.chmod dir 0o755)
    (fun () ->
      assert (Result.is_error (S.prune ~max_entries:1 ~max_bytes:(10 * 1024 * 1024) ~dir ()));
      assert (Result.is_ok (S.load ~dir h1));
      assert (Result.is_ok (S.load ~dir h2));
      assert (Result.is_ok (S.load ~dir h3)))

let test_load_finds_in_frames_subdir () =
  let dir = temp_dir () in
  let frames_dir = S.frames_dir ~dir in
  let h = ok (S.store ~auto_prune:false ~dir:frames_dir "lane screenshot bytes") in
  match S.load ~dir h with
  | Ok bytes -> assert (bytes = "lane screenshot bytes")
  | Error err -> failwith (S.load_error_to_string err)

let test_load_uses_verified_frame_when_root_is_corrupt () =
  let dir = temp_dir () in
  let bytes = "captured frame" in
  let h = ok (S.store ~auto_prune:false ~dir bytes) in
  let frames_dir = S.frames_dir ~dir in
  assert (S.to_string (ok (S.store ~auto_prune:false ~dir:frames_dir bytes)) = S.to_string h);
  Out_channel.with_open_bin (Filename.concat dir (S.to_string h)) (fun oc ->
    output_string oc "corrupt root");
  match S.load ~dir h with
  | Ok loaded -> assert (String.equal loaded bytes)
  | Error err -> failwith (S.load_error_to_string err)

let () =
  test_round_trip ();
  test_content_addressed ();
  test_repeated_store_preserves_and_repairs ();
  test_distinct ();
  test_persisted_handle_reload ();
  test_missing_is_error ();
  test_unreadable_is_not_missing ();
  test_corruption_detected ();
  test_malformed_handle_rejected ();
  test_prune_by_max_entries ();
  test_prune_by_max_bytes ();
  test_prune_preserves_non_canonical ();
  test_auto_prune_on_store ();
  test_invalid_limits_cannot_return_a_missing_frame ();
  test_re_store_refreshes_mtime_against_eviction ();
  test_prune_stops_on_unlink_failure ();
  test_load_finds_in_frames_subdir ();
  test_load_uses_verified_frame_when_root_is_corrupt ();
  print_endline "test_vision_artifact_store: all assertions passed"
