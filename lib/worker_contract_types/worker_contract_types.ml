(** Legacy module name retained while team-session runtime is retired.
    Only shared worker contract helpers remain here. *)

include Worker_contract_types_enums

open Yojson.Safe.Util

let dedup_strings = Dashboard_utils.dedup_strings

let default_execution_scope_for_worker_class = function
  | Some Worker_executor -> Limited_code_change
  | _ -> Observe_only

let effective_execution_scope ~worker_class execution_scope =
  match execution_scope with
  | Some scope -> scope
  | None -> default_execution_scope_for_worker_class worker_class

let effective_execution_scope_of_planned_worker (worker : planned_worker) =
  effective_execution_scope ~worker_class:worker.worker_class
    worker.execution_scope

let planned_worker_key (w : planned_worker) =
  match w.runtime_actor with
  | Some actor when String.trim actor <> "" -> "actor:" ^ String.trim actor
  | _ ->
      String.concat "|"
        [
          "agent:" ^ w.spawn_agent;
          "role:"
          ^ Option.value ~default:"" (Option.map String.trim w.spawn_role);
          "model:"
          ^ Option.value ~default:"" (Option.map String.trim w.spawn_model);
          "scope:"
          ^ Option.value ~default:""
              (Option.map execution_scope_to_string w.execution_scope);
          "thinking:"
          ^ Option.value ~default:""
              (Option.map string_of_bool w.thinking_enabled);
          "max_turns:"
          ^ Option.value ~default:"" (Option.map string_of_int w.max_turns);
          "timeout:"
          ^ Option.value ~default:""
              (Option.map string_of_int w.timeout_seconds);
          "class:"
          ^ Option.value ~default:""
              (Option.map worker_class_to_string w.worker_class);
          "pool:"
          ^ Option.value ~default:"" (Option.map String.trim w.runtime_pool);
          "lane:"
          ^ Option.value ~default:"" (Option.map String.trim w.lane_id);
          "level:"
          ^ Option.value ~default:""
              (Option.map controller_level_to_string w.controller_level);
          "domain:"
          ^ Option.value ~default:""
              (Option.map control_domain_to_string w.control_domain);
          "supervisor:"
          ^ Option.value ~default:""
              (Option.map String.trim w.supervisor_actor);
          "profile:"
          ^ Option.value ~default:""
              (Option.map task_profile_to_string w.task_profile);
        ]

let dedup_planned_workers xs =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | x :: rest ->
        let key = planned_worker_key x in
        if List.mem key seen then loop seen acc rest
        else loop (key :: seen) (x :: acc) rest
  in
  loop [] [] xs

let non_empty_strings_of_json json =
  match json with
  | `List xs ->
      xs
      |> List.filter_map (function
             | `String value ->
                 let trimmed = String.trim value in
                 if trimmed = "" then None else Some trimmed
             | _ -> None)
      |> dedup_strings
  | _ -> []

let string_list_to_json values =
  `List (List.map (fun value -> `String value) values)

