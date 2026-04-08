(** Team session types - long-running collaborative orchestration (includes enums) *)

include Team_session_types_enums

open Yojson.Safe.Util
let dedup_strings = Dashboard_utils.dedup_strings

let contains_substring = String_util.contains_substring

let system_session_creator_prefixes =
  [ "keeper"; "dashboard"; "operator"; "system";
    "keeper-system"; "team-session"; "ecosystem" ]

let creator_looks_system created_by =
  let normalized = String.lowercase_ascii (String.trim created_by) in
  normalized <> ""
  && List.exists
       (fun prefix ->
         String.equal normalized prefix
         || String.starts_with ~prefix:(prefix ^ "-") normalized
         || contains_substring normalized ("-" ^ prefix ^ "-"))
       system_session_creator_prefixes

let infer_session_origin_kind ~created_by ~orchestration_mode =
  match orchestration_mode with
  | Auto -> Origin_system
  | Manual | Assist ->
      if creator_looks_system created_by then Origin_system else Origin_human

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
          ^ Option.value ~default:""
              (Option.map string_of_int w.max_turns);
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

let participant_names (s : session) =
  dedup_strings (s.created_by :: s.agent_names) |> List.sort String.compare

let planned_worker_actor_names (s : session) =
  s.planned_workers
  |> List.filter_map (fun worker ->
         match worker.runtime_actor with
         | Some actor ->
             let trimmed = String.trim actor in
             if trimmed = "" then None else Some trimmed
         | None -> None)
  |> dedup_strings |> List.sort String.compare

let planned_participant_names (s : session) =
  dedup_strings (participant_names s @ planned_worker_actor_names s)
  |> List.sort String.compare

let assoc_find_default key pairs default =
  match List.assoc_opt key pairs with Some v -> v | None -> default

let done_delta_by_agent ~(baseline : (string * int) list) ~(current : (string * int) list)
    ~(agents : string list) : (string * int) list =
  let normalized_agents = dedup_strings agents in
  let from_agents =
    List.map
      (fun agent ->
        let base = assoc_find_default agent baseline 0 in
        let now = assoc_find_default agent current 0 in
        (agent, max 0 (now - base)))
      normalized_agents
  in
  let extra_agents =
    current
    |> List.filter (fun (agent, _) ->
         not (List.mem_assoc agent from_agents)
         && List.mem agent normalized_agents)
  in
  (from_agents @ extra_agents)
  |> List.sort (fun (a, _) (b, _) -> compare a b)

let count_by (extract : 'a -> string option) (items : 'a list) : (string * int) list =
  let tbl = Hashtbl.create 8 in
  List.iter
    (fun item ->
      match extract item with
      | None -> ()
      | Some key ->
          let prev = Option.value ~default:0 (Hashtbl.find_opt tbl key) in
          Hashtbl.replace tbl key (prev + 1))
    items;
  Hashtbl.fold (fun key count acc -> (key, count) :: acc) tbl []

let trim_nonempty s =
  let s = String.trim s in
  if s = "" then None else Some s

let done_counts_from_backlog (backlog : Types.backlog) : (string * int) list =
  count_by
    (fun (task : Types.task) ->
      match task.task_status with
      | Types.Done { assignee; _ } -> Some assignee
      | _ -> None)
    backlog.tasks
  |> List.sort (fun (a, _) (b, _) -> compare a b)

let assoc_int_to_json pairs =
  `Assoc (List.map (fun (k, v) -> (k, `Int v)) pairs)

