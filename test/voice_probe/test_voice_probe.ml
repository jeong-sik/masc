(* The probe report is a contract: the CLI prints it, and the wizard surfaces
   will read the same JSON. What these fix is the shape and the three words,
   because a reader that meets a fourth has a result this module did not write.

   The probes themselves reach endpoints over the network, so they are measured
   rather than unit-tested; docs/VOICE-RUNBOOK.md carries a dated run against a
   live configuration. *)

let attempt endpoint_id kind outcome : Masc.Voice_bridge.probe_attempt =
  { Masc.Voice_bridge.endpoint_id; kind; outcome }

let field name json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`String value) -> value
     | Some _ | None -> Alcotest.failf "field %s is not a string in the report" name)
  | _ -> Alcotest.fail "the report is not an object"

let test_each_state_has_its_own_word () =
  let of_outcome outcome =
    field "state" (Masc.Voice_bridge.probe_attempt_json
                     (attempt "e" Voice_config.Openai_compat outcome))
  in
  Alcotest.(check string) "answered" "answered"
    (of_outcome (Masc.Voice_bridge.Answered "24285 bytes of audio"));
  Alcotest.(check string) "refused" "refused"
    (of_outcome (Masc.Voice_bridge.Refused "connection refused"));
  Alcotest.(check string) "skipped" "skipped"
    (of_outcome (Masc.Voice_bridge.Skipped "disabled in the configuration"))

let test_the_report_names_the_endpoint_and_its_kind () =
  let json =
    Masc.Voice_bridge.probe_attempt_json
      (attempt "whisper-local" Voice_config.Openai_compat
         (Masc.Voice_bridge.Answered "heard it"))
  in
  Alcotest.(check string) "the endpoint id is carried" "whisper-local"
    (field "endpoint_id" json);
  Alcotest.(check string) "so is the kind, spelled as the config spells it"
    "openai_compat" (field "kind" json)

(* A transcript reaches an operator through this field. Escaping it as an OCaml
   literal turns every non-ASCII language into byte numbers, which is what the
   first measured run of the CLI printed for Korean. *)
let test_a_transcript_survives_as_written () =
  let spoken = "음성 연결을 확인합니다." in
  let json =
    Masc.Voice_bridge.probe_attempt_json
      (attempt "whisper-local" Voice_config.Openai_compat
         (Masc.Voice_bridge.Answered ("heard " ^ spoken)))
  in
  Alcotest.(check string) "the transcript is carried verbatim" ("heard " ^ spoken)
    (field "detail" json)

let test_the_readable_line_says_which_state_it_is () =
  Alcotest.(check string) "answered" "answered: 24285 bytes of audio"
    (Masc.Voice_bridge.probe_outcome_to_string
       (Masc.Voice_bridge.Answered "24285 bytes of audio"));
  Alcotest.(check string) "refused" "refused: connection refused"
    (Masc.Voice_bridge.probe_outcome_to_string
       (Masc.Voice_bridge.Refused "connection refused"));
  Alcotest.(check string) "skipped reads as not asked, not as a failure"
    "not asked: disabled in the configuration"
    (Masc.Voice_bridge.probe_outcome_to_string
       (Masc.Voice_bridge.Skipped "disabled in the configuration"))


(* Which transport is asked for a transcript. Every kind is spelled out rather
   than grouped, because the bug this pins was a kind that existed and was
   never considered: the two command kinds reached main while the probe still
   matched on three, and nothing was red until a build. *)
let test_every_kind_says_how_it_transcribes () =
  let transcriber = Masc.Voice_bridge.transcriber_of_kind in
  let open Masc.Voice_bridge in
  Alcotest.(check bool) "openai_compat is an address" true
    (transcriber Voice_config.Openai_compat = Over_http);
  Alcotest.(check bool) "so is elevenlabs" true
    (transcriber Voice_config.Elevenlabs_direct = Over_http);
  Alcotest.(check bool) "whisper is run, not reached" true
    (transcriber Voice_config.Whisper_cli = By_command);
  Alcotest.(check bool) "say speaks and has no ear" true
    (transcriber Voice_config.Macos_say = Does_not_transcribe);
  Alcotest.(check bool) "the mcp endpoint carries a tool call, not audio" true
    (transcriber Voice_config.Voice_mcp = Does_not_transcribe)

let transcript json =
  match Masc.Voice_bridge.transcript_of_stt_json json with
  | Ok text -> Ok text
  | Error reason -> Error reason

(* Silence is an answer. A person who recorded nothing and a person whose
   endpoint answered an error both need to know which of the two happened, and
   an empty transcript is how the first one reads. *)
let test_an_empty_transcript_is_still_a_transcript () =
  Alcotest.(check (result string string)) "what was heard"
    (Ok "안녕하세요") (transcript (`Assoc [ "text", `String "안녕하세요" ]));
  Alcotest.(check (result string string)) "and hearing nothing"
    (Ok "") (transcript (`Assoc [ "text", `String "" ]))

(* The body that has no transcript in it. Read as an empty transcript, this
   endpoint would be reported as a quiet microphone -- the one thing the probe
   is there to tell apart from an endpoint that did not answer properly. *)
let test_a_body_without_a_transcript_is_not_silence () =
  let refused json =
    match transcript json with
    | Error _ -> true
    | Ok _ -> false
  in
  Alcotest.(check bool) "an error body names no transcript" true
    (refused (`Assoc [ "error", `String "model not found" ]));
  Alcotest.(check bool) "neither does a number in the text field" true
    (refused (`Assoc [ "text", `Int 3 ]));
  Alcotest.(check bool) "nor a body that is not an object at all" true
    (refused (`List []))


(* The runtime path has to route the same way the probe does. It did not: the
   command transport was wired into probe_stt only, so a configured
   whisper_cli endpoint -- the one kind that transcribes without a server --
   was sent an HTTP request it has no address for, and [/transcribe] reported
   every endpoint as failed while [voice-verify --audio] on the same
   configuration worked (#35569, and the Codex review of #35526).

   Counted rather than exercised: [transcribe_audio] loads the workspace's
   voice configuration and reaches real endpoints, so what a test can hold
   here is that the routing is read at all. What it routes to is
   {!transcriber_of_kind}, which the cases above pin. *)
let voice_bridge_path = "lib/voice/voice_bridge.ml"

let test_the_runtime_loop_routes_by_kind () =
  Alcotest.(check int) "transcribe_audio is where the loop lives" 1
    (Ast_grep.count_value_bindings ~module_path:voice_bridge_path
       ~name:"transcribe_audio");
  Alcotest.(check int) "and it asks which transport this endpoint is" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:voice_bridge_path
       ~binding_name:"transcribe_audio" ~callee:"transcriber_of_kind")

let test_the_runtime_loop_can_reach_the_command_transport () =
  Alcotest.(check int) "a command kind is run, not addressed" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:voice_bridge_path
       ~binding_name:"transcribe_audio" ~callee:"transcribe_via_command")


(* [timeout_seconds] was in the configuration, its writer, the routes and the
   wizard, and nothing read it: an operator who asked for a longer wait got
   the workspace-wide one. whisper-cli on a CPU-only host is the case that
   makes it matter -- a longer recording does not finish in the HTTP default.
   (Codex review of #35526 and of #35627.) *)
let endpoint_with ?timeout_seconds kind id : Voice_config.endpoint =
  { Voice_config.id
  ; kind
  ; base_url = None
  ; mcp_url = None
  ; health_url = None
  ; api_key_env = None
  ; enabled = true
  ; timeout_seconds
  ; default_voice = None
  ; command = None
  }

let test_an_endpoint_that_names_a_timeout_is_given_it () =
  Alcotest.(check (float 0.001)) "the endpoint's own seconds" 600.
    (Voice_bridge_transport.endpoint_timeout_sec
       (endpoint_with ~timeout_seconds:600. Voice_config.Whisper_cli "whisper-local"))

let test_without_one_the_workspace_value_stands () =
  let seconds ?timeout_seconds () =
    Voice_bridge_transport.endpoint_timeout_sec
      (endpoint_with ?timeout_seconds Voice_config.Openai_compat "remote")
  in
  let unnamed = seconds () in
  Alcotest.(check bool) "the fallback is a wait, not zero" true (unnamed > 0.);
  (* A wait of zero or less is not a shorter wait. Until the configuration
     reader refuses one (#35641) it is read as not having been named. *)
  Alcotest.(check (float 0.001)) "a value at or below zero is read as unnamed"
    unnamed
    (seconds ~timeout_seconds:0. ());
  Alcotest.(check bool) "and a named one is not the fallback" false
    (Float.equal unnamed (seconds ~timeout_seconds:600. ()))

let () =
  Alcotest.run
    "voice_probe"
    [ ( "report contract"
      , [ Alcotest.test_case "each state has its own word" `Quick
            test_each_state_has_its_own_word
        ; Alcotest.test_case "the report names the endpoint and its kind" `Quick
            test_the_report_names_the_endpoint_and_its_kind
        ; Alcotest.test_case "a transcript survives as written" `Quick
            test_a_transcript_survives_as_written
        ; Alcotest.test_case "the readable line says which state it is" `Quick
            test_the_readable_line_says_which_state_it_is
        ] )
    ; ( "which transport answers a transcript"
      , [ Alcotest.test_case "every kind says how it transcribes" `Quick
            test_every_kind_says_how_it_transcribes
        ; Alcotest.test_case "an empty transcript is still a transcript" `Quick
            test_an_empty_transcript_is_still_a_transcript
        ; Alcotest.test_case "a body without a transcript is not silence" `Quick
            test_a_body_without_a_transcript_is_not_silence
        ; Alcotest.test_case "the runtime loop routes by kind" `Quick
            test_the_runtime_loop_routes_by_kind
        ; Alcotest.test_case "the runtime loop can reach the command transport" `Quick
            test_the_runtime_loop_can_reach_the_command_transport
        ] )
    ; ( "how long an endpoint is given"
      , [ Alcotest.test_case "an endpoint that names a timeout is given it" `Quick
            test_an_endpoint_that_names_a_timeout_is_given_it
        ; Alcotest.test_case "without one the workspace value stands" `Quick
            test_without_one_the_workspace_value_stands
        ] )
    ]
