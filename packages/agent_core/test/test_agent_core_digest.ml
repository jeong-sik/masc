(* The sliced hashes must give the digests of the published test vectors:
   FIPS 180-4 for SHA-256 and SHA-1, RFC 1321 for MD5. The million-'a' vector
   spans 16 slices, so a slice fed twice, skipped or cut short changes it. *)

let million_a = String.make 1_000_000 'a'

let sha256_hex s = Agent_core_sha256.(to_hex (digest_string s))

let hex_of_raw raw =
  String.concat "" (List.init (String.length raw) (fun i -> Printf.sprintf "%02x" (Char.code raw.[i])))

let check_hex name expected actual = Alcotest.(check string) name expected actual

let test_sha256_vectors () =
  check_hex "empty" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" (sha256_hex "");
  check_hex "abc" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" (sha256_hex "abc");
  check_hex "million a" "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    (sha256_hex million_a)

let test_sha256_feeding () =
  let whole = sha256_hex million_a in
  let split = String.length million_a / 3 in
  let fed =
    Agent_core_sha256.(
      to_hex (get (feed_string (feed_string empty ~off:0 ~len:split million_a) ~off:split million_a)))
  in
  check_hex "two feeds of one buffer" whole fed;
  let bytes = Bytes.of_string million_a in
  check_hex "bytes" whole Agent_core_sha256.(to_hex (get (feed_bytes empty bytes)));
  check_hex "range" (sha256_hex "abc") Agent_core_sha256.(to_hex (digest_string ~off:1 ~len:3 "xabcx"));
  let pieces = [ "a"; String.make Agent_core_sha256.slice_bytes 'b'; ""; "c" ] in
  check_hex "iterator" (sha256_hex (String.concat "" pieces))
    Agent_core_sha256.(to_hex (digesti_string (fun f -> List.iter f pieces)))

let test_sha256_slice_edges () =
  let n = Agent_core_sha256.slice_bytes in
  List.iter
    (fun length ->
       let s = String.init length (fun i -> Char.chr (i land 0xff)) in
       let one_byte_feeds =
         let ctx = ref Agent_core_sha256.empty in
         String.iteri (fun i _ -> ctx := Agent_core_sha256.feed_string !ctx ~off:i ~len:1 s) s;
         Agent_core_sha256.(to_hex (get !ctx))
       in
       check_hex (Printf.sprintf "%d bytes" length) one_byte_feeds (sha256_hex s))
    [ n - 1; n; n + 1; (2 * n) + 7 ]

let test_sha256_rejects_ranges () =
  let refuses name f =
    match f () with
    | (_ : Agent_core_sha256.t) -> Alcotest.failf "%s: accepted an invalid range" name
    | exception Invalid_argument _ -> ()
  in
  refuses "negative off" (fun () -> Agent_core_sha256.digest_string ~off:(-1) "abc");
  refuses "negative len" (fun () -> Agent_core_sha256.digest_string ~len:(-1) "abc");
  refuses "past the end" (fun () -> Agent_core_sha256.digest_string ~off:2 ~len:2 "abc");
  refuses "bytes past the end" (fun () ->
    Agent_core_sha256.(get (feed_bytes empty ~off:4 (Bytes.of_string "abc"))))

let test_sha256_hex_round_trip () =
  let digest = Agent_core_sha256.digest_string "abc" in
  match Agent_core_sha256.consistent_of_hex_opt (Agent_core_sha256.to_hex digest) with
  | Some parsed -> Alcotest.(check bool) "parsed equals" true (Agent_core_sha256.equal parsed digest)
  | None -> Alcotest.fail "hex did not parse"

let md5_hex s = Agent_core_md5.(to_hex (feed_string empty s))

let test_md5_vectors () =
  check_hex "empty" "d41d8cd98f00b204e9800998ecf8427e" (md5_hex "");
  check_hex "abc" "900150983cd24fb0d6963f7d28e17f72" (md5_hex "abc");
  check_hex "million a" "7707d6ae4e027c70eea2a935c2296f21" (md5_hex million_a);
  check_hex "two feeds" (md5_hex "abc") Agent_core_md5.(to_hex (feed_string (feed_string empty "a") "bc"))

let test_sha1_vectors () =
  let hex s = hex_of_raw (Agent_core_sha1.raw_digest_string s) in
  check_hex "abc" "a9993e364706816aba3e25717850c26c9cd0d89d" (hex "abc");
  check_hex "million a" "34aa973cd4c4daa4f61eeb2bdbad27316534016f" (hex million_a)

let () =
  Alcotest.run "agent_core_digest"
    [ ( "sha256",
        [ Alcotest.test_case "test vectors" `Quick test_sha256_vectors;
          Alcotest.test_case "feeding" `Quick test_sha256_feeding;
          Alcotest.test_case "slice edges" `Quick test_sha256_slice_edges;
          Alcotest.test_case "invalid ranges" `Quick test_sha256_rejects_ranges;
          Alcotest.test_case "hex round trip" `Quick test_sha256_hex_round_trip ] );
      ("md5", [ Alcotest.test_case "test vectors" `Quick test_md5_vectors ]);
      ("sha1", [ Alcotest.test_case "test vectors" `Quick test_sha1_vectors ]) ]