let assoc_int_of_json json =
  match json with
  | `Assoc fields ->
      List.filter_map
        (fun (k, v) ->
          match v with
          | `Int n -> Some (k, n)
          | `Intlit s -> (
              match int_of_string_opt s with Some v -> Some (k, v) | None -> None)
          | _ -> None)
        fields
  | _ -> []

let counts_to_json counts =
  `Assoc
    (counts
    |> List.map (fun (label, count) -> (label, `Int count))
    |> List.sort (fun (a, _) (b, _) -> compare a b))

let worker_class_counts workers =
  count_by
    (fun (w : planned_worker) ->
      Option.map worker_class_to_string w.worker_class)
    workers

let runtime_pool_counts workers =
  count_by
    (fun (w : planned_worker) -> Option.bind w.runtime_pool trim_nonempty)
    workers

let lane_counts workers =
  count_by
    (fun (w : planned_worker) -> Option.bind w.lane_id trim_nonempty)
    workers

let controller_level_counts workers =
  count_by
    (fun (w : planned_worker) ->
      Option.map controller_level_to_string w.controller_level)
    workers

let control_domain_counts workers =
  count_by
    (fun (w : planned_worker) ->
      Option.map control_domain_to_string w.control_domain)
    workers

let task_profile_counts workers =
  count_by
    (fun (w : planned_worker) ->
      Option.map task_profile_to_string w.task_profile)
    workers

let escalation_count workers =
  List.fold_left
    (fun acc (worker : planned_worker) ->
      if worker.routing_escalated then acc + 1 else acc)
    0 workers

let routing_reason_summary ?(max_items = 8) workers =
  let rec take acc remaining = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | x :: xs ->
        if List.mem x acc then take acc remaining xs
        else take (x :: acc) (remaining - 1) xs
  in
  workers
  |> List.filter_map (fun (worker : planned_worker) ->
         match worker.routing_reason with
         | Some reason ->
             let trimmed = String.trim reason in
             if trimmed = "" then None else Some trimmed
         | None -> None)
  |> take [] max_items

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
      match Yojson.Safe.Util.member "contract_id" json with
      | `String contract_id ->
          let contract_id = String.trim contract_id in
          if contract_id = "" then None
          else
            Some
              {
                contract_id;
                summary =
                  (match Yojson.Safe.Util.member "summary" json with
                  | `String value -> String.trim value
                  | _ -> "");
                acceptance_checks =
                  non_empty_strings_of_json
                    (Yojson.Safe.Util.member "acceptance_checks" json);
                required_artifacts =
                  non_empty_strings_of_json
                    (Yojson.Safe.Util.member "required_artifacts" json);
                repair_budget =
                  (match Yojson.Safe.Util.member "repair_budget" json with
                  | `Int value -> max 0 value
                  | `Intlit raw -> (
                      match int_of_string_opt raw with Some v -> max 0 v | None -> 0)
                  | _ -> 0);
                generator_roles =
                  non_empty_strings_of_json
                    (Yojson.Safe.Util.member "generator_roles" json);
                evaluator_role =
                  (match
                     Yojson.Safe.Util.member "evaluator_role" json
                     |> Yojson.Safe.Util.to_string_option
                     |> Option.map String.trim
                   with
                  | Some value when value <> "" -> Some value
                  | _ -> None);
                evaluator_cascade =
                  (match Yojson.Safe.Util.member "evaluator_cascade" json with
                  | `String value ->
                      let trimmed = String.trim value in
                      if trimmed = "" then "cross_verifier" else trimmed
                  | _ -> "cross_verifier");
                evidence_refs =
                  non_empty_strings_of_json
                    (Yojson.Safe.Util.member "evidence_refs" json);
                updated_by =
                  (match Yojson.Safe.Util.member "updated_by" json with
                  | `String value ->
                      let trimmed = String.trim value in
                      if trimmed = "" then "unknown" else trimmed
                  | _ -> "unknown");
                updated_at_iso =
                  (match Yojson.Safe.Util.member "updated_at_iso" json with
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
      match Yojson.Safe.Util.member "contract_id" json with
      | `String contract_id ->
          let contract_id = String.trim contract_id in
          if contract_id = "" then None
          else
            Some
              {
                contract_id;
                status =
                  (match Yojson.Safe.Util.member "status" json with
                  | `String value ->
                      delivery_verdict_status_of_string
                        (String.lowercase_ascii (String.trim value))
                  | _ -> Delivery_fail);
                summary =
                  (match Yojson.Safe.Util.member "summary" json with
                  | `String value -> String.trim value
                  | _ -> "");
                evaluator =
                  (match Yojson.Safe.Util.member "evaluator" json with
                  | `String value ->
                      let trimmed = String.trim value in
                      if trimmed = "" then "unknown" else trimmed
                  | _ -> "unknown");
                evaluator_role =
                  (match
                     Yojson.Safe.Util.member "evaluator_role" json
                     |> Yojson.Safe.Util.to_string_option
                     |> Option.map String.trim
                   with
                  | Some value when value <> "" -> Some value
                  | _ -> None);
                evaluator_cascade =
                  (match Yojson.Safe.Util.member "evaluator_cascade" json with
                  | `String value ->
                      let trimmed = String.trim value in
                      if trimmed = "" then "cross_verifier" else trimmed
                  | _ -> "cross_verifier");
                repair_directive =
                  (match
                     Yojson.Safe.Util.member "repair_directive" json
                     |> Yojson.Safe.Util.to_string_option
                     |> Option.map String.trim
                   with
                  | Some value when value <> "" -> Some value
                  | _ -> None);
                evidence_refs =
                  non_empty_strings_of_json
                    (Yojson.Safe.Util.member "evidence_refs" json);
                generated_at_iso =
                  (match Yojson.Safe.Util.member "generated_at_iso" json with
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
            thinking_enabled =
              member "thinking_enabled" json |> to_bool_option;
            thinking_budget =
              member "thinking_budget" json |> to_int_option;
            max_turns =
              member "max_turns" json |> to_int_option;
            timeout_seconds =
              member "timeout_seconds" json |> to_int_option;
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
              | `Intlit raw -> (try Some (float_of_string raw) with Failure _ -> None)
              | _ -> None);
            routing_reason = member "routing_reason" json |> to_string_option;
            routing_escalated =
              (match member "routing_escalated" json with
              | `Bool value -> value
              | _ -> false);
          })
        spawn_agent
  | _ -> None

let session_to_yojson (s : session) =
  `Assoc
    [
      ("session_id", `String s.session_id);
      ("goal", `String s.goal);
      ("created_by", `String s.created_by);
      ("origin_kind", `String (session_origin_kind_to_string s.origin_kind));
      ("room_id", `String s.room_id);
      ("operation_id", Option.fold ~none:`Null ~some:(fun v -> `String v) s.operation_id);
      ("status", `String (status_to_string s.status));
      ("duration_seconds", `Int s.duration_seconds);
      ("execution_scope", `String (execution_scope_to_string s.execution_scope));
      ("checkpoint_interval_sec", `Int s.checkpoint_interval_sec);
      ("min_agents", `Int s.min_agents);
      ("scale_profile", `String (scale_profile_to_string s.scale_profile));
      ("control_profile", `String (control_profile_to_string s.control_profile));
      ("orchestration_mode", `String (orchestration_mode_to_string s.orchestration_mode));
      ("communication_mode", `String (communication_mode_to_string s.communication_mode));
      ("model_cascade", `List (List.map (fun m -> `String m) s.model_cascade));
      ("fallback_policy", `String (fallback_policy_to_string s.fallback_policy));
      ("instruction_profile", `String (instruction_profile_to_string s.instruction_profile));
      ("alert_channel", `String (alert_channel_to_string s.alert_channel));
      ("auto_resume", `Bool s.auto_resume);
      ("report_formats", `List (List.map (fun f -> `String (report_format_to_string f)) s.report_formats));
      ("turn_count", `Int s.turn_count);
      ("agent_names", `List (List.map (fun a -> `String a) s.agent_names));
      ("planned_workers", `List (List.map planned_worker_to_yojson s.planned_workers));
      ("broadcast_count", `Int s.broadcast_count);
      ("portal_count", `Int s.portal_count);
      ("cascade_attempted", `Int s.cascade_attempted);
      ("cascade_success", `Int s.cascade_success);
      ("cascade_failed", `Int s.cascade_failed);
      ("fallback_task_created", `Int s.fallback_task_created);
      ("min_agents_violation_streak", `Int s.min_agents_violation_streak);
      ("policy_violations", `List (List.map (fun v -> `String v) s.policy_violations));
      ("baseline_done_counts", assoc_int_to_json s.baseline_done_counts);
      ("final_done_delta_total", Option.fold ~none:`Null ~some:(fun v -> `Int v) s.final_done_delta_total);
      ("final_done_delta_by_agent", Option.fold ~none:`Null ~some:assoc_int_to_json s.final_done_delta_by_agent);
      ("started_at", `Float s.started_at);
      ("planned_end_at", `Float s.planned_end_at);
      ("stopped_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) s.stopped_at);
      ("last_checkpoint_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) s.last_checkpoint_at);
      ("last_event_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) s.last_event_at);
      ("last_turn_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) s.last_turn_at);
      ("stop_reason", Option.fold ~none:`Null ~some:(fun v -> `String v) s.stop_reason);
      ("generated_report", `Bool s.generated_report);
      ( "delivery_contract",
        Option.fold ~none:`Null ~some:delivery_contract_to_yojson
          s.delivery_contract );
      ( "latest_delivery_verdict",
        Option.fold ~none:`Null ~some:delivery_verdict_to_yojson
          s.latest_delivery_verdict );
      ("artifacts_dir", `String s.artifacts_dir);
      ("created_at_iso", `String s.created_at_iso);
      ("updated_at_iso", `String s.updated_at_iso);
    ]

let session_of_yojson json =
  try
    let get_int_default key default =
      match member key json with
      | `Int n -> n
      | `Intlit s -> (Option.value ~default:default (int_of_string_opt s))
      | _ -> default
    in
    let get_float_default key default =
      match member key json with
      | `Float v -> v
      | `Int n -> float_of_int n
      | `Intlit s -> (try float_of_string s with Failure _ -> default)
      | _ -> default
    in
    let started_at = get_float_default "started_at" (Time_compat.now ()) in
    let duration_seconds = get_int_default "duration_seconds" 3600 in
    let default_end = started_at +. float_of_int duration_seconds in
    Some
      {
        session_id = json |> member "session_id" |> to_string;
        goal = json |> member "goal" |> to_string;
        created_by = json |> member "created_by" |> to_string_option |> Option.value ~default:"unknown";
        origin_kind =
          (match json |> member "origin_kind" |> to_string_option with
          | Some raw -> session_origin_kind_of_string raw
          | None ->
              infer_session_origin_kind
                ~created_by:(json |> member "created_by" |> to_string_option |> Option.value ~default:"unknown")
                ~orchestration_mode:(
                  json |> member "orchestration_mode" |> to_string_option
                  |> Option.value ~default:"assist"
                  |> orchestration_mode_of_string));
        room_id = json |> member "room_id" |> to_string_option |> Option.value ~default:"default";
        operation_id = json |> member "operation_id" |> to_string_option;
        status = json |> member "status" |> to_string_option |> Option.value ~default:"failed" |> status_of_string;
        duration_seconds;
        execution_scope =
          json |> member "execution_scope" |> to_string_option |> Option.value ~default:"limited_code_change"
          |> execution_scope_of_string;
        checkpoint_interval_sec = get_int_default "checkpoint_interval_sec" 60;
        min_agents = get_int_default "min_agents" 2;
        scale_profile =
          json |> member "scale_profile" |> to_string_option
          |> Option.value ~default:"standard"
          |> scale_profile_of_string;
        control_profile =
          json |> member "control_profile" |> to_string_option
          |> Option.value ~default:"flat"
          |> control_profile_of_string;
        orchestration_mode =
          json |> member "orchestration_mode" |> to_string_option
          |> Option.value ~default:"assist"
          |> orchestration_mode_of_string;
        communication_mode =
          json |> member "communication_mode" |> to_string_option
          |> Option.value ~default:"broadcast"
          |> communication_mode_of_string;
        model_cascade =
          (match member "model_cascade" json with
           | `List xs -> List.filter_map (function `String s -> Some s | _ -> None) xs
           | _ -> [])
          |> dedup_strings;
        fallback_policy =
          json |> member "fallback_policy" |> to_string_option
          |> Option.value ~default:"cascade_then_task"
          |> fallback_policy_of_string;
        instruction_profile =
          json |> member "instruction_profile" |> to_string_option
          |> Option.value ~default:"standard"
          |> instruction_profile_of_string;
        alert_channel =
          json |> member "alert_channel" |> to_string_option
          |> Option.value ~default:"both"
          |> alert_channel_of_string;
        auto_resume = json |> member "auto_resume" |> to_bool_option |> Option.value ~default:true;
        report_formats =
          (match member "report_formats" json with
           | `List xs ->
               xs
               |> List.filter_map (function `String s -> Some s | _ -> None)
               |> report_formats_of_strings
           | _ -> [])
          |> (fun xs -> if xs = [] then [Markdown; Json] else xs);
        turn_count = get_int_default "turn_count" 0;
        agent_names =
          (match member "agent_names" json with
           | `List xs -> List.filter_map (function `String s -> Some s | _ -> None) xs
           | _ -> []);
        planned_workers =
          (match member "planned_workers" json with
           | `List xs -> List.filter_map planned_worker_of_yojson xs
           | _ -> [])
          |> dedup_planned_workers;
        broadcast_count = get_int_default "broadcast_count" 0;
        portal_count = get_int_default "portal_count" 0;
        cascade_attempted = get_int_default "cascade_attempted" 0;
        cascade_success = get_int_default "cascade_success" 0;
        cascade_failed = get_int_default "cascade_failed" 0;
        fallback_task_created = get_int_default "fallback_task_created" 0;
        min_agents_violation_streak = get_int_default "min_agents_violation_streak" 0;
        policy_violations =
          (match member "policy_violations" json with
           | `List xs -> List.filter_map (function `String s -> Some s | _ -> None) xs
           | _ -> [])
          |> dedup_strings;
        baseline_done_counts = assoc_int_of_json (member "baseline_done_counts" json);
        final_done_delta_total =
          (match member "final_done_delta_total" json with
           | `Int n -> Some n
           | `Intlit s -> (int_of_string_opt (s))
           | _ -> None);
        final_done_delta_by_agent =
          (match member "final_done_delta_by_agent" json with
           | `Assoc _ as assoc -> Some (assoc_int_of_json assoc)
           | _ -> None);
        started_at;
        planned_end_at = get_float_default "planned_end_at" default_end;
        stopped_at = json |> member "stopped_at" |> to_float_option;
        last_checkpoint_at = json |> member "last_checkpoint_at" |> to_float_option;
        last_event_at = json |> member "last_event_at" |> to_float_option;
        last_turn_at = json |> member "last_turn_at" |> to_float_option;
        stop_reason = json |> member "stop_reason" |> to_string_option;
        generated_report = json |> member "generated_report" |> to_bool_option |> Option.value ~default:false;
        delivery_contract =
          delivery_contract_of_yojson (member "delivery_contract" json);
        latest_delivery_verdict =
          delivery_verdict_of_yojson
            (member "latest_delivery_verdict" json);
        artifacts_dir = json |> member "artifacts_dir" |> to_string_option |> Option.value ~default:"";
        created_at_iso = json |> member "created_at_iso" |> to_string_option |> Option.value ~default:(Types.now_iso ());
        updated_at_iso = json |> member "updated_at_iso" |> to_string_option |> Option.value ~default:(Types.now_iso ());
      }
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Session.error "session_of_yojson parse failed: %s"
      (Printexc.to_string exn);
    None

let event_entry_to_yojson (e : event_entry) =
  `Assoc
    [
      ("ts", `Float e.ts);
      ("ts_iso", `String e.ts_iso);
      ("event_type", `String e.event_type);
      ("detail", e.detail);
    ]

