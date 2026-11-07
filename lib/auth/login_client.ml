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

type loopback_error =
  | Loopback_client_id_empty
  | Loopback_client_secret_empty
  | Port_out_of_range
  | Path_not_plain

let make ~client_id ~client_secret ~redirect_uri =
  if String.equal client_id ""
  then Error Client_id_empty
  else if String.equal client_secret ""
  then Error Client_secret_empty
  else if not (Login_transport.is_https_url redirect_uri)
  then Error Redirect_uri_not_https
  else Ok { client_id; client_secret; redirect_uri }
;;

let loopback_host = "127.0.0.1"
let highest_port = 65535

let is_plain_path_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~' | '/' -> true
  | _ -> false
;;

let is_plain_path path =
  String.length path > 0 && Char.equal path.[0] '/' && String.for_all is_plain_path_char path
;;

let loopback ~client_id ~client_secret ~port ~path =
  if String.equal client_id ""
  then Error Loopback_client_id_empty
  else if String.equal client_secret ""
  then Error Loopback_client_secret_empty
  else if port < 1 || port > highest_port
  then Error Port_out_of_range
  else if not (is_plain_path path)
  then Error Path_not_plain
  else
    Ok
      { client_id
      ; client_secret
      ; redirect_uri = Printf.sprintf "http://%s:%d%s" loopback_host port path
      }
;;

let error_to_string = function
  | Client_id_empty -> "the client ID is empty"
  | Client_secret_empty -> "the client secret is empty"
  | Redirect_uri_not_https -> "the redirect URI is not an https URL with a host and no query or fragment"
;;

let loopback_error_to_string = function
  | Loopback_client_id_empty -> "the client ID is empty"
  | Loopback_client_secret_empty -> "the client secret is empty"
  | Port_out_of_range -> "the loopback port is not between 1 and 65535"
  | Path_not_plain -> "the loopback path is not / and then letters, digits, -, ., _, ~ and /"
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
