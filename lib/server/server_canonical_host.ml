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
  Httpun.Reqd.respond_with_string reqd response ""

let authority_host_port ~default_port request_authority =
  ( Server_request_authority.host request_authority
  , Option.value
      ~default:default_port
      (Server_request_authority.port request_authority) )
;;

let canonical_loopback_location
    ~default_port
    ~request_authority
    (request : Httpun.Request.t)
  =
  let host, port = authority_host_port ~default_port request_authority in
  let canonical_host = Transport_read_model.normalize_advertised_host host in
  if String.equal canonical_host host then
    None
  else
    Some (Printf.sprintf "http://%s:%d%s" canonical_host port request.target)

let with_canonical_loopback_host ~port handler request reqd =
  let request_authority = Server_request_authority.current_exn () in
  match
    canonical_loopback_location ~default_port:port ~request_authority request
  with
  | Some location -> respond_redirect ~location reqd
  | None -> handler request reqd
