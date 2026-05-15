(** Tool_shard_types — pure types + enum-string SSOT mirrors extracted
    from Tool_shard (2165 LoC godfile).

    See tool_shard_types.mli for rationale and contract. *)

let pr_review_event_enum_strings = [ "COMMENT"; "APPROVE"; "REQUEST_CHANGES" ]

let memory_search_source_enum_strings = [ "memory"; "history"; "all" ]

let memory_kind_enum_strings =
  [ "constraints"; "decision"; "next"; "goal"; "progress"; "open_question"; "long_term" ]
;;

let fs_write_mode_enum_strings = [ "overwrite"; "append"; "patch" ]

let sort_order_enum_strings = [ "hot"; "trending"; "recent"; "updated"; "discussed" ]

let vote_direction_enum_strings = [ "up"; "down" ]

let keeper_shell_op_enum_strings =
  [ "pwd"
  ; "ls"
  ; "cat"
  ; "rg"
  ; "git_status"
  ; "find"
  ; "head"
  ; "tail"
  ; "wc"
  ; "tree"
  ; "git_log"
  ; "git_diff"
  ; "git_worktree"
  ; "git_clone"
  ; "gh"
  ]
;;

type shard =
  { name : string
  ; tools : Masc_domain.tool_schema list
  ; read_only_tools : string list
  ; removable : bool
  ; description : string
  }

module StringMap = Map.Make (String)

let select_named_schemas (names : string list) (schemas : Masc_domain.tool_schema list)
  : Masc_domain.tool_schema list
  =
  names
  |> List.filter_map (fun name ->
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
      schemas)
;;

let default_shard_names : string list =
  [ "base"
  ; "board"
  ; "filesystem"
  ; "shell"
  ; "library"
  ; "taskboard"
  ; "coding"
  ]
;;

let tool_spec_read_only = [ "masc_tool_list" ]
let tool_spec_destructive = [ "masc_tool_grant"; "masc_tool_revoke" ]

let tool_required_permission = function
  | "masc_tool_list" -> Some Masc_domain.CanReadState
  | "masc_tool_grant" | "masc_tool_revoke" -> Some Masc_domain.CanAdmin
  | _ -> None
;;

let tool_effect_domain name =
  match Tool_name.of_string name with
  | Some (Tool_name.Masc Tool_name.Masc.Tool_list) -> Some Tool_catalog.Read_only
  | Some (Tool_name.Masc (Tool_name.Masc.Tool_grant | Tool_name.Masc.Tool_revoke)) ->
    Some Tool_catalog.Masc_coordination
  | _ -> None
;;
let base_tools : Masc_domain.tool_schema list =
  [ (* Stay silent: no-op tool for tool_choice=Any turns.
     Lets the model explicitly skip a turn without being forced
     to call a real tool when there is nothing to do. *)
    { name = "keeper_stay_silent"
    ; description =
        "Do nothing this turn. Call when you have no pending work and no information to \
         share. Costs no resources. Prefer this over calling a tool with no purpose."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ; (* Time *)
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
         message_count, generation, last_model_used, continuity_summary, and canonical \
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
        "Search memory for past goals, decisions, progress, or conversation history. \
         Returns scored results with metadata. Default searches the structured memory \
         bank. Use 'kind' to filter (goal, decision, progress, next, open_question, \
         constraints, long_term). Use source='history' for raw user messages, \
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
                        , `List (List.map (fun s -> `String s) memory_kind_enum_strings) )
                      ; "description", `String "Filter by memory kind"
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "max results (1-10, default 5)"
                      ] )
                ; (* Issue #8484: derive from local mirror that tracks
           [Keeper_exec_memory.valid_memory_search_source_strings]. *)
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
     Symmetric to keeper_memory_search; promotes a structured note
     (kind/title/content) into the memory bank, queryable on later
     turns. long_term kind is reserved for tool-result emission and
     is rejected here. *)
    { name = "keeper_memory_write"
    ; description =
        "Promote a structured decision/question/goal/etc into the memory bank, queryable \
         on later turns by keeper_memory_search. Use when board discussion converges to \
         a fact worth crystallizing, or to record a constraint, open question, next \
         step, or progress note. Subject to per-kind cap (typically 2) and total cap \
         (12); oldest may be dropped. 'long_term' kind is reserved for tool-result \
         emission and is not callable here."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "kind"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List (List.map (fun s -> `String s) memory_kind_enum_strings) )
                      ; ( "description"
                        , `String
                            "Memory kind. One of \
                             goal/progress/next/decision/open_question/constraints. \
                             long_term not supported." )
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
                            "Body. Required, must be non-empty. For \
                             decisions/constraints, lead with the rule then **Why** and \
                             **How to apply** lines." )
                      ] )
                ] )
          ; "required", `List [ `String "kind"; `String "content" ]
          ]
    }
  ; (* Tool self-introspection — lets the keeper enumerate its own capabilities *)
    { name = "keeper_tools_list"
    ; description =
        "List all tools currently available to you, grouped by category. Use when asked \
         'what can you do?' or when you need to discover your capabilities. Returns tool \
         names organized by category. Only includes tools allowed by your current preset \
         and policy."
    ; input_schema = `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
    }
  ]
;;
