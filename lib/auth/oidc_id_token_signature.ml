(* HIGH-RISK-UNREVIEWED: decides whether an OIDC ID token was signed by a key
   the identity provider published. A wrong answer here logs someone in as a
   person who never authenticated. *)

type error =
  | Malformed_token
  | Malformed_jwks
  | Algorithm_not_allowed
  | Unsupported_critical_header
  | Missing_key_id
  | Unknown_key_id
  | Key_not_rs256
  | Invalid_signature
  | Invalid_expiry
  | Expired

let error_to_string = function
  | Malformed_token -> "malformed_token"
  | Malformed_jwks -> "malformed_jwks"
  | Algorithm_not_allowed -> "algorithm_not_allowed"
  | Unsupported_critical_header -> "unsupported_critical_header"
  | Missing_key_id -> "missing_key_id"
  | Unknown_key_id -> "unknown_key_id"
  | Key_not_rs256 -> "key_not_rs256"
  | Invalid_signature -> "invalid_signature"
  | Invalid_expiry -> "invalid_expiry"
  | Expired -> "expired"
;;

let ( let* ) = Result.bind

let is_rs256 (alg : Jose.Jwa.alg) =
  match alg with
  | `RS256 -> true
  | `HS256 | `ES256 | `ES384 | `ES512 | `EdDSA | `Ed25519 | `RSA_OAEP | `RSA1_5 | `None
  | `Unsupported _ -> false
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
   trailing "=", ignores a dangling last character, and ignores nonzero padding
   bits, so one token has many spellings. RFC 7515 section 2 allows one: the
   unpadded base64url encoding of the bytes. A segment is canonical when
   encoding what it decodes to gives the segment back. A token in JSON form,
   which jose reads when the text starts with '{', has characters outside the
   alphabet and is not canonical. *)
let is_canonical_segment segment =
  match base64url_decode segment with
  | Ok bytes -> String.equal (base64url_encode bytes) segment
  | Error (`Msg _) -> false
;;

let is_canonical token = List.for_all is_canonical_segment (String.split_on_char '.' token)

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

let is_rsa key =
  match Jose.Jwk.get_kty key with
  | `RSA -> true
  | `oct | `EC | `OKP | `Unsupported _ -> false
;;

let declares_rs256 key = Option.fold ~none:false ~some:is_rs256 (Jose.Jwk.get_alg key)

(* jose fills [use] in from [alg] when only [alg] is given, so a key that
   declares RS256 has a [use] here. [Jwk] has no accessor for it, but the JSON
   form of the key carries it. *)
let declares_signature_use key =
  match Yojson.Safe.Util.member "use" (Jose.Jwk.to_pub_json key) with
  | `String "sig" -> true
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> false
  | exception Yojson.Safe.Util.Type_error _ -> false
;;

(* jose verifies with whatever kind of key the JWKS names, so an HMAC key would
   verify an RS256 header. It takes the hash from the key's own [alg], and a key
   with none accepts SHA-256, SHA-384 and SHA-512 under an RS256 header. It
   also ignores [use] once [alg] is given, so an entry with alg RS256 and use
   enc verifies. Requiring an RSA key that says RS256 and [use] = [sig] closes
   all three and leaves SHA-256 as the one hash. jose fills in [alg] from [use]
   when only that is given. *)
let require_rs256_rsa_key key =
  if is_rsa key && declares_rs256 key && declares_signature_use key
  then Ok ()
  else Error Key_not_rs256
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

let check_signature key jwt =
  let* checked = guard Invalid_signature (fun () -> Jose.Jwt.validate_signature ~jwk:key jwt) in
  Result.map_error (fun _ -> Invalid_signature) checked
;;

let verify ~jwks ~now token =
  let* () = if is_canonical token then Ok () else Error Malformed_token in
  let* jwt = parse_token token in
  let header = jwt.Jose.Jwt.header in
  let* () =
    if is_rs256 header.Jose.Header.alg then Ok () else Error Algorithm_not_allowed
  in
  let* () = if has_critical_header header then Error Unsupported_critical_header else Ok () in
  let* kid = Option.to_result ~none:Missing_key_id header.Jose.Header.kid in
  let* jwks = parse_jwks jwks in
  let* key = Option.to_result ~none:Unknown_key_id (Jose.Jwks.find_key jwks kid) in
  let* () = require_rs256_rsa_key key in
  let* verified = check_signature key jwt in
  let payload = verified.Jose.Jwt.payload in
  let* () = check_expiry ~now payload in
  Ok payload
;;
