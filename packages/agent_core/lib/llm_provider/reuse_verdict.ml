type close_reason =
  | Request_failed
  | Request_not_delivered
  | Not_persistent
  | Body_not_drained
  | Transport_ended

type t =
  | Park
  | Close of close_reason

(* Every line of the field counts: a recipient combines repeated field lines
   into one list (RFC 9110 §5.3). [Http.Header.get] returns only the last. *)
let header_has_token headers name token =
  Http.Header.get_multi headers name
  |> List.concat_map (String.split_on_char ',')
  |> List.exists (fun value ->
    String.equal
      (String.lowercase_ascii (String.trim value))
      (String.lowercase_ascii token))
;;

let valid_single_content_length = function
  | [ value ] ->
    let value = String.trim value in
    (not (String.equal value ""))
    && String.for_all
         (function
           | '0' .. '9' -> true
           | _ -> false)
         value
    && Option.is_some (Int64.of_string_opt value)
  | [] | _ :: _ :: _ -> false
;;

let persistent ~request_headers response =
  let response_headers = Http.Response.headers response in
  let status = Http.Response.status response |> Http.Status.to_int in
  let response_allows_persistence =
    match Http.Response.version response with
    | `HTTP_1_1 -> true
    | `HTTP_1_0 -> header_has_token response_headers "connection" "keep-alive"
    | `Other _ -> false
  in
  let is_upgrade =
    status = 101
    || Option.is_some (Http.Header.get response_headers "upgrade")
    || header_has_token response_headers "connection" "upgrade"
  in
  (* An interim 1xx response is not the final one: the final response that
     follows it is still on the connection. *)
  let is_interim = status >= 100 && status < 200 in
  let response_has_no_body = status = 204 || status = 304 in
  let response_framing =
    match
      ( Http.Header.get_multi response_headers "content-length"
      , Http.Header.get_multi response_headers "transfer-encoding" )
    with
    | [], [] -> `Absent
    | content_lengths, [] when valid_single_content_length content_lengths ->
      `Content_length
    | [], _ :: _ ->
      (match Http.Header.get_transfer_encoding response_headers with
       | Http.Transfer.Chunked -> `Final_chunked
       | Http.Transfer.Fixed _ | Http.Transfer.Unknown -> `Invalid)
    | _ -> `Invalid
  in
  let response_is_self_delimited =
    match response_framing with
    | `Content_length | `Final_chunked -> true
    | `Absent -> response_has_no_body
    | `Invalid -> false
  in
  (not is_interim)
  && (not is_upgrade)
  && response_allows_persistence
  && response_is_self_delimited
  && (not (header_has_token request_headers "connection" "close"))
  && not (header_has_token response_headers "connection" "close")
;;

let decide ~request_headers ~response ~body =
  match body with
  | `Failed -> Close Request_failed
  | `Not_drained -> Close Body_not_drained
  | `Transport_ended -> Close Transport_ended
  | `Drained ->
    if persistent ~request_headers response then Park else Close Not_persistent
;;
