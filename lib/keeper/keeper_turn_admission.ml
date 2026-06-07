type fleet_state =
  | Running
  | Paused
  | Stopped

type rejection =
  | Fleet_paused
  | Fleet_stopped
  | Global_inflight_exceeded

type throttle_source =
  | Env_override
  | Toml
  | Default

type fleet_policy =
  { fleet_state : fleet_state
  ; generation : int
  ; reason : string option
  ; updated_by : string option
  ; updated_at : string option
  }

type waiter_info =
  { ticket : int
  ; keeper_name : string
  ; runtime_profile : string
  ; channel : string
  ; enqueued_at : float
  }

type snapshot =
  { fleet_state : fleet_state
  ; global_inflight : int
  ; global_limit : int
  ; available : int
  ; queue_depth : int
  ; active_keepers : string list
  ; waiters : waiter_info list
  ; generation : int
  ; reason : string option
  ; updated_by : string option
  ; updated_at : string option
  }

exception Fleet_stopped_by_operator

type token =
  { token_id : int
  ; keeper_name : string
  ; runtime_profile : string
  ; channel : string
  ; acquired_at : float
  ; released : bool Atomic.t
  ; cancel_requested : bool Atomic.t
  ; cancel_p : unit Eio.Promise.t
  ; cancel_u : unit Eio.Promise.u
  }

type decision = (token, rejection) result

type pending =
  { info : waiter_info
  ; decision_p : decision Eio.Promise.t
  ; decision_u : decision Eio.Promise.u
  ; mutable cancelled : bool
  }

type scheduler_state =
  { mutex : Stdlib.Mutex.t
  ; mutable policy : fleet_policy
  ; mutable next_ticket : int
  ; mutable next_token : int
  ; mutable last_limit : int
  ; inflight : (int, token) Hashtbl.t
  ; active_keepers : (string, int) Hashtbl.t
  ; mutable waiters : pending list
  }

let fleet_state_to_string = function
  | Running -> "running"
  | Paused -> "paused"
  | Stopped -> "stopped"
;;

let rejection_to_string = function
  | Fleet_paused -> "fleet_paused"
  | Fleet_stopped -> "fleet_stopped"
  | Global_inflight_exceeded -> "global_inflight_exceeded"
;;

let throttle_source_to_string = function
  | Env_override -> "env_override"
  | Toml -> "toml"
  | Default -> "default"
;;

let fleet_state_of_string = function
  | "running" -> Some Running
  | "paused" -> Some Paused
  | "stopped" -> Some Stopped
  | _ -> None
;;

let default_policy =
  { fleet_state = Running
  ; generation = 0
  ; reason = None
  ; updated_by = None
  ; updated_at = None
  }
;;

let keeper_turn_throttle_limit, keeper_turn_throttle_source =
  let env_name = "MASC_KEEPER_AUTOBOOT_MAX" in
  let default = 32 in
  let min_v = 1 in
  let max_v = max_int in
  let parse raw =
    let v = Option.value ~default (int_of_string_opt (String.trim raw)) in
    Keeper_config.clamp_int v ~min_v ~max_v
  in
  if Env_config_core.running_under_test_executable () then
    default, Default
  else
    match Sys.getenv_opt env_name with
    | Some raw when String.trim raw <> "" -> parse raw, Env_override
    | _ -> (
      match Env_config_core.raw_value_opt env_name with
      | Some raw when String.trim raw <> "" -> parse raw, Toml
      | _ -> default, Default)
;;

let effective_turn_throttle_limit =
  match keeper_turn_throttle_source with
  | Env_override -> (
    match Keeper_runtime_config.toml_value_opt "MASC_KEEPER_AUTOBOOT_MAX" with
    | Some toml_raw -> (
      match int_of_string_opt (String.trim toml_raw) with
      | Some toml_val when toml_val > 0 ->
        let hard_cap = toml_val * 2 in
        if keeper_turn_throttle_limit > hard_cap
        then hard_cap
        else keeper_turn_throttle_limit
      | _ -> keeper_turn_throttle_limit)
    | None -> keeper_turn_throttle_limit)
  | Toml | Default -> keeper_turn_throttle_limit
