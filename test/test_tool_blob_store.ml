(** Tests for Tool_blob_store + Tool_output.

    Covers:
    - Round-trip: encode then decode a [Stored] reference.
    - Backward compat: any string without marker reports [Not_marker].
    - Malformed marker surfaces as [Invalid_marker] — a visible, typed
      outcome.
    - Content-addressed: same bytes -> same sha -> idempotent put.
    - Sharding: blobs land under [<sha[0..1]>/<sha>].
    - Maintenance: union-scanned live refs survive and stable dead refs are
      deleted only on the second explicit retention pass.
    - Concurrent put: simultaneous writes of same content do not corrupt. *)

module B = Tool_blob_store
module M = Tool_blob_maintenance

(* Maintenance reads each workspace's posts where Board writes them. *)
let board_posts_file = Masc_board_handlers.Board_paths.posts_file
module O = Tool_output

(* --- Helpers --- *)

let ref_exn ~sha256 ~bytes ~preview ~mime =
  match O.make_artifact_ref ~sha256 ~bytes ~preview ~mime with
  | Ok r -> r
  | Error e -> Alcotest.fail (O.make_error_to_string e)

let fetch_ok store ~sha256 =
  match B.fetch store ~sha256 with
  | Ok value -> value
  | Error error ->
      Alcotest.failf "fetch failed: %s" (B.fetch_error_to_string error)

let stored_ref_exn (O.Stored reference) = reference

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

(* A spaced media type used to encode fine and fail at read time with
   "scanf: bad input at char number 109: looking for 'p', found 'c'" -- the
   decoder had stopped mime at the space and met "charset=" where it wanted
   "preview=". The value is rejected where it is built now. *)
let test_spaced_mime_is_refused_at_construction () =
  let sha256 = String.make 64 'b' in
  match
    O.make_artifact_ref ~sha256 ~bytes:12 ~preview:"p"
      ~mime:"text/plain; charset=utf-8"
  with
  | Ok _ ->
      Alcotest.fail "a media type the marker cannot carry was accepted"
  | Error (O.Unencodable_mime mime) ->
      Alcotest.(check string)
        "the offending value is named" "text/plain; charset=utf-8" mime
  | Error other ->
      Alcotest.failf "wrong rejection: %s" (O.make_error_to_string other)

(* The unspaced form every caller now writes must still survive the trip. *)
let test_parameterised_mime_roundtrips_without_a_space () =
  let sha256 = String.make 64 'c' in
  let artifact_ref =
    ref_exn ~sha256 ~bytes:7 ~preview:"body" ~mime:"text/plain;charset=utf-8"
  in
  let encoded = O.encode_for_agent_core (O.Stored artifact_ref) in
  match O.decode_from_agent_core encoded with
  | O.Decoded decoded ->
      Alcotest.(check string)
        "mime survives" "text/plain;charset=utf-8" decoded.O.mime
  | O.Not_marker -> Alcotest.fail "encoded value was not recognised as a marker"
  | O.Invalid_marker { detail } ->
      Alcotest.failf "round trip failed: %s" detail

let test_stored_roundtrip () =
  let sha256 = String.make 64 'a' in
  let artifact_ref =
    ref_exn ~sha256 ~bytes:128934 ~preview:"first 200 chars\nwith newline"
      ~mime:"text/plain"
  in
  let original = O.Stored artifact_ref in
  let encoded = O.encode_for_agent_core original in
  Alcotest.(check bool)
    "encoded starts with marker"
    true
    (O.is_marker encoded);
  match O.decode_from_agent_core encoded with
  | O.Decoded { sha256 = decoded_sha; bytes; preview; mime } ->
      Alcotest.(check string) "sha256" sha256 decoded_sha;
      Alcotest.(check int) "bytes" 128934 bytes;
      Alcotest.(check string)
        "preview" "first 200 chars\nwith newline" preview;
      Alcotest.(check string) "mime" "text/plain" mime
  | O.Not_marker -> Alcotest.fail "expected Decoded"
  | O.Invalid_marker { detail } ->
      Alcotest.failf "expected Decoded, got Invalid_marker: %s" detail

(* The marker is the whole value. Bytes after the closing bracket are a
   malformed marker, not a valid one with a tail to drop. *)
let test_trailing_bytes_after_the_marker_are_rejected () =
  let artifact_ref =
    ref_exn ~sha256:(String.make 64 'c') ~bytes:7 ~preview:"hi"
      ~mime:"text/plain"
  in
  let encoded = O.encode_for_agent_core (O.Stored artifact_ref) in
  match O.decode_from_agent_core (encoded ^ "trailing bytes") with
  | O.Invalid_marker _ -> ()
  | O.Decoded _ -> Alcotest.fail "a marker with trailing bytes must not decode"
  | O.Not_marker -> Alcotest.fail "expected a marker"

let test_normalized_artifact_ref_roundtrip () =
  let reference =
    ref_exn
      ~sha256:(String.make 64 'b')
      ~bytes:4096
      ~mime:"application/json"
      ~preview:"{\"ok\":true}"
  in
  match O.normalized_artifact_ref_of_json (O.normalized_artifact_ref_to_json reference) with
  | O.Decoded_normalized_artifact_ref decoded ->
    Alcotest.(check string) "sha256" reference.sha256 decoded.sha256;
    Alcotest.(check int) "bytes" reference.bytes decoded.bytes;
    Alcotest.(check string) "mime" reference.mime decoded.mime;
    Alcotest.(check string) "preview" reference.preview decoded.preview
  | O.Not_normalized_artifact_ref ->
    Alcotest.fail "expected normalized artifact reference"
  | O.Invalid_normalized_artifact_ref { detail } ->
    Alcotest.failf "normalized artifact reference rejected: %s" detail

let test_encoded_marker_stays_under_externalization_threshold () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let threshold = Masc.Tool_bridge.default_externalize_threshold_bytes in
      let payload = String.make (threshold + 1) '"' in
      let encoded = B.put store ~bytes:payload ~mime:"text/plain" |> O.encode_for_agent_core in
      Alcotest.(check bool)
        "marker stays below default externalization threshold"
        true
        (String.length encoded <= threshold);
      match O.decode_from_agent_core encoded with
      | O.Decoded { preview; _ } ->
        Alcotest.(check int) "preview remains documented cap" 200 (String.length preview)
      | O.Not_marker -> Alcotest.fail "expected Decoded"
      | O.Invalid_marker { detail } ->
          Alcotest.failf "expected Decoded, got Invalid_marker: %s" detail)

let test_decode_non_marker () =
  (* Any normal tool output reports Not_marker — backward compat for old
     checkpoints that pre-date the artifact store. The raw string passes
     through untouched. *)
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
      match O.decode_from_agent_core s with
      | O.Not_marker -> ()
      | O.Decoded _ ->
          Alcotest.failf "expected Not_marker for %S" s
      | O.Invalid_marker _ ->
          Alcotest.failf "expected Not_marker (not Invalid_marker) for %S" s)
    cases

let test_decode_malformed_marker () =
  (* Has the prefix but body is garbage — must NOT raise. A malformed
     marker is a visible, typed [Invalid_marker] outcome; the caller decides
     what to do with the raw text. *)
  let bad_markers =
    [ "[masc:blob sha256=garbage that cannot scanf]"
    ; "[masc:blob sha256=garbage]"
    ]
  in
  List.iter
    (fun bad ->
       match O.decode_from_agent_core bad with
       | O.Invalid_marker { detail } ->
         Alcotest.(check bool)
           "detail explains the failure" true (String.length detail > 0)
       | O.Not_marker ->
         Alcotest.fail "malformed marker must surface as Invalid_marker"
       | O.Decoded _ -> Alcotest.fail "malformed should NOT decode as Stored")
    bad_markers

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
          Alcotest.(check string) "mime" "text/plain" mime)

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
              Alcotest.failf "fetch failed: %s" (B.fetch_error_to_string error)))

let test_fetch_bounded_rejects_large_real_blob () =
  with_temp_dir (fun dir ->
    let store = B.create ~base_path:dir in
    let payload = "bounded blob" in
    let sha256 =
      match B.put store ~bytes:payload ~mime:"application/octet-stream" with
      | O.Stored { sha256; _ } -> sha256
    in
    let maximum = String.length payload - 1 in
    (match B.fetch_bounded store ~sha256 ~max_bytes:maximum with
     | Error (B.Too_large { actual; maximum = reported; _ }) ->
       Alcotest.(check int) "actual size" (String.length payload) actual;
       Alcotest.(check int) "reported limit" maximum reported
     | Error error ->
       Alcotest.failf "wrong bounded error: %s" (B.fetch_error_to_string error)
     | Ok _ -> Alcotest.fail "oversized blob was returned");
    (match B.fetch_bounded store ~sha256 ~max_bytes:(String.length payload) with
     | Ok (Some bytes) -> Alcotest.(check string) "at limit" payload bytes
     | Ok None -> Alcotest.fail "blob disappeared"
     | Error error -> Alcotest.fail (B.fetch_error_to_string error));
    match B.fetch_bounded store ~sha256 ~max_bytes:(-1) with
    | Error (B.Invalid_max_bytes (-1)) -> ()
    | _ -> Alcotest.fail "negative bound was accepted")
;;

let test_binary_previews_are_utf8_without_changing_stored_bytes () =
  with_temp_dir (fun dir ->
    let store = B.create ~base_path:dir in
    let unicode = "한글🙂 café" in
    let payloads =
      [ unicode
      ; String.init 256 Char.chr
      ; "\xc0\xaf\xed\xa0\x80\xff\xe2\x82"
      ; String.make (B.preview_max - 1) 'a' ^ "🙂"
      ; String.make (B.preview_max - String.length "🙂") 'a' ^ "🙂tail"
      ]
    in
    List.iter (fun payload ->
      with_temp_dir (fun file_ingest_base ->
      let file_store = B.create ~base_path:file_ingest_base in
      let path = Filename.concat dir "input.bin" in
      Out_channel.with_open_bin path (fun channel -> output_string channel payload);
      let references =
        [ store, (B.put store ~bytes:payload ~mime:"application/octet-stream" |> stored_ref_exn)
        ; store, B.put_durable store ~bytes:payload ~mime:"application/octet-stream"
        ; file_store, B.put_file_durable file_store ~path ~mime:"application/octet-stream"
        ]
      in
      let _, first = List.hd references in
      List.iter (fun (store, (reference : O.artifact_ref)) ->
        Alcotest.(check bool) "preview is valid UTF-8" true
          (String.is_valid_utf_8 reference.preview);
        Alcotest.(check bool) "preview keeps byte ceiling" true
          (String.length reference.preview <= B.preview_max);
        Alcotest.(check string) "file and memory previews agree"
          first.preview reference.preview;
        Alcotest.(check bool) "reference serializes as UTF-8 JSON" true
          (O.normalized_artifact_ref_to_json reference |> Yojson.Safe.to_string
           |> String.is_valid_utf_8);
        Alcotest.(check (option string)) "stored binary bytes remain exact"
          (Some payload) (fetch_ok store ~sha256:reference.sha256);
        if payload = unicode then
          Alcotest.(check string) "valid Unicode remains readable"
            unicode reference.preview)
        references))
      payloads)

