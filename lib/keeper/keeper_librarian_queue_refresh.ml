type policy = { instructions : string; task_id : Keeper_id.Task_id.t option }

let policy_of_meta (meta : Keeper_meta_contract.keeper_meta) =
  { instructions = meta.instructions; task_id = meta.current_task_id }

let policy_equal left right =
  String.equal left.instructions right.instructions
  && Option.equal Keeper_id.Task_id.equal left.task_id right.task_id

type attempt_state = Pending | Attempted of policy

type remembered =
  { trace_id : string
  ; identity : unit ref
  ; attempt_state : attempt_state
  ; process : meta:Keeper_meta_contract.keeper_meta -> Keeper_librarian_runtime.trigger -> unit
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

let attempt_remembered ~base_path ~keeper_name ~trace_id ~meta ~sources_changed ~trigger =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  match List.assoc_opt key (Atomic.get remembered) with
  | Some evidence when String.equal evidence.trace_id trace_id ->
    (match evidence.attempt_state, sources_changed with
     | Attempted policy, false when policy_equal policy (policy_of_meta meta) -> ()
     | Pending, _ | Attempted _, _ ->
       evidence.process ~meta trigger;
       (* Unit return only proves an attempt. In particular run_best_effort can
          return without committing. Exceptions, including cancellation, leave
          evidence pending; a newer turn arriving during this call stays dirty. *)
       Stdlib.Mutex.protect mu (fun () ->
         match List.assoc_opt key (Atomic.get remembered) with
         | Some latest when latest.identity == evidence.identity ->
           Atomic.set remembered
             ((key, {latest with attempt_state = Attempted (policy_of_meta meta)}) ::
              List.remove_assoc key (Atomic.get remembered))
         | Some _ | None -> ()));
    true
  | Some _ | None -> false

let run ~trigger ~base_path ~keeper_name =
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

module For_testing = struct
  let attempt_remembered = attempt_remembered
end
