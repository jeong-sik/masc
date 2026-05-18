(** Keeper spawn/admission decision helpers. *)

type denial_reason =
  | Fd_pressure_active
  | Disk_pressure_active
  | Fd_admission_blocked
  | Disk_admission_blocked
  | Max_active_keepers of { running_count : int; max_keepers : int }

let denial_reason_to_label = function
  | Fd_pressure_active -> "fd_pressure_active"
  | Disk_pressure_active -> "disk_pressure_active"
  | Fd_admission_blocked -> "fd_admission_blocked"
  | Disk_admission_blocked -> "disk_admission_blocked"
  | Max_active_keepers _ -> "max_active_keepers"
;;

let denial_reason_to_detail = function
  | Fd_pressure_active -> "spawn slot denied: fd pressure cooldown active"
  | Disk_pressure_active -> "spawn slot denied: disk pressure cooldown active"
  | Fd_admission_blocked -> "spawn slot denied: fd admission guard rejected launch"
  | Disk_admission_blocked -> "spawn slot denied: disk admission guard rejected launch"
  | Max_active_keepers { running_count; max_keepers } ->
    Printf.sprintf
      "spawn slot denied: max active keepers reached (running_count=%d max_keepers=%d)"
      running_count
      max_keepers
;;

let decision ~running_count ?base_path ?fd_admitted ?disk_admitted () =
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
  let disk_admitted () =
    match disk_admitted with
    | Some admitted -> admitted
    | None ->
      (match base_path with
       | None -> true
       | Some masc_root -> Keeper_disk_pressure.admit_turn ~masc_root ())
  in
  if Keeper_fd_pressure.active ()
  then Error Fd_pressure_active
  else if Keeper_disk_pressure.active ()
  then Error Disk_pressure_active
  else if not (fd_admitted ())
  then Error Fd_admission_blocked
  else if not (disk_admitted ())
  then Error Disk_admission_blocked
  else if max_keepers > 0 && running_count >= max_keepers
  then Error (Max_active_keepers { running_count; max_keepers })
  else Ok ()
;;

let available ~running_count ?base_path ?fd_admitted ?disk_admitted () =
  match decision ~running_count ?base_path ?fd_admitted ?disk_admitted () with
  | Ok () -> true
  | Error _ -> false
;;
