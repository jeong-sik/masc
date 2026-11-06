open Result.Syntax

type email_key =
  | Id_token_email
  | Id_token_email_claim

type id_token_rejection =
  | Not_a_jwt
  | Claims_not_base64url
  | Claims_not_json_object
  | Issuer_not_google
  | No_email_claim

type rejection =
  | Not_json_object
  | Repeated_account_key
  | No_account_key
  | Both_account_keys
  | Invalid_id_token of id_token_rejection
  | Unreadable_email of email_key
  | Not_email_text of email_key

type undecodable =
  | Not_hex
  | Not_base64

type keychain_rejection =
  | Undecodable of undecodable
  | Keychain_login of rejection

let email_key_to_string = function
  | Id_token_email -> "id_token_email"
  | Id_token_email_claim -> "id_token.email"
;;

let id_token_rejection_to_string = function
  | Not_a_jwt -> "is not a three-segment JWT"
  | Claims_not_base64url -> "claims do not decode as base64url"
  | Claims_not_json_object -> "claims are not a JSON object"
  | Issuer_not_google -> "iss is not a Google issuer"
  | No_email_claim -> "has no email claim"
;;

let rejection_to_string = function
  | Not_json_object -> "not a JSON object"
  | Repeated_account_key -> "id_token or id_token_email appears twice"
  | No_account_key ->
    "names no account: neither id_token (agy 1.2) nor id_token_email (agy 1.5) holds a value"
  | Both_account_keys -> "holds both id_token (agy 1.2) and id_token_email (agy 1.5)"
  | Invalid_id_token problem -> "id_token " ^ id_token_rejection_to_string problem
  | Unreadable_email Id_token_email -> "id_token_email is not a string"
  | Unreadable_email Id_token_email_claim -> "id_token.email repeats or is not a string"
  | Not_email_text key -> email_key_to_string key ^ " is not email text"
;;

let undecodable_to_string = function
  | Not_hex -> "go-keyring-encoded: is not followed by an even count of hex digits"
  | Not_base64 -> "go-keyring-base64: is not followed by padded standard base64"
;;

let keychain_rejection_to_string = function
  | Undecodable problem -> undecodable_to_string problem
  | Keychain_login rejection -> "decoded login " ^ rejection_to_string rejection
;;

type member =
  | Absent
  | Present of Yojson.Safe.t
  | Repeated

