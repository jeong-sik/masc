(* HIGH-RISK-UNREVIEWED: decides whether an OIDC ID token was signed by a key
   the identity provider published. A wrong answer here logs someone in as a
   person who never authenticated. *)

type error =
  | Malformed_token
  | Algorithm_not_allowed
  | Unsupported_critical_header
  | Missing_key_id
  | Malformed_jwks
  | Unknown_key_id
  | Key_not_rs256
  | Key_too_short
  | Invalid_signature
  | Invalid_expiry
  | Expired

let error_to_string = function
  | Malformed_token -> "malformed_token"
  | Algorithm_not_allowed -> "algorithm_not_allowed"
  | Unsupported_critical_header -> "unsupported_critical_header"
  | Missing_key_id -> "missing_key_id"
  | Malformed_jwks -> "malformed_jwks"
  | Unknown_key_id -> "unknown_key_id"
  | Key_not_rs256 -> "key_not_rs256"
  | Key_too_short -> "key_too_short"
  | Invalid_signature -> "invalid_signature"
  | Invalid_expiry -> "invalid_expiry"
  | Expired -> "expired"
;;

let ( let* ) = Result.bind

(* RFC 7518 section 3.3: a key used with RS256 must be 2048 bits or longer. *)
let min_rsa_bits = 2048

let is_rs256 (alg : Jose.Jwa.alg) =
  match alg with
  | `RS256 -> true
  | `HS256 | `ES256 | `ES384 | `ES512 | `EdDSA | `Ed25519 | `RSA_OAEP | `RSA1_5 | `None
  | `Unsupported _ -> false
;;

let is_signature_use (use : Jose.Jwk.use) =
  match use with
  | `Sig -> true
  | `Enc | `Unsupported _ -> false
;;

(* RFC 7515 4.1.11 makes a token invalid when its [crit] header names an
   extension the verifier does not support. This module supports none. jose
   does not read [crit] and leaves it in [extra]. *)
let has_critical_header (header : Jose.Header.t) = List.mem_assoc "crit" header.extra

let base64url_decode segment =
  Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet segment
;;

let base64url_encode bytes =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet bytes
;;

(* jose decodes a segment with [Base64.decode ~pad:false]. That accepts a
   trailing "=", ignores a dangling last character, and ignores nonzero
   padding bits, so one token has many spellings. RFC 7515 section 2 allows one:
   the unpadded base64url encoding of the bytes. A segment is canonical when
   encoding what it decodes to gives the segment back. The bytes come back for
   a canonical segment. *)
