(* HIGH-RISK-UNREVIEWED: see the interface. *)

type t =
  { client_id : string
  ; client_secret : string
  ; redirect_uri : string
  }

type error =
  | Client_id_empty
  | Client_secret_empty
  | Redirect_uri_not_https

let make ~client_id ~client_secret ~redirect_uri =
  if String.equal client_id ""
  then Error Client_id_empty
  else if String.equal client_secret ""
  then Error Client_secret_empty
  else if not (Login_transport.is_https_url redirect_uri)
  then Error Redirect_uri_not_https
  else Ok { client_id; client_secret; redirect_uri }
;;

let error_to_string = function
  | Client_id_empty -> "the client ID is empty"
  | Client_secret_empty -> "the client secret is empty"
  | Redirect_uri_not_https -> "the redirect URI is not an https URL with a host and no query or fragment"
;;

let client_id t = t.client_id
let redirect_uri t = t.redirect_uri

let token_request_fields t =
  [ "client_id", t.client_id; "client_secret", t.client_secret; "redirect_uri", t.redirect_uri ]
;;
