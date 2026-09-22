type pass_end =
  | Off
  | Lane_unconfigured
  | Drained
  | Not_committed
  | Stopped of Keeper_librarian_durable_consumer.error
  | Raised of string

type measurement =
  { measured_at : float
  ; last_pass : pass_end
  ; unread : Keeper_librarian_durable_consumer.unread option
  }

let measurements : ((string * string), measurement) Hashtbl.t = Hashtbl.create 16
let input_capacities :
    ((string * string), Keeper_lane_cli_oneshot.input_capacity) Hashtbl.t =
  Hashtbl.create 16
let measurements_mu = Stdlib.Mutex.create ()

let measurement_key ~config ~keeper_name =
  Workspace.keepers_runtime_dir config, keeper_name
;;

let last_measurement ~config ~keeper_name =
  let key = measurement_key ~config ~keeper_name in
  Stdlib.Mutex.protect measurements_mu (fun () -> Hashtbl.find_opt measurements key)
;;

let forget_measurement ~config ~keeper_name =
  let key = measurement_key ~config ~keeper_name in
  Stdlib.Mutex.protect measurements_mu (fun () ->
    Hashtbl.remove measurements key;
    Hashtbl.remove input_capacities key)
;;

let last_input_capacity ~config ~keeper_name =
  let key = measurement_key ~config ~keeper_name in
  match Stdlib.Mutex.protect measurements_mu (fun () -> Hashtbl.find_opt input_capacities key) with
  | Some capacity -> Some capacity
  | None ->
    let loaded =
      Domain_pool_ref.submit_io_or_inline (fun () ->
        Keeper_librarian_input_capacity.load
          ~keepers_dir:(Workspace.keepers_runtime_dir config)
          ~keeper_id:keeper_name)
    in
    (match loaded with
     | Ok (Some capacity) ->
       Stdlib.Mutex.protect measurements_mu (fun () ->
         Hashtbl.replace input_capacities key capacity);
       Some capacity
     | Ok None -> None
     | Error detail ->
       Log.Keeper.warn ~keeper_name
         "persisted Librarian input capacity ignored: %s" detail;
       None)
;;

let remember_input_capacity ~config ~keeper_name capacity =
  let key = measurement_key ~config ~keeper_name in
  Stdlib.Mutex.protect measurements_mu (fun () -> Hashtbl.replace input_capacities key capacity);
  (match
     Domain_pool_ref.submit_io_or_inline (fun () ->
       Keeper_librarian_input_capacity.save
         ~keepers_dir:(Workspace.keepers_runtime_dir config)
         ~keeper_id:keeper_name
         { runtime_id = capacity.runtime_id
         ; actual_chars = capacity.capacity.actual_chars
         ; max_chars = capacity.capacity.max_chars
         })
   with
   | Ok () -> ()
   | Error detail ->
     Log.Keeper.warn ~keeper_name
       "Librarian input capacity could not be persisted: %s" detail)
;;

let publish_measurement ~config ~keeper_name ~last_pass ~unread =
  let key = measurement_key ~config ~keeper_name in
  let measurement = { measured_at = Time_compat.now (); last_pass; unread } in
  Stdlib.Mutex.protect measurements_mu (fun () -> Hashtbl.replace measurements key measurement)
;;

