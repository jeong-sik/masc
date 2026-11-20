open Result.Syntax

type delivery_granularity =
  | Full
  | Half
  | Reference_only

let granularity_to_string = function
  | Full -> "full"
  | Half -> "half"
  | Reference_only -> "reference_only"

type pending_feed =
  { state : Workspace_memory_reader.reader_state
  ; entries : Workspace_memory_log.change_entry list
  ; granularity : delivery_granularity
  ; formatted_block : string
  ; last_committed_seq : Workspace_memory_log.seq
  }

let io f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | File_lock_eio.Flock_timeout { caller; path; attempts } ->
    Error (Printf.sprintf "%s: flock timeout on %s after %d attempts" caller path attempts)
  | Unix.Unix_error (error, fn, arg) ->
    Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message error))
  | Sys_error detail -> Error detail
  | Eio.Io _ as exn -> Error (Printexc.to_string exn)

let validate_base_and_keeper ~base_path ~keeper_name =
  if not (Sys.is_directory base_path) then
    Error (base_path ^ ": workspace base is not a directory")
  else if String.equal (String.trim keeper_name) "" then
    Error "keeper_name must be nonblank"
  else if String.contains keeper_name '/'
          || String.contains keeper_name '\\'
          || String.contains keeper_name '\000'
          || String.equal keeper_name "."
          || String.equal keeper_name ".."
  then
    Error (Printf.sprintf "invalid keeper_name for delta cursor: %S" keeper_name)
  else
    Ok ()

let load_or_init_state ~path ~keeper_name =
  if not (Sys.file_exists path) then
    Ok (Workspace_memory_reader.init ~keeper:keeper_name ())
  else
    let* state =
      Workspace_memory_reader.load_reader_state ~path
      |> Result.map_error Workspace_memory_reader.error_to_string
    in
    if String.equal state.keeper keeper_name then
      Ok state
    else
      Error
        (Printf.sprintf
           "reader state %s belongs to %S, expected %S"
           path
           state.keeper
           keeper_name)

let load_log_report ~base_path =
  let log_path = Workspace_memory_log.log_path ~base_path in
  Workspace_memory_log.recover_file ~path:log_path
  |> Result.map_error Workspace_memory_log.error_to_string

let granularity_of_state ~(state : Workspace_memory_reader.reader_state) ~last_committed_seq =
  match state.pending with
  | None -> Full
  | Some p ->
    (match p.mode with
     | Workspace_memory_reader.Reference_only -> Reference_only
     | Workspace_memory_reader.Full_entries ->
       if p.to_seq < last_committed_seq then Half else Full)

let format_entry_full (e : Workspace_memory_log.change_entry) =
  Printf.sprintf
    "- [seq=%d] %s (%s): %s\n  payload: %s"
    e.seq
    e.fact_id
    e.recorded_at
    e.summary
    (Yojson.Safe.to_string e.payload)

let format_entry_half (e : Workspace_memory_log.change_entry) =
  Printf.sprintf "- [seq=%d] %s: %s" e.seq e.fact_id e.summary

let format_entry_reference (e : Workspace_memory_log.change_entry) =
  Printf.sprintf
    "- [seq=%d] %s (fetch via {\"entry\": %d})"
    e.seq
    e.fact_id
    e.seq

let format_entries ~granularity (entries : Workspace_memory_log.change_entry list) =
  match entries with
  | [] -> ""
  | _ :: _ ->
    let heading, render =
      match granularity with
      | Full -> "## World Memory Updates", format_entry_full
      | Half -> "## World Memory Updates (partial slice)", format_entry_half
      | Reference_only -> "## World Memory Updates (reference only)", format_entry_reference
    in
    heading ^ "\n" ^ String.concat "\n" (List.map render entries)

