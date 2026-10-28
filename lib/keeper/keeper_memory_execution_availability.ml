module Contract = Keeper_librarian_addon
module Runtime = Lane_addon_runtime
module Exact = Lane_addon_exact
module Registry = Runtime_exact_output_registry

type mode = Preflight | Live of Runtime.tool_execution_snapshot

type problem =
  | Configuration_unreadable of Lane_addon_config.issue list
  | Addon_unattached
  | Addon_off of string list
  | Multiple_installations of string list
  | Tool_missing of string
  | Output_not_selected of string
  | Route_unavailable of Exact.lane_unavailable
  | Export_unavailable of Contract.unavailable
  | Declaration_not_applied

type binding = { installation_id : string; output : string; route_table : string }
type state =
  | Disabled
  | Invalid_setting
  | Unavailable of binding option * problem
  | Configuration_admitted of binding
  | Serving of binding * Runtime.tool_execution

type t = (Contract.operation * state) list

let observe ~setting ~(declarations : Lane_addon_config.snapshot) ~route ~mode =
  let inspect operation =
    match setting with
    | Env_config_keeper.KeeperMemoryOs.Disabled -> Disabled
    | Invalid -> Invalid_setting
    | Enabled ->
      if not declarations.complete || declarations.issues <> [] then
        Unavailable (None, Configuration_unreadable declarations.issues)
      else
        let candidates = List.filter (fun (d : Lane_addon_config.declaration) ->
          String.equal d.package.id Contract.package_id) declarations.declarations in
        let enabled = List.filter (fun (d : Lane_addon_config.declaration) -> d.enabled) candidates in
        match enabled with
        | [] -> Unavailable (None, (match candidates with
            | [] -> Addon_unattached
            | _ :: _ -> Addon_off (List.map (fun (d : Lane_addon_config.declaration) -> d.id) candidates)))
        | _ :: _ :: _ -> Unavailable (None, Multiple_installations
            (List.map (fun (d : Lane_addon_config.declaration) -> d.id) enabled))
        | [d] ->
          let output = Contract.output operation in
          match Runtime_schema.addon_lane ~declaration_id:d.id ~output with
          | Error _ -> Unavailable (None, Configuration_unreadable
              [{source_path=d.source_path;id=Some d.id;message="Invalid Librarian exact-output identity"}])
          | Ok lane ->
            let binding = {installation_id=d.id;output;
              route_table=Runtime_schema.exact_lane_table_name (Runtime_schema.Addon lane)} in
            let unavailable problem = Unavailable (Some binding,problem) in
            if not (List.mem (Contract.tool operation) d.package.exported_tools) then
              unavailable (Tool_missing (Contract.tool operation))
            else if not (List.exists (fun (entry : Lane_addon_types.exact_output) ->
              String.equal entry.name output) d.package.exact_outputs) then
              unavailable (Output_not_selected output)
            else match route lane with
            | Error reason -> unavailable (Route_unavailable reason)
            | Ok () ->
              match mode with
              | Preflight -> Configuration_admitted binding
              | Live snapshot ->
                match Contract.select operation snapshot with
                | Error reason -> unavailable (Export_unavailable reason)
                | Ok entry ->
                  if entry.installation_id <> Some d.id
                     || entry.configuration_revision <> Some d.revision then
                    unavailable Declaration_not_applied
                  else Serving (binding,entry)
  in
  List.map (fun operation -> operation,inspect operation) Contract.all

let snapshot ~config ~mode =
  let directory = Runtime.configuration_directory config in
  let declarations = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () -> Lane_addon_config.load ~directory) in
  let registry = Registry.current () in
  let route lane = match registry with
    | Error error -> Error (Exact.Lane_registry_unavailable {detail=Registry.publication_error_to_string error})
    | Ok registry ->
      match Registry.resolve_lane registry ~lane_id:(Runtime_schema.exact_lane_key (Runtime_schema.Addon lane)) with
      | Error (Registry.Exact_lane_unconfigured _) -> Error Exact.Lane_unconfigured
      | Error (Registry.Exact_lane_off _) -> Error Exact.Lane_off
      | Error (Registry.No_admitted_lane_slots _) -> Error Exact.No_admitted_slots
      | Ok {selected_slots=[];cli_slots=[]} -> Error Exact.No_admitted_slots
      | Ok {selected_slots=_;cli_slots=_} -> Ok () in
  let mode = match mode with
    | `Preflight -> Preflight
    | `Live -> Live (Runtime.tool_execution_snapshot ~config
        ~access:Lane_addon_sources.Operator_configuration ~reserved:(Contract.reserved ())) in
  observe ~setting:(Env_config_keeper.KeeperMemoryOs.librarian_config_state ())
    ~declarations ~route ~mode