let member name fields =
  match List.filter (fun (key, _) -> String.equal key name) fields with
  | [] | [ (_, `Null) ] -> Absent
  | [ (_, value) ] -> Present value
  | _ :: _ :: _ -> Repeated
;;

let email_text key (value : Yojson.Safe.t) =
  match value with
  | `String text ->
    (match Runtime_account_email_text.of_string text with
     | Some email -> Ok email
     | None -> Error (Not_email_text key))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
    Error (Unreadable_email key)
;;

(* Google documents [iss] as one of these two values:
   https://developers.google.com/identity/openid-connect/openid-connect
   Only the claims segment is decoded. *)
let id_token_email (value : Yojson.Safe.t) =
  match value with
  | `String token ->
    let* claims =
      match String.split_on_char '.' token with
      | [ header; payload; signature ] when header <> "" && signature <> "" ->
        (match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet payload with
         | Error _ -> Error (Invalid_id_token Claims_not_base64url)
         | Ok payload ->
           (match Yojson.Safe.from_string payload with
            | `Assoc claims -> Ok claims
            | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
              Error (Invalid_id_token Claims_not_json_object)
            | exception Yojson.Json_error _ -> Error (Invalid_id_token Claims_not_json_object)))
      | _ -> Error (Invalid_id_token Not_a_jwt)
    in
    let* () =
      match member "iss" claims with
      | Present (`String ("accounts.google.com" | "https://accounts.google.com")) -> Ok ()
      | Present _ | Absent | Repeated -> Error (Invalid_id_token Issuer_not_google)
    in
    (match member "email" claims with
     | Present email -> email_text Id_token_email_claim email
     | Absent -> Error (Invalid_id_token No_email_claim)
     | Repeated -> Error (Unreadable_email Id_token_email_claim))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
    Error (Invalid_id_token Not_a_jwt)
;;

(* HIGH-RISK-UNREVIEWED: account continuity reads a credential. A human must
   review which login shapes are admitted and what names the account. *)
let account_email bytes =
  match Yojson.Safe.from_string bytes with
  | `Assoc fields ->
    (match member "id_token" fields, member "id_token_email" fields with
     | Repeated, (Absent | Present _ | Repeated) | (Absent | Present _), Repeated ->
       Error Repeated_account_key
     | Absent, Absent -> Error No_account_key
     | Present _, Present _ -> Error Both_account_keys
     | Present token, Absent -> id_token_email token
     | Absent, Present email -> email_text Id_token_email email)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error Not_json_object
  | exception Yojson.Json_error _ -> Error Not_json_object
;;

(* go-keyring's macOS [Get], read at tag v0.2.8 and master 85eb737c1258 on
   2026-11-06T12:50Z (also tag v0.2.2, the first whose [Set] writes base64):
   https://github.com/zalando/go-keyring/blob/85eb737c1258e4849bfba6456dc0c48228ca8242/keyring_darwin.go#L43-L67
   It applies [strings.TrimSpace], then decodes a [go-keyring-encoded:] value
   as hex and a [go-keyring-base64:] value as standard base64, and returns any
   other value as it is. *)
type keychain_value =
  | Go_keyring_hex of string
  | Go_keyring_base64 of string
  | Unencoded of string

let go_keyring_hex_prefix = "go-keyring-encoded:"
let go_keyring_base64_prefix = "go-keyring-base64:"

(* The ASCII bytes Go's [unicode.IsSpace] admits. *)
let is_go_space = function
  | '\t' | '\n' | '\011' | '\012' | '\r' | ' ' -> true
  | _ -> false
;;

let trim_go_space value =
  let length = String.length value in
  let rec first index =
    if index < length && is_go_space value.[index] then first (index + 1) else index
  in
  let rec last index =
    if index > 0 && is_go_space value.[index - 1] then last (index - 1) else index
  in
  let start = first 0 in
  let stop = last length in
  if stop <= start then "" else String.sub value start (stop - start)
;;

let after prefix value =
  let offset = String.length prefix in
  String.sub value offset (String.length value - offset)
;;

let keychain_value value =
  let value = trim_go_space value in
  if String.starts_with ~prefix:go_keyring_hex_prefix value
  then Go_keyring_hex (after go_keyring_hex_prefix value)
  else if String.starts_with ~prefix:go_keyring_base64_prefix value
  then Go_keyring_base64 (after go_keyring_base64_prefix value)
  else Unencoded value
;;

let hex_digit = function
  | '0' .. '9' as digit -> Some (Char.code digit - Char.code '0')
  | 'a' .. 'f' as digit -> Some (Char.code digit - Char.code 'a' + 10)
  | 'A' .. 'F' as digit -> Some (Char.code digit - Char.code 'A' + 10)
  | _ -> None
;;

(* Go's [hex.DecodeString]: an even count of hex digits in either case. *)
let decode_hex digits =
  let length = String.length digits in
  if length mod 2 <> 0
  then None
  else (
    let decoded = Bytes.create (length / 2) in
    let rec fill index =
      if index = Bytes.length decoded
      then Some (Bytes.to_string decoded)
      else (
        match hex_digit digits.[2 * index], hex_digit digits.[(2 * index) + 1] with
        | Some high, Some low ->
          Bytes.set decoded index (Char.chr ((high * 16) + low));
          fill (index + 1)
        | None, (Some _ | None) | Some _, None -> None)
    in
    fill 0)
;;

(* Go's [base64.StdEncoding] skips carriage returns and line feeds. *)
let without_line_breaks text =
  String.to_seq text |> Seq.filter (fun byte -> byte <> '\r' && byte <> '\n') |> String.of_seq
;;

(* HIGH-RISK-UNREVIEWED: setup copies this login into a private account. *)
let login_of_keychain_value value =
  match keychain_value value with
  | Go_keyring_hex digits ->
    (match decode_hex digits with
     | Some login -> Ok login
     | None -> Error Not_hex)
  | Go_keyring_base64 text ->
    (match Base64.decode ~pad:true (without_line_breaks text) with
     | Ok login -> Ok login
     | Error _ -> Error Not_base64)
  | Unencoded login -> Ok login
;;

(* HIGH-RISK-UNREVIEWED: the keychain item is the login the CLI reads first. *)
let keychain_account_email value =
  let* login =
    login_of_keychain_value value |> Result.map_error (fun problem -> Undecodable problem)
  in
  account_email login |> Result.map_error (fun rejection -> Keychain_login rejection)
;;

let principal_sha256 email =
  let canonical =
    Yojson.Safe.to_string
      (`List [ `String "id_token_email"; `String (Runtime_account_email_text.to_string email) ])
  in
  Agent_core_sha256.(to_hex (digest_string canonical))
;;
