(* The server-owned Librarian loop, one per keeper (RFC librarian-lifecycle
   §4.3). See the interface for the contract. The shape -- an owner record
   with a parked resolver, a daemon on the server switch -- is the one
   Server_workspace_memory_curator uses. *)

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
  }

(* Raised into a loop's own switch by [retire]; the daemon ends on it. *)
exception Retired

type life =
  | Starting
  | Running of Eio.Switch.t
  | Purging

type owner =
  { mutex : Stdlib.Mutex.t
  ; mutable pending : bool
  ; mutable parked : unit Eio.Promise.u option
  ; mutable life : life
  ; exited : unit Eio.Promise.t
  ; exit : unit Eio.Promise.u
  ; mutable last : measurement option
  }

let owners_mutex = Stdlib.Mutex.create ()
let owners : (string, owner) Hashtbl.t = Hashtbl.create 16
let server_switch : Eio.Switch.t option Atomic.t = Atomic.make None

let key_of ~config ~keeper_name =
  Filename.concat (Workspace.keepers_runtime_dir config) keeper_name
;;

let find key = Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.find_opt owners key)

let new_owner ~life =
  let exited, exit = Eio.Promise.create () in
  { mutex = Stdlib.Mutex.create ()
  ; pending = true
  ; parked = None
  ; life
  ; exited
  ; exit
  ; last = None
  }
;;

(* Mark pending and hand back the parked resolver, under the owner's mutex;
   resolve outside it. A loop being purged takes no wake. *)
let wake_owner owner =
  let resolver =
    Stdlib.Mutex.protect owner.mutex (fun () ->
      match owner.life with
      | Purging -> None
      | Starting | Running _ ->
        owner.pending <- true;
        let resolver = owner.parked in
        owner.parked <- None;
        resolver)
  in
  Option.iter (fun resolver -> Eio.Promise.resolve resolver ()) resolver
;;