let test_put_then_fetch_bounded_ranges () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload =
        String.init 8_192 (fun index -> Char.chr (index mod 251))
      in
      match B.put store ~bytes:payload ~mime:"application/octet-stream" with
      | O.Stored { sha256; _ } ->
        let fetch_range store ~offset ~max_bytes =
          match B.fetch_range store ~sha256 ~offset ~max_bytes with
          | Ok (Some range) -> range
          | Ok None -> Alcotest.fail "fetch_range returned None"
          | Error error ->
            Alcotest.failf
              "fetch_range failed: %s"
              (B.fetch_error_to_string error)
        in
        let first = fetch_range store ~offset:123 ~max_bytes:257 in
        Alcotest.(check int) "range reports total bytes"
          (String.length payload)
          first.total_bytes;
        Alcotest.(check string) "range returns exact bounded bytes"
          (String.sub payload 123 257)
          first.content;
        let reopened_store = B.create ~base_path:dir in
        let tail =
          fetch_range reopened_store ~offset:8_150 ~max_bytes:256
        in
        Alcotest.(check string) "range stops exactly at EOF"
          (String.sub payload 8_150 42)
          tail.content;
        let past_eof =
          fetch_range reopened_store ~offset:9_000 ~max_bytes:256
        in
        Alcotest.(check string) "range beyond EOF is empty"
          ""
          past_eof.content)

let test_fetch_range_revalidates_changed_snapshot () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload =
        String.init 8_192 (fun index -> Char.chr (index mod 251))
      in
      match B.put store ~bytes:payload ~mime:"text/plain" with
      | O.Stored { sha256; _ } ->
        (match B.fetch_range store ~sha256 ~offset:0 ~max_bytes:64 with
         | Ok (Some _) -> ()
         | Ok None -> Alcotest.fail "initial fetch_range returned None"
         | Error error ->
           Alcotest.failf
             "initial fetch_range failed: %s"
             (B.fetch_error_to_string error));
        let initial_snapshot =
          match B.For_testing.validated_snapshot store ~sha256 with
          | Some snapshot -> snapshot
          | None -> Alcotest.fail "expected warm snapshot after initial fetch_range"
        in
        let path =
          Filename.concat
            (Filename.concat (B.root_dir store) (String.sub sha256 0 2))
            sha256
        in
        (* Rewriting the valid payload produces a new inode/snapshot. A
           range read must revalidate via the streaming digest path (invoking
           after_window_read), update the cached snapshot, and return the
           exact window. *)
        (match Fs_compat.save_file_atomic path payload with
         | Ok () -> ()
         | Error error ->
           Alcotest.failf "failed to rewrite valid fixture: %s" error);
        let streaming_passes = ref 0 in
        let after_window_read () = incr streaming_passes in
        (match
           B.For_testing.fetch_range
             ~after_window_read
             store
             ~sha256
             ~offset:128
             ~max_bytes:64
         with
         | Ok (Some range) ->
           Alcotest.(check string)
             "changed valid snapshot returns exact window"
             (String.sub payload 128 64)
             range.content;
           Alcotest.(check int)
             "changed valid snapshot used streaming digest path"
             1
             !streaming_passes
         | Ok None -> Alcotest.fail "changed valid snapshot returned None"
         | Error error ->
           Alcotest.failf
             "changed valid snapshot failed: %s"
             (B.fetch_error_to_string error));
        (match B.For_testing.validated_snapshot store ~sha256 with
         | Some refreshed ->
           Alcotest.(check bool)
             "cached snapshot updated to rewritten inode"
             false
             (Fs_compat.equal_owned_regular_file_snapshot
                initial_snapshot
                refreshed)
         | None ->
           Alcotest.fail "expected cached snapshot after streaming revalidation");
        (match
           Fs_compat.save_file_atomic path (String.make 8_192 'y')
         with
         | Ok () -> ()
         | Error error ->
           Alcotest.failf "failed to corrupt fixture: %s" error);
        (match
           B.For_testing.fetch_range
             ~after_window_read
             store
             ~sha256
             ~offset:64
             ~max_bytes:64
         with
         | Error (B.Integrity_mismatch _) ->
           Alcotest.(check int)
             "corrupted snapshot also used streaming digest path"
             2
             !streaming_passes;
           Alcotest.(check bool)
             "corrupted snapshot evicted from cache"
             true
             (Option.is_none (B.For_testing.validated_snapshot store ~sha256))
         | Error error ->
           Alcotest.failf
             "changed snapshot returned wrong error: %s"
             (B.fetch_error_to_string error)
         | Ok _ ->
           Alcotest.fail
             "changed snapshot bypassed content-address validation"))

let test_fetch_miss () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      match B.fetch store ~sha256:(String.make 64 '0') with
      | Ok None -> ()
      | Ok (Some _) -> Alcotest.fail "expected None for unknown sha"
      | Error error ->
          Alcotest.failf "fetch failed: %s" (B.fetch_error_to_string error))

let test_fetch_range_miss_returns_none_fast () =
  (* A range read on a nonexistent shard must not fall into whole-file
     materialisation. The cold path opens the descriptor for the bounded
     range first, so absence is reported as [Ok None] without reading any
     file contents. *)
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let missing = String.make 64 '0' in
      match B.fetch_range store ~sha256:missing ~offset:0 ~max_bytes:64 with
      | Ok None -> ()
      | Ok (Some _) ->
        Alcotest.fail "expected None for nonexistent shard"
      | Error error ->
        Alcotest.failf
          "fetch_range on missing shard returned an error: %s"
          (B.fetch_error_to_string error))

let test_fetch_range_cold_validates_without_materialising () =
  (* Cold-cache read of a large artifact: the streaming digest path must
     validate the content address and return the requested window without
     loading the whole file into memory. We verify behaviour, not
     allocation: the range content and total must be exact, and the
     snapshot cache must be populated so a second page is served by
     bounded I/O. *)
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let size = 1_048_576 in
      let payload = String.init size (fun i -> Char.chr (i mod 251)) in
      match B.put store ~bytes:payload ~mime:"application/octet-stream" with
      | O.Stored { sha256; _ } ->
        (* Reopen so the snapshot cache is cold. *)
        let cold = B.create ~base_path:dir in
        (match B.fetch_range cold ~sha256 ~offset:0 ~max_bytes:1024 with
         | Ok (Some first) ->
           Alcotest.(check int) "cold range reports total bytes" size
             first.total_bytes;
           Alcotest.(check string) "cold range returns exact prefix"
             (String.sub payload 0 1024)
             first.content
         | Ok None ->
           Alcotest.fail "cold fetch_range returned None"
         | Error error ->
           Alcotest.failf
             "cold fetch_range failed: %s"
             (B.fetch_error_to_string error));
        (* Second page hits the now-warm cache: bounded read only. *)
        (match B.fetch_range cold ~sha256 ~offset:1024 ~max_bytes:512 with
         | Ok (Some second) ->
           Alcotest.(check string) "warm range returns exact window"
             (String.sub payload 1024 512)
             second.content
         | Ok None ->
           Alcotest.fail "warm fetch_range returned None"
         | Error error ->
           Alcotest.failf
             "warm fetch_range failed: %s"
             (B.fetch_error_to_string error)))

let test_cancel_queued_cold_range_read_leaves_cache_empty () =
  with_temp_dir (fun dir ->
    let store = B.create ~base_path:dir in
    let payload = String.make 1_048_576 'p' in
    let reference =
      B.put store ~bytes:payload ~mime:"application/octet-stream"
      |> stored_ref_exn
    in
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let pool = Domain_pool.create ~sw ~domain_count:1 env#domain_mgr in
    let previous_pool = Domain_pool_ref.get () in
    Eio.Switch.on_release sw (fun () ->
      match previous_pool with
      | None -> Domain_pool_ref.clear_for_tests ()
      | Some previous -> Domain_pool_ref.set previous);
    Domain_pool_ref.set pool;
    let occupied, signal_occupied = Eio.Promise.create () in
    let released, release_worker = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Domain_pool.submit_cpu pool (fun () ->
        Eio.Promise.resolve signal_occupied ();
        Eio.Promise.await released));
    Eio.Promise.await occupied;
    let context, signal_context = Eio.Promise.create () in
    let cancelled = Eio.Fiber.fork_promise ~sw (fun () ->
      try
        Eio.Cancel.sub (fun cc ->
          Eio.Promise.resolve signal_context cc;
          ignore (B.fetch_range store ~sha256:reference.sha256 ~offset:0 ~max_bytes:64));
        false
      with Eio.Cancel.Cancelled _ -> true)
    in
    let cc = Eio.Promise.await context in
    Eio.Fiber.yield ();
    Alcotest.(check bool) "cold read waits for the occupied pool" false
      (Eio.Promise.is_resolved cancelled);
    let sibling = Eio.Fiber.fork_promise ~sw (fun () -> "progress") in
    Alcotest.(check string) "another fiber progresses" "progress"
      (Eio.Promise.await_exn sibling);
    Eio.Cancel.cancel cc Exit;
    Alcotest.(check bool) "queued read propagates cancellation" true
      (Eio.Promise.await_exn cancelled);
    Eio.Promise.resolve release_worker ();
    Domain_pool.submit_cpu pool (fun () -> ());
    Alcotest.(check bool) "cancelled read did not admit a cache entry" true
      (Option.is_none (B.For_testing.validated_snapshot store ~sha256:reference.sha256));
    match B.fetch_range store ~sha256:reference.sha256 ~offset:0 ~max_bytes:64 with
    | Ok (Some range) ->
      Alcotest.(check string) "subsequent read returns verified bytes"
        (String.sub payload 0 64) range.content
    | Ok None -> Alcotest.fail "artifact vanished after cancellation"
    | Error error -> Alcotest.fail (B.fetch_error_to_string error))