let string_list values = `List (List.map (fun value -> `String value) values)
let binding_json binding = `Assoc ["installation_id",`String binding.installation_id;
  "output",`String binding.output;"route_table",`String binding.route_table]
(* Full health is readable without operator credentials. Provider bodies and
   host failure details remain in the authenticated Lane inventory; this
   surface carries typed categories and original IDs, never those bodies. *)
let not_final_json reason =
  let code = match reason with
    | Exact.Lane_unavailable Lane_unconfigured -> "lane_unconfigured"
    | Lane_unavailable Lane_off -> "lane_off"
    | Lane_unavailable No_admitted_slots -> "no_admitted_slots"
    | Lane_unavailable (Lane_registry_unavailable _) -> "lane_registry_unavailable"
    | Provider_refused (Provider_unavailable _) -> "provider_unavailable"
    | Provider_refused (Provider_auth_refused _) -> "provider_auth_refused"
    | Provider_refused (Provider_configuration_refused _) -> "provider_configuration_refused"
    | Attempt_in_progress -> "attempt_in_progress" in
  `Assoc ["reason",`String code]
let host_issue_json issue =
  let code,request = match issue with
    | Runtime.Listing_failed _ -> "listing_failed",None
    | Listing_refused _ -> "listing_refused",None
    | Relisted_delivered_request id -> "relisted_delivered_request",Some id
    | Result_delivery_failed {request_id;_} -> "result_delivery_failed",Some request_id
    | Exact_record_failed {request_id;_} -> "exact_record_failed",Some request_id
    | Ask_record_failed {request_id;_} -> "ask_record_failed",Some request_id
    | No_exact_runner -> "no_exact_runner",None
    | No_web_search_runner -> "no_web_search_runner",None in
  `Assoc ["kind",`String code;"request_id",Option.fold ~none:`Null ~some:(fun id -> `String id) request]
let problem_json = function
  | Configuration_unreadable issues -> "configuration_unreadable",true,
    `List (List.map (fun (issue : Lane_addon_config.issue) ->
      `Assoc ["installation_id",Option.fold ~none:`Null ~some:(fun id -> `String id) issue.id;
        "reason",`String "declaration_unavailable"]) issues)
  | Addon_unattached -> "addon_unattached",true,`Null
  | Addon_off ids -> "addon_off",false,string_list ids
  | Multiple_installations ids -> "multiple_installations",true,string_list ids
  | Tool_missing name -> "tool_missing",true,`String name
  | Output_not_selected name -> "output_not_selected",false,`String name
  | Route_unavailable reason ->
    let action = match reason with Exact.Lane_off -> false
      | Lane_unconfigured | No_admitted_slots | Lane_registry_unavailable _ -> true in
    "route_unavailable",action,not_final_json (Exact.Lane_unavailable reason)
  | Export_unavailable reason ->
    let code,action = match reason with
      | Contract.Unattached -> "worker_not_attached",true
      | Unready (first,rest) ->
        let action=List.exists (fun (entry : Lane_addon_unready.t) -> match entry.reason with
          | Failed _ -> true | Starting | Stopping | Detaching -> false) (first::rest) in
        "worker_unready",action
      | Export_conflict _ -> "export_conflict",true
      | Wrong_package _ -> "wrong_package",true
      | Manual_installation -> "manual_installation",true in
    let detail = match reason with
      | Contract.Unready (first,rest) ->
        `List (List.map (fun (entry : Lane_addon_unready.t) ->
          let state = match entry.reason with
            | Starting -> "starting" | Stopping -> "stopping"
            | Detaching -> "detaching" | Failed _ -> "failed" in
          `Assoc ["installation_id",`String entry.installation;"instance_id",`String entry.instance_id;
            "state",`String state;"message",`String (Lane_addon_unready.message entry)]) (first::rest))
      | Unattached | Export_conflict _ | Wrong_package _ | Manual_installation ->
        `String (Contract.unavailable_to_string reason) in
    code,action,detail
  | Declaration_not_applied -> "declaration_not_applied",false,`Null