let start_daemon ~sw ~key ~pass owner =
  (* A daemon, because the switch is the server's whole life and the loop
     parks on [owner.parked] whenever there is nothing to do. As an ordinary
     fiber it would hold the server's shutdown open; as a daemon it is
     cancelled with the switch. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec drain () =
      let next =
        Stdlib.Mutex.protect owner.mutex (fun () ->
          match owner.life with
          | Purging -> `Stop
          | Starting | Running _ ->
            if owner.pending
            then (
              owner.pending <- false;
              `Run)
            else (
              let promise, resolver = Eio.Promise.create () in
              owner.parked <- Some resolver;
              `Wait promise))
      in
      match next with
      | `Stop -> ()
      | `Wait promise ->
        Eio.Promise.await promise;
        drain ()
      | `Run ->
        let last_pass =
          try pass () with
          | (Eio.Cancel.Cancelled _ | Retired) as exn -> raise exn
          | exn ->
            Log.Keeper.error "librarian loop %s: pass raised: %s" key (Printexc.to_string exn);
            Raised (Printexc.to_string exn)
        in
        Stdlib.Mutex.protect owner.mutex (fun () ->
          owner.last <- Some { measured_at = Time_compat.now (); last_pass });
        drain ()
    in
    let outcome =
      try
        Eio.Switch.run (fun own ->
          let proceed =
            Stdlib.Mutex.protect owner.mutex (fun () ->
              match owner.life with
              | Starting ->
                owner.life <- Running own;
                true
              | Purging | Running _ -> false)
          in
          if proceed then drain ());
        `Ended
      with
      | Retired -> `Ended
      | Eio.Cancel.Cancelled _ as exn -> `Cancelled exn
      | exn ->
        Log.Keeper.error "librarian loop %s ended: %s" key (Printexc.to_string exn);
        `Ended
    in
    Stdlib.Mutex.protect owner.mutex (fun () -> owner.life <- Purging);
    Eio.Promise.resolve owner.exit ();
    (match outcome with
     | `Ended -> ()
     | `Cancelled exn -> raise exn);
    `Stop_daemon)
;;

(* Admit an owner under [key] and start its daemon, unless one exists. Runs
   on the root-switch domain: the daemon is forked on that switch. *)
let start ~sw ~key ~pass =
  let owner = new_owner ~life:Starting in
  let admitted =
    Stdlib.Mutex.protect owners_mutex (fun () ->
      if Hashtbl.mem owners key
      then false
      else (
        Hashtbl.add owners key owner;
        true))
  in
  if admitted then start_daemon ~sw ~key ~pass owner
;;

let retire_key key =
  let held = new_owner ~life:Purging in
  let owner =
    Stdlib.Mutex.protect owners_mutex (fun () ->
      match Hashtbl.find_opt owners key with
      | Some owner -> Some owner
      | None ->
        Hashtbl.add owners key held;
        None)
  in
  let owner =
    match owner with
    | None ->
      (* Nothing to wait for; the tombstone alone keeps a wake from starting
         a loop while the caller removes files. *)
      Eio.Promise.resolve held.exit ();
      held
    | Some owner ->
      let life, parked =
        Stdlib.Mutex.protect owner.mutex (fun () ->
          let life = owner.life in
          owner.life <- Purging;
          let parked = owner.parked in
          owner.parked <- None;
          life, parked)
      in
      Option.iter (fun resolver -> Eio.Promise.resolve resolver ()) parked;
      (match life with
       | Running own -> Eio_context.run_on_owner_domain (fun () -> Eio.Switch.fail own Retired)
       | Starting | Purging -> ());
      Eio.Promise.await owner.exited;
      owner
  in
  fun () ->
    Stdlib.Mutex.protect owners_mutex (fun () ->
      match Hashtbl.find_opt owners key with
      | Some current when current == owner -> Hashtbl.remove owners key
      | Some _ | None -> ())
;;

(* {1 The production pass} *)

let lane_id = Runs.lane_key Runs.Librarian

let lane_available () =
  match Runtime_exact_output_registry.current () with
  | Error _ -> false
  | Ok registry ->
    (match Runtime_exact_output_registry.resolve_lane registry ~lane_id with
     | Error (Runtime_exact_output_registry.Exact_lane_unconfigured _) -> false
     | Ok _ | Error (Runtime_exact_output_registry.No_admitted_lane_slots _) -> true)
;;

(* RFC §4.4 row 9: the keeper's pending inputs changed since they were last
   organised, or a pocket asks to be reconsidered, so one round with no
   messages organises them. The condition is the one the queue round has
   always used. *)
let queue_round ~config ~keeper_name ~memory_keepers_dir =
  let base_path = config.Workspace.base_path in
  match
    Domain_pool_ref.submit_io_or_inline (fun () ->
      Keeper_meta_store.read_effective_meta_presence config keeper_name)
  with
  | Ok Keeper_meta_store.Meta_absent -> ()
  | Ok (Keeper_meta_store.Meta_not_current detail) | Error detail ->
    Log.Keeper.warn ~keeper_name "queue Librarian round skipped: metadata unreadable: %s" detail
  | Ok (Keeper_meta_store.Meta_present meta) ->
    let working_context =
      Domain_pool_ref.submit_io_or_inline (fun () ->
        Keeper_librarian_context_io.capture
          ~base_path
          ~keepers_dir:memory_keepers_dir
          ~keeper_name)
    in
    let refs sources =
      List.map (fun (source : Keeper_librarian_context.source) -> source.reference) sources
      |> List.sort String.compare
    in
    let prior_refs =
      match working_context.previous with
      | None -> []
      | Some snapshot -> refs snapshot.sources
    in
    let needs_reconsideration =
      match working_context.previous with
      | None -> false
      | Some snapshot ->
        List.exists
          (fun (pocket : Keeper_librarian_context.pocket) ->
             pocket.completeness = Keeper_librarian_context.Needs_reconsideration)
          snapshot.pockets
    in
    if refs working_context.sources <> prior_refs || needs_reconsideration
    then (
      match
        Domain_pool_ref.submit_io_or_inline (fun () ->
          Keeper_memory_os_current.read_for_keepers_dir
            ~keepers_dir:memory_keepers_dir
            ~keeper_id:keeper_name)
      with
      | Error detail ->
        Log.Keeper.warn ~keeper_name "queue Librarian memory unavailable: %s" detail
      | Ok current ->
        let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
        let input : Keeper_librarian.input =
          { turn_ref =
              Ids.Turn_ref.make ~trace_id ~absolute_turn:meta.runtime.usage.total_turns
          ; goal_context =
              (match meta.current_task_id with
               | None -> Keeper_librarian.No_task
               | Some task_id ->
                 Keeper_librarian.Task_goals
                   { task_id = Keeper_id.Task_id.to_string task_id
                   ; criteria = Error "goal context not observed before first completed turn"
                   })
          ; keeper_instructions = meta.instructions
          ; current =
              Option.map
                (fun (snapshot : Keeper_memory_os_current.t) ->
                   { Keeper_librarian.facts = snapshot.facts })
                current
          ; working_context
          ; messages = []
          ; tool_observations = []
          ; counterpart_observations = []
          }
        in
        Keeper_librarian_runtime.run_best_effort
          ~trigger:Keeper_librarian_runtime.Queue_changed
          ~base_path
          ~keepers_dir:memory_keepers_dir
          ~keeper_id:keeper_name
          ~expected_revision:
            (Option.map (fun (snapshot : Keeper_memory_os_current.t) -> snapshot.revision) current)
          input)
;;

let production_pass ~config ~keeper_name () =
  match Env_config.KeeperMemoryOs.librarian_config_state () with
  | Disabled | Invalid -> Off
  | Enabled ->
    if not (lane_available ())
    then (
      Log.Keeper.warn
        ~keeper_name
        "librarian loop: exact lane %s is not configured; the wake is dropped"
        lane_id;
      Lane_unconfigured)
    else (
      let base_path = config.Workspace.base_path in
      let memory_keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
      let commit =
        Consumer.commit_with_runtime
          ~base_path
          ~keepers_dir:memory_keepers_dir
          ~keeper_id:keeper_name
      in
      (* Every pass rechecks the toggle: an ON -> OFF change while a backlog
         drains stops the drain there. *)
      let rec drain () =
        match Env_config.KeeperMemoryOs.librarian_config_state () with
        | Disabled | Invalid -> Off
        | Enabled ->
          (match Consumer.consume_one ~config ~keeper_name ~commit with
           | Ok (Consumer.Baseline_advanced _ | Progress_advanced _ | Official_advanced _) ->
             drain ()
           | Ok Consumer.Nothing_to_read -> Drained
           | Ok Consumer.Memory_not_committed -> Not_committed
           | Error Consumer.Keeper_meta_absent -> Stopped Consumer.Keeper_meta_absent
           | Error error ->
             Log.Keeper.warn
               ~keeper_name
               "durable Librarian range not consumed: %s"
               (Consumer.error_to_string error);
             Stopped error)
      in
      let ended = drain () in
      (* Reading and organising are two jobs; a failed read does not starve
         the organising (§4.3). A keeper with no metadata has nothing to
         organise, and a toggle that turned off ends the pass. *)
      (match ended with
       | Off | Stopped Consumer.Keeper_meta_absent -> ()
       | Lane_unconfigured | Drained | Not_committed | Stopped _ | Raised _ ->
         queue_round ~config ~keeper_name ~memory_keepers_dir);
      ended)
;;

(* {1 The public surface} *)

let with_server_switch ~keeper_name f =
  match Atomic.get server_switch with
  | Some sw -> f sw
  | None ->
    Log.Keeper.warn
      ~keeper_name
      "librarian loop: no server switch is installed; the keeper's loop is not started"
;;

let ensure_key ~config ~keeper_name key =
  match find key with
  | Some _ -> ()
  | None ->
    with_server_switch ~keeper_name (fun sw ->
      Eio_context.run_on_owner_domain (fun () ->
        start ~sw ~key ~pass:(production_pass ~config ~keeper_name)))
;;

let ensure ~config ~keeper_name = ensure_key ~config ~keeper_name (key_of ~config ~keeper_name)

let wake ~base_path ~keeper_name =
  let config = Workspace.default_config base_path in
  let key = key_of ~config ~keeper_name in
  match find key with
  | Some owner -> wake_owner owner
  | None -> ensure_key ~config ~keeper_name key
;;

let init ~sw =
  Atomic.set server_switch (Some sw);
  Keeper_librarian_queue_signal.install (fun ~base_path ~keeper_name ->
    match Env_config.KeeperMemoryOs.librarian_config_state () with
    | Disabled | Invalid -> ()
    | Enabled -> wake ~base_path ~keeper_name)
;;

let boot ~config =
  List.iter (fun keeper_name -> ensure ~config ~keeper_name) (Keeper_meta_store.keeper_names config)
;;

let retire ~config ~keeper_name = retire_key (key_of ~config ~keeper_name)

let last_measurement ~config ~keeper_name =
  match find (key_of ~config ~keeper_name) with
  | None -> None
  | Some owner -> Stdlib.Mutex.protect owner.mutex (fun () -> owner.last)
;;

module For_testing = struct
  let start_with ~sw ~key ~pass = start ~sw ~key ~pass

  let wake_key key =
    match find key with
    | Some owner -> wake_owner owner
    | None -> ()
  ;;

  let retire_key = retire_key

  let measurement_key key =
    match find key with
    | None -> None
    | Some owner -> Stdlib.Mutex.protect owner.mutex (fun () -> owner.last)
  ;;

  let is_parked key =
    match find key with
    | None -> false
    | Some owner ->
      Stdlib.Mutex.protect owner.mutex (fun () -> Option.is_some owner.parked && not owner.pending)
  ;;

  let reset () =
    Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.reset owners);
    Atomic.set server_switch None
  ;;
end
