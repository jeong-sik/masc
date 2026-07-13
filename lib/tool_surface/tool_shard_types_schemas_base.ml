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
        "Search memory for explicit durable notes or conversation history. \
         Returns results with provenance metadata. Default searches the structured memory \
         bank. Use 'kind' to filter the typed note categories exposed by the runtime. \
         Use source='history' for raw user messages, \
         source='all' for both."
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
                      [ (* Issue #18472: LLM keepers emit [limit] as a JSON
                           string (["5"]); strict ["integer"] routes through
                           [correction_pipeline] for a silent coerce. The
                           runtime handler reads via [Safe_ops.json_int] /
                           [json_float] which accepts both shapes, so this is
                           wire-format only. Mirrors PR #19383's widening on
                           [tool_execute.timeout_sec]. *)
                        ( "type"
                        , `List [ `String "integer"; `String "string" ] )
                      ; ( "description"
                        , `String
                            "max results (1-10, default 5). Numeric strings \
                             (e.g. \"5\") are accepted; prefer the bare \
                             integer form." )
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
     Symmetric to the memory search tool; promotes a structured note
     (kind/title/content) into the memory bank, queryable on later
     turns. long_term kind is reserved for tool-result emission and
     is rejected here. *)
    { name = "keeper_memory_write"
    ; description =
        "Promote an explicit decision, question, goal, or progress note into the memory \
         bank for later search. Task sequencing and operating constraints belong to \
         their typed domain stores, not memory prose. The runtime records explicit \
         typed provenance and returns validation or persistence failures directly. \
         'long_term' kind is reserved for tool-result emission and is not callable here."
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
                               writable_memory_kind_enum_strings) )
                      ; ( "description"
                        , `String
                            "Memory kind. One of \
                             goal/progress/decision/open_question. long_term not \
                             supported." )
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
