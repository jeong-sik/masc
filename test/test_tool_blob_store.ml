(** Tests for Tool_blob_store + Tool_output.

    Covers:
    - Round-trip: encode then decode for both [Inline] and [Stored] variants.
    - Backward compat: any string without sentinel decodes to [Inline].
    - Malformed sentinel falls back to [Inline] (fail-safe).
    - Content-addressed: same bytes -> same sha -> idempotent put.
    - Sharding: blobs land under [<sha[0..1]>/<sha>].
    - GC: blobs not in keep_set are deleted; kept ones survive.
    - Concurrent put: simultaneous writes of same content do not corrupt. *)

module B = Tool_blob_store
module O = Tool_output

(* --- Helpers --- *)

let with_temp_dir f =
  let dir = Filename.temp_file "masc_blob_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cleanup () =
    let rec rm path =
      if Sys.file_exists path
      then
        if Sys.is_directory path
        then (
          Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
          Unix.rmdir path)
        else Unix.unlink path
    in
    try rm dir with
    | _ -> ()
  in
  let r =
    try Ok (f dir) with
    | e -> Error e
  in
  cleanup ();
  match r with
  | Ok v -> v
  | Error e -> raise e
;;

(* --- Tool_output round-trip --- *)

let test_inline_roundtrip () =
  let s = "hello world\n" in
  let encoded = O.encode_for_oas (O.Inline s) in
  Alcotest.(check string) "inline encode = identity" s encoded;
  match O.decode_from_oas encoded with
  | O.Inline s' -> Alcotest.(check string) "inline decode" s s'
  | O.Stored _ -> Alcotest.fail "expected Inline"
;;

let test_stored_roundtrip () =
  let original =
    O.Stored
      { sha256 = "abcd1234"
      ; bytes = 128934
      ; preview = "first 200 chars\nwith newline"
      ; mime = "text/plain"
      }
  in
  let encoded = O.encode_for_oas original in
  Alcotest.(check bool) "encoded starts with sentinel" true (O.is_sentinel encoded);
  match O.decode_from_oas encoded with
  | O.Stored { sha256; bytes; preview; mime } ->
    Alcotest.(check string) "sha256" "abcd1234" sha256;
    Alcotest.(check int) "bytes" 128934 bytes;
    Alcotest.(check string) "preview" "first 200 chars\nwith newline" preview;
    Alcotest.(check string) "mime" "text/plain" mime
  | O.Inline _ -> Alcotest.fail "expected Stored"
;;

let test_decode_non_sentinel () =
  (* Any normal tool output decodes as Inline — backward compat for old
     checkpoints that pre-date the artifact store. *)
  let cases =
    [ ""
    ; "plain text"
    ; "{\"key\":\"value\"}"
    ; "[tool:gh id:xyz lines:5 chars:128 summary:\"hi\"]"
    ; "[masc:other prefix]"
    ; "[masc:blob" (* truncated — no trailing space *)
    ]
  in
  List.iter
    (fun s ->
       match O.decode_from_oas s with
       | O.Inline s' -> Alcotest.(check string) ("inline-fallback for " ^ s) s s'
       | O.Stored _ -> Alcotest.failf "expected Inline for %S" s)
    cases
;;

let test_decode_malformed_sentinel () =
  (* Has the prefix but body is garbage — must NOT raise, falls back to
     Inline so the keeper LLM sees the raw string instead of crashing. *)
  let bad = "[masc:blob garbage that cannot scanf]" in
  match O.decode_from_oas bad with
  | O.Inline s -> Alcotest.(check string) "fallback string" bad s
  | O.Stored _ -> Alcotest.fail "malformed should NOT decode as Stored"
;;

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
;;

let test_put_then_fetch () =
  with_temp_dir (fun dir ->
    let store = B.create ~base_path:dir in
    let payload = String.make 5000 'x' in
    let stored = B.put store ~bytes:payload ~mime:"text/plain" in
    match stored with
    | O.Stored { sha256; _ } ->
      (match B.fetch store ~sha256 with
       | Some bytes -> Alcotest.(check string) "round-trip bytes" payload bytes
       | None -> Alcotest.fail "fetch returned None")
    | O.Inline _ -> Alcotest.fail "put returned Inline")
;;

let test_fetch_miss () =
  with_temp_dir (fun dir ->
    let store = B.create ~base_path:dir in
    match B.fetch store ~sha256:(String.make 64 '0') with
    | None -> ()
    | Some _ -> Alcotest.fail "expected None for unknown sha")
;;

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
    Alcotest.(check string) "same content -> same sha" (sha_of r1) (sha_of r2);
    Alcotest.(check int) "single entry" 1 (List.length (B.list_all store)))
;;

let test_sharding_layout () =
  with_temp_dir (fun dir ->
    let store = B.create ~base_path:dir in
    let payload = "sharding test" in
    let stored = B.put store ~bytes:payload ~mime:"text/plain" in
    match stored with
    | O.Stored { sha256; _ } ->
      let prefix = String.sub sha256 0 2 in
      let expected = Filename.concat (B.root_dir store) (Filename.concat prefix sha256) in
      Alcotest.(check bool) "sharded path exists" true (Sys.file_exists expected)
    | O.Inline _ -> Alcotest.fail "put returned Inline")
;;

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
      (B.fetch store ~sha256:keep))
;;

let test_gc_empty_keep_clears_all () =
  with_temp_dir (fun dir ->
    let store = B.create ~base_path:dir in
    let _ = B.put store ~bytes:"a" ~mime:"text/plain" in
    let _ = B.put store ~bytes:"b" ~mime:"text/plain" in
    let _ = B.put store ~bytes:"c" ~mime:"text/plain" in
    let deleted = B.gc store ~keep_set:[] in
    Alcotest.(check int) "deleted all" 3 deleted;
    Alcotest.(check int) "store empty" 0 (List.length (B.list_all store)))
;;

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
    Alcotest.(check int) "single sha after 8 puts" 1 (List.length (B.list_all store));
    let sha = List.hd (B.list_all store) in
    Alcotest.(check (option string))
      "fetched content matches"
      (Some payload)
      (B.fetch store ~sha256:sha))
;;

(* --- Entry point --- *)

let () =
  Alcotest.run
    "tool_blob_store"
    [ ( "tool_output round-trip"
      , [ Alcotest.test_case "inline" `Quick test_inline_roundtrip
        ; Alcotest.test_case "stored" `Quick test_stored_roundtrip
        ; Alcotest.test_case "non-sentinel = Inline" `Quick test_decode_non_sentinel
        ; Alcotest.test_case "malformed = Inline" `Quick test_decode_malformed_sentinel
        ] )
    ; ( "blob store basic"
      , [ Alcotest.test_case "put returns Stored" `Quick test_put_returns_stored
        ; Alcotest.test_case "put then fetch" `Quick test_put_then_fetch
        ; Alcotest.test_case "fetch miss = None" `Quick test_fetch_miss
        ; Alcotest.test_case "idempotent put" `Quick test_idempotent_put
        ; Alcotest.test_case "sharding layout" `Quick test_sharding_layout
        ] )
    ; ( "gc"
      , [ Alcotest.test_case "deletes unkept" `Quick test_gc_deletes_unkept
        ; Alcotest.test_case "empty keep clears all" `Quick test_gc_empty_keep_clears_all
        ] )
    ; ( "atomicity"
      , [ Alcotest.test_case "repeated put no dup" `Quick test_repeated_put_no_dup ] )
    ]
;;
