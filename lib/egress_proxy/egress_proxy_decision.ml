type refusal =
  | Malformed_request of string
  | Unparsable_host of Egress_host.parse_error
  | Proxy_auth_required
  | Port_not_allowed of
      { host : string
      ; port : int
      ; allowed : int list
      }
  | Forbidden_address of
      { host : string
      ; detail : string
      }
  | Upstream_unreachable of
      { host : string
      ; port : int
      ; detail : string
      }
  | Not_in_allowlist of { host : string }

let refusal_to_string = function
  | Malformed_request detail -> "malformed CONNECT request: " ^ detail
  | Unparsable_host error ->
    "destination is not a host this lane will resolve: "
    ^ Egress_host.parse_error_to_string error
  | Proxy_auth_required -> "proxy authentication required"
  | Port_not_allowed { host; port; allowed } ->
    Printf.sprintf
      "%s is allowed on %s, not on port %d"
      host
      (String.concat ", " (List.map string_of_int allowed))
      port
  | Forbidden_address { host; detail } ->
    Printf.sprintf "%s resolved to a non-public address: %s" host detail
  | Upstream_unreachable { host; port; detail } ->
    Printf.sprintf "%s:%d is allowed and did not answer: %s" host port detail
  | Not_in_allowlist { host } -> Printf.sprintf "%s is not in this keeper's allowlist" host
;;

let client_env ~proxy_url =
  [ "http_proxy", proxy_url
  ; "https_proxy", proxy_url
  ; "HTTP_PROXY", proxy_url
  ; "HTTPS_PROXY", proxy_url
  ]
;;

let proxy_url ~proxy_auth ~host ~port =
  match proxy_auth with
  | None -> Printf.sprintf "http://%s:%d" host port
  | Some token -> Printf.sprintf "http://masc:%s@%s:%d" token host port
;;

let strip_trailing_cr line =
  let length = String.length line in
  if length > 0 && line.[length - 1] = '\r'
  then String.sub line 0 (length - 1)
  else line
;;

let constant_time_equal ~expected candidate =
  let exp_len = String.length expected in
  let cand_len = String.length candidate in
  let diff = ref (exp_len lxor cand_len) in
  for i = 0 to exp_len - 1 do
    let c = if i < cand_len then Char.code candidate.[i] else 0 in
    diff := !diff lor (Char.code expected.[i] lxor c)
  done;
  !diff = 0
;;

let expected_proxy_authorization ~token =
  "Basic " ^ Base64.encode_string ("masc:" ^ token)
;;

let verify_proxy_authorization ~expected_token ~headers =
  let expected_b64 = Base64.encode_string ("masc:" ^ expected_token) in
  let matches_header raw_line =
    let line = strip_trailing_cr raw_line in
    match String.index_opt line ':' with
    | None -> false
    | Some colon ->
      let name = String.lowercase_ascii (String.trim (String.sub line 0 colon)) in
      if not (String.equal name "proxy-authorization")
      then false
      else (
        let rest =
          String.trim (String.sub line (colon + 1) (String.length line - colon - 1))
        in
        match String.index_opt rest ' ' with
        | None -> false
        | Some space ->
          let scheme = String.lowercase_ascii (String.sub rest 0 space) in
          let credential =
            String.trim (String.sub rest (space + 1) (String.length rest - space - 1))
          in
          String.equal scheme "basic"
          && constant_time_equal ~expected:expected_b64 credential)
  in
  List.exists matches_header headers
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

(* 403 says the client asked for something it may not have; 502 says the
   request was fine and what is behind the proxy did not answer. An admitted
   destination that will not connect is the second, and answering it with the
   first sends an operator to the allowlist for a problem that is not
   there. *)
let status_line_of_refusal = function
  | Proxy_auth_required -> "HTTP/1.1 407 Proxy Authentication Required"
  | Upstream_unreachable _ -> "HTTP/1.1 502 Bad Gateway"
  | Malformed_request _
  | Unparsable_host _
  | Port_not_allowed _
  | Forbidden_address _
  | Not_in_allowlist _ -> "HTTP/1.1 403 Forbidden"
;;

let extra_headers_of_refusal = function
  | Proxy_auth_required -> "Proxy-Authenticate: Basic realm=\"masc-egress\"\r\n"
  | Malformed_request _
  | Unparsable_host _
  | Port_not_allowed _
  | Forbidden_address _
  | Upstream_unreachable _
  | Not_in_allowlist _ -> ""
;;

let response_of_decision = function
  | Admitted _ -> "HTTP/1.1 200 Connection Established\r\n\r\n"
  | Refused refusal ->
    let body = refusal_to_string refusal ^ "\n" in
    Printf.sprintf
      "%s\r\n\
       %s\
       Content-Type: text/plain; charset=utf-8\r\n\
       Content-Length: %d\r\n\
       Connection: close\r\n\
       \r\n\
       %s"
      (status_line_of_refusal refusal)
      (extra_headers_of_refusal refusal)
      (String.length body)
      body
;;
