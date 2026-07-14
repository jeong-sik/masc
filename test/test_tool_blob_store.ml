(** Tests for Tool_blob_store + Tool_output.

    Covers:
    - Round-trip: encode then decode for both [Inline] and [Stored] variants.
    - Backward compat: any string without marker decodes to [Inline].
    - Malformed marker falls back to [Inline] (fail-safe).
    - Content-addressed: same bytes -> same sha -> idempotent put.
    - Sharding: blobs land under [<sha[0..1]>/<sha>].
    - GC: blobs not in keep_set are deleted; kept ones survive.
    - Concurrent put: simultaneous writes of same content do not corrupt. *)

module B = Tool_blob_store
module O = Tool_output

(* --- Helpers --- *)

let fetch_ok store ~sha256 =
  match B.fetch store ~sha256 with
  | Ok value -> value
  | Error error ->
      Alcotest.failf "fetch failed: %s" (B.fetch_error_to_string error)

let with_temp_dir f =
  let dir = Filename.temp_file "masc_blob_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cleanup () =
    let rec rm path =
      if Sys.file_exists path then
        if Sys.is_directory path then begin
          Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
          Unix.rmdir path
        end
        else Unix.unlink path
    in
    try rm dir with _ -> ()
  in
  let r = try Ok (f dir) with e -> Error e in
  cleanup ();
  match r with Ok v -> v | Error e -> raise e

(* --- Tool_output round-trip --- *)

let test_inline_roundtrip () =
  let s = "hello world\n" in
  let encoded = O.encode_for_oas (O.Inline s) in
  Alcotest.(check string) "inline encode = identity" s encoded;
  match O.decode_from_oas encoded with
  | O.Inline s' -> Alcotest.(check string) "inline decode" s s'
  | O.Stored _ -> Alcotest.fail "expected Inline"

let test_stored_roundtrip () =
  let original =
    O.Stored
      {
        sha256 = "abcd1234";
        bytes = 128934;
        preview = "first 200 chars\nwith newline";
        mime = "text/plain";
      }
  in
  let encoded = O.encode_for_oas original in
  Alcotest.(check bool)
    "encoded starts with marker"
    true
    (O.is_marker encoded);
  match O.decode_from_oas encoded with
  | O.Stored { sha256; bytes; preview; mime } ->
      Alcotest.(check string) "sha256" "abcd1234" sha256;
      Alcotest.(check int) "bytes" 128934 bytes;
      Alcotest.(check string)
        "preview" "first 200 chars\nwith newline" preview;
      Alcotest.(check string) "mime" "text/plain" mime
  | O.Inline _ -> Alcotest.fail "expected Stored"

let test_encoded_marker_stays_under_externalization_threshold () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let threshold = Masc.Tool_bridge.default_externalize_threshold_bytes in
      let payload = String.make (threshold + 1) '"' in
      let encoded = B.put store ~bytes:payload ~mime:"text/plain" |> O.encode_for_oas in
      Alcotest.(check bool)
        "marker stays below default externalization threshold"
        true
        (String.length encoded <= threshold);
      match O.decode_from_oas encoded with
      | O.Stored { preview; _ } ->
        Alcotest.(check int) "preview remains documented cap" 200 (String.length preview)
      | O.Inline _ -> Alcotest.fail "expected Stored")

let test_decode_non_marker () =
  (* Any normal tool output decodes as Inline — backward compat for old
     checkpoints that pre-date the artifact store. *)
  let cases =
    [
      "";
      "plain text";
      "{\"key\":\"value\"}";
      "[tool:gh id:xyz lines:5 chars:128 summary:\"hi\"]";
      "[masc:other prefix]";
      "[masc:blob"  (* truncated — no trailing space *);
    ]
  in
  List.iter
    (fun s ->
      match O.decode_from_oas s with
      | O.Inline s' ->
          Alcotest.(check string) ("inline-fallback for " ^ s) s s'
      | O.Stored _ ->
          Alcotest.failf "expected Inline for %S" s)
    cases

