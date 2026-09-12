(* Asking an endpoint which voices it has.

   The shape here is the one ElevenLabs answered with on 2026-09-12: a GET to
   /v2/voices with an xi-api-key header returned 200 and an object carrying
   has_more, next_page_token, total_count and voices, each voice an object with
   voice_id, name and a labels object holding language. The ids are twenty
   opaque characters, which is the whole reason this exists -- nobody types
   one from memory.

   The rows below use ids of that shape rather than the account's own: what the
   parser needs to be right about is the shape, and a test does not need to
   carry someone's voice library to hold it. *)

module Voice = Masc.Voice_bridge

let voice = Alcotest.testable (fun fmt (v : Voice.catalogue_voice) ->
  Format.fprintf fmt "%s/%s/%s" v.Voice.voice_id
    (Option.value v.Voice.voice_name ~default:"-")
    (Option.value v.Voice.voice_language ~default:"-"))
  (fun a b -> a = b)

let answer =
  {|{
    "voices": [
      { "voice_id": "QQ00AAbbCCddEEffGGhh", "name": "Korean Bright Voice",
        "labels": { "language": "ko", "accent": "seoul" } },
      { "voice_id": "RR11BBccDDeeFFggHHii", "name": "Han Aim",
        "labels": { "language": "ko" } },
      { "voice_id": "SS22CCddEEffGGhhIIjj", "name": "English Narrator",
        "labels": {} }
    ],
    "has_more": false,
    "total_count": 3
  }|}

let parse text = Voice.catalogue_voices_of_json (Yojson.Safe.from_string text)

let test_the_answer_becomes_pickable_rows () =
  match parse answer with
  | Error message -> Alcotest.fail message
  | Ok voices ->
    Alcotest.(check int) "every voice in the answer" 3 (List.length voices);
    Alcotest.check voice "the first, with its language"
      { Voice.voice_id = "QQ00AAbbCCddEEffGGhh"
      ; voice_name = Some "Korean Bright Voice"
      ; voice_language = Some "ko"
      }
      (List.nth voices 0);
    (* A voice whose labels carry no language is still pickable; it just shows
       without one. Dropping it would hide voices for a field that is not
       required. *)
    Alcotest.check voice "the one with no language label"
      { Voice.voice_id = "SS22CCddEEffGGhhIIjj"
      ; voice_name = Some "English Narrator"
      ; voice_language = None
      }
      (List.nth voices 2)

(* An id is what the configuration stores. A row without one cannot be chosen,
   and a list that offers unchoosable rows is worse than a shorter list. *)
let test_a_row_without_an_id_is_dropped () =
  match parse {|{"voices": [{"name": "nameless"}, {"voice_id": "abc", "name": "ok"}]}|} with
  | Error message -> Alcotest.fail message
  | Ok voices ->
    Alcotest.(check int) "only the one that can be chosen" 1 (List.length voices);
    Alcotest.(check string) "and it is that one" "abc"
      (List.nth voices 0).Voice.voice_id

(* A nameless voice keeps its namelessness. Standing the id in for it here
   would make it indistinguishable from a voice actually named after its id,
   and the screen is where that choice belongs. *)
let test_a_voice_without_a_name_keeps_the_absence () =
  match parse {|{"voices": [{"voice_id": "only-an-id"}]}|} with
  | Error _ -> Alcotest.fail "a voice with an id should parse"
  | Ok voices ->
    Alcotest.(check bool) "the name is absent, not invented" true
      (Option.is_none (List.nth voices 0).Voice.voice_name);
    Alcotest.(check string) "and the id is still there" "only-an-id"
      (List.nth voices 0).Voice.voice_id

let test_an_answer_without_voices_is_an_error () =
  (match parse {|{"detail": "unauthorized"}|} with
   | Ok _ -> Alcotest.fail "an answer with no voices list should not parse as voices"
   | Error message ->
     Alcotest.(check bool) "and says what was missing" true
       (String.length message > 0));
  match parse {|["not", "an", "object"]|} with
  | Ok _ -> Alcotest.fail "a list is not an answer"
  | Error _ -> ()

(* The catalogue lives on a different API version than everything else masc
   sends ElevenLabs: /v1 carries speech, /v2 carries this. *)
let endpoint ~kind ~base_url =
  { Voice_config.id = "under-test"
  ; kind
  ; base_url
  ; mcp_url = None
  ; health_url = None
  ; api_key_env = Some "A_VARIABLE"
  ; enabled = true
  ; timeout_seconds = None
  ; default_voice = None
  ; command = None
  }

let test_elevenlabs_is_asked_on_the_catalogue_version () =
  match
    Voice_runtime_overlay.voice_listing_request_for_endpoint
      (endpoint ~kind:Voice_config.Elevenlabs_direct
         ~base_url:(Some "https://api.elevenlabs.io/v1"))
      ~api_key:"a-key"
  with
  | Error message -> Alcotest.fail message
  | Ok request ->
    Alcotest.(check string) "the version is swapped, not appended"
      "https://api.elevenlabs.io/v2/voices" request.Voice_runtime_overlay.listing_url;
    Alcotest.(check (list (pair string string))) "and it carries the key header"
      [ "xi-api-key", "a-key" ] request.Voice_runtime_overlay.listing_headers

(* A base that names no version is asked as it stands. Guessing a version onto
   someone's proxy address would ask a different server than the one speech
   goes to. *)
let test_a_base_without_a_version_is_asked_as_it_stands () =
  match
    Voice_runtime_overlay.voice_listing_request_for_endpoint
      (endpoint ~kind:Voice_config.Elevenlabs_direct
         ~base_url:(Some "https://voices.internal"))
      ~api_key:"a-key"
  with
  | Error message -> Alcotest.fail message
  | Ok request ->
    Alcotest.(check string) "asked where it was pointed"
      "https://voices.internal/voices" request.Voice_runtime_overlay.listing_url

(* The honest answer for the other two kinds. The OpenAI shape takes a voice
   name and publishes no listing beside it, and the two local servers the
   runbook names answered 404 to a guess at one on 2026-09-12. *)
let test_the_other_kinds_say_there_is_nothing_to_ask () =
  let refused kind base_url =
    match
      Voice_runtime_overlay.voice_listing_request_for_endpoint
        (endpoint ~kind ~base_url) ~api_key:"a-key"
    with
    | Ok request ->
      Alcotest.failf "expected a refusal, got %s" request.Voice_runtime_overlay.listing_url
    | Error message -> message
  in
  let openai = refused Voice_config.Openai_compat (Some "http://127.0.0.1:8000/v1") in
  Alcotest.(check bool) "the OpenAI refusal names the endpoint" true
    (String.length openai > 0);
  let mcp = refused Voice_config.Voice_mcp (Some "http://127.0.0.1:9000") in
  Alcotest.(check bool) "the tool refusal names the endpoint" true
    (String.length mcp > 0)

let test_command_catalogues_are_not_http_requests () =
  List.iter
    (fun kind ->
      match
        Voice_runtime_overlay.voice_listing_request_for_endpoint
          (endpoint ~kind ~base_url:None) ~api_key:""
      with
      | Ok _ -> Alcotest.fail "a command must not produce an HTTP catalogue request"
      | Error message ->
        Alcotest.(check string) "the refusal names the transport, not a missing URL"
          "voice config endpoint under-test runs a command and has no HTTP voice catalogue"
          message)
    [ Voice_config.Macos_say; Voice_config.Whisper_cli ]

let test_http_and_command_catalogues_share_the_wire_shape () =
  let expected =
    `Assoc
      [ "id", `String "Yuna"
      ; "name", `String "Yuna"
      ; "language", `String "ko_KR"
      ]
  in
  let say = Voice.say_catalogue_of_output "Yuna  ko_KR  # hello" in
  let http =
    match parse {|{"voices":[{"voice_id":"Yuna","name":"Yuna","labels":{"language":"ko_KR"}}]}|} with
    | Ok voices -> voices
    | Error message -> Alcotest.fail message
  in
  List.iter
    (fun voices ->
      match voices with
      | [ voice ] ->
        Alcotest.(check string) "the transport does not change the catalogue shape"
          (Yojson.Safe.to_string expected)
          (Yojson.Safe.to_string (Voice.catalogue_voice_json voice))
      | _ -> Alcotest.fail "expected one pickable voice")
    [ say; http ]

