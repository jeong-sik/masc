module Jwt = Masc.Keeper_github_app_jwt

(* base64url decode without padding (RFC 7515 §2). jwt segments are unpadded. *)
let b64url_decode s =
  Base64.decode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet s
;;

(* Direct JSON access — avoids a Yojson.Util variant dependency. *)
let member key = function
  | `Assoc fields -> (match List.assoc_opt key fields with Some v -> v | None -> `Null)
  | _ -> `Null
;;

let as_string = function `String s -> s | _ -> Alcotest.fail "expected JSON string"
let as_int = function `Int i -> i | _ -> Alcotest.fail "expected JSON int"

(* A throwaway 2048-bit RSA key. Rsa.generate costs ~1s, so we mint once and
   reuse across tests via a lazy. 2048 is the minimum GitHub accepts and the
   minimum Rsa.PKCS1.sign requires for SHA-256. *)
let fresh_key =
  lazy
    (let priv = Mirage_crypto_pk.Rsa.generate ~bits:2048 () in
     let pem = X509.Private_key.encode_pem (`RSA priv) in
     (priv, pem))
;;

let test_sign_shape_and_claims () =
  let (priv, pem) = Lazy.force fresh_key in
  let app_id = "123456" in
  let now = 1700000000 in
  match Jwt.sign ~app_id ~pem ~now () with
  | Error e -> Alcotest.failf "sign returned Error: %s" e
  | Ok jwt ->
    let segs = String.split_on_char '.' jwt in
    Alcotest.(check int) "jwt has 3 segments" 3 (List.length segs);
    let header = Yojson.Safe.from_string (b64url_decode (List.nth segs 0)) in
    let payload = Yojson.Safe.from_string (b64url_decode (List.nth segs 1)) in
    Alcotest.(check string)
      "header alg=RS256" "RS256" (as_string (member "alg" header));
    Alcotest.(check string)
      "payload iss=app_id" app_id (as_string (member "iss" payload));
    let iat = as_int (member "iat" payload) in
    let exp = as_int (member "exp" payload) in
    Alcotest.(check int) "iat=now-60s" (now - 60) iat;
    Alcotest.(check int) "exp=now+540s" (now + 540) exp;
    Alcotest.(check int) "exp-iat=600s" 600 (exp - iat);
    (* Self-verify: the third segment is a valid RS256 signature of the
       signing input under the public half of the key. This proves the PEM
       round-trip (X509.Private_key.decode_pem) and the RS256 wiring
       (Rsa.PKCS1.sign) end to end without an external openssl cross-check. *)
    let signing_input = List.nth segs 0 ^ "." ^ List.nth segs 1 in
    let signature = b64url_decode (List.nth segs 2) in
    let pub = Mirage_crypto_pk.Rsa.pub_of_priv priv in
    let verified =
      Mirage_crypto_pk.Rsa.PKCS1.verify
        ~hashp:(fun _ -> true)
        ~key:pub
        ~signature
        (`Message signing_input)
    in
    Alcotest.(check bool) "RS256 self-verify" true verified
;;

let test_non_pem_rejected () =
  (* A non-PEM string cannot decode to an RSA key; sign must return Error
     rather than raising. *)
  (match Jwt.sign ~app_id:"1" ~pem:"not a pem" ~now:0 () with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "sign accepted a non-PEM string")
;;

let () =
  Alcotest.run
    "keeper_github_app_jwt"
    [ ( "shape_and_claims"
      , [ Alcotest.test_case "shape_and_claims" `Slow test_sign_shape_and_claims ] )
    ; ("rejection", [ Alcotest.test_case "non_pem_rejected" `Quick test_non_pem_rejected ])
    ]
;;
