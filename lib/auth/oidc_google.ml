(* HIGH-RISK-UNREVIEWED: see the interface. *)

let ( let* ) = Result.bind

(* The two values of [iss] that Google documents for its ID tokens. *)
let issuers = [ "https://accounts.google.com"; "accounts.google.com" ]

let is_issuer text = List.exists (String.equal text) issuers
let discovery_url = "https://accounts.google.com/.well-known/openid-configuration"

type error =
  | Payload_not_an_object
  | Issuer_not_google
  | Audience_is_a_list
  | Audience_not_this_client
  | Nonce_differs
  | Subject_not_a_string
  | Subject_invalid of Authz_external_identity.error

let error_to_string = function
  | Payload_not_an_object -> "the ID token payload is not a JSON object"
  | Issuer_not_google -> "the ID token was not issued by Google"
  | Audience_is_a_list -> "the ID token names several audiences"
  | Audience_not_this_client -> "the ID token was issued for another client"
  | Nonce_differs -> "the ID token nonce is not the nonce of this login"
  | Subject_not_a_string -> "the ID token has no sub string"
  | Subject_invalid error ->
    "the ID token sub is not a Google subject: " ^ Authz_external_identity.error_to_string error
;;

let string_member name members =
  match List.assoc_opt name members with
  | Some (`String value) -> Some value
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) | None -> None
;;

let check condition error = if condition then Ok () else Error error

let issuer members =
  check
    (match string_member "iss" members with
     | Some iss -> is_issuer iss
     | None -> false)
    Issuer_not_google
;;

let audience ~client_id members =
  match List.assoc_opt "aud" members with
  | Some (`String aud) -> check (String.equal aud client_id) Audience_not_this_client
  | Some (`List _) -> Error Audience_is_a_list
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _) | None ->
    Error Audience_not_this_client
;;

let same_nonce ~nonce members =
  check
    (match string_member "nonce" members with
     | Some claimed -> Eqaf.equal claimed nonce
     | None -> false)
    Nonce_differs
;;

let subject members =
  match string_member "sub" members with
  | Some sub -> Result.map_error (fun error -> Subject_invalid error) (Authz_external_identity.google ~sub)
  | None -> Error Subject_not_a_string
;;

let identity ~client_id ~nonce (payload : Yojson.Safe.t) =
  match payload with
  | `Assoc members ->
    let* () = issuer members in
    let* () = audience ~client_id members in
    let* () = same_nonce ~nonce members in
    subject members
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error Payload_not_an_object
;;