;;

let check_throttle_divergence () =
  if Env_config_core.running_under_test_executable () then
    ()
  else
    match keeper_turn_throttle_source with
    | Env_override -> (
      match Keeper_runtime_config.toml_value_opt "MASC_KEEPER_AUTOBOOT_MAX" with
      | None ->
        Log.Keeper.info
          "autoboot: env MASC_KEEPER_AUTOBOOT_MAX=%d (no TOML override, effective=%d)"
          keeper_turn_throttle_limit
          effective_turn_throttle_limit
      | Some toml_raw -> (
        match int_of_string_opt (String.trim toml_raw) with
        | None -> ()
        | Some toml_val when toml_val <= 0 -> ()
        | Some toml_val ->
          let env_val = keeper_turn_throttle_limit in
          let factor = float_of_int env_val /. float_of_int toml_val in
          if effective_turn_throttle_limit < env_val
          then
            Log.Keeper.warn
              "autoboot divergence: env MASC_KEEPER_AUTOBOOT_MAX=%d capped to %d (2x \
               TOML baseline %d, factor %.1fx); fleet overload prevented."
              env_val
              effective_turn_throttle_limit
              toml_val
              factor
          else if factor >= 2.0
          then
            Log.Keeper.warn
              "autoboot divergence: env MASC_KEEPER_AUTOBOOT_MAX=%d is %.1fx the TOML \
               value (%d); fleet may be overloaded. Either unset the env var to honour \
               TOML, or update TOML to match the intended cap."
              env_val
              factor
              toml_val
          else if env_val > toml_val
          then
            Log.Keeper.info
              "autoboot divergence: env MASC_KEEPER_AUTOBOOT_MAX=%d exceeds TOML (%d) \
               by a smaller margin (factor %.1fx); monitor fleet capacity."
              env_val
              toml_val
              factor))
    | Toml | Default -> ()
;;

let () = check_throttle_divergence ()

let semaphore_wait_timeout_sec =
  Keeper_config.float_of_env_default
    "MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC"
    ~default:180.0
    ~min_v:5.0
    ~max_v:Float.max_float
;;

let turn_concurrency_int_of_env_default_for_test name ~default ~min_v ~max_v =
  if Env_config_core.running_under_test_executable ()
  then default
  else Keeper_turn_slot_types.int_of_env_default ~primary:name ~default ~min_v ~max_v
;;

let autonomous_turn_limit =
  turn_concurrency_int_of_env_default_for_test
    "MASC_KEEPER_AUTONOMOUS_CONCURRENCY"
    ~default:16
    ~min_v:1
    ~max_v:max_int
;;

let reactive_turn_limit =
  turn_concurrency_int_of_env_default_for_test
    "MASC_KEEPER_REACTIVE_CONCURRENCY"
    ~default:16
    ~min_v:1
    ~max_v:max_int
;;

let channel_limit ~global_limit channel =
  let global_limit = max 1 global_limit in
  match String.lowercase_ascii (String.trim channel) with
  | "reactive" -> min global_limit reactive_turn_limit
  | "scheduled_autonomous" | "proactive" -> min global_limit autonomous_turn_limit
  | _ -> global_limit
;;

let state =
  { mutex = Stdlib.Mutex.create ()
  ; policy = default_policy
  ; next_ticket = 0
  ; next_token = 0
  ; last_limit = 1
  ; inflight = Hashtbl.create 32
  ; active_keepers = Hashtbl.create 32
  ; waiters = []
  }
;;

let with_mutex mutex f =
  Stdlib.Mutex.lock mutex;
  match f () with
  | value ->
    Stdlib.Mutex.unlock mutex;
    value
  | exception exn ->
    Stdlib.Mutex.unlock mutex;
    raise exn
;;

let with_lock f = with_mutex state.mutex f

let global_inflight_atomic = Atomic.make 0

