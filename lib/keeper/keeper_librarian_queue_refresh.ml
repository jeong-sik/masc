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

module Consumer = Keeper_librarian_durable_consumer
module Runs = Exact_lane_run_registry

type pass_end =
  | Off
  | Lane_unconfigured
  | Drained
  | Not_committed
  | Stopped of Consumer.error
  | Raised of string

type measurement =
  { measured_at : float
  ; last_pass : pass_end
  ; unread : Consumer.unread option
  }

type remembered =
  { trace_id : string
  ; identity : unit ref
  ; attempt_state : attempt_state
  ; process : meta:Keeper_meta_contract.keeper_meta -> Keeper_librarian_runtime.trigger -> runtime_entry
  }

let remembered : (string * remembered) list Atomic.t = Atomic.make []
let measurements : (string * measurement) list Atomic.t = Atomic.make []
(* Registry mutations never yield; provider work runs outside this mutex. *)
let mu = Stdlib.Mutex.create ()

let record_measurement ~config ~keeper_name measurement =
  let key = Keeper_registry_types.registry_key ~base_path:config.Workspace.base_path keeper_name in
  Stdlib.Mutex.protect mu (fun () ->
    Atomic.set
      measurements
      ((key, measurement) :: List.remove_assoc key (Atomic.get measurements)))
;;

let last_measurement ~config ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path:config.Workspace.base_path keeper_name in
  List.assoc_opt key (Atomic.get measurements)
;;
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

let rec drain_durable_with_commit ~config ~keeper_name ~commit =
  match Env_config.KeeperMemoryOs.librarian_config_state () with
  | Disabled | Invalid -> Off
  | Enabled ->
    (match
       Consumer.consume_one ~config ~keeper_name ~commit
     with
     | Ok Consumer.Nothing_to_read -> Drained
     | Ok Consumer.Memory_not_committed -> Not_committed
     | Ok (Consumer.Baseline_advanced _ | Progress_advanced _ | Official_advanced _) ->
       (* A stored advance can leave unread cuts, including after the first
          baseline or a successful small retry. Continue on that evidence;
          failures wait for another wake, and every pass rechecks the toggle. *)
       drain_durable_with_commit ~config ~keeper_name ~commit
     | Error Consumer.Keeper_meta_absent -> Stopped Consumer.Keeper_meta_absent
     | Error error ->
       Log.Keeper.warn
         ~keeper_name
         "durable Librarian range not consumed: %s"
         (Consumer.error_to_string error);
       Stopped error)
;;

let run_durable_with_commit ~config ~keeper_name ~commit =
  (* See For_testing: callers exercise effects; production projects the terminal state. *)
  ignore (drain_durable_with_commit ~config ~keeper_name ~commit)
;;

let lane_id = Runs.lane_key Runs.Librarian

let lane_available () =
  match Runtime_exact_output_registry.current () with
  | Error _ -> false
  | Ok registry ->
    (match Runtime_exact_output_registry.resolve_lane registry ~lane_id with
     | Error (Runtime_exact_output_registry.Exact_lane_unconfigured _) -> false
     | Ok _ | Error (Runtime_exact_output_registry.No_admitted_lane_slots _) -> true)
;;

let measure_unread ~config ~keeper_name =
  match Consumer.unread_turns ~config ~keeper_name with
  | Ok unread -> Some unread
  | Error error ->
    Log.Keeper.warn
      ~keeper_name
      "librarian lag not counted: %s"
      (Consumer.error_to_string error);
    None
;;

let finish_measurement ~config ~keeper_name last_pass =
  let unread =
    match last_pass with
    | Off | Stopped Consumer.Keeper_meta_absent -> None
    | Lane_unconfigured | Drained | Not_committed | Stopped _ | Raised _ ->
      measure_unread ~config ~keeper_name
  in
  record_measurement
    ~config
    ~keeper_name
    { measured_at = Time_compat.now (); last_pass; unread }
;;

let run_durable ~base_path ~keeper_name =
  let config = Workspace.default_config base_path in
  match Env_config.KeeperMemoryOs.librarian_config_state () with
  | Disabled | Invalid -> finish_measurement ~config ~keeper_name Off
  | Enabled ->
    if not (lane_available ())
    then (
      Log.Keeper.warn
        ~keeper_name
        "librarian queue: exact lane %s is not configured; the wake is dropped"
        lane_id;
      finish_measurement ~config ~keeper_name Lane_unconfigured)
    else
      let memory_keepers_dir =
        Config_dir_resolver.keepers_dir_for_base_path ~base_path
      in
      let last_pass =
        try
          drain_durable_with_commit
            ~config
            ~keeper_name
            ~commit:
              (Consumer.commit_with_runtime
                 ~base_path
                 ~keepers_dir:memory_keepers_dir
                 ~keeper_id:keeper_name)
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Raised (Printexc.to_string exn)
      in
      finish_measurement ~config ~keeper_name last_pass
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
    if sources_changed && not handled then (
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
