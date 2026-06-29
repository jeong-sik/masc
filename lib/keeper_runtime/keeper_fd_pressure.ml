(** Keeper_fd_pressure — FD exhaustion guard.

    The fleet failure mode is not a classic mutex deadlock. Once the
    process reaches EMFILE/ENFILE pressure, unrelated append/read/spawn paths
    all start failing and retries amplify the outage. This module provides a
    low-cardinality circuit breaker that can be tripped from central error
    sites and consulted by turn/spawn scheduling. It checks both the process
    [nofile] budget and, when available, the host kernel's global file-table
    budget when available because ENFILE can fire while the MASC server's own
    FD count is still low. System probe failures remain telemetry-only: a
    sandbox or restricted host must not block keeper launches after the direct
    process nofile budget has passed.

    Fleet baseline (2026-05-17): default capacity targets 64 active keepers
    (= 64 * fd_per_active_keeper + fd_headroom). The fleet knob is
    [MASC_KEEPER_MIN_NOFILE_FOR_FLEET]. *)

let cooldown_until = Atomic.make 0.0
let last_log_at = Atomic.make 0.0
let nofile_guard_warned = Atomic.make false

(** [nofile_cache] is a 3-state variant rather than [int option option] so
    concurrent first-call fibers can claim the slot via [In_flight] and avoid
    repeatedly probing the host FD limit precisely when pressure is already
    possible.
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
  ; max_files_per_process : int option
  }

type system_fd_cache_entry =
  { sampled_at : float
  ; snapshot : system_fd_snapshot option
  }

let system_fd_cache : system_fd_cache_entry option Atomic.t = Atomic.make None

