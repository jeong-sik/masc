(** Test suite for compression: the zstd codec and the gzip codec with HTTP
    content negotiation. *)

module Compression_codec = Compression_codec
module Http_response_payload = Masc.Http_response_payload

let test_codec_content_encoding_token () =
  Alcotest.(check string) "content-encoding token"
    "zstd" Compression_codec.content_encoding

let test_codec_compress_large () =
  let large = String.make 1000 'x' in
  match Compression_codec.compress large with
  | Compression_codec.Unchanged _ ->
      Alcotest.fail "expected large repetitive input to compress"
  | Compression_codec.Compressed payload ->
      Alcotest.(check bool) "payload shrinks" true (String.length payload < String.length large)

let test_codec_compress_skips_small () =
  let small = "tiny" in
  match Compression_codec.compress small with
  | Compression_codec.Unchanged payload ->
      Alcotest.(check string) "data unchanged" small payload
  | Compression_codec.Compressed _ ->
      Alcotest.fail "input below min_size must not be compressed"

let test_codec_round_trip () =
  let original = String.init 500 (fun i -> Char.chr (65 + (i mod 26))) in
  match Compression_codec.compress original with
  | Compression_codec.Unchanged _ ->
      Alcotest.fail "expected the 500-byte input to compress"
  | Compression_codec.Compressed payload ->
      (match Compression_codec.decompress ~orig_size:(String.length original) payload with
       | Ok restored ->
           Alcotest.(check string) "decompress restores the input" original restored
       | Error message -> Alcotest.failf "decompress failed: %s" message)

let test_codec_decompress_failure () =
  match Compression_codec.decompress
          ~orig_size:256
          "not-a-valid-zstd-payload"
  with
  | Ok _ -> Alcotest.fail "expected invalid payload to fail decompression"
  | Error _ -> ()

let codec_tests = [
  "content-encoding token", `Quick, test_codec_content_encoding_token;
  "compress large", `Quick, test_codec_compress_large;
  "compress skips small", `Quick, test_codec_compress_skips_small;
  "round trip", `Quick, test_codec_round_trip;
  "decompress failure", `Quick, test_codec_decompress_failure;
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

let test_prepared_snapshot_roundtrips () =
  let prepared = Http_response_payload.prepare sample_json in
  List.iter (fun (accept_encoding, expected_encoding) ->
    let body, headers =
      Http_response_payload.select_prepared ~accept_encoding prepared
    in
    Alcotest.(check (option string)) "negotiated content encoding"
      expected_encoding (List.assoc_opt "content-encoding" headers);
    Alcotest.(check (option string)) "all representations vary"
      (Some "Accept-Encoding") (List.assoc_opt "vary" headers);
    let decoded =
      match expected_encoding with
      | Some "gzip" -> gunzip body
      | Some "zstd" ->
        Compression_codec.decompress ~orig_size:(String.length sample_json) body
      | None -> Ok body
      | Some _ -> Alcotest.fail "unexpected test encoding"
    in
    (match decoded with
     | Ok decoded -> Alcotest.(check string) "complete snapshot" sample_json decoded
     | Error message -> Alcotest.fail message);
    let again, _ = Http_response_payload.select_prepared ~accept_encoding prepared in
    Alcotest.(check bool) "poll reuses the prepared bytes" true (body == again))
    [ Some "gzip", Some "gzip";
      Some "zstd, gzip", Some "zstd";
      Some "gzip;q=0, zstd;q=0", None;
      None, None ];
  let tiny = Http_response_payload.prepare "{}" in
  let body, headers =
    Http_response_payload.select_prepared ~accept_encoding:(Some "gzip") tiny
  in
  Alcotest.(check string) "small snapshot remains identity" "{}" body;
  Alcotest.(check (option string)) "no false gzip header" None
    (List.assoc_opt "content-encoding" headers)

(* Observational codec profile, not a timing gate or production fixture.
   Alternating level order reduces systematic warm-up/order bias. Sys.time
   measures process CPU consumed during encode; decode and checks are outside. *)
let test_gzip_level_profile () =
  let rows = List.init 700 (fun i ->
    let description = String.concat " " (List.init 12 (fun j ->
      Digest.to_hex (Digest.string (Printf.sprintf "fixture:%d:%d" i j)))) in
    Printf.sprintf
      {|{"id":"task-%d","title":"Synthetic task %d","description":"%s","status":"todo"}|}
      i i description) in
  let source = "[" ^ String.concat "," rows ^ "]" in
  let encode level =
    match Compression_gzip.compress ~level source with
    | Compression_gzip.Compressed payload -> payload
    | Compression_gzip.Unchanged _ -> Alcotest.fail "profile fixture must compress"
  in
  List.iter (fun level -> ignore (encode level)) [1; 4];
  for round = 0 to 11 do
    let levels = if round mod 2 = 0 then [1; 4] else [4; 1] in
    List.iter (fun level ->
      let allocated_before = Gc.allocated_bytes () in
      let started = Sys.time () in
      let payload = encode level in
      let cpu_ms = (Sys.time () -. started) *. 1000. in
      let allocated_bytes = Gc.allocated_bytes () -. allocated_before in
      (match gunzip payload with
       | Ok decoded -> Alcotest.(check string) "profile roundtrip" source decoded
       | Error message -> Alcotest.fail message);
      Printf.printf
        "gzip_profile round=%d level=%d input_bytes=%d output_bytes=%d process_cpu_ms=%.6f allocated_bytes=%.0f\n%!"
        round level (String.length source) (String.length payload) cpu_ms allocated_bytes
    ) levels
  done

let gzip_tests = [
  "level profile preserves bytes", `Quick, test_gzip_level_profile;
  "round trips through a real gunzip", `Quick, test_gzip_round_trips;
  "is deterministic", `Quick, test_gzip_is_deterministic;
  "skips payloads below min_size", `Quick, test_gzip_skips_small_payloads;
  "negotiation table", `Quick, test_negotiation_table;
  "identity still varies", `Quick, test_negotiation_always_varies;
  "prepared snapshots roundtrip and reuse bytes", `Quick, test_prepared_snapshot_roundtrips;
]

(* ===== Test Entry Point ===== *)

let () =
  Alcotest.run "Compression" [
    "Codec", codec_tests;
    "Gzip", gzip_tests;
  ]
