(** Keeper_fd_pressure — FD exhaustion guard.

    The fleet failure mode is not a classic mutex deadlock. Once the
    process reaches EMFILE/ENFILE pressure, unrelated append/read/spawn paths
    all start failing and retries amplify the outage. This module provides a
    low-cardinality circuit breaker that can be tripped from central error
    sites and consulted by turn/spawn scheduling. It checks both the process
    [nofile] budget and, when available, the host kernel's global file-table
    budget because ENFILE can fire while the MASC server's own FD count is
    still low.

    Fleet baseline (2026-05-17): default capacity targets 64 active keepers
    (= 64 * fd_per_active_keeper + fd_headroom). The previous default named
    [MASC_KEEPER_MIN_NOFILE_FOR_24] (= 4096) capped the fleet at ~41 keepers
    under macOS launchctl defaults; ramping to 64-keeper baseline closes that
    gap without changing the admission policy itself. *)

let cooldown_until = Atomic.make 0.0
let last_log_at = Atomic.make 0.0
let nofile_guard_warned = Atomic.make false

(** [nofile_cache] is a 3-state variant rather than [int option option] so
    concurrent first-call fibers can claim the slot via [In_flight] and avoid
    spawning N parallel [/bin/sh -c "ulimit -n"] subprocesses (which would
    themselves consume FDs precisely when we are trying to measure them).
    See [process_nofile_soft_limit] for the single-flight protocol. *)
type nofile_cache =
  | Uninitialized
  | In_flight
  | Resolved of int option

let nofile_soft_limit_cache : nofile_cache Atomic.t = Atomic.make Uninitialized
let nofile_soft_limit_mutex = Stdlib.Mutex.create ()

type system_fd_snapshot =
  { open_files : int
  ; max_files : int
  }

type system_fd_cache_entry =
  { sampled_at : float
  ; snapshot : system_fd_snapshot option
  }

let system_fd_cache : system_fd_cache_entry option Atomic.t = Atomic.make None
let system_fd_mutex = Stdlib.Mutex.create ()

type admission_block =
  | Fd_pressure_cooldown of float
  | Projected_fd_budget_exhausted of
      { soft_limit : int
      ; open_fds : int option
      ; active_keepers : int
      ; starting_keepers : int
      ; projected_fds : int
      }
  | System_fd_budget_exhausted of
      { open_files : int
      ; max_files : int
      ; remaining_files : int
      ; required_headroom : int
      ; projected_fds : int
      ; active_keepers : int
      ; starting_keepers : int
      }

type admission_decision =
  | Admit
  | Block of admission_block

let lowercase s = String.lowercase_ascii s

let contains haystack needle =
  let haystack = lowercase haystack in
  let needle = lowercase needle in
  String_util.contains_substring haystack needle
;;

let is_fd_exhaustion_text detail =
  List.exists
    (contains detail)
    [ "too many open files"
    ; "emfile"
    ; "enfile"
    ; "file descriptor"
    ; "os error 24"
    ; "execve: too many open files"
    ]
;;

let cooldown_sec () =
  Env_config_core.get_float ~default:60.0 "MASC_KEEPER_FD_PRESSURE_COOLDOWN_SEC"
  |> Float.max 5.0
  |> Float.min 600.0
;;

(* [cas_monotonic_max atom new_v] = [if new_v > atom then atom := new_v] but
   safe under concurrent updates. Without CAS, two fibers racing in [note]
   could each read the same [prev], then the larger [until_ts] could be
   clobbered by a smaller subsequent write — shortening cooldown silently.
   Returns [true] iff the slot was actually advanced. *)
let cas_monotonic_max ~(atom : float Atomic.t) (new_v : float) : bool =
  let rec loop () =
    let prev = Atomic.get atom in
    if new_v <= prev
    then false
    else if Atomic.compare_and_set atom prev new_v
    then true
    else loop ()
  in
  loop ()
;;

