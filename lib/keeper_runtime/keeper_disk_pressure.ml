(** Keeper_disk_pressure — process-local disk exhaustion guard.

    Disk pressure is a different fleet failure mode from FD exhaustion:
    Docker playgrounds and JSONL telemetry can keep growing after the request
    that created them has returned.  This module exposes a cheap cached
    filesystem-free-space projection and a circuit breaker tripped by ENOSPC
    style errors. *)

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

type admission_block =
  | Disk_pressure_cooldown of float
  | Disk_probe_error of { detail : string }
  | Disk_free_space_low of
      { path : string
      ; available_bytes : int
      ; min_free_bytes : int
      ; effective_min_free_bytes : int
      ; available_percent : float
      ; min_free_percent : float
      ; percent_floor_max_bytes : int
      }

type admission_decision =
  | Admit
  | Block of admission_block

type cache_entry =
  { path : string
  ; at : float
  ; result : snapshot_result
  }

let cooldown_until = Atomic.make 0.0
let last_log_at = Atomic.make 0.0
let cache : cache_entry option Atomic.t = Atomic.make None

let contains haystack needle =
  String_util.contains_substring_ci haystack needle
;;

(* RFC-0154 PR-2: substring vocabulary lives in
   [System_error_class.classify_string] now.  Wrapper preserved for
   external callers; mirrors the previous boolean semantics. *)
let is_disk_exhaustion_text detail =
  match System_error_class.classify_string detail with
  | System_error_class.Disk_exhaustion -> true
  | System_error_class.Fd_exhaustion
  | System_error_class.Permission_denied
  | System_error_class.Connection_refused
  | System_error_class.Timeout
  | System_error_class.Other _ -> false
;;

let is_disk_exhaustion_exn = function
  | Unix.Unix_error (Unix.ENOSPC, _, _) -> true
  | Sys_error msg -> is_disk_exhaustion_text msg
  | exn -> is_disk_exhaustion_text (Printexc.to_string exn)
;;

let cooldown_sec () =
  Env_config_core.get_float ~default:120.0 "MASC_KEEPER_DISK_PRESSURE_COOLDOWN_SEC"
  |> Float.max 10.0
  |> Float.min 1800.0
;;

let note ?(site = "unknown") ?(detail = "") () =
  let now = Time_compat.now () in
  let until_ts = now +. cooldown_sec () in
  let prev = Atomic.get cooldown_until in
  if until_ts > prev then Atomic.set cooldown_until until_ts;
  let last = Atomic.get last_log_at in
  if now -. last >= 10.0
  then (
    Atomic.set last_log_at now;
    Log.Keeper.error
      "disk_pressure: circuit breaker active for %.0fs site=%s detail=%s"
      (max 0.0 (Atomic.get cooldown_until -. now))
      site
      detail)
;;

let note_if_disk_exhaustion ?site detail =
  if is_disk_exhaustion_text detail then note ?site ~detail ()
;;

let note_exception ?site exn =
  if is_disk_exhaustion_exn exn then note ?site ~detail:(Printexc.to_string exn) ()
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
  Atomic.set cache None
;;

let env_int_clamped name ~default ~min_v =
  match Sys.getenv_opt name with
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | Some value -> max min_v value
     | None -> default)
  | None -> default
;;

let env_float_clamped name ~default ~min_v =
  match Sys.getenv_opt name with
  | Some raw ->
    (match float_of_string_opt (String.trim raw) with
     | Some value -> max min_v value
     | None -> default)
  | None -> default
;;

let min_free_bytes () =
  env_int_clamped
    "MASC_KEEPER_DISK_MIN_FREE_BYTES"
    ~default:(10 * 1024 * 1024 * 1024)
    ~min_v:(512 * 1024 * 1024)
;;

let min_free_percent () =
  env_float_clamped "MASC_KEEPER_DISK_MIN_FREE_PERCENT" ~default:5.0 ~min_v:0.1
;;

let percent_floor_max_bytes () =
  (* Keep the percent floor from scaling into hundreds of GiB on multi-TiB
     volumes. The explicit min_free knobs remain the operator-facing tuning
     surface; this cap is a guardrail against over-strict defaults. *)
  40 * 1024 * 1024 * 1024
;;

let snapshot_ttl_sec () =
  env_float_clamped "MASC_KEEPER_DISK_SNAPSHOT_TTL_SEC" ~default:30.0 ~min_v:1.0
;;