let shard_path_of store sha256 =
  Filename.concat
    (Filename.concat (B.root_dir store) (String.sub sha256 0 2))
    sha256

let test_fetch_range_cold_returns_only_bytes_it_hashed () =
  (* #38972. A put that repairs a corrupt address (temp+rename) can land
     while a cold range read is in flight. The shard holds corrupt bytes C
     when the read starts; the [after_window_read] seam restores the payload
     P after the window has been read and before the digest admits it. The
     invariant is "the bytes returned are the bytes hashed": the call either
     reports that the state it read does not match the address, or returns a
     window of a state that does — never C's window as verified — and C's
     snapshot never becomes the cached validated state. The earlier cold
     branch read the window and hashed through two opens, so the digest
     covered P while the window came from C; it served C and cached C. *)
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = String.make 8_192 'p' in
      let corrupt = String.make 8_192 'c' in
      match B.put store ~bytes:payload ~mime:"text/plain" with
      | O.Stored { sha256; _ } ->
        let path = shard_path_of store sha256 in
        let write bytes =
          match Fs_compat.save_file_atomic path bytes with
          | Ok () -> ()
          | Error error -> Alcotest.failf "failed to write fixture: %s" error
        in
        let snapshot_now () =
          match
            Fs_compat.load_owned_regular_file_with_snapshot
              ~ownership_root:dir
              path
          with
          | Ok (Some (contents : Fs_compat.owned_regular_file_contents)) ->
            contents.snapshot
          | Ok None -> Alcotest.fail "fixture shard is missing"
          | Error _ -> Alcotest.fail "fixture shard is unreadable"
        in
        write corrupt;
        let corrupt_snapshot = snapshot_now () in
        Alcotest.(check bool)
          "the range cache starts cold for this address"
          true
          (Option.is_none (B.For_testing.validated_snapshot store ~sha256));
        let swaps = ref 0 in
        let after_window_read () =
          incr swaps;
          write payload
        in
        (match
           B.For_testing.fetch_range
             ~after_window_read
             store
             ~sha256
             ~offset:0
             ~max_bytes:64
         with
         | Error (B.Integrity_mismatch _) -> ()
         | Ok (Some range) ->
           Alcotest.(check string)
             "a returned window belongs to a state whose digest matches the address"
             (String.sub payload 0 64)
             range.content
         | Ok None -> Alcotest.fail "fetch_range returned None"
         | Error error ->
           Alcotest.failf
             "fetch_range failed: %s"
             (B.fetch_error_to_string error));
        Alcotest.(check int) "the seam ran once, on the cold path" 1 !swaps;
        Alcotest.(check bool)
          "the corrupt state is not cached as validated"
          false
          (match B.For_testing.validated_snapshot store ~sha256 with
           | Some cached ->
             Fs_compat.equal_owned_regular_file_snapshot cached corrupt_snapshot
           | None -> false);
        (* The repaired shard serves the next page. *)
        match B.fetch_range store ~sha256 ~offset:64 ~max_bytes:64 with
        | Ok (Some range) ->
          Alcotest.(check string)
            "the next read serves the repaired payload"
            (String.sub payload 64 64)
            range.content
        | Ok None -> Alcotest.fail "next fetch_range returned None"
        | Error error ->
          Alcotest.failf
            "next fetch_range failed: %s"
            (B.fetch_error_to_string error))

let test_range_with_sha256_window_is_a_slice_of_the_hashed_bytes () =
  (* The single-descriptor read copies the window out while the whole file
     streams through a 64 KiB buffer, so the window arithmetic is the new
     risk: windows that start inside a chunk, cross a chunk boundary, fill
     exactly one chunk, run past EOF, start at or past EOF, or are empty. *)
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let size = 200_000 in
      let payload = String.init size (fun i -> Char.chr ((i * 7 + (i / 251)) mod 256)) in
      match B.put store ~bytes:payload ~mime:"application/octet-stream" with
      | O.Stored { sha256; _ } ->
        let path = shard_path_of store sha256 in
        List.iter
          (fun (offset, max_bytes) ->
             let label = Printf.sprintf "offset %d, max %d" offset max_bytes in
             match
               Fs_compat.load_owned_regular_file_range_with_sha256
                 ~ownership_root:dir
                 ~offset
                 ~max_bytes
                 path
             with
             | Ok (Some (observed : Fs_compat.owned_regular_file_range_digest)) ->
               let start = min offset size in
               Alcotest.(check string)
                 (label ^ ": window")
                 (String.sub payload start (min max_bytes (size - start)))
                 observed.content;
               Alcotest.(check string)
                 (label ^ ": digest covers the whole file")
                 sha256
                 observed.sha256;
               Alcotest.(check int)
                 (label ^ ": snapshot size")
                 size
                 observed.snapshot.file_size
             | Ok None -> Alcotest.failf "%s: shard missing" label
             | Error error ->
               Alcotest.failf
                 "%s: %s"
                 label
                 (Fs_compat.owned_regular_file_read_error_to_string error))
          [ 0, 64
          ; 65_530, 20
          ; 65_536, 65_536
          ; 131_000, 70_000
          ; 199_990, 64
          ; size, 64
          ; size + 5, 64
          ; 0, 0
          ; 0, size
          ])

let test_idempotent_put () =
  (* Same content twice = same sha = same path, no error. *)
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = "idempotent payload" in
      let r1 = B.put store ~bytes:payload ~mime:"text/plain" in
      let r2 = B.put store ~bytes:payload ~mime:"text/plain" in
      let sha_of = function
        | O.Stored { sha256; _ } -> sha256
      in
      Alcotest.(check string)
        "same content -> same sha" (sha_of r1) (sha_of r2);
      Alcotest.(check int) "single entry" 1 (List.length (B.list_all store)))

(* The demotion puts every aged tool result on every provider request. A put
   of an address this process already wrote leaves the file alone, so the file
   keeps its inode. A file that disappears or is damaged behind the store is
   noticed by fetch, and the next put writes it again. *)
let test_put_writes_an_address_again_only_after_fetch_finds_it_gone () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = String.make 4_096 'p' in
      let put () = ignore (B.put store ~bytes:payload ~mime:"text/plain" : O.t) in
      let reference =
        stored_ref_exn (B.put store ~bytes:payload ~mime:"text/plain")
      in
      let sha256 = reference.O.sha256 in
      let path =
        Filename.concat
          (Filename.concat (B.root_dir store) (String.sub sha256 0 2))
          sha256
      in
      let inode () = (Unix.stat path).Unix.st_ino in
      let written = inode () in
      put ();
      Alcotest.(check int) "a second put leaves the written file in place" written (inode ());
      Unix.unlink path;
      Alcotest.(check (option string)) "fetch reports the removed file" None
        (fetch_ok store ~sha256);
      put ();
      Alcotest.(check (option string)) "and the next put writes it again" (Some payload)
        (fetch_ok store ~sha256);
      (match Fs_compat.save_file_atomic path (String.make 4_096 'q') with
       | Ok () -> ()
       | Error error -> Alcotest.failf "failed to damage fixture: %s" error);
      (match B.fetch store ~sha256 with
       | Error (B.Integrity_mismatch _) -> ()
       | Error error ->
         Alcotest.failf "damaged blob returned wrong error: %s"
           (B.fetch_error_to_string error)
       | Ok _ -> Alcotest.fail "damaged blob passed content-address validation");
      put ();
      Alcotest.(check (option string)) "a put after the mismatch repairs the bytes"
        (Some payload) (fetch_ok store ~sha256))

(* The model reads markers through [fetch_range], and a blob path can end up
   holding something that is not the blob. Any read that does not return
   validated bytes lets the next put write the address again. *)
let blob_path store sha256 =
  Filename.concat (Filename.concat (B.root_dir store) (String.sub sha256 0 2)) sha256

let test_a_range_read_that_finds_the_blob_gone_lets_the_next_put_write_it () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = String.make 8_192 'r' in
      let sha256 =
        (stored_ref_exn (B.put store ~bytes:payload ~mime:"text/plain")).O.sha256
      in
      (match B.fetch_range store ~sha256 ~offset:0 ~max_bytes:64 with
       | Ok (Some _) -> ()
       | Ok None -> Alcotest.fail "first page of a stored blob returned None"
       | Error error ->
         Alcotest.failf "first page failed: %s" (B.fetch_error_to_string error));
      Unix.unlink (blob_path store sha256);
      (match B.fetch_range store ~sha256 ~offset:64 ~max_bytes:64 with
       | Ok None | Error (B.Owned_read_failed _) -> ()
       | Ok (Some _) -> Alcotest.fail "a removed blob returned a page"
       | Error error ->
         Alcotest.failf "removed blob returned wrong error: %s"
           (B.fetch_error_to_string error));
      ignore (B.put store ~bytes:payload ~mime:"text/plain" : O.t);
      Alcotest.(check (option string)) "the next put writes it again" (Some payload)
        (fetch_ok store ~sha256))

let test_a_read_error_at_the_blob_path_lets_the_next_put_replace_it () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = "blob behind a symlink" in
      let sha256 =
        (stored_ref_exn (B.put store ~bytes:payload ~mime:"text/plain")).O.sha256
      in
      let path = blob_path store sha256 in
      let elsewhere = Filename.concat dir "elsewhere" in
      Fs_compat.save_file elsewhere "not the blob";
      Unix.unlink path;
      Unix.symlink elsewhere path;
      (match B.fetch store ~sha256 with
       | Error (B.Owned_read_failed _) -> ()
       | Error error ->
         Alcotest.failf "symlinked blob returned wrong error: %s"
           (B.fetch_error_to_string error)
       | Ok _ -> Alcotest.fail "a symlink at the blob path was read as the blob");
      ignore (B.put store ~bytes:payload ~mime:"text/plain" : O.t);
      Alcotest.(check (option string)) "the next put replaces what was at the path"
        (Some payload) (fetch_ok store ~sha256))