let decode_canonical segment =
  match base64url_decode segment with
  | Ok bytes -> if String.equal (base64url_encode bytes) segment then Some bytes else None
  | Error (`Msg _) -> None
;;

(* RFC 7515 section 4 and RFC 7519 section 4 require the member names of a
   header and of a claims set to be unique. A parser must reject a repeated
   name or keep the last value. jose keeps the first, so a reader that keeps
   the last would see another token. Only the top-level names count: nothing
   here reads deeper. A value that is not an object has no names to repeat. *)
let has_repeated_member (json : Yojson.Safe.t) =
  match json with
  | `Assoc members ->
    let names = List.map fst members in
    List.length (List.sort_uniq String.compare names) <> List.length names
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false
;;

(* The segment is canonical base64url of JSON text, and the JSON does not
   repeat a member name. *)
let is_plain_json_segment segment =
  match decode_canonical segment with
  | None -> false
  | Some text ->
    (match Yojson.Safe.from_string text with
     | json -> not (has_repeated_member json)
     | exception Yojson.Json_error _ -> false)
;;

(* The compact form of RFC 7515 section 7.1: three canonical segments, the
   first two of them JSON without a repeated member name. A token in JSON
   form, which jose reads when the text starts with '{', has characters
   outside the alphabet and is not accepted. *)
let is_plain_compact_token token =
  match String.split_on_char '.' token with
  | [ header; payload; signature ] ->
    is_plain_json_segment header
    && is_plain_json_segment payload
    && Option.is_some (decode_canonical signature)
  | [] | [ _ ] | [ _; _ ] | _ :: _ :: _ :: _ :: _ -> false
;;

(* jose reports some input it cannot read by raising instead of returning an
   error. These are the four it raises, read from the 0.11.0 sources:
   - Yojson.Json_error: a JWKS, a token header, or a token payload that is not
     JSON (Jwks.of_string, Header.of_string, Jwt.of_jws).
   - Yojson.Safe.Util.Type_error: a JWKS without a [keys] list, or an entry
     without a [kty] (Jwks.of_json, Jwk.of_pub_json).
   - Not_found: a token header that names an [enc] it does not know
     (Jwa.enc_of_string).
   - Invalid_argument: an EC key whose point jose cannot read, in a JWKS or in
     the [jwk] field of a token header (Result.get_ok in
     Jwk.make_ESXXX_of_x_y). Also an RSA signature of the wrong shape, which
     jose catches itself in its RSA branch only (Jws.verify_jwk); the same call
     is guarded here so that does not depend on the key kind checked earlier.
   Anything else is a bug and is left to propagate. *)
let guard error read =
  match read () with
  | value -> Ok value
  | exception
      (Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Not_found | Invalid_argument _)
    -> Error error
;;

let parse_token token =
  let* parsed = guard Malformed_token (fun () -> Jose.Jwt.unsafe_of_string token) in
  Result.map_error (fun _ -> Malformed_token) parsed
;;

(* An entry that jose reports as unreadable is dropped from the list, so a
   token naming it ends as Unknown_key_id. An entry that makes jose raise
   refuses the whole document. *)
let parse_jwks text = guard Malformed_jwks (fun () -> Jose.Jwks.of_string text)
;;

(* jose verifies with whatever kind of key the JWKS names, so an HMAC key would
   verify an RS256 header. It takes the hash from the key's own [alg], and a key
   with none accepts SHA-256, SHA-384 and SHA-512 under an RS256 header. It
   also ignores [use] once [alg] is given, so an entry with alg RS256 and use
   enc verifies. Requiring an RSA key that says RS256 and [use] = [sig] closes
   all three and leaves SHA-256 as the one hash. jose fills in [alg] from [use]
   when only that is given, and [use] from [alg]. Matching on the key itself
   keeps these conditions, and the size, in one place, and a new kind of key
   in a later jose release does not compile until it is placed here. *)
let check_key (jwk : Jose.Jwk.public Jose.Jwk.t) =
  match jwk with
  | Jose.Jwk.Rsa_pub { Jose.Jwk.alg; use; key; kty = _; kid = _ } ->
    let says_rs256 = Option.fold ~none:false ~some:is_rs256 alg in
    let says_signature = Option.fold ~none:false ~some:is_signature_use use in
    if not (says_rs256 && says_signature)
    then Error Key_not_rs256
    else if Mirage_crypto_pk.Rsa.pub_bits key < min_rsa_bits
    then Error Key_too_short
    else Ok ()
  | Jose.Jwk.Oct _
  | Jose.Jwk.Es256_pub _
  | Jose.Jwk.Es384_pub _
  | Jose.Jwk.Es512_pub _
  | Jose.Jwk.Ed25519_pub _ -> Error Key_not_rs256
;;

(* jose's own expiry check passes a payload without [exp], or with a null one,
   and raises on an [exp] that is not an integer. This module reads [exp]
   itself and wants an integer. [member] raises on a payload that is not a JSON
   object, which has no [exp] either. *)
let expiry_of payload =
  match Yojson.Safe.Util.member "exp" payload with
  | `Int exp -> Some exp
  | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> None
  | exception Yojson.Safe.Util.Type_error _ -> None
;;

let check_expiry ~now payload =
  match expiry_of payload with
  | None -> Error Invalid_expiry
  | Some exp ->
    (match Ptime.of_float_s (float_of_int exp) with
     | None -> Error Invalid_expiry
     | Some deadline -> if Ptime.is_earlier now ~than:deadline then Ok () else Error Expired)
;;

let check_signature jwk jwt =
  let* checked = guard Invalid_signature (fun () -> Jose.Jwt.validate_signature ~jwk jwt) in
  Result.map_error (fun _ -> Invalid_signature) checked
;;

(* The checks run in the order of the constructors of [error]. [exp] is read
   after the signature, so only a payload some key of the provider signed is
   believed. *)
let verify_signature_and_expiry ~jwks ~now token =
  let* () = if is_plain_compact_token token then Ok () else Error Malformed_token in
  let* jwt = parse_token token in
  let header = jwt.Jose.Jwt.header in
  let* () =
    if is_rs256 header.Jose.Header.alg then Ok () else Error Algorithm_not_allowed
  in
  let* () = if has_critical_header header then Error Unsupported_critical_header else Ok () in
  let* kid = Option.to_result ~none:Missing_key_id header.Jose.Header.kid in
  let* jwks = parse_jwks jwks in
  let* jwk = Option.to_result ~none:Unknown_key_id (Jose.Jwks.find_key jwks kid) in
  let* () = check_key jwk in
  let* verified = check_signature jwk jwt in
  let payload = verified.Jose.Jwt.payload in
  let* () = check_expiry ~now payload in
  Ok payload
;;
