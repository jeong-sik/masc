open Alcotest
module Metadata = Auth_oauth_client_metadata

let claude_code_url = "https://claude.ai/oauth/claude-code-client-metadata"

(* Byte-for-byte what https://claude.ai/oauth/claude-code-client-metadata
   served on 2026-10-27 (cache-control: public, max-age=300). *)
let claude_code_document =
  {|{"client_id":"https://claude.ai/oauth/claude-code-client-metadata","client_name":"Claude Code","client_uri":"https://claude.ai","redirect_uris":["http://localhost/callback","http://127.0.0.1/callback"],"grant_types":["authorization_code","refresh_token"],"response_types":["code"],"token_endpoint_auth_method":"none"}|}
;;

let document_url raw =
  match Metadata.classify_client_id raw with
  | Ok (Metadata.Document url) -> url
  | Ok (Metadata.Registered _) -> fail (raw ^ " was read as a registered client id")
  | Error rule -> fail (raw ^ " was refused: " ^ rule)
;;

let claude_code () =
  match Metadata.parse_document (document_url claude_code_url) claude_code_document with
  | Ok document -> document
  | Error reason -> fail ("Claude Code document refused: " ^ reason)
;;

let test_registered_ids_stay_registered () =
  List.iter
    (fun raw ->
      match Metadata.classify_client_id raw with
      | Ok (Metadata.Registered id) -> check string "kept verbatim" raw id
      | Ok (Metadata.Document _) | Error _ -> fail (raw ^ " left the registered path"))
    [ "masc_abc"; "http://example.com/client.json"; "urn:example:client" ]
;;

let test_document_url_rules () =
  check
    string
    "a valid URL is kept byte-for-byte"
    claude_code_url
    (document_url claude_code_url :> string);
  ignore (document_url "https://example.com:8443/client.json");
  List.iter
    (fun raw ->
      match Metadata.classify_client_id raw with
      | Error _ -> ()
      | Ok _ -> fail (raw ^ " was accepted as a document URL"))
    [ "https://example.com"
    ; "https://example.com/"
    ; "https:///client.json"
    ; "https://user@example.com/client.json"
    ; "https://example.com/client.json#frag"
    ; "https://example.com/client.json?v=1"
    ; "https://example.com/a/../client.json"
    ; "https://example.com/./client.json"
    ; "https://example.com/a/%2E%2E/client.json"
    ; "https://attacker.example/c.json\n(claude.ai)"
    ; "https://a.example @b.example/c.json"
    ; "https://a.example\\@b.example/c.json"
    ; "https://example.com:abc/c.json"
      (* ocaml-uri prints the scheme in lower case, so this is not the URL it
         would fetch. *)
    ; "HTTPS://example.com/client.json"
    ]
;;

let test_claude_code_document_is_accepted () =
  let document = claude_code () in
  check string "client name" "Claude Code" document.client_name;
  check
    (list string)
    "redirect URIs"
    [ "http://localhost/callback"; "http://127.0.0.1/callback" ]
    document.redirect_uris
;;

let refused ~label url body =
  match Metadata.parse_document (document_url url) body with
  | Error _ -> ()
  | Ok _ -> fail (label ^ " was accepted")
;;

