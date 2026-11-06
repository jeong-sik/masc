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

type keychain_rejection =
  | Not_go_keyring_base64
  | Keychain_login of rejection

let email_key_to_string = function
  | Id_token_email -> "id_token_email"
  | Id_token_email_claim -> "id_token.email"
;;

let id_token_rejection_to_string = function
  | Not_a_jwt -> "is not a three-segment JWT"
  | Claims_not_base64url -> "claims are not unpadded base64url"
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
  | Unreadable_email key -> email_key_to_string key ^ " repeats or is not a string"
  | Not_email_text key -> email_key_to_string key ^ " is not email text"
;;

let keychain_rejection_to_string = function
  | Not_go_keyring_base64 -> "not a go-keyring-base64 value"
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

let email_text key = function
  | `String text ->
    (match Runtime_account_email_text.of_string text with
     | Some email -> Ok email
     | None -> Error (Not_email_text key))
  | _ -> Error (Unreadable_email key)
;;

(* Google documents [iss] as one of these two values:
   https://developers.google.com/identity/openid-connect/openid-connect
   Only the claims segment is decoded. *)
let id_token_email = function
  | `String token ->
    let* claims =
      match String.split_on_char '.' token with
      | [ header; payload; signature ] when header <> "" && signature <> "" ->
        (match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet payload with
         | Error _ -> Error (Invalid_id_token Claims_not_base64url)
         | Ok payload ->
           (match Yojson.Safe.from_string payload with
            | `Assoc claims -> Ok claims
            | _ -> Error (Invalid_id_token Claims_not_json_object)
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
  | _ -> Error (Invalid_id_token Not_a_jwt)
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
  | _ -> Error Not_json_object
  | exception Yojson.Json_error _ -> Error Not_json_object
;;

(* go-keyring's own encoding header, written by its macOS [Set]:
   https://github.com/zalando/go-keyring/blob/master/keyring_darwin.go *)
let go_keyring_base64_prefix = "go-keyring-base64:"

let login_of_keychain_value value =
  if String.starts_with ~prefix:go_keyring_base64_prefix value
  then (
    let offset = String.length go_keyring_base64_prefix in
    match Base64.decode ~pad:true (String.sub value offset (String.length value - offset)) with
    | Ok login -> Some login
    | Error _ -> None)
  else None
;;

(* HIGH-RISK-UNREVIEWED: the keychain item is the login the CLI reads first. *)
let keychain_account_email value =
  match login_of_keychain_value value with
  | None -> Error Not_go_keyring_base64
  | Some login ->
    account_email login |> Result.map_error (fun rejection -> Keychain_login rejection)
;;

let principal_sha256 email =
  let canonical =
    Yojson.Safe.to_string
      (`List [ `String "id_token_email"; `String (Runtime_account_email_text.to_string email) ])
  in
  Agent_core_sha256.(to_hex (digest_string canonical))
;;
