type t =
  { store : Dated_jsonl.t
  ; segment_max_bytes : int
  }

let create ~base_dir ~max_bytes =
  (* Leave room for a completed segment alongside the current one. A segment
     equal to the whole store target would be pruned immediately on rotation,
     collapsing the history to the newly appended row. *)
  let segment_max_bytes = if max_bytes <= 0 then 0 else max 1 (max_bytes / 2) in
  { store = Dated_jsonl.create ~base_dir ~max_bytes (); segment_max_bytes }

let read_store t = t.store

let append t json =
  match Dated_jsonl.append_rotating t.store ~max_current_file_bytes:t.segment_max_bytes json with
  | Appended_to_current | Appended_after_rotation _ -> ()
  | Skipped_by_append_guard ->
    raise (Sys_error "Keeper metric append refused by the append guard")
  | Skipped_rotation_exhausted { sequence_limit } ->
    raise
      (Sys_error
         (Printf.sprintf
            "Keeper metric append refused: rotation sequence reached %d under %s"
            sequence_limit (Dated_jsonl.base_dir t.store)))
