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
  ; cancel_p : unit Eio.Promise.t
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
  else Keeper_turn_admission_types.int_of_env_default ~primary:name ~default ~min_v ~max_v
;;

module Lease_id = struct
  type t = int

  let compare = Int.compare
end

module Lease_map = Map.Make (Lease_id)

type lease_metadata =
  { lease_keeper_name : string
  ; lease_runtime_profile : string
  ; lease_channel : string
  ; lease_acquired_at : float
  ; lease_cancel_p : unit Eio.Promise.t
  ; lease_cancel_resolver : unit Eio.Promise.u
  }

type runtime_state =
  { policy : fleet_policy
  ; runtime_limit : int
  ; active_leases : lease_metadata Lease_map.t
  ; next_lease_id : int
  }

let default_runtime_state =
  { policy = default_policy
  ; runtime_limit = 1
  ; active_leases = Lease_map.empty
  ; next_lease_id = 0
  }
;;

let current = Atomic.make default_runtime_state

let rec transition f =
  let before = Atomic.get current in
  let after, result = f before in
  if Atomic.compare_and_set current before after then result else transition f
;;

let runtime_inflight state = Lease_map.cardinal state.active_leases

let current_inflight () =
  runtime_inflight (Atomic.get current)
;;

let available_turns_in_state ~limit state =
  let limit = max 1 limit in
  max 0 (limit - runtime_inflight state)
;;

let available_turns_for_channel_in_state ~limit ~channel:_ state =
  available_turns_in_state ~limit state
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

let token_of_lease token_id (metadata : lease_metadata) =
  { token_id
  ; keeper_name = metadata.lease_keeper_name
  ; runtime_profile = metadata.lease_runtime_profile
  ; channel = metadata.lease_channel
  ; acquired_at = metadata.lease_acquired_at
  ; cancel_p = metadata.lease_cancel_p
  }
;;

let refresh_policy ?base_path ~limit () =
  let limit = max 1 limit in
  let file_policy = read_policy_file ?base_path () in
  transition (fun state ->
    let policy =
      match file_policy with
      | Some policy when policy.generation > state.policy.generation -> policy
      | _ -> state.policy
    in
    { state with policy; runtime_limit = limit }, ())
;;

let read_policy ?base_path () =
  let limit = (Atomic.get current).runtime_limit in
  refresh_policy ?base_path ~limit ();
  (Atomic.get current).policy
;;

let update_policy ?base_path ?reason ?updated_by fleet_state =
  let limit = (Atomic.get current).runtime_limit in
  refresh_policy ?base_path ~limit ();
  let policy =
    transition (fun state ->
      let policy =
        { fleet_state
        ; generation = state.policy.generation + 1
        ; reason
        ; updated_by
        ; updated_at = Some (now_string ())
        }
      in
      { state with policy }, policy)
  in
  (match persist_policy ?base_path policy with
   | Ok () -> ()
   | Error error ->
     Log.Keeper.warn
       "keeper_turn_admission: failed to persist fleet policy state=%s error=%s"
       (fleet_state_to_string fleet_state)
       error);
  policy
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

let wait_ms_since started_at =
  let waited_sec = Time_compat.now () -. started_at in
  int_of_float ((if waited_sec < 0.0 then 0.0 else waited_sec) *. 1000.0)
;;

let snapshot ?base_path ?(limit = (Atomic.get current).runtime_limit) () =
  let limit = max 1 limit in
  refresh_policy ?base_path ~limit ();
  let state = Atomic.get current in
  let global_inflight = runtime_inflight state in
  { fleet_state = state.policy.fleet_state
  ; global_inflight
  ; global_limit = limit
  ; available = available_turns_in_state ~limit state
  ; queue_depth = 0
  ; active_keepers = []
  ; waiters = []
  ; generation = state.policy.generation
  ; reason = state.policy.reason
  ; updated_by = state.policy.updated_by
  ; updated_at = state.policy.updated_at
  }
;;