let read_pending_for_keeper ~base_path ~keeper_name ?max_entries () =
  io (fun () ->
    let* () = validate_base_and_keeper ~base_path ~keeper_name in
    let reader_file =
      Workspace_memory_reader.reader_path ~base_path ~keeper:keeper_name
    in
    Fs_compat.mkdir_p (Filename.dirname reader_file);
    File_lock_eio.with_lock reader_file (fun () ->
      let* report = load_log_report ~base_path in
      let* state = load_or_init_state ~path:reader_file ~keeper_name in
      let* next_state, entries =
        Workspace_memory_reader.plan_delivery
          state
          ~committed:report.committed_changes
          ?max_entries
          ()
        |> Result.map_error Workspace_memory_reader.error_to_string
      in
      let* () =
        if next_state = state then
          Ok ()
        else
          Workspace_memory_reader.save_reader_state ~path:reader_file next_state
          |> Result.map_error Workspace_memory_reader.error_to_string
      in
      let granularity =
        granularity_of_state
          ~state:next_state
          ~last_committed_seq:report.last_committed_seq
      in
      let formatted_block = format_entries ~granularity entries in
      Ok
        { state = next_state
        ; entries
        ; granularity
        ; formatted_block
        ; last_committed_seq = report.last_committed_seq
        }))

let record_turn_outcome ~base_path ~keeper_name outcome =
  io (fun () ->
    let* () = validate_base_and_keeper ~base_path ~keeper_name in
    let reader_file =
      Workspace_memory_reader.reader_path ~base_path ~keeper:keeper_name
    in
    Fs_compat.mkdir_p (Filename.dirname reader_file);
    File_lock_eio.with_lock reader_file (fun () ->
      let* report = load_log_report ~base_path in
      let* state = load_or_init_state ~path:reader_file ~keeper_name in
      let* next_state =
        Workspace_memory_reader.apply_turn_outcome
          state
          ~committed:report.committed_changes
          outcome
        |> Result.map_error Workspace_memory_reader.error_to_string
      in
      let* () =
        if next_state = state then
          Ok ()
        else
          Workspace_memory_reader.save_reader_state ~path:reader_file next_state
          |> Result.map_error Workspace_memory_reader.error_to_string
      in
      Ok next_state))

let acknowledge_cursor ~base_path ~keeper_name ?to_seq () =
  io (fun () ->
    let* () = validate_base_and_keeper ~base_path ~keeper_name in
    let reader_file =
      Workspace_memory_reader.reader_path ~base_path ~keeper:keeper_name
    in
    Fs_compat.mkdir_p (Filename.dirname reader_file);
    File_lock_eio.with_lock reader_file (fun () ->
      let* report = load_log_report ~base_path in
      let* state = load_or_init_state ~path:reader_file ~keeper_name in
      match to_seq with
      | None ->
        (match state.pending with
         | None -> Ok state
         | Some _ ->
           let* next_state =
             Workspace_memory_reader.apply_turn_outcome
               state
               ~committed:report.committed_changes
               Workspace_memory_reader.Turn_succeeded
             |> Result.map_error Workspace_memory_reader.error_to_string
           in
           let* () =
             Workspace_memory_reader.save_reader_state ~path:reader_file next_state
             |> Result.map_error Workspace_memory_reader.error_to_string
           in
           Ok next_state)
      | Some seq ->
        if seq < state.acknowledged_seq then
          Error
            (Printf.sprintf
               "cannot rewind cursor for %s from seq %d to %d"
               keeper_name
               state.acknowledged_seq
               seq)
        else if seq > report.last_committed_seq then
          Error
            (Printf.sprintf
               "cannot acknowledge uncommitted seq %d (last_committed_seq=%d)"
               seq
               report.last_committed_seq)
        else
          let* next_state =
            match state.pending with
            | Some p when p.to_seq = seq ->
              Workspace_memory_reader.apply_turn_outcome
                state
                ~committed:report.committed_changes
                Workspace_memory_reader.Turn_succeeded
              |> Result.map_error Workspace_memory_reader.error_to_string
            | Some _ | None ->
              Ok { state with acknowledged_seq = seq; pending = None }
          in
          let* () =
            if next_state = state then
              Ok ()
            else
              Workspace_memory_reader.save_reader_state ~path:reader_file next_state
              |> Result.map_error Workspace_memory_reader.error_to_string
          in
          Ok next_state))

let read_entry_by_seq ~base_path ~seq =
  io (fun () ->
    if not (Sys.is_directory base_path) then
      Error (base_path ^ ": workspace base is not a directory")
    else
      let* report = load_log_report ~base_path in
      Ok
        (List.find_opt
           (fun (entry : Workspace_memory_log.change_entry) -> entry.seq = seq)
           report.committed_changes))
