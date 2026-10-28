(* Signature and expiry checks of OIDC ID tokens against fixed vectors.

   test/oidc_id_token_vectors.ml holds the JWKS documents and the tokens. They
   were made by scripts/gen-oidc-test-vectors.py, which signs with openssl and
   then checks every token with a second verifier written in plain Python. The
   remarks below about who signed what were checked that way, not assumed. The
   private keys were thrown away. No network and no clock: [now] is fixed. *)

module V = Oidc_id_token_vectors
module Verify = Oidc_id_token_signature

(* 2026-10-28T00:00:00Z, the instant the generator treats as now. *)
let now =
  match Ptime.of_float_s 1793145600. with
  | Some instant -> instant
  | None -> failwith "the fixed instant is representable"
;;

let subject payload =
  Option.value
    ~default:"no-subject"
    (Yojson.Safe.Util.to_string_option (Yojson.Safe.Util.member "sub" payload))
;;

let outcome ~jwks token =
  match Verify.verify_signature_and_expiry ~jwks ~now token with
  | Ok payload -> "ok:" ^ subject payload
  | Error error -> Verify.error_to_string error
;;

(* Each case is a label, the JWKS text, the token, and the outcome. *)

let accepted =
  [ "the first listed key signs", V.jwks_both, V.token_valid_key_1, "ok:user-1"
  ; "the second listed key signs", V.jwks_both, V.token_valid_key_2, "ok:user-2"
  ; ( "other kinds of key in the same set do not matter"
    , V.jwks_with_other_kinds
    , V.token_valid_key_1
    , "ok:user-1" )
  ; (* No [alg] in the entry, only [use] = [sig]. The library reads that as RS256,
       which is what some providers publish. *)
    "a key that says RS256 only through use", V.jwks_key_with_use_only, V.token_valid_key_1, "ok:user-1"
  ; (* No [use], only [alg] RS256. The library fills [use] in as [sig]. *)
    "a key that says RS256 without use", V.jwks_key_with_alg_only, V.token_valid_key_1, "ok:user-1"
  ]
;;

(* [exp] is read against [now] = 2026-10-28T00:00:00Z. *)
let expiry =
  [ "expired long ago", V.jwks_both, V.token_expired, "expired"
  ; "expires at this very second", V.jwks_both, V.token_expires_at_now, "expired"
  ; "expires one second later", V.jwks_both, V.token_expires_one_second_after_now, "ok:user-1"
  ; "no exp", V.jwks_both, V.token_without_exp, "invalid_expiry"
  ; "exp is a string", V.jwks_both, V.token_exp_as_string, "invalid_expiry"
  ; "exp is not an integer", V.jwks_both, V.token_exp_as_float, "invalid_expiry"
  ; "payload is JSON but not an object", V.jwks_both, V.token_payload_not_an_object, "invalid_expiry"
  ]
;;

let signature =
  [ "payload changed after signing", V.jwks_both, V.token_tampered, "invalid_signature"
  ; (* The header names the first key, the second key signed. *)
    "signed by another listed key", V.jwks_both, V.token_signed_by_the_other_key, "invalid_signature"
  ; (* The header carries the attacker's own public key under the real [kid]. Only
       the key in the JWKS may verify. *)
    ( "the header brings its own public key"
    , V.jwks_both
    , V.token_embedded_jwk_signed_by_attacker
    , "invalid_signature" )
  ; (* A valid SHA-384 signature under an RS256 header, against a key that says
       RS256. *)
    "SHA-384 under an RS256 key", V.jwks_both, V.token_signed_with_sha384, "invalid_signature"
  ; "empty signature", V.jwks_both, V.token_empty_signature, "invalid_signature"
  ; "truncated signature", V.jwks_both, V.token_truncated_signature, "invalid_signature"
  ; ( "signature with extra bytes"
    , V.jwks_both
    , V.token_signature_with_extra_bytes
    , "invalid_signature" )
  ; (* Right length, so the RSA call is reached. mirage-crypto raises
       Invalid_argument on a zero message, which jose catches in its RSA branch. *)
    "signature of zero bytes", V.jwks_both, V.token_zero_signature, "invalid_signature"
  ; (* 0xFF in every byte is a number above the modulus. *)
    "signature above the modulus", V.jwks_both, V.token_signature_above_modulus, "invalid_signature"
  ]
