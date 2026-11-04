open Alcotest

let ip raw =
  match Ipaddr.of_string raw with
  | Ok ip -> ip
  | Error (`Msg message) -> fail (raw ^ ": " ^ message)
;;

let refusal raw =
  Masc.Outbound_address.ip_refusal (ip raw)
  |> Option.map Masc.Outbound_address.refusal_to_string
;;

let test_private_and_public_addresses () =
  List.iter
    (fun (raw, expected) -> check (option string) raw expected (refusal raw))
    [ "10.0.0.1", Some "private-network address"
    ; "127.0.0.53", Some "loopback address"
    ; "169.254.169.254", Some "link-local address"
    ; "192.168.1.10", Some "private-network address"
    ; "8.8.8.8", None
    ; "::1", Some "loopback address"
    ; "fd00::1", Some "private-network address"
    ; "2606:4700::6810:84e5", None
    ; "::ffff:10.0.0.1", Some "private-network address"
    ; "::ffff:169.254.169.254", Some "link-local address"
    ; "::ffff:8.8.8.8", None
    ]
;;

(* Each special-purpose block ends where the IANA registry ends it: the
   public neighbours on either side stay fetchable. *)
let test_special_purpose_block_boundaries () =
  List.iter
    (fun (raw, expected) -> check (option string) raw expected (refusal raw))
    [ "0.1.2.3", Some "unspecified address"
    ; "100.64.0.1", Some "shared address space"
    ; "100.127.255.255", Some "shared address space"
    ; "100.128.0.1", None
    ; "192.0.0.8", Some "reserved address"
    ; "192.0.1.1", None
    ; "192.0.2.5", Some "reserved address"
    ; "198.18.0.1", Some "reserved address"
    ; "198.20.0.1", None
    ; "198.51.100.7", Some "reserved address"
    ; "198.52.0.1", None
    ; "203.0.113.9", Some "reserved address"
    ; "203.0.114.1", None
    ; "224.0.0.1", Some "multicast address"
    ; "255.255.255.255", Some "reserved address"
    ; "64:ff9b::7f00:1", Some "loopback address"
    ; "64:ff9b::808:808", None
    ; "fec0::1", Some "private-network address"
    ; "fe80::1", Some "link-local address"
    ; "fe80:0:0:1::1", Some "link-local address"
    ; "febf:ffff::1", Some "link-local address"
    ; "ff02::1", Some "multicast address"
    ; "100::1", Some "reserved address"
    ; "::7f00:1", Some "reserved address"
    ; "64:ff9b:1::7f00:1", Some "reserved address"
    ; "2001::1", Some "reserved address"
    ; "2001:1ff:ffff::1", Some "reserved address"
    ; "2001:200::1", None
    ; "2002:7f00:1::1", Some "reserved address"
    ; "3fff::1", Some "reserved address"
    ; "4000::1", Some "reserved address"
    ; "2606:4700:4700::1111", None
    ]
;;

let test_ipv6_documentation_prefix_boundary () =
  List.iter
    (fun (raw, expected) ->
      check bool raw expected (Option.is_some (refusal raw)))
    [ "2001:db8::", true
    ; "2001:db8:ffff:ffff:ffff:ffff:ffff:ffff", true
    ; "2001:db7:ffff:ffff:ffff:ffff:ffff:ffff", false
    ; "2001:db9::", false
    ; "2001:db80::1", false
    ; "2001:db8f::1", false
    ]
;;

(* The pin is what keeps curl on the admitted addresses: every spelling of
   the host curl may look up maps to them, and an environment proxy, which
   would resolve the name itself, is off. *)
let test_pinned_request_keeps_curl_on_admitted_addresses () =
  let argv =
    Masc.Tool_local_runtime_http.curl_get_argv_for_test
      ~pinned_resolution:
        { Masc.Tool_local_runtime_http.host = "pin.invalid."
        ; port = 8935
        ; first_address = Ipaddr.of_string_exn "203.0.114.5"
        ; other_addresses = [ Ipaddr.of_string_exn "2606:4700:4700::1111" ]
        }
      "http://pin.invalid.:8935/page"
  in
  let rec values flag = function
    | name :: value :: rest when String.equal name flag ->
      value :: values flag rest
    | _ :: rest -> values flag rest
    | [] -> []
  in
  check (list string) "resolve entries"
    [ "pin.invalid.:8935:203.0.114.5,[2606:4700:4700::1111]"
    ; "pin.invalid:8935:203.0.114.5,[2606:4700:4700::1111]"
    ]
    (values "--resolve" argv);
  check (list string) "no proxy" [ "*" ] (values "--noproxy" argv)
;;

let with_net f = Eio_main.run (fun env -> f env)

(* Address literals resolve without a DNS query, so these refusals need no
   network. *)
let test_refused_hosts () =
  with_net (fun env ->
    let net = Eio.Stdenv.net env in
    List.iter
      (fun url ->
        match Masc.Outbound_address.resolve_allowed_host ~net (Uri.of_string url) with
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
      check string "refused by the address check"
        "resolved address is not allowed: private-network address" reason
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
    "outbound_address"
    [ ( "address"
      , [ test_case "private and public addresses" `Quick test_private_and_public_addresses
        ; test_case "special-purpose block boundaries" `Quick
            test_special_purpose_block_boundaries
        ; test_case "IPv6 documentation prefix boundary" `Quick
            test_ipv6_documentation_prefix_boundary
        ; test_case "pinned request keeps curl on admitted addresses" `Quick
            test_pinned_request_keeps_curl_on_admitted_addresses
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
