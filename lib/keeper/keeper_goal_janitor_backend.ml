(** Keeper-owned goal binding cleanup installed behind Goal_janitor hooks. *)

let prune_orphan_goal_bindings workspace_config ~valid_goal_ids =
  let total_orphans = ref 0 in
  let keeper_dir =
    Filename.concat (Workspace.masc_dir workspace_config) "keepers"
  in
  if Sys.file_exists keeper_dir && Sys.is_directory keeper_dir then
    Sys.readdir keeper_dir
    |> Array.iter (fun entry ->
      if Filename.check_suffix entry ".json" then begin
        let name = Filename.chop_suffix entry ".json" in
        match Keeper_meta_store.read_meta workspace_config name with
        | Ok (Some meta) when meta.active_goal_ids <> [] ->
          let pruned_ids, removed =
            Goal_janitor.prune_active_goal_ids
              ~valid_goal_ids
              meta.active_goal_ids
          in
          if removed > 0 then begin
            let updated = { meta with active_goal_ids = pruned_ids } in
            match Keeper_meta_store.write_meta workspace_config updated with
            | Ok () -> total_orphans := !total_orphans + removed
            | Error e ->
              Log.Misc.warn
                "[GoalJanitor] failed to persist orphan-pruned meta for \
                 owner=%s removed=%d: %s"
                name
                removed
                e
          end
        | Ok None | Ok (Some _) | Error _ -> ()
      end);
  !total_orphans

let install_hooks () =
  Goal_janitor.set_orphan_goal_binding_hooks
    { Goal_janitor.prune_orphan_goal_bindings = prune_orphan_goal_bindings }