(* Only [put] reads the set of written addresses, so a [put_durable] write does
   not enter it: a put of the same bytes afterwards still writes the file. *)
let test_a_durable_put_does_not_let_a_later_put_skip_its_write () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = "written durably first" in
      let reference = B.put_durable store ~bytes:payload ~mime:"text/plain" in
      let path = blob_path store reference.O.sha256 in
      let durable_inode = (Unix.stat path).Unix.st_ino in
      ignore (B.put store ~bytes:payload ~mime:"text/plain" : O.t);
      Alcotest.(check bool) "the put after a durable put writes the file again" true
        (durable_inode <> (Unix.stat path).Unix.st_ino);
      Alcotest.(check (option string)) "and the bytes are the same" (Some payload)
        (fetch_ok store ~sha256:reference.O.sha256))

let test_durable_reuse_revalidates_without_rewriting () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = "current memory projection" in
      let reference = B.put_durable_reuse store ~bytes:payload ~mime:"text/plain" in
      let path = blob_path store reference.O.sha256 in
      let inode = (Unix.stat path).Unix.st_ino in
      ignore (B.put_durable_reuse store ~bytes:payload ~mime:"text/plain" : O.artifact_ref);
      Alcotest.(check int) "unchanged recall is not rewritten" inode (Unix.stat path).Unix.st_ino;
      Fs_compat.save_file path "corrupt recall";
      ignore (B.put_durable_reuse store ~bytes:payload ~mime:"text/plain" : O.artifact_ref);
      Alcotest.(check (option string)) "corrupt recall is repaired" (Some payload)
        (fetch_ok store ~sha256:reference.O.sha256);
      Unix.unlink path;
      ignore (B.put store ~bytes:payload ~mime:"text/plain" : O.t);
      let ordinary_inode = (Unix.stat path).Unix.st_ino in
      ignore (B.put_durable_reuse store ~bytes:payload ~mime:"text/plain" : O.artifact_ref);
      Alcotest.(check bool) "ordinary replacement cannot inherit strict evidence" true
        (ordinary_inode <> (Unix.stat path).Unix.st_ino);
      Unix.unlink path;
      ignore (B.put_durable_reuse store ~bytes:payload ~mime:"text/plain" : O.artifact_ref);
      Alcotest.(check (option string)) "collected recall is republished" (Some payload)
        (fetch_ok store ~sha256:reference.O.sha256))

let test_ordinary_put_does_not_establish_durable_reuse () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = "not yet strictly published" in
      let reference = stored_ref_exn (B.put store ~bytes:payload ~mime:"text/plain") in
      let path = blob_path store reference.O.sha256 in
      let inode = (Unix.stat path).Unix.st_ino in
      ignore (B.put_durable_reuse store ~bytes:payload ~mime:"text/plain" : O.artifact_ref);
      Alcotest.(check bool) "first strict publication does write" true
        (inode <> (Unix.stat path).Unix.st_ino))

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
            (Sys.file_exists expected))

(* Fixtures here hold a handful of small files and compete with no startup
   watchdog, so they scan unbounded; the budget path has its own tests. *)
let maintenance_ok ~base_path ~mode =
  match M.run ~base_path ~board_posts_file ~mode with
  | Ok report -> report
  | Error error ->
    Alcotest.failf "maintenance failed: %s" (M.error_to_string error)

let test_maintenance_keeps_live_and_deletes_stable_dead_after_restart () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let live =
        B.put store ~bytes:"live shared bridge output" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let dead =
        B.put store ~bytes:"dead replay sidecar output" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let replay_live =
        B.put store ~bytes:"live gate replay output" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let durable_consumer =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "keepers/keeper-a/sessions/history.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname durable_consumer);
      Fs_compat.save_file
        durable_consumer
        (Yojson.Safe.to_string
           (`Assoc
             [ "consumer", `String "Tool_bridge"
             ; "output_ref", `String (O.encode_for_agent_core (O.Stored live))
             ])
         ^ "\n");
      let replay_sidecar =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "gate/replay-results.json"
      in
      Fs_compat.mkdir_p (Filename.dirname replay_sidecar);
      Fs_compat.save_file
        replay_sidecar
        (Yojson.Safe.pretty_to_string
           (`Assoc
             [ "approval_id", `String "approval-maintenance"
             ; ( "outcome"
               , `String (O.encode_for_agent_core (O.Stored replay_live)) )
             ]));
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int) "union includes both consumers" 2 observed.live_references;
      Alcotest.(check int) "three blobs observed" 3 observed.blobs_observed;
      Alcotest.(check int) "one candidate" 1 observed.candidates_recorded;
      Alcotest.(check int) "observe deletes none" 0 observed.deleted;
      Alcotest.(check bool)
        "dead remains after observation"
        true
        (Option.is_some (fetch_ok store ~sha256:dead.sha256));
      (* The second call deliberately uses only the durable candidate snapshot:
         this is the restart boundary of the two-state retention policy. *)
      let swept =
        maintenance_ok
          ~base_path
          ~mode:M.Delete_previous_candidates
      in
      Alcotest.(check int) "stable dead blob deleted" 1 swept.deleted;
      Alcotest.(check (option string))
        "shared consumer reference remains live"
        (Some "live shared bridge output")
        (fetch_ok store ~sha256:live.sha256);
      Alcotest.(check (option string))
        "dead blob no longer exists"
        None
        (fetch_ok store ~sha256:dead.sha256);
      Alcotest.(check (option string))
        "Gate replay sidecar reference remains live"
        (Some "live gate replay output")
        (fetch_ok store ~sha256:replay_live.sha256))

let test_maintenance_keeps_board_attachment_reference () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let live =
        B.put store ~bytes:"board attachment" ~mime:"image/png"
        |> stored_ref_exn
      in
      let dead =
        B.put store ~bytes:"unreferenced attachment" ~mime:"image/png"
        |> stored_ref_exn
      in
      let child = B.put_durable store ~bytes:"board manifest child" ~mime:"text/plain" in
      let structured_content =
        `Assoc [ "output_artifact", O.normalized_artifact_ref_to_json child ]
      in
      let manifest =
        B.put_durable store
          ~bytes:
            (O.artifact_manifest_to_json
               ~content:"board manifest child" ~structured_content
             |> Yojson.Safe.to_string)
          ~mime:O.artifact_manifest_mime
      in
      (* Written where the product writes it (Board_paths), not where the scan
         reads, so a scanner path that drifts from Board's turns this red. *)
      let board_posts =
        Masc_board_handlers.Board_paths.file_path
          ~workspace_masc_dir:
            (Common.masc_dir_from_base_path ~base_path)
          Masc_board_handlers.Board_paths.Posts
      in
      Fs_compat.mkdir_p (Filename.dirname board_posts);
      Fs_compat.save_file
        board_posts
        (Yojson.Safe.to_string
           (`Assoc
              [ "meta",
                `Assoc
                  [ "attachments",
                    `List
                      [ `Assoc
                          [ "kind", `String "image"
                          ; "artifact", O.normalized_artifact_ref_to_json live
                          ]
                      ; `Assoc
                          [ "kind", `String "external_link"
                          ; "artifact", O.normalized_artifact_ref_to_json manifest
                          ]
                      ]
                  ]
              ])
         ^ "\n");
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int) "Board and manifest child references are live" 3 observed.live_references;
      let swept = maintenance_ok ~base_path ~mode:M.Delete_previous_candidates in
      Alcotest.(check int) "only dead blob deleted" 1 swept.deleted;
      Alcotest.(check (option string))
        "Board artifact survives"
        (Some "board attachment")
        (fetch_ok store ~sha256:live.sha256);
      Alcotest.(check (option string))
        "Board manifest child survives"
        (Some "board manifest child")
        (fetch_ok store ~sha256:child.sha256);
      Alcotest.(check (option string))
        "unreferenced artifact is deleted"
        None
        (fetch_ok store ~sha256:dead.sha256))

let test_maintenance_keeps_prepared_lane_broadcast () =
  with_temp_dir (fun base_path ->
    let store = B.create ~base_path in
    let child = B.put_durable store ~bytes:"prepared Lane evidence" ~mime:"text/plain" in
    let manifest = B.put_durable store ~mime:O.artifact_manifest_mime
      ~bytes:(O.artifact_manifest_to_json ~content:"prepared evidence"
        ~structured_content:(`Assoc ["artifact",O.normalized_artifact_ref_to_json child])
        |> Yojson.Safe.to_string) in
    let workspace = Common.masc_dir_from_base_path ~base_path in
    let prepared = Filename.concat workspace "lane-addons/broadcasts/instance/operation.json" in
    Fs_compat.mkdir_p (Filename.dirname prepared);
    Fs_compat.save_file prepared (Yojson.Safe.to_string (`Assoc ["evidence",`Assoc [
      "keeper_artifact",O.normalized_artifact_ref_to_json manifest]]));
    for _pass = 1 to 2 do
      let result = maintenance_ok ~base_path ~mode:M.Delete_previous_candidates in
      Alcotest.(check int) "prepared manifest and child remain rooted" 2 result.live_references;
      Alcotest.(check int) "prepared evidence is not swept" 0 result.deleted
    done;
    Alcotest.(check (option string)) "child remains readable for retry"
      (Some "prepared Lane evidence") (fetch_ok store ~sha256:child.sha256))

let test_maintenance_keeps_wire_capture_reference_within_retention () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let captured =
        B.put store ~bytes:"captured provider response" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let dead =
        B.put store ~bytes:"unreferenced provider response" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let wire_capture =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "wire-capture/2026-07/28.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname wire_capture);
      Fs_compat.save_file
        wire_capture
        (Yojson.Safe.to_string
           (`Assoc
             [ "kind", `String "response"
             ; ( "response_text"
               , `String (O.encode_for_agent_core (O.Stored captured)) )
             ])
         ^ "\n");
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "wire capture reference is live"
        1
        observed.live_references;
      Alcotest.(check int)
        "only the unreferenced blob is a candidate"
        1
        observed.candidates_recorded;
      let swept =
        maintenance_ok
          ~base_path
          ~mode:M.Delete_previous_candidates
      in
      Alcotest.(check int) "stable unreferenced blob is deleted" 1 swept.deleted;
      Alcotest.(check (option string))
        "wire capture blob remains readable"
        (Some "captured provider response")
        (fetch_ok store ~sha256:captured.sha256);
      Alcotest.(check (option string))
        "unreferenced blob no longer exists"
        None
        (fetch_ok store ~sha256:dead.sha256))

