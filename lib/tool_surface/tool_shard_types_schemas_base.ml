(** Tool_shard_types_schemas_base — [base_tools] always-on schemas
    every keeper sees (time, context status, memory r/w,
    tool self-introspection). *)

open Tool_shard_types_enum_mirrors

let base_tools : Masc_domain.tool_schema list =
  [ (* Time *)
    { name = "keeper_time_now"
    ; description =
        "Get current server time. Returns now_iso (ISO8601) and now_unix (float). Use to \
         timestamp events, check elapsed time, or include current time in reports."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; (* Context status *)
    { name = "keeper_context_status"
    ; description =
        "Check your own context window usage and session state. Returns: name (your \
         keeper name), context_ratio (0.0-1.0), context_tokens, context_max, \
         message_count, generation, last_model_used, and canonical \
         sandbox paths (sandbox_root, sandbox_mind, sandbox_repos) plus backend/profile \
         metadata. sandbox paths are tool-ready and can be passed directly as path or \
         cwd to keeper tools without prefix. Use when deciding whether to compact \
         context, extend turns, hand off to the next generation, or resolve a path \
         without string-interpolating your own keeper name."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; (* Memory *)
    { name = "keeper_memory_search"
    ; description =
        "Search this run's working notes or conversation history. \
         Returns results with provenance metadata. Default searches the structured memory \
         bank. Use 'kind' to filter the typed note categories exposed by the runtime. \
         Use source='history' for raw user messages, \
         source='all' for both. Durable long_term claims are not searched here; they \
         are rendered into your context automatically."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "query"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "keyword to search for"
                      ] )
                ; ( "kind"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            (List.map
                               (fun s -> `String s)
                               memory_kind_enum_strings) )
                      ; "description", `String "Filter by memory kind"
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ (* #18472 widening removed: a multi-type schema trips
                           OAS #2343 fail-closed and crashes the keeper cycle, so
                           [limit] stays a single scalar "integer". Wire contract:
                           Tool_input_validation rejects a string [limit] against
                           this integer schema (OAS 0.212 strict typing) in
                           keeper_tools_oas_handler, before Safe_ops.json_int would
                           coerce it, so the description must ask for a bare integer,
                           not a numeric string (codex #25274 P2). *)
                        ( "type", `String "integer" )
                      ; ( "description"
                        , `String
                            "max results (1-10, default 5). Must be a bare \
                             integer (e.g. 5); a quoted value is rejected." )
                      ] )
                ; (* Issue #8484: derive from local mirror that tracks
           [Keeper_tool_memory_runtime.valid_memory_search_source_strings]. *)
                  ( "source"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            (List.map
                               (fun s -> `String s)
                               memory_search_source_enum_strings) )
                      ; ( "description"
                        , `String
                            "Search scope: memory (default, structured notes), history \
                             (raw messages), or all" )
                      ] )
                ] )
          ; "required", `List [ `String "query" ]
          ]
    }
  ; (* RFC-0035 P4: explicit memory write surface.
     Symmetric to the memory search tool; takes a structured note
     (kind/title/content). RFC-0351 L1: the kind picks the store —
     long_term writes the durable claim recall reads back on later
     turns, the rest write turn-scoped working notes. *)
    { name = "keeper_memory_write"
    ; description =
        "Record something you want to keep. 'long_term' writes a durable claim that \
         later turns read back; the other kinds write a working note for the run in \
         progress, searchable but not carried forward on its own. Your context resets \
         between turns, so a conclusion you leave only in this turn's reasoning is \
         gone. Task sequencing and operating constraints belong to their typed domain \
         stores, not memory prose. The runtime records explicit typed provenance and \
         returns validation or persistence failures directly."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "kind"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            (List.map
                               (fun s -> `String s)
                               memory_kind_enum_strings) )
                      ; ( "description"
                        , `String
                            "Memory kind. 'long_term' is the durable store later \
                             turns read back; goal/progress/decision/open_question \
                             are working notes for the run in progress." )
                      ] )
                ; ( "title"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Short hook (≤120 chars). Optional; may be empty." )
                      ] )
                ; ( "content"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Body. Required, must be non-empty. For decisions, lead with \
                             the decision then **Why** and **How to apply** lines." )
                      ] )
                ] )
          ; "required", `List [ `String "kind"; `String "content" ]
          ]
    }
  ; (* Tool self-introspection — lets the keeper enumerate its own capabilities *)
    { name = "keeper_tools_list"
     ; description =
         "List all tools currently available to you, grouped by category. Use when asked \
         'what can you do?' or when you need to discover your capabilities. Do not use \
         this to answer connector content questions or channel registry questions; use \
         keeper_surface_read only for current connected-surface lane context and state \
         the limitation if a connector-wide registry is unavailable. Returns tool names \
         organized by category plus descriptor_surface metadata with executor, \
         schema-shape, and typed usage examples."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ]
;;
