type refusal =
  | Malformed_request of string
  | Unparsable_host of Egress_host.parse_error
  | Port_not_allowed of int
  | Not_in_allowlist of { host : string }

let allowed_ports = [ 443 ]

let refusal_to_string = function
  | Malformed_request detail -> "malformed CONNECT request: " ^ detail
  | Unparsable_host error ->
    "destination is not a host this lane will resolve: "
    ^ Egress_host.parse_error_to_string error
  | Port_not_allowed port ->
    Printf.sprintf
      "port %d is not carried by this lane (allowed: %s)"
      port
      (String.concat ", " (List.map string_of_int allowed_ports))
  | Not_in_allowlist { host } -> Printf.sprintf "%s is not in this keeper's allowlist" host
;;

let client_env ~proxy_url =
  [ "http_proxy", proxy_url
  ; "https_proxy", proxy_url
  ; "HTTP_PROXY", proxy_url
  ; "HTTPS_PROXY", proxy_url
  ]
;;

type decision =
  | Admitted of
      { host : Egress_host.t
      ; port : int
      }
  | Refused of refusal

(* The request line only, and only CONNECT. A proxy that also spoke plain
   HTTP would have to parse a request body to say honestly what it
   forwarded; this lane tunnels TLS and records the authority, which is the
   whole of what it can truthfully claim to know. *)
let split_request_line line =
  (* A CR is part of the line terminator, not of the target. Trimming it
     here rather than letting it reach the host parser keeps the refusal
     message about the host rather than about an invisible byte. *)
  let line =
    let length = String.length line in
    if length > 0 && line.[length - 1] = '\r' then String.sub line 0 (length - 1) else line
  in
  match String.split_on_char ' ' line with
  | [ verb; authority; version ] ->
    if not (String.equal verb "CONNECT") then
      Error (Malformed_request (Printf.sprintf "verb is not CONNECT"))
    else if String.equal authority "" then Error (Malformed_request "authority is empty")
    else if
      not
        (String.equal version "HTTP/1.1"
         || String.equal version "HTTP/1.0")
    then Error (Malformed_request "unsupported HTTP version")
    else Ok authority
  | _ -> Error (Malformed_request "expected three space-separated fields")
;;

(* Split on the last colon. A host that itself contains a colon is refused
   by the host parser, so this split cannot be used to smuggle one past the
   allowlist -- but splitting from the right is what keeps the two checks
   from disagreeing about which bytes are the host. *)
let split_authority authority =
  match String.rindex_opt authority ':' with
  | None -> Error (Malformed_request "authority carries no port")
  | Some index ->
    let host = String.sub authority 0 index in
    let port_text =
      String.sub authority (index + 1) (String.length authority - index - 1)
    in
    (match int_of_string_opt port_text with
     | None -> Error (Malformed_request "port is not a number")
     | Some port when port <= 0 || port > 65535 ->
       Error (Malformed_request "port is out of range")
     | Some port -> Ok (host, port))
;;

let decide ~rules ~request_line =
  match split_request_line request_line with
  | Error refusal -> Refused refusal
  | Ok authority ->
    (match split_authority authority with
     | Error refusal -> Refused refusal
     | Ok (host_text, port) ->
       (match Egress_host.parse host_text with
        | Error error -> Refused (Unparsable_host error)
        | Ok host ->
          if not (List.mem port allowed_ports) then Refused (Port_not_allowed port)
          else if Egress_host.admits rules host then Admitted { host; port }
          else Refused (Not_in_allowlist { host = Egress_host.to_string host })))
;;

let response_of_decision = function
  | Admitted _ -> "HTTP/1.1 200 Connection Established\r\n\r\n"
  | Refused refusal ->
    let body = refusal_to_string refusal ^ "\n" in
    Printf.sprintf
      "HTTP/1.1 403 Forbidden\r\n\
       Content-Type: text/plain; charset=utf-8\r\n\
       Content-Length: %d\r\n\
       Connection: close\r\n\
       \r\n\
       %s"
      (String.length body)
      body
;;