let percent_floor_bytes s ~min_free_percent =
  if s.total_bytes <= 0
  then 0
  else
    float_of_int s.total_bytes *. min_free_percent /. 100.0
    |> ceil
    |> int_of_float
;;

let effective_min_free_bytes s ~min_free_bytes ~min_free_percent =
  let percent_floor_max_bytes = percent_floor_max_bytes () in
  let capped_percent_floor =
    min (percent_floor_bytes s ~min_free_percent) percent_floor_max_bytes
  in
  max min_free_bytes capped_percent_floor
;;

let rec nearest_existing_path path =
  if path = "" then "/"
  else if Sys.file_exists path then path
  else (
    let parent = Filename.dirname path in
    if String.equal parent path then "/" else nearest_existing_path parent)
;;

let split_ws line = Str.split (Str.regexp "[ \t]+") (String.trim line)

let parse_capacity_percent raw =
  let raw = String.trim raw in
  let raw =
    if String.ends_with ~suffix:"%" raw
    then String.sub raw 0 (String.length raw - 1)
    else raw
  in
  Option.value ~default:0.0 (float_of_string_opt raw)
;;

let int_of_field raw = int_of_string_opt (String.trim raw)

let parse_df_output ~path lines =
  match lines with
  | _header :: row :: _ ->
    let fields = split_ws row in
    (match fields with
     | filesystem :: blocks :: used :: available :: capacity :: mounted_parts ->
       (match int_of_field blocks, int_of_field used, int_of_field available with
        | Some blocks_k, Some used_k, Some available_k ->
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
            ; capacity_percent = parse_capacity_percent capacity
            ; available_percent
            ; mounted_on = String.concat " " mounted_parts
            }
        | _ -> Probe_error ("unable to parse df numeric fields: " ^ row))
     | _ -> Probe_error ("unexpected df output: " ^ row))
  | _ -> Probe_error "df returned no filesystem row"
;;

let probe_uncached path =
  let path = nearest_existing_path path in
  try
    let lines, status =
      With_process.with_process_args_in
        "/bin/df"
        [| "df"; "-Pk"; path |]
        With_process.drain_lines
    in
    match status with
    | Unix.WEXITED 0 -> parse_df_output ~path lines
    | _ -> Probe_error "df -Pk failed"
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    note_exception ~site:"keeper_disk_pressure.probe" exn;
    Probe_error (Printexc.to_string exn)
;;

let probe_path ?now path =
  let now = Option.value ~default:(Time_compat.now ()) now in
  match Atomic.get cache with
  | Some cached
    when String.equal cached.path path && now -. cached.at < snapshot_ttl_sec () ->
    cached.result
  | _ ->
    let result = probe_uncached path in
    Atomic.set cache (Some { path; at = now; result });
    result
;;

let probe_masc_root ?now ~masc_root () = probe_path ?now masc_root

let admission_decision_of_snapshot ?now snapshot =
  if active ?now ()
  then Block (Disk_pressure_cooldown (remaining_sec ?now ()))
  else (
    match snapshot with
    | Probe_error detail -> Block (Disk_probe_error { detail })
    | Snapshot s ->
      let min_free_bytes = min_free_bytes () in
      let min_free_percent = min_free_percent () in
      let percent_floor_max_bytes = percent_floor_max_bytes () in
      let effective_min_free_bytes =
        effective_min_free_bytes s ~min_free_bytes ~min_free_percent
      in
      if s.available_bytes < effective_min_free_bytes
      then
        Block
          (Disk_free_space_low
             { path = s.path
             ; available_bytes = s.available_bytes
             ; min_free_bytes
             ; effective_min_free_bytes
             ; available_percent = s.available_percent
             ; min_free_percent
             ; percent_floor_max_bytes
             })
      else Admit)
;;

let admission_decision ?now ~masc_root () =
  admission_decision_of_snapshot ?now (probe_masc_root ?now ~masc_root ())
;;

let admitted = function
  | Admit -> true
  | Block _ -> false
;;

let admit_turn ?now ~masc_root () = admitted (admission_decision ?now ~masc_root ())

