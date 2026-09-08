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
  let h = ok (S.store ~dir bytes) in
  assert (String.equal (ok (Result.map_error S.load_error_to_string (S.load ~dir h))) bytes)

(* content-addressed: identical bytes -> identical handle. *)
let test_content_addressed () =
  let dir = temp_dir () in
  let h1 = ok (S.store ~dir "abc") in
  let h2 = ok (S.store ~dir "abc") in
  assert (String.equal (S.to_string h1) (S.to_string h2))

(* Repeated reads preserve the durable inode and mtime, while deletion or
   same-length corruption still requires a repair. No timing/sleep assertion. *)
let test_repeated_store_preserves_and_repairs () =
  let dir = temp_dir () in
  let bytes = "original image" in
  let h = ok (S.store ~dir bytes) in
  let path = Filename.concat dir (S.to_string h) in
  Unix.utimes path 1.0 1.0;
  let before = Unix.stat path in
  for _ = 1 to 100 do
    assert (S.to_string (ok (S.store ~dir bytes)) = S.to_string h)
  done;
  let after = Unix.stat path in
  assert (before.Unix.st_ino = after.Unix.st_ino);
  assert (before.Unix.st_mtime = after.Unix.st_mtime);
  Out_channel.with_open_bin path (fun oc ->
    output_string oc (String.make (String.length bytes) 'x'));
  ignore (ok (S.store ~dir bytes));
  assert (ok (Result.map_error S.load_error_to_string (S.load ~dir h)) = bytes);
  Unix.unlink path;
  ignore (ok (S.store ~dir bytes));
  assert (ok (Result.map_error S.load_error_to_string (S.load ~dir h)) = bytes);
  (* Matching prefix is not an exact image. The bounded reader must detect
     the extra suffix and repair it instead of accepting truncated content. *)
  Out_channel.with_open_bin path (fun oc ->
    output_string oc bytes;
    output_string oc (String.make 1_000_000 'x'));
  ignore (ok (S.store ~dir bytes));
  assert ((Unix.stat path).Unix.st_size = String.length bytes);
  assert (ok (Result.map_error S.load_error_to_string (S.load ~dir h)) = bytes);
  Unix.unlink path;
  Unix.mkfifo path 0o600;
  (* No writer exists: opening this FIFO with a blocking reader would hang.
     The owned regular-file reader rejects it and atomic storage replaces it. *)
  ignore (ok (S.store ~dir bytes));
  assert ((Unix.lstat path).Unix.st_kind = Unix.S_REG);
  assert (ok (Result.map_error S.load_error_to_string (S.load ~dir h)) = bytes);
  Unix.unlink path;
  Unix.mkdir path 0o700;
  match S.store ~dir bytes with
  | Error _ -> ()
  | Ok _ -> assert false

(* distinct bytes -> distinct handles. *)
let test_distinct () =
  let dir = temp_dir () in
  let h1 = ok (S.store ~dir "abc") in
  let h2 = ok (S.store ~dir "abd") in
  assert (not (String.equal (S.to_string h1) (S.to_string h2)))

(* the handle survives a string round-trip (what a checkpoint persists) and the
   reconstructed handle still loads the original bytes. *)
let test_persisted_handle_reload () =
  let dir = temp_dir () in
  let bytes = "durable-across-checkpoint" in
  let h = ok (S.store ~dir bytes) in
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
  let h = ok (S.store ~dir "original") in
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
  ignore (ok (S.store ~dir "seed so dir exists"));
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
  ignore (ok (S.store ~dir "seed"));
  let handle = String.make 64 'b' in
  Unix.mkdir (Filename.concat dir handle) 0o700;
  match S.load ~dir (S.of_string handle) with
  | Error (S.Read_failed _) -> ()
  | Error _ | Ok _ -> assert false

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
  print_endline "test_vision_artifact_store: all assertions passed"
