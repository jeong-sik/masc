type refusal =
  | Malformed_request of string
  | Unparsable_host of Egress_host.parse_error
  | Port_not_allowed of
      { host : string
      ; port : int
      ; allowed : int list
      }
  | Not_in_allowlist of { host : string }

let refusal_to_string = function
  | Malformed_request detail -> "malformed CONNECT request: " ^ detail
  | Unparsable_host error ->
    "destination is not a host this lane will resolve: "
    ^ Egress_host.parse_error_to_string error
  | Port_not_allowed { host; port; allowed } ->
    Printf.sprintf
      "%s is allowed on %s, not on port %d"
      host
      (String.concat ", " (List.map string_of_int allowed))
      port
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

(* A CONNECT authority always names a port, unlike a rule, so the absent-port
   case is a malformed request here rather than a default. Whether the port
   is permitted is then the allowlist's answer, not this function's. *)
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
          if Egress_host.admits rules host ~port then Admitted { host; port }
          else (
            let host_text = Egress_host.to_string host in
            (* A host the allowlist names, on a port it does not, is a
               different mistake than a host it does not name, and the
               operator fixes it in a different place. *)
            match Egress_host.ports_for_host rules host with
            | [] -> Refused (Not_in_allowlist { host = host_text })
            | allowed -> Refused (Port_not_allowed { host = host_text; port; allowed }))))
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
