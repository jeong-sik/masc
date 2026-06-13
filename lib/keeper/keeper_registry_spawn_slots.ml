(** Spawn-slot admission decisions for keeper registry. *)

type denial_reason =
  | Fd_pressure_active
  | Fd_admission_blocked
  | Max_active_keepers of { running_count : int; max_keepers : int }

let to_label = function
  | Fd_pressure_active -> "fd_pressure_active"
  | Fd_admission_blocked -> "fd_admission_blocked"
  | Max_active_keepers _ -> "max_active_keepers"
;;

let to_detail = function
  | Fd_pressure_active -> "spawn slot denied: fd pressure cooldown active"
  | Fd_admission_blocked -> "spawn slot denied: fd admission guard rejected launch"
  | Max_active_keepers { running_count; max_keepers } ->
    Printf.sprintf
      "spawn slot denied: max active keepers reached (running_count=%d max_keepers=%d)"
      running_count
      max_keepers
;;

let decision ?fd_admitted ~running_count () =
  let max_keepers = Keeper_runtime_resolved.bootstrap_max_active_keepers () in
  let fd_admitted () =
    match fd_admitted with
    | Some admitted -> admitted
    | None ->
      Keeper_fd_pressure.admit_start
        ~active_keepers:running_count
        ~starting_keepers:1
        ()
  in
  if Keeper_fd_pressure.active ()
  then Error Fd_pressure_active
  else if not (fd_admitted ())
  then Error Fd_admission_blocked
  else if max_keepers > 0 && running_count >= max_keepers
  then Error (Max_active_keepers { running_count; max_keepers })
  else Ok ()
;;

let record_denied ~keeper_name ~surface reason =
  let reason_label = to_label reason in
  let detail = to_detail reason in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string SpawnSlotDenied)
    ~labels:[ "keeper", keeper_name; "surface", surface; "reason", reason_label ]
    ();
  Log.Keeper.warn
    "keeper spawn denied: keeper=%s surface=%s reason=%s detail=%s"
    keeper_name
    surface
    reason_label
    detail
;;
