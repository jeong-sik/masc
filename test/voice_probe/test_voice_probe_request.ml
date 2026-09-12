(* What the two route tables read out of a probe request. Server_voice_probe
   exists so the HTTP/1 router and the HTTP/2 gateway cannot come to read it
   differently, and these fix the part that answers without reaching an
   endpoint: the refusals, and the extension a transcription probe gives its
   temporary copy of the body.

   A probe that gets past these reaches the network, so it is measured rather
   than unit-tested; docs/VOICE-RUNBOOK.md carries a dated run. *)

let suffix = Server_voice_probe.audio_suffix_of_content_type

let error_of = function
  | Ok _ -> Alcotest.fail "expected the request to be refused"
  | Error reason -> reason

let test_the_extension_follows_the_declared_media_type () =
  Alcotest.(check string) "wav" ".wav" (suffix (Some "audio/wav"));
  Alcotest.(check string) "mp4" ".mp4" (suffix (Some "audio/mp4"));
  Alcotest.(check string) "ogg" ".ogg" (suffix (Some "audio/ogg"));
  (* A browser sends the codec beside the type, and the header may be spelled
     in any case. *)
  Alcotest.(check string) "parameters are not part of the type" ".webm"
    (suffix (Some "audio/webm;codecs=opus"));
  Alcotest.(check string) "the type is matched case-insensitively" ".mp3"
    (suffix (Some "  AUDIO/MPEG  "))

let test_an_unnamed_body_is_recorded_audio () =
  (* The fallback is what a browser records, not a guess at an unknown format:
     an absent or unrecognised type still has to reach the transcriber as
     something, and every caller of this route is a recorder. *)
  Alcotest.(check string) "absent" ".webm" (suffix None);
  Alcotest.(check string) "unrecognised" ".webm"
    (suffix (Some "application/octet-stream"))

let test_a_synthesis_probe_needs_a_sentence () =
  Alcotest.(check string) "a body that is not JSON says so"
    "the request body is not JSON"
    (error_of (Server_voice_probe.tts_report ~body:"not json"));
  let needs_message =
    "a probe needs a non-empty \"message\" for the endpoints to synthesize"
  in
  Alcotest.(check string) "no message" needs_message
    (error_of (Server_voice_probe.tts_report ~body:"{}"));
  Alcotest.(check string) "blank message" needs_message
    (error_of (Server_voice_probe.tts_report ~body:{|{"message":"   "}|}));
  Alcotest.(check string) "message of the wrong type" needs_message
    (error_of (Server_voice_probe.tts_report ~body:{|{"message":7}|}));
  Alcotest.(check string) "a body that is not an object" needs_message
    (error_of (Server_voice_probe.tts_report ~body:"[]"))

let test_a_transcription_probe_needs_audio () =
  (* Refused before a temporary file is made: an empty body is a caller that
     sent nothing, not a recording of silence. *)
  Alcotest.(check string) "empty body" "empty audio body"
    (error_of (Server_voice_probe.stt_report ~content_type:None ~body:""))

let () =
  Alcotest.run "voice probe request"
    [ ( "reading the request"
      , [ Alcotest.test_case "the extension follows the declared media type" `Quick
            test_the_extension_follows_the_declared_media_type
        ; Alcotest.test_case "an unnamed body is recorded audio" `Quick
            test_an_unnamed_body_is_recorded_audio
        ; Alcotest.test_case "a synthesis probe needs a sentence" `Quick
            test_a_synthesis_probe_needs_a_sentence
        ; Alcotest.test_case "a transcription probe needs audio" `Quick
            test_a_transcription_probe_needs_audio
        ] )
    ]