let state_json = function
  | Disabled -> "disabled",false,"disabled",`Null,[]
  | Invalid_setting -> "degraded",true,"invalid_setting",`Null,[]
  | Configuration_admitted binding -> "ok",false,"configuration_admitted",binding_json binding,[]
  | Unavailable (binding,reason) ->
    let code,action,detail=problem_json reason in
    let status = match reason with
      | Addon_off _ | Output_not_selected _ | Route_unavailable Exact.Lane_off -> "disabled"
      | Configuration_unreadable _ | Addon_unattached | Multiple_installations _ | Tool_missing _
      | Route_unavailable (Lane_unconfigured | No_admitted_slots | Lane_registry_unavailable _)
      | Export_unavailable _ | Declaration_not_applied -> if action then "degraded" else "warning" in
    status,action,code,Option.fold ~none:`Null ~some:binding_json binding,["detail",detail]
  | Serving (binding,entry) ->
    let waits=List.filter (fun (wait : Runtime.exact_wait) -> String.equal wait.output binding.output) entry.exact_waiting in
    let action=Option.is_some entry.host_issue || List.exists (fun (wait : Runtime.exact_wait) ->
      match wait.reason with
      | Exact.Provider_refused (Provider_auth_refused _ | Provider_configuration_refused _) -> true
      | Provider_refused (Provider_unavailable _) | Lane_unavailable _ | Attempt_in_progress -> false) waits in
    let status=if action then "degraded" else if waits<>[] then "warning" else "ok" in
    let code = match entry.host_issue with
      | Some _ -> "host_cycle_unavailable"
      | None ->
        (match List.find_opt (fun (wait : Runtime.exact_wait) -> match wait.reason with
          | Exact.Provider_refused _ -> true | Lane_unavailable _ | Attempt_in_progress -> false) waits with
         | Some {reason=Exact.Provider_refused (Provider_unavailable _);_} -> "provider_unavailable"
         | Some {reason=Exact.Provider_refused (Provider_auth_refused _);_} -> "provider_auth_refused"
         | Some {reason=Exact.Provider_refused (Provider_configuration_refused _);_} -> "provider_configuration_refused"
         | Some {reason=(Exact.Lane_unavailable _ | Exact.Attempt_in_progress);_} | None ->
           if waits=[] then "serving" else "request_waiting") in
    status,action,code,binding_json binding,
    ["worker_serving",`Bool true;"instance_id",`String entry.export.instance_id;
     "last_cycle_waiting",`List (List.map (fun (wait : Runtime.exact_wait) ->
       `Assoc ["request_id",`String wait.request_id;"output",`String wait.output;
         "reason",not_final_json wait.reason]) waits);
     "last_cycle_at",Option.fold ~none:`Null ~some:(fun at -> `Float at) entry.last_cycle_at;
     "last_cycle_issue",Option.fold ~none:`Null ~some:host_issue_json entry.host_issue]

let to_json states =
  let rows=List.map (fun (operation,state) ->
    let status,action,code,binding,details=state_json state in
    status,action,code,`Assoc (["tool",`String (Contract.tool operation);
      "output",`String (Contract.output operation);"status",`String status;
      "state",`String code;"operator_action_required",`Bool action;"binding",binding;
      "provider_execution",`String "not_proven_by_availability"] @ details)) states in
  let status=List.fold_left (fun status (next,_,_,_) ->
    if String.equal next "disabled" then status else Health_status.max_string status next) "ok" rows in
  let reasons=List.filter_map (fun (status,_,code,_) ->
    if String.equal status "ok" || String.equal status "disabled" then None else Some code) rows
    |> List.sort_uniq String.compare in
  let actions=List.filter_map (fun (_,action,code,_) -> if action then Some code else None) rows
    |> List.sort_uniq String.compare in
  `Assoc ["schema",`String "keeper.memory_execution_availability.v1";"status",`String status;
    "operator_action_required",`Bool (actions<>[]);"status_reasons",string_list reasons;
    "operator_action_reasons",string_list actions;
    "operations",`List (List.map (fun (_,_,_,row) -> row) rows);
    "semantics",`String "Configuration and last-cycle observation only; no provider success, source consumption or Memory commit is implied"]