let semaphore_wait_timeout_snapshot ?(holders = []) () =
  let limit = max 1 effective_turn_throttle_limit in
  let state = Atomic.get current in
  let available = available_turns_in_state ~limit state in
  { Keeper_turn_admission_types.timeout_wait_sec = semaphore_wait_timeout_sec
  ; timeout_phase = Keeper_turn_admission_types.Global_admission
  ; timeout_autonomous_available =
      available_turns_for_channel_in_state ~limit ~channel:"scheduled_autonomous" state
  ; timeout_reactive_available =
      available_turns_for_channel_in_state ~limit ~channel:"reactive" state
  ; timeout_turn_available = available
  ; timeout_queue_depth = 0
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
      ~timeout_s:_
      ~keeper_name
      ~runtime_profile
      ~channel
      ()
  =
  let limit = max 1 limit in
  refresh_policy ?base_path ~limit ();
  let started_at = Time_compat.now () in
  transition (fun state ->
    let state = { state with runtime_limit = limit } in
    match state.policy.fleet_state with
    | Paused -> state, Error Fleet_paused
    | Stopped -> state, Error Fleet_stopped
    | Running ->
      if runtime_inflight state >= limit
      then state, Error Global_inflight_exceeded
      else
        let token_id = state.next_lease_id + 1 in
        let cancel_p, cancel_resolver = Eio.Promise.create () in
        let metadata =
          { lease_keeper_name = keeper_name
          ; lease_runtime_profile = runtime_profile
          ; lease_channel = channel
          ; lease_acquired_at = Time_compat.now ()
          ; lease_cancel_p = cancel_p
          ; lease_cancel_resolver = cancel_resolver
          }
        in
        ( { state with
            active_leases = Lease_map.add token_id metadata state.active_leases
          ; next_lease_id = token_id
          }
        , Ok (token_of_lease token_id metadata, wait_ms_since started_at) ))
;;

let release_turn token =
  transition (fun state ->
    { state with active_leases = Lease_map.remove token.token_id state.active_leases }, ())
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
  let released, cancel_resolvers =
    transition (fun state ->
      let matching =
        Lease_map.filter
          (fun _ metadata ->
             String.equal metadata.lease_keeper_name keeper_name)
          state.active_leases
      in
      let resolvers =
        Lease_map.fold
          (fun _ metadata acc -> metadata.lease_cancel_resolver :: acc)
          matching []
      in
      let active_leases =
        Lease_map.filter
          (fun _ metadata ->
             not (String.equal metadata.lease_keeper_name keeper_name))
          state.active_leases
      in
      let released = Lease_map.cardinal active_leases <> Lease_map.cardinal state.active_leases in
      { state with active_leases }, (released, resolvers))
  in
  List.iter (fun r -> Eio.Promise.resolve r ()) cancel_resolvers;
  released
;;

let token_cancel_p token = token.cancel_p
let token_keeper_name token = token.keeper_name
let token_acquired_at token = token.acquired_at
let token_id token = token.token_id

let snapshot_json ?base_path ?limit () =
  let snapshot = snapshot ?base_path ?limit () in
  `Assoc
    [ "fleet_state", `String (fleet_state_to_string snapshot.fleet_state)
    ; "global_inflight", `Int snapshot.global_inflight
    ; "global_limit", `Int snapshot.global_limit
    ; "available", `Int snapshot.available
    ; "queue_depth", `Int snapshot.queue_depth
    ; "active_keepers", `List (List.map (fun name -> `String name) snapshot.active_keepers)
    ; "waiters", `List []
    ; "generation", `Int snapshot.generation
    ; "reason", option_string_json snapshot.reason
    ; "updated_by", option_string_json snapshot.updated_by
    ; "updated_at", option_string_json snapshot.updated_at
    ]
;;

let global_inflight () =
  current_inflight ()
;;

let available_turns ~limit =
  let limit = max 1 limit in
  available_turns_in_state ~limit (Atomic.get current)
;;

let available_turns_for_channel ~limit ~channel =
  available_turns_for_channel_in_state ~limit ~channel (Atomic.get current)
;;

let reset_for_test () =
  Atomic.set current default_runtime_state
;;
