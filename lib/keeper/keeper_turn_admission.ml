type fleet_state =
  | Running
  | Paused
  | Stopped

type rejection =
  | Fleet_paused
  | Fleet_stopped
  | Global_inflight_exceeded

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

let select_eligible_waiter_locked () =
  let rec loop skipped = function
    | [] ->
      state.waiters <- List.rev skipped;
      None
    | pending :: rest when pending.cancelled -> loop skipped rest
    | pending :: rest
      when Hashtbl.mem state.active_keepers pending.info.keeper_name ->
      loop (pending :: skipped) rest
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
      match select_eligible_waiter_locked () with
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
      | Eio.Time.Timeout -> timeout_pending pending)
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
        loop ()))
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

let legacy_token_counter = Atomic.make 0
let legacy_tokens_mutex = Stdlib.Mutex.create ()
let legacy_tokens : token list ref = ref []

let acquire_global_slot ~limit ~timeout_s () =
  let n = Atomic.fetch_and_add legacy_token_counter 1 in
  match
    acquire_turn
      ~limit
      ~timeout_s
      ~keeper_name:(Printf.sprintf "__legacy_global_slot_%d" n)
      ~runtime_profile:"legacy"
      ~channel:"legacy"
      ()
  with
  | Error rejection -> Error rejection
  | Ok (token, wait_ms) ->
    with_mutex legacy_tokens_mutex (fun () ->
      legacy_tokens := token :: !legacy_tokens);
    Ok wait_ms
;;

let release_global_slot () =
  let token =
    with_mutex legacy_tokens_mutex (fun () ->
      match !legacy_tokens with
      | [] -> None
      | token :: rest ->
        legacy_tokens := rest;
        Some token)
  in
  match token with
  | Some token -> release_turn token
  | None -> Log.Keeper.warn "keeper_turn_admission: legacy release without token"
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
  Atomic.set global_inflight_atomic 0;
  with_mutex legacy_tokens_mutex (fun () ->
    legacy_tokens := []);
  Atomic.set legacy_token_counter 0
;;