let () =
  Alcotest.run
    "voice_catalog"
    [ ( "what the endpoint answered"
      , [ Alcotest.test_case "the answer becomes pickable rows" `Quick
            test_the_answer_becomes_pickable_rows
        ; Alcotest.test_case "a row without an id is dropped" `Quick
            test_a_row_without_an_id_is_dropped
        ; Alcotest.test_case "a voice without a name keeps the absence" `Quick
            test_a_voice_without_a_name_keeps_the_absence
        ; Alcotest.test_case "an answer without voices is an error" `Quick
            test_an_answer_without_voices_is_an_error
        ; Alcotest.test_case "HTTP and command catalogues share the wire shape" `Quick
            test_http_and_command_catalogues_share_the_wire_shape
        ] )
    ; ( "what gets asked"
      , [ Alcotest.test_case "elevenlabs is asked on the catalogue version" `Quick
            test_elevenlabs_is_asked_on_the_catalogue_version
        ; Alcotest.test_case "a base without a version is asked as it stands" `Quick
            test_a_base_without_a_version_is_asked_as_it_stands
        ; Alcotest.test_case "the other kinds say there is nothing to ask" `Quick
            test_the_other_kinds_say_there_is_nothing_to_ask
        ; Alcotest.test_case "command catalogues are not HTTP requests" `Quick
            test_command_catalogues_are_not_http_requests
        ] )
    ]