let measure_unread ~config ~keeper_name =
  try
    match Keeper_librarian_durable_consumer.unread_turns ~config ~keeper_name with
    | Ok unread -> Some unread
    | Error error ->
      Log.Keeper.warn ~keeper_name "Librarian unread count unavailable: %s"
        (Keeper_librarian_durable_consumer.error_to_string error);
      None
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    (* Observation failure must not change the durable drain's result. *)
    Log.Keeper.warn ~keeper_name "Librarian unread count raised: %s" (Printexc.to_string exn);
    None
;;

let uncommitted_pass () =
  match Runtime_exact_output_registry.current () with
  | Error _ -> Lane_unconfigured
  | Ok registry ->
    let lane_id = Exact_lane_run_registry.lane_key Exact_lane_run_registry.Librarian in
    match Runtime_exact_output_registry.resolve_lane registry ~lane_id with
    | Error (Runtime_exact_output_registry.Exact_lane_unconfigured _) -> Lane_unconfigured
    | Ok _ | Error (Runtime_exact_output_registry.No_admitted_lane_slots _) -> Not_committed
;;

let run_durable_with_commit ~config ~keeper_name ~commit =
  let rec drain () =
    match Env_config.KeeperMemoryOs.librarian_config_state () with
    | Disabled | Invalid -> Off
    | Enabled ->
      match Keeper_librarian_durable_consumer.consume_one ~config ~keeper_name ~commit with
      | Ok Keeper_librarian_durable_consumer.Nothing_to_read -> Drained
      | Ok Memory_not_committed -> uncommitted_pass ()
      | Ok (Baseline_advanced _ | Progress_advanced _ | Official_advanced _) ->
        (* Only stored progress continues the existing drain; observations
           below never control its scheduling or admission. *)
        drain ()
      | Error error ->
        Log.Keeper.warn ~keeper_name "durable Librarian range not consumed: %s"
          (Keeper_librarian_durable_consumer.error_to_string error);
        Stopped error
  in
  try
    let last_pass = drain () in
    let unread = match last_pass with Off -> None | _ -> measure_unread ~config ~keeper_name in
    publish_measurement ~config ~keeper_name ~last_pass ~unread
  with
  | Eio.Cancel.Cancelled _ as exn ->
    (* Do not run another filesystem read in the cancelled context. Replace
       any older success observation before preserving cancellation. *)
    publish_measurement ~config ~keeper_name ~last_pass:(Raised (Printexc.to_string exn)) ~unread:None;
    raise exn
  | exn ->
    publish_measurement ~config ~keeper_name ~last_pass:(Raised (Printexc.to_string exn)) ~unread:None;
    raise exn
;;

let run_durable ~base_path ~keeper_name =
  let config = Workspace.default_config base_path in
  let memory_keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  run_durable_with_commit ~config ~keeper_name
    ~commit:(Keeper_librarian_durable_consumer.commit_with_runtime
      ~base_path ~keepers_dir:memory_keepers_dir ~keeper_id:keeper_name)
;;

(* Continuity has its own exact source position. A Memory baseline does not
   claim the earlier checkpoint was summarized. Work stays in this Keeper's
   existing serial Librarian lane. *)
let run_continuity ?cli_runner ~base_path ~keeper_name () =
  let module P = Keeper_librarian_continuity in
  let module Runtime = Keeper_librarian_runtime in
  let config = Workspace.default_config base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let module O = Keeper_continuity_observation in
  let trace_id = ref None and selected_range = ref None in
  let observe state = O.record_synthesis ~config ~keeper_name
      {O.observed_at=Time_compat.now (); trace_id= !trace_id;
       state; range= !selected_range} in
  let select prepared =
    trace_id := Some (Ids.Turn_ref.trace_id (P.turn_ref prepared));
    selected_range := Some {O.start_atom=P.start_atom prepared;
      end_atom=P.end_atom prepared; completed_end_atom=P.completed_end_atom prepared} in
  let report state detail =
    observe state;
    Log.Keeper.warn ~keeper_name "continuity pass stopped: %s" detail in
  (* Keep the server's measured character limit across wakes in this process.
     A domain-output failure must not make the next drain rediscover it with
     another oversized request. Fitting still checks the runtime is selected
     and re-renders every chunk; neither an atom count nor a prompt is cached. *)
  let capacity = ref (last_input_capacity ~config ~keeper_name) in
  let rec next () =
    observe O.Checking;
    match Env_config.KeeperMemoryOs.librarian_config_state () with
    | Disabled | Invalid -> observe O.Disabled
    | Enabled ->
      match Keeper_meta_store.read_effective_meta_presence config keeper_name with
      | Error detail | Ok (Keeper_meta_store.Meta_not_current detail) -> report O.Source_unavailable detail
      | Ok Keeper_meta_store.Meta_absent -> observe O.Source_unavailable
      | Ok (Keeper_meta_store.Meta_present meta) ->
        let current_trace = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
        if !trace_id <> Some current_trace then selected_range := None;
        trace_id := Some current_trace;
        match Domain_pool_ref.submit_io_or_inline (fun () ->
          P.prepare ~config ~keeper_name
            ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id) ()) with
        | Error detail -> report O.Source_unavailable detail
        | Ok None -> observe O.No_source
        | Ok (Some prepared) -> attempt meta prepared
  and attempt meta prepared =
    select prepared;
    let inputs = Domain_pool_ref.submit_io_or_inline (fun () ->
      let ( let* ) = Result.bind in
      let* current = Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name in
      let input : Keeper_librarian.input =
        { turn_ref = P.turn_ref prepared; goal_context = Keeper_librarian.No_task;
          keeper_instructions = meta.Keeper_meta_contract.instructions;
          current = Option.map (fun (value : Keeper_memory_os_current.t) ->
            {Keeper_librarian.facts = value.facts}) current;
          working_context = Keeper_librarian_context.empty;
          messages = P.messages prepared;
          tool_observations = []; counterpart_observations = [] } in
      let* selected = match !capacity with
        | None -> Ok (Some prepared)
        | Some capacity -> Runtime.fit_continuity ~capacity ~base_path
            ~keeper_id:keeper_name ~input prepared in
      (* One fallback's limit cannot prohibit other providers. If no indivisible
         range fits it, keep the source for the normal lane walk; only a real
         final refusal may stop this attempt. *)
      let selected = match selected with
        | Some selected -> selected
        | None -> prepared in
      let* memory_committed = P.memory_committed ~config ~keeper_name selected in
      let* range_id = P.memory_range_id ~config ~keeper_name selected in
      Ok (current, memory_committed, range_id, selected,
        {input with messages = P.messages selected})) in
    match inputs with
    | Error detail -> report O.Input_unavailable detail
    | Ok (current, memory_committed, range_id, selected, input) ->
      if P.end_atom selected <> P.end_atom prepared then
        Log.Keeper.info ~keeper_name
          "continuity input fitted before dispatch; end_atom=%d -> %d"
          (P.end_atom prepared) (P.end_atom selected);
      select selected;
      observe O.Running;
      let saved = ref false and capacity_refused = ref None in
      Runtime.run_best_effort ?cli_runner
        ~write_scope:(if memory_committed then Runtime.Context_only else Context_and_memory)
        ~continuity:selected
        ?durable_range_id:(if memory_committed then None else Some range_id)
        ~on_capacity_refused:(fun refusal ->
          capacity_refused := Some refusal;
          match refusal with
          | Runtime.Input_limit_unknown -> ()
          | Runtime.Cli_input_limit observed ->
            remember_input_capacity ~config ~keeper_name observed;
            capacity := Some observed)
        ~on_continuity_committed:(fun _ -> saved := true; observe O.Committed)
        ~base_path ~keepers_dir ~keeper_id:keeper_name
        ~expected_revision:(Option.map (fun (value : Keeper_memory_os_current.t) -> value.revision) current)
        input;
      if !saved then next ()
      else match !capacity_refused with
      | None -> observe O.Not_committed
      | Some (Runtime.Cli_input_limit observed) ->
        let fitted = Domain_pool_ref.submit_io_or_inline (fun () ->
          Runtime.fit_continuity ~capacity:observed ~base_path
            ~keeper_id:keeper_name ~input selected) in
        (match fitted with
         | Error detail -> report O.Input_unavailable detail
         | Ok None -> report O.Capacity_refused "source cannot fit the reported CLI input capacity"
         | Ok (Some smaller) when P.end_atom smaller < P.end_atom selected ->
           Log.Keeper.info ~keeper_name
             "continuity input fitted to reported capacity; runtime=%s max_chars=%d end_atom=%d -> %d"
             observed.runtime_id observed.capacity.max_chars
             (P.end_atom selected) (P.end_atom smaller);
           attempt meta smaller
         | Ok (Some _) ->
           report O.Capacity_refused "provider capacity refusal disagrees with local prompt measurement")
      | Some Runtime.Input_limit_unknown ->
        match P.narrow selected with
        | Some smaller ->
          Log.Keeper.info ~keeper_name
            "continuity input capacity refused; narrowing end_atom=%d -> %d"
            (P.end_atom selected) (P.end_atom smaller);
          attempt meta smaller
        | None -> report O.Capacity_refused "source cannot be narrowed safely after runtime capacity refusal"
  in
  try next () with
  | Eio.Cancel.Cancelled _ as exn -> observe O.Cancelled; raise exn
  | exn -> observe O.Not_committed; raise exn
