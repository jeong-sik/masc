open Printf

(* [b64url s] is [s] encoded as base64url with no trailing padding. JWT
   header/payload/signature segments use this alphabet (RFC 7515 §2,
   RFC 4648 §5) rather than the standard base64 alphabet. *)
let b64url s = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

(* exp = now + 9 min. GitHub rejects a JWT whose exp exceeds iat by more than
   10 min, so we stay one minute under the ceiling. *)
let exp_window_seconds = 540

(* GitHub recommends setting [iat] in the past to tolerate small clock drift.
   With [exp = now + exp_window_seconds], this keeps [exp - iat] at the
   documented 10-minute ceiling. *)
let iat_clock_skew_seconds = 60

let signing_input ~app_id ~iat ~exp =
  let header = `Assoc [ ("alg", `String "RS256"); ("typ", `String "JWT") ] in
  let payload =
    `Assoc [ ("iss", `String app_id); ("iat", `Int iat); ("exp", `Int exp) ]
  in
  b64url (Yojson.Safe.to_string header) ^ "." ^ b64url (Yojson.Safe.to_string payload)
;;

let sign ~app_id ~pem ~now () =
  match X509.Private_key.decode_pem pem with
  | Error (`Msg m) -> Error ("keeper_github_app_jwt: PEM decode failed: " ^ m)
  | Ok (`RSA priv) ->
    let iat = now - iat_clock_skew_seconds in
    let exp = now + exp_window_seconds in
    let input = signing_input ~app_id ~iat ~exp in
    (* RS256 = RSASSA-PKCS1-v1_5 with SHA-256. [Rsa.PKCS1.sign] computes the
       SHA-256 digest, ASN.1 digest-info wraps it, and PKCS#1 v1.5 padding is
       applied before the RSA transform. We hand it the raw [Message]; the
       digest is computed internally. *)
    (try
       let signature =
         Mirage_crypto_pk.Rsa.PKCS1.sign ~hash:`SHA256 ~key:priv (`Message input)
       in
       Ok (input ^ "." ^ b64url signature)
     with
     | Mirage_crypto_pk.Rsa.Insufficient_key ->
       Error "keeper_github_app_jwt: RSA key too small for SHA-256 (need >= 2048 bits)"
     | Invalid_argument msg ->
       Error (sprintf "keeper_github_app_jwt: sign failed: %s" msg))
  | Ok _ -> Error "keeper_github_app_jwt: PEM is not an RSA private key"
;;
