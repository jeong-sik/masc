(* HIGH-RISK-UNREVIEWED: outbound fetch of an OAuth client metadata document
   whose URL arrived in an authorization request. *)

let ( let* ) = Result.bind

(* Bounds connect, request and body. The name lookups (the address check,
   then the client's own) run in system threads that cancellation cannot
   stop, so the system resolver bounds those instead. *)
let fetch_timeout_sec = 5.0
let request_headers = [ "Accept", "application/json" ]

let fetch ~clock ~net url =
  let url = (url : Auth_oauth_client_metadata.document_url :> string) in
  let* () = Server_outbound_address.validate_resolved_host ~net (Uri.of_string url) in
  match
    Masc_http_client.get_response_sync
      ~clock
      ~timeout_sec:fetch_timeout_sec
      ~max_body_bytes:Auth_oauth_client_metadata.max_document_bytes
      ~url
      ~headers:request_headers
      ()
  with
  | Error reason -> Error ("fetch failed: " ^ reason)
  | Ok { Masc_http_client.status = 200; body; _ } -> Ok body
  | Ok { Masc_http_client.status; _ } ->
    Error (Printf.sprintf "the document URL answered HTTP %d" status)
;;

let of_server_state (state : Mcp_server.server_state) url =
  let clock =
    match state.clock with
    | Some _ as clock -> clock
    | None -> Eio_context.get_clock_opt ()
  in
  let net =
    match state.net with
    | Some _ as net -> net
    | None -> Eio_context.get_net_opt ()
  in
  match clock, net with
  | Some clock, Some net -> fetch ~clock ~net url
  | None, _ | _, None -> Error "the server has no network to fetch the document"
;;
