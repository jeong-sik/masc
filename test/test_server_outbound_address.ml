open Alcotest

let ip raw =
  match Ipaddr.of_string raw with
  | Ok ip -> ip
  | Error (`Msg message) -> fail (raw ^ ": " ^ message)
;;

let test_private_and_public_addresses () =
  List.iter
    (fun (raw, expected) ->
      check bool raw expected (Server_outbound_address.ipaddr_is_private_or_reserved (ip raw)))
    [ "10.0.0.1", true
    ; "127.0.0.53", true
    ; "169.254.169.254", true
    ; "192.168.1.10", true
    ; "8.8.8.8", false
    ; "::1", true
    ; "fd00::1", true
    ; "2606:4700::6810:84e5", false
    ; "::ffff:10.0.0.1", true
    ; "::ffff:169.254.169.254", true
    ; "::ffff:8.8.8.8", false
    ]
;;

let test_ipv6_documentation_prefix_boundary () =
  List.iter
    (fun (raw, expected) ->
      check bool raw expected
        (Server_outbound_address.ipaddr_is_private_or_reserved (ip raw)))
    [ "2001:db8::", true
    ; "2001:db8:ffff:ffff:ffff:ffff:ffff:ffff", true
    ; "2001:db7:ffff:ffff:ffff:ffff:ffff:ffff", false
    ; "2001:db9::", false
    ; "2001:db80::1", false
    ; "2001:db8f::1", false
    ]
;;

let with_net f = Eio_main.run (fun env -> f env)

(* Address literals resolve without a DNS query, so these refusals need no
   network. *)
let test_refused_hosts () =
  with_net (fun env ->
    let net = Eio.Stdenv.net env in
    List.iter
      (fun url ->
        match Server_outbound_address.resolve_allowed_host ~net (Uri.of_string url) with
        | Error _ -> ()
        | Ok _ -> fail (url ^ " was allowed"))
      [ "https://localhost/meta.json"
      ; "https://127.0.0.1/meta.json"
      ; "https://0.0.0.0/meta.json"
      ; "https://10.1.2.3/meta.json"
      ; "https://[::ffff:10.0.0.1]/meta.json"
      ; "https://[::ffff:127.0.0.1]/meta.json"
      ; "https:///meta.json"
      ])
;;

let test_document_fetch_refuses_before_connecting () =
  with_net (fun env ->
    let url =
      match Auth_oauth_client_metadata.classify_client_id "https://10.0.0.7/meta.json" with
      | Ok (Auth_oauth_client_metadata.Document url) -> url
      | Ok (Auth_oauth_client_metadata.Registered _) | Error _ ->
        fail "fixture must be a document URL"
    in
    match
      Server_oauth_client_metadata_fetch.fetch
        ~clock:(Eio.Stdenv.clock env)
        ~net:(Eio.Stdenv.net env)
        url
    with
    | Error reason ->
      check string "refused by the address check" "resolved address is not allowed" reason
    | Ok _ -> fail "a private address was fetched")
;;

module Rebinding_net = struct
  type tag = [ `Generic | `Unix ]
  type t = {
    net : tag Eio.Net.ty Eio.Resource.t;
    lookups : int ref;
    attempted : Eio.Net.Ipaddr.v4v6 list ref;
  }
  let getaddrinfo t ~service _host =
    incr t.lookups;
    let ip = if !(t.lookups) = 1 then Eio.Net.Ipaddr.of_raw "\008\008\008\008"
      else Eio.Net.Ipaddr.V4.loopback in
    [`Tcp (ip, int_of_string service)]
  let connect t ~sw:_ = function
    | `Tcp (ip, _) ->
      t.attempted := ip :: !(t.attempted);
      (* Observe the destination without sending any packet. *)
      raise (Unix.Unix_error (Unix.ECONNREFUSED, "fixture TCP boundary", ""))
    | `Unix _ -> fail "metadata fetch attempted a Unix socket"
  let getnameinfo t = Eio.Net.getnameinfo t.net
  let listen t ~reuse_addr ~reuse_port ~backlog ~sw address =
    Eio.Net.listen t.net ~reuse_addr ~reuse_port ~backlog ~sw address
  let datagram_socket t ~reuse_addr ~reuse_port ~sw address =
    Eio.Net.datagram_socket t.net ~reuse_addr ~reuse_port ~sw address
end

let test_document_fetch_binds_approved_dns_answer () =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let lookups = ref 0 and attempted = ref [] in
    let net = Eio.Resource.T
      ({ Rebinding_net.net = env#net; lookups; attempted },
       Eio.Net.Pi.network (module Rebinding_net)) in
    let routed = object
      method net = net
      method stdin = env#stdin
      method stdout = env#stdout
      method stderr = env#stderr
      method domain_mgr = env#domain_mgr
      method process_mgr = env#process_mgr
      method clock = env#clock
      method mono_clock = env#mono_clock
      method fs = env#fs
      method cwd = env#cwd
      method secure_random = env#secure_random
      method debug = env#debug
      method backend_id = env#backend_id
    end in
    let url = match Auth_oauth_client_metadata.classify_client_id "https://provider.test/meta.json" with
      | Ok (Auth_oauth_client_metadata.Document url) -> url
      | _ -> fail "fixture must be a metadata document URL" in
    let result = Masc_http_client.with_scoped_pool ~sw ~env:routed (fun () ->
      Server_oauth_client_metadata_fetch.fetch ~clock:env#clock ~net url) in
    check bool "fixture refuses TCP" true (Result.is_error result);
    check int "only the admitted lookup occurs" 1 !lookups;
    check (list string) "only the admitted address reaches TCP"
      ["8.8.8.8"] (List.map (Fmt.str "%a" Eio.Net.Ipaddr.pp) !attempted)))
;;

let () =
  run
    "server_outbound_address"
    [ ( "address"
      , [ test_case "private and public addresses" `Quick test_private_and_public_addresses
        ; test_case "IPv6 documentation prefix boundary" `Quick
            test_ipv6_documentation_prefix_boundary
        ; test_case "refused hosts" `Quick test_refused_hosts
        ; test_case
            "document fetch refuses before connecting"
            `Quick
            test_document_fetch_refuses_before_connecting
        ; test_case "document fetch binds the approved DNS answer" `Quick
            test_document_fetch_binds_approved_dns_answer
        ] )
    ]
;;