let test_maintenance_malformed_reference_fails_closed () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"must survive malformed source" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let source =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "gate/malformed.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname source);
      Fs_compat.save_file source "{\"output\":\"[masc:blob sha256=garbage]\"}\n";
      (match M.run ~base_path ~board_posts_file ~mode:M.Delete_previous_candidates with
       | Error (M.Malformed_artifact_reference { path; line; _ }) ->
         Alcotest.(check string) "exact malformed source" source path;
         Alcotest.(check int) "exact malformed line" 1 line
       | Error error ->
         Alcotest.failf
           "unexpected maintenance error: %s"
           (M.error_to_string error)
       | Ok _ -> Alcotest.fail "malformed reference reached deletion");
      Alcotest.(check (option string))
        "blob retained on malformed reference"
        (Some "must survive malformed source")
        (fetch_ok store ~sha256:blob.sha256))

let test_maintenance_noncanonical_reference_fails_closed () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"must survive noncanonical source" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let source =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "gate/noncanonical.json"
      in
      Fs_compat.mkdir_p (Filename.dirname source);
      Fs_compat.save_file
        source
        (Yojson.Safe.to_string
           (`String
             (O.encode_for_agent_core (O.Stored blob) ^ " trailing text")));
      (match M.run ~base_path ~board_posts_file ~mode:M.Delete_previous_candidates with
       | Error (M.Malformed_artifact_reference { path; line; offset; _ }) ->
         Alcotest.(check string) "exact noncanonical source" source path;
         Alcotest.(check int) "exact malformed line" 1 line;
         Alcotest.(check int) "whole-value offset" 0 offset
       | Error error ->
         Alcotest.failf
           "unexpected maintenance error: %s"
           (M.error_to_string error)
       | Ok _ -> Alcotest.fail "noncanonical reference reached deletion");
      Alcotest.(check (option string))
        "blob retained on noncanonical reference"
        (Some "must survive noncanonical source")
        (fetch_ok store ~sha256:blob.sha256))

let test_maintenance_ignores_marker_embedded_in_prose () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"unreferenced output" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let source =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "gate/prompt.json"
      in
      Fs_compat.mkdir_p (Filename.dirname source);
      Fs_compat.save_file
        source
        (Yojson.Safe.to_string
           (`Assoc
             [ ( "content"
               , `String
                   ("documentation example: "
                    ^ O.encode_for_agent_core (O.Stored blob)) )
             ]));
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "embedded marker is not a live reference"
        0
        observed.live_references;
      Alcotest.(check int)
        "prose does not claim blob ownership"
        1
        observed.candidates_recorded;
      Alcotest.(check (option string))
        "observe-only scan retains candidate"
        (Some "unreferenced output")
        (fetch_ok store ~sha256:blob.sha256))

let test_maintenance_does_not_scan_repository_mirrors () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"not owned by a repository mirror" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let repository_source =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "repos/masc/docs/blob-marker.md"
      in
      Fs_compat.mkdir_p (Filename.dirname repository_source);
      Fs_compat.save_file
        repository_source
        "documentation example: [masc:blob not-a-reference]";
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "repository source does not claim blob ownership"
        1
        observed.candidates_recorded;
      let swept =
        maintenance_ok
          ~base_path
          ~mode:M.Delete_previous_candidates
      in
      Alcotest.(check int) "stable unowned blob is deleted" 1 swept.deleted;
      Alcotest.(check (option string))
        "repository text did not retain the blob"
        None
        (fetch_ok store ~sha256:blob.sha256))

let test_maintenance_does_not_scan_trajectory_previews () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"not owned by a trajectory preview" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let trajectory_source =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "trajectories/keeper-a/trace.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname trajectory_source);
      let marker = O.encode_for_agent_core (O.Stored blob) in
      Fs_compat.save_file
        trajectory_source
        (Yojson.Safe.to_string
           (`Assoc
             [ ( "result"
               , `String
                   (String.sub marker 0 (min 120 (String.length marker))
                    ^ "...") )
             ])
         ^ "\n");
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "trajectory preview is not a live reference"
        0
        observed.live_references;
      Alcotest.(check int)
        "trajectory preview does not claim blob ownership"
        1
        observed.candidates_recorded;
      Alcotest.(check (option string))
        "observe-only scan retains trajectory candidate"
        (Some "not owned by a trajectory preview")
        (fetch_ok store ~sha256:blob.sha256))

let test_maintenance_rechecks_candidate_referenced_before_startup () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let candidate =
        B.put store ~bytes:"referenced before startup sweep" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int) "one candidate observed" 1 observed.candidates_recorded;
      let durable_consumer =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "keepers/keeper-a/history.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname durable_consumer);
      Fs_compat.save_file
        durable_consumer
        (Yojson.Safe.to_string
           (`Assoc
             [ "output_ref", `String (O.encode_for_agent_core (O.Stored candidate)) ])
         ^ "\n");
      let swept =
        maintenance_ok
          ~base_path
          ~mode:M.Delete_previous_candidates
      in
      Alcotest.(check int) "new live reference prevents deletion" 0 swept.deleted;
      Alcotest.(check (option string))
        "newly referenced candidate remains readable"
        (Some "referenced before startup sweep")
        (fetch_ok store ~sha256:candidate.sha256))

let test_maintenance_keeps_normalized_tool_call_blob_reference () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let reference =
        B.put
          store
          ~bytes:"normalized tool-call output"
          ~mime:"text/plain"
        |> stored_ref_exn
      in
      let tool_call_log =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "tool_calls/2026-07/29.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname tool_call_log);
      Fs_compat.save_file
        tool_call_log
        (Yojson.Safe.to_string
           (`Assoc
             [ "keeper", `String "keeper-tool-log"
             ; "tool", `String "large_output"
             ; ( "output"
               , `Assoc
                   [ ( "_blob"
                     , `Assoc
                         [ "sha256", `String reference.sha256
                         ; "bytes", `Int reference.bytes
                         ; "mime", `String reference.mime
                         ; "preview", `String reference.preview
                         ] )
                   ] )
             ])
         ^ "\n");
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "normalized tool-call reference is live"
        1
        observed.live_references;
      Alcotest.(check int)
        "normalized live blob is not a candidate"
        0
        observed.candidates_recorded;
      let swept =
        maintenance_ok
          ~base_path
          ~mode:M.Delete_previous_candidates
      in
      Alcotest.(check int) "normalized live blob is not deleted" 0 swept.deleted;
      Alcotest.(check (option string))
        "normalized tool-call blob remains readable"
        (Some "normalized tool-call output")
        (fetch_ok store ~sha256:reference.sha256))

let test_maintenance_skips_open_tool_call_read_index_and_wal_sidecars () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let reference =
        B.put
          store
          ~bytes:"tool-call output alongside open read index"
          ~mime:"text/plain"
        |> stored_ref_exn
      in
      Masc.Keeper_tool_call_log.reset_for_testing ();
      Masc.Keeper_tool_call_log.init ~base_path ();
      let ledger_dir =
        Filename.concat (Common.masc_dir_from_base_path ~base_path) "tool_calls"
      in
      Fun.protect
        ~finally:(fun () ->
          (match Masc.Keeper_tool_call_log.store () with
           | Some ledger_store ->
             Dated_jsonl.prepare_for_directory_removal ledger_store
           | None -> ());
          Masc.Keeper_tool_call_log.reset_for_testing ();
          Keeper_tool_call_index.forget_for_ledger ~ledger_dir)
        (fun () ->
          Masc.Keeper_tool_call_log.log_call
            ~keeper_name:"keeper-tool-log"
            ~tool_name:"large_output"
            ~input:(`Assoc [])
            ~output_text:(O.encode_for_agent_core (O.Stored reference))
            ~duration_ms:1.0
            ~wire_outcome:Tool_result.Ok
            ~artifact_refs:[ reference ]
            ();
          (match
             Masc.Keeper_tool_call_log.read_recent
               ~keeper_name:"keeper-tool-log"
               ~n:10
               ()
           with
           | Ok rows ->
             Alcotest.(check int) "indexed row read back" 1 (List.length rows)
           | Error (Masc.Keeper_tool_call_log.Index_unavailable detail) ->
             Alcotest.failf "read_recent failed: %s" detail);
          let db_path = Keeper_tool_call_index.database_path ~ledger_dir in
          Alcotest.(check bool)
            "SQLite read index exists"
            true
            (Sys.file_exists db_path);
          Alcotest.(check bool)
            "SQLite WAL sidecar exists while connection is open"
            true
            (Sys.file_exists (db_path ^ "-wal"));
          Alcotest.(check bool)
            "SQLite SHM sidecar exists while connection is open"
            true
            (Sys.file_exists (db_path ^ "-shm"));
          Fs_compat.save_file (db_path ^ "-journal") "\x00\xd9\xd5\x05\xf9\x20\xa1\x63";
          let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
          Alcotest.(check int)
            "tool-call reference remains live across open WAL index scan"
            1
            observed.live_references;
          Alcotest.(check int)
            "referenced blob is not marked as candidate"
            0
            observed.candidates_recorded))

let test_maintenance_skips_atomic_staging_files () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let reference =
        B.put
          store
          ~bytes:"tool-call output beside an atomic staging file"
          ~mime:"text/plain"
        |> stored_ref_exn
      in
      let month_dir =
        Filename.concat
          (Filename.concat (Common.masc_dir_from_base_path ~base_path) "tool_calls")
          "2026-07"
      in
      Fs_compat.mkdir_p month_dir;
      let ledger_row = Filename.concat month_dir "29.jsonl" in
      Fs_compat.save_file
        ledger_row
        (Yojson.Safe.to_string
           (`Assoc
             [ "keeper", `String "keeper-tool-log"
             ; "tool", `String "large_output"
             ; ( "output"
               , `Assoc
                   [ ( "_blob"
                     , `Assoc
                         [ "sha256", `String reference.sha256
                         ; "bytes", `Int reference.bytes
                         ; "mime", `String reference.mime
                         ; "preview", `String reference.preview
                         ] ) ]
             )])
        ^ "\n");
      (* An interrupted atomic replace can leave an incomplete staging
         payload beside the authoritative ledger. Offline maintenance skips
         the unpublished payload and still reads the ledger reference. *)
      let staging_path = Filename.concat month_dir ".atomic_42.tmp" in
      Fs_compat.save_file staging_path "{\"half-written\":";
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "ledger reference survives a staging file in the scanned directory"
        1
        observed.live_references;
      Alcotest.(check int)
        "staging scan skips keep the referenced blob unmarked"
        0
        observed.candidates_recorded)

