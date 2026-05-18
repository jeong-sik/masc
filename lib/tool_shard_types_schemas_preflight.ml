(** Tool_shard_types_schemas_preflight — keeper_preflight_check schema. *)

(** Pre-flight validation for keeper autonomous work. *)
let keeper_preflight_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_preflight_check"
    ; description =
        "Validate prerequisites before starting autonomous work: gh auth, repo access, \
         keeper identity, preset level, cascade resilience, autonomous activation, repo \
         readiness. Returns structured JSON with all check results. Read-only, no side \
         effects."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "GitHub repo (owner/name) to check access for" )
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