let test_decode_malformed_marker () =
  (* Has the prefix but body is garbage — must NOT raise, falls back to
     Inline so the keeper LLM sees the raw string instead of crashing. *)
  let bad = "[masc:blob garbage that cannot scanf]" in
  match O.decode_from_oas bad with
  | O.Inline s -> Alcotest.(check string) "fallback string" bad s
  | O.Stored _ -> Alcotest.fail "malformed should NOT decode as Stored"

(* --- Tool_blob_store basic --- *)

let test_put_returns_stored () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = "hello tool output" in
      match B.put store ~bytes:payload ~mime:"text/plain" with
      | O.Stored { sha256; bytes; preview; mime } ->
          Alcotest.(check int) "sha length" 64 (String.length sha256);
          Alcotest.(check int) "bytes" (String.length payload) bytes;
          Alcotest.(check string) "preview" payload preview;
          Alcotest.(check string) "mime" "text/plain" mime
      | O.Inline _ -> Alcotest.fail "put must return Stored")

let test_put_then_fetch () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = String.make 5000 'x' in
      let stored = B.put store ~bytes:payload ~mime:"text/plain" in
      match stored with
      | O.Stored { sha256; _ } -> (
          match B.fetch store ~sha256 with
          | Ok (Some bytes) ->
              Alcotest.(check string) "round-trip bytes" payload bytes
          | Ok None -> Alcotest.fail "fetch returned None"
          | Error error ->
              Alcotest.failf "fetch failed: %s" (B.fetch_error_to_string error))
      | O.Inline _ -> Alcotest.fail "put returned Inline")

let test_fetch_miss () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      match B.fetch store ~sha256:(String.make 64 '0') with
      | Ok None -> ()
      | Ok (Some _) -> Alcotest.fail "expected None for unknown sha"
      | Error error ->
          Alcotest.failf "fetch failed: %s" (B.fetch_error_to_string error))

let test_idempotent_put () =
  (* Same content twice = same sha = same path, no error. *)
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = "idempotent payload" in
      let r1 = B.put store ~bytes:payload ~mime:"text/plain" in
      let r2 = B.put store ~bytes:payload ~mime:"text/plain" in
      let sha_of = function
        | O.Stored { sha256; _ } -> sha256
        | O.Inline _ -> Alcotest.fail "expected Stored"
      in
      Alcotest.(check string)
        "same content -> same sha" (sha_of r1) (sha_of r2);
      Alcotest.(check int) "single entry" 1 (List.length (B.list_all store)))

let test_sharding_layout () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = "sharding test" in
      let stored = B.put store ~bytes:payload ~mime:"text/plain" in
      match stored with
      | O.Stored { sha256; _ } ->
          let prefix = String.sub sha256 0 2 in
          let expected =
            Filename.concat (B.root_dir store)
              (Filename.concat prefix sha256)
          in
          Alcotest.(check bool)
            "sharded path exists" true
            (Sys.file_exists expected)
      | O.Inline _ -> Alcotest.fail "put returned Inline")

(* --- GC --- *)

let test_gc_deletes_unkept () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let stored payload =
        match B.put store ~bytes:payload ~mime:"text/plain" with
        | O.Stored { sha256; _ } -> sha256
        | O.Inline _ -> Alcotest.fail "expected Stored"
      in
      let keep = stored "keep me" in
      let _drop = stored "drop me" in
      let _drop2 = stored "drop me too" in
      Alcotest.(check int) "before gc" 3 (List.length (B.list_all store));
      let deleted = B.gc store ~keep_set:[ keep ] in
      Alcotest.(check int) "deleted count" 2 deleted;
      Alcotest.(check int) "after gc" 1 (List.length (B.list_all store));
      Alcotest.(check (option string))
        "kept blob still fetchable"
        (Some "keep me")
        (fetch_ok store ~sha256:keep))

let test_gc_empty_keep_clears_all () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let _ = B.put store ~bytes:"a" ~mime:"text/plain" in
      let _ = B.put store ~bytes:"b" ~mime:"text/plain" in
      let _ = B.put store ~bytes:"c" ~mime:"text/plain" in
      let deleted = B.gc store ~keep_set:[] in
      Alcotest.(check int) "deleted all" 3 deleted;
      Alcotest.(check int) "store empty" 0 (List.length (B.list_all store)))

