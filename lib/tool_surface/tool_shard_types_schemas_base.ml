(** Tool_shard_types_schemas_base — [base_tools] always-on schemas
    every keeper sees (time, context status, memory r/w,
    tool self-introspection). *)

open Tool_shard_types_enum_mirrors

let base_tools : Masc_domain.tool_schema list =
  [ (* Time *)
    { name = "keeper_time_now"
    ; description =
        "Return the current wall-clock time as ISO 8601 and Unix epoch \
         seconds. No arguments."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; (* Context status *)
    { name = "keeper_context_status"
    ; description =
        "Return persisted checkpoint, recent-message, memory, and sandbox \
         state for this keeper turn. Context-window occupancy is not \
         currently observed."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; (* Memory *)
    { name = "keeper_memory_search"
    ; description =
        "Search keeper memory or history; current facts use explicit substring filtering and snapshot order."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; "additionalProperties", `Bool false
          ; ( "properties"
            , `Assoc
                [ ( "query"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "keyword to search for"
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
                            "Search scope: memory (default, durable facts), history \
                             (raw messages), or all" )
                      ] )
                ] )
          ; "required", `List [ `String "query" ]
          ]
    }
  ; (* Explicit memory write surface (docs/spec/05-keeper-agent.md 6 Memory Subsystem).
     Writes a durable claim
     into the Memory OS fact store (RFC keeper-memory-consolidation
     Stage 4: the turn-scoped bank is gone). *)
    { name = "keeper_memory_write"
    ; description =
        "Persist a memory entry for this keeper."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "title"
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
          ; "required", `List [ `String "content" ]
          ; "additionalProperties", `Bool false
          ]
    }
  ; (* Tool self-introspection — lets the keeper enumerate its own capabilities *)
    { name = "keeper_tools_list"
     ; description =
         "List the active keeper tool surface from descriptors and registered schemas. \
          This is capability introspection, not connector content lookup. Use \
          keeper_surface_read only for current conversation context. \
          No arguments."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ]
;;
