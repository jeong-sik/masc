(* The redirect that sends a request naming a loopback alias ([localhost], [::1], a
   wildcard bind address) to the canonical loopback host. It reads the admitted
   request authority and nothing else: no server state, no credential. *)

let respond_redirect ~location reqd =
  let response =
    Httpun.Response.create
      ~headers:(Httpun.Headers.of_list [
        ("location", location);
        ("content-length", "0");
      ])
      `Found
  in
  Http_reqd.respond_with_string reqd response ""

let authority_host_port ~default_port request_authority =
  ( Server_request_authority.host request_authority
  , Option.value
      ~default:default_port
      (Server_request_authority.port request_authority) )
;;

(* The admitted authority's scheme: a request on the TLS listener is sent to
   the canonical host over https, never to a cleartext URL on the TLS port. *)
let authority_scheme request_authority =
  Server_request_authority.scheme_to_string
    (Server_request_authority.scheme request_authority)
;;

(* The redirect names the admitted authority's port, or its scheme's default
   when the request named none: a port-less Host is admitted only when the
   listener sits on that default, so the redirect reaches the same listener. *)
let canonical_loopback_location ~request_authority (request : Httpun.Request.t) =
  let host = Server_request_authority.host request_authority in
  let port = Server_request_authority.port_or_default request_authority in
  let canonical_host = Transport_read_model.normalize_advertised_host host in
  if String.equal canonical_host host then
    None
  else
    Some
      (Printf.sprintf
         "%s://%s:%d%s"
         (authority_scheme request_authority)
         canonical_host
         port
         request.target)

let with_canonical_loopback_host handler request reqd =
  let request_authority = Server_request_authority.current_exn () in
  match
    canonical_loopback_location ~request_authority request
  with
  | Some location -> respond_redirect ~location reqd
  | None -> handler request reqd