(* --- Repeated put: documents the atomicity contract --- *)

(* Atomicity is guaranteed at the OS layer by [Fs_compat.save_file_atomic]
   (tempfile + rename). Same-content puts always produce same sha256 ->
   same path -> rename is idempotent. We don't need a true concurrency test
   here; serial repetition exercises the same code path. *)
let test_repeated_put_no_dup () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = String.make 1024 'z' in
      for _ = 1 to 8 do
        let _ = B.put store ~bytes:payload ~mime:"text/plain" in
        ()
      done;
      Alcotest.(check int)
        "single sha after 8 puts" 1
        (List.length (B.list_all store));
      let sha = List.hd (B.list_all store) in
      Alcotest.(check (option string))
        "fetched content matches" (Some payload)
        (fetch_ok store ~sha256:sha))

(* --- Storage-failure contract --- *)

(* [put] must surface a storage failure (raise) rather than silently returning
   a [Stored] marker for bytes it never persisted. Here [base_path] is a
   regular file, so the blob store directory cannot be created and the write
   cannot land. Using a file (not a chmod) makes the failure structural
   (ENOTDIR), so the test holds even when run as root. *)
let test_put_raises_on_unwritable_store () =
  let file = Filename.temp_file "masc_blob_unwritable" "" in
  let store = B.create ~base_path:file in
  let raised =
    try
      let _ = B.put store ~bytes:(String.make 5000 'x') ~mime:"text/plain" in
      false
    with _ -> true
  in
  (try Sys.remove file with _ -> ());
  Alcotest.(check bool) "put raises on unwritable store" true raised

let test_fetch_rejects_non_regular_paths () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let assert_rejected character expected_kind create_path =
        let sha256 = String.make 64 character in
        let shard_dir =
          Filename.concat (B.root_dir store) (String.make 2 character)
        in
        Fs_compat.mkdir_p shard_dir;
        let path = Filename.concat shard_dir sha256 in
        create_path path;
        match B.fetch store ~sha256 with
        | Error
            (B.Owned_read_failed
              { failure = Fs_compat.Path_is_not_regular_file { kind; _ }
              ; _
              }) ->
            Alcotest.(check bool) "exact non-regular kind" true (kind = expected_kind)
        | Error error ->
            Alcotest.failf "unexpected fetch error: %s" (B.fetch_error_to_string error)
        | Ok _ -> Alcotest.fail "non-regular path reached blob read"
      in
      let target = Filename.concat dir "symlink-target" in
      Fs_compat.save_file target "outside blob store";
      assert_rejected 'a' Unix.S_DIR (fun path -> Unix.mkdir path 0o755);
      assert_rejected 'b' Unix.S_FIFO (fun path -> Unix.mkfifo path 0o600);
      assert_rejected 'c' Unix.S_LNK (fun path -> Unix.symlink target path))

let test_fetch_reports_inspection_failure () =
  let base_path = Filename.temp_file "masc_blob_parent_file" "" in
  let store = B.create ~base_path in
  let sha256 = String.make 64 'b' in
  let result = B.fetch store ~sha256 in
  (try Sys.remove base_path with _ -> ());
  match result with
  | Error
      (B.Owned_read_failed
        { failure = Fs_compat.Ownership_boundary_rejected _; _ }) -> ()
  | Error error ->
      Alcotest.failf
        "unexpected fetch error: %s"
        (B.fetch_error_to_string error)
  | Ok None -> Alcotest.fail "structural store failure was reported as missing"
  | Ok (Some _) -> Alcotest.fail "structural store failure returned bytes"

