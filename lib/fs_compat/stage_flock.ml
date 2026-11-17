external try_lock_exclusive_fd : Unix.file_descr -> bool
  = "caml_masc_stage_flock_try_lock_ex"

external lock_exclusive_fd : Unix.file_descr -> path:string -> unit
  = "caml_masc_stage_flock_lock_ex"

external is_path_flocked : string -> bool
  = "caml_masc_stage_flock_is_held"