type admission_block =
  | Fd_pressure_cooldown of float
  | Probe_unknown of
      { probe : string
      ; active_keepers : int
      ; starting_keepers : int
      ; projected_fds : int
      }
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
  | Host_fd_hotspot_budget_exhausted of
      { open_files : int
      ; max_files_per_process : int
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

(* RFC-0154 PR-2: substring vocabulary lives in
   [System_error_class.classify_string] now.  Local [contains] /
   [lowercase] helpers remain for other call sites in this module.

   Wrapper preserved for external callers; mirrors the previous boolean
   semantics by checking the typed classification result. *)
let is_fd_exhaustion_text detail =
  match System_error_class.classify_string detail with
  | System_error_class.Fd_exhaustion -> true
  | System_error_class.Disk_exhaustion
  | System_error_class.Permission_denied
  | System_error_class.Connection_refused
  | System_error_class.Timeout
  | System_error_class.Other _ -> false
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

(* RFC-0137: host-external FD pressure → cooldown trip.

   [Keeper_fd_pressure.note] is reactive — it fires only when an internal
   call site hits EMFILE/ENFILE. That misses the slow-burn case where the
   *host* kernel FD table accumulates against [kern.maxfiles] from an
   adjacent process (Apple Virtualization VM XPC under Docker Desktop)
   while masc's own [nofile] budget stays comfortable.

   The out-of-process sysmon daemon emits a JSON state file on WARN/CRIT
   thresholds; [Host_fd_pressure_poller] (PR-2) reads the configured path on a
   1s cadence and invokes [engage_external].

   Monotonic guarantee: stale [ts] produces a smaller [until_ts] than
   the current [cooldown_until], so [cas_monotonic_max] rejects it — no
   separate last_external_ts atomic needed. *)
type external_level =
  | External_warn
  | External_crit

let string_of_external_level = function
  | External_warn -> "warn"
  | External_crit -> "crit"
;;

let external_cooldown_sec_of level =
  let default_sec, env_var =
    match level with
    | External_warn -> 600.0, "MASC_HOST_PRESSURE_COOLDOWN_WARN_SEC"
    | External_crit -> 1800.0, "MASC_HOST_PRESSURE_COOLDOWN_CRIT_SEC"
  in
  Env_config_core.get_float ~default:default_sec env_var
  |> Float.max 5.0
  |> Float.min Masc_time_constants.hour
;;

let engage_external ~reason ~level ~ts () =
  let cooldown = external_cooldown_sec_of level in
  let until_ts = ts +. cooldown in
  let advanced = cas_monotonic_max ~atom:cooldown_until until_ts in
  if advanced
  then begin
    let now = Time_compat.now () in
    let last = Atomic.get last_log_at in
    if now -. last >= 10.0 && Atomic.compare_and_set last_log_at last now
    then
      Log.Keeper.error
        "fd_pressure: external engage level=%s cooldown=%.0fs reason=%s"
        (string_of_external_level level)
        cooldown
        reason
  end
;;

let reset_for_tests () =
  Atomic.set cooldown_until 0.0;
  Atomic.set last_log_at 0.0;
  Atomic.set nofile_guard_warned false;
  Atomic.set nofile_soft_limit_cache Uninitialized;
  Atomic.set system_fd_cache None
;;

external native_nofile_soft_limit : unit -> int option = "masc_nofile_soft_limit"

(* Detect the host's nofile soft limit with a direct [getrlimit(RLIMIT_NOFILE)]
   stub. This is intentionally not a shell probe: spawning a process just to
   measure FD headroom consumes the scarce resource that this guard protects.
   Single-flight protocol:
   - Uninitialized → In_flight while holding the process-local mutex.
     The holder runs detection, stores Resolved, and releases waiters.
   - Resolved cached → return immediately.
   Stdlib.Mutex is intentional here: this helper can run before an Eio context
   exists, and the protected section is a one-shot host-limit probe. *)
let detect_nofile_soft_limit_now () =
  (* Native probe failures remain telemetry-neutral. Sandboxed or unusual
     hosts should fall back to the existing probe_unknown admission path. *)
  Cancel_safe.protect
    ~on_exn:(fun _ -> None)
    native_nofile_soft_limit
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
  | open_files :: max_files :: max_files_per_process :: _
    when open_files >= 0 && max_files > 0 && max_files_per_process > 0 ->
    Some { open_files; max_files; max_files_per_process = Some max_files_per_process }
  | open_files :: max_files :: _ when open_files >= 0 && max_files > 0 ->
    Some { open_files; max_files; max_files_per_process = None }
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
       Some { open_files; max_files; max_files_per_process = None }
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
            [| "sysctl"; "-n"; "kern.num_files"; "kern.maxfiles"; "kern.maxfilesperproc" |]
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

(* The detect spawns a [sysctl] subprocess on darwin and does a blocking
   [input_line] drain. Run it via [Eio_guard.run_in_systhread] so the blocking
   read does not freeze the owning Eio domain's event-loop thread; the guard
   falls back to a direct call before [Eio_guard.enable ()] (unit tests / init).

   No mutex around the detect: [system_fd_cache] is an [Atomic], and the probe is
   an idempotent read-only [sysctl] read, so concurrent duplicate detects are
   harmless (last-write-wins). A [Stdlib.Mutex] held across the systhread offload
   would be held across a yield (the installed [With_process] guard acquires an
   [Eio.Semaphore]; see fd_accountant.ml install_with_process_sandbox_exec_guard),
   which is a defect on OCaml 5.x. Contrast [process_nofile_soft_limit]: its detect
   is a non-yielding native [getrlimit] stub, so its Stdlib.Mutex stays. *)
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
    let snapshot =
      Eio_guard.run_in_systhread (fun () -> detect_system_fd_snapshot_now ())
    in
    Atomic.set system_fd_cache (Some { sampled_at = now; snapshot });
    snapshot
;;

(* Fleet baseline. Default targets 64 active keepers:
   64 * fd_per_active_keeper (96) + fd_headroom (128) ≈ 6272;
   with 2x margin → 12288. *)
let min_nofile_for_fleet () =
  let fleet_default = 12288 in
  let from_fleet =
    Env_config_core.get_int ~default:0 "MASC_KEEPER_MIN_NOFILE_FOR_FLEET"
  in
  let resolved = if from_fleet > 0 then from_fleet else fleet_default in
  max 256 resolved
;;

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

let host_fd_hotspot_headroom () =
  Env_config_core.get_int ~default:0 "MASC_KEEPER_HOST_FD_HOTSPOT_HEADROOM" |> max 0
;;

let host_fd_hotspot_blocking_enabled () = host_fd_hotspot_headroom () > 0
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
  | Some { open_files; max_files; max_files_per_process } ->
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
    else (
      match max_files_per_process with
      | Some max_files_per_process when max_files_per_process > 0 ->
        let remaining_files = max 0 (max_files_per_process - open_files) in
        let required_headroom = host_fd_hotspot_headroom () in
        if required_headroom > 0 && remaining_files < required_headroom + projected_fds
        then
          Some
            (Host_fd_hotspot_budget_exhausted
               { open_files
               ; max_files_per_process
               ; remaining_files
               ; required_headroom
               ; projected_fds
               ; active_keepers = max 0 active_keepers
               ; starting_keepers = max 0 starting_keepers
               })
        else None
      | _ -> None)
  | None -> None
;;

let probe_unknown_block ~probe ~projected_fds ~active_keepers ~starting_keepers =
  Block
    (Probe_unknown
       { probe
       ; active_keepers = max 0 active_keepers
       ; starting_keepers = max 0 starting_keepers
       ; projected_fds
       })
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
      if Option.is_none open_fds
      then
        probe_unknown_block
          ~probe:"process_open_fds"
          ~projected_fds
          ~active_keepers
          ~starting_keepers
      else if projected_fds > soft_limit
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
        (match system_fds with
         | None -> Admit
         | Some _ ->
           (match
              system_fd_budget_block system_fds ~projected_fds ~active_keepers
                ~starting_keepers
            with
            | Some block -> Block block
            | None -> Admit))
    | _ ->
      probe_unknown_block
        ~probe:"process_nofile_soft_limit"
        ~projected_fds
        ~active_keepers
        ~starting_keepers)
