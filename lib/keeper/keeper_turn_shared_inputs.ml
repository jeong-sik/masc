type t =
  { lane_updates : (Yojson.Safe.t, string) result
  ; workspace_memory : Workspace_memory_ledger.observation
  ; wiki_contents : Keeper_wiki_contents.t
  }

let observe ?preview ~(config : Workspace.config) ~keeper_name () =
  let turn_ref = Option.bind preview Keeper_turn_preview.original_turn_ref in
  Keeper_turn_preview.with_preparation ~writer:preview
    ~turn_ref
    ~phase:Keeper_turn_preview.World_preparation (fun () ->
      let lane () =
        Keeper_turn_preview.with_preparation_result ~writer:preview ~turn_ref
          ~phase:Keeper_turn_preview.Lane_inputs_preparation (fun () ->
            Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
              Lane_addon_subscription.observe ~config ~keeper_name)) in
      let memory () =
        Keeper_turn_preview.with_preparation_result ~writer:preview ~turn_ref
          ~phase:Keeper_turn_preview.Workspace_memory_preparation (fun () ->
            let observed = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
              Workspace_memory_ledger.observe ~base_path:config.base_path) in
            match observed with
            | Workspace_memory_ledger.Unavailable _ -> Error observed
            | Missing | Available _ -> Ok observed)
        |> Result.fold ~ok:Fun.id ~error:Fun.id in
      let wiki () =
        Keeper_turn_preview.with_preparation_result ~writer:preview ~turn_ref
          ~phase:Keeper_turn_preview.Wiki_preparation (fun () ->
            let observed = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
              Keeper_wiki_contents.observe ~base_path:config.base_path) in
            match observed with
            | Keeper_wiki_contents.Unlisted _ -> Error observed
            | Off | Listed _ -> Ok observed)
        |> Result.fold ~ok:Fun.id ~error:Fun.id in
      let lane_updates,workspace_memory,wiki_contents =
        match Eio_guard.execution_context () with
        | Eio_guard.Eio_fiber ->
          let lane_updates,(workspace_memory,wiki_contents) =
            Eio.Fiber.pair lane (fun () -> Eio.Fiber.pair memory wiki) in
          lane_updates,workspace_memory,wiki_contents
        | Eio_guard.Non_eio ->
          let lane_updates = lane () in
          let workspace_memory = memory () in
          let wiki_contents = wiki () in
          lane_updates,workspace_memory,wiki_contents
      in
      (match workspace_memory with
       | Workspace_memory_ledger.Unavailable detail ->
         Log.Keeper.warn "workspace memory discovery unavailable keeper=%s: %s" keeper_name detail
       | Missing | Available _ -> ());
      Keeper_workspace_memory_observation_metrics.record workspace_memory;
      (match wiki_contents with
       | Keeper_wiki_contents.Unlisted detail ->
         Log.Keeper.warn "wiki listing unavailable keeper=%s: %s" keeper_name detail
       | Off | Listed _ -> ());
      {lane_updates;workspace_memory;wiki_contents})
