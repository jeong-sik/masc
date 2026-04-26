(** Tool_autoresearch_schemas — autoresearch + swarm-facing synthesis schema definitions.

    Extracted from tool_autoresearch.ml to keep schema data separate from logic.

    @since 2.80.0 *)

let schemas : Types.tool_schema list =
  [ { name = "masc_autoresearch_start"
    ; description =
        "Start a solo experiment loop: iteratively modify a target file to optimize a \
         metric. Each cycle: read file -> LLM generates change -> measure -> keep if \
         improved, discard if not. Runs autonomously until max_cycles, target_score, or \
         stopped. Returns loop_id. Requires: goal, metric_fn (shell command outputting a \
         float), target_file. Set lower_is_better=true for metrics where lower values \
         are better (e.g., loss, BPB). Optionally set target_score to stop as soon as \
         the threshold is reached."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "goal"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "What to optimize (e.g. 'Reduce inference latency')" )
                      ] )
                ; ( "metric_fn"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Shell command that outputs a single float on its last line \
                             (e.g. 'python eval.py --metric accuracy'). Higher is better \
                             by default; set lower_is_better=true to invert." )
                      ] )
                ; ( "workdir"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Working directory for git operations and metric_fn \
                             (default: MASC base path)" )
                      ] )
                ; ( "max_cycles"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String "Maximum number of experiment cycles (default: 100)" )
                      ] )
                ; ( "cycle_timeout_s"
                  , `Assoc
                      [ "type", `String "number"
                      ; ( "description"
                        , `String "Timeout per cycle in seconds (default: 300 = 5min)" )
                      ] )
                ; ( "baseline"
                  , `Assoc
                      [ "type", `String "number"
                      ; ( "description"
                        , `String
                            "Initial baseline score. If omitted, measured by running \
                             metric_fn once." )
                      ] )
                ; ( "target_score"
                  , `Assoc
                      [ "type", `String "number"
                      ; ( "description"
                        , `String
                            "Optional success threshold. Higher-or-equal wins by \
                             default; with lower_is_better=true, lower-or-equal wins." )
                      ] )
                ; ( "model_model"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Model label for code change generation (uses cascade \
                             default)" )
                      ] )
                ; ( "lower_is_better"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; ( "description"
                        , `String
                            "When true, lower metric values are better (e.g., loss, \
                             BPB). Default: false (higher is better)." )
                      ] )
                ; ( "target_file"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "File that the MODEL will read and modify (relative to \
                             workdir). The MODEL receives the full file, generates a \
                             modified version, and writes it back." )
                      ] )
                ] )
          ; ( "required"
            , `List [ `String "goal"; `String "metric_fn"; `String "target_file" ] )
          ]
    }
  ; { name = "masc_autoresearch_status"
    ; description =
        "Get the current status of an autoresearch loop. Returns: loop_id, cycle count, \
         baseline, best score, target_score, target_reached, keep/discard counts, recent \
         history."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "loop_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Loop ID (optional, uses latest if omitted)" )
                      ] )
                ] )
          ]
    }
  ; { name = "masc_autoresearch_stop"
    ; description =
        "Stop a running autoresearch loop. The loop will finish its current cycle and \
         save final state."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "loop_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Loop ID (optional, stops latest)"
                      ] )
                ; ( "reason"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Reason for stopping (for logging)"
                      ] )
                ] )
          ]
    }
  ; { name = "masc_autoresearch_inject"
    ; description =
        "Inject a specific hypothesis into a running autoresearch loop. The next cycle \
         will test this hypothesis instead of generating one via MODEL. Useful for \
         directing the research based on human insight."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "loop_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Loop ID (optional, uses latest)"
                      ] )
                ; ( "hypothesis"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "The hypothesis to test in the next cycle"
                      ] )
                ] )
          ; "required", `List [ `String "hypothesis" ]
          ]
    }
  ; { name = "masc_autoresearch_cycle"
    ; description =
        "Run one experiment cycle of an active loop. Reads target file, LLM generates a \
         modification, measures before/after, keeps change if metric improved. Returns \
         cycle_number, before_score, after_score, kept (bool). Requires an active loop \
         from masc_autoresearch_start. Normally the loop runs autonomously; use this for \
         manual single-step control."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "loop_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Loop ID (optional, uses latest)"
                      ] )
                ; ( "hypothesis"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Hypothesis to test (optional, auto-generates via MODEL if \
                             omitted)" )
                      ] )
                ] )
          ]
    }
  ; { name = "masc_autoresearch_record_finding"
    ; description =
        "Persist a structured autoresearch finding to the current MASC base path. Use \
         after a research loop discovers evidence that should inform future cycles. \
         Requires goal, hypothesis, evidence, and conclusion."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "loop_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Optional autoresearch loop ID associated with this finding" )
                      ] )
                ; ( "goal"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Research goal or question"
                      ] )
                ; ( "hypothesis"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Hypothesis that was tested or evaluated"
                      ] )
                ; ( "evidence"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Observed evidence, measurements, or citations" )
                      ] )
                ; ( "conclusion"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Conclusion drawn from the evidence"
                      ] )
                ; ( "confidence"
                  , `Assoc
                      [ "type", `String "string"
                      ; "enum", `List [ `String "high"; `String "medium"; `String "low" ]
                      ; "description", `String "Confidence level (default: medium)"
                      ] )
                ; ( "tags"
                  , `Assoc
                      [ "type", `String "array"
                      ; "items", `Assoc [ "type", `String "string" ]
                      ; "description", `String "Optional finding tags"
                      ] )
                ; ( "cycle_start"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String "Optional first cycle number covered by this finding" )
                      ] )
                ; ( "cycle_end"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String "Optional last cycle number covered by this finding" )
                      ] )
                ] )
          ; ( "required"
            , `List
                [ `String "goal"
                ; `String "hypothesis"
                ; `String "evidence"
                ; `String "conclusion"
                ] )
          ]
    }
  ; { name = "masc_autoresearch_search_findings"
    ; description =
        "Search structured autoresearch findings stored under the current MASC base \
         path. Returns the most recent matching findings first."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "query"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Keyword or phrase to search for"
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String "Maximum number of findings to return (default: 10)" )
                      ] )
                ] )
          ; "required", `List [ `String "query" ]
          ]
    }
  ]
;;
