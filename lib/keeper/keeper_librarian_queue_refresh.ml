type policy = { instructions : string; task_id : Keeper_id.Task_id.t option }

let policy_of_meta (meta : Keeper_meta_contract.keeper_meta) =
  { instructions = meta.instructions; task_id = meta.current_task_id }

let policy_equal left right =
  String.equal left.instructions right.instructions
  && Option.equal Keeper_id.Task_id.equal left.task_id right.task_id

type attempt_state =
  | Pending
  | Pending_retire_after_attempt
  | Attempted of policy

type runtime_entry = Not_entered | Entered

type remembered =
  { trace_id : string
  ; identity : unit ref
  ; attempt_state : attempt_state
  ; process : meta:Keeper_meta_contract.keeper_meta -> Keeper_librarian_runtime.trigger -> runtime_entry
  }

let remembered : (string * remembered) list Atomic.t = Atomic.make []
(* Registry mutations never yield; provider work runs outside this mutex. *)
let mu = Stdlib.Mutex.create ()
let remember_turn ~base_path ~keeper_name ~trace_id process =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect mu (fun () ->
    Atomic.set remembered
      ((key, {trace_id; identity = ref (); attempt_state = Pending; process}) ::
       List.remove_assoc key (Atomic.get remembered)))

let forget_turn ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect mu (fun () ->
    match List.assoc_opt key (Atomic.get remembered) with
    | Some ({ attempt_state = Pending; _ } as evidence) ->
      Atomic.set remembered
        ( (key, { evidence with attempt_state = Pending_retire_after_attempt })
        :: List.remove_assoc key (Atomic.get remembered) )
    | Some { attempt_state = Pending_retire_after_attempt; _ } -> ()
    | Some { attempt_state = Attempted _; _ } | None ->
      Atomic.set remembered (List.remove_assoc key (Atomic.get remembered)))
;;

let attempt_remembered ~base_path ~keeper_name ~trace_id ~meta ~sources_changed ~trigger =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  match List.assoc_opt key (Atomic.get remembered) with
  | Some evidence when String.equal evidence.trace_id trace_id ->
    (match evidence.attempt_state, sources_changed with
     | Attempted policy, false when policy_equal policy (policy_of_meta meta) -> ()
     | Pending, _ | Pending_retire_after_attempt, _ | Attempted _, _ ->
       (match evidence.process ~meta trigger with
        | Not_entered -> ()
        | Entered ->
          (* Runtime entry records an attempt, not extraction or commit success.
             Pre-entry refusal and exceptions keep handoff evidence pending;
             an in-flight replacement remains owned by its newer identity. *)
          Stdlib.Mutex.protect mu (fun () ->
            match List.assoc_opt key (Atomic.get remembered) with
            | Some latest when latest.identity == evidence.identity ->
              (match latest.attempt_state with
               | Pending_retire_after_attempt ->
                 Atomic.set remembered (List.remove_assoc key (Atomic.get remembered))
               | Pending | Attempted _ ->
                 Atomic.set remembered
                   ((key, { latest with attempt_state = Attempted (policy_of_meta meta) }) ::
                    List.remove_assoc key (Atomic.get remembered)))
            | Some _ | None -> ())));
    true
  | Some _ | None -> false

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
  Stdlib.Mutex.protect measurements_mu (fun () -> Hashtbl.remove measurements key)
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

let run ~trigger ~base_path ~keeper_name =
  run_durable ~base_path ~keeper_name;
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
    let handled = attempt_remembered ~base_path ~keeper_name
        ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
        ~meta ~sources_changed ~trigger in
    let continuity = Domain_pool_ref.submit_io_or_inline (fun () ->
      Keeper_librarian_continuity.prepare_committed ~config:(Workspace.default_config base_path)
        ~keeper_name ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)) in
    let continuity = match continuity with
      | Ok value -> value
      | Error detail -> Log.Keeper.warn ~keeper_name "continuity source unavailable: %s" detail; None in
    if (sources_changed && not handled) || Option.is_some continuity then (
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
        Keeper_librarian_runtime.run_best_effort ~trigger:Queue_changed
          ~write_scope:Keeper_librarian_runtime.Context_only
          ?continuity
          ~base_path ~keepers_dir ~keeper_id:keeper_name
          ~expected_revision:(Option.map (fun (s : Keeper_memory_os_current.t) -> s.revision) current) inp)
  | (Disabled | Invalid), _
  | Enabled, (Owner_absent | Owner_projection {meta = None; _}
             | Owner_projection {stopping = true; _}) -> ()

let run_completed_turn ~base_path ~keeper_name =
  run ~trigger:Keeper_librarian_runtime.Conversation_completed ~base_path ~keeper_name

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
            (fun () -> run ~trigger:Keeper_librarian_runtime.Queue_changed
              ~base_path ~keeper_name)
        in ()))

let submit_durable ~base_path ~keeper_name =
  let (_ : Keeper_memory_lane.outcome) =
    Keeper_memory_lane.submit ~base_path ~keeper_name (fun () ->
      run_durable ~base_path ~keeper_name)
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
  let attempt_remembered = attempt_remembered
  let run_durable_with_commit = run_durable_with_commit
end
