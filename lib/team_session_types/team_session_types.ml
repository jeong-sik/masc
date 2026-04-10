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

let ( let* ) result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error

let json_type_name = function
  | `Null -> "null"
  | `Bool _ -> "bool"
  | `Int _ | `Intlit _ -> "int"
  | `Float _ -> "float"
  | `String _ -> "string"
  | `Assoc _ -> "object"
  | `List _ -> "array"

let field_error kind field message =
  Printf.sprintf "%s.%s: %s" kind field message

let required_nonempty_string_field kind json field =
  match member field json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then Error (field_error kind field "empty string")
      else Ok trimmed
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected string, got %s" (json_type_name value)))

let required_string_field kind json field =
  match member field json with
  | `String value -> Ok (String.trim value)
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected string, got %s" (json_type_name value)))

let optional_string_field kind json field =
  match member field json with
  | `Null -> Ok None
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then Ok None else Ok (Some trimmed)
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected string or null, got %s" (json_type_name value)))

let required_int_field kind json field =
  match member field json with
  | `Int value -> Ok value
  | `Intlit raw -> (
      match int_of_string_opt raw with
      | Some value -> Ok value
      | None -> Error (field_error kind field "invalid int literal"))
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected int, got %s" (json_type_name value)))

let optional_int_field kind json field =
  match member field json with
  | `Null -> Ok None
  | `Int value -> Ok (Some value)
  | `Intlit raw -> (
      match int_of_string_opt raw with
      | Some value -> Ok (Some value)
      | None -> Error (field_error kind field "invalid int literal"))
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected int or null, got %s" (json_type_name value)))

let required_float_field kind json field =
  match member field json with
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | `Intlit raw -> (
      match float_of_string_opt raw with
      | Some value -> Ok value
      | None -> Error (field_error kind field "invalid float literal"))
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected float, got %s" (json_type_name value)))

let optional_float_field kind json field =
  match member field json with
  | `Null -> Ok None
  | `Float value -> Ok (Some value)
  | `Int value -> Ok (Some (float_of_int value))
  | `Intlit raw -> (
      match float_of_string_opt raw with
      | Some value -> Ok (Some value)
      | None -> Error (field_error kind field "invalid float literal"))
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected float or null, got %s" (json_type_name value)))

let required_bool_field kind json field =
  match member field json with
  | `Bool value -> Ok value
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected bool, got %s" (json_type_name value)))

let optional_bool_field kind json field =
  match member field json with
  | `Null -> Ok None
  | `Bool value -> Ok (Some value)
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected bool or null, got %s"
              (json_type_name value)))

let required_enum_field kind json field parse =
  let* value = required_nonempty_string_field kind json field in
  match parse value with
  | Ok parsed -> Ok parsed
  | Error message -> Error (field_error kind field message)

let optional_enum_field kind json field parse =
  match member field json with
  | `Null -> Ok None
  | `String raw ->
      let value = String.trim raw in
      if value = "" then Ok None
      else
        (match parse value with
         | Ok parsed -> Ok (Some parsed)
         | Error message -> Error (field_error kind field message))
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected string or null, got %s" (json_type_name value)))

let string_list_field_result kind json field =
  match member field json with
  | `List values ->
      let rec loop acc = function
        | [] -> Ok (dedup_strings (List.rev acc))
        | `String value :: rest ->
            let trimmed = String.trim value in
            if trimmed = "" then loop acc rest else loop (trimmed :: acc) rest
        | value :: _ ->
            Error
              (field_error kind field
                 (Printf.sprintf "expected string items, got %s"
                    (json_type_name value)))
      in
      loop [] values
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected array, got %s" (json_type_name value)))

let assoc_int_field_result kind json field =
  match member field json with
  | `Assoc fields ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | (key, `Int value) :: rest -> loop ((key, value) :: acc) rest
        | (key, `Intlit raw) :: rest -> (
            match int_of_string_opt raw with
            | Some value -> loop ((key, value) :: acc) rest
            | None ->
                Error
                  (field_error kind field
                     (Printf.sprintf "invalid int literal for key %s" key)))
        | (key, value) :: _ ->
            Error
              (field_error kind field
                 (Printf.sprintf "expected int values; key %s had %s"
                    key (json_type_name value)))
      in
      loop [] fields
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected object, got %s" (json_type_name value)))

