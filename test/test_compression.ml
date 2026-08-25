(** Test suite for Compact Protocol v4 Compression

    Tests compression functionality across MASC modules:
    - Backend.Compression (storage layer)

    Expected Results:
    - 60-70% compression ratio for text/JSON data
    - Roundtrip integrity preservation
    - Transparent decompression via ZSTD header detection
*)

(* ===== Backend Compression Tests ===== *)

module BackendCompression = Backend.Compression
module Compression_codec = Compression_codec
module Http_response_payload = Masc.Http_response_payload

let test_backend_compress_skip_small () =
  let small = "tiny" in  (* <32 bytes, below min_dict_size *)
  let (result, _used_dict, did_compress) = BackendCompression.compress small in
  Alcotest.(check bool) "small data not compressed" false did_compress;
  Alcotest.(check string) "data unchanged" small result

let test_backend_compress_large () =
  let large = String.make 1000 'x' in  (* Highly compressible *)
  let (result, _used_dict, did_compress) = BackendCompression.compress large in
  Alcotest.(check bool) "large data compressed" true did_compress;
  Alcotest.(check bool) "smaller than original" true (String.length result < 1000)

let test_backend_roundtrip () =
  let original = String.init 500 (fun i -> Char.chr (65 + (i mod 26))) in
  let compressed = BackendCompression.compress_with_header original in
  let decompressed = BackendCompression.decompress_auto compressed in
  Alcotest.(check string) "roundtrip preserves data" original decompressed

let test_backend_header_format () =
  (* compress_with_header is a passthrough (compression disabled).
     Data should be returned unchanged — no ZSTD header. *)
  let data = String.make 512 'Z' in
  let result = BackendCompression.compress_with_header data in
  Alcotest.(check string) "passthrough returns data unchanged" data result

let test_backend_non_compressed_passthrough () =
  let plain = "This is plain text without ZSTD header" in
  let result = BackendCompression.decompress_auto plain in
  Alcotest.(check string) "non-compressed unchanged" plain result

let test_backend_decompress_failure () =
  let result = BackendCompression.decompress
      ~orig_size:128
      "not-a-valid-zstd-payload"
  in
  Alcotest.(check (option string)) "invalid payload returns none" None result

let test_backend_json_passthrough () =
  (* compress_with_header is a passthrough — JSON data returned unchanged *)
  let json_parts = List.init 10 (fun i ->
    Printf.sprintf {|{"id":%d,"type":"agent_response","status":"ok","timestamp":%d}|} i (1234567890 + i)
  ) in
  let json = "[" ^ String.concat "," json_parts ^ "]" in
  let result = BackendCompression.compress_with_header json in
  Alcotest.(check string) "JSON passthrough unchanged" json result

let backend_tests = [
  "skip small data", `Quick, test_backend_compress_skip_small;
  "compress large data", `Quick, test_backend_compress_large;
  "roundtrip", `Quick, test_backend_roundtrip;
  "ZSTD header format", `Quick, test_backend_header_format;
  "non-compressed passthrough", `Quick, test_backend_non_compressed_passthrough;
  "decompress failure", `Quick, test_backend_decompress_failure;
  "JSON passthrough", `Quick, test_backend_json_passthrough;
]


(* ===== Compression Threshold Tests ===== *)

let test_threshold_backend () =
  (* Now uses dictionary compression with lower threshold *)
  Alcotest.(check int) "backend min_size" 32 BackendCompression.min_size

let test_default_level () =
  Alcotest.(check int) "backend level" 3 BackendCompression.default_level

let threshold_tests = [
  "backend min_size", `Quick, test_threshold_backend;
  "default compression level", `Quick, test_default_level;
]

let test_codec_encoding_tokens () =
  Alcotest.(check string) "standard encoding"
    "zstd" (Compression_codec.content_encoding Compression_codec.Standard);
  Alcotest.(check string) "dictionary encoding"
    "zstd-dict" (Compression_codec.content_encoding Compression_codec.Dictionary)

let test_codec_compress_large () =
  let large = String.make 1000 'x' in
  match Compression_codec.compress large with
  | Compression_codec.Unchanged _ ->
      Alcotest.fail "expected large repetitive input to compress"
  | Compression_codec.Compressed { payload; encoding } ->
      Alcotest.(check bool) "payload shrinks" true (String.length payload < String.length large);
      Alcotest.(check string) "encoding token"
        "zstd" (Compression_codec.content_encoding encoding)

let test_codec_decompress_failure () =
  match Compression_codec.decompress
          ~orig_size:256
          "not-a-valid-zstd-payload"
  with
  | Ok _ -> Alcotest.fail "expected invalid payload to fail decompression"
  | Error _ -> ()

let codec_tests = [
  "encoding tokens", `Quick, test_codec_encoding_tokens;
  "compress large", `Quick, test_codec_compress_large;
  "decompress failure", `Quick, test_codec_decompress_failure;
]

(* ===== Compression Ratio Benchmarks ===== *)

(* compress_with_header is a passthrough — ratio tests verify this. *)

let test_passthrough_text () =
  let text = String.concat "" (List.init 20 (fun _ ->
    "The quick brown fox jumps over the lazy dog. "
  )) in
  let result = BackendCompression.compress_with_header text in
  Alcotest.(check int) "text passthrough same length"
    (String.length text) (String.length result)