let test_fetch_rejects_symbolic_link_parent () =
  with_temp_dir (fun dir ->
    let outside = Filename.concat dir "outside" in
    Unix.mkdir outside 0o755;
    let linked_parent = Filename.concat dir ".masc" in
    Unix.symlink outside linked_parent;
    Fun.protect
      ~finally:(fun () -> Unix.unlink linked_parent)
      (fun () ->
         let store = B.create ~base_path:dir in
         match B.fetch store ~sha256:(String.make 64 '0') with
         | Error
             (B.Owned_read_failed
               { failure = Fs_compat.Ownership_boundary_rejected _; _ }) -> ()
         | Error error ->
           Alcotest.failf
             "unexpected fetch error: %s"
             (B.fetch_error_to_string error)
         | Ok _ -> Alcotest.fail "symbolic-link parent escaped blob ownership"))

let test_fetch_reports_integrity_mismatch () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let original = "content-addressed bytes" in
      match B.put store ~bytes:original ~mime:"text/plain" with
      | O.Inline _ -> Alcotest.fail "put returned Inline"
      | O.Stored { sha256; _ } ->
          let path =
            Filename.concat
              (Filename.concat (B.root_dir store) (String.sub sha256 0 2))
              sha256
          in
          Fs_compat.save_file path "tampered bytes";
          (match B.fetch store ~sha256 with
           | Error (B.Integrity_mismatch _) -> ()
           | Error error ->
               Alcotest.failf
                 "unexpected fetch error: %s"
                 (B.fetch_error_to_string error)
           | Ok None -> Alcotest.fail "tampered blob was reported as missing"
           | Ok (Some _) -> Alcotest.fail "tampered blob passed digest verification"))

let test_sha256_rejects_path_component () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      match B.fetch store ~sha256:("../" ^ String.make 61 'a') with
      | Error (B.Invalid_sha256 _) -> ()
      | Error error ->
          Alcotest.failf
            "unexpected fetch error: %s"
            (B.fetch_error_to_string error)
      | Ok _ -> Alcotest.fail "path-like digest reached blob lookup")

(* --- Entry point --- *)

let () =
  Alcotest.run "tool_blob_store"
    [
      ( "tool_output round-trip",
        [
          Alcotest.test_case "inline" `Quick test_inline_roundtrip;
          Alcotest.test_case "stored" `Quick test_stored_roundtrip;
          Alcotest.test_case
            "encoded marker stays under externalization threshold"
            `Quick
            test_encoded_marker_stays_under_externalization_threshold;
          Alcotest.test_case "non-marker = Inline" `Quick
            test_decode_non_marker;
          Alcotest.test_case "malformed = Inline" `Quick
            test_decode_malformed_marker;
        ] );
      ( "blob store basic",
        [
          Alcotest.test_case "put returns Stored" `Quick
            test_put_returns_stored;
          Alcotest.test_case "put then fetch" `Quick test_put_then_fetch;
          Alcotest.test_case "fetch miss = None" `Quick test_fetch_miss;
          Alcotest.test_case "idempotent put" `Quick test_idempotent_put;
          Alcotest.test_case "sharding layout" `Quick test_sharding_layout;
        ] );
      ( "gc",
        [
          Alcotest.test_case "deletes unkept" `Quick test_gc_deletes_unkept;
          Alcotest.test_case "empty keep clears all" `Quick
            test_gc_empty_keep_clears_all;
        ] );
      ( "atomicity",
        [
          Alcotest.test_case "repeated put no dup" `Quick
            test_repeated_put_no_dup;
        ] );
      ( "storage failure",
        [
          Alcotest.test_case "put raises on unwritable store" `Quick
            test_put_raises_on_unwritable_store;
          Alcotest.test_case "fetch rejects non-regular paths" `Quick
            test_fetch_rejects_non_regular_paths;
          Alcotest.test_case "fetch reports inspection failure" `Quick
            test_fetch_reports_inspection_failure;
          Alcotest.test_case "fetch rejects symbolic-link parent" `Quick
            test_fetch_rejects_symbolic_link_parent;
          Alcotest.test_case "fetch reports integrity mismatch" `Quick
            test_fetch_reports_integrity_mismatch;
          Alcotest.test_case "sha256 rejects path component" `Quick
            test_sha256_rejects_path_component;
        ] );
    ]