let test_maintenance_reads_chat_operation_store_and_prepared_gate_checkpoint () =
  with_temp_dir (fun base_path ->
      let module Store = Keeper_chat_operation_store in
      let module Operation = Keeper_chat_operation in
      let module Semantic = Keeper_semantic_execution in
      let require = function
        | Ok value -> value
        | Error detail -> Alcotest.fail detail
      in
      let ok = function
        | Ok value -> value
        | Error error -> Alcotest.fail (Store.error_to_string error)
      in
      let blob_store = B.create ~base_path in
      let terminal_outcome_blob =
        B.put
          blob_store
          ~bytes:"terminal chat operation outcome payload"
          ~mime:"text/plain"
        |> stored_ref_exn
      in
      let batch_leader_blob =
        B.put
          blob_store
          ~bytes:"frozen batch leader original input payload"
          ~mime:"text/plain"
        |> stored_ref_exn
      in
      let queued_blob =
        B.put
          blob_store
          ~bytes:"queued chat operation payload"
          ~mime:"text/plain"
        |> stored_ref_exn
      in
      let gate_checkpoint_blob =
        B.put
          blob_store
          ~bytes:"prepared gate checkpoint payload"
          ~mime:"text/plain"
        |> stored_ref_exn
      in
      let keepers_runtime_dir = Common.keepers_runtime_dir_of_base ~base_path in
      let db_path =
        Store.path_for_keeper
          ~keepers_runtime_dir
          ~keeper_name:"keeper-exec-tools"
      in
      Fs_compat.mkdir_p (Filename.dirname db_path);
      let op_store = Store.open_or_create ~path:db_path |> ok in
      Fun.protect
        ~finally:(fun () -> ignore (Store.close op_store : (unit, Store.error) result))
        (fun () ->
          let terminal_op_id =
            Operation.Operation_id.of_string "op-terminal-ref" |> require
          in
          let gate_op_id =
            Operation.Operation_id.of_string "op-gate-reconcile" |> require
          in
          let batch_leader_id =
            Operation.Operation_id.of_string "op-batch-leader-ref" |> require
          in
          let queued_op_id =
            Operation.Operation_id.of_string "op-queued-ref" |> require
          in
          let source = `Assoc [ "kind", `String "dashboard" ] in
          let gate_input = `Assoc [ "message", `String "run gate turn" ] in
          let batch_leader_input =
            `Assoc
              [ ( "leader_ref"
                , `String (O.encode_for_agent_core (O.Stored batch_leader_blob)) )
              ]
          in
          let queued_input =
            `Assoc
              [ ( "output_ref"
                , `String (O.encode_for_agent_core (O.Stored queued_blob)) )
              ]
          in
          ignore
            (Store.submit
               op_store
               ~now:0.5
               ~operation_id:terminal_op_id
               ~source
               ~input:(`Assoc [ "message", `String "complete me" ])
             |> ok);
          ignore (Store.claim_next op_store ~now:0.6 |> ok);
          ignore
            (Store.succeed_running
               op_store
               ~now:0.7
               ~operation_id:terminal_op_id
               ~outcome_ref:
                 (O.encode_for_agent_core (O.Stored terminal_outcome_blob))
             |> ok);
          ignore
            (Store.submit
               op_store
               ~now:1.0
               ~operation_id:gate_op_id
               ~source
               ~input:gate_input
             |> ok);
          let claimed =
            match Store.claim_next op_store ~now:2.0 |> ok with
            | Some op -> op
            | None -> Alcotest.fail "expected gate operation to claim"
          in
          let canonical_checkpoint_bytes =
            Agent_core.Checkpoint.to_string
              Agent_core.Checkpoint.
                { version = checkpoint_version
                ; session_id = "gate-trace"
                ; agent_name = "keeper-exec-tools"
                ; model = "fixture"
                ; system_prompt = None
                ; messages =
                    [ Agent_core.Types.user_msg
                        (O.encode_for_agent_core
                           (O.Stored gate_checkpoint_blob))
                    ]
                ; usage = Agent_core.Types.empty_usage
                ; turn_count = 1
                ; created_at = 2.0
                ; tools = []
                ; tool_choice = None
                ; disable_parallel_tool_use = false
                ; temperature = None
                ; top_p = None
                ; top_k = None
                ; min_p = None
                ; enable_thinking = None
                ; preserve_thinking = None
                ; response_format = Agent_core.Types.Off
                ; reasoning_effort = None
                ; cache_system_prompt = false
                ; context = Agent_core.Context.create_sync ()
                ; pending_input = None; mcp_sessions = []
                ; working_context = None
                }
          in
          let reference =
            Keeper_checkpoint_ref.create
              ~trace_id:(Keeper_id.Trace_id.of_string "gate-trace" |> require)
              ~turn_count:1
              ~canonical_checkpoint_bytes
            |> Result.map_error Masc.Keeper_checkpoint_store.checkpoint_ref_create_error_to_string
            |> require
          in
          let preparation : Semantic.gate_preparation =
            Semantic.Prepared_agent_core { reference; canonical_checkpoint_bytes }
          in
          let binding =
            (* gate_binding already reports its error as a string, so
               require takes it directly. *)
            Semantic.gate_binding
              ~preparation
              ~approval_ids:[ "approval-1" ]
              ~obligations:[]
              ~runtime_suffix:None
            |> require
          in
          ignore
            (Store.defer_direct_gate_reconciliation
               op_store
               ~now:3.0
               ~operation_id:gate_op_id
               ~execution_digest:claimed.execution_digest
               ~binding
               ~diagnostic:"unconfirmed checkpoint retained in sqlite"
             |> ok);
          ignore
            (Store.submit
               op_store
               ~now:4.0
               ~operation_id:batch_leader_id
               ~source
               ~input:batch_leader_input
             |> ok);
          ignore
            (Store.submit
               op_store
               ~now:4.5
               ~operation_id:queued_op_id
               ~source
               ~input:queued_input
             |> ok);
          ignore
            (Store.claim_next
               op_store
               ~now:5.0
               ~batch:(fun head candidates ->
                 match candidates with
                 | _ :: member :: _ ->
                   Ok
                     (Some
                        { Store.members =
                            [ head.operation_id; member.operation_id ]
                        ; input = `Assoc [ "combined", `String "merged input" ]
                        })
                 | [] | [ _ ] -> Alcotest.fail "expected second batch candidate")
             |> ok);
          let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
          Alcotest.(check int)
            "terminal outcome, batch leader original input, member input, and prepared gate checkpoint references are live"
            4
            observed.live_references;
          Alcotest.(check int)
            "no blob is marked as candidate"
            0
            observed.candidates_recorded;
          let swept =
            maintenance_ok
              ~base_path
              ~mode:M.Delete_previous_candidates
          in
          Alcotest.(check int) "no live blob deleted" 0 swept.deleted;
          Alcotest.(check (option string))
            "terminal outcome blob survives"
            (Some "terminal chat operation outcome payload")
            (fetch_ok blob_store ~sha256:terminal_outcome_blob.sha256);
          Alcotest.(check (option string))
            "batch leader original input blob survives"
            (Some "frozen batch leader original input payload")
            (fetch_ok blob_store ~sha256:batch_leader_blob.sha256);
          Alcotest.(check (option string))
            "queued operation blob survives"
            (Some "queued chat operation payload")
            (fetch_ok blob_store ~sha256:queued_blob.sha256);
          Alcotest.(check (option string))
            "prepared gate checkpoint blob survives"
            (Some "prepared gate checkpoint payload")
            (fetch_ok blob_store ~sha256:gate_checkpoint_blob.sha256);
          Store.close op_store |> ok;
          Sys.remove db_path;
          Fs_compat.save_file (db_path ^ "-wal") "\x37\x7f\x06\x82";
          match M.run ~base_path ~board_posts_file ~mode:M.Observe_only with
          | Error (M.Durable_source_parse_failed _) -> ()
          | Error error ->
            Alcotest.failf
              "expected Durable_source_parse_failed for orphan WAL, got: %s"
              (M.error_to_string error)
          | Ok _ ->
            Alcotest.fail "orphan chat-operations WAL without database succeeded"))

