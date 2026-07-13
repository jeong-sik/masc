(** Observation-only filesystem-space facts.

    Actual [ENOSPC] exceptions and raw filesystem probes are facts. Free-space
    floors, cooldowns, and admission decisions were estimates that could stop
    unrelated Keepers, so they do not belong here. *)

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

type cache_entry =
  { path : string
  ; at : float
  ; result : snapshot_result
  }

let cache : cache_entry option Atomic.t = Atomic.make None
let storage_space_exhaustion_total = Atomic.make 0
let last_storage_space_exhaustion_ts = Atomic.make None

let note_exception ?(site = "unknown") exn =
  match exn with
  | Unix.Unix_error (Unix.ENOSPC, _, _) ->
    Atomic.incr storage_space_exhaustion_total;
    Atomic.set last_storage_space_exhaustion_ts (Some (Time_compat.now ()));
    Log.Keeper.error
      "disk_observation: typed storage-space exhaustion site=%s exception=%s"
      site
      (Printexc.to_string exn)
  | _ -> ()
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

let split_ws line = Str.split (Str.regexp "[ \t]+") (String.trim line)

let parse_capacity_percent raw =
  let trimmed = String.trim raw in
  let number =
    if String.ends_with ~suffix:"%" trimmed
    then String.sub trimmed 0 (String.length trimmed - 1)
    else trimmed
  in
  float_of_string_opt number
;;

let parse_df_output ~path lines =
  match lines with
  | _header :: row :: _ ->
    (match split_ws row with
     | filesystem :: blocks :: used :: available :: capacity :: mounted_parts ->
       (match
          ( int_of_string_opt blocks
          , int_of_string_opt used
          , int_of_string_opt available
          , parse_capacity_percent capacity )
        with
        | Some blocks_k, Some used_k, Some available_k, Some capacity_percent ->
          let total_bytes = blocks_k * 1024 in
          let used_bytes = used_k * 1024 in
          let available_bytes = available_k * 1024 in
          let available_percent =
            if total_bytes <= 0
            then 0.0
            else float_of_int available_bytes /. float_of_int total_bytes *. 100.0
          in
          Snapshot
            { path
            ; filesystem
            ; total_bytes
            ; used_bytes
            ; available_bytes
            ; capacity_percent
            ; available_percent
            ; mounted_on = String.concat " " mounted_parts
            }
        | _ -> Probe_error ("unable to parse df filesystem row: " ^ row))
     | _ -> Probe_error ("unexpected df output: " ^ row))
  | _ -> Probe_error "df returned no filesystem row"
;;

let process_status_to_string = function
  | Unix.WEXITED code -> Printf.sprintf "exited(%d)" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signaled(%d)" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped(%d)" signal
;;

let probe_uncached path =
  let path = nearest_existing_path path in
  try
    match
      With_process.with_process_args_in
        "/bin/df"
        [| "df"; "-Pk"; path |]
        With_process.drain_lines
    with
    | lines, Unix.WEXITED 0 -> parse_df_output ~path lines
    | _lines, status ->
      let detail = "df -Pk " ^ process_status_to_string status in
      Log.Keeper.warn "disk_observation: probe failed path=%s detail=%s" path detail;
      Probe_error detail
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
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
    Atomic.set cache (Some { path; at = now; result });
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
  let snapshot = probe_masc_root ?now ~masc_root () in
  `Assoc
    ([ "masc_root", `String masc_root
     ; "snapshot_ttl_sec", `Float (snapshot_ttl_sec ())
     ; "filesystem", snapshot_result_to_json snapshot
     ]
     @ observation_fields ())
;;

module For_testing = struct
  let reset = reset_for_tests
end
