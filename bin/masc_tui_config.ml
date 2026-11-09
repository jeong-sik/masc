(* What a terminal reader starts with. The [tui] settings come from the
   server, which is also where the terminal's picks are written (RFC-0482
   §3.1), so the two cannot part over which runtime.toml each process finds.
   The Keeper list's order and view are this terminal's own presentation and
   stay in [tui-keepers.toml] beside its runtime.toml. *)

type opening = Masc.Tui_preference.opening =
  | Overview
  | Last of Keeper_id.Keeper_name.t option
  | Keeper of Keeper_id.Keeper_name.t

type t = {
  stored : Masc.Tui_preference.settings;
  settings_unread : string option;
  keeper_list_sort : string option;
  keeper_list_view : string option;
  keeper_list_density : string option;
  keeper_list_error : string option;
}

let runtime_toml_path ~base_path =
  let inputs = Config_dir_resolver.inputs_from_env () in
  let resolution =
    Config_dir_resolver.resolve_with { inputs with env_base_path = Some base_path }
  in
  Filename.concat resolution.Config_dir_resolver.config_root.path
    Config_dir_resolver.runtime_toml_filename

(* List choices are local presentation state, so they do not require a
   runtime configuration or change the server's runtime registry. *)
let keeper_preferences_path ~base_path =
  Filename.concat (Filename.dirname (runtime_toml_path ~base_path)) "tui-keepers.toml"

let read_keeper_preferences path =
  (* Atomic replacement acts on the pathname itself. Following a symlink here
     would replace that link on save, rather than updating its target. *)
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  | { Unix.st_kind = Unix.S_REG; _ } ->
      (try Ok (Some (Fs_compat.load_file path))
       with Sys_error reason -> Error reason)
  | { Unix.st_kind = (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK
                     | Unix.S_FIFO | Unix.S_SOCK); _ } ->
      Error "Keeper preference path is not a regular file"

let of_settings ~base_path reading =
  let (settings : Masc.Tui_preference.settings), settings_unread =
    match reading with
    | Ok settings -> settings, None
    | Error reason ->
        (* Unread settings start every pick at its default, but the last
           conversation stays unread rather than shown as none. *)
        { (Masc.Tui_preference.settings_of_reading (Ok None)) with
          Masc.Tui_preference.last_chat_keeper = Error reason },
        Some reason
  in
  let keeper_preferences =
    match read_keeper_preferences (keeper_preferences_path ~base_path) with
    | Ok None -> Ok None
    | Error reason -> Error reason
    | Ok (Some text) -> Result.map Option.some (Keeper_toml_loader.parse_toml text)
  in
  let keeper_read key =
    match keeper_preferences with
    | Ok (Some doc) ->
        (match List.assoc_opt ("keepers." ^ key) doc with
         | None -> None, None
         | Some (Keeper_toml_loader.Toml_string value) -> Some value, None
         | Some (Keeper_toml_loader.Toml_int _ | Keeper_toml_loader.Toml_float _
                | Keeper_toml_loader.Toml_bool _ | Keeper_toml_loader.Toml_string_array _
                | Keeper_toml_loader.Toml_array _ | Keeper_toml_loader.Toml_table _
                | Keeper_toml_loader.Toml_inline_table _ | Keeper_toml_loader.Toml_table_array _
                | Keeper_toml_loader.Toml_offset_datetime _ | Keeper_toml_loader.Toml_local_datetime _
                | Keeper_toml_loader.Toml_local_date _ | Keeper_toml_loader.Toml_local_time _) ->
             None, Some ("keepers." ^ key ^ " must be a string"))
    | Ok None | Error _ -> None, None
  in
  let keeper_list_sort, sort_error = keeper_read "sort" in
  let keeper_list_view, view_error = keeper_read "view" in
  let keeper_list_density, density_error = keeper_read "density" in
  let container_error =
    match keeper_preferences with
    | Ok (Some doc) when Option.is_some (List.assoc_opt "keepers" doc) ->
        Some "keepers must be a [keepers] table"
    | Ok (Some _) | Ok None | Error _ -> None in
  let keeper_list_errors =
    (match keeper_preferences with Ok _ -> [] | Error reason -> [reason])
    @ Option.to_list container_error @ Option.to_list sort_error
    @ Option.to_list view_error @ Option.to_list density_error in
  { stored = settings;
    settings_unread;
    keeper_list_sort;
    keeper_list_view;
    keeper_list_density;
    keeper_list_error = (match keeper_list_errors with [] -> None | errors -> Some (String.concat "; " errors));
  }

type startup_snapshot = {
  settings : t;
  reader_entered_ns : int64;
  reader_returned_ns : int64;
}
type startup_read = {
  started_ns : int64;
  result : startup_snapshot Eio.Promise.or_exn;
}

let startup_read_event ~started_ns ~phase =
  let at_ns = Mtime_clock.elapsed_ns () in
  let emit () = try Log.Transport.routine_lazy (fun () ->
      Printf.sprintf "tui_startup_settings phase=%s started_ns=%Ld at_ns=%Ld"
        phase started_ns at_ns) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> () in
  match Eio_guard.execution_context () with
  | Eio_fiber -> Eio.Cancel.protect emit
  | Non_eio -> emit ()

(* The settings read runs in its own fiber: it waits for this terminal's
   credential and asks the server, while independent terminal initialization
   goes on. The Keeper list file is read on the I/O pool. A failed settings
   read opens on the defaults and says why once the screen is up; a value that
   arrives later never replaces a choice the reader has made meanwhile. *)
let prepare_startup_read ~sw ~base_path ~read_settings =
  let started_ns = Mtime_clock.elapsed_ns () in
  startup_read_event ~started_ns ~phase:"requested";
  let read () =
    let reader_entered_ns = Mtime_clock.elapsed_ns () in
    startup_read_event ~started_ns ~phase:"reader_entered";
    match
      let reading = read_settings () in
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () -> of_settings ~base_path reading)
    with
    | settings ->
      let reader_returned_ns = Mtime_clock.elapsed_ns () in
      startup_read_event ~started_ns ~phase:"reader_returned";
      { settings; reader_entered_ns; reader_returned_ns }
    | exception exn ->
      let bt = Printexc.get_raw_backtrace () in
      startup_read_event ~started_ns
        ~phase:(match exn with Eio.Cancel.Cancelled _ -> "reader_interrupted" | _ -> "reader_raised");
      Printexc.raise_with_backtrace exn bt
  in
  let result =
    match sw with
    | Some sw ->
      Eio.Switch.check sw;
      Eio.Fiber.fork_promise ~sw read
    | None -> Eio.Promise.create_resolved (Ok (read ()))
  in
  { started_ns; result }

