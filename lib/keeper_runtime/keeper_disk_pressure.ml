(** Observation-only filesystem-space facts.

    Actual [ENOSPC] exceptions and raw [statvfs(2)] filesystem probes are
    facts. This module never admits, delays, pauses, or rejects Keeper work;
    health classification is purely observational for operator visibility and
    [/health?full=1] rollup. *)

type disk_snapshot =
  { path : string
  ; filesystem : string
  ; total_bytes : int
  ; used_bytes : int
  ; available_bytes : int
  ; capacity_percent : float
  ; available_percent : float
  ; mounted_on : string
  }

type snapshot_result =
  | Snapshot of disk_snapshot
  | Probe_error of string

type health_status =
  | Healthy
  | Low_space
  | Critical_space
  | Exhausted_enospc
  | Probe_unavailable

let low_space_available_pct = 15.0
let critical_space_available_pct = 5.0
let critical_space_available_bytes = 2 * 1024 * 1024 * 1024
let enospc_recent_window_sec = 900.0

let health_status_to_string = function
  | Healthy -> "healthy"
  | Low_space -> "low_space"
  | Critical_space -> "critical_space"
  | Exhausted_enospc -> "exhausted_enospc"
  | Probe_unavailable -> "probe_unavailable"
;;

let is_enospc_recent ~now ~enospc_observations ~last_enospc_ts =
  if enospc_observations <= 0
  then false
  else (
    match last_enospc_ts with
    | Some ts when Float.is_finite ts && ts > 0.0 ->
      Float.max 0.0 (now -. ts) <= enospc_recent_window_sec
    | Some _ | None -> false)
;;

let classify_health ?now ~enospc_observations ~last_enospc_ts snapshot =
  let now_ts = Option.value ~default:(Time_compat.now ()) now in
  if is_enospc_recent ~now:now_ts ~enospc_observations ~last_enospc_ts
  then Exhausted_enospc
  else (
    match snapshot with
    | Probe_error _ -> Probe_unavailable
    | Snapshot s ->
      if
        s.available_percent <= critical_space_available_pct
        || s.available_bytes <= critical_space_available_bytes
      then Critical_space
      else if s.available_percent <= low_space_available_pct
      then Low_space
      else Healthy)
;;

(* Wire vocabulary read by [Server_health_rollup] via [Health_status.of_string_opt]. *)
let rollup_status_of_health = function
  | Healthy -> "ok"
  | Low_space -> "warning"
  | Critical_space -> "critical"
  | Exhausted_enospc -> "error"
  | Probe_unavailable -> "unavailable"
;;

let operator_action_required_of_health = function
  | Healthy | Low_space | Probe_unavailable -> false
  | Critical_space | Exhausted_enospc -> true
;;

let status_reasons_of snapshot health =
  let snapshot_reason =
    match snapshot with
    | Probe_error _ -> [ "disk_probe_unavailable" ]
    | Snapshot s ->
      if
        s.available_percent <= critical_space_available_pct
        || s.available_bytes <= critical_space_available_bytes
      then [ "critical_disk_space" ]
      else if s.available_percent <= low_space_available_pct
      then [ "low_disk_space" ]
      else []
  in
  match health with
  | Healthy -> []
  | Low_space | Critical_space | Probe_unavailable -> snapshot_reason
  | Exhausted_enospc -> "storage_space_exhausted_enospc" :: snapshot_reason
;;

type cache_entry =
  { path : string
  ; at : float
  ; result : snapshot_result
  }

let cache : cache_entry option Atomic.t = Atomic.make None
let storage_space_exhaustion_total = Atomic.make 0
let last_storage_space_exhaustion_ts = Atomic.make None

external caml_masc_statvfs :
  string -> (int64 * int64 * int64, string) result
  = "caml_masc_statvfs"

let note_exception ?(site = "unknown") exn =
  match System_error_class.errno_of_exn exn with
  | Some System_error_class.Enospc ->
    Atomic.incr storage_space_exhaustion_total;
    Atomic.set last_storage_space_exhaustion_ts (Some (Time_compat.now ()));
    Log.Keeper.error
      "disk_observation: typed storage-space exhaustion site=%s exception=%s"
      site
      (Printexc.to_string exn)
  | Some
      System_error_class.(
        Emfile | Enfile | Eacces | Eperm | Enoent | Econnrefused | Etimedout
        | Epipe | Eaddrinuse | Eaddrnotavail | Other_errno _)
  | None -> ()
;;

let reset_for_tests () =
  Atomic.set cache None;
  Atomic.set storage_space_exhaustion_total 0;
  Atomic.set last_storage_space_exhaustion_ts None
;;

let snapshot_ttl_sec () =
  Env_config_core.get_float ~default:30.0 "MASC_KEEPER_DISK_SNAPSHOT_TTL_SEC"
  |> Float.max 1.0
;;