let test_maintenance_follows_typed_result_manifest () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let child =
        B.put_durable store ~bytes:"manifest-owned child" ~mime:"text/plain"
      in
      let structured_content =
        `Assoc [ "output_artifact", O.normalized_artifact_ref_to_json child ]
      in
      let manifest_payload =
        O.artifact_manifest_to_json
          ~content:(Yojson.Safe.to_string structured_content)
          ~structured_content
        |> Yojson.Safe.to_string
      in
      let manifest =
        B.put_durable
          store
          ~bytes:manifest_payload
          ~mime:O.artifact_manifest_mime
      in
      let checkpoint =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "keepers/keeper-a/checkpoint.json"
      in
      Fs_compat.mkdir_p (Filename.dirname checkpoint);
      Fs_compat.save_file
        checkpoint
        (Yojson.Safe.to_string
           (`Assoc
             [ ( "tool_result"
               , `String (O.encode_for_agent_core (O.Stored manifest)) ) ]));
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "checkpoint marker roots manifest and child"
        2
        observed.live_references;
      Alcotest.(check int) "manifest graph has no candidates" 0 observed.candidates_recorded;
      let swept =
        maintenance_ok ~base_path ~mode:M.Delete_previous_candidates
      in
      Alcotest.(check int) "manifest graph survives the second pass" 0 swept.deleted;
      Alcotest.(check (option string))
        "manifest-owned child remains readable"
        (Some "manifest-owned child")
        (fetch_ok store ~sha256:child.sha256))

let test_maintenance_rejects_malformed_typed_result_manifest () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let survivor =
        B.put_durable store ~bytes:"survive malformed manifest" ~mime:"text/plain"
      in
      let malformed =
        O.artifact_manifest_to_json
          ~content:"malformed"
          ~structured_content:
            (`Assoc
               [ ( "output_artifact"
                 , `Assoc [ "_blob", `Assoc [ "sha256", `String survivor.sha256 ] ]
                 )
               ])
        |> Yojson.Safe.to_string
      in
      let manifest =
        B.put_durable store ~bytes:malformed ~mime:O.artifact_manifest_mime
      in
      let checkpoint =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "keepers/keeper-a/checkpoint.json"
      in
      Fs_compat.mkdir_p (Filename.dirname checkpoint);
      Fs_compat.save_file
        checkpoint
        (Yojson.Safe.to_string
           (`String (O.encode_for_agent_core (O.Stored manifest))));
      (match M.run ~base_path ~board_posts_file ~mode:M.Delete_previous_candidates with
       | Error (M.Artifact_manifest_invalid { sha256; _ }) ->
         Alcotest.(check string) "exact malformed manifest" manifest.sha256 sha256
       | Error error ->
         Alcotest.failf "unexpected maintenance error: %s" (M.error_to_string error)
       | Ok _ -> Alcotest.fail "malformed typed manifest reached deletion");
      Alcotest.(check (option string))
        "malformed manifest abort preserves unrelated blobs"
        (Some "survive malformed manifest")
        (fetch_ok store ~sha256:survivor.sha256))

let test_maintenance_malformed_normalized_blob_fails_closed () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let reference =
        B.put store ~bytes:"survive malformed normalized ref" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let tool_call_log =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "tool_calls/2026-07/29.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname tool_call_log);
      Fs_compat.save_file
        tool_call_log
        (Yojson.Safe.to_string
           (`Assoc
             [ ( "output"
               , `Assoc
                   [ ( "_blob"
                     , `Assoc [ "sha256", `String reference.sha256 ] )
                   ] )
             ])
         ^ "\n");
      (match M.run ~base_path ~board_posts_file ~mode:M.Delete_previous_candidates with
       | Error
           (M.Malformed_structured_artifact_reference
             { path; line; _ }) ->
         Alcotest.(check string) "exact malformed tool-call log" tool_call_log path;
         Alcotest.(check int) "exact malformed tool-call line" 1 line
       | Error error ->
         Alcotest.failf
           "unexpected normalized-reference error: %s"
           (M.error_to_string error)
       | Ok _ -> Alcotest.fail "malformed normalized reference reached deletion");
      Alcotest.(check (option string))
        "malformed normalized reference retains every blob"
        (Some "survive malformed normalized ref")
        (fetch_ok store ~sha256:reference.sha256))

let test_maintenance_ignores_route_evidence_artifact_schema () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let reference =
        B.put store ~bytes:"schema-safe live artifact" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let tool_call_log =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "tool_calls/2026-08/25.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname tool_call_log);
      let artifact_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "output_artifact"
                  , `Assoc
                      [ "type", `String "object"
                      ; ( "properties"
                        , `Assoc
                            [ ( "_blob"
                              , `Assoc [ "type", `String "object" ] )
                            ] )
                      ] )
                ] )
          ]
      in
      Fs_compat.save_file
        tool_call_log
        (Yojson.Safe.to_string
           (`Assoc
             [ ( "route_evidence"
               , `Assoc
                   [ ( "composable_output"
                     , `Assoc
                         [ "kind", `String "json"
                         ; "schema", artifact_schema
                         ] )
                   ] )
             ; ( "artifact_refs"
               , `List [ O.normalized_artifact_ref_to_json reference ] )
             ])
         ^ "\n");
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "route schema is not an artifact and the durable root remains live"
        1
        observed.live_references;
      Alcotest.(check int)
        "live artifact is not recorded as a deletion candidate"
        0
        observed.candidates_recorded)
;;

let test_maintenance_truncated_normalized_blob_fails_closed () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let reference =
        B.put store ~bytes:"survive truncated normalized ref" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let observed = maintenance_ok ~base_path ~mode:M.Observe_only in
      Alcotest.(check int)
        "unreferenced blob is first recorded"
        1
        observed.candidates_recorded;
      let tool_call_log =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "tool_calls/2026-07/29.jsonl"
      in
      Fs_compat.mkdir_p (Filename.dirname tool_call_log);
      let complete_reference =
        O.normalized_artifact_ref_to_json reference
        |> Yojson.Safe.to_string
      in
      Fs_compat.save_file
        tool_call_log
        ("{\"output\":" ^ complete_reference);
      (match M.run ~base_path ~board_posts_file ~mode:M.Delete_previous_candidates with
       | Error
           (M.Durable_source_parse_failed
             { path; line; _ }) ->
         Alcotest.(check string) "exact truncated tool-call log" tool_call_log path;
         Alcotest.(check int) "exact truncated tool-call line" 1 line
       | Error error ->
         Alcotest.failf
           "unexpected truncated-reference error: %s"
           (M.error_to_string error)
       | Ok _ ->
         Alcotest.fail "truncated normalized reference reached deletion");
      Alcotest.(check (option string))
        "truncated normalized reference retains every blob"
        (Some "survive truncated normalized ref")
        (fetch_ok store ~sha256:reference.sha256))