;;

let admitted = function
  | Admit -> true
  | Block _ -> false
;;


let admission_block_to_json = function
  | Fd_pressure_cooldown remaining_sec ->
    `Assoc
      [ "kind", `String "fd_pressure_cooldown"
      ; "remaining_sec", `Float remaining_sec
      ]
  | Probe_unknown { probe; active_keepers; starting_keepers; projected_fds } ->
    `Assoc
      [ "kind", `String (probe ^ "_probe_unknown")
      ; "probe", `String probe
      ; "active_keepers", `Int active_keepers
      ; "starting_keepers", `Int starting_keepers
      ; "projected_fds", `Int projected_fds
      ]
  | Projected_fd_budget_exhausted
      { soft_limit; open_fds; active_keepers; starting_keepers; projected_fds } ->
    `Assoc
      [ "kind", `String "projected_fd_budget_exhausted"
      ; "soft_limit", `Int soft_limit
      ; "open_fds", Json_util.int_option_to_yojson open_fds
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
  | Host_fd_hotspot_budget_exhausted
      { open_files
      ; max_files_per_process
      ; remaining_files
      ; required_headroom
      ; projected_fds
      ; active_keepers
      ; starting_keepers
      } ->
    `Assoc
      [ "kind", `String "host_fd_hotspot_budget_exhausted"
      ; "system_open_files", `Int open_files
      ; "system_max_files_per_process", `Int max_files_per_process
      ; "host_fd_hotspot_remaining", `Int remaining_files
      ; "host_fd_hotspot_headroom", `Int required_headroom
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
  | Probe_unknown { probe; _ } -> probe ^ "_probe_unknown"
  | Projected_fd_budget_exhausted _ -> "projected_fd_budget_exhausted"
  | System_fd_budget_exhausted _ -> "system_fd_budget_exhausted"
  | Host_fd_hotspot_budget_exhausted _ -> "host_fd_hotspot_budget_exhausted"
;;

(* Human-readable one-line summary carrying the typed numbers (no re-probe).
   Used by the fleet admission observer's edge WARN — mirrors
   [Keeper_disk_pressure.admission_block_summary]. *)
let admission_block_summary = function
  | Fd_pressure_cooldown remaining_sec ->
    Printf.sprintf "fd pressure cooldown (remaining=%.0fs)" remaining_sec
  | Probe_unknown { probe; projected_fds; active_keepers; _ } ->
    Printf.sprintf
      "fd probe '%s' unknown (projected=%d active_keepers=%d)"
      probe
      projected_fds
      active_keepers
  | Projected_fd_budget_exhausted { soft_limit; projected_fds; active_keepers; _ } ->
    Printf.sprintf
      "projected fd budget exhausted (soft_limit=%d projected=%d active_keepers=%d)"
      soft_limit
      projected_fds
      active_keepers
  | System_fd_budget_exhausted { open_files; max_files; remaining_files; projected_fds; _ } ->
    Printf.sprintf
      "system fd budget exhausted (open=%d max=%d remaining=%d projected=%d)"
      open_files
      max_files
      remaining_files
      projected_fds
  | Host_fd_hotspot_budget_exhausted
      { open_files; max_files_per_process; remaining_files; projected_fds; _ } ->
    Printf.sprintf
      "host fd hotspot exhausted (open=%d max_per_proc=%d remaining=%d projected=%d)"
      open_files
      max_files_per_process
      remaining_files
      projected_fds
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
  let ( system_open_files
      , system_max_files
      , system_fd_remaining
      , system_fd_utilization
      , system_max_files_per_process
      , host_fd_hotspot_remaining
      , host_fd_hotspot_probe_supported )
    =
    match system_fds with
    | Some { open_files; max_files; max_files_per_process } ->
      let max_files_per_process_json, hotspot_remaining, hotspot_supported =
        match max_files_per_process with
        | Some limit ->
          `Int limit, `Int (max 0 (limit - open_files)), `Bool true
        | None -> `Null, `Null, `Bool false
      in
      ( `Int open_files
      , `Int max_files
      , `Int (max 0 (max_files - open_files))
      , `Float (float_of_int open_files /. float_of_int max_files)
      , max_files_per_process_json
      , hotspot_remaining
      , hotspot_supported )
    | None -> `Null, `Null, `Null, `Null, `Null, `Null, `Bool false
  in
  `Assoc
    [ "status", `String status
    ; "reason", reason
    ; "degraded", `Bool (active ())
    ; "fd_pressure_remaining_sec", `Float (remaining_sec ())
    ; "soft_limit", Json_util.int_option_to_yojson soft_limit
    ; "open_fds", Json_util.int_option_to_yojson open_fds
    ; "system_open_files", system_open_files
    ; "system_max_files", system_max_files
    ; "system_fd_remaining", system_fd_remaining
    ; "system_fd_utilization", system_fd_utilization
    ; "system_fd_headroom", `Int (system_fd_headroom ())
    ; "system_fd_probe_supported", `Bool (Option.is_some system_fds)
    ; "system_max_files_per_process", system_max_files_per_process
    ; "host_fd_hotspot_remaining", host_fd_hotspot_remaining
    ; "host_fd_hotspot_headroom", `Int (host_fd_hotspot_headroom ())
    ; "host_fd_hotspot_blocking_enabled", `Bool (host_fd_hotspot_blocking_enabled ())
    ; "host_fd_hotspot_probe_supported", host_fd_hotspot_probe_supported
    ; "headroom", `Int (fd_headroom ())
    ; "fd_per_active_keeper", `Int (fd_per_active_keeper ())
    ; "min_nofile_for_fleet", `Int (min_nofile_for_fleet ())
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