let optional_assoc_int_field_result kind json field =
  match member field json with
  | `Null -> Ok None
  | `Assoc _ ->
      let* counts = assoc_int_field_result kind json field in
      Ok (Some counts)
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected object or null, got %s"
              (json_type_name value)))

let report_formats_field_result kind json field =
  match member field json with
  | `List values ->
      let rec loop seen acc = function
        | [] ->
            if acc = [] then Error (field_error kind field "empty report format list")
            else Ok (List.rev acc)
        | `String raw :: rest ->
            let value = String.lowercase_ascii (String.trim raw) in
            if value = "" then Error (field_error kind field "empty report format")
            else
              (match report_format_of_string_result value with
               | Ok parsed ->
                   if List.mem parsed seen then loop seen acc rest
                   else loop (parsed :: seen) (parsed :: acc) rest
               | Error message -> Error (field_error kind field message))
        | value :: _ ->
            Error
              (field_error kind field
                 (Printf.sprintf "expected string items, got %s"
                    (json_type_name value)))
      in
      loop [] [] values
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected array, got %s" (json_type_name value)))

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

let delivery_contract_of_yojson_result (json : Yojson.Safe.t) :
    (delivery_contract, string) result =
  let kind = "delivery_contract" in
  match json with
  | `Assoc _ ->
      let* contract_id =
        required_nonempty_string_field kind json "contract_id"
      in
      let* summary = required_string_field kind json "summary" in
      let* acceptance_checks =
        string_list_field_result kind json "acceptance_checks"
      in
      let* required_artifacts =
        string_list_field_result kind json "required_artifacts"
      in
      let* repair_budget = required_int_field kind json "repair_budget" in
      let* repair_budget =
        if repair_budget < 0 then
          Error (field_error kind "repair_budget" "must be non-negative")
        else Ok repair_budget
      in
      let* generator_roles =
        string_list_field_result kind json "generator_roles"
      in
      let* evaluator_role = optional_string_field kind json "evaluator_role" in
      let* evaluator_cascade =
        required_nonempty_string_field kind json "evaluator_cascade"
      in
      let* evidence_refs = string_list_field_result kind json "evidence_refs" in
      let* updated_by = required_nonempty_string_field kind json "updated_by" in
      let* updated_at_iso =
        required_nonempty_string_field kind json "updated_at_iso"
      in
      Ok
        {
          contract_id;
          summary;
          acceptance_checks;
          required_artifacts;
          repair_budget;
          generator_roles;
          evaluator_role;
          evaluator_cascade;
          evidence_refs;
          updated_by;
          updated_at_iso;
        }
  | value ->
      Error
        (field_error kind "<root>"
           (Printf.sprintf "expected object, got %s" (json_type_name value)))

let delivery_contract_of_yojson (json : Yojson.Safe.t) =
  match delivery_contract_of_yojson_result json with
  | Ok contract -> Some contract
  | Error _ -> None

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

let delivery_verdict_of_yojson_result (json : Yojson.Safe.t) :
    (delivery_verdict, string) result =
  let kind = "delivery_verdict" in
  match json with
  | `Assoc _ ->
      let* contract_id =
        required_nonempty_string_field kind json "contract_id"
      in
      let* status =
        required_enum_field kind json "status"
          delivery_verdict_status_of_string_result
      in
      let* summary = required_string_field kind json "summary" in
      let* evaluator = required_nonempty_string_field kind json "evaluator" in
      let* evaluator_role = optional_string_field kind json "evaluator_role" in
      let* evaluator_cascade =
        required_nonempty_string_field kind json "evaluator_cascade"
      in
      let* repair_directive =
        optional_string_field kind json "repair_directive"
      in
      let* evidence_refs = string_list_field_result kind json "evidence_refs" in
      let* generated_at_iso =
        required_nonempty_string_field kind json "generated_at_iso"
      in
      Ok
        {
          contract_id;
          status;
          summary;
          evaluator;
          evaluator_role;
          evaluator_cascade;
          repair_directive;
          evidence_refs;
          generated_at_iso;
        }
  | value ->
      Error
        (field_error kind "<root>"
           (Printf.sprintf "expected object, got %s" (json_type_name value)))

