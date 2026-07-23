(** Observation-only process and host file-descriptor facts.

    Actual [EMFILE]/[ENFILE] exceptions and operating-system probes are facts.
    Projected FD cost, fleet headroom, cooldowns, and admission decisions were
    estimates that could stop unrelated Keepers, so they do not belong here. *)

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

type external_level =
  | External_warn
  | External_crit

let process_fd_exhaustion_total = Atomic.make 0
let system_fd_exhaustion_total = Atomic.make 0
let last_fd_exhaustion_ts = Atomic.make None
let external_warn_total = Atomic.make 0
let external_crit_total = Atomic.make 0
let last_external_signal_key = Atomic.make None
let last_external_signal_ts = Atomic.make None
let last_external_signal_reason = Atomic.make None

let note_exception ?(site = "unknown") exn =
  match exn with
  | Unix.Unix_error (Unix.EMFILE, _, _) ->
    Atomic.incr process_fd_exhaustion_total;
    Atomic.set last_fd_exhaustion_ts (Some (Time_compat.now ()));
    Log.Keeper.error
      "fd_observation: typed process FD exhaustion site=%s exception=%s"
      site
      (Printexc.to_string exn)
  | Unix.Unix_error (Unix.ENFILE, _, _) ->
    Atomic.incr system_fd_exhaustion_total;
    Atomic.set last_fd_exhaustion_ts (Some (Time_compat.now ()));
    Log.Keeper.error
      "fd_observation: typed system FD exhaustion site=%s exception=%s"
      site
      (Printexc.to_string exn)
  | _ -> ()
;;

let string_of_external_level = function
  | External_warn -> "warn"
  | External_crit -> "crit"
;;

let engage_external ~reason ~level ~ts () =
  let rec claim_new_signal () =
    let previous = Atomic.get last_external_signal_key in
    match previous with
    | Some (previous_level, previous_ts)
      when previous_level = level && Float.equal previous_ts ts -> false
    | Some _ | None ->
      if Atomic.compare_and_set last_external_signal_key previous (Some (level, ts))
      then true
      else claim_new_signal ()
  in
  if claim_new_signal ()
  then (
    (match level with
     | External_warn -> Atomic.incr external_warn_total
     | External_crit -> Atomic.incr external_crit_total);
    Atomic.set last_external_signal_ts (Some ts);
    Atomic.set last_external_signal_reason (Some reason);
    Log.Keeper.warn
      "fd_observation: external host signal level=%s observed_at=%.03f \
       reason=%s; execution remains unchanged"
      (string_of_external_level level)
      ts
      reason)
;;

let option_float_to_yojson = function
  | Some value -> `Float value
  | None -> `Null
;;

let option_string_to_yojson = function
  | Some value -> `String value
  | None -> `Null
;;