let note ?(site = "unknown") ?(detail = "") () =
  let now = Time_compat.now () in
  let until_ts = now +. cooldown_sec () in
  let _ : bool = cas_monotonic_max ~atom:cooldown_until until_ts in
  (* Log-throttle (10s window): only the CAS winner emits, so concurrent
     noters can't double-log under storm. *)
  let last = Atomic.get last_log_at in
  if now -. last >= 10.0 && Atomic.compare_and_set last_log_at last now
  then
    Log.Keeper.error
      "fd_pressure: circuit breaker active for %.0fs site=%s detail=%s"
      (max 0.0 (Atomic.get cooldown_until -. now))
      site
      detail
;;

let note_if_fd_exhaustion ?site detail =
  if is_fd_exhaustion_text detail then note ?site ~detail ()
;;

let is_fd_exhaustion_exn = function
  | Unix.Unix_error ((Unix.EMFILE | Unix.ENFILE), _, _) -> true
  | Sys_error msg -> is_fd_exhaustion_text msg
  | exn -> is_fd_exhaustion_text (Printexc.to_string exn)
;;

let note_exception ?site exn =
  if is_fd_exhaustion_exn exn
  then note ?site ~detail:(Printexc.to_string exn) ()
;;

let active ?now () =
  let now = Option.value ~default:(Time_compat.now ()) now in
  Atomic.get cooldown_until > now
;;

let remaining_sec ?now () =
  let now = Option.value ~default:(Time_compat.now ()) now in
  max 0.0 (Atomic.get cooldown_until -. now)
;;

let projection_fields ?now () =
  let degraded = active ?now () in
  [ "degraded", `Bool degraded
  ; "degraded_reason", (if degraded then `String "fd_pressure" else `Null)
  ; "fd_pressure_remaining_sec", `Float (remaining_sec ?now ())
  ]
;;

let degraded_projection_json ?now () = `Assoc (projection_fields ?now ())

let degraded_trust_json ?now () =
  `Assoc
    [ "disposition", `String "Degraded"
    ; "disposition_reason", `String "fd_pressure"
    ; "operator_disposition", `String "blocked_runtime"
    ; "operator_disposition_reason", `String "fd_pressure"
    ; "needs_attention", `Bool true
    ; "attention_reason", `String "fd_pressure"
    ; "next_human_action", `String "restore_fd_headroom"
    ; "approval", `Null
    ; "execution", `Null
    ; "pending_approval_count", `Null
    ; "latest_terminal_reason", `Null
    ; "latest_next_action", `String "restore_fd_headroom"
    ; "latest_causal_event", degraded_projection_json ?now ()
    ]
;;

let reset_for_tests () =
  Atomic.set cooldown_until 0.0;
  Atomic.set last_log_at 0.0;
  Atomic.set nofile_guard_warned false;
  Atomic.set nofile_soft_limit_cache Uninitialized;
  Atomic.set system_fd_cache None
;;

(* Detect the host's nofile soft limit by spawning [sh -c 'ulimit -n']. The
   subprocess itself consumes pipes/FDs, so under fleet startup we must run
   it at most once. Single-flight protocol:
   - Uninitialized → In_flight while holding the process-local mutex.
     The holder runs detection, stores Resolved, and releases waiters.
   - Resolved cached → return immediately.
   Stdlib.Mutex is intentional here: this helper can run before an Eio context
   exists, and the protected section is a one-shot host-limit probe. *)
let detect_nofile_soft_limit_now () =
  (* RFC-0106 P1: one-shot host-limit probe; silent _ -> None is the
     pre-existing fallback when ulimit is unavailable.  Cancelled
     re-raise centralised via Cancel_safe.protect. *)
  Cancel_safe.protect
    ~on_exn:(fun _ -> None)
    (fun () ->
      let lines, status =
        With_process.with_process_args_in
          "/bin/sh"
          [| "sh"; "-c"; "ulimit -n" |]
          With_process.drain_lines
      in
      match status, lines with
      | Unix.WEXITED 0, line :: _ -> int_of_string_opt (String.trim line)
      | _ -> None)
;;

let process_nofile_soft_limit () =
  match Atomic.get nofile_soft_limit_cache with
  | Resolved cached -> cached
  | _ ->
    Stdlib.Mutex.lock nofile_soft_limit_mutex;
    Fun.protect
      ~finally:(fun () -> Stdlib.Mutex.unlock nofile_soft_limit_mutex)
      (fun () ->
        match Atomic.get nofile_soft_limit_cache with
        | Resolved cached -> cached
        | Uninitialized | In_flight ->
          Atomic.set nofile_soft_limit_cache In_flight;
          (try
             let detected = detect_nofile_soft_limit_now () in
             Atomic.set nofile_soft_limit_cache (Resolved detected);
             detected
           with
           | Eio.Cancel.Cancelled _ as exn ->
             Atomic.set nofile_soft_limit_cache Uninitialized;
             raise exn))
;;

let process_open_fd_count () =
  let count_dir path =
    try Some (Array.length (Sys.readdir path)) with
    | Sys_error _ | Unix.Unix_error _ -> None
  in
  match count_dir "/dev/fd" with
  | Some _ as count -> count
  | None -> count_dir "/proc/self/fd"
;;

let parse_system_fd_snapshot lines =
  match List.filter_map (fun line -> int_of_string_opt (String.trim line)) lines with
  | open_files :: max_files :: _ when open_files >= 0 && max_files > 0 ->
    Some { open_files; max_files }
  | _ -> None
;;

let read_first_line path =
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> Some (input_line ic))
  with
  | Sys_error _ | Unix.Unix_error _ | End_of_file -> None