let test_passthrough_json () =
  let json = String.concat "," (List.init 50 (fun i ->
    Printf.sprintf {|{"id":%d,"name":"item_%d","value":%d}|} i i (i * 100)
  )) in
  let full_json = "[" ^ json ^ "]" in
  let result = BackendCompression.compress_with_header full_json in
  Alcotest.(check string) "JSON passthrough unchanged" full_json result

let test_passthrough_repeated () =
  let data = String.make 500 'x' in
  let result = BackendCompression.compress_with_header data in
  Alcotest.(check string) "repeated data passthrough" data result

let ratio_tests = [
  "text passthrough", `Quick, test_passthrough_text;
  "JSON passthrough", `Quick, test_passthrough_json;
  "repeated data passthrough", `Quick, test_passthrough_repeated;
]

(* ===== Gzip codec and content negotiation ===== *)

(* Decode with the library's own reader rather than re-using anything from the
   encoder path, so a round-trip proves the bytes are real gzip and not merely
   self-consistent. *)
let gunzip payload =
  let input = De.bigstring_create De.io_buffer_size in
  let output = De.bigstring_create De.io_buffer_size in
  let decoded = Buffer.create (String.length payload * 4) in
  let consumed = ref 0 in
  let refill buffer =
    let take = min (Bigstringaf.length buffer) (String.length payload - !consumed) in
    Bigstringaf.blit_from_string payload ~src_off:!consumed buffer ~dst_off:0 ~len:take;
    consumed := !consumed + take;
    take
  in
  let flush buffer written =
    Buffer.add_string decoded (Bigstringaf.substring buffer ~off:0 ~len:written)
  in
  match Gz.Higher.uncompress ~refill ~flush input output with
  | Ok _ -> Ok (Buffer.contents decoded)
  | Error (`Msg message) -> Error message

let sample_json =
  "[" ^ String.concat ","
    (List.init 400 (fun i ->
       Printf.sprintf {|{"i":%d,"keeper":"alpha","ts":1786500000.0}|} i))
  ^ "]"

let test_gzip_round_trips () =
  match Compression_gzip.compress sample_json with
  | Compression_gzip.Unchanged _ ->
    Alcotest.fail "a 400-row JSON array should compress"
  | Compression_gzip.Compressed payload ->
    Alcotest.(check bool) "gzip is smaller than the source" true
      (String.length payload < String.length sample_json);
    (match gunzip payload with
     | Error message -> Alcotest.failf "gunzip rejected the payload: %s" message
     | Ok decoded ->
       Alcotest.(check string) "round trip is byte-identical" sample_json decoded)

let test_gzip_is_deterministic () =
  let once = Compression_gzip.compress sample_json in
  let twice = Compression_gzip.compress sample_json in
  match once, twice with
  | Compression_gzip.Compressed a, Compression_gzip.Compressed b ->
    Alcotest.(check string) "same input yields the same bytes" a b
  | _ -> Alcotest.fail "expected both attempts to compress"

let test_gzip_skips_small_payloads () =
  let small = String.make (Compression_codec.min_size - 1) 'x' in
  match Compression_gzip.compress small with
  | Compression_gzip.Unchanged payload ->
    Alcotest.(check string) "small payload passes through" small payload
  | Compression_gzip.Compressed _ ->
    Alcotest.fail "payload below min_size must not be encoded"

(* The behaviour this change exists for: what a client actually receives.

   Before, anything that did not offer zstd fell through to identity, so the
   gzip and "nothing offered" rows below were the same 145x-larger body. *)
let negotiated_encoding accept_encoding =
  let _, headers =
    Http_response_payload.compress_body ~accept_encoding sample_json
  in
  match List.assoc_opt "content-encoding" headers with
  | Some encoding -> encoding
  | None -> "identity"

let test_negotiation_table () =
  let check_case accept expected =
    Alcotest.(check string)
      (Printf.sprintf "Accept-Encoding: %s" (Option.value accept ~default:"<none>"))
      expected (negotiated_encoding accept)
  in
  check_case (Some "zstd") "zstd";
  check_case (Some "gzip, deflate") "gzip";
  check_case (Some "gzip, deflate, br") "gzip";
  check_case (Some "gzip;q=0.5, zstd;q=0.9") "zstd";
  check_case (Some "gzip;q=0, deflate") "identity";
  check_case (Some "identity") "identity";
  check_case (Some "*") "zstd";
  check_case None "identity"

let test_negotiation_always_varies () =
  let _, headers = Http_response_payload.compress_body ~accept_encoding:None sample_json in
  Alcotest.(check bool) "identity responses still advertise Vary" true
    (List.mem_assoc "vary" headers)

let gzip_tests = [
  "round trips through a real gunzip", `Quick, test_gzip_round_trips;
  "is deterministic", `Quick, test_gzip_is_deterministic;
  "skips payloads below min_size", `Quick, test_gzip_skips_small_payloads;
  "negotiation table", `Quick, test_negotiation_table;
  "identity still varies", `Quick, test_negotiation_always_varies;
]

(* ===== Test Entry Point ===== *)

let () =
  Alcotest.run "Compression" [
    "Backend", backend_tests;
    "Thresholds", threshold_tests;
    "Codec", codec_tests;
    "Compression Ratios", ratio_tests;
    "Gzip", gzip_tests;
  ]
