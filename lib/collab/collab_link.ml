type capability = View | Control

type room = {
  id : string;
  key : string;
  write_token : string;
}

type parse_error =
  | Missing_separator
  | Invalid_room_id
  | Invalid_secret
  | Invalid_secret_length of int
  | Missing_fragment

type parsed = {
  id : string;
  key : string;
  capability : capability;
  write_token : string option;
}

let room_bytes = 16
let key_bytes = 32
let write_token_bytes = 16
let control_secret_bytes = key_bytes + write_token_bytes

let generate () =
  Crypto_rng.ensure_default ();
  {
    id = Crypto_rng.generate room_bytes;
    key = Crypto_rng.generate key_bytes;
    write_token = Crypto_rng.generate write_token_bytes;
  }
;;

let b64_encode s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s
;;

let b64_decode s = Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let format_link room = function
  | View -> b64_encode room.id ^ "." ^ b64_encode room.key
  | Control ->
    b64_encode room.id ^ "." ^ b64_encode (room.key ^ room.write_token)
;;

let format_web_link ~base room cap = base ^ "/#" ^ format_link room cap

let ( let* ) = Result.bind

let decode_part ~err s =
  match b64_decode s with
  | Ok v -> Ok v
  | Error (`Msg _) -> Error err
;;

let parse_secret ~id secret =
  let len = String.length secret in
  if len = key_bytes
  then Ok { id; key = secret; capability = View; write_token = None }
  else if len = control_secret_bytes
  then (
    let key = String.sub secret 0 key_bytes in
    let token = String.sub secret key_bytes write_token_bytes in
    Ok { id; key; capability = Control; write_token = Some token })
  else Error (Invalid_secret_length len)
;;

let parse_link s =
  match String.split_on_char '.' s with
  | [ room_b64; secret_b64 ] ->
    let* id = decode_part ~err:Invalid_room_id room_b64 in
    if String.length id <> room_bytes
    then Error Invalid_room_id
    else (
      let* secret = decode_part ~err:Invalid_secret secret_b64 in
      parse_secret ~id secret)
  | [] | [ _ ] | _ :: _ :: _ :: _ -> Error Missing_separator
;;

let parse_web_link s =
  match String.rindex_opt s '#' with
  | None -> Error Missing_fragment
  | Some i ->
    let start = i + 1 in
    parse_link (String.sub s start (String.length s - start))
;;
