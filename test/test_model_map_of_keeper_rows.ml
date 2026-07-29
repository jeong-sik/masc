(** Regression test for the execution-dashboard ["agents"] wire projection.
    Bug: the keeper-name to active-model index stayed empty, so every
    ["agents"][].["model"] was null. *)

open Alcotest

let json = testable Yojson.Safe.pp Yojson.Safe.equal

let agent name : Masc_domain.agent =
  { id = None
  ; name
  ; agent_type = "test"
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
  (* Production keeper rows carry both "name" (display) and "agent_name"
     (canonical keeper identity used by agent.name in the agents list).
     The model map must join on agent_name. *)
  let keepers =
    [ `Assoc [ "name", `String "Alice Kim"; "agent_name", `String "keeper-alice-agent"; "active_model", `String "old-model" ]
    ; `Assoc [ "name", `String "Alice Kim"; "agent_name", `String "keeper-alice-agent"; "active_model", `String "current-model" ]
    ; `Assoc [ "name", `String "Bob Lee"; "agent_name", `String "keeper-bob-agent"; "active_model", `String "   " ]
    ; `Assoc [ "name", `String "Carol"; "agent_name", `String "keeper-carol-agent" ]
    ; `Assoc [ "agent_name", `String "keeper-dave-agent"; "active_model", `String "no-display-name" ]
    ; `Assoc [ "name", `String "Eve"; "active_model", `String "missing-agent-name" ]
    ; `Null
    ]
  in
  let agents =
    List.map agent [ "keeper-alice-agent"; "keeper-bob-agent"; "keeper-carol-agent"; "keeper-dave-agent"; "keeper-eve-agent" ]
  in
  let agents_json = Dashboard_execution.For_test.agents_json ~keepers ~agents in
  (* latest row wins for duplicate agent_name keys *)
  check json "latest exact keeper row wins"
    (`String "current-model")
    (model_of_agent "keeper-alice-agent" agents_json);
  (* whitespace-only active_model is trimmed to None → null *)
  List.iter
    (fun name ->
       check json (name ^ " has no active model") `Null
         (model_of_agent name agents_json))
    [ "keeper-bob-agent"; "keeper-carol-agent"; "keeper-eve-agent" ];
  (* row with agent_name but no display name still resolves *)
  check json "row with agent_name only resolves"
    (`String "no-display-name")
    (model_of_agent "keeper-dave-agent" agents_json)
;;

let () =
  run "dashboard agent model projection"
    [ ( "agents wire",
        [ test_case "projects active models to agents wire" `Quick
            test_projects_active_models_to_agents_wire
        ] )
    ]
