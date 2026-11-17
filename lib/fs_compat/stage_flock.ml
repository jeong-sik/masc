external try_lock_exclusive_fd : Unix.file_descr -> bool
  = "caml_masc_stage_flock_try_lock_ex"

type undeterminable_reason =
  | Open_failed
  | Not_regular_file
  | Flock_refused

type probe =
  | Held
  | Not_held
  | Undeterminable of undeterminable_reason

external probe_path_code : string -> int = "caml_masc_stage_flock_probe_path"

let probe_path path =
  match probe_path_code path with
  | 0 -> Not_held
  | 1 -> Held
  | 2 -> Undeterminable Open_failed
  | 3 -> Undeterminable Not_regular_file
  | _ -> Undeterminable Flock_refused
;;

let undeterminable_reason_label = function
  | Open_failed -> "open_failed"
  | Not_regular_file -> "not_regular_file"
  | Flock_refused -> "flock_refused"
;;
