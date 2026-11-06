open Result.Syntax

type field =
  | Auth_method
  | Token
  | Token_access_token
  | Token_token_type
  | Token_refresh_token
  | Token_expiry
  | Id_token
  | Id_token_issuer
  | Id_token_email_claim
  | Id_token_email

type rejection =
  | Not_json_object
  | No_known_shape of
      { openid_id_token : field
      ; id_token_email : field
      }
  | Both_shapes

type principal = Sign_in_email of string

let field_to_string = function
  | Auth_method -> "auth_method"
  | Token -> "token"
  | Token_access_token -> "token.access_token"
  | Token_token_type -> "token.token_type"
  | Token_refresh_token -> "token.refresh_token"
  | Token_expiry -> "token.expiry"
  | Id_token -> "id_token"
  | Id_token_issuer -> "id_token.iss"
  | Id_token_email_claim -> "id_token.email"
  | Id_token_email -> "id_token_email"
;;

let rejection_to_string = function
  | Not_json_object -> "not a JSON object"
  | No_known_shape { openid_id_token; id_token_email } ->
    Printf.sprintf
      "matches no known agy login shape: the agy 1.2 id_token shape cannot read %s, \
       the agy 1.5 id_token_email shape cannot read %s"
      (field_to_string openid_id_token)
      (field_to_string id_token_email)
  | Both_shapes ->
    "reads as both the agy 1.2 id_token shape and the agy 1.5 id_token_email shape"
;;

(* Exactly one non-blank string under [name]. *)
let string_member name fields =
  match List.filter (fun (key, _) -> String.equal key name) fields with
  | [ (_, `String value) ] when String.trim value <> "" -> Some value
  | _ -> None
;;

let required field = function
  | Some value -> Ok value
  | None -> Error field
;;

let token_envelope fields =
  let* _auth_method = required Auth_method (string_member "auth_method" fields) in
  let* credentials =
    match List.filter (fun (key, _) -> String.equal key "token") fields with
    | [ (_, `Assoc credentials) ] -> Ok credentials
    | _ -> Error Token
  in
  List.fold_left
    (fun read (name, field) ->
      let* () = read in
      let* _value = required field (string_member name credentials) in
      Ok ())
    (Ok ())
    [ "access_token", Token_access_token
    ; "token_type", Token_token_type
    ; "refresh_token", Token_refresh_token
    ; "expiry", Token_expiry
    ]
;;

(* Only the claims segment is decoded. Google documents [iss] as one of these
   two values: https://developers.google.com/identity/openid-connect/openid-connect *)
let openid_id_token_email fields =
  let* token = required Id_token (string_member "id_token" fields) in
  let* claims =
    match String.split_on_char '.' token with
    | [ header; payload; signature ] when header <> "" && signature <> "" ->
      (match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet payload with
       | Error _ -> Error Id_token
       | Ok payload ->
         (match Yojson.Safe.from_string payload with
          | `Assoc claims -> Ok claims
          | _ -> Error Id_token
          | exception Yojson.Json_error _ -> Error Id_token))
    | _ -> Error Id_token
  in
  let* () =
    match string_member "iss" claims with
    | Some ("accounts.google.com" | "https://accounts.google.com") -> Ok ()
    | Some _ | None -> Error Id_token_issuer
  in
  required Id_token_email_claim (string_member "email" claims)
;;

let read_openid_id_token fields =
  let* () = token_envelope fields in
  openid_id_token_email fields
;;

let read_id_token_email fields =
  let* () = token_envelope fields in
  required Id_token_email (string_member "id_token_email" fields)
;;

(* HIGH-RISK-UNREVIEWED: account continuity reads a credential file. A human
   must review which shapes are admitted and what the principal is. *)
let parse bytes =
  match Yojson.Safe.from_string bytes with
  | `Assoc fields ->
    (match read_openid_id_token fields, read_id_token_email fields with
     | Ok email, Error _ | Error _, Ok email -> Ok (Sign_in_email email)
     | Ok _, Ok _ -> Error Both_shapes
     | Error openid_id_token, Error id_token_email ->
       Error (No_known_shape { openid_id_token; id_token_email }))
  | _ -> Error Not_json_object
  | exception Yojson.Json_error _ -> Error Not_json_object
;;

let principal_sha256 (Sign_in_email email) =
  let canonical = Yojson.Safe.to_string (`List [ `String "id_token_email"; `String email ]) in
  Agent_core_sha256.(to_hex (digest_string canonical))
;;