;;

let run ~base_path ~keeper_name =
  run_durable ~base_path ~keeper_name;
  run_continuity ~base_path ~keeper_name ();
  match Env_config.KeeperMemoryOs.librarian_config_state (),
        Keeper_owner_projection.lookup ~base_path ~keeper_name with
  | Enabled, Owner_projection {meta = Some meta; stopping = false} ->
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let working_context = Domain_pool_ref.submit_io_or_inline (fun () ->
      Keeper_librarian_context_io.capture ~base_path ~keepers_dir ~keeper_name) in
    let refs sources = List.map (fun (s : Keeper_librarian_context.source) -> s.reference) sources
                       |> List.sort String.compare in
    let prior_refs = match working_context.previous with None -> [] | Some s -> refs s.sources in
    let needs_reconsideration = match working_context.previous with
      | None -> false
      | Some snapshot -> List.exists (fun (p : Keeper_librarian_context.pocket) ->
          p.completeness = Keeper_librarian_context.Needs_reconsideration) snapshot.pockets in
    let sources_changed = refs working_context.sources <> prior_refs || needs_reconsideration in
    if sources_changed then (
      match Domain_pool_ref.submit_io_or_inline (fun () ->
        Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name) with
      | Error detail -> Log.Keeper.warn ~keeper_name "queue Librarian memory unavailable: %s" detail
      | Ok current ->
        let current_selection = Option.map (fun (s : Keeper_memory_os_current.t) ->
          {Keeper_librarian.facts = s.facts}) current in
        let inp : Keeper_librarian.input =
          { turn_ref = Ids.Turn_ref.make
              ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
              ~absolute_turn:meta.runtime.usage.total_turns
          ; goal_context = (match meta.current_task_id with
              | None -> Keeper_librarian.No_task
              | Some task_id -> Keeper_librarian.Task_goals
                  {task_id = Keeper_id.Task_id.to_string task_id;
                   criteria = Error "goal context not observed before first completed turn"})
          ; keeper_instructions = meta.instructions
          ; current = current_selection
          ; working_context
          ; messages = []; tool_observations = []; counterpart_observations = [] } in
        Keeper_librarian_runtime.run_best_effort
          ~write_scope:Keeper_librarian_runtime.Context_only
          ~base_path ~keepers_dir ~keeper_id:keeper_name
          ~expected_revision:(Option.map (fun (s : Keeper_memory_os_current.t) -> s.revision) current) inp)
  | (Disabled | Invalid), _
  | Enabled, (Owner_absent | Owner_projection {meta = None; _}
             | Owner_projection {stopping = true; _}) -> ()