let test_document_rules () =
  let url = "https://client.example/meta.json" in
  let with_fields fields =
    Yojson.Safe.to_string
      (`Assoc
          ([ "client_id", `String url
           ; "client_name", `String "Example"
           ; "redirect_uris", `List [ `String "http://127.0.0.1/cb" ]
           ]
           @ fields))
  in
  (match Metadata.parse_document (document_url url) (with_fields []) with
   | Ok _ -> ()
   | Error reason -> fail ("minimal document refused: " ^ reason));
  refused ~label:"client_id with a trailing slash" url
    {|{"client_id":"https://client.example/meta.json/","client_name":"E","redirect_uris":["http://127.0.0.1/cb"]}|};
  refused ~label:"missing client_name" url
    (Printf.sprintf {|{"client_id":%S,"redirect_uris":["http://127.0.0.1/cb"]}|} url);
  refused ~label:"blank client_name" url
    (Printf.sprintf {|{"client_id":%S,"client_name":" ","redirect_uris":["http://127.0.0.1/cb"]}|} url);
  refused ~label:"empty redirect_uris" url
    (Printf.sprintf {|{"client_id":%S,"client_name":"E","redirect_uris":[]}|} url);
  refused ~label:"duplicate redirect" url
    (Printf.sprintf
       {|{"client_id":%S,"client_name":"E","redirect_uris":["http://127.0.0.1/cb","http://127.0.0.1/cb"]}|}
       url);
  refused ~label:"repeated member name" url
    (Printf.sprintf
       {|{"client_id":%S,"client_name":"E","client_name":"F","redirect_uris":["http://127.0.0.1/cb"]}|}
       url);
  refused ~label:"control character in client_name" url
    (Printf.sprintf
       {|{"client_id":%S,"client_name":"Claude\nCode","redirect_uris":["http://127.0.0.1/cb"]}|}
       url);
  refused ~label:"client_secret" url (with_fields [ "client_secret", `String "s" ]);
  refused ~label:"client_secret_expires_at" url
    (with_fields [ "client_secret_expires_at", `Int 0 ]);
  refused ~label:"confidential auth method" url
    (with_fields [ "token_endpoint_auth_method", `String "client_secret_basic" ]);
  refused ~label:"unsupported grant" url
    (with_fields [ "grant_types", `List [ `String "client_credentials" ] ]);
  refused ~label:"unsupported response type" url
    (with_fields [ "response_types", `List [ `String "token" ] ]);
  refused ~label:"not an object" url {|["client_id"]|};
  refused ~label:"not JSON" url "client_id=x";
  refused ~label:"over 5 KiB" url
    (with_fields
       [ "client_uri", `String (String.make Metadata.max_document_bytes 'a') ])
;;

let test_loopback_redirects_ignore_the_port () =
  let document = claude_code () in
  let allowed uri = Metadata.redirect_uri_allowed document uri in
  check bool "localhost on an ephemeral port" true
    (allowed "http://localhost:3118/callback");
  check bool "127.0.0.1 on an ephemeral port" true
    (allowed "http://127.0.0.1:53017/callback");
  check bool "the listed URI itself" true (allowed "http://localhost/callback");
  check bool "another path" false (allowed "http://localhost:3118/other");
  check bool "an added query" false (allowed "http://localhost:3118/callback?x=1");
  check bool "https" false (allowed "https://localhost:3118/callback");
  check bool "a host that only starts like loopback" false
    (allowed "http://127.0.0.1.attacker.example:3118/callback");
  check bool "another loopback spelling is not the listed host" false
    (allowed "http://[::1]:3118/callback");
  check bool "a line feed tail" false (allowed "http://localhost:3118/callback\nX");
  check bool "a space" false (allowed "http://localhost:3118/call back")
;;

let test_ipv6_loopback_redirects_ignore_the_port () =
  let url = "https://client.example/meta.json" in
  let body =
    Printf.sprintf
      {|{"client_id":%S,"client_name":"E","redirect_uris":["http://[::1]/cb"]}|}
      url
  in
  match Metadata.parse_document (document_url url) body with
  | Error reason -> fail reason
  | Ok document ->
    check bool "[::1] on an ephemeral port" true
      (Metadata.redirect_uri_allowed document "http://[::1]:4000/cb");
    check bool "127.0.0.1 is not the listed host" false
      (Metadata.redirect_uri_allowed document "http://127.0.0.1:4000/cb")
;;

let test_non_loopback_redirects_match_exactly () =
  let url = "https://client.example/meta.json" in
  let body =
    Printf.sprintf
      {|{"client_id":%S,"client_name":"E","redirect_uris":["https://client.example/cb"]}|}
      url
  in
  match Metadata.parse_document (document_url url) body with
  | Error reason -> fail reason
  | Ok document ->
    check bool "exact" true
      (Metadata.redirect_uri_allowed document "https://client.example/cb");
    check bool "port added" false
      (Metadata.redirect_uri_allowed document "https://client.example:8443/cb")
;;

let () =
  run
    "auth_oauth_client_metadata"
    [ ( "client id"
      , [ test_case "registered ids stay registered" `Quick
            test_registered_ids_stay_registered
        ; test_case "document URL rules" `Quick test_document_url_rules
        ] )
    ; ( "document"
      , [ test_case "Claude Code document is accepted" `Quick
            test_claude_code_document_is_accepted
        ; test_case "document rules" `Quick test_document_rules
        ] )
    ; ( "redirect"
      , [ test_case "loopback redirects ignore the port" `Quick
            test_loopback_redirects_ignore_the_port
        ; test_case "IPv6 loopback redirects ignore the port" `Quick
            test_ipv6_loopback_redirects_ignore_the_port
        ; test_case "non-loopback redirects match exactly" `Quick
            test_non_loopback_redirects_match_exactly
        ] )
    ]
;;