let delivery_verdict_of_yojson (json : Yojson.Safe.t) =
  match delivery_verdict_of_yojson_result json with
  | Ok verdict -> Some verdict
  | Error _ -> None

let optional_delivery_contract_field_result kind json field =
  match member field json with
  | `Null -> Ok None
  | (`Assoc _ as value) -> (
      match delivery_contract_of_yojson_result value with
      | Ok contract -> Ok (Some contract)
      | Error message -> Error (field_error kind field message))
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected object or null, got %s"
              (json_type_name value)))

let optional_delivery_verdict_field_result kind json field =
  match member field json with
  | `Null -> Ok None
  | (`Assoc _ as value) -> (
      match delivery_verdict_of_yojson_result value with
      | Ok verdict -> Ok (Some verdict)
      | Error message -> Error (field_error kind field message))
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected object or null, got %s"
              (json_type_name value)))

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

let planned_worker_of_yojson_result (json : Yojson.Safe.t) :
    (planned_worker, string) result =
  let kind = "planned_worker" in
  match json with
  | `Assoc _ ->
      let* spawn_agent = required_nonempty_string_field kind json "spawn_agent" in
      let* runtime_actor = optional_string_field kind json "runtime_actor" in
      let* spawn_role = optional_string_field kind json "spawn_role" in
      let* spawn_model = optional_string_field kind json "spawn_model" in
      let* execution_scope =
        optional_enum_field kind json "execution_scope"
          execution_scope_of_string_result
      in
      let* thinking_enabled =
        optional_bool_field kind json "thinking_enabled"
      in
      let* thinking_budget = optional_int_field kind json "thinking_budget" in
      let* max_turns = optional_int_field kind json "max_turns" in
      let* timeout_seconds =
        optional_int_field kind json "timeout_seconds"
      in
      let* worker_class =
        optional_enum_field kind json "worker_class" worker_class_of_string_result
      in
      let* parent_actor = optional_string_field kind json "parent_actor" in
      let* capsule_mode =
        optional_enum_field kind json "capsule_mode" capsule_mode_of_string_result
      in
      let* runtime_pool = optional_string_field kind json "runtime_pool" in
      let* lane_id = optional_string_field kind json "lane_id" in
      let* controller_level =
        optional_enum_field kind json "controller_level"
          controller_level_of_string_result
      in
      let* control_domain =
        optional_enum_field kind json "control_domain"
          control_domain_of_string_result
      in
      let* supervisor_actor =
        optional_string_field kind json "supervisor_actor"
      in
      let* task_profile =
        optional_enum_field kind json "task_profile" task_profile_of_string_result
      in
      let* risk_level =
        optional_enum_field kind json "risk_level" risk_level_of_string_result
      in
      let* routing_confidence =
        optional_float_field kind json "routing_confidence"
      in
      let* routing_reason = optional_string_field kind json "routing_reason" in
      let* routing_escalated =
        match member "routing_escalated" json with
        | `Null -> Ok false
        | `Bool value -> Ok value
        | value ->
            Error
              (field_error kind "routing_escalated"
                 (Printf.sprintf "expected bool or null, got %s"
                    (json_type_name value)))
      in
      Ok
        {
          spawn_agent;
          runtime_actor;
          spawn_role;
          spawn_model;
          execution_scope;
          thinking_enabled;
          thinking_budget;
          max_turns;
          timeout_seconds;
          worker_class;
          parent_actor;
          capsule_mode;
          runtime_pool;
          lane_id;
          controller_level;
          control_domain;
          supervisor_actor;
          task_profile;
          risk_level;
          routing_confidence;
          routing_reason;
          routing_escalated;
        }
  | value ->
      Error
        (field_error kind "<root>"
           (Printf.sprintf "expected object, got %s" (json_type_name value)))

let planned_worker_of_yojson (json : Yojson.Safe.t) =
  match planned_worker_of_yojson_result json with
  | Ok worker -> Some worker
  | Error _ -> None

let planned_workers_field_result kind json field =
  match member field json with
  | `List values ->
      let rec loop acc = function
        | [] -> Ok (dedup_planned_workers (List.rev acc))
        | value :: rest ->
            let* worker = planned_worker_of_yojson_result value in
            loop (worker :: acc) rest
      in
      loop [] values
  | value ->
      Error
        (field_error kind field
           (Printf.sprintf "expected array, got %s" (json_type_name value)))

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

