(** Keeper_fd_pressure — process-local FD exhaustion guard.

    The 24-keeper failure mode is not a classic mutex deadlock. Once the
    process reaches EMFILE/ENFILE pressure, unrelated append/read/spawn paths
    all start failing and retries amplify the outage. This module provides a
    low-cardinality circuit breaker that can be tripped from central error
    sites and consulted by turn/spawn scheduling. *)

let cooldown_until = Atomic.make 0.0
let last_log_at = Atomic.make 0.0
let nofile_guard_warned = Atomic.make false
let nofile_soft_limit_cache : int option option Atomic.t = Atomic.make None

type admission_block =
  | Fd_pressure_cooldown of float
  | Projected_fd_budget_exhausted of
      { soft_limit : int
      ; open_fds : int option
      ; active_keepers : int
      ; starting_keepers : int
      ; projected_fds : int
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

let note ?(site = "unknown") ?(detail = "") () =
  let now = Time_compat.now () in
  let until_ts = now +. cooldown_sec () in
  let prev = Atomic.get cooldown_until in
  if until_ts > prev then Atomic.set cooldown_until until_ts;
  let last = Atomic.get last_log_at in
  if now -. last >= 10.0 then begin
    Atomic.set last_log_at now;
    Log.Keeper.error
      "fd_pressure: circuit breaker active for %.0fs site=%s detail=%s"
      (max 0.0 (Atomic.get cooldown_until -. now))
      site
      detail
  end
;;

let note_if_fd_exhaustion ?site detail =
  if is_fd_exhaustion_text detail then note ?site ~detail ()
;;

let active ?now () =
  let now = Option.value ~default:(Time_compat.now ()) now in
  Atomic.get cooldown_until > now
;;

let remaining_sec ?now () =
  let now = Option.value ~default:(Time_compat.now ()) now in
  max 0.0 (Atomic.get cooldown_until -. now)
;;

let reset_for_tests () =
  Atomic.set cooldown_until 0.0;
  Atomic.set last_log_at 0.0;
  Atomic.set nofile_guard_warned false;
  Atomic.set nofile_soft_limit_cache None
;;

let process_nofile_soft_limit () =
  match Atomic.get nofile_soft_limit_cache with
  | Some cached -> cached
  | None ->
    let detected =
      try
        let lines, status =
          With_process.with_process_args_in
            "/bin/sh"
            [| "sh"; "-c"; "ulimit -n" |]
            With_process.drain_lines
        in
        match status, lines with
        | Unix.WEXITED 0, line :: _ -> int_of_string_opt (String.trim line)
        | _ -> None
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | _ -> None
    in
    Atomic.set nofile_soft_limit_cache (Some detected);
    detected
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

let min_nofile_for_24_keepers () =
  Env_config_core.get_int ~default:4096 "MASC_KEEPER_MIN_NOFILE_FOR_24"
  |> max 256
;;

let fd_headroom () =
  Env_config_core.get_int ~default:128 "MASC_KEEPER_FD_HEADROOM"
  |> max 32
;;

let fd_per_active_keeper () =
  Env_config_core.get_int ~default:96 "MASC_KEEPER_FD_PER_ACTIVE_KEEPER"
  |> max 16
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

let admission_decision
  ?(soft_limit = process_nofile_soft_limit ())
  ?(open_fds = process_open_fd_count ())
  ~active_keepers
  ~starting_keepers
  ()
  =
  if active ()
  then Block (Fd_pressure_cooldown (remaining_sec ()))
  else (
    match soft_limit with
    | Some soft_limit when soft_limit > 0 ->
      let projected_fds =
        projected_fd_budget ?open_fds ~active_keepers ~starting_keepers ()
      in
      if projected_fds <= soft_limit
      then Admit
      else
        Block
          (Projected_fd_budget_exhausted
             { soft_limit
             ; open_fds
             ; active_keepers = max 0 active_keepers
             ; starting_keepers = max 0 starting_keepers
             ; projected_fds
             })
    | _ -> Admit)
;;

let admitted = function
  | Admit -> true
  | Block _ -> false
;;

let admit_start ?soft_limit ?open_fds ~active_keepers ~starting_keepers () =
  admitted (admission_decision ?soft_limit ?open_fds ~active_keepers ~starting_keepers ())
;;

let admit_turn ?soft_limit ?open_fds ~active_keepers () =
  admit_start ?soft_limit ?open_fds ~active_keepers ~starting_keepers:0 ()
;;

let cap_active_keepers_for_nofile ?(soft_limit = process_nofile_soft_limit ()) requested =
  match soft_limit with
  | Some soft when soft > 0 && soft < min_nofile_for_24_keepers () ->
    let soft_cap = active_keeper_cap_for_soft_limit soft in
    let cap = if requested <= 0 then soft_cap else min requested soft_cap in
    if (requested <= 0 || cap < requested) && not (Atomic.get nofile_guard_warned) then begin
      Atomic.set nofile_guard_warned true;
      Log.Keeper.error
        "fd_pressure: process nofile soft limit %d is below safe 24-keeper floor %d; \
         reducing active keeper cap from %d to %d"
        soft
        (min_nofile_for_24_keepers ())
        requested
        cap
    end;
    cap
  | _ -> requested
;;