let keeper_preference_keys = [ "sort"; "view"; "density" ]

(* [choices] are written together under one lock; every other choice of the
   file must read the same after the edit. *)
let set_keeper_list_preference ~base_path choices =
  let path = keeper_preferences_path ~base_path in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    match File_lock_eio.try_with_durable_lock_observed ~lock_path:(path ^ ".lock") (fun () ->
      let ( let* ) = Result.bind in
      let* existing = read_keeper_preferences path in
      let content = Option.value existing ~default:"" in
      let* original = Keeper_toml_loader.parse_toml content in
      let edited =
        List.fold_left
          (fun text (key, value) ->
            Toml_line_editor.edit_table_scalar text ~path:"keepers" ~key ~value:(Some value))
          content choices
      in
      let* updated = Keeper_toml_loader.parse_toml edited in
      let written (key, value) =
        Keeper_toml_loader.toml_string_opt updated ("keepers." ^ key) = Some value in
      let kept key =
        List.mem_assoc key choices
        || List.assoc_opt ("keepers." ^ key) original = List.assoc_opt ("keepers." ^ key) updated in
      let* () =
        if List.for_all written choices && List.for_all kept keeper_preference_keys then Ok ()
        else Error "preference edit did not preserve the other choice" in
      Fs_compat.save_file_atomic_strict_staged path edited
      |> Result.map_error Fs_compat.atomic_replace_failure_to_string) with
    | File_lock_eio.Lock_held_elsewhere -> Error "preference file is being updated elsewhere"
    | File_lock_eio.Lock_attempted (File_lock_eio.Lock_not_acquired error) -> Error (File_lock_eio.durable_lock_error_to_string error)
    | File_lock_eio.Lock_attempted (File_lock_eio.Body_completed { value = Error reason; release_error = _ }) -> Error reason
    | File_lock_eio.Lock_attempted (File_lock_eio.Body_completed { value = Ok (); release_error = Some error }) ->
        Error ("preference written; lock release unconfirmed: " ^ File_lock_eio.durable_lock_error_to_string error)
    | File_lock_eio.Lock_attempted (File_lock_eio.Body_completed { value = Ok (); release_error = None }) -> Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error reason -> Error reason
  | Unix.Unix_error (error, operation, _) -> Error (operation ^ ": " ^ Unix.error_message error)

let set_keeper_list_sort ~base_path sort = set_keeper_list_preference ~base_path [ "sort", sort ]

let set_keeper_list_view ~base_path ~view ~density =
  set_keeper_list_preference ~base_path [ "view", view; "density", density ]

type keeper_preference =
  | Keeper_order of string
  | Keeper_view of { view : string; density : string }
type keeper_preference_outcome =
  | Preference_saved
  | Preference_unconfirmed of string
  | Preference_not_started of string