let disk_snapshot_to_json (s : disk_snapshot) =
  `Assoc
    [ "path", `String s.path
    ; "filesystem", `String s.filesystem
    ; "mounted_on", `String s.mounted_on
    ; "total_bytes", `Int s.total_bytes
    ; "used_bytes", `Int s.used_bytes
    ; "available_bytes", `Int s.available_bytes
    ; "capacity_percent", `Float s.capacity_percent
    ; "available_percent", `Float s.available_percent
    ]
;;

let snapshot_result_to_json = function
  | Snapshot snapshot -> disk_snapshot_to_json snapshot
  | Probe_error error -> `Assoc [ "error", `String error ]
;;

let admission_block_to_json = function
  | Disk_pressure_cooldown remaining_sec ->
    `Assoc
      [ "tag", `String "disk_pressure_cooldown"
      ; "remaining_sec", `Float remaining_sec
      ]
  | Disk_probe_error { detail } ->
    `Assoc
      [ "tag", `String "disk_probe_error"
      ; "detail", `String detail
      ]
  | Disk_free_space_low
      { path
      ; available_bytes
      ; min_free_bytes
      ; effective_min_free_bytes
      ; available_percent
      ; min_free_percent
      ; percent_floor_max_bytes
      } ->
    `Assoc
      [ "tag", `String "disk_free_space_low"
      ; "path", `String path
      ; "available_bytes", `Int available_bytes
      ; "min_free_bytes", `Int min_free_bytes
      ; "effective_min_free_bytes", `Int effective_min_free_bytes
      ; "available_percent", `Float available_percent
      ; "min_free_percent", `Float min_free_percent
      ; "percent_floor_max_bytes", `Int percent_floor_max_bytes
      ]
;;

(* Stable, exhaustive kind tag per block constructor — mirrors
   [Keeper_fd_pressure.admission_block_kind]. Display/skip-reason only; the sum
   type stays the source of truth, the string is never parsed back. *)
let admission_block_kind = function
  | Disk_pressure_cooldown _ -> "disk_pressure_cooldown"
  | Disk_probe_error _ -> "disk_probe_error"
  | Disk_free_space_low _ -> "disk_free_space_low"
;;

(* Human-readable one-line summary carrying the typed numbers (no df re-probe).
   Used by the fleet admission observer's edge WARN so operators see the actual
   free/floor/short figures instead of a bare DEBUG skip. *)
let admission_block_summary block =
  let gib bytes = float_of_int bytes /. 1024. /. 1024. /. 1024. in
  match block with
  | Disk_pressure_cooldown remaining_sec ->
    Printf.sprintf "disk pressure cooldown (remaining=%.0fs)" remaining_sec
  | Disk_probe_error { detail } -> Printf.sprintf "disk probe error (%s)" detail
  | Disk_free_space_low
      { path; available_bytes; effective_min_free_bytes; available_percent; _ } ->
    Printf.sprintf
      "disk free-space below fleet floor: free=%.2fGiB (%.2f%%) floor=%.2fGiB \
       short=%.2fGiB path=%s"
      (gib available_bytes)
      available_percent
      (gib effective_min_free_bytes)
      (gib (effective_min_free_bytes - available_bytes))
      path
;;

let admission_decision_to_json = function
  | Admit -> `Assoc [ "admitted", `Bool true; "reason", `String "ok" ]
  | Block block ->
    `Assoc
      [ "admitted", `Bool false
      ; "reason", `String "blocked"
      ; "block", admission_block_to_json block
      ]
;;

let playground_paths_json ~masc_root =
  `Assoc
    [ "playground_root", `String (Filename.concat masc_root "playground")
    ; "docker_playground_root", `String (Filename.concat masc_root "playground/docker")
    ; "cleanup_policy", `String "operator_required_for_repo_data"
    ]
;;

let snapshot_json ?now ~masc_root () =
  let snapshot = probe_masc_root ?now ~masc_root () in
  `Assoc
    [ "active", `Bool (active ?now ())
    ; "remaining_sec", `Float (remaining_sec ?now ())
    ; "masc_root", `String masc_root
    ; "min_free_bytes", `Int (min_free_bytes ())
    ; "min_free_percent", `Float (min_free_percent ())
    ; "percent_floor_max_bytes", `Int (percent_floor_max_bytes ())
    ; "snapshot_ttl_sec", `Float (snapshot_ttl_sec ())
    ; "filesystem", snapshot_result_to_json snapshot
    ; "admission", admission_decision_to_json (admission_decision_of_snapshot ?now snapshot)
    ; "playground", playground_paths_json ~masc_root
    ]
;;

module For_testing = struct
  let reset = reset_for_tests
  let is_disk_exhaustion_text = is_disk_exhaustion_text
  let is_disk_exhaustion_exn = is_disk_exhaustion_exn
  let admission_decision_of_snapshot = admission_decision_of_snapshot
end