let projection_fields () =
  [ "mode", `String "observation_only"
  ; ( "process_fd_exhaustion_observations_total"
    , `Int (Atomic.get process_fd_exhaustion_total) )
  ; ( "system_fd_exhaustion_observations_total"
    , `Int (Atomic.get system_fd_exhaustion_total) )
  ; "last_fd_exhaustion_ts", option_float_to_yojson (Atomic.get last_fd_exhaustion_ts)
  ; "external_warn_total", `Int (Atomic.get external_warn_total)
  ; "external_crit_total", `Int (Atomic.get external_crit_total)
  ; "last_external_signal_ts", option_float_to_yojson (Atomic.get last_external_signal_ts)
  ; ( "last_external_signal_reason"
    , option_string_to_yojson (Atomic.get last_external_signal_reason) )
  ]
;;

let reset_for_tests () =
  Atomic.set nofile_soft_limit_cache Uninitialized;
  Atomic.set system_fd_cache None;
  Atomic.set process_fd_exhaustion_total 0;
  Atomic.set system_fd_exhaustion_total 0;
  Atomic.set last_fd_exhaustion_ts None;
  Atomic.set external_warn_total 0;
  Atomic.set external_crit_total 0;
  Atomic.set last_external_signal_key None;
  Atomic.set last_external_signal_ts None;
  Atomic.set last_external_signal_reason None
;;

external native_nofile_soft_limit : unit -> int option = "masc_nofile_soft_limit"

let detect_nofile_soft_limit_now () =
  try native_nofile_soft_limit () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.warn
      "fd_observation: RLIMIT_NOFILE probe failed: %s"
      (Printexc.to_string exn);
    None
;;

let process_nofile_soft_limit () =
  match Atomic.get nofile_soft_limit_cache with
  | Resolved cached -> cached
  | Uninitialized | In_flight ->
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

let process_status_to_string = function
  | Unix.WEXITED code -> Printf.sprintf "exited(%d)" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signaled(%d)" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped(%d)" signal
;;

let read_first_line path =
  try
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        try Some (input_line ic) with
        | End_of_file -> None)
  with
  | Sys_error _ | Unix.Unix_error _ -> None
;;

let detect_linux_system_fd_snapshot_now () =
  match read_first_line "/proc/sys/fs/file-nr" with
  | None -> None
  | Some line ->
    let normalized =
      String.map
        (function
          | '\t' | '\r' | '\n' -> ' '
          | char -> char)
        line
    in
    (match
       String.split_on_char ' ' normalized
       |> List.filter_map (fun field ->
         if String.equal field "" then None else int_of_string_opt field)
     with
     | open_files :: _unused_files :: max_files :: _
       when open_files >= 0 && max_files > 0 ->
       Some { open_files; max_files; max_files_per_process = None }
     | _ -> None)
;;

let detect_darwin_system_fd_snapshot_now () =
  if not (Sys.file_exists "/System/Library/CoreServices/SystemVersion.plist")
  then None
  else
    try
      match
        With_process.with_process_args_in
          "/usr/sbin/sysctl"
          [| "sysctl"; "-n"; "kern.num_files"; "kern.maxfiles"; "kern.maxfilesperproc" |]
          With_process.drain_lines
      with
      | lines, Unix.WEXITED 0 -> parse_system_fd_snapshot lines
      | _lines, status ->
        Log.Keeper.warn
          "fd_observation: sysctl FD probe exited with %s"
          (process_status_to_string status);
        None
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Log.Keeper.warn
        "fd_observation: sysctl FD probe failed: %s"
        (Printexc.to_string exn);
      None
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
    | Some { sampled_at; snapshot }
      when now -. sampled_at <= system_fd_probe_ttl_sec () -> Some snapshot
    | Some _ | None -> None
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

let option_int_to_yojson = function
  | Some value -> `Int value
  | None -> `Null
;;

let runtime_state_json ?(soft_limit = process_nofile_soft_limit ())
    ?(open_fds = process_open_fd_count ()) ?(system_fds = system_fd_snapshot ())
    ~active_keepers () =
  let process_remaining =
    match soft_limit, open_fds with
    | Some limit, Some open_count -> Some (limit - open_count)
    | (Some _ | None), None | None, Some _ -> None
  in
  let system_open_files, system_max_files, system_remaining, max_files_per_process =
    match system_fds with
    | Some snapshot ->
      ( Some snapshot.open_files
      , Some snapshot.max_files
      , Some (snapshot.max_files - snapshot.open_files)
      , snapshot.max_files_per_process )
    | None -> None, None, None, None
  in
  `Assoc
    ([ "mode", `String "observation_only"
     ; "active_keepers", `Int active_keepers
     ; "nofile_soft_limit", option_int_to_yojson soft_limit
     ; "process_open_fds", option_int_to_yojson open_fds
     ; "process_remaining_fds", option_int_to_yojson process_remaining
     ; "nofile_probe_supported", `Bool (Option.is_some soft_limit)
     ; "system_open_files", option_int_to_yojson system_open_files
     ; "system_max_files", option_int_to_yojson system_max_files
     ; "system_remaining_files", option_int_to_yojson system_remaining
     ; "system_max_files_per_process", option_int_to_yojson max_files_per_process
     ; "system_fd_probe_supported", `Bool (Option.is_some system_fds)
     ]
     @ projection_fields ())
;;