;;

let header_rules =
  [ "none", V.jwks_both, V.token_alg_none, "algorithm_not_allowed"
  ; (* Signed with HMAC, using the text of the RSA public key as the secret. *)
    ( "HS256 keyed with the public key"
    , V.jwks_both
    , V.token_hs256_with_public_key_as_secret
    , "algorithm_not_allowed" )
  ; (* Signed correctly. The header lists [crit], which no verifier here supports. *)
    "a critical header", V.jwks_both, V.token_with_critical_header, "unsupported_critical_header"
  ]
;;

let key_choice =
  [ "no key has this kid", V.jwks_both, V.token_unknown_kid, "unknown_key_id"
  ; "no kid in the header", V.jwks_both, V.token_without_kid, "missing_key_id"
  ; (* An RS256 header, signed with HMAC by the symmetric key the set lists under
       that kid. Without the key check the library would accept it. *)
    ( "the kid names a symmetric key"
    , V.jwks_with_other_kinds
    , V.token_rs256_header_for_oct_key
    , "key_not_rs256" )
  ; "the kid names an EC key", V.jwks_with_other_kinds, V.token_rs256_header_for_ec_key, "key_not_rs256"
  ; (* Neither [alg] nor [use]: the library would accept any of SHA-256, SHA-384 and
       SHA-512 here, so the key is refused before it is asked. *)
    "a key with neither alg nor use", V.jwks_key_without_alg_and_use, V.token_valid_key_1, "key_not_rs256"
  ; ( "a key with neither alg nor use and a SHA-384 signature"
    , V.jwks_key_without_alg_and_use
    , V.token_signed_with_sha384
    , "key_not_rs256" )
  ; (* [use] enc alone makes the library read the key as RSA-OAEP, which it
       refuses for signatures on its own. *)
    "a key meant for encryption", V.jwks_key_for_encryption, V.token_valid_key_1, "key_not_rs256"
  ; (* [alg] RS256 with [use] enc contradicts itself, and the library verifies
       with it. *)
    ( "a key that says RS256 and is meant for encryption"
    , V.jwks_key_declared_rs256_for_encryption
    , V.token_valid_key_1
    , "key_not_rs256" )
  ; (* [use] is a string RFC 7517 section 4.2 does not define. The library keeps it
       as unsupported, and only [sig] is accepted. *)
    ( "a key that says RS256 and names another use"
    , V.jwks_key_declared_rs256_with_another_use
    , V.token_valid_key_1
    , "key_not_rs256" )
  ; ( "a key that says RS384 and a SHA-384 signature"
    , V.jwks_key_declared_rs384
    , V.token_signed_with_sha384
    , "key_not_rs256" )
  ; (* RS256, [use] = [sig], and the key signed the token. Its modulus is 2047
       bits. Every 2048-bit key above is accepted, so this pins the limit. *)
    ( "a key one bit short of 2048"
    , V.jwks_key_2047_bits
    , V.token_signed_by_2047_bit_key
    , "key_too_short" )
  ]
;;