;;

let detect_linux_system_fd_snapshot_now () =
  match read_first_line "/proc/sys/fs/file-nr" with
  | Some line ->
    let normalized =
      String.map (function
        | '\t' | '\r' | '\n' -> ' '
        | c -> c)
        line
    in
    (match
       String.split_on_char ' ' normalized
       |> List.filter_map (fun field ->
         if String.equal field "" then None else int_of_string_opt field)
     with
     | open_files :: _unused_files :: max_files :: _ when open_files >= 0 && max_files > 0 ->
       Some { open_files; max_files }
     | _ -> None)
  | None -> None
;;

let detect_darwin_system_fd_snapshot_now () =
  if not (Sys.file_exists "/System/Library/CoreServices/SystemVersion.plist")
  then None
  else
    (* RFC-0106 P1: darwin-only sysctl probe; silent _ -> None preserved. *)
    Cancel_safe.protect
      ~on_exn:(fun _ -> None)
      (fun () ->
        let lines, status =
          With_process.with_process_args_in
            "/usr/sbin/sysctl"
            [| "sysctl"; "-n"; "kern.num_files"; "kern.maxfiles" |]
            With_process.drain_lines
        in
        match status with
        | Unix.WEXITED 0 -> parse_system_fd_snapshot lines
        | _ -> None)
;;

let detect_system_fd_snapshot_now () =
  match detect_linux_system_fd_snapshot_now () with
  | Some _ as snapshot -> snapshot
  | None -> detect_darwin_system_fd_snapshot_now ()
;;

let system_fd_probe_ttl_sec () =
  Env_config_core.get_float ~default:2.0 "MASC_KEEPER_SYSTEM_FD_PROBE_TTL_SEC"
  |> Float.max 0.25
  |> Float.min 30.0
;;

let system_fd_snapshot ?now () =
  let now = Option.value ~default:(Time_compat.now ()) now in
  let fresh = function
    | Some { sampled_at; snapshot } when now -. sampled_at <= system_fd_probe_ttl_sec () ->
      Some snapshot
    | _ -> None
  in
  match fresh (Atomic.get system_fd_cache) with
  | Some snapshot -> snapshot
  | None ->
    Stdlib.Mutex.lock system_fd_mutex;
    Fun.protect
      ~finally:(fun () -> Stdlib.Mutex.unlock system_fd_mutex)
      (fun () ->
        match fresh (Atomic.get system_fd_cache) with
        | Some snapshot -> snapshot
        | None ->
          let snapshot = detect_system_fd_snapshot_now () in
          Atomic.set system_fd_cache (Some { sampled_at = now; snapshot });
          snapshot)
;;

(* Fleet baseline (renamed 2026-05-17 from min_nofile_for_24_keepers).
   Default targets 64 active keepers: 64 * fd_per_active_keeper (96)
   + fd_headroom (128) ≈ 6272; with 2x margin → 12288. The legacy env name
   [MASC_KEEPER_MIN_NOFILE_FOR_24] is still honored for operators who set it
   pre-rename, but FLEET takes precedence and the legacy var only applies
   when FLEET is absent. *)
let min_nofile_for_fleet () =
  let fleet_default = 12288 in
  let from_fleet =
    Env_config_core.get_int ~default:0 "MASC_KEEPER_MIN_NOFILE_FOR_FLEET"
  in
  let resolved =
    if from_fleet > 0
    then from_fleet
    else (
      let legacy =
        Env_config_core.get_int ~default:0 "MASC_KEEPER_MIN_NOFILE_FOR_24"
      in
      if legacy > 0 then legacy else fleet_default)
  in
  max 256 resolved
;;

(* Compat alias preserved for any out-of-tree callers; do not add new uses. *)
let min_nofile_for_24_keepers = min_nofile_for_fleet

let fd_headroom () =
  Env_config_core.get_int ~default:128 "MASC_KEEPER_FD_HEADROOM"
  |> max 32
;;

let fd_per_active_keeper () =
  Env_config_core.get_int ~default:96 "MASC_KEEPER_FD_PER_ACTIVE_KEEPER"
  |> max 16
;;

let system_fd_headroom () =
  Env_config_core.get_int ~default:8192 "MASC_KEEPER_SYSTEM_FD_HEADROOM"
  |> max (fd_headroom ())