let rec try_acquire_global_capacity ~limit =
  let limit = max 1 limit in
  let current = Atomic.get global_inflight_atomic in
  if current >= limit
  then false
  else if Atomic.compare_and_set global_inflight_atomic current (current + 1)
  then true
  else try_acquire_global_capacity ~limit
;;

let rec release_global_capacity () =
  let current = Atomic.get global_inflight_atomic in
  if current <= 0
  then ()
  else if not (Atomic.compare_and_set global_inflight_atomic current (current - 1))
  then release_global_capacity ()
;;

let channel_inflight_locked channel =
  Hashtbl.fold
    (fun _ token count ->
       if String.equal token.channel channel then count + 1 else count)
    state.inflight
    0
;;

let channel_has_capacity_locked ~limit channel =
  channel_inflight_locked channel < channel_limit ~global_limit:limit channel
;;

let available_turns_for_channel_locked ~limit ~channel =
  let limit = max 1 limit in
  let global_available = max 0 (limit - Atomic.get global_inflight_atomic) in
  let channel_available =
    max 0 (channel_limit ~global_limit:limit channel - channel_inflight_locked channel)
  in
  min global_available channel_available
;;

let base_path_opt ?base_path () =
  match base_path with
  | Some path -> Some path
  | None when Env_config_core.running_under_test_executable () -> None
  | None -> (
    try Some (Env_config_core.base_path ()) with
    | _ -> None)
;;

let policy_path ?base_path () =
  match base_path_opt ?base_path () with
  | None -> None
  | Some base_path ->
    Some
      (Filename.concat
         (Filename.concat (Common.masc_dir_from_base_path ~base_path) "keeper")
         "fleet_admission_policy.json")
;;

let option_string_json = function
  | None -> `Null
  | Some value -> `String value
;;

