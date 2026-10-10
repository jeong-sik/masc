module Queue = Keeper_memory_admission_queue
module Current = Keeper_memory_os_current

type judgment_result = Committed | Deferred of string | Input_size_refused of string
type outcome =
  | Disabled | Idle | Settled of {has_more : bool}
  | Pending of string | Unavailable of string

let io = Domain_pool_ref.submit_io_or_inline

let run_with ~keepers_dir ~keeper_name ~judge =
  let read () = io (fun () -> Queue.read_pending ~keepers_dir ~keeper_id:keeper_name) in
  let acknowledge () = io (fun () -> Queue.acknowledge_committed ~keepers_dir ~keeper_id:keeper_name) in
  match acknowledge () with
  | Error detail -> Unavailable detail
  | Ok () ->
    match read () with
    | Error detail -> Unavailable detail
    | Ok None -> Idle
    | Ok (Some batch) ->
      let rec evaluate batch =
        match judge batch with
        | Deferred detail -> Pending detail
        | Input_size_refused detail ->
          (match Queue.smaller_prefix batch with
           | None -> Pending detail
           | Some prefix -> evaluate prefix)
        | Committed ->
          (match acknowledge () with
           | Error detail -> Unavailable detail
           | Ok () ->
             match read () with
             | Error detail -> Unavailable detail
             | Ok None -> Settled {has_more=false}
             | Ok (Some remaining) ->
               if (Queue.range_id remaining).after_sequence >= (Queue.range_id batch).through_sequence
               then Settled {has_more=true}
               else Unavailable "admission commit has no matching consumed-input receipt") in
      evaluate batch

let run ~base_path ~keeper_name =
  match Env_config.KeeperMemoryOs.librarian_config_state () with
  | Disabled | Invalid -> Disabled
  | Enabled ->
    let config = Workspace.default_config base_path in
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let judge admission =
      match io (fun () -> Keeper_meta_store.read_effective_meta_presence_named config keeper_name) with
      | Error detail | Ok (_, Keeper_meta_store.Meta_not_current detail) -> Deferred detail
      | Ok (_, Keeper_meta_store.Meta_absent) -> Deferred "Keeper metadata is absent"
      | Ok (keeper_id, Keeper_meta_store.Meta_present meta) ->
        match io (fun () -> Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name) with
        | Error detail -> Deferred detail
        | Ok snapshot ->
          let input : Keeper_librarian.input =
            { keeper_id; keeper_instructions=meta.instructions;
              turn_ref=Ids.Turn_ref.make
                ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                ~absolute_turn:meta.runtime.usage.total_turns;
              current=Option.map (fun (value : Current.t) ->
                ({Keeper_librarian.facts=value.facts} : Keeper_librarian.current_selection)) snapshot;
              historical_task_contexts=[];
              goal_context=io (fun () -> Keeper_librarian_input_sources.goal_context_for_task
                ~config meta.current_task_id);
              working_context=Keeper_librarian_context.empty;
              messages=[]; tool_observations=[]; counterpart_observations=[] } in
          let committed = ref false in
          let outcome = ref (Deferred "Librarian admission did not commit") in
          Keeper_librarian_runtime.run_best_effort ~write_scope:Memory_maintenance ~admission
            ~on_memory_committed:(fun () -> committed := true)
            ~on_not_committed:(fun reason ->
              (* This is the runtime's existing typed range-sizing decision,
                 not a candidate-count threshold or a prose error match. *)
              outcome := if reason.Keeper_librarian_runtime.walk_shows_size
                then Input_size_refused reason.detail else Deferred reason.detail)
            ~base_path ~keepers_dir ~keeper_id:keeper_name
            ~expected_revision:(Option.map (fun (value : Current.t) -> value.revision) snapshot)
            input;
          if !committed then Committed else !outcome in
    run_with ~keepers_dir ~keeper_name ~judge

module For_testing = struct
  let run_with = run_with
end
