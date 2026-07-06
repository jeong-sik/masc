(** Keeper-owned task owner hooks behind the tool/task boundary. *)

let resolve_agent_name config agent_name ~log_context =
  try Workspace.resolve_agent_name config agent_name with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Task.warn
      "resolve_agent_name failed for %s %s: %s"
      log_context
      agent_name
      (Stdlib.Printexc.to_string exn);
    agent_name
;;

let is_registered_agent_alias config agent_name =
  let agent_name = String.trim agent_name in
  let keeper_name_variants keeper_name =
    let map_sep ~from_ch ~to_ch value =
      String.map (fun c -> if Char.equal c from_ch then to_ch else c) value
    in
    let separator_variants value =
      Json_util.dedupe_keep_order
        [ value
        ; map_sep ~from_ch:'_' ~to_ch:'-' value
        ; map_sep ~from_ch:'-' ~to_ch:'_' value
        ]
    in
    let generated_type_variants value =
      if Nickname.is_dictionary_generated_nickname value
      then (
        match Nickname.extract_agent_type value with
        | Some agent_type when Keeper_config.validate_name agent_type ->
          separator_variants agent_type
        | _ -> [])
      else []
    in
    let base_variants = separator_variants keeper_name in
    Json_util.dedupe_keep_order
      (base_variants @ List.concat_map generated_type_variants base_variants)
  in
  let registered_keeper_name keeper_name =
    keeper_name_variants keeper_name
    |> List.exists (fun name ->
      Option.is_some (Keeper_registry.get ~base_path:config.Workspace.base_path name))
  in
  match Keeper_identity.canonical_keeper_name_from_agent_name agent_name with
  | Some keeper_name ->
    Keeper_identity.is_keeper_agent_alias agent_name
    && registered_keeper_name keeper_name
  | None -> false
;;

let sync_current_task_binding config ~agent_name =
  Keeper_current_task_reconcile.sync_current_task_id_for_agent_name
    ~config
    ~agent_name
;;

let meta_for_agent_result config ~agent_name =
  let resolved = resolve_agent_name config agent_name ~log_context:"owner policy" in
  let candidate_names =
    [ agent_name; resolved ]
    |> List.filter_map Keeper_identity.canonical_keeper_name
    |> Json_util.dedupe_keep_order
  in
  let rec find_meta = function
    | [] -> Ok None
    | keeper_name :: rest -> (
        match Keeper_registry.get ~base_path:config.base_path keeper_name with
        | Some entry -> Ok (Some entry.meta)
        | None -> (
            match Keeper_meta_store.read_meta config keeper_name with
            | Ok (Some meta) -> Ok (Some meta)
            | Ok None -> find_meta rest
            | Error err ->
              Error
                (Printf.sprintf
                   "keeper meta read failed for %s while resolving task-owner \
                    policy for %s: %s"
                   keeper_name
                   agent_name
                   err)))
  in
  find_meta candidate_names

let meta_for_agent config ~agent_name =
  match meta_for_agent_result config ~agent_name with
  | Ok meta -> meta
  | Error err ->
    Log.Task.warn "%s" err;
    None

let transition_action_fail_closed_denylist () =
  Masc_domain.valid_task_action_strings
  |> List.map Task.Handlers.transition_action_denylist_entry

let transition_action_denylist config ~agent_name =
  match meta_for_agent_result config ~agent_name with
  | Ok (Some meta) -> meta.tool_denylist
  | Ok None -> []
  | Error err ->
    Log.Task.warn "transition_action_denylist failed closed: %s" err;
    transition_action_fail_closed_denylist ()

let active_goal_phases_for_agent config ~agent_name =
  match Keeper_meta_store.read_meta_resolved config agent_name with
  | Ok (Some (_, meta)) ->
    List.map
      (fun goal_id ->
         match Goal_store.get_goal config ~goal_id with
         | Some goal -> Printf.sprintf "%s=%s" goal_id (Goal_phase.to_string goal.phase)
         | None -> Printf.sprintf "%s=missing" goal_id)
      meta.active_goal_ids
  | Ok None -> []
  | Error err ->
    Log.Task.warn
      "active_goal_phases_for_agent meta read failed for %s: %s"
      agent_name
      err;
    []
;;
let install_hooks () =
  let is_registered_agent_alias_fn = is_registered_agent_alias in
  let sync_current_task_binding_fn = sync_current_task_binding in
  let transition_action_denylist_fn = transition_action_denylist in
  let active_goal_phases_for_agent_fn = active_goal_phases_for_agent in
  Task.Handlers.set_task_owner_hooks
    Task.Handlers.
      { is_registered_agent_alias =
          (fun config agent_name -> is_registered_agent_alias_fn config agent_name)
      ; sync_current_task_binding =
          (fun config ~agent_name -> sync_current_task_binding_fn config ~agent_name)
      ; transition_action_denylist =
          (fun config ~agent_name -> transition_action_denylist_fn config ~agent_name)
      ; active_goal_phases_for_agent =
          (fun config ~agent_name -> active_goal_phases_for_agent_fn config ~agent_name)
      }
;;
