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

type environment_error =
  | Secret_variable_unset of string
  | Client_refused of error

let environment_error_to_string = function
  | Secret_variable_unset name -> Printf.sprintf "the environment variable %s is not set" name
  | Client_refused error -> error_to_string error
;;

let of_environment ~getenv ~client_id ~redirect_uri ~client_secret_env =
  match getenv client_secret_env with
  | None -> Error (Secret_variable_unset client_secret_env)
  | Some client_secret ->
    make ~client_id ~client_secret ~redirect_uri |> Result.map_error (fun error -> Client_refused error)
;;

let client_id t = t.client_id
let redirect_uri t = t.redirect_uri

let token_request_fields t =
  [ "client_id", t.client_id; "client_secret", t.client_secret; "redirect_uri", t.redirect_uri ]
;;
