module Gcm = Mirage_crypto.AES.GCM

let iv_bytes = 12
let key_bytes = 32

type key = Gcm.key
type key_error = Invalid_key_length of int

let key_of_secret secret =
  let len = String.length secret in
  if len = key_bytes
  then Ok (Gcm.of_secret secret)
  else Error (Invalid_key_length len)
;;

let seal key plaintext =
  Crypto_rng.ensure_default ();
  let iv = Crypto_rng.generate iv_bytes in
  let ciphered = Gcm.authenticate_encrypt ~key ~nonce:iv plaintext in
  iv ^ ciphered
;;

type open_error =
  | Sealed_too_short
  | Authentication_failed

let open_sealed key sealed =
  let len = String.length sealed in
  if len <= iv_bytes
  then Error Sealed_too_short
  else (
    let iv = String.sub sealed 0 iv_bytes in
    let ciphered = String.sub sealed iv_bytes (len - iv_bytes) in
    match Gcm.authenticate_decrypt ~key ~nonce:iv ciphered with
    | Some plaintext -> Ok plaintext
    | None -> Error Authentication_failed)
;;
