(** Tool_registration_check — Startup validation of keeper tool policy coverage.

    Detects drift between the runtime keeper tool universe and
    config/tool_policy.toml group definitions.
    Called once after init_policy_config succeeds. *)

type validation_result = {
  orphan_toml : string list;
  uncovered : string list;
}

let add_names names tbl =
  List.iter (fun name -> Hashtbl.replace tbl name ()) names;
  tbl

let runtime_keeper_tool_names () =
  Hashtbl.create 512
  |> add_names Keeper_exec_tools.keeper_internal_candidate_tool_names
  |> add_names (Keeper_exec_tools.effective_core_tools ())
  |> add_names Keeper_exec_tools.keeper_admin_dispatched_tools
  |> add_names
       (Keeper_tool_policy.keeper_supported_masc_tool_names_from_schemas
          Config.raw_all_tool_schemas)

let validate () : validation_result =
  match Keeper_tool_policy.policy_config_for_validation () with
  | None -> { orphan_toml = []; uncovered = [] }
  | Some cfg ->
    let runtime_keeper_tools = runtime_keeper_tool_names () in
    let configured =
      let tbl = Hashtbl.create 256 in
      List.iter (fun n -> Hashtbl.replace tbl n ())
        (Keeper_tool_policy_config.all_group_tools cfg
         @ Keeper_tool_policy_config.all_masc_tools cfg);
      tbl
    in
    let orphan_toml =
      Hashtbl.fold (fun name () acc ->
        if not (Hashtbl.mem runtime_keeper_tools name) then name :: acc else acc
      ) configured []
      |> List.sort String.compare
    in
    (* tool_policy.toml describes the keeper-facing subset, not the full MCP
       registry, so reverse "coverage" against all registered tools is noisy
       and not actionable as a startup warning. *)
    let uncovered = [] in
    { orphan_toml; uncovered }

let log_validation_result (r : validation_result) =
  if r.orphan_toml <> [] then
    Log.Server.warn "tool_policy unknown tool names (%d): %s"
      (List.length r.orphan_toml)
      (String.concat ", " (List.filteri (fun i _ -> i < 10) r.orphan_toml));
  if r.uncovered <> [] then
    Log.Server.info "tool_policy reverse coverage (%d): %s"
      (List.length r.uncovered)
      (String.concat ", " (List.filteri (fun i _ -> i < 10) r.uncovered))