let malformed_token =
  [ "empty text", V.jwks_both, "", "malformed_token"
  ; "two segments", V.jwks_both, V.token_two_segments, "malformed_token"
  ; "four segments", V.jwks_both, "a.b.c.d", "malformed_token"
  ; "segments that are not base64url", V.jwks_both, "!!!.!!!.!!!", "malformed_token"
  ; "JSON serialization instead of the compact form", V.jwks_both, V.token_flattened_json, "malformed_token"
  ; (* The next five are signed correctly. The library raises on the first four
       instead of returning an error, and returns an error on the fifth. *)
    "payload is not JSON", V.jwks_both, V.token_payload_not_json, "malformed_token"
  ; "header is not JSON", V.jwks_both, V.token_header_not_json, "malformed_token"
  ; "header names an enc the library does not know", V.jwks_both, V.token_unknown_enc, "malformed_token"
  ; ( "header carries an EC key that is not on the curve"
    , V.jwks_both
    , V.token_embedded_ec_jwk_off_the_curve
    , "malformed_token" )
  ; "alg is not a string", V.jwks_both, V.token_alg_not_a_string, "malformed_token"
  ; (* The next three spell the bytes of a valid token in another way. The
       library decodes each to the same signature and payload bytes and accepts
       the token. *)
    "signature with a trailing =", V.jwks_both, V.token_signature_with_padding, "malformed_token"
  ; ( "signature with nonzero padding bits"
    , V.jwks_both
    , V.token_signature_with_nonzero_padding_bits
    , "malformed_token" )
  ; ( "payload with a dangling last character"
    , V.jwks_both
    , V.token_payload_with_dangling_char
    , "malformed_token" )
  ; (* The library finds out only when it checks the signature. *)
    "signature that is not base64url", V.jwks_both, V.token_signature_not_base64url, "malformed_token"
  ; (* The next two are signed correctly. The library takes the first value of a
       repeated name. A reader that takes the last one, as RFC 7515 section 4 and
       RFC 7519 section 4 allow, would read the header as alg none and the payload
       as expired. *)
    "header that repeats alg", V.jwks_both, V.token_header_repeats_alg, "malformed_token"
  ; "payload that repeats exp", V.jwks_both, V.token_payload_repeats_exp, "malformed_token"
  ]
;;

let malformed_jwks =
  [ "empty text", "", V.token_valid_key_1, "malformed_jwks"
  ; "not JSON", "not json", V.token_valid_key_1, "malformed_jwks"
  ; "an array instead of an object", "[]", V.token_valid_key_1, "malformed_jwks"
  ; "no keys member", "{}", V.token_valid_key_1, "malformed_jwks"
  ; "keys is not a list", {|{"keys":3}|}, V.token_valid_key_1, "malformed_jwks"
  ; "an entry that is not an object", {|{"keys":[3]}|}, V.token_valid_key_1, "malformed_jwks"
  ; "an entry without kty", {|{"keys":[{}]}|}, V.token_valid_key_1, "malformed_jwks"
  ; (* The RSA entry in the same set is fine. The library raises on the EC entry,
       so the whole document is refused. *)
    ( "an EC entry that is not on the curve"
    , V.jwks_with_an_ec_key_off_the_curve
    , V.token_valid_key_1
    , "malformed_jwks" )
  ; "no entries", {|{"keys":[]}|}, V.token_valid_key_1, "unknown_key_id"
  ; (* The library drops an entry whose key material it cannot read. *)
    ( "an RSA entry without key material"
    , {|{"keys":[{"kty":"RSA","kid":"test-key-1"}]}|}
    , V.token_valid_key_1
    , "unknown_key_id" )
  ]
;;

let every_case =
  List.concat
    [ accepted; expiry; signature; header_rules; key_choice; malformed_token; malformed_jwks ]
;;

let to_tests cases =
  List.map
    (fun (label, jwks, token, expected) ->
      Alcotest.test_case label `Quick (fun () ->
        Alcotest.(check string) label expected (outcome ~jwks token)))
    cases
;;

(* Every token against every JWKS text above. Whatever the pair is,
   [verify_signature_and_expiry] returns an outcome. An exception would fail the
   test. *)
let never_raises () =
  let distinct select = List.sort_uniq String.compare (List.map select every_case) in
  let tokens = distinct (fun (_, _, token, _) -> token) in
  let keysets = distinct (fun (_, jwks, _, _) -> jwks) in
  List.iter
    (fun token ->
      List.iter
        (fun jwks ->
          Alcotest.(check bool) "returns an outcome" true (String.length (outcome ~jwks token) > 0))
        keysets)
    tokens
;;

let () =
  Alcotest.run
    "oidc_id_token_signature"
    [ "accepted", to_tests accepted
    ; "expiry", to_tests expiry
    ; "signature", to_tests signature
    ; "header rules", to_tests header_rules
    ; "key choice", to_tests key_choice
    ; "malformed token", to_tests malformed_token
    ; "malformed jwks", to_tests malformed_jwks
    ; "totality", [ Alcotest.test_case "never raises" `Quick never_raises ]
    ]
;;
