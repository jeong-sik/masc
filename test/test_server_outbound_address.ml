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

let with_net f = Eio_main.run (fun env -> f env)

(* Address literals resolve without a DNS query, so these refusals need no
   network. *)
let test_refused_hosts () =
  with_net (fun env ->
    let net = Eio.Stdenv.net env in
    List.iter
      (fun url ->
        match Server_outbound_address.validate_resolved_host ~net (Uri.of_string url) with
        | Error _ -> ()
        | Ok () -> fail (url ^ " was allowed"))
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

let () =
  run
    "server_outbound_address"
    [ ( "address"
      , [ test_case "private and public addresses" `Quick test_private_and_public_addresses
        ; test_case "refused hosts" `Quick test_refused_hosts
        ; test_case
            "document fetch refuses before connecting"
            `Quick
            test_document_fetch_refuses_before_connecting
        ] )
    ]
;;