let policy_to_json (policy : fleet_policy) =
  `Assoc
    [ "fleet_state", `String (fleet_state_to_string policy.fleet_state)
    ; "generation", `Int policy.generation
    ; "reason", option_string_json policy.reason
    ; "updated_by", option_string_json policy.updated_by
    ; "updated_at", option_string_json policy.updated_at
    ]
;;

let fleet_state_of_json json =
  match Safe_ops.json_string_opt "fleet_state" json with
  | None -> Ok Running
  | Some raw -> (
    match raw |> String.lowercase_ascii |> fleet_state_of_string with
    | Some fleet_state -> Ok fleet_state
    | None -> Error raw)
;;

let policy_of_json json =
  match fleet_state_of_json json with
  | Error invalid_fleet_state -> Error invalid_fleet_state
  | Ok fleet_state ->
    Ok
      { fleet_state
      ; generation = Safe_ops.json_int ~default:0 "generation" json
      ; reason = Safe_ops.json_string_opt "reason" json
      ; updated_by = Safe_ops.json_string_opt "updated_by" json
      ; updated_at = Safe_ops.json_string_opt "updated_at" json
      }
;;

let read_policy_file ?base_path () =
  match policy_path ?base_path () with
  | None -> None
  | Some path ->
    if not (Sys.file_exists path)
    then None
    else (
      match Workspace_utils.read_json_local_result path with
      | Ok json -> (
        match policy_of_json json with
        | Ok policy -> Some policy
        | Error invalid_fleet_state ->
          Log.Keeper.warn
            "keeper_turn_admission: invalid fleet policy path=%s fleet_state=%s"
            path
            invalid_fleet_state;
          None)
      | Error error ->
        Log.Keeper.warn
          "keeper_turn_admission: failed to read fleet policy path=%s error=%s"
          path
          error;
        None)
;;

let persist_policy ?base_path (policy : fleet_policy) =
  match policy_path ?base_path () with
  | None -> Ok ()
  | Some path -> Workspace_utils.write_json_local path (policy_to_json policy)
;;

let now_string () = Printf.sprintf "%.3f" (Time_compat.now ())

let resolve_decision pending decision =
  if not pending.cancelled
  then
    match Eio.Promise.peek pending.decision_p with
    | None -> Eio.Promise.resolve pending.decision_u decision
    | Some _ -> ()
;;

let request_cancel_token token =
  if Atomic.compare_and_set token.cancel_requested false true
  then (
    match Eio.Promise.peek token.cancel_p with
    | None -> Eio.Promise.resolve token.cancel_u ()
    | Some _ -> ())
;;

let reject_waiters_locked rejection =
  let waiters = state.waiters in
  state.waiters <- [];
  List.iter
    (fun pending ->
       resolve_decision pending (Error rejection);
       pending.cancelled <- true)
    waiters
;;

let grant_locked pending =
  state.next_token <- state.next_token + 1;
  let token_id = state.next_token in
  let cancel_p, cancel_u = Eio.Promise.create () in
  let token =
    { token_id
    ; keeper_name = pending.info.keeper_name
    ; runtime_profile = pending.info.runtime_profile
    ; channel = pending.info.channel
    ; acquired_at = Time_compat.now ()
    ; released = Atomic.make false
    ; cancel_requested = Atomic.make false
    ; cancel_p
    ; cancel_u
    }
  in
  Hashtbl.replace state.inflight token_id token;
  Hashtbl.replace state.active_keepers token.keeper_name token_id;
  resolve_decision pending (Ok token)
;;

let select_eligible_waiter_locked ~limit =
  let rec loop skipped = function
    | [] ->
      state.waiters <- List.rev skipped;
      None
    | pending :: rest when pending.cancelled -> loop skipped rest
    | pending :: rest
      when Hashtbl.mem state.active_keepers pending.info.keeper_name ->
      loop (pending :: skipped) rest
    | pending :: rest when not (channel_has_capacity_locked ~limit pending.info.channel)
      -> loop (pending :: skipped) rest
    | pending :: rest ->
      state.waiters <- List.rev_append skipped rest;
      Some pending
  in
  loop [] state.waiters
;;

let rec schedule_locked ~limit =
  let limit = max 1 limit in
  state.last_limit <- limit;
  match state.policy.fleet_state with
  | Paused | Stopped -> ()
  | Running ->
    if try_acquire_global_capacity ~limit
    then (
      match select_eligible_waiter_locked ~limit with
      | None -> release_global_capacity ()
      | Some pending ->
        grant_locked pending;
        schedule_locked ~limit)
    else ()
;;

let remove_token_locked token =
  Hashtbl.remove state.inflight token.token_id;
  match Hashtbl.find_opt state.active_keepers token.keeper_name with
  | Some active_token_id when active_token_id = token.token_id ->
    Hashtbl.remove state.active_keepers token.keeper_name
  | _ -> ()
;;

let release_turn token =
  if Atomic.compare_and_set token.released false true
  then
    with_lock (fun () ->
      release_global_capacity ();
      remove_token_locked token;
      schedule_locked ~limit:state.last_limit)
;;

let cancel_all_inflight_locked () =
  Hashtbl.iter (fun _ token -> request_cancel_token token) state.inflight
;;

let apply_policy_locked ~limit policy =
  state.policy <- policy;
  match policy.fleet_state with
  | Running -> schedule_locked ~limit
  | Paused -> reject_waiters_locked Fleet_paused
  | Stopped ->
    reject_waiters_locked Fleet_stopped;
    cancel_all_inflight_locked ()
;;

let refresh_policy ?base_path ~limit () =
  match read_policy_file ?base_path () with
  | None -> ()
  | Some file_policy ->
    with_lock (fun () ->
      if file_policy.generation > state.policy.generation
      then apply_policy_locked ~limit file_policy)
;;

let read_policy ?base_path () =
  refresh_policy ?base_path ~limit:state.last_limit ();
  with_lock (fun () -> state.policy)
;;

let update_policy ?base_path ?reason ?updated_by fleet_state =
  refresh_policy ?base_path ~limit:state.last_limit ();
  let policy =
    with_lock (fun () ->
      { fleet_state
      ; generation = state.policy.generation + 1
      ; reason
      ; updated_by
      ; updated_at = Some (now_string ())
      })
  in
  (match persist_policy ?base_path policy with
   | Ok () -> ()
   | Error error ->
     Log.Keeper.warn
       "keeper_turn_admission: failed to persist fleet policy state=%s error=%s"
       (fleet_state_to_string fleet_state)
       error);
  with_lock (fun () ->
    apply_policy_locked ~limit:state.last_limit policy;
    state.policy)
;;

let pause_fleet ?base_path ?reason ?updated_by () =
  update_policy ?base_path ?reason ?updated_by Paused
;;

let resume_fleet ?base_path ?reason ?updated_by () =
  update_policy ?base_path ?reason ?updated_by Running
;;

let stop_fleet ?base_path ?reason ?updated_by () =
  update_policy ?base_path ?reason ?updated_by Stopped
;;

let remove_pending_locked pending =
  pending.cancelled <- true;
  state.waiters
  <- List.filter
       (fun candidate -> candidate.info.ticket <> pending.info.ticket)
       state.waiters
;;

let timeout_pending pending =
  let decision =
    with_lock (fun () ->
      remove_pending_locked pending;
      let decision = Eio.Promise.peek pending.decision_p in
      (match decision with
       | None -> schedule_locked ~limit:state.last_limit
       | Some _ -> ());
      decision)
  in
  match decision with
  | Some (Ok token) ->
    release_turn token;
    Error Global_inflight_exceeded
  | Some (Error rejection) -> Error rejection
  | None -> Error Global_inflight_exceeded
;;

let cleanup_pending_wait_abort pending =
  let decision =
    with_lock (fun () ->
      remove_pending_locked pending;
      let decision = Eio.Promise.peek pending.decision_p in
      (match decision with
       | None -> schedule_locked ~limit:state.last_limit
       | Some _ -> ());
      decision)
  in
  match decision with
  | Some (Ok token) -> release_turn token
  | Some (Error _) | None -> ()
;;

let await_decision ~timeout_s pending =
  match Eio.Promise.peek pending.decision_p with
  | Some decision -> decision
  | None -> (
    match Eio_context.get_clock_opt () with
    | Some clock -> (
      try
        Eio.Time.with_timeout_exn clock timeout_s (fun () ->
          Eio.Promise.await pending.decision_p)
      with
      | Eio.Time.Timeout -> timeout_pending pending
      | exn ->
        cleanup_pending_wait_abort pending;
        raise exn)
    | None ->
      if timeout_s <= 0.0
      then timeout_pending pending
      else (
        let deadline = Time_compat.now () +. timeout_s in
        let rec loop () =
          match Eio.Promise.peek pending.decision_p with
          | Some decision -> decision
          | None when Time_compat.now () >= deadline -> timeout_pending pending
          | None ->
            Eio.Fiber.yield ();
            loop ()
        in
        try loop () with
        | exn ->
          cleanup_pending_wait_abort pending;
          raise exn))
;;

let enqueue_turn_locked ~keeper_name ~runtime_profile ~channel ~started_at =
  state.next_ticket <- state.next_ticket + 1;
  let decision_p, decision_u = Eio.Promise.create () in
  let pending =
    { info =
        { ticket = state.next_ticket
        ; keeper_name
        ; runtime_profile
        ; channel
        ; enqueued_at = started_at
        }
    ; decision_p
    ; decision_u
    ; cancelled = false
    }
  in
  state.waiters <- state.waiters @ [ pending ];
  pending
;;

let wait_ms_since started_at =
  let waited_sec = Time_compat.now () -. started_at in
  int_of_float ((if waited_sec < 0.0 then 0.0 else waited_sec) *. 1000.0)
;;

let active_keepers_locked () =
  Hashtbl.fold (fun keeper_name _ acc -> keeper_name :: acc) state.active_keepers []
  |> List.sort String.compare
;;

let snapshot ?base_path ?(limit = state.last_limit) () =
  let limit = max 1 limit in
  refresh_policy ?base_path ~limit ();
  with_lock (fun () ->
    let global_inflight = Atomic.get global_inflight_atomic in
    { fleet_state = state.policy.fleet_state
    ; global_inflight
    ; global_limit = limit
    ; available = max 0 (limit - global_inflight)
    ; queue_depth = List.length state.waiters
    ; active_keepers = active_keepers_locked ()
    ; waiters = List.map (fun pending -> pending.info) state.waiters
    ; generation = state.policy.generation
    ; reason = state.policy.reason
    ; updated_by = state.policy.updated_by
    ; updated_at = state.policy.updated_at
    })
;;

let semaphore_wait_timeout_snapshot ?(holders = []) () =
  let limit = max 1 effective_turn_throttle_limit in
  let global_inflight = Atomic.get global_inflight_atomic in
  let available = max 0 (limit - global_inflight) in
  let autonomous_available =
    with_lock (fun () ->
      available_turns_for_channel_locked ~limit ~channel:"scheduled_autonomous")
  in
  let reactive_available =
    with_lock (fun () -> available_turns_for_channel_locked ~limit ~channel:"reactive")
  in
  let queue_depth = with_lock (fun () -> List.length state.waiters) in
  { Keeper_turn_slot_types.timeout_wait_sec = semaphore_wait_timeout_sec
  ; timeout_phase = Keeper_turn_slot_types.Turn_slot
  ; timeout_autonomous_available = autonomous_available
  ; timeout_reactive_available = reactive_available
  ; timeout_turn_available = available
  ; timeout_queue_depth = queue_depth
  ; timeout_queue_ahead = None
  ; timeout_holders = holders
  }
;;

let semaphore_wait_seconds_buckets =
  [ 0.001; 0.005; 0.01; 0.025; 0.05; 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0; 30.0; 60.0 ]
;;

let observe_admission_wait_seconds ~keeper_name ~runtime_profile ~channel seconds =
  let seconds = if seconds < 0.0 then 0.0 else seconds in
  let labels =
    [ "keeper_name", keeper_name; "runtime_profile", runtime_profile; "channel", channel ]
  in
  Otel_metric_store.observe_histogram
    Keeper_metrics.(to_string SemaphoreWaitSeconds)
    ~labels
    seconds;
  let inc_bucket le =
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SemaphoreWaitSecondsBucket)
      ~labels:(labels @ [ "le", le ])
      ()
  in
  List.iter
    (fun upper -> if seconds <= upper then inc_bucket (Printf.sprintf "%g" upper))
    semaphore_wait_seconds_buckets;
  inc_bucket "+Inf"
;;

let acquire_turn
      ?base_path
      ~limit
      ~timeout_s
      ~keeper_name
      ~runtime_profile
      ~channel
      ()
  =
  let limit = max 1 limit in
  refresh_policy ?base_path ~limit ();
  let started_at = Time_compat.now () in
  let admission =
    with_lock (fun () ->
      state.last_limit <- limit;
      match state.policy.fleet_state with
      | Paused -> `Decision (Error Fleet_paused)
      | Stopped -> `Decision (Error Fleet_stopped)
      | Running ->
        let pending =
          enqueue_turn_locked ~keeper_name ~runtime_profile ~channel ~started_at
        in
        schedule_locked ~limit;
        (match Eio.Promise.peek pending.decision_p with
         | Some decision -> `Decision decision
         | None -> `Pending pending))
  in
  match admission with
  | `Decision (Ok token) -> Ok (token, wait_ms_since started_at)
  | `Decision (Error rejection) -> Error rejection
  | `Pending pending -> (
    match await_decision ~timeout_s pending with
    | Ok token -> Ok (token, wait_ms_since started_at)
    | Error rejection -> Error rejection)
