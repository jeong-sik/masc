(* The endpoint a catalogue read is taken against.

   It is built for one request and thrown away, so everything it carries is a
   decision: the kind says who is asked and how, the credential is named
   rather than carried, and the destination is the kind's own rather than the
   caller's -- a route cannot check an address or a command path it was
   handed, and taking one would let a caller aim masc at anything. *)

module Actions = Server_voice_setup_actions

let endpoint_of text =
  match Actions.catalogue_endpoint_of_json (Yojson.Safe.from_string text) with
  | Ok endpoint -> endpoint
  | Error error -> Alcotest.fail (Actions.error_message error)

let refusal_of text =
  match Actions.catalogue_endpoint_of_json (Yojson.Safe.from_string text) with
  | Ok _ -> Alcotest.fail "expected a refusal"
  | Error error -> Actions.error_message error

let test_the_kind_is_what_decides_who_is_asked () =
  let endpoint = endpoint_of {|{"kind": "macos_say"}|} in
  Alcotest.(check bool) "say" true (endpoint.Voice_config.kind = Voice_config.Macos_say);
  let endpoint = endpoint_of {|{"kind": "elevenlabs_direct"}|} in
  Alcotest.(check bool) "elevenlabs" true
    (endpoint.Voice_config.kind = Voice_config.Elevenlabs_direct)

(* The name of the variable, never the value. runtime.toml is committed, and
   the same rule the wizard and the setup routes follow applies to a read. *)
let test_the_credential_is_named_not_carried () =
  let endpoint = endpoint_of {|{"kind": "elevenlabs_direct", "api_key_env": "ELEVENLABS_API_KEY"}|} in
  Alcotest.(check (option string)) "the variable name" (Some "ELEVENLABS_API_KEY")
    endpoint.Voice_config.api_key_env;
  let endpoint = endpoint_of {|{"kind": "elevenlabs_direct", "api_key_env": "  "}|} in
  Alcotest.(check (option string)) "blank is no variable at all" None
    endpoint.Voice_config.api_key_env

(* Neither is taken from the request. A route cannot check where an address
   points or what a command path runs, so it does not accept either. *)
let test_no_destination_comes_from_the_caller () =
  let endpoint =
    endpoint_of
      {|{"kind": "macos_say", "base_url": "http://127.0.0.1:9/v1",
         "mcp_url": "http://127.0.0.1:9", "command": "/tmp/say"}|}
  in
  Alcotest.(check (option string)) "no address" None endpoint.Voice_config.base_url;
  Alcotest.(check (option string)) "no MCP address" None endpoint.Voice_config.mcp_url;
  Alcotest.(check (option string)) "no command path" None endpoint.Voice_config.command

let test_an_unknown_kind_is_refused_by_name () =
  Alcotest.(check bool) "the kind is quoted back" true
    (Astring.String.is_infix ~affix:"\"kokoro\"" (refusal_of {|{"kind": "kokoro"}|}))

let test_a_listing_without_a_kind_is_refused () =
  Alcotest.(check bool) "and the field is named" true
    (Astring.String.is_infix ~affix:"kind" (refusal_of {|{}|}))

let () =
  Alcotest.run
    "voice_catalogue_request"
    [ ( "what the request decides"
      , [ Alcotest.test_case "the kind decides who is asked" `Quick
            test_the_kind_is_what_decides_who_is_asked
        ; Alcotest.test_case "the credential is named, not carried" `Quick
            test_the_credential_is_named_not_carried
        ; Alcotest.test_case "no destination comes from the caller" `Quick
            test_no_destination_comes_from_the_caller
        ] )
    ; ( "what it refuses"
      , [ Alcotest.test_case "an unknown kind, by name" `Quick
            test_an_unknown_kind_is_refused_by_name
        ; Alcotest.test_case "a listing without a kind" `Quick
            test_a_listing_without_a_kind_is_refused
        ] )
    ]
