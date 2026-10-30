(** Regression test for the execution-dashboard ["agents"] wire projection.
    Bug: the keeper-name to active-model index stayed empty, so every
    ["agents"][].["model"] was null. *)

open Alcotest

let json = testable Yojson.Safe.pp Yojson.Safe.equal

let agent ~agent_type name : Masc_domain.agent =
  { id = None
  ; name
  ; agent_type
  ; status = Masc_domain.Active
  ; capabilities = []
  ; current_task = None
  ; session_bound_at = "2026-07-29T00:00:00Z"
  ; last_seen = "2026-07-29T00:00:00Z"
  ; meta = None
  }
;;

let model_of_agent name = function
  | `List agents ->
    (match
       List.find_opt
         (fun agent -> Yojson.Safe.Util.(agent |> member "name" |> to_string) = name)
         agents
     with
     | Some agent -> Yojson.Safe.Util.member "model" agent
     | None -> failf "missing agent %s" name)
  | json -> failf "agents field is not a list: %s" (Yojson.Safe.to_string json)
;;

let test_projects_active_models_to_agents_wire () =
  let keeper_name = "alice" in
  let keepers =
    [ `Assoc
        [ "name", `String keeper_name
        ; "active_model", `String "model-x"
        ]
    ]
  in
  let agents =
    [ agent ~agent_type:"keeper" keeper_name; agent ~agent_type:"test" "bob" ]
  in
  let agents_json = Dashboard_execution.For_test.agents_json ~keepers ~agents in
  check json "the keeper agent receives its model"
    (`String "model-x")
    (model_of_agent keeper_name agents_json);
  check json "an unrelated agent does not receive the keeper model"
    `Null
    (model_of_agent "bob" agents_json)
;;

let () =
  run "dashboard agent model projection"
    [ ( "agents wire",
        [ test_case "projects active models to agents wire" `Quick
            test_projects_active_models_to_agents_wire
        ] )
    ]