;;

let active_keeper_cap_for_soft_limit soft =
  let usable = max 0 (soft - fd_headroom ()) in
  max 1 (usable / fd_per_active_keeper ())
;;

let projected_fd_budget
  ?open_fds
  ~active_keepers
  ~starting_keepers
  ()
  =
  let active_keepers = max 0 active_keepers in
  let starting_keepers = max 0 starting_keepers in
  let fleet_projected =
    fd_headroom () + ((active_keepers + starting_keepers) * fd_per_active_keeper ())
  in
  match open_fds with
  | None -> fleet_projected
  | Some open_fds ->
    max fleet_projected (max 0 open_fds + fd_headroom () + (starting_keepers * fd_per_active_keeper ()))
;;

let system_fd_budget_block system_fds ~projected_fds ~active_keepers ~starting_keepers =
  match system_fds with
  | Some { open_files; max_files } ->
    let remaining_files = max 0 (max_files - open_files) in
    let required_headroom = system_fd_headroom () in
    if remaining_files < required_headroom + projected_fds
    then
      Some
        (System_fd_budget_exhausted
           { open_files
           ; max_files
           ; remaining_files
           ; required_headroom
           ; projected_fds
           ; active_keepers = max 0 active_keepers
           ; starting_keepers = max 0 starting_keepers
           })
    else None
  | None -> None
;;

let admission_decision
  ?(soft_limit = process_nofile_soft_limit ())
  ?(open_fds = process_open_fd_count ())
  ?(system_fds = system_fd_snapshot ())
  ~active_keepers
  ~starting_keepers
  ()
  =
  if active ()
  then Block (Fd_pressure_cooldown (remaining_sec ()))
  else (
    let projected_fds =
      projected_fd_budget ?open_fds ~active_keepers ~starting_keepers ()
    in
    match soft_limit with
    | Some soft_limit when soft_limit > 0 ->
      if projected_fds > soft_limit
      then
        Block
          (Projected_fd_budget_exhausted
             { soft_limit
             ; open_fds
             ; active_keepers = max 0 active_keepers
             ; starting_keepers = max 0 starting_keepers
             ; projected_fds
             })
      else
        (match
           system_fd_budget_block system_fds ~projected_fds ~active_keepers
             ~starting_keepers
         with
         | Some block -> Block block
         | None -> Admit)
    | _ ->
      (match
         system_fd_budget_block system_fds ~projected_fds ~active_keepers
           ~starting_keepers
       with
       | Some block -> Block block
       | None -> Admit))
;;

let admitted = function
  | Admit -> true
  | Block _ -> false
;;

let option_int_json = function
  | Some value -> `Int value
  | None -> `Null
;;

