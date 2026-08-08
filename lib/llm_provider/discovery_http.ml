(* See discovery_http.mli for module rationale. *)

let http_error_detail = function
  | Http_client.HttpError { code; _ } -> Printf.sprintf "HTTP %d" code
  | Http_client.AcceptRejected { reason } -> reason
  | Http_client.NetworkError { message; _ } -> message
  | Http_client.TimeoutError { message; _ } -> message
  | Http_client.ProviderTerminal { message; _ } -> message
  | Http_client.ProviderFailure { kind; message } ->
    Http_client.provider_failure_to_string ~kind ~message
;;

let get_json ~sw ~net url =
  match Http_client.get_sync ~sw ~net ~url ~headers:[] () with
  | Ok (code, body) when code >= 200 && code < 300 ->
    (try Ok (Yojson.Safe.from_string body) with
     | Yojson.Json_error msg -> Error msg)
  | Ok (code, _) -> Error (Printf.sprintf "HTTP %d" code)
  | Error error -> Error (http_error_detail error)
;;

let probe_liveness ~sw ~net url =
  match Http_client.get_sync ~sw ~net ~url ~headers:[] () with
  | Ok (code, _) when code >= 200 && code < 300 -> Ok ()
  | Ok (code, _) -> Error (Printf.sprintf "HTTP %d" code)
  | Error error -> Error (http_error_detail error)
;;