let install () =
  Keeper_librarian_queue_signal.install (fun ~base_path ~keeper_name ->
    match Env_config.KeeperMemoryOs.librarian_config_state () with
    | Disabled | Invalid -> ()
    | Enabled ->
      (* Queue commits can originate in HTTP/IO domains. Only the short
         submission crosses to the root switch owner; model work is detached. *)
      Eio_context.run_on_owner_domain (fun () ->
        let (_ : Keeper_memory_lane.outcome) =
          Keeper_memory_lane.submit ~base_path ~keeper_name
            (fun () -> run ~base_path ~keeper_name)
        in ()))

let submit_durable ~base_path ~keeper_name =
  let (_ : Keeper_memory_lane.outcome) =
    Keeper_memory_lane.submit ~base_path ~keeper_name (fun () ->
      run_durable ~base_path ~keeper_name;
      run_continuity ~base_path ~keeper_name ())
  in
  ()
;;

let unlaunched_keeper_names ~persisted ~launched =
  List.filter (fun name -> not (List.mem name launched)) persisted
;;

let submit_durable_for_unlaunched ~base_path ~persisted ~launched =
  let names = unlaunched_keeper_names ~persisted ~launched in
  List.iter (fun keeper_name -> submit_durable ~base_path ~keeper_name) names;
  names
;;

module For_testing = struct
  let run_continuity = run_continuity
  let run_durable_with_commit = run_durable_with_commit
end
