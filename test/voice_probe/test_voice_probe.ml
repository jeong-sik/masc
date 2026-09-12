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
    ]
