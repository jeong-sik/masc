open Alcotest

let large_sample =
  String.concat "" (List.init 32 (fun _ -> "compression-boundary-sample-"))

let test_codec_roundtrip () =
  match Compression_codec.compress large_sample with
  | Compression_codec.Unchanged _ ->
      fail "expected codec to compress repetitive sample"
  | Compression_codec.Compressed { payload; encoding } ->
      check string "encoding token" "zstd"
        (Compression_codec.content_encoding encoding);
      match Compression_codec.decompress
              ~orig_size:(String.length large_sample)
              ~encoding
              payload
      with
      | Ok decoded -> check string "codec roundtrip" large_sample decoded
      | Error msg -> fail ("codec decompress failed: " ^ msg)

let test_legacy_wrapper_roundtrip () =
  let compressed, used_dict, did_compress = Compression_dict.compress large_sample in
  check bool "compat compresses" true did_compress;
  check bool "simplified path uses standard zstd" false used_dict;
  let decoded =
    Compression_dict.decompress
      ~orig_size:(String.length large_sample)
      ~used_dict
      compressed
  in
  check string "compat roundtrip" large_sample decoded

let test_backend_header_roundtrip () =
  let encoded = Backend_compression.compress_with_header large_sample in
  let decoded = Backend_compression.decompress_auto encoded in
  check string "backend roundtrip" large_sample decoded

let () =
  run "Compression boundary" [
    ("codec", [ test_case "roundtrip" `Quick test_codec_roundtrip ]);
    ("compat", [ test_case "legacy wrapper roundtrip" `Quick test_legacy_wrapper_roundtrip ]);
    ("backend", [ test_case "header roundtrip" `Quick test_backend_header_roundtrip ]);
  ]