let checkpoint_of_yojson (json : Yojson.Safe.t) : (checkpoint, string) result =
  try
    Ok
      {
        ts = json |> member "ts" |> to_float;
        ts_iso = json |> member "ts_iso" |> to_string;
        status =
          json |> member "status" |> to_string |> status_of_string;
        elapsed_sec = json |> member "elapsed_sec" |> to_int;
        remaining_sec = json |> member "remaining_sec" |> to_int;
        progress_pct = json |> member "progress_pct" |> to_float;
        done_delta_total = json |> member "done_delta_total" |> to_int;
        done_delta_by_agent =
          assoc_int_of_json (json |> member "done_delta_by_agent");
        active_agents =
          json |> member "active_agents" |> to_list |> List.map to_string;
      }
  with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)

let event_entry_of_yojson (json : Yojson.Safe.t) : (event_entry, string) result =
  try
    Ok
      {
        ts = json |> member "ts" |> to_float;
        ts_iso = json |> member "ts_iso" |> to_string;
        event_type = json |> member "event_type" |> to_string;
        detail = json |> member "detail";
      }
  with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)

let checkpoint_to_yojson (c : checkpoint) =
  `Assoc
    [
      ("ts", `Float c.ts);
      ("ts_iso", `String c.ts_iso);
      ("status", `String (status_to_string c.status));
      ("elapsed_sec", `Int c.elapsed_sec);
      ("remaining_sec", `Int c.remaining_sec);
      ("progress_pct", `Float c.progress_pct);
      ("done_delta_total", `Int c.done_delta_total);
      ("done_delta_by_agent", assoc_int_to_json c.done_delta_by_agent);
      ("active_agents", `List (List.map (fun a -> `String a) c.active_agents));
    ]
