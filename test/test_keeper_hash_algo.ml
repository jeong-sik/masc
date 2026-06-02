(** RFC-0070 Phase 3b-i — tests for [Keeper_hash_algo].

    Pins the closed-variant behaviour: known SHA test vectors,
    output length per algorithm, [of_string] case-insensitivity +
    None on unknown input, [all] completeness for property tests. *)

open Alcotest
open Masc_mcp

let h = Keeper_hash_algo.digest_hex
let hb = Keeper_hash_algo.digest_bytes

(* Known test vectors from NIST FIPS 180-4 / RFC 6234. *)

let test_sha256_empty () =
  (* SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 *)
  check string "SHA-256 empty"
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    (h Keeper_hash_algo.SHA_256 "")

let test_sha256_abc () =
  (* SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad *)
  check string "SHA-256 abc"
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    (h Keeper_hash_algo.SHA_256 "abc")

let test_sha512_empty () =
  (* SHA-512("") =
     cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce
     47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e *)
  check string "SHA-512 empty"
    "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
    (h Keeper_hash_algo.SHA_512 "")

(* Length invariants — important for Container_name truncation in
   Phase 3b-ii (16-byte / 32-hex-char slice). *)

let test_sha256_hex_length () =
  check int "SHA-256 hex = 64" 64
    (String.length (h Keeper_hash_algo.SHA_256 "anything"))

let test_sha512_hex_length () =
  check int "SHA-512 hex = 128" 128
    (String.length (h Keeper_hash_algo.SHA_512 "anything"))

let test_sha256_bytes_length () =
  check int "SHA-256 bytes = 32" 32
    (String.length (hb Keeper_hash_algo.SHA_256 "anything"))

let test_sha512_bytes_length () =
  check int "SHA-512 bytes = 64" 64
    (String.length (hb Keeper_hash_algo.SHA_512 "anything"))

(* Determinism contract — same input ⇒ identical output. *)

let test_determinism () =
  let a = h Keeper_hash_algo.SHA_256 "deterministic input" in
  let b = h Keeper_hash_algo.SHA_256 "deterministic input" in
  check string "SHA-256 deterministic" a b

(* of_string / to_string round-trip. *)

let test_of_string_canonical () =
  check (option (testable Keeper_hash_algo.pp Keeper_hash_algo.equal))
    "sha256 canonical"
    (Some Keeper_hash_algo.SHA_256)
    (Keeper_hash_algo.of_string "sha256")

let test_of_string_case_insensitive () =
  check (option (testable Keeper_hash_algo.pp Keeper_hash_algo.equal))
    "SHA-256 case-insensitive"
    (Some Keeper_hash_algo.SHA_256)
    (Keeper_hash_algo.of_string "SHA-256")

let test_of_string_underscore () =
  check (option (testable Keeper_hash_algo.pp Keeper_hash_algo.equal))
    "sha_512 with underscore"
    (Some Keeper_hash_algo.SHA_512)
    (Keeper_hash_algo.of_string "sha_512")

let test_of_string_unknown_is_none () =
  check (option (testable Keeper_hash_algo.pp Keeper_hash_algo.equal))
    "unknown returns None (no permissive default)"
    None
    (Keeper_hash_algo.of_string "blake3")

let test_to_string_sha256 () =
  check string "to_string sha256" "sha256"
    (Keeper_hash_algo.to_string Keeper_hash_algo.SHA_256)

let test_to_string_sha512 () =
  check string "to_string sha512" "sha512"
    (Keeper_hash_algo.to_string Keeper_hash_algo.SHA_512)

(* [all] completeness — invariant for property tests. *)

let test_all_completeness () =
  check int "all enumerates 2 variants" 2 (List.length Keeper_hash_algo.all)

let () =
  run "Keeper_hash_algo"
    [
      ( "test vectors",
        [
          test_case "SHA-256 empty" `Quick test_sha256_empty;
          test_case "SHA-256 abc" `Quick test_sha256_abc;
          test_case "SHA-512 empty" `Quick test_sha512_empty;
        ] );
      ( "length invariants",
        [
          test_case "SHA-256 hex length" `Quick test_sha256_hex_length;
          test_case "SHA-512 hex length" `Quick test_sha512_hex_length;
          test_case "SHA-256 bytes length" `Quick test_sha256_bytes_length;
          test_case "SHA-512 bytes length" `Quick test_sha512_bytes_length;
        ] );
      ("determinism", [ test_case "SHA-256 same input → same output" `Quick test_determinism ]);
      ( "string forms",
        [
          test_case "of_string canonical" `Quick test_of_string_canonical;
          test_case "of_string case-insensitive" `Quick test_of_string_case_insensitive;
          test_case "of_string with underscore" `Quick test_of_string_underscore;
          test_case "of_string unknown is None" `Quick test_of_string_unknown_is_none;
          test_case "to_string SHA-256" `Quick test_to_string_sha256;
          test_case "to_string SHA-512" `Quick test_to_string_sha512;
        ] );
      ("enumeration", [ test_case "all enumerates 2 variants" `Quick test_all_completeness ]);
    ]
