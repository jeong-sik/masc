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
         available voices, active voice session state, available conversation \
         modes, and voice_loop guidance. Without MASC_VOICE_REALTIME_WS_URL, \
         operator audio is transcribed to normal keeper text turns and keeper \
         output uses keeper_voice_speak/dashboard audio clips. No network \
         required."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; { name = "keeper_voice_sessions"
    ; description = "List active voice sessions from the voice bridge."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; { name = "keeper_voice_session_start"
    ; description =
        "Start a voice session for this keeper. Defaults to turn_based batch \
         STT/TTS. conversation_mode=realtime_bridge is accepted only when \
         MASC_VOICE_REALTIME_WS_URL points at a configured realtime audio bridge; \
         otherwise the tool fails closed instead of pretending a duplex stream \
         exists."
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
                ; ( "conversation_mode"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List [ `String "turn_based"; `String "realtime_bridge" ] )
                      ; ( "description"
                        , `String
                            "Optional mode. realtime_bridge requires \
                             MASC_VOICE_REALTIME_WS_URL." )
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
