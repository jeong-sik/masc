(** Tool_shard_types_schemas_preflight — keeper_preflight_check schema. *)

(** Pre-flight validation for keeper autonomous work. *)
let keeper_preflight_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_preflight_check"
    ; description =
        "Validate prerequisites before starting autonomous work: configured credential \
         binding, repo argument shape, keeper identity, preset level, cascade resilience, \
         autonomous activation, and repo readiness. Does not probe gh/git identity state; \
         returns structured JSON with all check results. Read-only, no side effects."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "GitHub repo slug (owner/name) for argument validation" )
                      ] )
                ; ( "repo_name"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Optional sandbox repo directory name under repos/ when it \
                             differs from the GitHub repo basename" )
                      ] )
                ] )
          ; "required", `List [ `String "repo" ]
          ]
    }
  ]
;;
