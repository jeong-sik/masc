open Masc_domain

let property name kind description =
  name, `Assoc [ "type", `String kind; "description", `String description ]
;;

let object_schema ?(required = []) properties =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc properties
    ; "required", `List (List.map (fun name -> `String name) required)
    ; "additionalProperties", `Bool false
    ]
;;

let string_enum_property name values description =
  ( name
  , `Assoc
      [ "type", `String "string"
      ; "enum", `List (List.map (fun value -> `String value) values)
      ; "description", `String description
      ] )
;;

let artifact_read =
  { name = "keeper_artifact_read"
  ; description =
      "Read an explicit byte range from a [masc:blob ...] ToolResult. Use \
       the marker's sha256, then continue with the returned next_offset. \
       Text pages use UTF-8; arbitrary bytes use base64. The full artifact \
       is never restored into model history."
  ; input_schema =
      object_schema
        ~required:[ "sha256" ]
        [ property "sha256" "string" "Exact sha256 from a [masc:blob ...] ToolResult."
        ; ( "offset"
          , `Assoc
              [ "type", `String "integer"
              ; "minimum", `Int 0
              ; "default", `Int 0
              ; "description", `String "Byte offset to read from."
              ] )
        ; ( "max_bytes"
          , `Assoc
              [ "type", `String "integer"
              ; "minimum", `Int Keeper_artifact_read.minimum_max_bytes
              ; "maximum", `Int Keeper_artifact_read.maximum_max_bytes
              ; "default", `Int Keeper_artifact_read.default_max_bytes
              ; "description", `String "Maximum source bytes to expose in this model-visible page."
              ] )
        ]
  }
;;

let fusion = Keeper_runtime_schemas_toml.fusion

let fusion_status =
  { name = "masc_fusion_status"
  ; description =
      "Read the status of out-of-band fusion deliberations started by \
       masc_fusion. With no argument, lists tracked runs (in-progress and \
       recently completed); with a run_id, returns that single run. Each run \
       reports keeper, preset, started_at (unix seconds), and status \
       (running | completed | failed); failed runs also carry error and \
       failure_code. Prefer waiting for the completion wake over polling \
       this tool — the result reaches you without it. Read-only — does not \
       start a deliberation. In-memory and server-lifetime: runs do not \
       survive a restart."
  ; input_schema =
      object_schema
        [ property
            "run_id"
            "string"
            "Optional fusion run id (the run_id returned by masc_fusion). When \
             given, returns that single run's status; when omitted, lists every \
             tracked run (in-progress and recently completed)."
        ]
  }
;;

let analyze_image =
  { name = "analyze_image"
  ; description =
      "Read a stored image artifact and return a text description or answer. \
       Delegates to a vision model in a sub-call; the image is never added to \
       this conversation. Returns the extracted text, or a typed error \
       (invalid_args | eio_context_unavailable | artifact_load_failed | \
       invalid_timeout | image_too_large | invalid_media_type | \
       invalid_request | no_capable_runtime | empty_extraction | \
       truncated_extraction | timeout | provider_error)."
  ; input_schema =
      object_schema
        ~required:[ "artifact"; "query" ]
        [ property
            "artifact"
            "string"
            "Handle of a stored image artifact (the content-addressed id returned \
             when the image was stored). The raw image is read in a vision sub-call \
             and never enters this conversation."
        ; property
            "query"
            "string"
            "What to ask about the image, e.g. \"describe the chart\" or \
             \"transcribe the text\"."
        ; string_enum_property
            "media_type"
            Keeper_vision_tool.supported_image_media_types
            "Optional image MIME type override (e.g. image/png, image/jpeg). \
             Sniffed from the bytes when omitted."
        ]
  }
;;

let schemas = [ artifact_read; fusion; fusion_status; analyze_image ]