let session_of_yojson_result (json : Yojson.Safe.t) : (session, string) result =
  let kind = "session" in
  match json with
  | `Assoc _ ->
      let* session_id = required_nonempty_string_field kind json "session_id" in
      let* goal = required_nonempty_string_field kind json "goal" in
      let* created_by = required_nonempty_string_field kind json "created_by" in
      let* origin_kind =
        required_enum_field kind json "origin_kind"
          session_origin_kind_of_string_result
      in
      let* room_id = required_nonempty_string_field kind json "room_id" in
      let* operation_id = optional_string_field kind json "operation_id" in
      let* status =
        required_enum_field kind json "status" status_of_string_result
      in
      let* duration_seconds = required_int_field kind json "duration_seconds" in
      let* execution_scope =
        required_enum_field kind json "execution_scope"
          execution_scope_of_string_result
      in
      let* checkpoint_interval_sec =
        required_int_field kind json "checkpoint_interval_sec"
      in
      let* min_agents = required_int_field kind json "min_agents" in
      let* scale_profile =
        required_enum_field kind json "scale_profile"
          scale_profile_of_string_result
      in
      let* control_profile =
        required_enum_field kind json "control_profile"
          control_profile_of_string_result
      in
      let* orchestration_mode =
        required_enum_field kind json "orchestration_mode"
          orchestration_mode_of_string_result
      in
      let* communication_mode =
        required_enum_field kind json "communication_mode"
          communication_mode_of_string_result
      in
      let* model_cascade = string_list_field_result kind json "model_cascade" in
      let* fallback_policy =
        required_enum_field kind json "fallback_policy"
          fallback_policy_of_string_result
      in
      let* instruction_profile =
        required_enum_field kind json "instruction_profile"
          instruction_profile_of_string_result
      in
      let* alert_channel =
        required_enum_field kind json "alert_channel"
          alert_channel_of_string_result
      in
      let* auto_resume = required_bool_field kind json "auto_resume" in
      let* report_formats = report_formats_field_result kind json "report_formats" in
      let* turn_count = required_int_field kind json "turn_count" in
      let* agent_names = string_list_field_result kind json "agent_names" in
      let* planned_workers =
        planned_workers_field_result kind json "planned_workers"
      in
      let* broadcast_count = required_int_field kind json "broadcast_count" in
      let* portal_count = required_int_field kind json "portal_count" in
      let* cascade_attempted = required_int_field kind json "cascade_attempted" in
      let* cascade_success = required_int_field kind json "cascade_success" in
      let* cascade_failed = required_int_field kind json "cascade_failed" in
      let* fallback_task_created =
        required_int_field kind json "fallback_task_created"
      in
      let* min_agents_violation_streak =
        required_int_field kind json "min_agents_violation_streak"
      in
      let* policy_violations =
        string_list_field_result kind json "policy_violations"
      in
      let* baseline_done_counts =
        assoc_int_field_result kind json "baseline_done_counts"
      in
      let* final_done_delta_total =
        optional_int_field kind json "final_done_delta_total"
      in
      let* final_done_delta_by_agent =
        optional_assoc_int_field_result kind json "final_done_delta_by_agent"
      in
      let* started_at = required_float_field kind json "started_at" in
      let* planned_end_at = required_float_field kind json "planned_end_at" in
      let* stopped_at = optional_float_field kind json "stopped_at" in
      let* last_checkpoint_at =
        optional_float_field kind json "last_checkpoint_at"
      in
      let* last_event_at = optional_float_field kind json "last_event_at" in
      let* last_turn_at = optional_float_field kind json "last_turn_at" in
      let* stop_reason = optional_string_field kind json "stop_reason" in
      let* generated_report = required_bool_field kind json "generated_report" in
      let* delivery_contract =
        optional_delivery_contract_field_result kind json "delivery_contract"
      in
      let* latest_delivery_verdict =
        optional_delivery_verdict_field_result kind json
          "latest_delivery_verdict"
      in
      let* artifacts_dir = required_string_field kind json "artifacts_dir" in
      let* created_at_iso =
        required_nonempty_string_field kind json "created_at_iso"
      in
      let* updated_at_iso =
        required_nonempty_string_field kind json "updated_at_iso"
      in
      Ok
        {
          session_id;
          goal;
          created_by;
          origin_kind;
          room_id;
          operation_id;
          status;
          duration_seconds;
          execution_scope;
          checkpoint_interval_sec;
          min_agents;
          scale_profile;
          control_profile;
          orchestration_mode;
          communication_mode;
          model_cascade;
          fallback_policy;
          instruction_profile;
          alert_channel;
          auto_resume;
          report_formats;
          turn_count;
          agent_names;
          planned_workers;
          broadcast_count;
          portal_count;
          cascade_attempted;
          cascade_success;
          cascade_failed;
          fallback_task_created;
          min_agents_violation_streak;
          policy_violations;
          baseline_done_counts;
          final_done_delta_total;
          final_done_delta_by_agent;
          started_at;
          planned_end_at;
          stopped_at;
          last_checkpoint_at;
          last_event_at;
          last_turn_at;
          stop_reason;
          generated_report;
          delivery_contract;
          latest_delivery_verdict;
          artifacts_dir;
          created_at_iso;
          updated_at_iso;
        }
  | value ->
      Error
        (field_error kind "<root>"
           (Printf.sprintf "expected object, got %s" (json_type_name value)))

let session_of_yojson json =
  match session_of_yojson_result json with
  | Ok session -> Some session
  | Error message ->
      Log.Session.error "session_of_yojson parse failed: %s" message;
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
  let kind = "checkpoint" in
  match json with
  | `Assoc _ ->
      let* ts = required_float_field kind json "ts" in
      let* ts_iso = required_nonempty_string_field kind json "ts_iso" in
      let* status =
        required_enum_field kind json "status" status_of_string_result
      in
      let* elapsed_sec = required_int_field kind json "elapsed_sec" in
      let* remaining_sec = required_int_field kind json "remaining_sec" in
      let* progress_pct = required_float_field kind json "progress_pct" in
      let* done_delta_total =
        required_int_field kind json "done_delta_total"
      in
      let* done_delta_by_agent =
        assoc_int_field_result kind json "done_delta_by_agent"
      in
      let* active_agents = string_list_field_result kind json "active_agents" in
      Ok
        {
          ts;
          ts_iso;
          status;
          elapsed_sec;
          remaining_sec;
          progress_pct;
          done_delta_total;
          done_delta_by_agent;
          active_agents;
        }
  | value ->
      Error
        (field_error kind "<root>"
           (Printf.sprintf "expected object, got %s" (json_type_name value)))

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