;;

let eio_scheduler_available () =
  Eio_guard.is_ready ()
  ||
  try
    Eio.Fiber.yield ();
    true
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | _ -> false
;;

let run_with_token ~token ~semaphore_wait_ms f =
  let cleanup () = release_turn token in
  let body () = Ok (f ~semaphore_wait_ms) in
  if eio_scheduler_available ()
  then
    Eio.Switch.run (fun turn_sw ->
      Eio.Switch.on_release turn_sw cleanup;
      Eio.Fiber.fork_daemon ~sw:turn_sw (fun () ->
        Eio.Promise.await token.cancel_p;
        Eio.Switch.fail turn_sw Fleet_stopped_by_operator;
        `Stop_daemon);
      body ())
  else Fun.protect ~finally:cleanup body
;;

let with_turn_admission
      ?base_path
      ?(runtime_profile = "unknown")
      ~keeper_name
      ~channel
      f
  =
  let channel_label = Keeper_world_observation.channel_to_string channel in
  match
    acquire_turn
      ?base_path
      ~limit:effective_turn_throttle_limit
      ~timeout_s:semaphore_wait_timeout_sec
      ~keeper_name
      ~runtime_profile
      ~channel:channel_label
      ()
  with
  | Ok (token, semaphore_wait_ms) ->
    observe_admission_wait_seconds
      ~keeper_name
      ~runtime_profile
      ~channel:channel_label
      (float_of_int semaphore_wait_ms /. 1000.0);
    run_with_token ~token ~semaphore_wait_ms f
  | Error Global_inflight_exceeded ->
    Error (`Semaphore_wait_timeout (semaphore_wait_timeout_snapshot ()))
  | Error (Fleet_paused | Fleet_stopped as rejection) ->
    Error (`Turn_admission_rejected rejection)
;;

let force_release_keeper ~keeper_name =
  let released =
    with_lock (fun () ->
      let matches =
        Hashtbl.fold
          (fun _ token acc ->
             if String.equal token.keeper_name keeper_name then token :: acc else acc)
          state.inflight
          []
      in
      List.iter
        (fun token ->
           if Atomic.compare_and_set token.released false true
           then (
             release_global_capacity ();
             remove_token_locked token;
             request_cancel_token token))
        matches;
      schedule_locked ~limit:state.last_limit;
      matches)
  in
  released <> []
;;

let token_cancel_p token = token.cancel_p
let token_keeper_name token = token.keeper_name
let token_acquired_at token = token.acquired_at
let token_id token = token.token_id

let waiter_json waiter =
  `Assoc
    [ "ticket", `Int waiter.ticket
    ; "keeper_name", `String waiter.keeper_name
    ; "runtime_profile", `String waiter.runtime_profile
    ; "channel", `String waiter.channel
    ; "enqueued_at", `Float waiter.enqueued_at
    ]
;;

let snapshot_json ?base_path ?limit () =
  let snapshot = snapshot ?base_path ?limit () in
  `Assoc
    [ "fleet_state", `String (fleet_state_to_string snapshot.fleet_state)
    ; "global_inflight", `Int snapshot.global_inflight
    ; "global_limit", `Int snapshot.global_limit
    ; "available", `Int snapshot.available
    ; "queue_depth", `Int snapshot.queue_depth
    ; "active_keepers", `List (List.map (fun name -> `String name) snapshot.active_keepers)
    ; "waiters", `List (List.map waiter_json snapshot.waiters)
    ; "generation", `Int snapshot.generation
    ; "reason", option_string_json snapshot.reason
    ; "updated_by", option_string_json snapshot.updated_by
    ; "updated_at", option_string_json snapshot.updated_at
    ]
;;

let global_inflight () =
  Atomic.get global_inflight_atomic
;;

let available_turns ~limit =
  let limit = max 1 limit in
  max 0 (limit - Atomic.get global_inflight_atomic)
;;

let available_turns_for_channel ~limit ~channel =
  with_lock (fun () -> available_turns_for_channel_locked ~limit ~channel)
;;

let reset_for_test () =
  with_lock (fun () ->
    state.policy <- default_policy;
    state.next_ticket <- 0;
    state.next_token <- 0;
    state.last_limit <- 1;
    Hashtbl.reset state.inflight;
    Hashtbl.reset state.active_keepers;
    state.waiters <- []);
  Atomic.set global_inflight_atomic 0
;;
