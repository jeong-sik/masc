type t =
  { store : Dated_jsonl.t
  ; max_bytes : int
  }

let create ~base_dir ~max_bytes =
  { store = Dated_jsonl.create ~base_dir ~max_bytes (); max_bytes }

let read_store t = t.store

let append t json =
  match Dated_jsonl.append_rotating t.store ~max_current_file_bytes:t.max_bytes json with
  | Appended_to_current | Appended_after_rotation _ -> ()
  | Skipped_by_append_guard ->
    raise (Sys_error "Keeper metric append refused by the append guard")
  | Skipped_rotation_exhausted { sequence_limit } ->
    raise
      (Sys_error
         (Printf.sprintf
            "Keeper metric append refused: %d rotation segments already exist under %s"
            sequence_limit (Dated_jsonl.base_dir t.store)))