let delivery_contract_to_yojson (contract : delivery_contract) =
  `Assoc
    [
      ("contract_id", `String contract.contract_id);
      ("summary", `String contract.summary);
      ("acceptance_checks", string_list_to_json contract.acceptance_checks);
      ("required_artifacts", string_list_to_json contract.required_artifacts);
      ("repair_budget", `Int contract.repair_budget);
      ("generator_roles", string_list_to_json contract.generator_roles);
      ( "evaluator_role",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          contract.evaluator_role );
      ("evaluator_cascade", `String contract.evaluator_cascade);
      ("evidence_refs", string_list_to_json contract.evidence_refs);
      ("updated_by", `String contract.updated_by);
      ("updated_at_iso", `String contract.updated_at_iso);
    ]

let delivery_contract_of_yojson (json : Yojson.Safe.t) =
  match json with
  | `Assoc _ -> (
      match member "contract_id" json with
      | `String contract_id ->
          let contract_id = String.trim contract_id in
          if contract_id = "" then None
          else
            Some
              {
                contract_id;
                summary =
                  (match member "summary" json with
                  | `String value -> String.trim value
                  | _ -> "");
                acceptance_checks =
                  non_empty_strings_of_json (member "acceptance_checks" json);
                required_artifacts =
                  non_empty_strings_of_json (member "required_artifacts" json);
                repair_budget =
                  (match member "repair_budget" json with
                  | `Int value -> max 0 value
                  | `Intlit raw -> (
                      match int_of_string_opt raw with
                      | Some value -> max 0 value
                      | None -> 0)
                  | _ -> 0);
                generator_roles =
                  non_empty_strings_of_json (member "generator_roles" json);
                evaluator_role =
                  (match member "evaluator_role" json |> to_string_option with
                  | Some value ->
                      let trimmed = String.trim value in
                      if trimmed = "" then None else Some trimmed
                  | None -> None);
                evaluator_cascade =
                  (match member "evaluator_cascade" json with
                  | `String value ->
                      let trimmed = String.trim value in
                      if trimmed = "" then "cross_verifier" else trimmed
                  | _ -> "cross_verifier");
                evidence_refs =
                  non_empty_strings_of_json (member "evidence_refs" json);
                updated_by =
                  (match member "updated_by" json with
                  | `String value ->
                      let trimmed = String.trim value in
                      if trimmed = "" then "unknown" else trimmed
                  | _ -> "unknown");
                updated_at_iso =
                  (match member "updated_at_iso" json with
                  | `String value ->
                      let trimmed = String.trim value in
                      if trimmed = "" then Types.now_iso () else trimmed
                  | _ -> Types.now_iso ());
              }
      | _ -> None)
  | _ -> None

let delivery_verdict_to_yojson (verdict : delivery_verdict) =
  `Assoc
    [
      ("contract_id", `String verdict.contract_id);
      ("status", `String (delivery_verdict_status_to_string verdict.status));
      ("summary", `String verdict.summary);
      ("evaluator", `String verdict.evaluator);
      ( "evaluator_role",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          verdict.evaluator_role );
      ("evaluator_cascade", `String verdict.evaluator_cascade);
      ( "repair_directive",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          verdict.repair_directive );
      ("evidence_refs", string_list_to_json verdict.evidence_refs);
      ("generated_at_iso", `String verdict.generated_at_iso);
    ]

let delivery_verdict_of_yojson (json : Yojson.Safe.t) =
  match json with
  | `Assoc _ -> (
      match member "contract_id" json with
      | `String contract_id ->
          let contract_id = String.trim contract_id in
          if contract_id = "" then None
          else
            Some
              {
                contract_id;
                status =
                  (match member "status" json with
                  | `String value ->
                      delivery_verdict_status_of_string
                        (String.lowercase_ascii (String.trim value))
                  | _ -> Delivery_fail);
                summary =
                  (match member "summary" json with
                  | `String value -> String.trim value
                  | _ -> "");
                evaluator =
                  (match member "evaluator" json with
                  | `String value ->
                      let trimmed = String.trim value in
                      if trimmed = "" then "unknown" else trimmed
                  | _ -> "unknown");
                evaluator_role =
                  (match member "evaluator_role" json |> to_string_option with
                  | Some value ->
                      let trimmed = String.trim value in
                      if trimmed = "" then None else Some trimmed
                  | None -> None);
                evaluator_cascade =
                  (match member "evaluator_cascade" json with
                  | `String value ->
                      let trimmed = String.trim value in
                      if trimmed = "" then "cross_verifier" else trimmed
                  | _ -> "cross_verifier");
                repair_directive =
                  (match member "repair_directive" json |> to_string_option with
                  | Some value ->
                      let trimmed = String.trim value in
                      if trimmed = "" then None else Some trimmed
                  | None -> None);
                evidence_refs =
                  non_empty_strings_of_json (member "evidence_refs" json);
                generated_at_iso =
                  (match member "generated_at_iso" json with
                  | `String value ->
                      let trimmed = String.trim value in
                      if trimmed = "" then Types.now_iso () else trimmed
                  | _ -> Types.now_iso ());
              }
      | _ -> None)
  | _ -> None

let planned_worker_to_yojson (w : planned_worker) =
  `Assoc
    [
      ("spawn_agent", `String w.spawn_agent);
      ( "runtime_actor",
        Option.fold ~none:`Null ~some:(fun s -> `String s) w.runtime_actor );
      ("spawn_role", Option.fold ~none:`Null ~some:(fun s -> `String s) w.spawn_role);
      ("spawn_model", Option.fold ~none:`Null ~some:(fun s -> `String s) w.spawn_model);
      ( "execution_scope",
        Option.fold ~none:`Null
          ~some:(fun scope -> `String (execution_scope_to_string scope))
          w.execution_scope );
      ("thinking_enabled", Option.fold ~none:`Null ~some:(fun v -> `Bool v) w.thinking_enabled);
      ("thinking_budget", Option.fold ~none:`Null ~some:(fun n -> `Int n) w.thinking_budget);
      ("max_turns", Option.fold ~none:`Null ~some:(fun n -> `Int n) w.max_turns);
      ("timeout_seconds", Option.fold ~none:`Null ~some:(fun n -> `Int n) w.timeout_seconds);
      ( "worker_class",
        Option.fold ~none:`Null
          ~some:(fun kind -> `String (worker_class_to_string kind))
          w.worker_class );
      ("parent_actor", Option.fold ~none:`Null ~some:(fun s -> `String s) w.parent_actor);
      ( "capsule_mode",
        Option.fold ~none:`Null
          ~some:(fun mode -> `String (capsule_mode_to_string mode))
          w.capsule_mode );
      ("runtime_pool", Option.fold ~none:`Null ~some:(fun s -> `String s) w.runtime_pool);
      ("lane_id", Option.fold ~none:`Null ~some:(fun s -> `String s) w.lane_id);
      ( "controller_level",
        Option.fold ~none:`Null
          ~some:(fun level -> `String (controller_level_to_string level))
          w.controller_level );
      ( "control_domain",
        Option.fold ~none:`Null
          ~some:(fun domain -> `String (control_domain_to_string domain))
          w.control_domain );
      ( "supervisor_actor",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          w.supervisor_actor );
      ( "task_profile",
        Option.fold ~none:`Null
          ~some:(fun profile -> `String (task_profile_to_string profile))
          w.task_profile );
      ( "risk_level",
        Option.fold ~none:`Null
          ~some:(fun level -> `String (risk_level_to_string level))
          w.risk_level );
      ("routing_confidence", Option.fold ~none:`Null ~some:(fun value -> `Float value) w.routing_confidence);
      ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) w.routing_reason);
      ("routing_escalated", `Bool w.routing_escalated);
    ]

let planned_worker_of_yojson (json : Yojson.Safe.t) =
  match json with
  | `Assoc _ ->
      let spawn_agent =
        match member "spawn_agent" json with
        | `String s ->
            let trimmed = String.trim s in
            if trimmed = "" then None else Some trimmed
        | _ -> None
      in
      Option.map
        (fun spawn_agent ->
          {
            spawn_agent;
            runtime_actor = member "runtime_actor" json |> to_string_option;
            spawn_role = member "spawn_role" json |> to_string_option;
            spawn_model = member "spawn_model" json |> to_string_option;
            execution_scope =
              Option.map
                execution_scope_of_string
                (member "execution_scope" json |> to_string_option);
            thinking_enabled = member "thinking_enabled" json |> to_bool_option;
            thinking_budget = member "thinking_budget" json |> to_int_option;
            max_turns = member "max_turns" json |> to_int_option;
            timeout_seconds = member "timeout_seconds" json |> to_int_option;
            worker_class =
              Option.bind
                (member "worker_class" json |> to_string_option)
                (fun value ->
                  worker_class_of_string
                    (String.lowercase_ascii (String.trim value)));
            parent_actor = member "parent_actor" json |> to_string_option;
            capsule_mode =
              Option.bind
                (member "capsule_mode" json |> to_string_option)
                (fun value ->
                  capsule_mode_of_string
                    (String.lowercase_ascii (String.trim value)));
            runtime_pool = member "runtime_pool" json |> to_string_option;
            lane_id = member "lane_id" json |> to_string_option;
            controller_level =
              Option.bind
                (member "controller_level" json |> to_string_option)
                (fun value ->
                  controller_level_of_string
                    (String.lowercase_ascii (String.trim value)));
            control_domain =
              Option.bind
                (member "control_domain" json |> to_string_option)
                (fun value ->
                  control_domain_of_string
                    (String.lowercase_ascii (String.trim value)));
            supervisor_actor =
              member "supervisor_actor" json |> to_string_option;
            task_profile =
              Option.bind
                (member "task_profile" json |> to_string_option)
                (fun value ->
                  task_profile_of_string
                    (String.lowercase_ascii (String.trim value)));
            risk_level =
              Option.bind
                (member "risk_level" json |> to_string_option)
                (fun value ->
                  risk_level_of_string
                    (String.lowercase_ascii (String.trim value)));
            routing_confidence =
              (match member "routing_confidence" json with
              | `Float value -> Some value
              | `Int value -> Some (float_of_int value)
              | `Intlit raw -> (
                  try Some (float_of_string raw) with Failure _ -> None)
              | _ -> None);
            routing_reason = member "routing_reason" json |> to_string_option;
            routing_escalated =
              (match member "routing_escalated" json with
              | `Bool value -> value
              | _ -> false);
          })
        spawn_agent
  | _ -> None