let rec nearest_existing_path path =
  if String.equal path ""
  then "/"
  else if Sys.file_exists path
  then path
  else (
    let parent = Filename.dirname path in
    if String.equal parent path then "/" else nearest_existing_path parent)
;;

let clamp_int64_to_int value =
  if value <= 0L
  then 0
  else if value >= Int64.of_int max_int
  then max_int
  else Int64.to_int value
;;

let clamp_percent pct = Float.max 0.0 (Float.min 100.0 pct)

let snapshot_of_statvfs ~path ~total_bytes:total_64 ~used_bytes:used_64 ~available_bytes:avail_64 =
  let total_f = Int64.to_float total_64 in
  let used_f = Int64.to_float used_64 in
  let avail_f = Int64.to_float avail_64 in
  let available_percent =
    if total_64 <= 0L
    then 0.0
    else clamp_percent (avail_f /. total_f *. 100.0)
  in
  let usable_f = used_f +. avail_f in
  let capacity_percent =
    if usable_f > 0.0
    then clamp_percent (used_f /. usable_f *. 100.0)
    else if total_64 > 0L
    then clamp_percent (used_f /. total_f *. 100.0)
    else 0.0
  in
  Snapshot
    { path
    ; filesystem = "statvfs"
    ; total_bytes = clamp_int64_to_int total_64
    ; used_bytes = clamp_int64_to_int used_64
    ; available_bytes = clamp_int64_to_int avail_64
    ; capacity_percent
    ; available_percent
    ; mounted_on = path
    }
;;

let probe_uncached path =
  let path = nearest_existing_path path in
  try
    match
      Eio_guard.run_in_systhread ~label:"keeper_disk_pressure.statvfs" (fun () ->
        caml_masc_statvfs path)
    with
    | Ok (total_bytes, used_bytes, available_bytes) ->
      snapshot_of_statvfs ~path ~total_bytes ~used_bytes ~available_bytes
    | Error detail ->
      let msg = "statvfs: " ^ detail in
      Log.Keeper.warn "disk_observation: probe failed path=%s detail=%s" path msg;
      Probe_error msg
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    note_exception ~site:"keeper_disk_pressure.probe" exn;
    let detail = Printexc.to_string exn in
    Log.Keeper.warn "disk_observation: probe raised path=%s exception=%s" path detail;
    Probe_error detail
;;

let probe_path ?now path =
  let now = Option.value ~default:(Time_compat.now ()) now in
  match Atomic.get cache with
  | Some cached
    when String.equal cached.path path && now -. cached.at < snapshot_ttl_sec () ->
    cached.result
  | Some _ | None ->
    let result = probe_uncached path in
    (match result with
     | Snapshot _ -> Atomic.set cache (Some { path; at = now; result })
     | Probe_error _ -> ());
    result
;;

let probe_masc_root ?now ~masc_root () = probe_path ?now masc_root

let disk_snapshot_to_json (snapshot : disk_snapshot) =
  `Assoc
    [ "path", `String snapshot.path
    ; "filesystem", `String snapshot.filesystem
    ; "mounted_on", `String snapshot.mounted_on
    ; "total_bytes", `Int snapshot.total_bytes
    ; "used_bytes", `Int snapshot.used_bytes
    ; "available_bytes", `Int snapshot.available_bytes
    ; "capacity_percent", `Float snapshot.capacity_percent
    ; "available_percent", `Float snapshot.available_percent
    ]
;;

let snapshot_result_to_json = function
  | Snapshot snapshot -> disk_snapshot_to_json snapshot
  | Probe_error detail -> `Assoc [ "error", `String detail ]
;;

let observation_fields () =
  [ "mode", `String "observation_only"
  ; ( "storage_space_exhaustion_observations_total"
    , `Int (Atomic.get storage_space_exhaustion_total) )
  ; ( "last_storage_space_exhaustion_ts"
    , match Atomic.get last_storage_space_exhaustion_ts with
      | Some value -> `Float value
      | None -> `Null )
  ]
;;

let snapshot_json ?now ~masc_root () =
  let now_ts = Option.value ~default:(Time_compat.now ()) now in
  let snapshot = probe_masc_root ~now:now_ts ~masc_root () in
  let enospc_observations = Atomic.get storage_space_exhaustion_total in
  let last_enospc_ts = Atomic.get last_storage_space_exhaustion_ts in
  let health =
    classify_health ~now:now_ts ~enospc_observations ~last_enospc_ts snapshot
  in
  let reasons = status_reasons_of snapshot health in
  `Assoc
    ([ "masc_root", `String masc_root
     ; "snapshot_ttl_sec", `Float (snapshot_ttl_sec ())
     ; "status", `String (rollup_status_of_health health)
     ; "health_status", `String (health_status_to_string health)
     ; "status_reasons", `List (List.map (fun reason -> `String reason) reasons)
     ; "operator_action_required", `Bool (operator_action_required_of_health health)
     ; "filesystem", snapshot_result_to_json snapshot
     ]
     @ observation_fields ())
;;