let test_maintenance_undecodable_rows_preserve_candidate_and_blob () =
  List.iter
    (fun shape ->
      with_temp_dir (fun base_path ->
        let store = B.create ~base_path in
        let payload = "retain this candidate until every source is readable" in
        let reference = B.put_durable store ~bytes:payload ~mime:"text/plain" in
        ignore (maintenance_ok ~base_path ~mode:M.Observe_only);
        let snapshot_path = M.candidate_snapshot_path ~base_path in
        let snapshot () = In_channel.with_open_bin snapshot_path In_channel.input_all in
        let before = snapshot () in
        let marker = O.encode_for_agent_core (O.Stored reference) in
        let incomplete = match shape with
          | `Marker -> "{\"output_ref\":" ^ Yojson.Safe.to_string (`String marker)
          | `Normalized -> "{\"output_artifact\":" ^
              Yojson.Safe.to_string (O.normalized_artifact_ref_to_json reference)
          | `No_reference -> "{\"other\":" in
        let source = Filename.concat (Common.masc_dir_from_base_path ~base_path)
            "tool_calls/2026-10/17.jsonl" in
        Fs_compat.mkdir_p (Filename.dirname source);
        Fs_compat.save_file source ("{\"complete_prior_row\":true}\n" ^ incomplete ^ "\n");
        (match M.run ~base_path ~board_posts_file ~mode:M.Delete_previous_candidates with
         | Error (M.Durable_source_parse_failed { path; line; _ }) ->
           Alcotest.(check string) "exact unreadable source" source path;
           Alcotest.(check int) "exact unreadable row" 2 line
         | Error error -> Alcotest.fail (M.error_to_string error)
         | Ok _ -> Alcotest.fail "unreadable source authorized deletion");
        Alcotest.(check string) "failed scan preserves previous candidates" before (snapshot ());
        Alcotest.(check (option string)) "failed scan preserves candidate bytes"
          (Some payload) (fetch_ok store ~sha256:reference.sha256);
        Fs_compat.save_file source (Yojson.Safe.to_string
          (`Assoc ["output_ref", `String marker]) ^ "\n");
        let repaired = maintenance_ok ~base_path ~mode:M.Delete_previous_candidates in
        Alcotest.(check int) "readable source roots the exact reference" 1 repaired.live_references;
        Alcotest.(check int) "repair does not delete the referenced candidate" 0 repaired.deleted))
    [ `Marker; `Normalized; `No_reference ]

let test_maintenance_accepts_canonical_marker_and_blank_rows () =
  with_temp_dir (fun base_path ->
    let store = B.create ~base_path in
    let reference = B.put_durable store ~bytes:"canonical raw marker row" ~mime:"text/plain" in
    let source = Filename.concat (Common.masc_dir_from_base_path ~base_path)
        "gate/reference.jsonl" in
    Fs_compat.mkdir_p (Filename.dirname source);
    Fs_compat.save_file source
      ("\n\t\n" ^ O.encode_for_agent_core (O.Stored reference) ^ "\n\n{\"other\":true}\n");
    let report = maintenance_ok ~base_path ~mode:M.Delete_previous_candidates in
    Alcotest.(check int) "canonical marker remains an authoritative reference" 1 report.live_references;
    Alcotest.(check int) "blank rows do not authorize deletion" 0 report.deleted)

let test_maintenance_unlink_failure_is_typed () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let sha256 = String.make 64 'a' in
      let shard_dir =
        Filename.concat (B.root_dir store) (String.sub sha256 0 2)
      in
      Fs_compat.mkdir_p shard_dir;
      Unix.mkdir (Filename.concat shard_dir sha256) 0o755;
      ignore (maintenance_ok ~base_path ~mode:M.Observe_only);
      match M.run ~base_path ~board_posts_file ~mode:M.Delete_previous_candidates with
      | Error
          (M.Blob_delete_failed
            { Tool_blob_store.sha256 = actual; _ }) ->
        Alcotest.(check string) "exact failed blob" sha256 actual
      | Error error ->
        Alcotest.failf
          "unexpected unlink error: %s"
          (M.error_to_string error)
      | Ok _ -> Alcotest.fail "unlink failure was silently skipped")

let test_maintenance_rejects_symbolic_link_shard () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      Fs_compat.mkdir_p (B.root_dir store);
      let outside = Filename.concat base_path "outside-blobs" in
      Unix.mkdir outside 0o755;
      Fs_compat.save_file
        (Filename.concat outside (String.make 64 'a'))
        "outside";
      Unix.symlink outside (Filename.concat (B.root_dir store) "aa");
      match M.run ~base_path ~board_posts_file ~mode:M.Observe_only with
      | Error (M.Blob_listing_failed { Tool_blob_store.path; _ }) ->
        Alcotest.(check string)
          "exact symbolic-link shard"
          (Filename.concat (B.root_dir store) "aa")
          path
      | Error error ->
        Alcotest.failf
          "unexpected symbolic-link error: %s"
          (M.error_to_string error)
      | Ok _ -> Alcotest.fail "symbolic-link shard crossed blob ownership")

let test_maintenance_rejects_symbolic_link_durable_source () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"must survive linked source" ~mime:"text/plain"
        |> stored_ref_exn
      in
      let outside = Filename.concat base_path "outside-consumer.json" in
      Fs_compat.save_file
        outside
        (Yojson.Safe.to_string
           (`Assoc
             [ "output_ref", `String (O.encode_for_agent_core (O.Stored blob)) ]));
      let linked_source =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "messages/linked-consumer.json"
      in
      Fs_compat.mkdir_p (Filename.dirname linked_source);
      Unix.symlink outside linked_source;
      (match M.run ~base_path ~board_posts_file ~mode:M.Observe_only with
       | Error (M.Durable_source_stat_failed { path; _ }) ->
         Alcotest.(check string) "exact linked source" linked_source path
       | Error error ->
         Alcotest.failf
           "unexpected linked-source error: %s"
           (M.error_to_string error)
       | Ok _ -> Alcotest.fail "symbolic-link source was silently skipped");
      Alcotest.(check (option string))
        "blob retained when source ownership is ambiguous"
        (Some "must survive linked source")
        (fetch_ok store ~sha256:blob.sha256))

let test_maintenance_rejects_symbolic_link_candidate_snapshot () =
  with_temp_dir (fun base_path ->
      let store = B.create ~base_path in
      let blob =
        B.put store ~bytes:"must survive linked snapshot" ~mime:"text/plain"
        |> stored_ref_exn
      in
      ignore (maintenance_ok ~base_path ~mode:M.Observe_only);
      let candidate_path = M.candidate_snapshot_path ~base_path in
      let outside = Filename.concat base_path "outside-candidates.json" in
      Fs_compat.save_file
        outside
        (Yojson.Safe.to_string
           (`Assoc
             [ "schema_version", `Int 1
             ; "unreferenced_candidates", `List [ `String blob.sha256 ]
             ]));
      Sys.remove candidate_path;
      Unix.symlink outside candidate_path;
      (match M.run ~base_path ~board_posts_file ~mode:M.Delete_previous_candidates with
       | Error (M.Candidate_snapshot_read_failed { path; _ }) ->
         Alcotest.(check string) "exact linked snapshot" candidate_path path
       | Error error ->
         Alcotest.failf
           "unexpected linked-snapshot error: %s"
           (M.error_to_string error)
       | Ok _ -> Alcotest.fail "symbolic-link candidate snapshot reached deletion");
      Alcotest.(check (option string))
        "blob retained when candidate snapshot ownership is ambiguous"
        (Some "must survive linked snapshot")
        (fetch_ok store ~sha256:blob.sha256))

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
          Alcotest.test_case "stored" `Quick test_stored_roundtrip;
          Alcotest.test_case "trailing bytes after the marker are rejected"
            `Quick test_trailing_bytes_after_the_marker_are_rejected;
          Alcotest.test_case
            "normalized artifact reference"
            `Quick
            test_normalized_artifact_ref_roundtrip;
          Alcotest.test_case
            "encoded marker stays under externalization threshold"
            `Quick
            test_encoded_marker_stays_under_externalization_threshold;
          Alcotest.test_case "non-marker = Not_marker" `Quick
            test_decode_non_marker;
          Alcotest.test_case "malformed = Invalid_marker" `Quick
            test_decode_malformed_marker;
        ] );
      ( "blob store basic",
        [
          Alcotest.test_case "put returns Stored" `Quick
            test_put_returns_stored;
          Alcotest.test_case "put then fetch" `Quick test_put_then_fetch;
          Alcotest.test_case "bounded fetch rejects oversized real blob" `Quick
            test_fetch_bounded_rejects_large_real_blob;
          Alcotest.test_case "binary previews preserve UTF-8 and stored bytes" `Quick
            test_binary_previews_are_utf8_without_changing_stored_bytes;
          Alcotest.test_case "put then fetch bounded ranges" `Quick
            test_put_then_fetch_bounded_ranges;
          Alcotest.test_case "changed range snapshot revalidates digest" `Quick
            test_fetch_range_revalidates_changed_snapshot;
          Alcotest.test_case "fetch range miss = None without content read" `Quick
            test_fetch_range_miss_returns_none_fast;
          Alcotest.test_case "cold fetch range validates without materialising" `Quick
            test_fetch_range_cold_validates_without_materialising;
          Alcotest.test_case "cancelled queued cold range leaves cache empty" `Quick
            test_cancel_queued_cold_range_read_leaves_cache_empty;
          Alcotest.test_case "cold fetch range returns only bytes it hashed" `Quick
            test_fetch_range_cold_returns_only_bytes_it_hashed;
          Alcotest.test_case "range digest window is a slice of the hashed bytes" `Quick
            test_range_with_sha256_window_is_a_slice_of_the_hashed_bytes;
          Alcotest.test_case "fetch miss = None" `Quick test_fetch_miss;
          Alcotest.test_case "idempotent put" `Quick test_idempotent_put;
          Alcotest.test_case "put writes an address again only after fetch finds it gone" `Quick
            test_put_writes_an_address_again_only_after_fetch_finds_it_gone;
          Alcotest.test_case "a range read that finds the blob gone lets the next put write it" `Quick
            test_a_range_read_that_finds_the_blob_gone_lets_the_next_put_write_it;
          Alcotest.test_case "a read error at the blob path lets the next put replace it" `Quick
            test_a_read_error_at_the_blob_path_lets_the_next_put_replace_it;
          Alcotest.test_case "a durable put does not let a later put skip its write" `Quick
            test_a_durable_put_does_not_let_a_later_put_skip_its_write;
          Alcotest.test_case "sharding layout" `Quick test_sharding_layout;
        ] );
      ( "gc",
        [
          Alcotest.test_case
            "maintenance keeps live and deletes stable dead after restart"
            `Quick
            test_maintenance_keeps_live_and_deletes_stable_dead_after_restart;
          Alcotest.test_case
            "maintenance keeps Board attachment artifact"
            `Quick
            test_maintenance_keeps_board_attachment_reference;
          Alcotest.test_case
            "maintenance malformed reference fails closed"
            `Quick
            test_maintenance_malformed_reference_fails_closed;
          Alcotest.test_case
            "maintenance noncanonical reference fails closed"
            `Quick
            test_maintenance_noncanonical_reference_fails_closed;
          Alcotest.test_case
            "maintenance ignores marker embedded in prose"
            `Quick
            test_maintenance_ignores_marker_embedded_in_prose;
          Alcotest.test_case "maintenance keeps prepared Lane Broadcast artifacts" `Quick
            test_maintenance_keeps_prepared_lane_broadcast;
          Alcotest.test_case
            "maintenance keeps wire-capture reference within retention"
            `Quick
            test_maintenance_keeps_wire_capture_reference_within_retention;
          Alcotest.test_case
            "maintenance ignores repository mirrors"
            `Quick
            test_maintenance_does_not_scan_repository_mirrors;
          Alcotest.test_case
            "maintenance ignores trajectory previews"
            `Quick
            test_maintenance_does_not_scan_trajectory_previews;
          Alcotest.test_case
            "maintenance rechecks candidate referenced before startup"
            `Quick
            test_maintenance_rechecks_candidate_referenced_before_startup;
          Alcotest.test_case
            "maintenance keeps normalized tool-call blob reference"
            `Quick
            test_maintenance_keeps_normalized_tool_call_blob_reference;
          Alcotest.test_case
            "maintenance skips open tool-call read index and WAL sidecars"
            `Quick
            test_maintenance_skips_open_tool_call_read_index_and_wal_sidecars;
          Alcotest.test_case
            "maintenance skips atomic staging files in scanned directories"
            `Quick
            test_maintenance_skips_atomic_staging_files;
          Alcotest.test_case
            "maintenance reads chat operation store and prepared gate checkpoint"
            `Quick
            test_maintenance_reads_chat_operation_store_and_prepared_gate_checkpoint;
          Alcotest.test_case
            "maintenance follows typed result manifest"
            `Quick
            test_maintenance_follows_typed_result_manifest;
          Alcotest.test_case
            "maintenance rejects malformed typed result manifest"
            `Quick
            test_maintenance_rejects_malformed_typed_result_manifest;
          Alcotest.test_case
            "maintenance malformed normalized blob fails closed"
            `Quick
            test_maintenance_malformed_normalized_blob_fails_closed;
          Alcotest.test_case
            "maintenance ignores route evidence artifact schema"
            `Quick
            test_maintenance_ignores_route_evidence_artifact_schema;
          Alcotest.test_case
            "maintenance truncated normalized blob fails closed"
            `Quick
            test_maintenance_truncated_normalized_blob_fails_closed;
          Alcotest.test_case
            "maintenance undecodable rows preserve candidates and blobs"
            `Quick
            test_maintenance_undecodable_rows_preserve_candidate_and_blob;
          Alcotest.test_case
            "maintenance accepts canonical marker and blank rows"
            `Quick
            test_maintenance_accepts_canonical_marker_and_blank_rows;
          Alcotest.test_case
            "maintenance unlink failure is typed"
            `Quick
            test_maintenance_unlink_failure_is_typed;
          Alcotest.test_case
            "maintenance rejects symbolic-link shard"
            `Quick
            test_maintenance_rejects_symbolic_link_shard;
          Alcotest.test_case
            "maintenance rejects symbolic-link durable source"
            `Quick
            test_maintenance_rejects_symbolic_link_durable_source;
          Alcotest.test_case
            "maintenance rejects symbolic-link candidate snapshot"
            `Quick
            test_maintenance_rejects_symbolic_link_candidate_snapshot;
        ] );
      ( "atomicity",
        [
          Alcotest.test_case "durable recall reuse and repair" `Quick
            test_durable_reuse_revalidates_without_rewriting;
          Alcotest.test_case "ordinary put is not durable reuse evidence" `Quick
            test_ordinary_put_does_not_establish_durable_reuse;
          Alcotest.test_case "repeated put no dup" `Quick
            test_repeated_put_no_dup;
          Alcotest.test_case "spaced mime is refused at construction" `Quick
            test_spaced_mime_is_refused_at_construction;
          Alcotest.test_case "parameterised mime round-trips without a space"
            `Quick test_parameterised_mime_roundtrips_without_a_space;
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
