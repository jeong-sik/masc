(* TUI settings read from the [tui] table of runtime.toml. The server reads the
   rest of that file for its own turn/provider config; the TUI reads only the
   handful of keys it draws, so this stays a small client-side read rather than
   a round-trip through the server. One read supplies all startup choices.
   The path is resolved the same way
   keeper_runtime_config resolves it, so both processes read one file. *)

type t = {
  theme : string option;
  board_sort : string option;
  lift_colours : bool option;
  table_frame : bool option;
  hints_visible : bool option;
  coalesce_queued_input : bool option;
  send_on_stop : bool option;
}

let runtime_toml_path ~base_path =
  let inputs = Config_dir_resolver.inputs_from_env () in
  let resolution =
    Config_dir_resolver.resolve_with { inputs with env_base_path = Some base_path }
  in
  Filename.concat resolution.Config_dir_resolver.config_root.path
    Config_dir_resolver.runtime_toml_filename

(* The reader's chosen theme name, [tui].theme. Kept pure so a test can hand it
   a parsed doc without a file: every absence -- file gone, table missing, key
   missing -- reads the same as "no stored choice", and the caller then follows
   the terminal exactly as it did before this key existed. *)
let theme_of_doc doc = Keeper_toml_loader.toml_string_opt doc "tui.theme"

(* The writer for the one key above that changes while masc runs. The other
   settings in this file are read once at boot and never moved from inside
   the TUI, so they have nothing to store; the theme is picked on a pane, and
   a pick that does not survive a restart is not a setting.

   [None] withdraws the choice: the key is removed rather than set to a name
   meaning "the terminal's", because absence is the state the reader is going
   back to -- the same absence [load] reads as "no stored choice".

   Pure, and deliberately spelled in the editor's table-and-key form while
   [theme_of_doc] reads the loader's dotted form. The two grammars are not
   the same, so nothing can be shared between them; what proves they meet is
   the round trip in test_tui_config.ml. *)
let text_with_theme content ~theme =
  Toml_line_editor.edit_table_scalar content ~path:"tui" ~key:"theme" ~value:theme

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
let lift_colours_of_doc doc = Keeper_toml_loader.toml_bool_opt doc "tui.lift_colours"

(* Whether tables draw their outer box, [tui].table_frame. Absent reads as
   "no", which is what the pane drew before the key existed: the box is paid
   for out of the columns, and taking a cell of content from a reader who did
   not ask is the change that needs the stronger reason. *)
let table_frame_of_doc doc = Keeper_toml_loader.toml_bool_opt doc "tui.table_frame"

(* Whether footers spell their key hints, [tui].hints_visible. Absent reads
   as "yes" -- the hints predate the key, and a reader who never set it must
   see no change. Off trades the hint text for status room: the tail
   (port, build, worktree/generation warnings) gets the whole row, and a
   long hint list stops being cell-truncated. "?:help" stays, because the
   reader who turned hints off still needs the door back. *)
let hints_visible_of_doc doc =
  Keeper_toml_loader.toml_bool_opt doc "tui.hints_visible"

(* Whether a line typed while an earlier one is still waiting joins that line
   instead of queueing behind it, [tui].coalesce_queued_input. Absent reads as
   "yes".

   A queued line has not been sent yet -- dispatch takes it out of the queue --
   so joining two of them changes what one turn receives, not what a turn in
   flight sees. The reader who types a thought, then its correction, then the
   part they forgot, means one message; queueing them separately spends a turn
   on each and lets the Keeper answer the first before the rest arrive.

   Off keeps every line its own turn, which is what a reader wants when the
   lines really are separate errands. *)
let coalesce_queued_input_of_doc doc =
  Keeper_toml_loader.toml_bool_opt doc "tui.coalesce_queued_input"

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

let load ~base_path =
  let path = runtime_toml_path ~base_path in
  (* One read of the file, two parsers over it: the [tui] keys through the
     loader this file has always used, and the voice one through the parser
     that owns that section's schema. Reading the voice field by raw path
     would be a second definition of it, which is how it came to have two. *)
  let text = try Some (Fs_compat.load_file path) with Sys_error _ -> None in
  let doc = Option.bind text (fun text ->
    match Keeper_toml_loader.parse_toml text with
    | Ok doc -> Some doc
    | Error _ -> None)
  in
  let read extract = Option.bind doc extract in
  { theme = read theme_of_doc;
    board_sort = read (fun doc -> Keeper_toml_loader.toml_string_opt doc "tui.board_sort");
    lift_colours = read lift_colours_of_doc;
    table_frame = read table_frame_of_doc;
    hints_visible = read hints_visible_of_doc;
    coalesce_queued_input = read coalesce_queued_input_of_doc;
    send_on_stop = Option.bind text send_on_stop_of_text;
  }

let set_board_sort ~base_path sort =
  match Runtime.edit_config_text
      ~runtime_config_path:(runtime_toml_path ~base_path)
      (fun content -> Toml_line_editor.edit_table_scalar content
          ~path:"tui" ~key:"board_sort" ~value:(Some sort)) with
  | Ok (_ : Runtime.config_commit_receipt) -> Ok ()
  | Error message -> Error message
