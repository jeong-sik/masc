(** Tool_registration_check — Startup validation of Tool_spec ↔ TOML coverage.

    Detects drift between registered Tool_spec tools and config/tool_policy.toml
    group definitions. Called once after init_policy_config succeeds. *)

type validation_result = {
  orphan_toml : string list;
  uncovered : string list;
}

let validate () : validation_result =
  let registered =
    let tbl = Hashtbl.create 256 in
    List.iter (fun n -> Hashtbl.replace tbl n ()) (Tool_spec.all_registered_names ());
    tbl
  in
  match Keeper_tool_policy.policy_config_for_validation () with
  | None -> { orphan_toml = []; uncovered = [] }
  | Some cfg ->
    let configured =
      let tbl = Hashtbl.create 256 in
      List.iter (fun n -> Hashtbl.replace tbl n ())
        (Keeper_tool_policy_config.all_group_tools cfg
         @ Keeper_tool_policy_config.all_masc_tools cfg);
      tbl
    in
    let orphan_toml =
      Hashtbl.fold (fun name () acc ->
        if not (Hashtbl.mem registered name) then name :: acc else acc
      ) configured []
      |> List.sort String.compare
    in
    let uncovered =
      Hashtbl.fold (fun name () acc ->
        if not (Hashtbl.mem configured name) then name :: acc else acc
      ) registered []
      |> List.sort String.compare
    in
    { orphan_toml; uncovered }

let log_validation_result (r : validation_result) =
  if r.orphan_toml <> [] then
    Log.Server.warn "TOML->Tool_spec orphans (%d): %s"
      (List.length r.orphan_toml)
      (String.concat ", " (List.filteri (fun i _ -> i < 10) r.orphan_toml));
  if r.uncovered <> [] then
    Log.Server.warn "Tool_spec->TOML uncovered (%d): %s"
      (List.length r.uncovered)
      (String.concat ", " (List.filteri (fun i _ -> i < 10) r.uncovered))
