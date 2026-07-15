(** Keeper-owned task owner hooks behind the tool/task boundary. *)

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

let install_hooks () =
  let is_registered_agent_alias_fn = is_registered_agent_alias in
  let sync_current_task_binding_fn = sync_current_task_binding in
  Task.Handlers.set_task_owner_hooks
    Task.Handlers.
      { is_registered_agent_alias =
          (fun config agent_name -> is_registered_agent_alias_fn config agent_name)
      ; sync_current_task_binding =
          (fun config ~agent_name -> sync_current_task_binding_fn config ~agent_name)
      }
;;
