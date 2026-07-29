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
  let keepers =
    [ `Assoc [ "name", `String "alice"; "active_model", `String "old-model" ]
    ; `Assoc [ "name", `String "alice"; "active_model", `String "current-model" ]
    ; `Assoc [ "name", `String "bob"; "active_model", `String "   " ]
    ; `Assoc [ "name", `String "carol" ]
    ; `Assoc [ "active_model", `String "no-name" ]
    ; `Null
    ]
  in
  let agents = List.map agent [ "alice"; "bob"; "carol"; "dave" ] in
  let agents_json = Dashboard_execution.For_test.agents_json ~keepers ~agents in
  check json "latest exact keeper row wins"
    (`String "current-model")
    (model_of_agent "alice" agents_json);
  List.iter
    (fun name ->
       check json (name ^ " has no active model") `Null
         (model_of_agent name agents_json))
    [ "bob"; "carol"; "dave" ]
;;

let () =
  run "dashboard agent model projection"
    [ test_case "projects active models to agents wire" `Quick
        test_projects_active_models_to_agents_wire
    ]
