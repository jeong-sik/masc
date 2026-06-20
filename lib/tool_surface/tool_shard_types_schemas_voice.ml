(** Tool_shard_types_schemas_voice — keeper_voice_* tool schemas. *)

let voice_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_voice_speak"
    ; description =
        "Speak a short utterance via the voice bridge. Blocks until local playback \
         finishes: status='spoken' with played_seconds means the user has already \
         heard it — do NOT repeat or rephrase the same content. Duplicate identical \
         messages within 30s return status='dedup_skipped' without playing. TTS or \
         playback failures are returned as errors (ok=false), not silent successes. \
         Concurrent calls are serialized by a global lock."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "message"
                  , `Assoc
                      [ "type", `String "string"; "description", `String "Text to speak" ]
                  )
                ; ( "provider"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Optional voice provider override"
                      ] )
                ; ( "priority"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "Optional priority hint for the TTS endpoint"
                      ] )
                ; ( "audio_device"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description"
                        , `String
                            "Optional target output device id/name for the dashboard/client"
                      ] )
                ] )
          ; "required", `List [ `String "message" ]
          ]
    }
  ; { name = "keeper_voice_listen"
    ; description =
        "Record user speech via microphone and transcribe to text. Starts recording, \
         waits for speech, stops on silence (2s), then returns transcribed text."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "timeout_seconds"
                  , `Assoc
                      [ "type", `String "number"
                      ; ( "description"
                        , `String "Max recording duration in seconds (default 15)" )
                      ] )
                ; ( "language_code"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "ISO language hint, e.g. ko, en"
                      ] )
                ] )
          ]
    }
  ; { name = "keeper_voice_agent"
    ; description =
        "Get your own voice capability and configuration. Reports assigned voice, \
         available voices, active turn-based voice session state, and \
         voice_loop guidance: operator audio is transcribed to normal keeper text \
         turns, while keeper output uses keeper_voice_speak and dashboard audio \
         clips. realtime_supported=false means no full-duplex live audio stream is \
         bound to keeper turns. No network required."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; { name = "keeper_voice_sessions"
    ; description = "List active voice sessions from the voice bridge."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; { name = "keeper_voice_session_start"
    ; description =
        "Start a turn-based voice session for this keeper. The result includes \
         voice_loop guidance that tells the keeper and dashboard how operator \
         speech is transcribed and how keeper output is played."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "session_name"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Optional session name"
                      ] )
                ] )
          ]
    }
  ; { name = "keeper_voice_session_end"
    ; description =
        "End the active voice session for this keeper and release bridge resources."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ]
;;
