(** Tool_shard_types_schemas_voice — keeper_voice_* tool schemas. *)

let voice_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_voice_speak"
    ; description =
        "Speak a short utterance via the voice bridge. Blocks until playback finishes \
         and returns played_seconds. Do NOT call again until you receive the result — \
         concurrent calls are serialized by a global lock. Duplicate identical messages \
         within 30s are silently skipped."
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
                      ; "description", `String "Optional queue priority"
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
        "Get your own voice configuration (assigned voice, available voices). No network \
         required."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; { name = "keeper_voice_sessions"
    ; description = "List active voice sessions from the voice bridge."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; { name = "keeper_voice_session_start"
    ; description =
        "Start a voice session for this keeper using the configured voice bridge."
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