let admission_block_to_json = function
  | Fd_pressure_cooldown remaining_sec ->
    `Assoc
      [ "kind", `String "fd_pressure_cooldown"
      ; "remaining_sec", `Float remaining_sec
      ]
  | Projected_fd_budget_exhausted
      { soft_limit; open_fds; active_keepers; starting_keepers; projected_fds } ->
    `Assoc
      [ "kind", `String "projected_fd_budget_exhausted"
      ; "soft_limit", `Int soft_limit
      ; "open_fds", option_int_json open_fds
      ; "active_keepers", `Int active_keepers
      ; "starting_keepers", `Int starting_keepers
      ; "projected_fds", `Int projected_fds
      ]
  | System_fd_budget_exhausted
      { open_files
      ; max_files
      ; remaining_files
      ; required_headroom
      ; projected_fds
      ; active_keepers
      ; starting_keepers
      } ->
    `Assoc
      [ "kind", `String "system_fd_budget_exhausted"
      ; "system_open_files", `Int open_files
      ; "system_max_files", `Int max_files
      ; "system_fd_remaining", `Int remaining_files
      ; "system_fd_headroom", `Int required_headroom
      ; "projected_fds", `Int projected_fds
      ; "active_keepers", `Int active_keepers
      ; "starting_keepers", `Int starting_keepers
      ]
;;

let admission_decision_to_json = function
  | Admit -> `Assoc [ "status", `String "admit"; "block", `Null ]
  | Block block ->
    `Assoc [ "status", `String "block"; "block", admission_block_to_json block ]
;;

let admission_block_kind = function
  | Fd_pressure_cooldown _ -> "fd_pressure_cooldown"
  | Projected_fd_budget_exhausted _ -> "projected_fd_budget_exhausted"
  | System_fd_budget_exhausted _ -> "system_fd_budget_exhausted"
;;

let runtime_state_json ?(soft_limit = process_nofile_soft_limit ())
    ?(open_fds = process_open_fd_count ()) ?(system_fds = system_fd_snapshot ())
    ~active_keepers ~starting_keepers ~requested_keepers () =
  let active_keepers = max 0 active_keepers in
  let starting_keepers = max 0 starting_keepers in
  let requested_keepers = max 0 requested_keepers in
  let target_keeper_count = max requested_keepers (active_keepers + starting_keepers) in
  let projected_starting_keepers =
    max starting_keepers (target_keeper_count - active_keepers)
  in
  let projected_fds =
    projected_fd_budget ?open_fds ~active_keepers
      ~starting_keepers:projected_starting_keepers ()
  in
  let admission_decision =
    admission_decision ~soft_limit ~open_fds ~system_fds ~active_keepers
      ~starting_keepers:projected_starting_keepers ()
  in
  let admission_blocked = not (admitted admission_decision) in
  let status, reason =
    match admission_decision with
    | Admit -> "ok", `Null
    | Block block -> "blocked", `String (admission_block_kind block)
  in
  let active_keeper_cap =
    match soft_limit with
    | Some soft when soft > 0 -> `Int (active_keeper_cap_for_soft_limit soft)
    | _ -> `Null
  in
  let system_open_files, system_max_files, system_fd_remaining, system_fd_utilization =
    match system_fds with
    | Some { open_files; max_files } ->
      ( `Int open_files
      , `Int max_files
      , `Int (max 0 (max_files - open_files))
      , `Float (float_of_int open_files /. float_of_int max_files) )
    | None -> `Null, `Null, `Null, `Null
  in
  `Assoc
    [ "status", `String status
    ; "reason", reason
    ; "degraded", `Bool (active ())
    ; "fd_pressure_remaining_sec", `Float (remaining_sec ())
    ; "soft_limit", option_int_json soft_limit
    ; "open_fds", option_int_json open_fds
    ; "system_open_files", system_open_files
    ; "system_max_files", system_max_files
    ; "system_fd_remaining", system_fd_remaining
    ; "system_fd_utilization", system_fd_utilization
    ; "system_fd_headroom", `Int (system_fd_headroom ())
    ; "system_fd_probe_supported", `Bool (Option.is_some system_fds)
    ; "headroom", `Int (fd_headroom ())
    ; "fd_per_active_keeper", `Int (fd_per_active_keeper ())
    ; "min_nofile_for_24_keepers", `Int (min_nofile_for_24_keepers ())
    ; "requested_keepers", `Int requested_keepers
    ; "target_keeper_count", `Int target_keeper_count
    ; "active_keepers", `Int active_keepers
    ; "starting_keepers", `Int starting_keepers
    ; "projected_starting_keepers", `Int projected_starting_keepers
    ; "projected_fds", `Int projected_fds
    ; "active_keeper_cap", active_keeper_cap
    ; "admission_decision", admission_decision_to_json admission_decision
    ; "admission_blocked", `Bool admission_blocked
    ; ( "admission_blocked_keepers"
      , if admission_blocked then `Int requested_keepers else `Null )
    ; "operator_action_required", `Bool admission_blocked
    ]
;;

let admit_start ?soft_limit ?open_fds ?system_fds ~active_keepers ~starting_keepers () =
  admitted
    (admission_decision
       ?soft_limit
       ?open_fds
       ?system_fds
       ~active_keepers
       ~starting_keepers
       ())
;;

let admit_turn ?soft_limit ?open_fds ?system_fds ~active_keepers () =
  admit_start ?soft_limit ?open_fds ?system_fds ~active_keepers ~starting_keepers:0 ()
;;

let cap_active_keepers_for_nofile ?(soft_limit = process_nofile_soft_limit ()) requested =
  match soft_limit with
  | Some soft when soft > 0 && soft < min_nofile_for_fleet () ->
    let soft_cap = active_keeper_cap_for_soft_limit soft in
    let cap = if requested <= 0 then soft_cap else min requested soft_cap in
    if (requested <= 0 || cap < requested)
       && Atomic.compare_and_set nofile_guard_warned false true
    then
      Log.Keeper.error
        "fd_pressure: process nofile soft limit %d is below fleet floor %d \
         (64-keeper baseline); reducing active keeper cap from %d to %d. \
         Raise launchctl maxfiles or set MASC_KEEPER_MIN_NOFILE_FOR_FLEET \
         to match your fleet size."
        soft
        (min_nofile_for_fleet ())
        requested
        cap;
    cap
  | _ -> requested
;;