type keeper_preference_completion = {
  request_id : int;
  preference : keeper_preference;
  outcome : keeper_preference_outcome;
}
type preference_request = { request_id : int; base_path : string; preference : keeper_preference }
type preference_writer_phase = Writer_open | Writer_closing | Writer_closed
type keeper_preference_writer = {
  pending_preferences : preference_request Queue.t;
  completed_preferences : keeper_preference_completion Queue.t;
  mutable preference_writer_phase : preference_writer_phase;
  mutable preference_writer_idle : unit Eio.Promise.t option;
  mutable preference_next_request_id : int;
}

let create_keeper_preference_writer () =
  { pending_preferences = Queue.create (); completed_preferences = Queue.create ();
    preference_writer_phase = Writer_open; preference_writer_idle = None;
    preference_next_request_id = 0 }

let publish_preference writer (request : preference_request) outcome =
  Queue.add { request_id = request.request_id; preference = request.preference; outcome }
    writer.completed_preferences

let refuse_pending_preferences writer reason =
  Queue.iter (fun request -> publish_preference writer request (Preference_not_started reason))
    writer.pending_preferences;
  Queue.clear writer.pending_preferences

let rec run_keeper_preference_writer writer =
  Eio.Fiber.check ();
  match Queue.take_opt writer.pending_preferences with
  | None -> ()
  | Some request ->
      let outcome =
        try
          let result = Eio.Cancel.protect (fun () -> Eio_unix.run_in_systhread (fun () ->
            match request.preference with
            | Keeper_order value -> set_keeper_list_sort ~base_path:request.base_path value
            | Keeper_view { view; density } ->
                set_keeper_list_view ~base_path:request.base_path ~view ~density)) in
          (match result with Ok () -> Preference_saved | Error reason -> Preference_unconfirmed reason)
        with
        | Eio.Cancel.Cancelled _ as exn ->
            let bt = Printexc.get_raw_backtrace () in
            publish_preference writer request (Preference_unconfirmed "Preference save was interrupted");
            refuse_pending_preferences writer "Preference writer was cancelled before this choice started";
            Printexc.raise_with_backtrace exn bt
        | exn -> Preference_unconfirmed (Printexc.to_string exn)
      in
      publish_preference writer request outcome;
      run_keeper_preference_writer writer

let start_keeper_preference_writer writer sw =
  let idle, resolve = Eio.Promise.create () in
  writer.preference_writer_idle <- Some idle;
  let entered = ref false in
  let finish () =
    writer.preference_writer_idle <- None;
    ignore (Eio.Promise.try_resolve resolve ()) in
  try
    Eio.Switch.check sw;
    Eio.Fiber.fork ~sw (fun () ->
      entered := true;
      Fun.protect ~finally:finish (fun () ->
        try
          Eio.Fiber.yield ();
          run_keeper_preference_writer writer
        with
        | Eio.Cancel.Cancelled _ as exn ->
            let bt = Printexc.get_raw_backtrace () in
            refuse_pending_preferences writer "Preference writer was cancelled before this choice started";
            Printexc.raise_with_backtrace exn bt));
    if not !entered then begin
      refuse_pending_preferences writer "Preference writer did not start";
      finish ()
    end
  with
  | Eio.Cancel.Cancelled _ as exn ->
      let bt = Printexc.get_raw_backtrace () in
      refuse_pending_preferences writer "Preference writer cancelled before launch";
      finish ();
      Printexc.raise_with_backtrace exn bt
  | exn ->
      refuse_pending_preferences writer ("Preference writer could not start: " ^ Printexc.to_string exn);
      finish ()

let submit_keeper_preference writer ~on_request_id ~sw ~base_path preference =
  let request_id = writer.preference_next_request_id in
  writer.preference_next_request_id <- request_id + 1;
  let request = { request_id; base_path; preference } in
  on_request_id request_id;
  (match writer.preference_writer_phase, sw with
   | (Writer_closing | Writer_closed), _ ->
       publish_preference writer request (Preference_not_started "Preference writer is closing")
   | Writer_open, None ->
       publish_preference writer request (Preference_not_started "Preference writer is unavailable")
   | Writer_open, Some sw ->
       Queue.add request writer.pending_preferences;
       if Option.is_none writer.preference_writer_idle then start_keeper_preference_writer writer sw);
  request_id

let drain_keeper_preferences writer ~can_take ~apply =
  let rec take remaining =
    if remaining > 0 && can_take () then
      match Queue.take_opt writer.completed_preferences with
      | None -> ()
      | Some result -> apply result; take (remaining - 1) in
  take (Queue.length writer.completed_preferences)

let close_keeper_preference_writer writer =
  writer.preference_writer_phase <- Writer_closing;
  Eio.Cancel.protect (fun () -> Option.iter Eio.Promise.await writer.preference_writer_idle);
  writer.preference_writer_phase <- Writer_closed
