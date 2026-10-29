(* TUI settings read from the [tui] table of runtime.toml. The server reads the
   rest of that file for its own turn/provider config; the TUI reads only the
   handful of keys it draws, so this stays a small client-side read rather than
   a round-trip through the server. One read supplies all startup choices.
   The path is resolved the same way
   keeper_runtime_config resolves it, so both processes read one file. *)

type opening = Overview | Last of Keeper_id.Keeper_name.t option | Keeper of Keeper_id.Keeper_name.t

type t = {
  opening : (opening, string) result;
  last_chat_keeper : (Keeper_id.Keeper_name.t option, string) result;
  theme : string option;
  language : string option;
  board_sort : string option;
  keeper_list_sort : string option;
  keeper_list_layout : string option;
  keeper_list_error : string option;
  candle : string option;
  reduce_motion : bool option;
  lift_colours : bool option;
  table_frame : bool option;
  hints_visible : bool option;
  help_hint_shown : bool option;
  coalesce_queued_input : bool option;
  send_on_stop : bool option;
  user_input_priority_next : bool option;
  midi_soundfont : string option;
  audio_input_device : string option;
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

(* The reader's chosen theme name, [tui].theme. Kept pure so a test can hand it
   a parsed doc without a file: every absence -- file gone, table missing, key
   missing -- reads the same as "no stored choice", and the caller then follows
   the terminal exactly as it did before this key existed. *)
(* The [[tui]] table of runtime.toml, spelled once (#39539). *)
let tui_table = Runtime_toml_namespace.(key Tui)

let theme_of_doc doc = Keeper_toml_loader.toml_string_opt doc (tui_table ^ ".theme")

let language_of_doc doc = Keeper_toml_loader.toml_string_opt doc (tui_table ^ ".language")

let opening_keeper_of_doc doc =
  match List.assoc_opt (tui_table ^ ".opening_keeper") doc with
  | None -> Ok None
  | Some (Keeper_toml_loader.Toml_string name) ->
    (match Keeper_id.Keeper_name.of_string name with
     | Ok name -> Ok (Some name)
     | Error reason -> Error ("Invalid [tui].opening_keeper: " ^ reason))
  | Some (Keeper_toml_loader.Toml_int _) | Some (Keeper_toml_loader.Toml_float _)
  | Some (Keeper_toml_loader.Toml_bool _) | Some (Keeper_toml_loader.Toml_string_array _)
  | Some (Keeper_toml_loader.Toml_array _) | Some (Keeper_toml_loader.Toml_table _)
  | Some (Keeper_toml_loader.Toml_inline_table _) | Some (Keeper_toml_loader.Toml_table_array _)
  | Some (Keeper_toml_loader.Toml_offset_datetime _)
  | Some (Keeper_toml_loader.Toml_local_datetime _) | Some (Keeper_toml_loader.Toml_local_date _)
  | Some (Keeper_toml_loader.Toml_local_time _) -> Error "[tui].opening_keeper must be a Keeper name string"

let last_chat_keeper_of_doc doc =
  match List.assoc_opt (tui_table ^ ".last_chat_keeper") doc with
  | None -> Ok None
  | Some (Keeper_toml_loader.Toml_string name) ->
      (match Keeper_id.Keeper_name.of_string name with
       | Ok name -> Ok (Some name)
       | Error reason -> Error ("Invalid [tui].last_chat_keeper: " ^ reason))
  | Some (Keeper_toml_loader.Toml_int _) | Some (Keeper_toml_loader.Toml_float _)
  | Some (Keeper_toml_loader.Toml_bool _) | Some (Keeper_toml_loader.Toml_string_array _)
  | Some (Keeper_toml_loader.Toml_array _) | Some (Keeper_toml_loader.Toml_table _)
  | Some (Keeper_toml_loader.Toml_inline_table _) | Some (Keeper_toml_loader.Toml_table_array _)
  | Some (Keeper_toml_loader.Toml_offset_datetime _)
  | Some (Keeper_toml_loader.Toml_local_datetime _) | Some (Keeper_toml_loader.Toml_local_date _)
  | Some (Keeper_toml_loader.Toml_local_time _) -> Error "[tui].last_chat_keeper must be a Keeper name string"

let opening_of_doc doc =
  match List.assoc_opt (tui_table ^ ".opening") doc with
  | None | Some (Keeper_toml_loader.Toml_string "overview") -> Ok Overview
  | Some (Keeper_toml_loader.Toml_string "last") ->
    (match last_chat_keeper_of_doc doc with
     | Ok (Some name) -> Ok (Last (Some name))
     | Ok None -> Result.map (fun name -> Last name) (opening_keeper_of_doc doc)
     | Error reason -> Error reason)
  | Some (Keeper_toml_loader.Toml_string "keeper") ->
    (match opening_keeper_of_doc doc with
     | Ok (Some name) -> Ok (Keeper name)
     | Ok None -> Error "[tui].opening = keeper needs opening_keeper"
     | Error reason -> Error reason)
  | Some (Keeper_toml_loader.Toml_string value) ->
    Error ("Unknown [tui].opening: " ^ value)
  | Some (Keeper_toml_loader.Toml_int _) | Some (Keeper_toml_loader.Toml_float _)
  | Some (Keeper_toml_loader.Toml_bool _) | Some (Keeper_toml_loader.Toml_string_array _)
  | Some (Keeper_toml_loader.Toml_array _) | Some (Keeper_toml_loader.Toml_table _)
  | Some (Keeper_toml_loader.Toml_inline_table _) | Some (Keeper_toml_loader.Toml_table_array _)
  | Some (Keeper_toml_loader.Toml_offset_datetime _)
  | Some (Keeper_toml_loader.Toml_local_datetime _) | Some (Keeper_toml_loader.Toml_local_date _)
  | Some (Keeper_toml_loader.Toml_local_time _) -> Error "[tui].opening must be overview, last, or keeper"

(* Remember a chat target only when [opening] is [Last] and the target
   changes. The edit shares Runtime's config write lock with other settings. *)
let text_with_opening_keeper content ~keeper =
  Toml_line_editor.edit_table_scalar content ~path:tui_table ~key:"opening_keeper"
    ~value:(Some (Keeper_id.Keeper_name.to_string keeper))

let record_chat_visit ~base_path keeper =
  match
    Runtime.edit_config_text
      ~runtime_config_path:(runtime_toml_path ~base_path)
      (fun content ->
         let content =
           Toml_line_editor.edit_table_scalar content ~path:tui_table
             ~key:"last_chat_keeper"
             ~value:(Some (Keeper_id.Keeper_name.to_string keeper))
         in
         match Keeper_toml_loader.parse_toml content with
         | Ok doc ->
             (match opening_of_doc doc with
              | Ok (Last _) -> text_with_opening_keeper content ~keeper
              | Ok (Overview | Keeper _) | Error _ -> content)
         | Error _ -> content)
  with
  | Ok (receipt : Runtime.config_commit_receipt) -> Ok receipt.durability
  | Error message -> Error message

let text_with_theme content ~theme =
  Toml_line_editor.edit_table_scalar content ~path:tui_table ~key:"theme" ~value:theme

(* Store [theme] in the same runtime.toml [load] reads. Runtime does the
   load, the edit and the write under one lock, so the keeper assignment an
   operator changes from the dashboard at that moment is not lost.

   The error is returned rather than swallowed: by the time this is called the
   scheme is already on the screen, so a reader who is not told would take the
   screen as proof it was stored and find the old one back after a restart. *)
let set_theme ~base_path theme =
  match
    Runtime.edit_config_text
      ~runtime_config_path:(runtime_toml_path ~base_path)
      (fun content -> text_with_theme content ~theme)
  with
  | Ok (receipt : Runtime.config_commit_receipt) -> Ok receipt.ignored_legacy_keys
  | Error message -> Error message

(* [set_theme] now returns the legacy keys the committed file still carries.
   A save that lands must still tell the reader them: the key is inert from
   this commit on, and the reader is the one who has to decide whether to
   clean it up. The message is one line -- the state bar is one line. *)

let text_with_language content ~language =
  Toml_line_editor.edit_table_scalar content ~path:tui_table ~key:"language"
    ~value:(Some language)

(* Store [language] ("ko" or "en") in the same runtime.toml [load] reads,
   under the same write lock as the theme pick. Unlike the theme there is no
   legacy-keys receipt: the key is new, so nothing old can shadow it.

   The error is returned rather than swallowed: by the time this is called
   the language is already on the screen, so a reader who is not told would
   take the screen as proof it was stored and find the old one back after a
   restart. *)
let set_language ~base_path language =
  match
    Runtime.edit_config_text
      ~runtime_config_path:(runtime_toml_path ~base_path)
      (fun content -> text_with_language content ~language)
  with
  | Ok (_ : Runtime.config_commit_receipt) -> Ok ()
  | Error message -> Error message

(* Whether masc lifts colours the reader's theme leaves under the readable
   floor, [tui].lift_colours. Absent reads as "yes", which is what masc did
   before the key existed.

   The lift is there to rescue a theme whose colours are too dim to read on
   its own background. A reader who picked a high-contrast scheme has already
   solved that, and for them the lift is not a rescue but a distortion: it
   moves a colour the scheme's author placed deliberately. Turning it off is
   also what every other terminal UI does -- ratatui, tcell and lipgloss emit
   the code and let the terminal decide -- so this is the setting that makes
   masc behave the ordinary way.

   Off has a cost worth naming: masc says some things with colour alone, and
   on a scheme that leaves those colours dim they stop being read. That is the
   reader's call to make, which is the point of the key. *)
let lift_colours_of_doc doc = Keeper_toml_loader.toml_bool_opt doc (tui_table ^ ".lift_colours")

(* Whether tables draw their outer box, [tui].table_frame. Absent reads as
   "no", which is what the pane drew before the key existed: the box is paid
   for out of the columns, and taking a cell of content from a reader who did
   not ask is the change that needs the stronger reason. *)
let table_frame_of_doc doc = Keeper_toml_loader.toml_bool_opt doc (tui_table ^ ".table_frame")

let reduce_motion_of_doc doc =
  Keeper_toml_loader.toml_bool_opt doc (tui_table ^ ".reduce_motion")

(* Whether footers spell their key hints, [tui].hints_visible. Absent reads
   as "yes" -- the hints predate the key, and a reader who never set it must
   see no change. Off trades the hint text for status room: the tail
   (port, build, worktree/generation warnings) gets the whole row, and a
   long hint list stops being cell-truncated. "?:help" stays, because the
   reader who turned hints off still needs the door back. *)
let hints_visible_of_doc doc =
  Keeper_toml_loader.toml_bool_opt doc (tui_table ^ ".hints_visible")

(* Whether the opening screen's help-door line has already been shown,
   [tui].help_hint_shown. Absent reads as "no" on purpose: the line exists
   for the operator who has met none of this yet, and a reader who has been
   running masc for a year still meets it exactly once. *)
let help_hint_shown_of_doc doc =
  Keeper_toml_loader.toml_bool_opt doc (tui_table ^ ".help_hint_shown")

(* Whether a line typed while an earlier one is still waiting joins that line
   instead of queueing behind it, [tui].coalesce_queued_input. Absent reads as
   "no" so separate sends retain their identities.

   A queued line has not been sent yet -- dispatch takes it out of the queue --
   so joining two of them changes what one turn receives, not what a turn in
   flight sees. An operator who wants several separate Enter sends treated as
   one message can opt in; otherwise each send retains its own request id. *)
let coalesce_queued_input_of_doc doc =
  Keeper_toml_loader.toml_bool_opt doc (tui_table ^ ".coalesce_queued_input")

let user_input_priority_next_of_doc doc =
  Keeper_toml_loader.toml_bool_opt doc (tui_table ^ ".user_input_priority_next")

(* Whether ^Y ending a capture also sends what was heard,
   [voice.stt].send_on_stop. Absent reads as off, unlike its siblings here:
   they choose between two ways of showing the same thing, and this one sends
   a message without the operator confirming it. The draft is also where a
   spoken half-sentence waits for typing, so the default keeps the step that
   operator uses.

   Read through [Voice_config], not as a raw [tui] key. The setting lived in
   two places at once: [voice.stt].send_on_stop was parsed, published by
   [GET /api/v1/voice/config] and by the voice setup route, and read by
   nothing, while this file read a [tui].voice_send_on_stop that no surface
   published. An operator who set the documented one got silence. One
   spelling now, and it is the one on the wire -- which is also the one the
   voice setup routes write, so a surface that configures voice can reach it.

   A [voice] section that does not parse reads as off rather than as an error
   here: the TUI is not where a broken voice config is reported (the speak and
   transcribe paths carry that, by name), and off is the direction that does
   not send a message nobody confirmed. *)
let send_on_stop_of_text text =
  match Voice_config.parse_runtime_toml_text text with
  | Ok (Some config) ->
    Option.map (fun stt -> stt.Voice_config.send_on_stop) config.Voice_config.stt
  | Ok None | Error _ -> None

(* The input device captures open, [tui].audio_input_device. Pure, so a test
   can hand it a parsed doc without a file; absent reads as "no stored pick",
   the same way theme reads, and so does a blank value: the changelog's "set
   it to \"\"" turns the pick off, and a blank name passed on would reach the
   recorder as an empty AUDIODEV. *)
let audio_input_device_of_doc doc =
  match Keeper_toml_loader.toml_string_opt doc (tui_table ^ ".audio_input_device") with
  | Some device when String.trim device <> "" -> Some (String.trim device)
  | Some _ | None -> None

let load ~base_path =
  let path = runtime_toml_path ~base_path in
  (* One read of the file, two parsers over it: the [tui] keys through the
     loader this file has always used, and the voice one through the parser
     that owns that section's schema. Reading the voice field by raw path
     would be a second definition of it, which is how it came to have two. *)
  let text_reading =
    match Unix.stat path with
    | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> Ok None
    | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
    | _ ->
        (try Ok (Some (Fs_compat.load_file path))
         with Sys_error reason -> Error reason)
  in
  let doc_reading =
    match text_reading with
    | Ok None -> Ok None
    | Error reason -> Error reason
    | Ok (Some text) -> Result.map Option.some (Keeper_toml_loader.parse_toml text)
  in
  let text = match text_reading with Ok text -> text | Error _ -> None in
  let doc = match doc_reading with Ok doc -> doc | Error _ -> None
  in
  let read extract = Option.bind doc extract in
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
  let keeper_list_layout, layout_error = keeper_read "layout" in
  let container_error =
    match keeper_preferences with
    | Ok (Some doc) when Option.is_some (List.assoc_opt "keepers" doc) ->
        Some "keepers must be a [keepers] table"
    | Ok (Some _) | Ok None | Error _ -> None in
  let keeper_list_errors =
    (match keeper_preferences with Ok _ -> [] | Error reason -> [reason])
    @ Option.to_list container_error @ Option.to_list sort_error @ Option.to_list layout_error in
  { opening =
      (match doc with
       | Some doc -> opening_of_doc doc
       | None -> Ok Overview);
    last_chat_keeper =
      (match doc_reading with
       | Ok (Some doc) -> last_chat_keeper_of_doc doc
       | Ok None -> Ok None
       | Error reason -> Error ("Conversation history unavailable: " ^ reason));
    theme = read theme_of_doc;
    language = read language_of_doc;
    board_sort = read (fun doc -> Keeper_toml_loader.toml_string_opt doc (tui_table ^ ".board_sort"));
    keeper_list_sort;
    keeper_list_layout;
    keeper_list_error = (match keeper_list_errors with [] -> None | errors -> Some (String.concat "; " errors));
    candle = read (fun doc -> Keeper_toml_loader.toml_string_opt doc (tui_table ^ ".candle"));
    reduce_motion = read reduce_motion_of_doc;
    lift_colours = read lift_colours_of_doc;
    table_frame = read table_frame_of_doc;
    hints_visible = read hints_visible_of_doc;
    help_hint_shown = read help_hint_shown_of_doc;
    coalesce_queued_input = read coalesce_queued_input_of_doc;
    send_on_stop = Option.bind text send_on_stop_of_text;
    user_input_priority_next = read user_input_priority_next_of_doc;
    midi_soundfont =
      read (fun doc ->
          Keeper_toml_loader.toml_string_opt doc (tui_table ^ ".midi_soundfont"));
    audio_input_device = read audio_input_device_of_doc;
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

let prepare_startup_read ~sw ~base_path =
  let started_ns = Mtime_clock.elapsed_ns () in
  startup_read_event ~started_ns ~phase:"requested";
  let read () =
    match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      let reader_entered_ns = Mtime_clock.elapsed_ns () in
      startup_read_event ~started_ns ~phase:"reader_entered";
      match load ~base_path with
      | settings ->
          let reader_returned_ns = Mtime_clock.elapsed_ns () in
          startup_read_event ~started_ns ~phase:"reader_returned";
          { settings; reader_entered_ns; reader_returned_ns }
      | exception exn ->
          let bt = Printexc.get_raw_backtrace () in
          startup_read_event ~started_ns
            ~phase:(match exn with Eio.Cancel.Cancelled _ -> "reader_interrupted" | _ -> "reader_raised");
          Printexc.raise_with_backtrace exn bt) with
    | snapshot ->
        startup_read_event ~started_ns ~phase:"submission_observed";
        snapshot
    | exception exn ->
        let bt = Printexc.get_raw_backtrace () in
        startup_read_event ~started_ns
          ~phase:(match exn with Eio.Cancel.Cancelled _ -> "submission_interrupted" | _ -> "submission_raised");
        Printexc.raise_with_backtrace exn bt in
  let result = match sw with
    | Some sw ->
        Eio.Switch.check sw;
        Eio.Fiber.fork_promise ~sw read
    | None ->
        Eio.Promise.create_resolved (Ok (read ())) in
  { started_ns; result }

let set_tui_string ~base_path ~key value =
  match Runtime.edit_config_text
      ~runtime_config_path:(runtime_toml_path ~base_path)
      (fun content -> Toml_line_editor.edit_table_scalar content
          ~path:tui_table ~key ~value:(Some value)) with
  | Ok (_ : Runtime.config_commit_receipt) -> Ok ()
  | Error message -> Error message

let set_board_sort ~base_path sort = set_tui_string ~base_path ~key:"board_sort" sort

let set_keeper_list_preference ~base_path ~key value =
  let path = keeper_preferences_path ~base_path in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    match File_lock_eio.try_with_durable_lock_observed ~lock_path:(path ^ ".lock") (fun () ->
      let ( let* ) = Result.bind in
      let* existing = read_keeper_preferences path in
      let content = Option.value existing ~default:"" in
      let* original = Keeper_toml_loader.parse_toml content in
      let edited = Toml_line_editor.edit_table_scalar content ~path:"keepers" ~key ~value:(Some value) in
      let* updated = Keeper_toml_loader.parse_toml edited in
      let other = if String.equal key "sort" then "keepers.layout" else "keepers.sort" in
      let* () =
        if Keeper_toml_loader.toml_string_opt updated ("keepers." ^ key) = Some value
           && List.assoc_opt other original = List.assoc_opt other updated then Ok ()
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

let set_keeper_list_sort ~base_path sort = set_keeper_list_preference ~base_path ~key:"sort" sort
let set_keeper_list_layout ~base_path layout = set_keeper_list_preference ~base_path ~key:"layout" layout

type keeper_preference = Keeper_order of string | Keeper_view of string
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
            | Keeper_view value -> set_keeper_list_layout ~base_path:request.base_path value)) in
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
let set_candle ~base_path candle = set_tui_string ~base_path ~key:"candle" candle

let text_with_audio_input_device content ~device =
  Toml_line_editor.edit_table_scalar content
    ~path:tui_table ~key:"audio_input_device" ~value:device

(* Store the input device captures open, [tui].audio_input_device, in the same
   runtime.toml {!load} reads and under the same write lock as the theme pick.
   [None] withdraws a stored device, so captures go back to whatever the
   operating system calls the default input. The error is returned rather than
   swallowed: the next capture opens on whatever the file still says, and an
   operator who is not told would take the notice as proof it was stored. *)
let set_audio_input_device ~base_path device =
  match
    Runtime.edit_config_text
      ~runtime_config_path:(runtime_toml_path ~base_path)
      (fun content -> text_with_audio_input_device content ~device)
  with
  | Ok (_ : Runtime.config_commit_receipt) -> Ok ()
  | Error message -> Error message

(* [tui].help_hint_shown = true, written once when the first input retires
   the opening screen's help-door line, under the same lock and in the same
   file as the writers above. A bare boolean, not a quoted string: the
   reader is [toml_bool_opt] and refuses "true" the way any typed reader
   does. *)
let set_help_hint_shown ~base_path =
  match Runtime.edit_config_text
      ~runtime_config_path:(runtime_toml_path ~base_path)
      (fun content ->
        Toml_line_editor.edit_table_bool content
          ~path:tui_table ~key:"help_hint_shown" ~value:true)
  with
  | Ok (_ : Runtime.config_commit_receipt) -> Ok ()
  | Error message -> Error message
