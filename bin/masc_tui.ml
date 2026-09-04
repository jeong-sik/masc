open Masc_tui_types
open Masc_tui_ansi
open Masc_tui_render
open Masc_tui_loader

(* One place decides how an aborted $EDITOR form reads. Only the cancel
   differs by caller, because only the action's own name belongs in it; an
   editor that never ran and a temp file that could not be read are the same
   fact wherever they happen, and neither is the operator saying no. *)
let report_editor_abort state ~action ?cancelled (abort : Masc_tui_editor.abort)
  =
  match abort with
  | Masc_tui_editor.Cancelled ->
    report_action state "system"
      (match cancelled with Some text -> text | None -> action ^ " cancelled")
  | Masc_tui_editor.Editor_unavailable _ | Masc_tui_editor.Form_unreadable _ ->
    report_action state "error"
      (action ^ ": " ^ Masc_tui_editor.abort_detail abort)

module Approval = Masc_tui_operator_projection
module Board_detail = Masc_tui_board_detail
module Board_hearth = Masc_tui_board_hearth
module Board_selection = Masc_tui_board_selection
module Frame_presenter = Masc_tui_frame_presenter
module Approval_authority = Masc_tui_approval_authority
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_history = Masc_tui_keeper_chat_history
module Chat_queue = Masc_tui_keeper_chat_queue
module Keeper_chat_live = Masc_tui_keeper_chat_live
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Composer = Masc_tui_composer
module Composer_projection = Masc_tui_composer_projection
module Keeper_control = Masc_tui_keeper_control
module Ask = Masc_tui_ask_projection
module Metrics_tail = Masc_tui_metrics_tail
module Planning_selection = Masc_tui_planning_selection
module Render_schedule = Masc_tui_render_schedule
module Link = Masc_tui_link
module Terminal_profile = Masc_tui_terminal_profile
module Terminal_title = Masc_tui_terminal_title
module Terminal_write_repair = Masc_tui_terminal_write_repair

(* Tools rows are the exact projection the renderer draws, so their scroll
   bound belongs to that projection rather than a second reconstruction in
   the state module. Every other counted surface remains state-owned. *)
let scrolled_surface state surface =
  match surface with
  | Tools -> Some (Masc_tui_render.tools_scrolled state)
  | _ -> Masc_tui_types.scrolled_surface state surface
;;

(** Local exception for breaking the main TUI loop without using Exit. *)
exception Break

let json_assoc_member_opt = Masc_tui_json.member_opt

(** One 60 Hz frame window: bursts are coalesced without delaying an idle
    terminal's first changed frame. *)
let frame_interval_ns = 16_000_000L
let roster_marquee_interval_ns = 150_000_000L

(* Four frames at 150ms is one turn of the mark per 600ms: fast enough to
   read as alive, slow enough not to strobe. The same cadence as the marquee
   above, so the two moving things on a masc screen move at one speed. *)
let activity_interval_ns = 150_000_000L
(* What one wheel detent moves. Terminals report three lines per detent, so a
   notch here is worth what a notch is worth in a pager. *)
let wheel_notch_rows = 3

let maximum_input_wait_seconds = 0.016
let nanoseconds_per_second = 1_000_000_000.0

(* Point fd 2 at a file under the base path, so writing to stderr cannot land
   in the frame. Best effort by construction: a surface that cannot open its
   log is still a working surface, and refusing to start over it would trade a
   cosmetic fault for an outage. The failure is reported on the terminal that
   is about to be cleared, which is the last moment a person can see it. *)
let redirect_stderr_off_terminal ~base_path =
  match
    let dir =
      Filename.concat (Common.masc_dir_from_base_path ~base_path) "logs"
    in
    let path =
      Filename.concat dir (Printf.sprintf "masc-tui-%d.log" (Unix.getpid ()))
    in
    (* [O_CREAT] makes the file, not the directory above it. A base path that
       has never had a log written under it -- a fresh workspace, a test's
       temporary root -- therefore failed here on ENOENT, and the surface
       started with its stderr still on the terminal. That is the exact state
       this function exists to avoid, reached by the one cause it could have
       removed itself. *)
    Fs_compat.mkdir_p dir;
    let fd =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o644
    in
    (* No [Fun.protect] around the close: its [Finally_raised] is neither
       [Unix_error] nor [Sys_error], so a raising finaliser would leave this
       match and take the surface down over a descriptor. If [dup2] raises,
       one fd leaks in a process that is one line from reporting it. *)
    Unix.dup2 fd Unix.stderr;
    Unix.close fd;
    path
  with
  | path ->
      Log.Startup.info "stderr redirected to %s" path
  | exception (Unix.Unix_error _ | Sys_error _) ->
      (* Say so before the screen is taken: a surface drawing over a mirror it
         could not move is the state this whole path exists to avoid. *)
      prerr_endline
        "[masc-tui] could not redirect stderr off this terminal; log lines may \
         land in the drawn screen"

let require_interactive_terminal () =
  let term =
    Sys.getenv_opt "TERM"
    |> Option.value ~default:""
    |> String.lowercase_ascii
    |> String.trim
  in
  if
    (not (Unix.isatty Unix.stdin))
    || not (Unix.isatty Unix.stdout)
    || String.equal term "dumb"
  then begin
    prerr_endline
      "masc-tui requires interactive TTY stdin/stdout and TERM other than dumb";
    exit 2
  end

(* The bound comes from [scrolled_surface], which the drawing reads too, so a
   keypress cannot move past what the frame can show. Surfaces the state
   cannot count keep their old unbounded step; the drawing still clamps those
   on the way past. *)
(* The rows a surface's list actually draws in. A surface that puts a preview
   under its list says so in its [scrolled], and both movers ask here: a bound
   worked out from the full body while the frame draws half of it is not a
   bound, and the rows past the shortened list stop being reachable. *)
let surface_body_height ~rows
    { sc_count; sc_chrome; sc_overflow_takes_row; sc_preview_keep } =
  Masc_tui_scroll.content_height ~rows ~chrome:sc_chrome ~count:sc_count
    ~preview_keep:sc_preview_keep ~overflow_takes_row:sc_overflow_takes_row

let move_surface_scroll (state : state) ~rows ~delta ~current =
  match scrolled_surface state state.view with
  | None -> current + delta
  | Some scrolled ->
      let height = surface_body_height ~rows scrolled in
      if delta >= 0 then
        Masc_tui_scroll.down ~count:scrolled.sc_count ~height current
      else Masc_tui_scroll.up ~count:scrolled.sc_count ~height current

let move_surface_to_end (state : state) ~rows ~current =
  match scrolled_surface state state.view with
  | None -> current
  | Some scrolled ->
      let height = surface_body_height ~rows scrolled in
      Masc_tui_scroll.maximum ~count:scrolled.sc_count ~height

(* The rows a surface has to draw in. The same arithmetic the drawing does --
   a bound worked out from a different height than the frame uses is not a
   bound. Reading the terminal's own rows here, as this did, left the log
   surface's keypress bound one row looser than the frame it moved within, and
   subtracting only the composer left it one row looser again on every screen
   the agenda strip was on. Both readers now ask
   {!Masc_tui_types.surface_body_rows}. *)
let surface_rows (state : state) =
  let terminal_rows, _columns = get_terminal_size () in
  Masc_tui_types.surface_body_rows state ~terminal_rows

(* Page keys move almost one visible body, leaving a few rows of overlap so
   the reader keeps their place across the jump. Individual renderers clamp
   the result against their exact wrapped-line count. *)
let surface_page_rows (state : state) = max 1 (surface_rows state - 8)

let runtime_config_assignment_rows (state : state) =
  match state.runtime_config_view with
  | None -> []
  | Some (_, rows) ->
      rows
      |> List.filter_mapi (fun index row ->
             if Masc_tui_code_lexer.row_has_assignment row then Some index
             else None)

(* Pick an actual value row at or beyond [target] in the requested direction.
   The cursor never lands on a comment, table heading, or blank line; those
   rows stay visible as context around the selected field. *)
let runtime_config_row_near rows ~direction ~target =
  match rows with
  | [] -> 0
  | first :: _ when direction >= 0 ->
      Option.value ~default:(List.hd (List.rev rows))
        (List.find_opt (fun row -> row >= target) rows)
  | first :: _ ->
      List.fold_left
        (fun selected row -> if row <= target then row else selected)
        first rows

let set_runtime_config_cursor_near state ~direction ~target =
  let rows = runtime_config_assignment_rows state in
  let cursor = runtime_config_row_near rows ~direction ~target in
  state.runtime_config_cursor <- cursor;
  state.config_scroll <-
    Masc_tui_scroll.ensure_visible ~cursor
      ~height:(Masc_tui_render.config_content_height state)
      state.config_scroll

(* Resolve a server-owned runtime.toml table heading without reparsing TOML in
   the client. Callers supply the complete dotted table name; the raw source
   view remains the one authority for both what is shown and what $EDITOR
   later receives. *)
let runtime_config_section_line ~section rows =
  let header = "[" ^ section ^ "]" in
  let rec scan index = function
    | [] -> None
    | segments :: rest ->
      let text = String.trim (String.concat "" (List.map fst segments)) in
      if String.equal text header then Some index else scan (index + 1) rest
  in
  scan 0 rows

(* Consume a cross-surface source jump after runtime.toml has landed. The
   cursor itself stays on a value row, while the viewport leaves the table
   heading visible as context. *)
let apply_runtime_config_jump state =
  match state.runtime_config_jump_section, state.runtime_config_view with
  | Some section, Some (_, rows) ->
    state.runtime_config_jump_section <- None;
    state.config_pane <- Config_runtime;
    let found = runtime_config_section_line ~section rows in
    (match found with
     | Some index ->
       set_runtime_config_cursor_near state ~direction:1 ~target:index;
       state.config_scroll <- max 0 (index - 3)
     | None -> ());
    Some (section, Option.is_some found)
  | None, _ | Some _, None -> None

let move_runtime_config_cursor state ~delta =
  let direction = if delta >= 0 then 1 else -1 in
  set_runtime_config_cursor_near state ~direction
    ~target:(state.runtime_config_cursor + direction)

(* The columns the Identity pane wraps its notice at. Asked of the terminal
   the same way {!surface_rows} asks for its rows, so the key handler counts
   the lines the renderer is about to draw. *)
(* The query the list is showing, which is the empty one whenever the filter
   is not open. Asked here so the renderer, the cursor and the keys all read
   the same list. *)
let identity_query (state : state) =
  Option.value state.identity_filter ~default:""

let identity_pane_columns (state : state) =
  let _rows, columns = get_terminal_size () in
  Masc_tui_roster_pane.content_cols ~hidden:state.roster_pane_hidden
    ~cols:columns

(* A row cursor over a plain listing: the keypress moves the cursor and the
   window follows with the smallest move that keeps it visible. Reads the
   same [scrolled_surface] bound the drawing uses, so the cursor cannot name
   a row the frame will not draw. *)
let move_row_cursor (state : state) ~delta ~cursor ~scroll =
  match scrolled_surface state state.view with
  | None -> (cursor, scroll + delta)
  | Some ({ sc_count; _ } as scrolled) ->
      let height = surface_body_height ~rows:(surface_rows state) scrolled in
      let cursor =
        if delta >= 0 then Masc_tui_scroll.cursor_down ~count:sc_count cursor
        else Masc_tui_scroll.cursor_up ~count:sc_count cursor
      in
      (cursor, Masc_tui_scroll.ensure_visible ~cursor ~height scroll)

(* The Identity tab's provider list. The cursor names a provider while the
   pane scrolls lines, so the row kept visible is the line that provider is
   drawn on rather than the cursor itself -- the two differ by whatever the
   pane prints above the list, which is why that preamble is a value both
   sides read instead of a number each side counts. *)
let move_identity_cursor (state : state) ~delta =
  match state.identity_view with
  | None -> ()
  | Some (_, providers) ->
      let count =
        List.length
          (Masc_tui_types.identity_connectable ~query:(identity_query state)
             providers)
      in
      if count > 0 then begin
        let query = identity_query state in
        let cursor =
          Masc_tui_types.identity_cursor_clamped ~query ~providers
            state.identity_cursor
        in
        let cursor =
          if delta >= 0 then Masc_tui_scroll.cursor_down ~count cursor
          else Masc_tui_scroll.cursor_up ~count cursor
        in
        state.identity_cursor <- cursor;
        match scrolled_surface state state.view with
        | None -> ()
        | Some scrolled ->
            let height =
              surface_body_height ~rows:(surface_rows state) scrolled
            in
            state.detail_scroll <-
              Masc_tui_scroll.ensure_visible
                ~cursor:
                  (Masc_tui_types.identity_provider_line
                     ~notice:
                       (Masc_tui_types.identity_notice
                          ~cols:(identity_pane_columns state)
                          state.identity_attempt_error
                       @ Masc_tui_types.identity_app_form_rows
                           state.identity_app_form
                       @ Masc_tui_types.identity_filter_rows ~providers
                           state.identity_filter)
                     ~index:cursor)
                ~height state.detail_scroll
      end

let keeper_log_content_height (state : state) =
  Metrics_tail.content_height ~terminal_rows:(surface_rows state)
    ~error:state.log_error

(* Bytes the terminal has delivered that the reader has not served yet.

   One [Unix.read] per byte is one syscall per character, which is invisible
   while a person types and expensive the moment they do not: a paste is
   thousands of bytes arriving at once, and the terminal hands them over in
   one read whether or not this asks for them one at a time.

   The unserved tail is also the pushback: an invalid UTF-8 continuation has
   to leave the byte it rejected for the next key. [last_source] steps back
   either the terminal probe's replay or [position], with no second reader for
   a byte to hide in. *)
type input_source =
  | Probe_replay
  | Terminal_buffer

type input_reader = {
  bytes : Bytes.t;
  mutable filled : int;
  mutable position : int;
  mutable terminal_probe : Masc_tui_terminal_probe.decoder option;
  mutable late_palette_publisher :
    (Masc_tui_terminal_palette.t -> unit) option;
  mutable last_source : input_source option;
  mutable partial_scalar : string;
      (** The head of a multi-byte character whose tail has not arrived.

          A leading byte states how many bytes follow, and a terminal that
          sent it will send them — but not necessarily inside one
          [Unix.read]. A character straddles the buffer boundary, or the
          emulator re-sends a syllable mid-composition, and the wait for the
          next byte expires with the character half read. Discarding the head
          loses the character and leaves the tail in the stream, where each
          continuation byte is read as its own unrecognised key: one dropped
          Hangul syllable arrives as three.

          So the head waits here instead. The next read resumes it, which is
          the same character arriving late rather than a lost one. Empty
          whenever no character is in flight. *)
}

(* One terminal read. Bigger than any escape sequence and big enough that a
   pasted screenful arrives whole; a paste larger than this is read in as many
   passes as it takes, which is the same loop either way. *)
let input_buffer_bytes = 8192

let create_input_reader () =
  {
    bytes = Bytes.create input_buffer_bytes;
    filled = 0;
    position = 0;
    terminal_probe = None;
    late_palette_publisher = None;
    last_source = None;
    partial_scalar = "";
  }

let refill_input_reader reader ~timeout =
  let timeout_ns =
    Int64.of_float (max 0.0 timeout *. nanoseconds_per_second)
  in
  let poll remaining =
    match Unix.select [Unix.stdin] [] [] remaining with
    | ready, _, _ when ready <> [] ->
        (match
           Unix.read Unix.stdin reader.bytes 0 (Bytes.length reader.bytes)
         with
         | count when count > 0 -> Render_schedule.Input_wait.Ready count
         | _ -> Render_schedule.Input_wait.Timed_out
         | exception Unix.Unix_error (Unix.EINTR, _, _) ->
             Render_schedule.Input_wait.Interrupted)
    | _ -> Render_schedule.Input_wait.Timed_out
    | exception Unix.Unix_error (Unix.EINTR, _, _) ->
        Render_schedule.Input_wait.Interrupted
  in
  match
    Render_schedule.Input_wait.await ~now_ns:Mtime_clock.elapsed_ns ~timeout_ns
      ~poll
  with
  | Some count ->
      reader.filled <- count;
      reader.position <- 0;
      true
  | None -> false

let take_terminal_buffer_byte reader ~timeout =
  if
    reader.position >= reader.filled && not (refill_input_reader reader ~timeout)
  then None
  else begin
    let byte = Bytes.get reader.bytes reader.position in
    reader.position <- reader.position + 1;
    Some byte
  end

let take_late_palette_publisher reader =
  match reader.late_palette_publisher with
  | None -> None
  | Some publish ->
    reader.late_palette_publisher <- None;
    Some publish
;;

let publish_late_terminal_palette reader decoder =
  (* The page the terminal reports is not the palette and does not wait on
     it: a multiplexer answers DECSET 996 and no OSC colour query, so this is
     the only thing that ever arrives there. Published on its own so a colour
     that has to know which way to move can still be told. *)
  (match Masc_tui_terminal_probe.theme_mode decoder with
   | None -> ()
   | Some _ as theme_mode ->
     if
       Masc_tui_terminal_palette.snapshot_theme_mode
         (Masc_tui_terminal_palette.snapshot ())
       <> theme_mode
     then Masc_tui_terminal_palette.set_theme_mode theme_mode);
  match reader.late_palette_publisher with
  | None -> ()
  | Some _ ->
    (match Masc_tui_terminal_probe.palette decoder with
     | None -> ()
     | Some palette ->
       (match take_late_palette_publisher reader with
        | None -> ()
        | Some publish -> publish palette))
;;

let install_late_palette_publisher reader ~request_full_repaint =
  reader.late_palette_publisher <-
    Some
      (fun palette ->
        Masc_tui_terminal_palette.set_current (Some palette);
        request_full_repaint 0)
;;

let take_input_byte reader ~timeout =
  let timeout_ns =
    Int64.of_float (max 0.0 timeout *. nanoseconds_per_second)
  in
  let deadline_ns = Int64.add (Mtime_clock.elapsed_ns ()) timeout_ns in
  let terminal_byte () =
    let remaining_ns =
      Int64.sub deadline_ns (Mtime_clock.elapsed_ns ())
    in
    take_terminal_buffer_byte reader
      ~timeout:
        (if Int64.compare remaining_ns 0L <= 0 then 0.0
         else Int64.to_float remaining_ns /. nanoseconds_per_second)
  in
  match reader.terminal_probe with
  | None ->
    (match terminal_byte () with
     | None ->
       reader.last_source <- None;
       None
     | Some byte ->
       reader.last_source <- Some Terminal_buffer;
       Some byte)
  | Some decoder
    when (not (Masc_tui_terminal_probe.has_replay decoder))
         && Masc_tui_terminal_probe.complete decoder ->
    publish_late_terminal_palette reader decoder;
    reader.terminal_probe <- None;
    (match terminal_byte () with
     | None ->
       reader.last_source <- None;
       None
     | Some byte ->
       reader.last_source <- Some Terminal_buffer;
       Some byte)
  | Some decoder ->
    let next = Masc_tui_terminal_probe.next decoder ~next_raw:terminal_byte in
    publish_late_terminal_palette reader decoder;
    (match next with
     | Some byte ->
       reader.last_source <- Some Probe_replay;
       Some byte
     | None ->
       if
         (not (Masc_tui_terminal_probe.has_replay decoder))
         && Masc_tui_terminal_probe.complete decoder
       then begin
         publish_late_terminal_palette reader decoder;
         reader.terminal_probe <- None
       end;
       reader.last_source <- None;
       None)

(* Give back the byte just taken. Probe replay and the terminal buffer are two
   sources inside this reader, not two readers. The source marker puts an
   invalid UTF-8 continuation back where it came from. *)
let return_input_byte reader =
  (match reader.last_source with
   | Some Probe_replay ->
     Option.iter Masc_tui_terminal_probe.return_replay reader.terminal_probe
   | Some Terminal_buffer -> reader.position <- max 0 (reader.position - 1)
   | None -> ());
  reader.last_source <- None
;;

let is_utf8_continuation = Masc_tui_utf8_input.is_continuation

(* [prefix] is what has already been read of this character: one leading byte
   on the first attempt, or the head left by an attempt that ran out of bytes.

   Returning [None] means the character is still in flight, not that a key was
   lost. The head is parked in [partial_scalar] and the next read resumes it.
   Only a byte that cannot belong to the character — one that is not a
   continuation — is a real decoding failure, and that byte is pushed back so
   it can be read as whatever it actually is. *)
let read_utf8_scalar reader ~prefix expected_length =
  match
    Masc_tui_utf8_input.read_scalar ~prefix ~expected_length
      ~next_byte:(fun () -> take_input_byte reader ~timeout:0.05)
  with
  | Masc_tui_utf8_input.Complete scalar ->
      reader.partial_scalar <- "";
      Some scalar
  | Masc_tui_utf8_input.Incomplete head ->
      (* Not a key. The character is still arriving and the next read finishes
         it from here. *)
      reader.partial_scalar <- head;
      None
  | Masc_tui_utf8_input.Malformed { pushback } ->
      reader.partial_scalar <- "";
      (* The byte belongs to whatever comes next, not to this character. *)
      if Option.is_some pushback then return_input_byte reader;
      Some "invalid-utf8"

(* A paste is not a key and does not become one. Encoding the payload into
   the key channel would put a second meaning on a string every surface reads
   as a key name, and the caller would have to tell the two apart by looking
   at the text -- the classifier this codebase spent RFC-0042 removing. The
   two kinds travel as two constructors instead, and only the paste path can
   carry text. *)
type input_event =
  | Key of string
  | Pasted of Masc_tui_paste.t
  | Graphics_reply of string
      (** The body of an APC the terminal sent back, between [ESC _ G] and
          [ESC \\]. Only the graphics capability query asks for one -- every
          placement says q=2 -- but a reply that is never read is not silent:
          stdin here is the key stream, so its bytes are typed into whatever
          the operator was writing. Reading it is what keeps that from
          happening, whether or not anyone is waiting for it. *)
  | Mouse_left_press of int * int
      (** [(row, column)] of an unmodified left-button press, 1-based as the
          terminal reported it. Only surfaces that map frame rows to their own
          rows consume one; everywhere else it is inert, like a wheel notch on
          a surface with nothing to scroll. *)

(* How long to wait for the next byte of a paste already in progress. The
   terminal writes the payload in one go behind the start marker, so this is a
   liveness bound on a stream that stalled, not a pace. *)
let paste_byte_timeout_seconds = 0.5

(* Read an APC body to its terminator. Bounded: a terminal that opens one and
   never closes it would otherwise hold the reader until the stream stalled,
   and every reply the protocol defines is short. *)
let apc_reply_max_bytes = 4096

let read_apc_body reader =
  let body = Buffer.create 64 in
  let finished = ref false in
  let ended = ref false in
  let escaped = ref false in
  while not (!finished || !ended) do
    match take_input_byte reader ~timeout:0.05 with
    | None -> ended := true
    | Some '\x1b' -> escaped := true
    | Some byte ->
        if !escaped then begin
          escaped := false;
          if byte = '\\' then finished := true
          else begin
            Buffer.add_char body '\x1b';
            Buffer.add_char body byte
          end
        end
        else Buffer.add_char body byte;
        if Buffer.length body > apc_reply_max_bytes then ended := true
  done;
  Buffer.contents body

(** Read one key, one paste, or one thing the terminal said back. *)
let read_input ?(timeout = 0.1) reader () : input_event option =
  Eio_guard.run_in_systhread (fun () ->
      let key name = Some (Key name) in
      (* A character left half-read by the previous call is finished before
         anything else is looked at. Its remaining bytes are the next thing in
         the stream, so reading past them would decode the tail of one
         character as the start of another. *)
      if String.length reader.partial_scalar > 0 then (
        let prefix = reader.partial_scalar in
        match Masc_tui_message_layout.utf8_scalar_byte_length prefix.[0] with
        | Some expected_length ->
            Option.map
              (fun scalar -> Key scalar)
              (read_utf8_scalar reader ~prefix expected_length)
        | None ->
            (* Only a leading byte is ever parked, so this is unreachable;
               clearing it keeps an impossible state from parking forever. *)
            reader.partial_scalar <- "";
            key "invalid-utf8")
      else
      match take_input_byte reader ~timeout with
      | None -> None
      | Some '\027' -> (
          (* CSI: parameter bytes, then one final byte in 0x40-0x7E. Reading to
             the final byte is what keeps a parameterised key from leaving its
             tail in the stream -- Page Up is ESC [ 5 ~, and stopping at the 5
             left the ~ to be typed as text. *)
          match take_input_byte reader ~timeout:0.05 with
          | Some '[' ->
              let parameters = Buffer.create 4 in
              let rec read_csi () =
                match take_input_byte reader ~timeout:0.05 with
                | None -> None
                | Some byte when Char.code byte >= 0x40 && Char.code byte <= 0x7E
                  -> Some (Buffer.contents parameters, byte)
                | Some byte ->
                    Buffer.add_char parameters byte;
                    if Buffer.length parameters > 16 then None else read_csi ()
              in
              (match read_csi () with
               | None -> key "esc"

               (* The terminal says the next bytes were pasted, not typed.
                  Every newline in them is text; without this mode each one
                  arrives as Return and a three-line paste is three sends. *)
               | Some ("200", '~') ->
                   Some
                     (Pasted
                        (Masc_tui_paste.read ~next_byte:(fun () ->
                             take_input_byte reader
                               ~timeout:paste_byte_timeout_seconds)))
               (* A parameter span starting with [<] is an SGR mouse report.
                  Wheel reports become the same keys the arrows make, so every
                  surface's scroll binding answers the wheel; an unmodified
                  left press travels as its own event so a surface can map the
                  row to its cursor; a report nothing consumes stays unclaimed
                  rather than leaking into a key. *)
               | Some (params, final)
                 when String.length params > 0 && params.[0] = '<' -> (
                   match Masc.Tui_decode.sgr_wheel_key params final with
                   | Some wheel_key -> key wheel_key
                   | None -> (
                       match Masc.Tui_decode.sgr_left_press params final with
                       | Some (row, column) ->
                           Some (Mouse_left_press (row, column))
                       | None -> key "unknown-esc"))
               (* A bare [CSI M] is the legacy X10 mouse report: three raw
                  bytes follow and belong to the report, not to the typist.
                  Terminals that ignore the SGR half of the [?1006;1000h]
                  request answer in this shape -- Apple Terminal, the macOS
                  default, is one -- so leaving the bytes unread typed three
                  characters into the composer on every wheel notch. They are
                  consumed whether or not the button means anything. *)
               | Some ("", 'M') ->
                   let button = take_input_byte reader ~timeout:0.05 in
                   let _column = take_input_byte reader ~timeout:0.05 in
                   let _row = take_input_byte reader ~timeout:0.05 in
                   (match button with
                    | None -> key "unknown-esc"
                    | Some button -> (
                        match Masc.Tui_decode.x10_wheel_key button with
                        | Some wheel_key -> key wheel_key
                        | None -> key "unknown-esc"))
               (* Every named key, legacy or modifier-reporting, comes from
                  one vocabulary now. It was seven arms here that could not
                  see a second parameter, so Shift+Up and Ctrl+P both reached
                  the surface as "unknown-esc". *)
               | Some (parameters, final) -> (
                   match Masc_tui_csi.name ~parameters ~final with
                   | Some named -> key named
                   | None -> key "unknown-esc"))
          (* [ESC O <final>] is SS3: what a terminal in application cursor
             mode sends for the arrows and Home/End instead of [ESC \[
             <final>]. Left unread the [ESC] answered as "esc" and the final
             byte arrived as the letter [A], so the arrows moved nothing on
             any surface while j/k kept working. The finals are the same
             ones CSI uses, so the same table names them. *)
          | Some 'O' -> (
              match take_input_byte reader ~timeout:0.05 with
              | Some final -> (
                  match Masc_tui_csi.name ~parameters:"" ~final with
                  | Some named -> key named
                  | None -> key "unknown-esc")
              | None -> key "esc")
          (* [ESC _ G] opens an APC the terminal is sending back. Left
             unread its body arrives as keys: "Gi=31" typed into the
             composer, once per image. *)
          | Some '_' -> (
              match take_input_byte reader ~timeout:0.05 with
              | Some 'G' -> Some (Graphics_reply (read_apc_body reader))
              | Some _ | None -> key "esc")
          (* Alt+Backspace arrives as ESC DEL (or ESC BS where Backspace sends
             BS): the second byte was swallowed as "esc" and the chat closed
             under the typist's thumb. It names its own key now, and the
             composer reads it as delete-word-back. *)
          | Some ('\x7f' | '\x08') -> key "alt-backspace"
          | Some _ | None -> key "esc")
      | Some byte -> (
          match Masc_tui_message_layout.utf8_scalar_byte_length byte with
          | Some 1 -> key (String.make 1 byte)
          | Some expected_length ->
              Option.map
                (fun scalar -> Key scalar)
                (read_utf8_scalar reader
                   ~prefix:(String.make 1 byte)
                   expected_length)
          | None -> key "invalid-utf8"))

(** Parse command line arguments *)
let parse_args () =
  let port = ref (Env_config_core.masc_http_port_int ()) in
  let workspace = ref "" in
  let refresh = ref 2.0 in
  let base_path = ref "" in
  let reasoning_visibility = ref "hidden" in
  let tool_visibility = ref "compact" in

  let specs = [
    ("--port", Arg.Set_int port, Printf.sprintf "MASC server port (default: %d)" (Env_config_core.masc_http_port_int ()));
    ("--workspace", Arg.Set_string workspace, "Workspace name (default: from base path)");
    ("--refresh", Arg.Set_float refresh, "Refresh interval in seconds (default: 2)");
    ( "--base-path",
      Arg.Set_string base_path,
      "Workspace/base path; .masc lives below it (default: MASC_BASE_PATH or cwd)" );
    ( "--base",
      Arg.Set_string base_path,
      "Alias for --base-path" );
    ( "--reasoning",
      Arg.Symbol ([ "hidden"; "folded"; "full" ], fun value -> reasoning_visibility := value),
      "Keeper chat reasoning default: hidden, folded, or full" );
    ( "--tool-view",
      Arg.Symbol ([ "compact"; "full" ], fun value -> tool_visibility := value),
      "Keeper chat tool-call default: compact or full" );
  ] in

  Arg.parse specs (fun _ -> ()) "masc-tui [OPTIONS]";

  (* Resolve base path *)
  let base =
    if !base_path <> "" then (
      match Env_config_core.normalize_masc_base_path_input !base_path with
      | "" -> Config_dir_resolver.base_path_or_cwd ()
      | p -> p)
    else Config_dir_resolver.base_path_or_cwd ()
  in

  (* Resolve workspace *)
  let r = if !workspace <> "" then !workspace
    else match Env_config_core.cluster_name_opt () with
      | Some name -> name
      | None -> Filename.basename base
  in

  let reasoning_visibility =
    match !reasoning_visibility with
    | "hidden" -> Reasoning_hidden
    | "folded" -> Reasoning_folded
    | "full" -> Reasoning_full
    | _ -> Reasoning_hidden
  in
  let tool_visibility =
    match !tool_visibility with
    | "compact" -> Tools_compact
    | "full" -> Tools_full
    | _ -> Tools_compact
  in
  let base_path_input =
    if !base_path <> "" then !base_path else base
  in
  ( base_path_input
  , base
  , r
  , !port
  , !refresh
  , reasoning_visibility
  , tool_visibility )

let save_message_draft state =
  match state.msg_target_keeper_name with
  | None -> ()
  | Some keeper_name ->
      let other_drafts =
        List.filter
          (fun (name, _) -> not (String.equal name keeper_name))
          state.msg_drafts
      in
      let text = Buffer.contents state.msg_input in
      state.msg_drafts <-
        if String.equal text "" then other_drafts
        else (keeper_name, text) :: other_drafts

(* Put the pasted text back into the draft where its placeholder stands.

   Used when the draft is put away -- a saved draft has to stand on its own,
   and a placeholder whose text went with the composer would be sent as a
   sentence about a paste instead of the paste.

   The spill is dropped whether or not its line was still there. An operator
   who deleted the placeholder meant to drop the paste, and a spill that
   outlived the draft would attach itself to the next message. *)
let materialise_spilled_paste state text =
  match state.msg_spill with
  | None -> text
  | Some spill ->
      state.msg_spill <- None;
      Option.value ~default:text
        (Masc_tui_paste_spill.substituted spill
           ~replacement:spill.Masc_tui_paste_spill.text text)

(* Where this process stages a spilled paste for the keeper.

   [Keeper_sandbox_config] is the same answer the server gives: it reads the
   keeper's own TOML for the sandbox profile and returns the backend-scoped
   root -- [.masc/playground/docker/<name>/] for a Docker keeper and
   [.masc/playground/<name>/] for the endpoint-owned profiles (microvm,
   remote_ssh). Working the path out here instead would be this process
   copying a layout the server owns, and the two roots differ by a directory
   that is easy to get right once and wrong afterwards.

   "Staging" is the honest word. For Docker the root is bind-mounted into
   the container, so the staged file is already where the keeper reads it.
   For an endpoint-owned tree the root is only the host bookkeeping bundle
   and the keeper cannot see it; [Keeper_paste_delivery] carries the file to
   the endpoint's workspace root at the next turn setup, the first moment a
   turn-owned endpoint exists. Writing here at paste time is still right:
   the paste is durable from the moment the operator sends it, and no
   endpoint has to be up for this process to receive it.

   [None] when the root cannot be named or does not exist. A keeper that has
   never run has no playground, and creating one from outside would be this
   process deciding something about the keeper's own space. *)
let keeper_staging_dir ~base_path ~keeper_name =
  match
    Keeper_sandbox_config.sandbox_profile_of_agent ~base_path
      ~agent_name:keeper_name
  with
  (* [sandbox_profile_of_agent] raises on a keeper TOML it cannot read, and
     [Sys.is_directory] raises on a path that went away between the two
     calls. Neither is a reason to lose the paste -- the caller falls back to
     sending the text. *)
  | exception _ -> None
  | profile -> (
      let dir =
        Filename.concat base_path
          (Keeper_sandbox_config.host_root_rel_of_profile profile keeper_name)
      in
      match Sys.file_exists dir && Sys.is_directory dir with
      | true -> Some (dir, profile)
      | false -> None
      | exception Sys_error _ -> None)

(* Written beside the final name and renamed over it: a turn starting while
   this write is mid-flight enumerates the staging directory, and a file it
   can see must be whole. The temporary name is outside the
   [Keeper_paste_naming] shape, so enumeration never picks it up. *)
let write_file path contents =
  let drop_tmp tmp_path = try Sys.remove tmp_path with Sys_error _ -> () in
  match
    Filename.temp_file ~temp_dir:(Filename.dirname path) "spill-write-" ".tmp"
  with
  | exception Sys_error detail -> Error detail
  | tmp_path -> (
      match
        match open_out_bin tmp_path with
        | exception Sys_error detail -> Error detail
        | channel -> (
            match
              Fun.protect
                ~finally:(fun () -> close_out_noerr channel)
                (fun () -> output_string channel contents)
            with
            | () -> Ok ()
            | exception Sys_error detail -> Error detail)
      with
      | Error detail ->
          drop_tmp tmp_path;
          Error detail
      | Ok () -> (
          match Unix.rename tmp_path path with
          | () -> Ok ()
          | exception Unix.Unix_error (error, _, _) ->
              drop_tmp tmp_path;
              Error (Unix.error_message error)))

(* Stage a spilled paste as a file the keeper will be able to read, and put
   a line naming that file where the placeholder stands.

   Measured before it was built: a keeper reads paths relative to its own
   sandbox root and refuses anything outside it, so [/tmp] comes back as
   [path_outside_sandbox] and a workspace-relative path is simply not found.
   The file goes into the root the server names for this keeper and the
   message names it bare.

   For Docker that root is the bind-mounted workspace itself, so the file is
   already where the keeper reads it. For the endpoint-owned profiles it is
   the host bookkeeping bundle -- staging, not the destination -- and
   [Keeper_paste_delivery] writes it through the remote lane at the next
   turn setup. The keeper-facing line ("It is in your working directory")
   becomes true before that turn's first Read.

   Every failure falls back to sending the text itself. A paste that reached
   the keeper as a large message is worse than one it can read off disk; a
   paste that reached it as neither is the thing this must not do. *)
let place_spilled_paste state ~base_path ~keeper_name text =
  match state.msg_spill with
  | None -> text
  | Some spill -> (
      state.msg_spill <- None;
      let inline () =
        Option.value ~default:text
          (Masc_tui_paste_spill.substituted spill
             ~replacement:spill.Masc_tui_paste_spill.text text)
      in
      match Masc_tui_paste_spill.substituted spill
              ~replacement:(Masc_tui_paste_spill.message_line spill) text
      with
      | None ->
          (* The placeholder is gone: the operator deleted it, and there is
             nothing to hand the keeper. *)
          text
      | Some pointed -> (
          match keeper_staging_dir ~base_path ~keeper_name with
          | None ->
              add_event state "system"
                (Printf.sprintf
                   "%s has no workspace on disk; sending the pasted text in \
                    the message instead"
                   (Keeper_chat.terminal_safe_text keeper_name));
              inline ()
          | Some (dir, profile) -> (
              let path =
                Filename.concat dir spill.Masc_tui_paste_spill.file_name
              in
              match write_file path spill.Masc_tui_paste_spill.text with
              | Error detail ->
                  add_event state "error"
                    (Printf.sprintf
                       "Could not write the pasted text for %s (%s); sending \
                        it in the message instead"
                       (Keeper_chat.terminal_safe_text keeper_name) detail);
                  inline ()
              | Ok () ->
                  (match profile with
                   | Keeper_sandbox_config.Docker ->
                       (* The staged directory is the bind-mounted workspace
                          itself: written is delivered. *)
                       add_event state "system"
                         (Printf.sprintf
                            "Wrote %s (%d bytes) into %s's workspace"
                            spill.Masc_tui_paste_spill.file_name
                            spill.Masc_tui_paste_spill.bytes
                            (Keeper_chat.terminal_safe_text keeper_name))
                   | Keeper_sandbox_config.Micro_vm
                   | Keeper_sandbox_config.Remote_ssh ->
                       add_event state "system"
                         (Printf.sprintf
                            "Staged %s (%d bytes) for %s; it lands in the \
                             workspace when the next turn starts"
                            spill.Masc_tui_paste_spill.file_name
                            spill.Masc_tui_paste_spill.bytes
                            (Keeper_chat.terminal_safe_text keeper_name)));
                  pointed)))

let reset_message_file_changes state keeper_name =
  (* A late alpha response must not populate alpha after alpha -> beta ->
     alpha. Identity plus this generation is the cache authority. *)
  state.msg_file_changes_generation <- state.msg_file_changes_generation + 1;
  state.msg_file_changes <- None;
  state.msg_file_changes_keeper <- Some keeper_name;
  state.msg_file_change_index <- Masc_tui_keeper_chat_diff.empty;
  state.msg_file_changes_loading <- false;
  state.msg_file_changes_refresh_pending <- false;
  state.msg_file_changes_error <- None

let open_message_for_keeper ?(return_to = Keeper_chat_return_detail) state
    keeper_name =
  (* The paste goes back into the draft before the draft is put away. A spill
     lives with the composer; a saved draft has to stand on its own, and a
     placeholder without its text would reach the keeper as a sentence about a
     paste instead of the paste. *)
  (let materialised = materialise_spilled_paste state (Buffer.contents state.msg_input) in
   Buffer.clear state.msg_input;
   Buffer.add_string state.msg_input materialised);
  save_message_draft state;
  (* Re-entering the same Keeper is a fresh reading too: another process may
     have written files while this pane was elsewhere. Compact mode still
     performs no GET; it only invalidates this presentation cache. *)
  reset_message_file_changes state keeper_name;
  state.msg_target_keeper_name <- Some keeper_name;
  state.msg_live <- live_for_keeper state keeper_name;
  state.msg_return <- return_to;
  state.keeper_message_focus <- Right_pane;
  Buffer.clear state.msg_input;
  List.assoc_opt keeper_name state.msg_drafts
  |> Option.iter (Buffer.add_string state.msg_input)

let leave_keeper_message state =
  save_message_draft state;
  let target_registered =
    match state.msg_target_keeper_name with
    | Some keeper_name -> keeper_available_for_new_message state keeper_name
    | None -> false
  in
  state.view <-
    (match state.msg_return, target_registered with
     | Keeper_chat_return_lanes, _ -> Lanes
     | Keeper_chat_return_detail, true -> Keepers Keeper_detail
     | Keeper_chat_return_list, _ | Keeper_chat_return_detail, false ->
         Keepers Keeper_list);
  state.detail_scroll <- 0;
  if not target_registered then state.log_scroll <- 0

let clear_current_message_draft state =
  Buffer.clear state.msg_input;
  save_message_draft state

let consume_dispatched_message_draft state request =
  state.msg_drafts <-
    List.filter
      (fun (keeper_name, text) ->
        not
          (String.equal keeper_name request.Keeper_chat.keeper_name
           && String.equal text request.message))
      state.msg_drafts;
  match state.msg_target_keeper_name with
  | Some keeper_name
    when String.equal keeper_name request.Keeper_chat.keeper_name
         && String.equal (Buffer.contents state.msg_input) request.message ->
      clear_current_message_draft state
  | Some _ | None -> save_message_draft state

(** Handle local editing keys for message mode. Network submission is injected
    so the input path never owns a blocking HTTP effect. *)
(* One page of the transcript. Measured from the terminal rather than fixed,
   so the jump is a screenful on every window; a page smaller than the pane
   would leave rows the reader has to catch with the arrow keys anyway. *)
let keeper_message_page_rows state =
  let rows, _cols = get_terminal_size () in
  (* The pane's fixed chrome is shared with [render_keeper_message];
     composer growth is already inside [keeper_message_status_rows]. Adding
     composer_max_rows here counted it twice, and every PgUp jumped four
     rows short of the screenful the comment promises. *)
  let status_rows = keeper_message_status_rows state in
  (* PgUp creates the reading-back notice and PgDn removes it. Reserve that
     possible row on both sides of the transition: using only the rows drawn
     right now made a 46-row pane move 38 up, then only 37 down, leaving the
     operator one row behind the live edge. One stable reserved budget also
     leaves a single context row overlapping adjacent pages. *)
  let page_status_rows =
    keeper_message_support_status_rows state ~status_rows
  in
  max 1
    (Masc_tui_message_layout.message_history_height ~terminal_rows:rows
       ~status_rows:page_status_rows)

(* What this pane has of the operator's own lines for the keeper on screen,
   oldest first. The arrows walk it the way a shell walks its own history.
   That is why the wheel no longer arrives as the same key: one of the two had
   to be wrong while they shared it, and scrolling has the wheel and the page
   keys.

   Sent lines come from [msg_history], which is written when a line is
   dispatched. A line typed during a turn has not been dispatched, so it is
   not there -- it is in the queue, and it is the newest thing the operator
   typed. Walking only the sent ones stepped straight past it, which is how a
   queued line could be neither read back nor edited. *)
let own_typed_messages (state : state) =
  let target = Option.value ~default:"" state.msg_target_keeper_name in
  let sent =
    state.msg_history
    |> List.filter (fun entry ->
           (match entry.me_role with
            (* Asked of the type, not of the label. [String.equal label "you"]
               was false for the operator's own lines that came in on any
               surface but the dashboard -- those read "you \xc2\xb7 agent" --
               so the up-arrow recall silently skipped them. *)
            | Message_user (Sent_by_operator _) -> true
            | Message_user (Sent_by_other _) -> false
            | Message_keeper | Message_autonomous | Message_status
            | Message_local | Message_error | Message_tool | Message_skill _
            | Message_thinking | Message_memory ->
                false)
           && String.equal entry.me_keeper_name target
           &&
           match
             Chat_queue.find state.msg_queued ~request_id:entry.me_request_id
           with
           | Some item when item.Chat_queue.intent = Chat_queue.Steer_after_interrupt ->
               (* A steer is command intent, not ordinary chat text. Ctrl-P
                  restores it with [/steer]; arrow recall must not turn it into
                  NEXT merely because both have a user-shaped session row. *)
               false
           | Some _ | None -> true)
  in
  (* The queue is not walked here any more. A queued line enters the history
     when it is typed, not when it is dispatched, so it is already in [sent] --
     concatenating the queue would put the newest line in the walk twice. *)
  sent

let set_composer_text (state : state) text =
  Buffer.clear state.msg_input;
  Buffer.add_string state.msg_input text

(* The draft is put aside on the first step back and handed over on the way
   forward past the newest, so a walk through the history never costs what was
   already typed. *)
(* Land the walk on one line: its text into the composer, and whether that
   line is still waiting.

   Stepping onto a waiting line makes this an edit of it. The arrows copy, and
   a copy of a line that has not been sent yet would be sent twice -- the
   original from the queue and the copy from the composer. Recorded here and
   acted on at Enter, so the step itself stays what it always was: reversible,
   and costing nothing if the operator walks on past. *)
let recall_land (state : state) entries at =
  let count = List.length entries in
  let entry = List.nth entries (count - 1 - at) in
  set_composer_text state entry.me_text;
  state.msg_recall_replaces <-
    Chat_queue.find state.msg_queued ~request_id:entry.me_request_id

let recall_older (state : state) =
  let sent = own_typed_messages state in
  let count = List.length sent in
  if count = 0 then ()
  else begin
    let at =
      match state.msg_recall_at with
      | None ->
          state.msg_recall_draft <- Buffer.contents state.msg_input;
          0
      | Some at -> min (at + 1) (count - 1)
    in
    state.msg_recall_at <- Some at;
    recall_land state sent at
  end

let recall_newer (state : state) =
  match state.msg_recall_at with
  | None -> ()
  | Some 0 ->
      state.msg_recall_at <- None;
      (* Back at the operator's own draft: it is not an edit of anything. *)
      state.msg_recall_replaces <- None;
      set_composer_text state state.msg_recall_draft
  | Some at ->
      let sent = own_typed_messages state in
      let at = at - 1 in
      state.msg_recall_at <- Some at;
      if List.length sent > at then recall_land state sent at

(* Typing makes the composer the operator's again: the walk is over, so a step
   forward must not replace what they just wrote with a draft from before it. *)
let forget_recall (state : state) = state.msg_recall_at <- None

(* A queued line is drawn in the conversation, so cancelling one or pulling it
   back into the composer has to take its row with it. The row is found by the
   request's own id and not by its text: two identical lines to one keeper are
   two requests, and dropping "the row that reads like this" would take
   whichever came first. *)
let forget_queued_history (state : state) (request : Keeper_chat.request) =
  state.msg_history <-
    List.filter
      (fun entry ->
        not
          (String.equal entry.me_request_id request.Keeper_chat.request_id
           && match entry.me_role with Message_user _ -> true | _ -> false))
      state.msg_history
;;

(* Staged images belong to the draft, so the batch and its recency marker move
   together: staging marks the history row that was newest at that moment (or
   [None] when the history was empty, which makes any row it later holds the
   newer one), and clearing takes the marker with the batch. The anchor, not
   the row's position, is what survives: transcript loads replace session rows
   and paging rewrites the list, both of which move positions. *)
let note_attachment_staged (state : state) =
  state.msg_attachments_since <-
    (match List.rev state.msg_history with
     | newest :: _ -> Some (msg_anchor newest)
     | [] -> None)
;;

let clear_staged_attachments (state : state) =
  state.msg_attachments <- [];
  state.msg_attachments_since <- None
;;

let handle_message_key (state : state) ~(submit_message : string -> unit)
    ~(answer_approval : tool_call_id:string -> allow:bool -> unit)
    ~(load_older : before:float -> unit) ~(paste_image : unit -> unit)
    ~(open_named_image : unit -> unit) ~(inspect_context : unit -> unit)
    ~(load_tool_changes : unit -> unit) ~(drain_queue : unit -> unit)
    ~(start_voice : unit -> unit) ~(toggle_voice_continuous : unit -> unit)
    ~(interrupt_turn : unit -> bool) (key : string) : bool =
  (* y and n answer a held call, and only while one is held -- otherwise they
     are letters someone is typing. The prompt on screen is what makes them
     mean anything, so it is also what decides whether they are taken. *)
  (* Moving back and asking for what is behind it are the same act. They were
     three separate copies of the same four lines and [pageup] was missing its
     copy, so a page-at-a-time reader stopped at whatever the first load
     happened to bring in (#31089). Going back through here means the request
     cannot be forgotten again. *)
  let scroll_back rows =
    set_msg_scroll state (state.msg_scroll + rows);
    match state.msg_older_cursor with
    | Some before when state.msg_older_exist && not state.msg_older_loading ->
        load_older ~before
    | Some _ | None -> ()
  in
  let live_is_on_screen live =
    (* [msg_live] survives leaving the chat, so a prompt for keeper A must
       not be answered (or interrupted) from keeper B's screen. *)
    state.msg_target_keeper_name
    = Some (Keeper_chat_transcript.keeper_name live)
  in
  match state.msg_live, key with
  | Some live, ("y" | "Y" | "n" | "N")
    when live_is_on_screen live
         && Option.is_some (Keeper_chat_transcript.awaiting_approval live) -> (
      match Keeper_chat_transcript.awaiting_approval live with
      | Some awaiting ->
          answer_approval ~tool_call_id:awaiting.Keeper_chat_transcript.call_id
            ~allow:(String.lowercase_ascii key = "y");
          true
      | None -> true)
  | _ ->
  let apply_autocomplete direction =
    let text = Buffer.contents state.msg_input in
    let keeper_names =
      List.map (fun (keeper : keeper) -> keeper.k_name) state.keepers
    in
    match Masc_tui_command.autocomplete ~direction ~keeper_names text with
    | Some completed ->
        forget_recall state;
        Buffer.clear state.msg_input;
        Buffer.add_string state.msg_input completed;
        true
    | None -> true
  in
  let slash_navigable () =
    let keeper_names =
      List.map (fun (keeper : keeper) -> keeper.k_name) state.keepers
    in
    Masc_tui_command.is_slash_navigable ~keeper_names
      (Buffer.contents state.msg_input)
  in
  match key with
  (* Esc cancels the innermost thing, and a running capture is inside
     everything else here: the operator is mid-utterance, not mid-turn. ^Y
     stops one and keeps what was said, which is the common case; this is the
     other one, and without it there is no way to abandon a recording that
     picked up something the operator did not mean to send. *)
  | "esc" when Option.is_some state.voice_capture ->
    state.voice_stop_requested <- Some Masc.Voice_bridge.Discard;
    state.last_action <- Some ("voice: discarding", Unix.gettimeofday ());
    true
  | "esc" when Option.is_some state.msg_recall_replaces ->
    state.msg_recall_replaces <- None;
    clear_staged_attachments state;
    Buffer.clear state.msg_input;
    drain_queue ();
    true
  | "\t" -> apply_autocomplete Masc_tui_command.Next
  | "shift-tab" -> apply_autocomplete Masc_tui_command.Prev
  (* The footer and this arm read the same table (Masc_tui_esc_interrupt),
     so the hint the operator sees is the act the key performs: Esc is the
     first press of an interrupt, the accidental second press inside the
     grace window, or a request to leave once the interrupt is stale,
     declined, or errored. Leaving cancels nothing: the interrupt proceeds
     server-side and the pane can be reopened. *)
  | "esc" -> if interrupt_turn () then true else (leave_keeper_message state; true)
  (* Q is the leave half of Esc with the interrupt half taken out. Esc's
     first press on a live turn spends itself stopping the turn, so an
     operator who wants to walk away and let the turn run had no key: the
     only exit signalled the turn to stop. This arm never consults
     [interrupt_turn], so the turn keeps streaming while the operator reads
     something else, and reopening the chat finds it. The view guard first:
     [handle_message_key] has a second caller -- the composer row on every
     other surface -- where every printable key is draft text, and a Q typed
     into a focused row must be the letter, not a jump out of the surface.
     Chat side only, too: in the roster pane Esc means "back to chat", so the
     leave belongs to the composer's focus alone. Empty draft, because
     mid-sentence Q is the letter someone is typing; nothing mid-flight,
     because Esc settles the innermost thing first -- a capture, a
     half-edited queued line -- and Q must not strand either. Decline on any
     of these and the printable arm answers Q as an ordinary letter. *)
  | "Q"
    when state.view = Keepers Keeper_message
         && state.keeper_message_focus = Right_pane
         && Buffer.length state.msg_input = 0
         && Option.is_none state.msg_recall_replaces
         && Option.is_none state.voice_capture ->
    leave_keeper_message state;
    true
  | "\r" ->
    let text = Buffer.contents state.msg_input in
    if String.trim text <> "" then begin
      (* Back to the newest row: the turn that is about to start is drawn
         there, and staying scrolled back would hide the send. *)
      set_msg_scroll state 0;
      forget_recall state;
      submit_message text;
      (* The composer is empty after a submit, so a line held only because the
         operator was mid-compose ([composing_for_keeper]) can dispatch now. When
         the submit folded onto that held line, this is what sends the merge. *)
      drain_queue ()
    end;
    true
  (* The same two keys the composer row binds, because this surface has its own
     editor and never reaches that row: [handle_composer_key] is skipped
     outright while the view is Keeper_message. An operator who learned ^Y on
     one surface would otherwise find it dead on the one they type into most. *)
  | k when String.equal k Composer.listen_key ->
    start_voice ();
    true
  | k when String.equal k Composer.continuous_key ->
    toggle_voice_continuous ();
    true
  | "\n" | "shift-enter" ->
    (* Ctrl-J, Shift+Enter with enhanced keys, or Return on a terminal that
       still translates it. A composer that cannot hold two lines makes an
       operator send two messages for one thought. *)
    forget_recall state;
    Buffer.add_char state.msg_input '\n';
    true
  | "up" when state.msg_scroll > 0 ->
    scroll_back 1;
    true
  | "down" when state.msg_scroll > 0 ->
    set_msg_scroll state (state.msg_scroll - 1);
    true
  | "down" when slash_navigable () -> apply_autocomplete Masc_tui_command.Next
  | "up" when slash_navigable () -> apply_autocomplete Masc_tui_command.Prev
  | "up" ->
    recall_older state;
    true
  | "down" ->
    let was_editing = Option.is_some state.msg_recall_replaces in
    recall_newer state;
    if was_editing && Option.is_none state.msg_recall_replaces
    then drain_queue ();
    true
  | "wheel-up" ->
    (* A notch is worth more than a row. The wheel used to arrive as the arrow
       key and moved one row with it, so reading back through a keeper turn --
       hundreds of rows -- took hundreds of notches. Three is what a terminal
       reports per detent, so a notch here covers what a notch covers
       everywhere else. *)
    scroll_back wheel_notch_rows;
    true
  | "wheel-down" ->
    set_msg_scroll state (state.msg_scroll - wheel_notch_rows);
    true
  | "pageup" ->
    (* A keeper's turn is many rows, so one row per press walks back through a
       single message. A page is the unit the reader actually moves in. *)
    scroll_back (keeper_message_page_rows state);
    true
  | "pagedown" ->
    set_msg_scroll state (state.msg_scroll - keeper_message_page_rows state);
    true
  | "end" ->
    set_msg_scroll state 0;
    true
  | "\127" | "\b" ->
    forget_recall state;
    let new_content =
      Buffer.contents state.msg_input
      |> Masc_tui_message_layout.drop_last_utf8_scalar
    in
    Buffer.clear state.msg_input;
    Buffer.add_string state.msg_input new_content;
    (* Emptying the composer releases a line held only for this keeper's compose
       ([composing_for_keeper]); send it now rather than waiting for a settle. *)
    if Buffer.length state.msg_input = 0 then drain_queue ();
    true
  | "\x17" | "alt-backspace" ->
    (* Ctrl-W, or Alt+Backspace on a terminal that sends ESC DEL: the last
       word goes, the rest of the draft stays. *)
    forget_recall state;
    let new_content =
      Buffer.contents state.msg_input
      |> Masc_tui_message_layout.drop_last_utf8_word
    in
    Buffer.clear state.msg_input;
    Buffer.add_string state.msg_input new_content;
    if Buffer.length state.msg_input = 0 then drain_queue ();
    true
  | s ->
    let c = if String.length s = 1 then Some (Char.code s.[0]) else None in
    if c = Some 18 then begin
      (* Ctrl-R cycles the presentation only; transcript bytes stay intact. *)
      state.msg_reasoning_visibility <-
        next_reasoning_visibility state.msg_reasoning_visibility;
      true
    end else if c = Some 4 then begin
      (* Ctrl-D opens/folds the per-call rows without changing typed calls. *)
      let visibility = toggle_tool_visibility state.msg_tool_visibility in
      state.msg_tool_visibility <- visibility;
      if visibility = Tools_full then load_tool_changes ();
      true
    end else if c = Some 6 then begin
      (* Ctrl-F starts with the clock-free gutter, then adds an inline clock,
         then gives full timestamp/request metadata a row of its own.
         Ctrl-O would have read better for an origin, but it is VDISCARD on
         this platform and [Unix.terminal_io] carries no IEXTEN field to turn
         that off, so the terminal would eat the key before the loop saw it. *)
      state.msg_origin_display <- next_origin_display state.msg_origin_display;
      true
    end else if c = Some 21 then begin
      (* Ctrl-U: clear the composer. The pasted text goes with it -- clearing
         is the operator saying they do not want what is there, and a spill
         that outlived it would attach to the next message. An edit of a
         waiting line is abandoned the same way: the line stays queued and the
         next Enter is a new line, not a replacement. *)
      state.msg_spill <- None;
      if Option.is_some state.msg_recall_replaces
      then begin
        clear_staged_attachments state;
        state.msg_recall_replaces <- None;
        drain_queue ()
      end;
      Buffer.clear state.msg_input;
      (* Cleared composer: release any line held only for this keeper's compose
         ([composing_for_keeper]). *)
      drain_queue ();
      true
    end else if c = Some 5 then begin
      (* Ctrl-E: back to the newest row. Scrolling down one row at a time from
         far back is worse than a key that ends the trip. *)
      set_msg_scroll state 0;
      true
    end else if c = Some 14 then begin
      (* Ctrl-N walks the Librarian/Memory journal lane through summary,
         full, and hidden, same as /memory. Ctrl-M would read better for
         memory, but that byte is the carriage return. *)
      state.msg_memory_visibility <-
        next_memory_visibility state.msg_memory_visibility;
      true
    end else if c = Some 11 then begin
      (* Ctrl-K: drop the newest waiting line without sending it. The queue
         shows what waits in the order it will go; the newest is the one a
         mis-send just hit, and dropping it is local — nothing was
         dispatched. *)
      (match
         Option.bind state.msg_target_keeper_name (fun keeper_name ->
           Chat_queue.take_newest_for_keeper state.msg_queued ~keeper_name)
       with
       | None -> () (* nothing waits; consume quietly like Ctrl-U on empty *)
       | Some (item, rest) ->
         let request = item.Chat_queue.request in
         state.msg_queued <- rest;
         (match state.msg_recall_replaces with
          | Some editing
            when String.equal editing.Chat_queue.request.request_id
                   request.request_id ->
              state.msg_recall_replaces <- None;
              clear_staged_attachments state
          | Some _ | None -> ());
         forget_queued_history state request;
         add_event state "info"
           (Printf.sprintf "Cancelled queued message to %s"
              (Keeper_chat.terminal_safe_text request.Keeper_chat.keeper_name)));
      true
    end else if c = Some 16 then begin
      (* Ctrl-P: pull the newest waiting line back into the composer. That is
         the edit: fix it and Enter queues it again. *)
      (match
         Option.bind state.msg_target_keeper_name (fun keeper_name ->
           Chat_queue.take_newest_for_keeper state.msg_queued ~keeper_name)
       with
       | None -> ()
       | Some (item, _rest) ->
         let request = item.Chat_queue.request in
         state.msg_recall_replaces <- Some item;
         (* The attachments come back with the text. They were staged for this
            line and remain on the queued request while it is edited in place.
            The composer mirrors them so replacing the body retains the exact
            payload; Ctrl-U abandons only the edit and leaves the queue item.
            The batch and its marker move together, so the old pair goes first:
            a text-only recall would otherwise leave the dropped batch's anchor
            behind. *)
         clear_staged_attachments state;
         state.msg_attachments <- request.Keeper_chat.attachments;
         (* The original staging moment is gone -- the send that queued this
            line cleared the marker with the batch -- so the recall is what
            Ctrl-O can weigh: the attachments are the freshest thing the
            composer holds from this moment on. *)
         if request.Keeper_chat.attachments <> [] then
           note_attachment_staged state;
         Buffer.clear state.msg_input;
         Buffer.add_string state.msg_input request.Keeper_chat.message);
      true
    end else if c = Some 22 then begin
      (* Ctrl-V: the clipboard's image, staged for the next message. The key
         reaches here only because [Masc_tui_termios.disable_literal_next]
         turned off VLNEXT -- with the terminal's default the tty layer eats
         this byte and passes the next one through raw, so the composer would
         see the letter after Ctrl-V and never Ctrl-V itself. *)
      paste_image ();
      true
    end else if c = Some 24 then begin
      (* Ctrl-X: the breakdown behind the figure in the header. The header
         names this key beside the number, so the place that shows how full
         the context is is also the place that opens what filled it. *)
      inspect_context ();
      true
    end else if c = Some 15 then begin
      (* Ctrl-O: look at the picture this conversation last named -- or, when
         it named none, the newest image staged for the next message, drawn
         from the bytes the composer is already holding. The path is already
         on screen -- the point is not having to retype it into /image, which
         on a nested evidence path is most of the work. *)
      open_named_image ();
      true
    end else if Masc_tui_message_layout.is_printable_utf8_scalar s then begin
      forget_recall state;
      Buffer.add_string state.msg_input s;
      true
    end else
      true  (* Consume but ignore other control chars *)

let keeper_message_input_supported state =
  let rows, cols = get_terminal_size () in
  let status_rows = keeper_message_status_rows state in
  Masc_tui_message_layout.message_viewport_supported ~terminal_rows:rows
    ~terminal_cols:cols
    ~status_rows:(keeper_message_support_status_rows state ~status_rows)

let approval_decision_key = function
  | Confirm -> "y"
  | Deny -> "n"

let approval_decision_done = function
  | Confirm -> "Confirmed"
  | Deny -> "Denied"

let approval_decision_unverified = function
  | Confirm -> "Confirmation outcome unverified"
  | Deny -> "Denial outcome unverified"

type approval_observation = {
  ao_generation: Approval.Flow.generation;
  ao_result: (approval_snapshot, string) result;
}

type http_scoped_surface_results = {
  http_transport: (Tui_decode.transport_health, string) result option;
  http_approvals: approval_observation option;
  (* [None] on surfaces that do not draw them. Each is read by one surface, and
     leaving it out keeps whatever that surface last observed rather than
     dropping it. *)
  http_asks: (Tui_decode.asks_snapshot, string) result option;
  http_board: (board_post list, string) result option;
  (* The board's hearth census rides with its listing: the two are read for
     one surface and a cycle keyed on a census the listing has outgrown walks
     names that are no longer there. *)
  http_board_hearths: ((string * int) list, string) result option;
  http_planning: (planning_snapshot, string) result option;
  http_system_logs: (system_log_snapshot, string) result option;
  http_fleet_safety: (Tui_decode.fleet_safety, string) result option;
  (* [None] on surfaces that do not show it: the roster costs a request and
     only the Keepers surface reads it, so leaving it out keeps whatever the
     last Keepers refresh observed rather than dropping it. *)
  http_keeper_roster:
    (Keeper_control.roster, Keeper_control.roster_failure) result option;
}

type http_surface_results = {
  http_overview: (overview_snapshot, string) result;
  http_approvals: approval_observation option;
  http_scoped: http_scoped_surface_results;
  (* Mandatory on every refresh: the same endpoint may name a different
     server after a restart, without a failed request reaching this process. *)
  http_server_identity: (Tui_decode.server_identity, string) result;
}

type preset_sink =
  | Preset_to_chat of string option
  | Preset_to_pane

type async_msg =
  (* A microphone capture, from the fiber that runs it. The keeper is carried
     on every one of these rather than read from the state at delivery: the
     roster cursor moves under a refresh, and a transcript that took several
     seconds would otherwise land on whoever happens to be selected when it
     arrives. *)
  | Voice_config_loaded of (Yojson.Safe.t, string) result * string option
  | Voice_level of { keeper : string; db : float }
  | Voice_transcribed of { keeper : string; text : string }
  | Voice_silent of { keeper : string; reason : string }
  | Voice_failed of { keeper : string; error : string }
  | Http_refresh_done of http_surface_results
  | Http_refresh_failed of string * Approval.Flow.generation option
  | Http_scoped_refresh_done of http_scoped_surface_results
  | Http_scoped_refresh_failed of
      string * Approval.Flow.generation option
  | Board_post_refresh_done of
      Board_detail.request * (board_post * board_comment list, string) result
  | Board_post_refresh_failed of Board_detail.request * string
  | Approval_decision_done of
      approval_item
      * approval_decision
      * (Approval.confirm_outcome, string) result
      * approval_observation
  (* The answer that came back, and the list re-read behind it. The store
     settles on first write, so the response says what was actually recorded
     -- which may be someone else's answer. The first field is the human
     confirmation label (the Keeper and what was chosen), built at submit time
     from the labels the operator saw rather than the ask's opaque id. *)
  | Ask_answer_done of
      string
      * (Yojson.Safe.t, string) result
      * (Tui_decode.asks_snapshot, string) result
  | Keeper_chat_dispatch_started of
      Keeper_chat.request * bool * bool Eio.Promise.u
  | Keeper_chat_done of
      Keeper_chat.request
      * bool
      * (Keeper_chat.response, Keeper_chat.error) result
      * unit Eio.Promise.u
  | Keeper_chat_stream_deltas of Keeper_chat.request * Keeper_chat_live.delta list
  | Keeper_chat_stream_unavailable of Keeper_chat.request * string
  | Keeper_chat_interrupt_done of
      Keeper_chat.request * (Masc_tui_interrupt_signal.interrupt_signal, string) result
  | Keeper_chat_history_loaded of
      int
      * string
      * (Keeper_chat_history.decoded, string) result
      * (Keeper_chat_history.decoded, string) result
  | Context_inspector_loaded of
      int * string * Masc_tui_context_inspector.reading
  | Keeper_chat_older_loaded of
      int * string * float * (Keeper_chat_history.page, string) result
  | Lanes_loaded of
      ( Masc.Tui_decode.keeper_lanes_snapshot
        * Masc.Tui_decode.keeper_secret_projection list,
        string )
      result
  | Standalone_lanes_loaded of
      int * (Masc.Tui_decode.standalone_lanes_snapshot, string) result
  | Clients_loaded of
      int * (Masc.Tui_decode.clients_snapshot, string) result
  (* Keyed by the lane / run they answer for: an answer that lands after the
     operator left the list or the run is not this view's answer. *)
  | Lane_runs_loaded of
      string * (Masc.Tui_decode.lane_run_summary list, string) result
  | Lane_run_detail_loaded of
      string * (Masc.Tui_decode.lane_run_detail, string) result
  | Verification_loaded of (Masc.Tui_decode.verification_snapshot, string) result
  | Harness_loaded of (Masc.Tui_decode.harness_snapshot, string) result
  | Fusion_runs_loaded of
      int * (Masc.Tui_decode.fusion_snapshot, string) result
  | Fusion_detail_loaded of
      int * string * (Masc.Tui_decode.fusion_detail, string) result
  | Repositories_loaded of (Masc.Tui_decode.repository_snapshot, string) result
  | Memory_loaded of (Masc.Tui_decode.memory_health_snapshot, string) result
  (* Carries the keeper it was asked about: the browser can be closed or
     pointed at another keeper while a load is in flight, and a late answer
     for somebody else must be dropped, not filed under whoever is open. *)
  | Memory_facts_loaded of
      string * (Masc.Tui_decode.memory_fact_snapshot, string) result
  | Repository_changes_loaded of
      Masc.Tui_decode.repository_change_scope
      * (Masc.Tui_decode.repository_change_snapshot, string) result
  (* Carries the keeper it was asked about. The surface can be pointed at a
     different keeper while a load is in flight, and an answer that did not
     say whose it was would be filed under whoever is selected when it
     lands. *)
  | File_changes_loaded of
      string * (Masc.Tui_decode.file_change_snapshot, string) result
  | Keeper_chat_file_changes_loaded of
      int * string * (Masc.Tui_decode.file_change_snapshot, string) result
      (** Generation and keeper-stamped answer for the chat-only cache. The
          Changes surface owns [File_changes_loaded] and is never populated by
          this response. *)
  (* Keyed by the path it answers for, for the same reason the file-change
     message carries a keeper: an answer for a file the operator has since
     left is not this view's answer. *)
  | Git_diff_loaded of string * (Masc.Tui_decode.git_diff, string) result
  | Connectors_loaded of (Masc.Tui_decode.connector_snapshot, string) result
  | Runtime_surface_loaded of
      int * (Masc_tui_loader.runtime_surface_load, string) result
  | Tools_loaded of (Masc.Tui_decode.tool_snapshot, string) result
  | Skills_catalog_loaded of (Masc.Tui_decode.skills_catalog, string) result
  | Tools_async_observation_loaded of (Yojson.Safe.t, string) result
  | Runtime_lane_slots_written of (unit, string) result
  | Runtime_catalog_loaded of
      ( Masc.Tui_decode.runtime_option list
        * Masc.Tui_decode.runtime_assignment list,
        string )
      result
  | Runtime_assignment_set of
      string
      * string option
      * (Masc_tui_http.runtime_assignment_write_result, string) result
      (** keeper, the runtime it was pointed at ([None] = back to default),
          and whether the server took it. *)
  | Keeper_chat_approval_answered of
      Keeper_chat.request
      * string
      * bool
      * (Masc_tui_http.tool_approval_answer, string) result
  | Keeper_tool_approvals_loaded of
      (Tui_decode.keeper_tool_approval list, string) result
  | Keeper_turns_loaded of (Tui_decode.keeper_turn_row list, string) result
      (** Which keepers are mid-turn right now, for the "answering now"
          badge drawn from every surface. *)
  | Gate_snapshot_loaded of (Tui_decode.gate_snapshot, string) result
      (** The durable Gate beside the held calls: pending approvals that
          survive nobody watching, and both lane modes. *)
  | Gate_approval_resolved of
      string * bool * (unit, string) result * Approval.Flow.generation
      (** approval id, approve, the resolve result, and the in-flight
          generation this decision holds. Completion releases that slot, so
          the header stops drawing [submitting] and a second press is admitted
          again. *)
  | Gate_auto_judge_retried of
      string * (unit, string) result * Approval.Flow.generation
      (** approval id, rearm outcome, and the action slot this explicit retry
          owns. The server accepts it only if every observed identity field
          still matches the blocked row. *)
  | Gate_external_mode_set of string * (unit, string) result
      (** The external-services lane the operator asked for, and whether the
          server took it. *)
  | Surface_tool_approval_answered of
      string
      * string
      * bool
      * (Masc_tui_http.tool_approval_answer, string) result
      * Approval.Flow.generation
  (* Its own message rather than a field on the stance one: the two come from
     different endpoints and one failing must not blank the other. *)
  | Keeper_gate_settings_loaded of
      (((string * string) list * (string * string) list), string) result
  | Keeper_tool_modes_loaded of
      ((string * string) list, string) result * Approval.Flow.generation
      (** The stance listing replaces the whole yolo set, so a fetch that
          started before an operator armed a gate would put the pre-press
          answer back. The generation says which flow the answer belongs to
          and a stale one is dropped, the same guard the held-call listing
          already rides. *)
  | Keeper_tool_mode_set of
      string * string * (unit, string) result * Approval.Flow.generation
      (** keeper, tool call id, allow, and whether a wait was released — the
          Approvals-surface twin of [Keeper_chat_approval_answered], which
          needs the chat request this path does not have. *)
  | Keeper_chat_dispatch_blocked of Keeper_chat.request * string
  | Keeper_action_done of
      string
      * Keeper_control.action
      * (Keeper_control.outcome, string) result
  | Board_new_post_done of {
      reply_to : string option;
      sent_draft : string;
      result : (string, string) result;
    }
  | Board_vote_done of (string, string) result
  | Goal_transition_done of (string, string) result
  | Schedules_loaded of (schedule_snapshot, string) result
  (* Carries the schedule it was asked about: the reader can step to the next
     row or close the detail while a load is in flight, and an answer that did
     not say whose it was would be filed under whoever is open when it lands. *)
  | Schedule_wake_history_loaded of
      string * (schedule_wake_history, string) result
  (* Carries the keeper it was asked about: the roster cursor can move while a
     load is in flight, and an answer that did not say whose it was would be
     filed under whoever is selected when it lands. *)
  | Keeper_schedules_loaded of string * (schedule_snapshot, string) result
  | System_logs_loaded of (system_log_snapshot, string) result
  | Schedule_cancel_done of (string, string) result
  (* (message, noop): [noop = true] says the verdict already stood. *)
  | Verification_verdict_done of (string * bool, string) result
  | Harness_label_done of (string, string) result
  | Keeper_calls_loaded of
      int * string * (Masc.Tui_decode.keeper_calls_snapshot, string) result
  | Goal_timeline_loaded of
      string * (Masc.Tui_decode.goal_timeline, string) result
  | Task_history_loaded of
      string * (Masc.Tui_decode.task_history_event list, string) result
  | Task_cancel_done of string * (string, string) result
  | Verification_evidence_loaded of
      string * (Masc.Tui_decode.verification_evidence, string) result
  | Keeper_config_view_loaded of string * (string list, string) result
  | Keeper_sandbox_view_loaded of
      string * (Masc_tui_keeper_sandbox.t, string) result
  | Keeper_sandbox_logs_loaded of
      string * int * (Masc_tui_keeper_sandbox.logs, string) result
  | Runtime_config_view_loaded of (string * string list, string) result
  | Runtime_params_loaded of
      (Tui_decode.runtime_param_row list, string) result
  | Prompts_loaded of (Tui_decode.prompts_snapshot, string) result
  (* Where a preset answer goes: the chat pane that typed the command, or
     the Config pane that pressed the key. *)
  | Presets_listed of preset_sink * (Tui_decode.presets_snapshot, string) result
  | Preset_saved of preset_sink * (Tui_decode.preset_manifest, string) result
  | Preset_restored of preset_sink * (Tui_decode.preset_restore_report, string) result
  | Librarian_input_loaded of string * (string list, string) result
  | Resources_listed of (Masc_tui_mcp.resource list, string) result
  | Code_entries_loaded of
      string * (Masc.Tui_decode.workspace_tree_node list, string) result
  | Code_file_loaded of string * (string, string) result
  | Code_history_loaded of
      code_workspace_scope
      * string
      * (Masc_tui_types.code_history_listing, string) result
  | Code_diff_loaded of
      string * (Masc.Tui_decode.git_diff, string) result
  | Code_notes_loaded of
      string * (Masc.Tui_decode.ide_annotation list, string) result
  (* The path the margin describes; stamped so a late answer cannot caption
     another file. *)
  | Code_blame_loaded of
      string * (Masc.Tui_decode.blame_block list, string) result
  (* The path the note anchored to; success re-reads the listing. *)
  | Code_note_written of string * (unit, string) result
  (* (question, symbol, answer) — the note the pane shows names both. *)
  | Code_lsp_answered of
      string * string * (Masc.Tui_decode.lsp_answer, string) result
  | Resource_read of
      string * (Masc_tui_mcp.resource_content list, string) result
  | Github_identity_view_loaded of string * (string list, string) result
  | Identity_providers_loaded of
      string * (Masc_tui_types.identity_provider list, string) result
  | Identity_switch_set of
      string * string * bool * (unit, string) result
      (** keeper, provider, the state the operator asked for, and whether
          the server took it. *)
  | Identity_login_started of
      string * (string * string * string, string) result
      (** keeper, then (provider id, label, url) *)
  | Identity_refreshed of string * (unit, string) result
  | Identity_app_saved of string * (int, string) result
      (** provider id, then how many scopes were recorded *)
  | Github_login_lines of string * string list
  | Github_login_finished of string * (unit, string) result
  | Observer_opened of string
  | Observer_received of Masc_tui_observer.decoded list
  | Observer_closed of string
  | Task_dispatched of {
      keeper : string;
      task_id : string;
      title : string;
      body : string;
    }
  | Task_dispatch_failed of {
      keeper : string;
      detail : string;
      original : string;
    }

let enqueue_async mailbox msg = Eio.Stream.add mailbox msg

let current_clock_text () =
  let now = Unix.localtime (Unix.gettimeofday ()) in
  Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
    now.Unix.tm_sec

let clock_text_of_unix at =
  let time = Unix.localtime at in
  Printf.sprintf "%02d:%02d:%02d" time.Unix.tm_hour time.Unix.tm_min
    time.Unix.tm_sec

let next_chat_operation_seq state request_id =
  List.fold_left
    (fun next entry ->
      if String.equal entry.me_request_id request_id
      then max next (entry.me_operation_seq + 1)
      else next)
    0
    (state.msg_loaded @ state.msg_history)
;;

let append_chat_history ?tool_block ?skill_activity ?at ?submitted_at ?turn_phase
    ?operation_seq state request role text =
  let text = Keeper_chat.terminal_safe_text ~preserve_newlines:true text in
  let at = Option.value ~default:(Unix.gettimeofday ()) at in
  let turn_phase =
    Option.value ~default:(chat_turn_phase_of_role role) turn_phase
  in
  let operation_seq =
    Option.value
      ~default:(next_chat_operation_seq state request.Keeper_chat.request_id)
      operation_seq
  in
  state.msg_history <-
    state.msg_history
    @ [ {
          me_role = role;
          me_identity =
            Session_row
              { request_id = request.Keeper_chat.request_id
              ; turn_phase
              ; operation_seq
              };
          me_turn_phase = turn_phase;
          me_turn_sequence = None;
          me_operation_seq = operation_seq;
          me_text = text;
          me_memory_summary = None;
          me_gate = None;
          me_submitted_at = submitted_at;
          me_tool_block = tool_block;
          me_skill_activity = skill_activity;
          me_timestamp = clock_text_of_unix at;
          me_keeper_name = request.Keeper_chat.keeper_name;
          me_request_id = request.request_id;
          me_at = at;
        } ]

let append_user_history_once ~submitted_at state
    (request : Keeper_chat.request) =
  let expected_text =
    Keeper_chat.terminal_safe_text ~preserve_newlines:true request.message
  in
  let already_present =
    List.exists
      (fun entry ->
        (match entry.me_role with Message_user _ -> true | _ -> false)
        && String.equal entry.me_request_id request.Keeper_chat.request_id
        && String.equal entry.me_keeper_name request.keeper_name
        && String.equal entry.me_text expected_text)
      state.msg_history
  in
  if not already_present then
    append_chat_history ~at:submitted_at ~submitted_at state request
      (Message_user (Sent_by_operator "you"))
      request.message

let enqueue_dispatch_ack mailbox make_message =
  let acknowledged, acknowledge = Eio.Promise.create () in
  enqueue_async mailbox (make_message acknowledge);
  Eio.Promise.await acknowledged

let enqueue_dispatch_start mailbox request was_replay =
  let acknowledged, acknowledge = Eio.Promise.create () in
  enqueue_async mailbox
    (Keeper_chat_dispatch_started (request, was_replay, acknowledge));
  Eio.Promise.await acknowledged

(* The server this screen reads. It runs on this machine, so the address is
   loopback and there is nothing to configure.

   It used to read MASC_HOST, which is the *server's* bind address
   ([main_eio.ml] spells it "Host/IP to bind", [Server_auth] calls it
   [configured_bind_host]). That answers a different question -- which
   interfaces to accept on -- and its documented non-default values are the
   wildcards 0.0.0.0 and ::, which [Masc_network_defaults.is_unspecified_host]
   exists to name as "every interface" rather than a reachable peer. Setting
   it the way the server's own help recommends therefore pointed this screen
   at an address that is not a destination.

   Reading it also made a second setting: the roster, the task backlog, the
   keeper metrics and the context occupancy are read from [base_path] on
   local disk, and nothing checked that the two named the same machine. With
   one of them gone there is nothing left to disagree. *)
let server_peer_host = Masc_network_defaults.masc_http_loopback_peer

(* RFC tui-server-lifecycle: the one masc server this TUI started, if any.
   Held at module scope because the switch cleanup in [run_with_eio_context]
   is registered before [main] builds the per-session [state], so the
   cleanup and the key handler need a shared handle neither owns. *)
let tui_owned_server : Masc_tui_server_lifecycle.owned_server option ref =
  ref None

(* Resolve [name] on $PATH — the fallback after the sibling-binary probe.
   [Sys.file_exists] is the same presence test the installer's layout gives
   us; the executable bit is not re-checked here because a non-executable
   [masc] on PATH is a broken install the spawn will report on its own. *)
let find_executable_in_path name =
  match Sys.getenv_opt "PATH" with
  | None -> None
  | Some path ->
      String.split_on_char ':' path
      |> List.find_map (fun dir ->
             if String.equal dir "" then None
             else
               let candidate = Filename.concat dir name in
               if Sys.file_exists candidate then Some candidate else None)

(* Opt-in start of a masc server from inside the TUI. [note] surfaces one
   line to the operator; [on_ready] fires once /health answers so the caller
   can trigger a reconnect. Never starts a second server while one is owned;
   the health wait runs in a forked fiber so the render loop stays live. *)
let start_masc_server_here ~base_path ~host ~port ~note ~on_ready =
  match !tui_owned_server with
  | Some _ -> note "masc server is already starting"
  | None -> (
      match
        Masc_tui_server_lifecycle.discover_server_binary
          ~tui_exe:Sys.executable_name ~file_exists:Sys.file_exists
          ~path_lookup:find_executable_in_path ~base_path ~host ~port
      with
      | Masc_tui_server_lifecycle.Not_found { manual_command } ->
          note ("masc server binary not found; start it with: " ^ manual_command)
      | Masc_tui_server_lifecycle.Sibling masc_bin
      | Masc_tui_server_lifecycle.On_path masc_bin -> (
          match
            Masc_tui_server_lifecycle.start ~masc_bin ~base_path ~host ~port
              ~env:(Unix.environment ())
          with
          | Error e -> note ("masc server start failed: " ^ e)
          | Ok owned -> (
              tui_owned_server := Some owned;
              note "starting masc server here...";
              match Eio_context.get_switch_opt () with
              | None -> ()
              | Some sw ->
                  Eio.Fiber.fork ~sw (fun () ->
                      let health_ok () =
                        match
                          Masc_tui_http.http_get ~host ~port ~path:"/health"
                        with
                        | Ok (200, _) -> true
                        | Ok _ | Error _ -> false
                      in
                      let sleep () =
                        match Eio_context.get_clock_opt () with
                        | Some clock -> Eio.Time.sleep clock 0.5
                        | None -> ()
                      in
                      match
                        Masc_tui_server_lifecycle.wait_healthy ~health_ok
                          ~child_alive:(fun () ->
                            Masc_tui_server_lifecycle.is_running owned)
                          ~attempts:60 ~sleep
                      with
                      | Masc_tui_server_lifecycle.Ready ->
                          note "masc server is up";
                          on_ready ()
                      | Masc_tui_server_lifecycle.Server_exited ->
                          tui_owned_server := None;
                          note "masc server exited before it was ready"
                      | Masc_tui_server_lifecycle.Timed_out _ ->
                          note "masc server did not answer /health in time")))
      )

(* Send the turn and read it as it arrives.

   Bounding the silence needs a clock. Without one the buffered send is used
   instead -- it is what shipped before this and stays correct, so a missing
   clock costs the live view and nothing else. It is said out loud rather than
   passed over: a pane that quietly stops drawing looks like a keeper that
   stopped working. *)
let post_keeper_chat_watching ~mailbox ~port request =
  let host = server_peer_host in
  match Eio_context.get_clock_opt () with
  | None ->
      enqueue_async mailbox
        (Keeper_chat_stream_unavailable
           ( request
           , "sending without a live view: no Eio clock to bound the stream" ));
      Masc_tui_http.post_keeper_chat ~host ~port request
  | Some clock ->
      let rec watch was_unverified =
        let decoder = Keeper_chat_live.create () in
        (* Each idempotent re-subscribe has its own SSE grammar state. The
           visible transcript remains request-owned, but an acceptance event
           at the head of the new stream is not a duplicate in that stream. *)
        let on_chunk chunk =
          match Keeper_chat_live.feed decoder chunk with
          | [] -> ()
          | deltas ->
              enqueue_async mailbox
                (Keeper_chat_stream_deltas (request, deltas))
        in
        let result =
          Masc_tui_http.post_keeper_chat_streaming ~clock ~host ~port ~on_chunk
            request
        in
        match result with
        | Error error
          when Keeper_chat.error_certainty ~was_unverified error
               = Keeper_chat.Outcome_unverified ->
            if not was_unverified
            then
              enqueue_async mailbox
                (Keeper_chat_stream_unavailable
                   ( request
                   , Printf.sprintf
                       "connection lost; reconciling exact request %s before NEXT"
                       request.Keeper_chat.request_id ));
            (* Re-POSTing the same operation id is the server's idempotent
               subscribe/reconcile path. The in-flight owner stays held until
               one watcher observes terminal truth, so NEXT cannot overlap a
               turn whose first stream merely disappeared. *)
            Eio.Time.sleep clock 0.5;
            watch true
        | (Ok _ | Error _) as terminal -> terminal
      in
      watch false

let inflight_entry_by_request_id state request_id =
  List.find_opt
    (fun entry -> String.equal entry.sent_request.request_id request_id)
    state.msg_inflight
;;

let inflight_by_request_id state request_id =
  Option.map
    (fun entry -> entry.sent_request)
    (inflight_entry_by_request_id state request_id)
;;

(* The strict decode carries no tool information, so the rows the live pane
   drew are the only record of what the turn did. They are committed before
   the reply lands so the scrollback reads in the order it happened. *)
let settle_live_turn state (request : Keeper_chat.request) =
  match inflight_entry_by_request_id state request.Keeper_chat.request_id with
  | Some entry
    when Keeper_chat.same_request_identity entry.sent_request request ->
      let live = entry.live in
      List.iter
        (function
          | Keeper_chat_transcript.Trail_skill skill ->
              append_chat_history ~skill_activity:skill state request
                (Message_skill skill.state)
                (String.concat "\n"
                   (Keeper_chat_transcript.skill_rows ~full:false skill))
          | Keeper_chat_transcript.Trail_tools block ->
              let projection =
                Keeper_chat_transcript.project_tool_block
                  Keeper_chat_transcript.Full block
              in
              (match projection.rows with
               | [] -> ()
               | rows ->
                   append_chat_history ~tool_block:block state request
                     Message_tool (String.concat "\n" rows))
          | Keeper_chat_transcript.Trail_thinking _
          | Keeper_chat_transcript.Trail_text _ -> ())
        (Keeper_chat_transcript.trail live);
      (match state.msg_live with
       | Some visible
         when String.equal
                (Keeper_chat_transcript.request_id visible)
                request.Keeper_chat.request_id ->
           state.msg_live <- None
       | Some _ | None -> ())
  | Some _ | None -> ()

(* Ask the server to interrupt the turn this request opened.

   Nothing here decides that the turn stopped. The server reports whether it
   signalled the running fiber, and a turn parked in an uncancellable section
   keeps going after that (masc #29229). The stream ending is the proof, so the
   pane keeps drawing until it does. *)
(* Load the keeper's durable transcript. Runs on its own fiber: the pane stays
   responsive, and a slow or unreachable server costs the scrollback rather than
   the keypress that asked for it. *)
(* Answer the call the keeper is held at. Runs on its own fiber: the pane stays
   responsive, and a slow server costs the answer rather than the keypress. *)
(* The Approvals-surface twin of [launch_keeper_approval]: same route, no chat
   request to correlate with, so the outcome lands in Recent Events instead of
   a pane's transcript. *)
let launch_surface_tool_approval state ~mailbox ~keeper_name ~tool_call_id
    ~allow =
  (* Answering a held tool call mutates server state over one round trip, like
     the Gate and operator-confirm decisions beside it. Take the same
     single-action slot so the header shows [submitting] at once and a repeat
     press during the trip is refused rather than answering the call twice.
     Completion ([Surface_tool_approval_answered]) releases the slot. *)
  match Approval.Flow.begin_action state.approval_flow with
  | Error `Already_inflight ->
      add_event state "system" "Approval action already in progress"
  | Ok (flow, generation) -> (
      state.approval_flow <- flow;
      let host = server_peer_host in
      let port = state.port in
      let run () =
        let result =
          try
            Masc_tui_http.post_keeper_tool_approval ~host ~port ~keeper_name
              ~tool_call_id ~allow
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        enqueue_async mailbox
          (Surface_tool_approval_answered
             (keeper_name, tool_call_id, allow, result, generation))
      in
      match Eio_context.get_switch_opt () with
      | Some sw ->
          Eio.Fiber.fork_daemon ~sw (fun () ->
              run ();
              `Stop_daemon)
      | None ->
          enqueue_async mailbox
            (Surface_tool_approval_answered
               ( keeper_name,
                 tool_call_id,
                 allow,
                 Error "Eio switch is unavailable",
                 generation )))

(* Fetch the held tool calls for the Approvals surface. Its own fiber for the
   same reason every loader runs on one: a slow server costs the refresh, not
   the keypress. *)
let launch_keeper_tool_approvals_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_keeper_tool_approvals ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_tool_approvals_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_tool_approvals_loaded (Error "Eio switch is unavailable"))

(* What voice actually resolved to, plus the microphone the recorder would
   open.

   The server's answer is the only surface that separates "voice is not
   configured" from "a config exists and does not parse". runtime.toml shows
   the second as though it were fine, which is how a six-day outage stayed
   invisible.

   The input device is read here rather than asked of the server: no server
   knows it. sox opens whatever CoreAudio calls default, and captures that come
   back empty are usually a different microphone than the operator assumes. *)
let launch_voice_config_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let config =
      match Masc_tui_http.http_get ~host ~port ~path:"/api/v1/voice/config" with
      | Ok (200, body) -> (
        match Yojson.Safe.from_string body with
        | json -> Ok json
        | exception _ -> Error "voice config did not parse as JSON")
      | Ok (code, body) ->
        Error (Printf.sprintf "voice config HTTP %d: %s" code (String.trim body))
      | Error message -> Error message
    in
    let device =
      (* AUDIODEV wins when set, the way sox reads it; otherwise CoreAudio's
         default, which is what an unset AUDIODEV means. *)
      match Sys.getenv_opt "AUDIODEV" with
      | Some device when String.trim device <> "" -> Some (String.trim device)
      | Some _ | None -> Masc_tui_audio_device.default_input ()
    in
    enqueue_async mailbox (Voice_config_loaded (config, device))
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork_daemon ~sw (fun () -> run (); `Stop_daemon)
  | None ->
    enqueue_async
      mailbox
      (Voice_config_loaded (Error "Eio switch is unavailable", None))
;;

let launch_keeper_turns_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_keeper_turns ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_turns_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_turns_loaded (Error "Eio switch is unavailable"))

let launch_gate_snapshot_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_dashboard_gate ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Gate_snapshot_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Gate_snapshot_loaded (Error "Eio switch is unavailable"))

(* [reason] mirrors [Masc_tui_http.post_dashboard_gate_resolve]: required
   labeled option, because a trailing [?reason] here is unerasable
   (warning 16). *)
let launch_gate_resolve state ~mailbox ~approval_id ~approve ~reason =
  (* A Gate decision mutates durable server state over one round trip. Take the
     same single-action slot the operator-confirm path takes, so the header
     draws [submitting] the instant the key lands and a second press during the
     trip is refused here instead of firing a duplicate resolve. Completion
     ([Gate_approval_resolved]) releases the slot. *)
  match Approval.Flow.begin_action state.approval_flow with
  | Error `Already_inflight ->
      add_event state "system" "Approval action already in progress"
  | Ok (flow, generation) -> (
      state.approval_flow <- flow;
      let host = server_peer_host in
      let port = state.port in
      let run () =
        let result =
          try
            Masc_tui_http.post_dashboard_gate_resolve ~host ~port ~approval_id
              ~approve ~reason
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        enqueue_async mailbox
          (Gate_approval_resolved (approval_id, approve, result, generation))
      in
      match Eio_context.get_switch_opt () with
      | Some sw ->
          Eio.Fiber.fork_daemon ~sw (fun () ->
              run ();
              `Stop_daemon)
      | None ->
          enqueue_async mailbox
            (Gate_approval_resolved
               ( approval_id,
                 approve,
                 Error "Eio switch is unavailable",
                 generation )))

let launch_gate_auto_judge_retry state ~mailbox (pending : Tui_decode.gate_pending) =
  match pending.gp_retry_request with
  | None ->
      add_event state "system"
        "This Auto Judge result cannot be replayed safely; decide it with y/n"
  | Some request ->
      match Approval.Flow.begin_action state.approval_flow with
      | Error `Already_inflight ->
          add_event state "system" "Approval action already in progress"
      | Ok (flow, generation) -> (
          state.approval_flow <- flow;
          let host = server_peer_host in
          let port = state.port in
          let run () =
            let result =
              try Masc_tui_http.post_dashboard_gate_retry ~host ~port ~request with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn -> Error (Printexc.to_string exn)
            in
            enqueue_async mailbox
              (Gate_auto_judge_retried (pending.gp_id, result, generation))
          in
          match Eio_context.get_switch_opt () with
          | Some sw ->
              Eio.Fiber.fork_daemon ~sw (fun () ->
                  run ();
                  `Stop_daemon)
          | None ->
              enqueue_async mailbox
                (Gate_auto_judge_retried
                   ( pending.gp_id,
                     Error "Eio switch is unavailable",
                     generation )))

let launch_gate_external_mode_set state ~mailbox ~mode =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_http.post_dashboard_gate_external_mode ~host ~port ~mode with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Gate_external_mode_set (mode, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Gate_external_mode_set (mode, Error "Eio switch is unavailable"))

let launch_keeper_tool_modes_load state ~mailbox =
  (* [reserve_refresh] declines while the operator's own press is still in
     flight: the answer on the way back would be the stance from before it. *)
  let flow, reserved = Approval.Flow.reserve_refresh state.approval_flow in
  state.approval_flow <- flow;
  match reserved with
  | None -> ()
  | Some generation -> (
      let host = server_peer_host in
      let port = state.port in
      let run () =
        let result =
          try Masc_tui_loader.load_keeper_tool_approval_modes ~host ~port with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        enqueue_async mailbox (Keeper_tool_modes_loaded (result, generation));
        (* Same trip, because both answer "what did somebody set about this
           Keeper" and a detail pane showing one fresh and one stale would be
           two different moments beside each other. No generation guard: this
           listing has no operator press to be superseded by. *)
        let settings =
          try Masc_tui_loader.load_keeper_gate_settings ~host ~port with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        enqueue_async mailbox (Keeper_gate_settings_loaded settings)
      in
      match Eio_context.get_switch_opt () with
      | Some sw ->
          Eio.Fiber.fork_daemon ~sw (fun () ->
              run ();
              `Stop_daemon)
      | None ->
          enqueue_async mailbox
            (Keeper_tool_modes_loaded
               (Error "Eio switch is unavailable", generation)))

let launch_keeper_tool_mode_set state ~mailbox ~keeper_name ~mode =
  (* [begin_action] takes the newest generation, so a stance listing already
     on the wire stops being current and cannot put the old answer back on
     top of this press. It also refuses a second press while one is open. *)
  match Approval.Flow.begin_action state.approval_flow with
  | Error `Already_inflight ->
      add_event state "system"
        (Printf.sprintf "%s's gate is already changing; wait for the answer"
           keeper_name)
  | Ok (flow, generation) -> (
      state.approval_flow <- flow;
      let host = server_peer_host in
      let port = state.port in
      let run () =
        let result =
          try
            Masc_tui_http.post_keeper_tool_approval_mode ~host ~port
              ~keeper_name ~mode
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        enqueue_async mailbox
          (Keeper_tool_mode_set (keeper_name, mode, result, generation))
      in
      match Eio_context.get_switch_opt () with
      | Some sw ->
          Eio.Fiber.fork_daemon ~sw (fun () ->
              run ();
              `Stop_daemon)
      | None ->
          enqueue_async mailbox
            (Keeper_tool_mode_set
               ( keeper_name,
                 mode,
                 Error "Eio switch is unavailable",
                 generation )))

let launch_keeper_approval state ~mailbox (request : Keeper_chat.request)
    ~tool_call_id ~allow =
  let host = server_peer_host in
  let port = state.port in
  let keeper_name = request.Keeper_chat.keeper_name in
  let run () =
    let result =
      try
        Masc_tui_http.post_keeper_tool_approval ~host ~port ~keeper_name
          ~tool_call_id ~allow
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox
      (Keeper_chat_approval_answered (request, tool_call_id, allow, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_chat_approval_answered
           (request, tool_call_id, allow, Error "Eio switch is unavailable"))

(* Fetch the page before [before]. One at a time: msg_older_loading gates the
   caller, so scrolling fast cannot open a request per keypress and land the
   pages out of order. *)
(* Load the verification queue. Its own fiber, like every other surface fetch:
   the pane stays responsive and a slow server costs the list rather than the
   keypress that asked for it. *)
let launch_tools_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let keeper =
    Option.map (fun (row : keeper) -> row.k_name) (selected_keeper state)
  in
  let run () =
    let result =
      try Masc_tui_loader.load_tools ~host ~port ?keeper () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Tools_loaded result);
    let async_observation =
      try Masc_tui_http.fetch_async_request_observation ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Tools_async_observation_loaded async_observation)
  in
  (* The skills catalog (usage + flows) is a separate read and must not
     delay the tool list: a slow catalog costs its own section, not the
     screen. *)
  let run_catalog () =
    let result =
      try Masc_tui_loader.load_skills_catalog ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Skills_catalog_loaded result)
  in
  (match Eio_context.get_switch_opt () with
   | Some sw ->
       Eio.Fiber.fork_daemon ~sw (fun () ->
           run_catalog ();
           `Stop_daemon)
   | None ->
       enqueue_async mailbox
         (Skills_catalog_loaded (Error "Eio switch is unavailable")));
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None -> enqueue_async mailbox (Tools_loaded (Error "Eio switch is unavailable"))

let tools_skill_profiles state =
  match state.tools_inventory with
  | Some
      { Masc.Tui_decode.ts_effective =
          Some
            (Masc.Tui_decode.Effective_surface_available
               { ets_skill_profiles; _ });
        _ } ->
    ets_skill_profiles
  | Some _ | None -> []
;;

let normalize_tools_skill_cursor state =
  let count = List.length (tools_skill_profiles state) in
  if count = 0
  then state.tools_skill_cursor <- 0
  else if state.tools_skill_cursor >= count
  then state.tools_skill_cursor <- count - 1
  else if state.tools_skill_cursor < 0
  then state.tools_skill_cursor <- 0
;;

let selected_tools_skill_profile state =
  List.nth_opt (tools_skill_profiles state) state.tools_skill_cursor
;;

let move_tools_skill_cursor state delta =
  let count = List.length (tools_skill_profiles state) in
  if count > 0
  then state.tools_skill_cursor <- (state.tools_skill_cursor + delta + count) mod count
;;

let cycle_tools_keeper state ~mailbox ~delta =
  let count = List.length state.keepers in
  if count > 0 then begin
    let next = (state.keeper_cursor + delta + count) mod count in
    state.keeper_cursor <- next;
    state.tools_inventory <- None;
    state.tools_error <- None;
    state.tools_scroll <- 0;
    state.tools_skill_cursor <- 0;
    launch_tools_load state ~mailbox
  end
;;

let launch_schedule_wake_history_load state ~mailbox ~schedule_id =
  match state.schedule_wake_history_inflight with
  | Some inflight when String.equal inflight schedule_id -> ()
  | Some _ | None ->
      state.schedule_wake_history_inflight <- Some schedule_id;
      let host = server_peer_host in
      let port = state.port in
      let run () =
        let result =
          try Masc_tui_loader.load_schedule_wake_history ~host ~port ~schedule_id with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        enqueue_async mailbox (Schedule_wake_history_loaded (schedule_id, result))
      in
      (match Eio_context.get_switch_opt () with
       | Some sw ->
           Eio.Fiber.fork_daemon ~sw (fun () ->
               run ();
               `Stop_daemon)
       | None ->
           enqueue_async mailbox
             (Schedule_wake_history_loaded
                (schedule_id, Error "Eio switch is unavailable")))
let launch_keeper_schedules_load state ~mailbox ~keeper_name =
  match state.keeper_schedules_inflight with
  | Some inflight when String.equal inflight keeper_name -> ()
  | Some _ | None ->
      state.keeper_schedules_inflight <- Some keeper_name;
      let host = server_peer_host in
      let port = state.port in
      let payload_target = "keeper:" ^ keeper_name in
      let run () =
        let result =
          try Masc_tui_loader.load_schedules_for_target ~host ~port ~payload_target with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        enqueue_async mailbox (Keeper_schedules_loaded (keeper_name, result))
      in
      (match Eio_context.get_switch_opt () with
       | Some sw ->
           Eio.Fiber.fork_daemon ~sw (fun () ->
               run ();
               `Stop_daemon)
       | None ->
           enqueue_async mailbox
             (Keeper_schedules_loaded
                (keeper_name, Error "Eio switch is unavailable")))

let launch_schedules_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_schedules ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Schedules_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox (Schedules_loaded (Error "Eio switch is unavailable"))

(* The durable call log of one keeper, over HTTP. The row the answer is
   applied to is named in the message so a load that returns after the
   operator moved to another keeper is discarded, not drawn under it. *)
let launch_keeper_calls_load ?(force = false) state ~mailbox keeper_name =
  let same_scope =
    Option.equal String.equal state.keeper_calls_keeper (Some keeper_name)
  in
  if state.keeper_calls_loading && same_scope then
    if force then state.keeper_calls_refresh_pending <- true else ()
  else begin
    state.keeper_calls_generation <- state.keeper_calls_generation + 1;
    let generation = state.keeper_calls_generation in
    if not same_scope then state.keeper_calls <- None;
    state.keeper_calls_keeper <- Some keeper_name;
    state.keeper_calls_loading <- true;
    state.keeper_calls_refresh_pending <- false;
    state.keeper_calls_error <- None;
    let host = server_peer_host in
    let port = state.port in
    let run () =
      let result =
        try Masc_tui_http.fetch_keeper_calls ~host ~port ~keeper_name ~limit:100
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Printexc.to_string exn)
      in
      enqueue_async mailbox
        (Keeper_calls_loaded (generation, keeper_name, result))
    in
    match Eio_context.get_switch_opt () with
    | Some sw ->
        Eio.Fiber.fork_daemon ~sw (fun () ->
            run ();
            `Stop_daemon)
    | None ->
        enqueue_async mailbox
          (Keeper_calls_loaded
             (generation, keeper_name, Error "Eio switch is unavailable"))
  end

(* The two detail-pane histories, over HTTP. Same discipline as the call
   log: the answer names the row it is for, so a load that returns after the
   operator moved on is discarded, not drawn under another item. *)
let launch_goal_timeline_load state ~mailbox goal_id =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_http.fetch_goal_timeline ~host ~port ~goal_id with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Goal_timeline_loaded (goal_id, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Goal_timeline_loaded (goal_id, Error "Eio switch is unavailable"))

let launch_task_history_load state ~mailbox task_id =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_http.fetch_task_history ~host ~port ~task_id with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Task_history_loaded (task_id, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Task_history_loaded (task_id, Error "Eio switch is unavailable"))

(* Cancel one task through the same MCP tool the keepers use
   (masc_transition action=cancel). Cancel is an exit-class action, so the
   contract wants both [reason] and a non-empty [handoff_context.summary];
   the one operator-typed reason serves as both. Opens its own MCP session,
   like the resource browser: a human-cadence action does not earn a held
   connection. The server's task FSM stays the judge of whether this task
   can still be cancelled. *)
let launch_task_cancel state ~mailbox ~task_id ~reason =
  let host = server_peer_host in
  let port = state.port in
  let request_id = Printf.sprintf "tui-cancel-%.6f" (Unix.gettimeofday ()) in
  let run () =
    let result =
      try
        match
          Masc_tui_http.open_mcp_session ~host ~port
            ~client_version:Runtime_build_version.current
        with
        | Error detail -> Error detail
        | Ok session_id -> (
            let arguments =
              Masc_tui_mcp.task_cancel_arguments ~task_id ~reason
            in
            match
              Masc_tui_http.call_mcp_tool ~host ~port ~session_id ~request_id
                ~tool:"masc_transition" ~arguments
            with
            | Error detail -> Error detail
            | Ok outcome ->
                if outcome.Masc_tui_mcp.is_error then
                  Error outcome.Masc_tui_mcp.text
                else Ok outcome.Masc_tui_mcp.text)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Task_cancel_done (task_id, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Task_cancel_done (task_id, Error "Eio switch is unavailable"))

(* The operator evidence bundle for the verification detail, over HTTP.
   Keyed by task id so a stale answer for a request the operator already
   left is discarded, not drawn under another one. *)
let launch_verification_evidence_load state ~mailbox task_id =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_http.fetch_verification_evidence ~host ~port ~task_id with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Verification_evidence_loaded (task_id, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Verification_evidence_loaded (task_id, Error "Eio switch is unavailable"))

(* The detail pane's two non-Info tabs. Same discipline as the call log:
   the answer names the keeper it is for, so a stale load cannot be drawn
   under another keeper's heading. *)
(* The MCP resource inventory, and one resource's text. Each operation
   opens its own session: a human-cadence browser does not earn a held
   connection, and a stale session id would be a second failure mode. *)
let launch_resources_list state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let request_id = Printf.sprintf "tui-res-%.6f" (Unix.gettimeofday ()) in
  let session = state.mcp_session in
  let run () =
    let result =
      try
        let session_result =
          match session with
          | Some session_id -> Ok session_id
          | None ->
              Masc_tui_http.open_mcp_session ~host ~port
                ~client_version:Runtime_build_version.current
        in
        match session_result with
        | Error detail -> Error detail
        | Ok session_id ->
            Masc_tui_http.call_mcp_resources_list ~host ~port ~session_id
              ~request_id
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Resources_listed result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox (Resources_listed (Error "Eio switch is unavailable"))

let launch_resource_read state ~mailbox ~uri =
  state.resource_pending_uri <- Some uri;
  state.resource_content <- None;
  state.resource_content_error <- None;
  state.resource_scroll <- 0;
  let host = server_peer_host in
  let port = state.port in
  let request_id = Printf.sprintf "tui-res-%.6f" (Unix.gettimeofday ()) in
  let session = state.mcp_session in
  let run () =
    let result =
      try
        let session_result =
          match session with
          | Some session_id -> Ok session_id
          | None ->
              Masc_tui_http.open_mcp_session ~host ~port
                ~client_version:Runtime_build_version.current
        in
        match session_result with
        | Error detail -> Error detail
        | Ok session_id ->
            Masc_tui_http.call_mcp_resources_read ~host ~port ~session_id
              ~request_id ~uri
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Resource_read (uri, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Resource_read (uri, Error "Eio switch is unavailable"))

(* The Code surface's two loads: one directory level, one whole file. Plain
   HTTP GETs forked off the render loop, answered on the async mailbox and
   stamped with what they answer for, so a slow reply cannot dress a newer
   selection. *)
(* The scope, as the two optional query axes the fetchers take. The match
   is exhaustive: a fourth scope must decide its axis here. *)
let code_scope_axes_of = function
  | Code_scope_project -> (None, None)
  | Code_scope_keeper keeper -> (Some keeper, None)
  | Code_scope_repo repo -> (None, Some repo)

let code_scope_axes state = code_scope_axes_of state.code_scope

let launch_code_entries_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let dir = state.code_dir in
  let run () =
    let result =
      try
        let keeper, repo = code_scope_axes state in
        Masc_tui_http.fetch_workspace_entries ?keeper ?repo ~host ~port
          ~path:dir ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Code_entries_loaded (dir, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Code_entries_loaded (dir, Error "Eio switch is unavailable"))

let launch_code_file_load state ~mailbox ~path =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        let keeper, repo = code_scope_axes state in
        Masc_tui_http.fetch_workspace_file ?keeper ?repo ~host ~port ~path ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Code_file_loaded (path, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Code_file_loaded (path, Error "Eio switch is unavailable"))

(* The 50-commit first page covers the pane; the route caps at 200 anyway. *)
let code_history_limit = 50

(* What the working tree is compared against, everywhere a tree diff is
   read. *)
let tree_diff_base_ref = "HEAD"

(* Annotation routes are scoped by the server-minted codebase slug
   (RFC-0378), and only a Repositories row carries one -- the other scopes say
   so instead of guessing a slug. Durable file activity below is different:
   its repository id is resolved server-side against the tool-call log. *)
let code_scope_codebase state =
  match state.code_scope with
  | Code_scope_repo repo_id -> (
      match state.repositories with
      | None -> Error "the repositories listing is not loaded yet"
      | Some snapshot -> (
          match
            List.find_opt
              (fun (r : Masc.Tui_decode.repository) ->
                String.equal r.Masc.Tui_decode.rp_id repo_id)
              snapshot.Masc.Tui_decode.rs_repositories
          with
          | None ->
              Error ("repository " ^ repo_id ^ " is not in the listing")
          | Some r -> (
              match r.Masc.Tui_decode.rp_codebase with
              | Some slug -> Ok slug
              | None ->
                  Error
                    "this repository's remote has no canonical slug, so \
                     it has no notes")))
  | Code_scope_keeper _ ->
      Error "notes are scoped by repository; open the file from Workspace"
  | Code_scope_project ->
      Error "the project tree is not a registered repository; no notes here"

let code_file_activity_address scope path =
  match scope with
  | Code_scope_repo repo_id -> Ok (Some repo_id, path)
  | Code_scope_keeper _ -> (
      match Playground_paths.parse_bundle_relative_repo_path path with
      | Some (repo_id, relative_path) -> Ok (Some repo_id, relative_path)
      | None ->
        Error
          "this Keeper file is outside a registered repository clone, so it has no shared repository address")
  | Code_scope_project -> Ok (None, path)

let code_history_entry_at_ms = function
  | Hist_commit (row : Masc.Tui_decode.git_log_row) -> row.gl_at_ms
  | Hist_keeper_change (change : Masc.Tui_decode.file_change) ->
    change.fc_at *. 1000.

let launch_code_history_load state ~mailbox ~path =
  let host = server_peer_host in
  let port = state.port in
  let scope = state.code_scope in
  let activity_address = code_file_activity_address scope path in
  let run () =
    let result =
      try
        let keeper, repo = code_scope_axes_of scope in
        match
          Masc_tui_http.fetch_git_log ?keeper ?repo ~host ~port ~path
            ~limit:code_history_limit ()
        with
        | Error detail -> Error detail
        | Ok commits ->
            let changes, chl_activity_note =
              match activity_address with
              | Error detail -> [], "Keeper activity unavailable: " ^ detail
              | Ok (repo_id, file_path) -> (
                  match
                    Masc_tui_http.fetch_ide_file_activity
                      ~host ~port ~repo_id ~file_path
                  with
                  | Error detail ->
                    [], "Keeper activity unavailable: " ^ detail
                  | Ok snapshot ->
                    let incomplete =
                      snapshot.fas_incomplete_over_budget
                      + snapshot.fas_incomplete_malformed
                    in
                    let unattributed =
                      snapshot.fas_unattributed_over_budget
                      + snapshot.fas_unattributed_malformed
                    in
                    let missing_note =
                      [ (if incomplete = 0
                         then None
                         else
                           Some
                             (Printf.sprintf
                                "%d exact-address row%s incomplete"
                                incomplete (if incomplete = 1 then "" else "s")))
                      ; (if unattributed = 0
                         then None
                         else
                           Some
                             (Printf.sprintf
                                "%d fleet row%s had no readable address"
                                unattributed (if unattributed = 1 then "" else "s")))
                      ]
                      |> List.filter_map Fun.id
                      |> function
                      | [] -> ""
                      | notes -> "; " ^ String.concat "; " notes
                    in
                    ( snapshot.fas_changes
                    , Printf.sprintf
                        "Keeper activity: %.0fh durable window, %d exact change%s%s"
                        snapshot.fas_window_hours
                        (List.length snapshot.fas_changes)
                        (if List.length snapshot.fas_changes = 1 then "" else "s")
                        missing_note ))
            in
            let chl_entries =
              List.stable_sort
                (fun a b ->
                  Float.compare (code_history_entry_at_ms b)
                    (code_history_entry_at_ms a))
                (List.map (fun c -> Hist_commit c) commits
                 @ List.map (fun change -> Hist_keeper_change change) changes)
            in
            Ok { chl_entries; chl_activity_note }
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Code_history_loaded (scope, path, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Code_history_loaded
           (scope, path, Error "Eio switch is unavailable"))

let launch_code_diff_load state ~mailbox ~path =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        let keeper, repo = code_scope_axes state in
        Masc_tui_loader.load_git_diff ?repo ~host ~port ~keeper ~path
          ~base_ref:tree_diff_base_ref ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Code_diff_loaded (path, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Code_diff_loaded (path, Error "Eio switch is unavailable"))

(* The squash-merge convention leaves the PR number as the subject's last
   "(#N)"; a subject without one truthfully has no PR to point at. *)
let pr_number_of_subject subject =
  let n = String.length subject in
  let rec scan i best =
    if i >= n then best
    else if
      subject.[i] = '(' && i + 2 < n && subject.[i + 1] = '#'
    then begin
      let rec digits j acc =
        if j < n && subject.[j] >= '0' && subject.[j] <= '9' then
          digits (j + 1) ((acc * 10) + (Char.code subject.[j] - 48))
        else (j, acc)
      in
      let stop, value = digits (i + 2) 0 in
      if value > 0 && stop < n && subject.[stop] = ')' then
        scan (stop + 1) (Some value)
      else scan (i + 1) best
    end
    else scan (i + 1) best
  in
  scan 0 None

(* A GitHub pull-request URL from the registered remote. Only GitHub: other
   forges spell the path differently, and guessing would link to a 404. *)
let github_pr_url ~remote ~number =
  let remote = String.trim remote in
  let https =
    if String.starts_with ~prefix:"git@github.com:" remote then
      Some
        ("https://github.com/"
        ^ String.sub remote 15 (String.length remote - 15))
    else if String.starts_with ~prefix:"https://github.com/" remote then
      Some remote
    else None
  in
  Option.map
    (fun base ->
      let base =
        if String.ends_with ~suffix:".git" base then
          String.sub base 0 (String.length base - 4)
        else base
      in
      Printf.sprintf "%s/pull/%d" base number)
    https

(* The codebase slug for the surface's scope, when it has one. Only a
   repository row carries the server-minted slug (RFC-0378: the client
   never re-derives it); the other scopes honestly have none. *)
(* Same fiber-and-mailbox shape as the notes read below. Scoped by the same
   keeper / repo axes the file itself was read through, so the margin
   describes the checkout on screen rather than whichever one the server
   would default to. *)
let launch_code_blame_load state ~mailbox ~path =
  let host = server_peer_host in
  let port = state.port in
  let keeper, repo = code_scope_axes state in
  let run () =
    let result =
      try Masc_tui_http.fetch_git_blame ?keeper ?repo ~host ~port ~path ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Code_blame_loaded (path, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Code_blame_loaded (path, Error "Eio switch is unavailable"))

let launch_code_notes_load state ~mailbox ~codebase ~path =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        Masc_tui_http.fetch_ide_annotations ~host ~port ~codebase
          ~file_path:path
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Code_notes_loaded (path, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Code_notes_loaded (path, Error "Eio switch is unavailable"))

(* Same fiber-and-mailbox shape as the other writes. *)
let start_code_note_write state ~mailbox ~codebase ~path ~line_start ~line_end
    ~kind ~content =
  add_event state "system" ("adding a note to " ^ path);
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        Masc_tui_http.post_ide_annotation ~host ~port ~codebase
          ~file_path:path ~line_start ~line_end ~kind ~content
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Code_note_written (path, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run
  | None -> run ()

(* Remember where a jump is about to leave from, so B can walk back.
   Bounded: the oldest entry falls off past twenty. *)
let code_jump_back_limit = 20

let push_code_jump state =
  let file = Option.map fst state.code_file in
  let entry =
    ( state.code_scope,
      state.code_dir,
      file,
      state.code_file_cursor,
      state.code_file_scroll )
  in
  state.code_jump_back <-
    entry
    :: (if List.length state.code_jump_back >= code_jump_back_limit then
          List.filteri
            (fun i _ -> i < code_jump_back_limit - 1)
            state.code_jump_back
        else state.code_jump_back)

(* Ask the language server about [symbol] on the pane's cursor line. The
   question rides the surface's workspace axes, so a keeper checkout and a
   repository ask about their own bytes. *)
let start_code_lsp_question state ~mailbox ~(question : string)
    ~(symbol : string) =
  match state.code_file with
  | None -> add_event state "error" "no file is open on the Code surface"
  | Some (path, _) ->
      state.code_lsp_note <-
        Some (Printf.sprintf "asking %s about %S" question symbol);
      let host = server_peer_host in
      let port = state.port in
      let line = state.code_file_cursor + 1 in
      let keeper, repo = code_scope_axes state in
      let run () =
        let result =
          try
            Masc_tui_http.fetch_lsp_question ?keeper ?repo ~host ~port ~path
              ~line ~symbol ~question ()
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        enqueue_async mailbox (Code_lsp_answered (question, symbol, result))
      in
      (match Eio_context.get_switch_opt () with
       | Some sw ->
           Eio.Fiber.fork_daemon ~sw (fun () ->
               run ();
               `Stop_daemon)
       | None ->
           enqueue_async mailbox
             (Code_lsp_answered
                (question, symbol, Error "Eio switch is unavailable")))

(* The device-flow login, streamed. gh prints the one-time code on its
   own output, which the server forwards redacted; every data line lands
   in the GitHub tab as it arrives so the operator can read the code and
   finish in the browser. When the stream ends the tab re-reads the
   identity observation, which is the fact the login was for. *)
let launch_github_login state ~mailbox keeper_name =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    match Eio_context.get_clock_opt () with
    | None ->
        enqueue_async mailbox
          (Github_login_finished (keeper_name, Error "Eio clock is unavailable"))
    | Some clock ->
        let pending = Buffer.create 256 in
        let flush_lines () =
          let text = Buffer.contents pending in
          match String.rindex_opt text '\n' with
          | None -> ()
          | Some last ->
              let complete = String.sub text 0 last in
              let rest =
                String.sub text (last + 1) (String.length text - last - 1)
              in
              Buffer.clear pending;
              Buffer.add_string pending rest;
              let lines =
                String.split_on_char '\n' complete
                |> List.filter_map (fun line ->
                       let line = String.trim line in
                       if String.length line > 6
                          && String.sub line 0 6 = "data: "
                       then
                         let payload =
                           String.sub line 6 (String.length line - 6)
                         in
                         match Yojson.Safe.from_string payload with
                         | `Assoc fields -> (
                             match List.assoc_opt "text" fields with
                             | Some (`String text) ->
                                 Some (String.split_on_char '\n' text)
                             | _ -> (
                                 match List.assoc_opt "message" fields with
                                 | Some (`String message) ->
                                     Some [ "error: " ^ message ]
                                 | _ -> Some [ payload ]))
                         | _ | (exception Yojson.Json_error _) ->
                             Some [ payload ]
                       else None)
                |> List.concat
                |> List.map Masc.Tui_decode.sanitize_terminal_text
                |> List.filter (fun line -> String.trim line <> "")
              in
              if lines <> [] then
                enqueue_async mailbox (Github_login_lines (keeper_name, lines))
        in
        let result =
          try
            Masc_tui_http.post_keeper_github_login_streaming ~clock ~host
              ~port ~keeper_name
              ~on_chunk:(fun chunk ->
                Buffer.add_string pending chunk;
                flush_lines ())
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        enqueue_async mailbox (Github_login_finished (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Github_login_finished (keeper_name, Error "Eio switch is unavailable"))

let launch_runtime_config_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_runtime_config_view ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Runtime_config_view_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Runtime_config_view_loaded (Error "Eio switch is unavailable"))

let launch_runtime_params_load state ~mailbox =
  state.runtime_params_loading <- true;
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_runtime_params ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Runtime_params_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Runtime_params_loaded (Error "Eio switch is unavailable"))

let launch_prompts_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_prompts ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Prompts_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox (Prompts_loaded (Error "Eio switch is unavailable"))

(* A /preset call runs off the input loop like the prompt catalog load; its
   answer comes back as a chat notice for the pane that asked, so [wrap]
   carries that pane's keeper. *)
let launch_preset_call state ~mailbox ~call ~wrap =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try call ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (wrap result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None -> enqueue_async mailbox (wrap (Error "Eio switch is unavailable"))

let launch_presets_load state ~mailbox =
  state.presets_error <- None;
  launch_preset_call state ~mailbox
    ~call:(fun ~host ~port -> Masc_tui_loader.load_presets ~host ~port)
    ~wrap:(fun result -> Presets_listed (Preset_to_pane, result))

let preset_rows_for_state state =
  match state.presets_snapshot with
  | None -> []
  | Some snapshot -> snapshot.Tui_decode.pss_presets

let selected_preset_for_state state =
  let rows = preset_rows_for_state state in
  List.nth_opt rows (max 0 (min state.presets_cursor (List.length rows - 1)))

let prompt_rows_for_state state =
  match state.prompts_snapshot with
  | None -> []
  | Some snapshot ->
      Tui_decode.prompt_rows_for_operator
        ~show_fragments:state.prompts_show_fragments snapshot
;;

let runtime_prompt_assets_for_state state =
  match state.prompts_snapshot with
  | None -> []
  | Some snapshot -> snapshot.Tui_decode.ps_runtime_assets
;;

let prompt_catalog_count_for_state state =
  if state.prompts_show_runtime_assets
  then List.length (runtime_prompt_assets_for_state state)
  else List.length (prompt_rows_for_state state)
;;

let selected_prompt_for_state state =
  List.nth_opt (prompt_rows_for_state state) state.prompts_cursor
;;

let launch_librarian_input_load state ~mailbox ~prompt_key =
  let host = server_peer_host in
  let port = state.port in
  state.prompts_librarian_input <- None;
  state.prompts_librarian_input_error <- None;
  state.prompts_librarian_input_loading <- true;
  let run () =
    let result =
      try Masc_tui_http.fetch_latest_librarian_input ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Librarian_input_loaded (prompt_key, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Librarian_input_loaded
           (prompt_key, Error "Eio switch is unavailable"))

let launch_keeper_config_view state ~mailbox keeper_name =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_keeper_config_view ~host ~port ~keeper_name with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_config_view_loaded (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_config_view_loaded
           (keeper_name, Error "Eio switch is unavailable"))

let launch_keeper_sandbox_view state ~mailbox keeper_name =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_keeper_sandbox_view ~host ~port ~keeper_name with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_sandbox_view_loaded (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_sandbox_view_loaded
           (keeper_name, Error "Eio switch is unavailable"))

let launch_keeper_sandbox_logs state ~mailbox keeper_name =
  let host = server_peer_host in
  let port = state.port in
  state.keeper_sandbox_logs_generation <- state.keeper_sandbox_logs_generation + 1;
  let generation = state.keeper_sandbox_logs_generation in
  state.keeper_sandbox_logs_inflight <- Some (keeper_name, generation);
  let run () =
    let result =
      try
        Masc_tui_loader.load_keeper_sandbox_logs ~host ~port ~keeper_name
          ~tail:200
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox
      (Keeper_sandbox_logs_loaded (keeper_name, generation, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
    Eio.Fiber.fork_daemon ~sw (fun () ->
      run ();
      `Stop_daemon)
  | None ->
    enqueue_async mailbox
      (Keeper_sandbox_logs_loaded
         (keeper_name, generation, Error "Eio switch is unavailable"))

let launch_github_identity_view state ~mailbox keeper_name =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        Masc_tui_loader.load_keeper_github_identity_view ~host ~port
          ~keeper_name
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Github_identity_view_loaded (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Github_identity_view_loaded
           (keeper_name, Error "Eio switch is unavailable"))

let launch_identity_view state ~mailbox keeper_name =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_identity_providers ~host ~port ~keeper_name with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Identity_providers_loaded (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Identity_providers_loaded (keeper_name, Error "Eio switch is unavailable"))

(* Throw or clear one attached service's switch. Off keeps the token and
   catalog; the keeper's turns stop being handed that provider's tools. *)
let launch_identity_switch state ~mailbox ~keeper_name ~provider_id ~enabled =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        Masc_tui_http.post_identity_switch ~host ~port ~keeper_name
          ~provider_id ~enabled
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox
      (Identity_switch_set (keeper_name, provider_id, enabled, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Identity_switch_set
           (keeper_name, provider_id, enabled, Error "Eio switch is unavailable"))

(* Begin a login. The answer is a URL the operator has to open; nothing is
   written to the keeper until the browser comes back to the server. *)
(* Recording an app the operator made. Answers on the same notice line a
   failed attempt uses -- what an operator wants after pressing save is one
   sentence saying whether it took, in the place they are already reading. *)
let launch_identity_app_save state ~mailbox
      ~(form : Masc_tui_types.identity_app_form) =
  let host = server_peer_host in
  let port = state.port in
  let provider_id = form.Masc_tui_types.iaf_provider in
  let client_id = form.Masc_tui_types.iaf_client_id in
  let client_secret = form.Masc_tui_types.iaf_client_secret in
  let scopes = form.Masc_tui_types.iaf_scopes in
  let run () =
    let result =
      try
        match
          Masc_tui_http.post_keeper_oauth_client ~host ~port ~provider_id
            ~client_id ~client_secret ~scopes
        with
        | Error err -> Error err
        | Ok (`Assoc pairs) -> (
          match List.assoc_opt "error" pairs with
          | Some (`String detail) -> Error detail
          | Some _ | None ->
            let count =
              match List.assoc_opt "scopes" pairs with
              | Some (`List rows) -> List.length rows
              | Some _ | None -> 0
            in
            Ok count)
        | Ok _ -> Error "the server answered with something unreadable"
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Identity_app_saved (provider_id, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
    Eio.Fiber.fork_daemon ~sw (fun () ->
      run ();
      `Stop_daemon)
  | None ->
    enqueue_async mailbox
      (Identity_app_saved (provider_id, Error "Eio switch is unavailable"))

let launch_identity_login state ~mailbox ~keeper_name ~provider_id ~label =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        match
          Masc_tui_http.post_keeper_oauth_login ~host ~port ~keeper_name
            ~provider_id
        with
        | Error err -> Error err
        | Ok json -> (
            match json with
            | `Assoc fields -> (
                match List.assoc_opt "authorize_url" fields with
                | Some (`String url) ->
                    let provider_id =
                      match List.assoc_opt "provider" fields with
                      | Some (`String id) -> id
                      | Some _ | None -> provider_id
                    in
                    (* Opened here, on this fiber, because the URL is about
                       nine hundred characters and a pane truncates it -- an
                       operator cannot select what is not on screen. It is
                       still printed below, wrapped, for the machine that has
                       no opener. *)
                    (match Masc_tui_browser.open_url url with
                    | Ok _ | Error _ -> ());
                    Ok (provider_id, label, url)
                | Some _ | None ->
                    Error "the server answered without an authorize_url")
            | _ -> Error "the server answered with something this cannot read")
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Identity_login_started (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Identity_login_started (keeper_name, Error "Eio switch is unavailable"))

(* Ask every attached service again what tools it has. An operator action
   rather than a timer: a stale catalog is visible and fixable, while a timer
   is a network call nobody asked for. *)
let launch_identity_refresh state ~mailbox ~keeper_name ~provider_ids =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        List.fold_left
          (fun acc provider_id ->
            match acc with
            | Error _ as err -> err
            | Ok () -> (
                match
                  Masc_tui_http.post_keeper_identity_refresh ~host ~port
                    ~keeper_name ~provider_id
                with
                | Ok _ -> Ok ()
                | Error err -> Error (provider_id ^ ": " ^ err)))
          (Ok ()) provider_ids
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Identity_refreshed (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Identity_refreshed (keeper_name, Error "Eio switch is unavailable"))

let launch_connectors_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_connectors ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Connectors_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox (Connectors_loaded (Error "Eio switch is unavailable"))

let launch_runtime_surface_load state ~mailbox ~force =
  match state.runtime_surface_inflight with
  | Some _ -> if force then state.runtime_surface_force_pending <- true
  | None ->
      state.runtime_surface_generation <- state.runtime_surface_generation + 1;
      let generation = state.runtime_surface_generation in
      state.runtime_surface_inflight <- Some generation;
      let host = server_peer_host in
      let port = state.port in
      let run () =
        let result =
          try Masc_tui_loader.load_runtime_surface ~host ~port ~force with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        enqueue_async mailbox (Runtime_surface_loaded (generation, result))
      in
      (match Eio_context.get_switch_opt () with
       | Some sw ->
           Eio.Fiber.fork_daemon ~sw (fun () ->
               run ();
               `Stop_daemon)
       | None ->
           enqueue_async mailbox
             (Runtime_surface_loaded
                (generation, Error "Eio switch is unavailable")))

let launch_repositories_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_repositories ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Repositories_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Repositories_loaded (Error "Eio switch is unavailable"))

let launch_memory_health_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_memory_health ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Memory_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox (Memory_loaded (Error "Eio switch is unavailable"))

let launch_memory_facts_load state ~mailbox ~keeper_name =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_memory_facts ~host ~port ~keeper_name with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Memory_facts_loaded (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Memory_facts_loaded (keeper_name, Error "Eio switch is unavailable"))

let repository_change_scope_equal left right =
  match left, right with
  | Tui_decode.Repository_change_project, Tui_decode.Repository_change_project ->
      true
  | ( Tui_decode.Repository_change_repository left_id
    , Tui_decode.Repository_change_repository right_id ) ->
      String.equal left_id right_id
  | Tui_decode.Repository_change_project, Tui_decode.Repository_change_repository _
  | Tui_decode.Repository_change_repository _, Tui_decode.Repository_change_project ->
      false

let launch_repository_changes_load state ~mailbox ~scope =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        match scope with
        | Tui_decode.Repository_change_project ->
            Masc_tui_loader.load_project_changes ~host ~port
        | Tui_decode.Repository_change_repository repository_id ->
            Masc_tui_loader.load_repository_changes ~host ~port ~repository_id
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Repository_changes_loaded (scope, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Repository_changes_loaded
           (scope, Error "Eio switch is unavailable"))

let open_repository_changes state ~mailbox ~scope =
  state.repository_changes_open <- true;
  state.repository_changes_scope <- Some scope;
  state.repository_changes <- None;
  state.repository_changes_error <- None;
  state.repository_changes_cursor <- 0;
  state.repository_changes_scroll <- 0;
  launch_repository_changes_load state ~mailbox ~scope

let close_repository_changes state =
  state.repository_changes_open <- false;
  state.repository_changes_scope <- None;
  state.repository_changes <- None;
  state.repository_changes_error <- None;
  state.repository_changes_cursor <- 0;
  state.repository_changes_scroll <- 0

let refresh_repository_changes state ~mailbox =
  match state.repository_changes_scope with
  | None -> ()
  | Some scope ->
      state.repository_changes <- None;
      state.repository_changes_error <- None;
      launch_repository_changes_load state ~mailbox ~scope

let open_repository_change_in_code state ~mailbox ~scope
    (change : Tui_decode.repository_change) =
  state.code_scope <-
    (match scope with
     | Tui_decode.Repository_change_project -> Code_scope_project
     | Tui_decode.Repository_change_repository repository_id ->
         Code_scope_repo repository_id);
  let parent = Filename.dirname change.rc_path in
  state.code_dir <- (if String.equal parent "." then "" else parent);
  state.code_cursor <- 0;
  state.code_entries <- [];
  state.code_entries_error <- None;
  state.code_file <- None;
  state.code_file_error <- None;
  state.code_focus_file <- Left_pane;
  close_repository_changes state;
  state.view <- Code;
  launch_code_entries_load state ~mailbox;
  launch_code_file_load state ~mailbox ~path:change.rc_path

(* Where the change is on this machine.

   All three shapes resolve inside the keeper's own bundle, because that is
   where the write happened. An operator's checkout of the same repository is
   a different tree and this surface does not know where it is; naming the
   keeper's copy is the answer that is true.

   A Docker keeper's bundle is not on this filesystem at all, so the path may
   not exist. The caller checks before handing it to an editor rather than
   opening an empty buffer under a real file's name. *)
let change_absolute_path ~base_path (change : Masc.Tui_decode.file_change) =
  let bundle =
    Filename.concat base_path
      (Playground_paths.bundle_root change.Masc.Tui_decode.fc_keeper)
  in
  match change.Masc.Tui_decode.fc_location with
  | Masc.Tui_decode.Fc_at_absolute_path { path } -> path
  | Masc.Tui_decode.Fc_in_bundle { bundle_path } -> Filename.concat bundle bundle_path
  | Masc.Tui_decode.Fc_in_repo { repo_id; relative_path } ->
      Filename.concat bundle
        (Playground_paths.bundle_relative_repo_path ~repo_id relative_path)

(* The address the git-diff read wants: relative to the keeper's playground,
   because that is the root the server resolves ?keeper= against. Absolute
   writes have no such address -- a worktree beside the clones is not under
   the playground -- so they have no tree reading either, and the caller is
   told rather than sent a path the server would resolve somewhere else. *)
let change_bundle_relative_path (change : Masc.Tui_decode.file_change) =
  match change.Masc.Tui_decode.fc_location with
  | Masc.Tui_decode.Fc_in_bundle { bundle_path } -> Some bundle_path
  | Masc.Tui_decode.Fc_in_repo { repo_id; relative_path } ->
      Some (Playground_paths.bundle_relative_repo_path ~repo_id relative_path)
  | Masc.Tui_decode.Fc_at_absolute_path _ -> None

(* The window the Changes surface asks for. A day is what an operator means
   by "what has this keeper been doing"; the server's own ceiling is what the
   read costs, and it clamps anything wider. *)
let changes_window_hours = 24.0

let launch_file_changes_load state ~mailbox ~keeper_name =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        Masc_tui_loader.load_keeper_file_changes ~host ~port ~keeper_name
          ~window_hours:changes_window_hours
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (File_changes_loaded (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (File_changes_loaded (keeper_name, Error "Eio switch is unavailable"))

let launch_keeper_chat_file_changes_load ?(force = false) state ~mailbox
    ~keeper_name =
  if state.msg_tool_visibility <> Tools_full then ()
  else begin
    if
      not
        (Option.equal String.equal state.msg_file_changes_keeper
           (Some keeper_name))
    then reset_message_file_changes state keeper_name;
    if state.msg_file_changes_loading then
      if force then state.msg_file_changes_refresh_pending <- true else ()
    else if
      (Option.is_some state.msg_file_changes
       || Option.is_some state.msg_file_changes_error)
      && not force
    then ()
    else begin
      state.msg_file_changes_generation <- state.msg_file_changes_generation + 1;
      let generation = state.msg_file_changes_generation in
      state.msg_file_changes_loading <- true;
      state.msg_file_changes_refresh_pending <- false;
      state.msg_file_changes_error <- None;
      let host = server_peer_host in
      let port = state.port in
      let run () =
        let result =
          try
            Masc_tui_loader.load_keeper_file_changes ~host ~port ~keeper_name
              ~window_hours:changes_window_hours
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        enqueue_async mailbox
          (Keeper_chat_file_changes_loaded (generation, keeper_name, result))
      in
      match Eio_context.get_switch_opt () with
      | Some sw ->
          Eio.Fiber.fork_daemon ~sw (fun () ->
              run ();
              `Stop_daemon)
      | None ->
          enqueue_async mailbox
            (Keeper_chat_file_changes_loaded
               ( generation
               , keeper_name
               , Error "Eio switch is unavailable" ))
    end
  end

let launch_keeper_chat_tool_details_load ?(force = false) state ~mailbox
    ~keeper_name =
  if state.msg_tool_visibility <> Tools_full then ()
  else begin
    launch_keeper_chat_file_changes_load ~force state ~mailbox ~keeper_name;
    launch_keeper_calls_load ~force state ~mailbox keeper_name
  end

(* Changes follows the selected Keeper, but the surface is useful precisely
   when comparing more than one Keeper. Brackets move that shared selection
   and invalidate every row whose identity belonged to the previous Keeper;
   the stamped async response below already rejects a late answer. *)
let cycle_changes_keeper state ~mailbox ~delta =
  let count = List.length state.keepers in
  if count > 0 then begin
    let current =
      match state.changes_keeper with
      | Some keeper_name ->
          let rec find index = function
            | [] -> min state.keeper_cursor (count - 1)
            | (keeper : keeper) :: rest ->
                if String.equal keeper.k_name keeper_name
                then index
                else find (index + 1) rest
          in
          find 0 state.keepers
      | None -> min state.keeper_cursor (count - 1)
    in
    let next = (current + delta + count) mod count in
    match List.nth_opt state.keepers next with
    | None -> ()
    | Some keeper ->
        state.keeper_cursor <- next;
        state.changes_keeper <- Some keeper.k_name;
        state.changes <- None;
        state.changes_error <- None;
        state.changes_cursor <- 0;
        state.changes_scroll <- 0;
        state.changes_diff_row <- None;
        state.changes_diff_scroll <- 0;
        state.changes_tree_diff <- None;
        state.changes_tree_diff_error <- None;
        state.changes_tree_diff_path <- None;
        launch_file_changes_load state ~mailbox ~keeper_name:keeper.k_name
  end

(* What the tree holds for one file, against its last commit. HEAD rather
   than a branch point: the question the surface answers is "did this survive
   into the tree", and a merge base would answer a different one. *)
let launch_git_diff_load state ~mailbox ~keeper ~path =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        Masc_tui_loader.load_git_diff ~host ~port ~keeper ~path
          ~base_ref:tree_diff_base_ref ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Git_diff_loaded (path, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Git_diff_loaded (path, Error "Eio switch is unavailable"))

let launch_harness_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_harness ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Harness_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None -> enqueue_async mailbox (Harness_loaded (Error "Eio switch is unavailable"))

let launch_fusion_runs_load state ~mailbox =
  match state.fusion_runs_inflight with
  | Some _ -> ()
  | None ->
      state.fusion_runs_generation <- state.fusion_runs_generation + 1;
      let generation = state.fusion_runs_generation in
      state.fusion_runs_inflight <- Some generation;
      let host = server_peer_host in
      let port = state.port in
      let run () =
        let result =
          try Masc_tui_loader.load_fusion_runs ~host ~port with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)
        in
        enqueue_async mailbox (Fusion_runs_loaded (generation, result))
      in
      (match Eio_context.get_switch_opt () with
       | Some sw ->
           Eio.Fiber.fork_daemon ~sw (fun () ->
               run ();
               `Stop_daemon)
       | None ->
           enqueue_async mailbox
             (Fusion_runs_loaded
                (generation, Error "Eio switch is unavailable")))

let launch_fusion_detail_load state ~mailbox ~run_id =
  let already_loading =
    match state.fusion_detail_inflight with
    | Some (generation, loading_run_id) ->
        generation = state.fusion_detail_generation
        && String.equal loading_run_id run_id
    | None -> false
  in
  if not already_loading then begin
    state.fusion_detail_generation <- state.fusion_detail_generation + 1;
    let generation = state.fusion_detail_generation in
    state.fusion_detail_inflight <- Some (generation, run_id);
    let host = server_peer_host in
    let port = state.port in
    let run () =
      let result =
        try Masc_tui_loader.load_fusion_detail ~host ~port ~run_id with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Printexc.to_string exn)
      in
      enqueue_async mailbox (Fusion_detail_loaded (generation, run_id, result))
    in
    match Eio_context.get_switch_opt () with
    | Some sw ->
        Eio.Fiber.fork_daemon ~sw (fun () ->
            run ();
            `Stop_daemon)
    | None ->
        enqueue_async mailbox
          (Fusion_detail_loaded
             (generation, run_id, Error "Eio switch is unavailable"))
  end

let launch_keeper_lanes_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let keeper_result =
      try Masc_tui_loader.load_keeper_lanes ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Lanes_loaded keeper_result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox (Lanes_loaded (Error "Eio switch is unavailable"))

let launch_lanes_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  state.standalone_lanes_generation <- state.standalone_lanes_generation + 1;
  let standalone_generation = state.standalone_lanes_generation in
  let run () =
    let standalone_result =
      try Masc_tui_loader.load_standalone_lanes ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox
      (Standalone_lanes_loaded (standalone_generation, standalone_result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Standalone_lanes_loaded
           (standalone_generation, Error "Eio switch is unavailable"))

let launch_clients_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  state.clients_surface_generation <- state.clients_surface_generation + 1;
  let generation = state.clients_surface_generation in
  let run () =
    let result =
      try Masc_tui_loader.load_clients ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Clients_loaded (generation, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork_daemon ~sw (fun () -> run (); `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Clients_loaded (generation, Error "Eio switch is unavailable"))

let launch_lane_runs_load state ~mailbox ~lane_id =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_http.fetch_lane_runs ~host ~port ~lane:lane_id with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Lane_runs_loaded (lane_id, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Lane_runs_loaded (lane_id, Error "Eio switch is unavailable"))

let launch_lane_run_detail_load state ~mailbox ~run_id =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_http.fetch_lane_run_detail ~host ~port ~run_id with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Lane_run_detail_loaded (run_id, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Lane_run_detail_loaded (run_id, Error "Eio switch is unavailable"))

(* Opening a standalone lane's runs drops the previous lane's list so a stale
   answer can never draw under the new heading. *)
let open_lane_run_list state ~mailbox (lane : Tui_decode.standalone_lane) =
  state.lanes_mode <- Lanes_run_list lane.sl_lane_id;
  state.lane_runs <- None;
  state.lane_runs_error <- None;
  state.lane_runs_cursor <- 0;
  state.lane_runs_scroll <- 0;
  launch_lane_runs_load state ~mailbox ~lane_id:lane.sl_lane_id

let open_lane_run_detail state ~mailbox ~lane_id ~run_id =
  state.lanes_mode <- Lanes_run_detail (lane_id, run_id);
  state.lane_run_detail <- None;
  state.lane_run_detail_error <- None;
  state.lane_run_detail_scroll <- 0;
  launch_lane_run_detail_load state ~mailbox ~run_id

let launch_verification_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_verification ~host ~port ~limit:200 with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Verification_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None -> enqueue_async mailbox (Verification_loaded (Error "Eio switch is unavailable"))

(* Move the active surface's row cursor to the next row whose search text
   contains [query], scanning from [after] and wrapping; [backwards] walks
   the other way. A miss moves nothing. The searched list is the one
   [surface_row_texts] answers -- the same list the row cursor names -- and
   the window follows the landing so the match is visible. *)
let search_row_cursor state =
  match state.view with
  | Keepers Keeper_list -> Some state.keeper_cursor
  | Lanes -> Some state.lanes_standalone_cursor
  | Clients -> Some state.clients_surface_cursor
  | Verification ->
      if Option.is_some state.verification_detail_request_id then None
      else Some state.verification_cursor
  | Harness -> Some state.harness_cursor
  | Memory ->
      Some
        (if Option.is_some state.memory_facts_keeper then
           state.memory_facts_cursor
         else state.memory_health_cursor)
  | Repositories ->
      Some
        (if state.repository_changes_open then state.repository_changes_cursor
         else state.repositories_cursor)
  | Connectors -> Some state.connectors_cursor
  | Runtime -> Some state.runtime_cursor
  | System_logs -> Some state.system_logs_cursor
  | Code ->
      if state.repository_changes_open then
        Some state.repository_changes_cursor
      else if
        state.code_focus_file = Right_pane && not state.code_history_open
        && not state.code_diff_open && not state.code_notes_open
      then Some state.code_file_cursor
      else Some state.code_cursor
  | Board ->
      (match state.board_mode with
       | Board_read _ | Board_compose -> None
       | Board_list -> Some state.board_cursor)
  | Planning ->
      (match state.planning_mode with
       | Planning_detail _ -> None
       | Planning_list -> Some state.planning_cursor)
  (* Named rather than left to a wildcard. [surface_row_texts] is exhaustive
     and will name a new surface; this used to end in [_ -> None], so a
     surface given searchable rows there still had no cursor to move here and
     the key did nothing. The three matches -- the rows, this reading, and
     the write below -- have to agree, and only naming every surface makes
     the compiler say so. *)
  | Overview | Acting | Keepers Keeper_detail | Keepers Keeper_logs
  | Keepers Keeper_calls | Keepers Keeper_message | Keepers Keeper_runtime_pick
  | Approvals | Schedules | Fusion | Changes | Config | Resources | Tools ->
      None

let search_land state index =
  let follow ?(cursor = index) scroll set_scroll =
    match scrolled_surface state state.view with
    | None -> ()
    | Some scrolled ->
        (* Through [surface_body_height], not [rows - sc_chrome]. A surface that
           gives half its rows to a preview says so in [sc_preview_keep], and a
           height that ignores it lands the cursor under the preview while
           [ensure_visible] reports the row as already on screen. Both movers
           ask the same helper for the same reason. *)
        let height = surface_body_height ~rows:(surface_rows state) scrolled in
        set_scroll (Masc_tui_scroll.ensure_visible ~cursor ~height scroll)
  in
  match state.view with
  | Keepers Keeper_list -> state.keeper_cursor <- index
  | Keepers Keeper_detail when state.context_inspector_open ->
      (* A landed search row is a new item: its reader starts at the top of
         the detail, the way a j/k move does. *)
      state.context_inspector_cursor <- index;
      state.context_inspector_detail_scroll <- 0
  | Lanes -> state.lanes_standalone_cursor <- index
  | Clients ->
      state.clients_surface_cursor <- index;
      follow state.clients_surface_scroll (fun s -> state.clients_surface_scroll <- s)
  | Verification ->
      state.verification_cursor <- index;
      follow state.verification_scroll (fun s -> state.verification_scroll <- s)
  | Harness ->
      state.harness_cursor <- index;
      follow state.harness_scroll (fun s -> state.harness_scroll <- s)
  | Memory ->
      if Option.is_some state.memory_facts_keeper then begin
        state.memory_facts_cursor <- index;
        follow state.memory_facts_scroll
          (fun s -> state.memory_facts_scroll <- s)
      end
      else begin
        state.memory_health_cursor <- index;
        follow state.memory_health_scroll
          (fun s -> state.memory_health_scroll <- s)
      end
  | Repositories ->
      if state.repository_changes_open then begin
        state.repository_changes_cursor <- index;
        follow state.repository_changes_scroll
          (fun s -> state.repository_changes_scroll <- s)
      end
      else begin
        state.repositories_cursor <- index;
        follow state.repositories_scroll (fun s -> state.repositories_scroll <- s)
      end
  | Connectors ->
      state.connectors_cursor <- index;
      follow state.connectors_scroll (fun s -> state.connectors_scroll <- s)
  | Runtime ->
      state.runtime_cursor <- index;
      follow state.runtime_surface_scroll
        (fun s -> state.runtime_surface_scroll <- s)
  | System_logs ->
      state.system_logs_cursor <- index;
      follow state.system_logs_scroll (fun s -> state.system_logs_scroll <- s)
  | Code ->
      if state.repository_changes_open then begin
        state.repository_changes_cursor <- index;
        follow state.repository_changes_scroll
          (fun s -> state.repository_changes_scroll <- s)
      end
      else if
        state.code_focus_file = Right_pane && not state.code_history_open
        && not state.code_diff_open && not state.code_notes_open
      then begin
        state.code_file_cursor <- index;
        state.code_file_scroll <-
          Masc_tui_scroll.ensure_visible ~cursor:index
            ~height:(Masc_tui_render.code_pane_content_height state)
            state.code_file_scroll
      end
      else
        (* The tree pane windows itself around the cursor; no scroll
           follows. *)
        state.code_cursor <- index
  (* Listed rather than caught. A surface becomes searchable by being added to
     [surface_row_texts], which is exhaustive and will name the new variant at
     compile time; this match has to move with it or the search finds a row and
     then goes nowhere. A [_] here would let the two drift apart silently, and
     the drift shows up as a search that quietly does nothing. *)
  (* These three lists window themselves around the cursor when they draw --
     the same reason the Code tree above takes no [follow] -- so the landing
     is on screen without a scroll to move. [state.board_scroll] is the
     reading pane's, not the list's. *)
  | Board ->
      (match state.board_mode with
       | Board_read _ | Board_compose -> ()
       | Board_list -> state.board_cursor <- index)
  | Planning ->
      (match state.planning_mode with
       | Planning_detail _ -> ()
       | Planning_list -> state.planning_cursor <- index)
  | Overview | Acting | Keepers Keeper_detail | Keepers Keeper_logs
  | Keepers Keeper_calls | Keepers Keeper_message | Keepers Keeper_runtime_pick
  | Approvals | Schedules | Fusion | Changes | Config
  | Resources | Tools ->
      ()

(* Standalone rows never scroll, so an action notice only has to be retained
   until movement or navigation clears it. *)
let show_lanes_action_error state detail =
  state.lanes_action_error <- Some detail

let search_jump ?(backwards = false) state ~query ~after =
  let query = String.lowercase_ascii query in
  match surface_row_texts state state.view with
  | None -> ()
  | Some texts ->
      let total = List.length texts in
      if String.length query > 0 && total > 0 then begin
        let matches index =
          match List.nth_opt texts index with
          | Some text -> Masc_tui_types.palette_contains ~needle:query text
          | None -> false
        in
        let rec scan step =
          if step > total then ()
          else begin
            let index =
              if backwards then (after - step + (total * 2)) mod total
              else (after + step + total) mod total
            in
            if matches index then begin
              if state.view = Lanes then state.lanes_action_error <- None;
              search_land state index
            end
            else scan (step + 1)
          end
        in
        scan 1
      end

(* Move to a surface, fetching what that surface shows on arrival. Tab,
   Shift-Tab, and any future jump go through here so no direction can forget
   a load the other performs. Surfaces not listed refresh on the periodic
   cadence ([surface_needs]); the ones here are snapshots that would
   otherwise read as empty until the next tick. *)
let goto_surface state ~mailbox (destination : surface) =
  if state.repository_changes_open && destination <> state.view then
    close_repository_changes state;
  if state.view = Lanes || destination = Lanes then
    state.lanes_action_error <- None;
  (match destination with
   | Lanes -> launch_lanes_load state ~mailbox
   | Clients -> launch_clients_load state ~mailbox
   | Keepers Keeper_list -> launch_keeper_lanes_load state ~mailbox
   | Approvals ->
       launch_keeper_tool_approvals_load state ~mailbox;
       launch_gate_snapshot_load state ~mailbox
   | Schedules -> launch_schedules_load state ~mailbox
   | Verification -> launch_verification_load state ~mailbox
   | Planning -> launch_verification_load state ~mailbox
   | Harness -> launch_harness_load state ~mailbox
   | Fusion ->
       launch_fusion_runs_load state ~mailbox;
       (match state.fusion_mode with
        | Fusion_list -> ()
        | Fusion_detail run_id ->
            launch_fusion_detail_load state ~mailbox ~run_id)
   | Memory -> launch_memory_health_load state ~mailbox
   | Repositories -> launch_repositories_load state ~mailbox
   | Changes -> (
       (* The surface follows whoever is selected on Keepers. Arriving with a
          different keeper selected than the one already loaded drops the old
          rows first: showing one keeper's files under another's name for the
          length of a request is the confusion this surface exists to end. *)
       let selected = Option.map (fun (k : keeper) -> k.k_name) (selected_keeper state) in
       (match selected with
        | Some name when not (Option.equal String.equal state.changes_keeper (Some name)) ->
            state.changes_keeper <- Some name;
            state.changes <- None;
            state.changes_error <- None;
            state.changes_cursor <- 0;
            state.changes_scroll <- 0;
            state.changes_diff_row <- None;
            state.changes_diff_scroll <- 0
        | Some _ | None -> ());
       match state.changes_keeper with
       | Some keeper_name -> launch_file_changes_load state ~mailbox ~keeper_name
       | None -> ())
   | Connectors -> launch_connectors_load state ~mailbox
   | Runtime -> launch_runtime_surface_load state ~mailbox ~force:false
   | Tools -> launch_tools_load state ~mailbox
   | Config -> (
       (* Each pane loads its own source. Named rather than left to an
          if/else chain: a pane added later should have to say where its data
          comes from instead of quietly inheriting runtime.toml's. *)
       match state.config_pane with
       | Config_prompts -> launch_prompts_load state ~mailbox
       | Config_presets -> launch_presets_load state ~mailbox
       | Config_params -> launch_runtime_params_load state ~mailbox
       | Config_voice -> launch_voice_config_load state ~mailbox
       | Config_runtime | Config_models | Config_themes ->
           launch_runtime_config_load state ~mailbox)
   | Resources -> launch_resources_list state ~mailbox
   | Code -> launch_code_entries_load state ~mailbox
   | Overview | Acting | Keepers _ | Board | System_logs -> ());
  (* Leaving Approvals drops a half-armed decision, exactly as the old Tab
     arm did on the Approvals -> Board step. *)
  (match state.view with
   | Approvals when destination <> Approvals ->
       state.pending_approval_action <- None
   | _ -> ());
  state.view <- destination

(* One step around the ring the surface strip draws. Tab and Shift-Tab
   call this; so does board compose when its handler declines the key, so
   "Tab falls through" stays true while composing. *)
let cycle_surface state ~mailbox ~backwards =
  let ring = Masc_tui_types.surface_ring in
  let count = List.length ring in
  let step = if backwards then count - 1 else 1 in
  let index =
    (Masc_tui_types.surface_ring_index state.view + step) mod count
  in
  goto_surface state ~mailbox (fst (List.nth ring index))

let launch_keeper_older_page state ~mailbox ~keeper_name ~before =
  let host = server_peer_host in
  let port = state.port in
  let generation = state.msg_history_load_generation in
  state.msg_older_loading <- true;
  let run () =
    let result =
      try
        Masc_tui_http.fetch_keeper_chat_history_page ~host ~port ~keeper_name
          ~before
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox
      (Keeper_chat_older_loaded (generation, keeper_name, before, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_chat_older_loaded
           (generation, keeper_name, before, Error "Eio switch is unavailable"))

let launch_keeper_history_load ?(load_file_changes = true) state ~mailbox
    ~keeper_name =
  let host = server_peer_host in
  let port = state.port in
  state.msg_history_load_generation <- state.msg_history_load_generation + 1;
  state.msg_older_loading <- false;
  state.msg_memory_error <- None;
  state.msg_memory_dropped <- 0;
  let generation = state.msg_history_load_generation in
  let run () =
    let history_result =
      try Masc_tui_http.fetch_keeper_chat_history ~host ~port ~keeper_name with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    let memory_result =
      try Masc_tui_http.fetch_keeper_memory_journal ~host ~port ~keeper_name with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox
      (Keeper_chat_history_loaded
         (generation, keeper_name, history_result, memory_result))
  in
  (match Eio_context.get_switch_opt () with
   | Some sw ->
       Eio.Fiber.fork_daemon ~sw (fun () ->
           run ();
           `Stop_daemon)
   | None ->
       enqueue_async mailbox
         (Keeper_chat_history_loaded
            ( generation
            , keeper_name
            , Error "Eio switch is unavailable"
            , Error "Eio switch is unavailable" )));
  (* Full tool detail owns the only lazy read. Compact chat remains byte- and
     network-compatible; repeated history refreshes reuse this separate cache. *)
  if load_file_changes then
    launch_keeper_chat_tool_details_load state ~mailbox ~keeper_name

let launch_context_inspector_load state ~mailbox ~keeper_name =
  let host = server_peer_host in
  let port = state.port in
  state.context_inspector_generation <- state.context_inspector_generation + 1;
  state.context_inspector_loading <- true;
  let generation = state.context_inspector_generation in
  let turn_back = state.context_inspector_turn_back in
  let run () =
    let reading =
      try
        Masc_tui_http.fetch_keeper_context_inspector ~host ~port ~keeper_name
          ~turn_back
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          let error = Error (Printexc.to_string exn) in
          { Masc_tui_context_inspector.turn = error
          ; provider_input = error
          ; response = error
          }
    in
    enqueue_async mailbox
      (Context_inspector_loaded (generation, keeper_name, reading))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      let error = Error "Eio switch is unavailable" in
      enqueue_async mailbox
        (Context_inspector_loaded
           ( generation
           , keeper_name
           , { Masc_tui_context_inspector.turn = error
             ; provider_input = error
             ; response = error
             } ))

let open_context_inspector state ~mailbox ~keeper_name =
  state.context_inspector_open <- true;
  state.context_inspector_keeper <- Some keeper_name;
  (* A fresh Keeper target starts unread. Showing the previous Keeper's
     already-loaded composition under this name while the GET is in flight
     would be a more dangerous lie than a loading row. Refreshing the same
     target keeps its reading; opening a target does not. *)
  state.context_inspector_reading <- None;
  state.context_inspector_tab <- Masc_tui_context_inspector.Composition;
  state.context_inspector_cursor <- 0;
  state.context_inspector_scroll <- 0;
  state.context_inspector_exact <- None;
  state.context_inspector_turn_back <- 0;
  launch_context_inspector_load state ~mailbox ~keeper_name

let switch_to_next_keeper_message state ~mailbox =
  match next_keeper_message_target state with
  | Masc_tui_keeper_selection.No_alternative -> ()
  | Masc_tui_keeper_selection.Switch_to { keeper_name; cursor } ->
      open_message_for_keeper ~return_to:state.msg_return state keeper_name;
      state.keeper_cursor <- cursor;
      set_msg_scroll state 0;
      state.msg_loaded <- [];
      state.msg_loaded_keeper <- None;
      state.msg_loaded_error <- None;
      state.msg_loaded_dropped <- 0;
      state.msg_memory_error <- None;
      state.msg_memory_dropped <- 0;
      state.msg_older_cursor <- None;
      state.msg_older_exist <- false;
      state.msg_older_loading <- false;
      state.msg_older_error <- None;
      launch_keeper_history_load state ~mailbox ~keeper_name

(* Rows this session wrote that the transcript now carries. Dropped so the same
   turn is not drawn twice, once from each source.

   Four roles go on sight: the server holds every user line, keeper line, tool
   block and reasoning block.

   Errors used to be kept on sight for the opposite reason. Most are notices
   the server has no row for -- a blocked dispatch, a recovery fence waiting on
   Ctrl-R -- and dropping those loses the only record of them. A failed turn is
   the overlap the server does record, so it showed twice, which was the price
   of not being able to tell the two apart.

   The transcript can say which it is. The server persists a failed turn under
   the operation it ran, and that operation is the id this session dispatched
   under, so a session error row goes exactly when the transcript arrives
   carrying one for its request. Until then it stays -- a persist the server
   could not finish never produces that row, and the session keeps the only
   record, which is what keeping every error row was protecting. *)
let forget_session_rows_the_transcript_holds state keeper_name rows =
  let user_turns_the_transcript_holds =
    List.filter_map
      (fun (row : Keeper_chat_history.row) ->
        match row.Keeper_chat_history.kind with
        | Keeper_chat_history.Addressed_to_keeper _ -> row.turn_id
        | Keeper_chat_history.Said_by_keeper
        | Keeper_chat_history.Autonomous_reply
        | Keeper_chat_history.Delivery_failed _
        | Keeper_chat_history.Tool_calls _
        | Keeper_chat_history.Skill_activity _
        | Keeper_chat_history.Reasoning _
        | Keeper_chat_history.Gate_activity _
        | Keeper_chat_history.Memory_activity _ ->
            None)
      rows
  in
  let failures_the_transcript_holds =
    List.filter_map
      (fun (row : Keeper_chat_history.row) ->
        match row.Keeper_chat_history.kind with
        | Keeper_chat_history.Delivery_failed { origin_request_id; _ } ->
            origin_request_id
        | Keeper_chat_history.Addressed_to_keeper _
        | Keeper_chat_history.Said_by_keeper
        | Keeper_chat_history.Autonomous_reply
        | Keeper_chat_history.Tool_calls _
        | Keeper_chat_history.Skill_activity _
        | Keeper_chat_history.Reasoning _
        | Keeper_chat_history.Gate_activity _
        | Keeper_chat_history.Memory_activity _ -> None)
      rows
  in
  state.msg_history <-
    List.filter
      (fun entry ->
        (not (String.equal entry.me_keeper_name keeper_name))
        ||
        match entry.me_role with
        (* Neither is in the transcript a refresh brings back -- the gate rows
           because the refresh does not carry them, this one because it never
           went to the server at all -- so both are kept. *)
        | Message_status | Message_local -> true
        | Message_error ->
            String.equal entry.me_request_id ""
            || not
                 (List.exists
                    (String.equal entry.me_request_id)
                    failures_the_transcript_holds)
        | Message_user _ ->
            (* Queue membership is not proof that a row reached the server,
               and leaving the queue is not proof either: the next request can
               enter [msg_inflight] before a transcript refresh started for the
               previous turn comes back. Replace this session row only when
               the exact request id is in the snapshot being applied. *)
            not
              (List.exists (String.equal entry.me_request_id)
                 user_turns_the_transcript_holds)
        | Message_keeper | Message_autonomous | Message_tool | Message_skill _
        | Message_thinking | Message_memory ->
            false)
      state.msg_history

let locally_submitted_at state keeper_name request_id =
  List.find_map
    (fun entry ->
      match entry.me_role with
      | Message_user (Sent_by_operator _)
        when String.equal entry.me_keeper_name keeper_name
             && String.equal entry.me_request_id request_id ->
          entry.me_submitted_at
      (* [Sent_by_operator] is listed again because the arm above it is
         guarded: an operator row for another keeper or request falls through
         to here rather than matching that one. *)
      | Message_user (Sent_by_operator _ | Sent_by_other _)
      | Message_keeper | Message_autonomous
      | Message_status | Message_local | Message_error | Message_tool
      | Message_skill _ | Message_thinking
      | Message_memory -> None)
    (state.msg_history @ state.msg_loaded)
;;

let msg_entry_of_history_row state keeper_name ~operation_seq
    (row : Keeper_chat_history.row) =
  let gate =
    match row.Keeper_chat_history.kind with
    | Keeper_chat_history.Gate_activity { approval_id; phase; tool } ->
        Some
          { gs_approval_id = approval_id; gs_phase = phase; gs_tool = tool }
    | Keeper_chat_history.Memory_activity _
    | Keeper_chat_history.Addressed_to_keeper _
    | Keeper_chat_history.Said_by_keeper
    | Keeper_chat_history.Autonomous_reply
    | Keeper_chat_history.Delivery_failed _
    | Keeper_chat_history.Tool_calls _
    | Keeper_chat_history.Skill_activity _
    | Keeper_chat_history.Reasoning _ -> None
  in
  let memory_summary =
    match row.Keeper_chat_history.kind with
    | Keeper_chat_history.Memory_activity { summary } -> summary
    | Keeper_chat_history.Gate_activity _
    | Keeper_chat_history.Addressed_to_keeper _
    | Keeper_chat_history.Said_by_keeper
    | Keeper_chat_history.Autonomous_reply
    | Keeper_chat_history.Delivery_failed _
    | Keeper_chat_history.Tool_calls _
    | Keeper_chat_history.Skill_activity _
    | Keeper_chat_history.Reasoning _ ->
        None
  in
  let role, turn_phase, text, tool_block, skill_activity =
    match row.Keeper_chat_history.kind with
    | Keeper_chat_history.Addressed_to_keeper { speaker; surface } ->
        (* The label is what the row draws; the speaker is what it is. Both
           come from the same decode, and only the label used to survive. *)
        let label = Keeper_chat_history.addressed_label speaker surface in
        let author =
          match speaker with
          | Keeper_chat_history.Operator -> Sent_by_operator label
          | Keeper_chat_history.Named _
          | Keeper_chat_history.Unresolved _ -> Sent_by_other label
        in
        (Message_user author, Turn_input, row.text, None, None)
    | Keeper_chat_history.Said_by_keeper ->
        (Message_keeper, Turn_output, row.text, None, None)
    | Keeper_chat_history.Autonomous_reply ->
        ( Message_autonomous
        , Turn_output
        , (if String.trim row.text = "" then "\xc2\xb7" else row.text)
        , None
        , None )
    | Keeper_chat_history.Delivery_failed { recovered_at; _ } ->
        let text, recovered =
          match
            Keeper_chat_history.present_delivery_failure ?recovered_at row.text
          with
          | Some presented -> presented
          | None -> row.text, false
        in
        ( (if recovered then Message_status else Message_error)
        , Turn_output
        , text
        , None
        , None )
    | Keeper_chat_history.Tool_calls block ->
        ( Message_tool
        , Turn_tool
        , String.concat "\n" (Keeper_chat_history.tool_rows block)
        , Some block
        , None )
    | Keeper_chat_history.Skill_activity activity ->
        ( Message_skill activity.Keeper_chat_transcript.state
        , Turn_progress
        , String.concat "\n"
            (Keeper_chat_transcript.skill_rows ~full:false activity)
        , None
        , Some activity )
    | Keeper_chat_history.Reasoning lines ->
        (Message_thinking, Turn_progress, String.concat "\n" lines, None, None)
    | Keeper_chat_history.Gate_activity { approval_id = _; phase; tool } ->
        (* Server-owned gate status, drawn from the phase rather than from
           the sentence the store composed. It is not Memory: putting it in
           that lane interleaved approvals with journal commits, and hiding
           the journal hid the gate with it. *)
        ( Message_status
        , Turn_progress
        , Masc_tui_gate_text.lifecycle_line ~phase ~tool
        , None
        , None )
    | Keeper_chat_history.Memory_activity _ ->
        (Message_memory, Turn_progress, row.text, None, None)
  in
  let submitted_at =
    match row.Keeper_chat_history.kind, row.Keeper_chat_history.turn_id with
    | Keeper_chat_history.Addressed_to_keeper _, Some request_id ->
        locally_submitted_at state keeper_name request_id
    | (Keeper_chat_history.Said_by_keeper
      | Keeper_chat_history.Autonomous_reply
      | Keeper_chat_history.Delivery_failed _
      | Keeper_chat_history.Tool_calls _
      | Keeper_chat_history.Skill_activity _
      | Keeper_chat_history.Reasoning _
      | Keeper_chat_history.Gate_activity _
      | Keeper_chat_history.Memory_activity _), _
    | Keeper_chat_history.Addressed_to_keeper _, None -> None
  in
  let timestamp =
    let source_at =
      Option.value ~default:row.Keeper_chat_history.at submitted_at
    in
    if Float.is_finite source_at && source_at > 0.
    then clock_text_of_unix source_at
    else "--:--:--"
  in
  (* A file the row carries, said on a line of its own under the words. The
     store has held these since the composer learned to stage one; the pane
     never looked, so a message that arrived with a 70 KB image read as the
     sentence beside it and nothing else.

     Named, not drawn: the bytes stay where they are and [Ctrl-O] opens a path
     the conversation mentions. What the reader needs here is to know a file
     is there at all. *)
  let text =
    Keeper_chat_history.text_with_attachments
      ~format_bytes:Masc_tui_context_inspector.format_bytes ~text
      ~notes:row.Keeper_chat_history.attachments
  in
  { me_role = role
  ; me_identity =
      (match row.Keeper_chat_history.structural_id with
       | Some id -> Persisted_row id
       | None ->
           Persisted_legacy_row
             { request_id = Option.value ~default:"" row.turn_id
             ; operation_seq
             })
  ; me_turn_phase = turn_phase
  ; me_turn_sequence = row.Keeper_chat_history.turn_sequence
  ; me_operation_seq = operation_seq
  ; me_text = Keeper_chat.terminal_safe_text ~preserve_newlines:true text
  ; me_memory_summary =
      Option.map
        (Keeper_chat.terminal_safe_text ~preserve_newlines:false)
        memory_summary
  ; me_gate = gate
  ; me_submitted_at = submitted_at
  ; me_tool_block = tool_block
  ; me_skill_activity = skill_activity
  ; me_timestamp = timestamp
  ; me_keeper_name = keeper_name
  ; (* Direct rows retain their typed delivery key; autonomous rows retain the
       persisted turn_ref. Old rows and Memory journal entries carry neither,
       so the empty value continues to mean "no grouping authority". *)
    me_request_id = Option.value ~default:"" row.Keeper_chat_history.turn_id
  ; me_at = row.Keeper_chat_history.at
  }

let msg_entries_of_history_rows state keeper_name rows =
  let next_by_request = Hashtbl.create 16 in
  List.map
    (fun (row : Keeper_chat_history.row) ->
      let request_id = Option.value ~default:"" row.turn_id in
      let operation_seq =
        Option.value ~default:0 (Hashtbl.find_opt next_by_request request_id)
      in
      Hashtbl.replace next_by_request request_id (operation_seq + 1);
      msg_entry_of_history_row state keeper_name ~operation_seq row)
    rows
;;

let launch_keeper_interrupt state ~mailbox (request : Keeper_chat.request) =
  let host = server_peer_host in
  let port = state.port in
  let keeper_name = request.Keeper_chat.keeper_name in
  let request_id = request.Keeper_chat.request_id in
  let run () =
    let result =
      try
        Masc_tui_http.post_keeper_turn_interrupt ~host ~port ~keeper_name
          ~request_id
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_chat_interrupt_done (request, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_chat_interrupt_done (request, Error "Eio switch is unavailable"))

(* Fetch the runtime catalogue and assignments for the picker. *)
(* Append one runtime to a lane's candidate order. Appending rather than
   replacing is the whole point: a lane whose two slots share a provider has
   no failover when that provider is down, and the fix is one more candidate
   from somewhere else, not a different single one. The server previews the
   resulting runtime.toml and refuses an unknown id, so this sends and reads
   the verdict rather than validating here. *)
(* The picker's list, ordered so the candidate a lane actually needs is at
   the top. Computed in both the key handler and the renderer from the same
   snapshot rather than stored: a cached order and a re-read snapshot drift,
   and the cursor would then point at a different runtime than the one drawn. *)
let runtime_lane_picker_rows (state : state) =
  match state.runtime_lane_pick, state.runtime_surface with
  | Some lane, Some snapshot ->
      let open Masc.Tui_decode in
      let already =
        snapshot.rss_resolved.rrs_lanes
        |> List.find_opt (fun (l : runtime_resolved_lane) ->
             String.equal l.rrl_id lane)
        |> function Some l -> l.rrl_runtime_ids | None -> []
      in
      let lane_providers =
        already
        |> List.filter_map (fun id ->
             List.find_opt
               (fun (r : runtime_option) -> String.equal r.ro_id id)
               state.runtime_catalog
             |> Option.map (fun (r : runtime_option) -> r.ro_provider))
      in
      ( already
      , Masc_tui_types.runtimes_for_lane_picker ~lane_providers ~already
          state.runtime_catalog )
  | _ -> [], []
;;

let launch_runtime_lane_append state ~mailbox ~lane ~runtime_id ~existing =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      if List.exists (String.equal runtime_id) existing then
        Error (runtime_id ^ " is already a candidate on " ^ lane)
      else
        try
          Masc_tui_http.set_runtime_lane_slots ~host ~port ~lane
            ~runtime_ids:(existing @ [ runtime_id ])
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Runtime_lane_slots_written result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Runtime_lane_slots_written (Error "Eio switch is unavailable"))
;;

let launch_runtime_catalog_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_runtime_resolved ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Runtime_catalog_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Runtime_catalog_loaded (Error "Eio switch is unavailable"))

let launch_runtime_assignment_set state ~mailbox ~keeper_name ~runtime_id =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        match
          Masc_tui_http.fetch_keeper_config_snapshot ~host ~port ~keeper_name
        with
        | Error detail -> Error detail
        | Ok json ->
          (match
             Masc_tui_keeper_config.expected_runtime_assignment_revision json
           with
           | Ok expected_assignment_revision ->
             Masc_tui_http.post_runtime_assignment ~host ~port ~keeper_name
               ~runtime_id ~expected_assignment_revision
           | Error detail -> Error detail)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox
      (Runtime_assignment_set (keeper_name, runtime_id, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Runtime_assignment_set
           (keeper_name, runtime_id, Error "Eio switch is unavailable"))

let inflight_for state keeper_name =
  Option.map
    (fun entry -> entry.sent_request)
    (List.find_opt
       (fun entry -> String.equal entry.sent_request.keeper_name keeper_name)
       state.msg_inflight)
;;

let drop_inflight state request =
  state.msg_inflight <-
    List.filter
      (fun entry ->
        not (Keeper_chat.same_request_identity entry.sent_request request))
      state.msg_inflight
;;

(* POST the request. There is no durable claim to take first: the server keys
   every chat operation by this request's id and refuses a second submission of
   it ([Keeper_chat_operation_store.submit] answers [Existing] for a repeat and
   [Idempotency_conflict] for the same id with different content), so a resend
   cannot produce a second turn. The client used to hold its own five-phase
   fence to prevent exactly that, and the price was one un-acknowledged POST
   per workspace — talking to one keeper stopped every other. *)
(* Staged images belong to the message being composed, so the send that consumes
   the draft consumes them too. Returning and clearing in one step keeps a failed
   send from silently re-attaching the same image to the next one. *)
let take_pending_attachments state =
  let staged = state.msg_attachments in
  clear_staged_attachments state;
  staged
;;

let launch_keeper_request ?promoted state ~mailbox request =
  let submitted_at, origin =
    match promoted with
    | None -> Unix.gettimeofday (), Direct_submission
    | Some (item : Chat_queue.item) ->
        ( item.submitted_at
        , Promoted_queue
            { submission_seq = item.submission_seq
            ; intent = item.intent
            ; causal_parent_request_id = item.causal_parent_request_id
            } )
  in
  let live =
    Keeper_chat_transcript.create
      ~keeper_name:request.Keeper_chat.keeper_name
      ~request_id:request.request_id
      ~started_at:(Unix.gettimeofday ())
  in
  state.msg_inflight <-
    { sent_request = request
    ; submitted_at
    ; sent_at = Unix.gettimeofday ()
    ; origin
    ; phase = Turn_streaming
    ; live
    }
    :: state.msg_inflight;
  if
    Option.exists
      (String.equal request.Keeper_chat.keeper_name)
      state.msg_target_keeper_name
  then state.msg_live <- Some live;
  let run () =
    if enqueue_dispatch_start mailbox request false
    then begin
      let result =
        try post_keeper_chat_watching ~mailbox ~port:state.port request with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Keeper_chat.Transport_error (Printexc.to_string exn))
      in
      enqueue_dispatch_ack mailbox (fun acknowledge ->
        Keeper_chat_done (request, false, result, acknowledge))
    end
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_chat_dispatch_blocked
           (request, "Eio switch is unavailable"))

(* The joined line keeps the request identity the history row already carries,
   so the row is rewritten rather than duplicated. [append_user_history_once]
   matches on identity AND text, so a changed text would otherwise append a
   second row for the same queue item. *)
let update_queued_history_text state (request : Keeper_chat.request) =
  let text =
    Keeper_chat.terminal_safe_text ~preserve_newlines:true request.message
  in
  state.msg_history <-
    List.map
      (fun entry ->
        if
          (match entry.me_role with Message_user _ -> true | _ -> false)
          && String.equal entry.me_request_id request.Keeper_chat.request_id
          && String.equal entry.me_keeper_name request.keeper_name
        then { entry with me_text = text }
        else entry)
      state.msg_history

let queue_keeper_message state request =
  let submitted_at = Unix.gettimeofday () in
  let joined =
    if not state.coalesce_queued_input
    then None
    else (
      match
        Chat_queue.join_target state.msg_queued
          ~keeper_name:request.Keeper_chat.keeper_name
      with
      | None -> None
      | Some item ->
        let waiting_request = item.Chat_queue.request in
        let merged =
          { waiting_request with
            Keeper_chat.message =
              waiting_request.Keeper_chat.message
              ^ "\n"
              ^ request.Keeper_chat.message
          ; Keeper_chat.attachments =
              waiting_request.Keeper_chat.attachments
              @ request.Keeper_chat.attachments
          }
        in
        (match
           Chat_queue.replace_request state.msg_queued
             ~request_id:merged.Keeper_chat.request_id merged
         with
         | Error _ -> None
         | Ok queue -> Some (queue, merged)))
  in
  match joined with
  | Some (queue, merged) ->
      state.msg_queued <- queue;
      update_queued_history_text state merged;
      Ok
        (Chat_queue.length_for_keeper queue
           ~keeper_name:merged.Keeper_chat.keeper_name)
  | None ->
      (match Chat_queue.push state.msg_queued ~submitted_at request with
       | Error _ as error -> error
       | Ok (queue, waiting) ->
           state.msg_queued <- queue;
           (* Keep one request-owned session row for recall and the later
              active turn, but causal projection withholds it from the
              transcript while the queue owns it. NEXT renders the queue item
              itself. *)
           append_user_history_once ~submitted_at state request;
           Ok waiting)
;;

let queue_keeper_steer state ~causal_parent_request_id request =
  let submitted_at = Unix.gettimeofday () in
  match
    Chat_queue.push_steer state.msg_queued ~submitted_at
      ~causal_parent_request_id request
  with
  | Error _ as error -> error
  | Ok (queue, waiting) ->
      state.msg_queued <- queue;
      append_user_history_once ~submitted_at state request;
      Ok waiting
;;

let start_keeper_steer ?keeper_name state ~base_path ~mailbox text =
  let target =
    match keeper_name with
    | Some _ as named -> named
    | None -> state.msg_target_keeper_name
  in
  match target with
  | None -> add_event state "error" "/steer needs a Keeper selected"
  | Some keeper_name when not (keeper_available_for_new_message state keeper_name) ->
      add_event state "error"
        (Printf.sprintf "Cannot steer: Keeper %s is unavailable"
           (Keeper_chat.terminal_safe_text keeper_name))
  | Some keeper_name -> (
      match inflight_for state keeper_name, live_for_keeper state keeper_name with
      | None, _ | _, None ->
          add_event state "error"
            "/steer needs a turn currently streaming for this Keeper"
      | Some active_request, Some live ->
          let text =
            place_spilled_paste state ~base_path ~keeper_name text
          in
          let request =
            Keeper_chat.create_request ~attachments:state.msg_attachments
              ~keeper_name ~message:text ()
          in
          (match
             queue_keeper_steer state
               ~causal_parent_request_id:active_request.Keeper_chat.request_id
               request
           with
           | Error detail -> add_event state "error" detail
           | Ok waiting ->
               clear_staged_attachments state;
               clear_current_message_draft state;
               add_event state "message"
                 (Printf.sprintf
                    "Steer queued for %s after interrupting %s (%d waiting)"
                    (Keeper_chat.terminal_safe_text keeper_name)
                    active_request.Keeper_chat.request_id waiting);
               if
                 Keeper_chat_transcript.interrupt live
                 = Keeper_chat_transcript.Not_requested
               then launch_keeper_interrupt state ~mailbox active_request))
;;
(* Send one line to one keeper.

   The refusals here are about whether the message can be delivered at all: no
   keeper selected, a roster this build could not read, a keeper that is no
   longer registered. What used to sit above them — a prepared fence, an
   unverified outcome, a blocked recovery, each with its own Ctrl-R — is gone
   with the fence that produced them. *)
let start_keeper_message ?keeper_name state ~base_path ~mailbox text =
  match
    match keeper_name with
    | Some _ -> keeper_name
    | None -> state.msg_target_keeper_name
  with
  | None -> add_event state "error" "Cannot send: no Keeper is selected"
  | Some _ when Option.is_some state.keepers_error ->
      add_event state "error"
        "Cannot send while the Keeper roster is unavailable"
  | Some target when not (keeper_available_for_new_message state target) ->
      add_event state "error"
        (Printf.sprintf "Cannot send: Keeper %s is no longer registered"
           (Keeper_chat.terminal_safe_text target))
  | Some target -> (
      (* Now that the keeper is known, a spilled paste can be written where
         that keeper can read it. Above this point there is no answer to
         "whose workspace", and a file in the wrong one is a message pointing
         at nothing. *)
      let text = place_spilled_paste state ~base_path ~keeper_name:target text in
      match state.msg_recall_replaces with
      | Some editing
        when String.equal editing.Chat_queue.request.Keeper_chat.keeper_name
               target ->
          let original = editing.Chat_queue.request in
          let request =
            { original with
              message = text
            ; attachments = take_pending_attachments state
            }
          in
          (match
             Chat_queue.replace_request state.msg_queued
               ~request_id:original.Keeper_chat.request_id request
           with
           | Error detail -> add_event state "error" detail
           | Ok queue ->
               state.msg_queued <- queue;
               state.msg_recall_replaces <- None;
               let safe_text =
                 Keeper_chat.terminal_safe_text ~preserve_newlines:true text
               in
               state.msg_history <-
                 List.map
                   (fun entry ->
                     if
                       String.equal entry.me_request_id request.request_id
                       && String.equal entry.me_keeper_name request.keeper_name
                       &&
                       match entry.me_role with
                       | Message_user (Sent_by_operator _) -> true
                       | Message_user (Sent_by_other _) | Message_keeper
                       | Message_autonomous | Message_status | Message_local
                       | Message_error | Message_tool | Message_skill _
                       | Message_thinking | Message_memory -> false
                     then { entry with me_text = safe_text }
                     else entry)
                   state.msg_history;
               clear_current_message_draft state;
               add_event state "message"
                 (Printf.sprintf "Updated queued %s for %s"
                    (match editing.Chat_queue.intent with
                     | Chat_queue.Next -> "NEXT"
                     | Chat_queue.Steer_after_interrupt -> "STEER")
                    (Keeper_chat.terminal_safe_text target));
               if Option.is_none (inflight_for state target)
               then
                 match
                   Chat_queue.take state.msg_queued
                     ~request_id:request.Keeper_chat.request_id
                 with
                 | None -> ()
                 | Some (item, rest) ->
                     state.msg_queued <- rest;
                     launch_keeper_request ~promoted:item state ~mailbox
                       item.request)
      | Some _ ->
          add_event state "error"
            "Queued edit belongs to another Keeper; switch back or press Ctrl-U"
      | None ->
        (* Read through [send_disposition] rather than the state directly: the
           footer answers the same question the same way, and the two drifting
           apart is what put "Enter:blocked" on a screen that also said
           "queued 1". *)
        (match send_disposition state ~keeper_name:target with
      | Sends ->
          let request =
            Keeper_chat.create_request
              ~attachments:(take_pending_attachments state)
              ~keeper_name:target
              ~message:text
              ()
          in
          launch_keeper_request state ~mailbox request
      | Queues_behind blocking -> (
          (* A turn to this keeper is already running. Hold the line rather than
             refusing it: the operator pressed Enter meaning "send this next",
             and the turn settling is what "next" is.

             The request is built here, the same way the sending branch builds
             it, so what waits is what will be sent -- identity and staged
             attachments included. Building it at dispatch instead is what sent
             an image with whichever line happened to go next. *)
          let request =
            Keeper_chat.create_request
              ~attachments:(take_pending_attachments state)
              ~keeper_name:target
              ~message:text
              ()
          in
          match queue_keeper_message state request with
          | Error detail -> add_event state "error" detail
          | Ok waiting ->
              clear_current_message_draft state;
              add_event state "message"
                (Printf.sprintf "Queued for %s behind %s (%d waiting)"
                   (Keeper_chat.terminal_safe_text target)
                   blocking.Keeper_chat.request_id waiting))))
;;

(* The operator is mid-line for this keeper: the composer holds text and it is
   aimed here. While that is true, a settle should not dispatch the keeper's
   waiting line out from under the line being typed -- holding it lets the next
   Enter fold the two together ([coalesce_queued_input]). Gated on that setting:
   with coalescing off the operator wants every line its own turn, so the settle
   dispatches promptly as before. *)
let composing_for_keeper state keeper_name =
  state.coalesce_queued_input
  && Buffer.length state.msg_input > 0
  && (match state.msg_target_keeper_name with
      | Some target -> String.equal target keeper_name
      | None -> false)

let drain_queued_message state ~base_path ~mailbox =
  (* Send everything that can go now, oldest first, skipping lines whose own
     keeper still has a turn running. Sending sets that keeper's in-flight, so
     the next pass will not pick it again and the walk terminates.

     Taking strictly from the front would stall the queue behind a busy
     keeper — and permanently, because the lines behind it are addressed to
     keepers that are idle and so have no settle coming to drain them.

     Recursion stays inside so the exported name has no self-call: a wiring
     test that counts calls to it would otherwise be satisfied by this
     function calling itself, and pass with nothing else calling it at all. *)
  let rec next () =
    match
      Chat_queue.take_first_sendable state.msg_queued ~sendable:(fun keeper_name ->
        Option.is_none (inflight_for state keeper_name)
        && not (composing_for_keeper state keeper_name)
        &&
        match state.msg_recall_replaces with
        | Some editing ->
            not
              (String.equal editing.Chat_queue.request.Keeper_chat.keeper_name
                 keeper_name)
        | None -> true)
    with
    | None -> ()
    | Some (item, rest) ->
        let request = item.Chat_queue.request in
        let keeper_name = request.Keeper_chat.keeper_name in
        if keeper_available_for_new_message state keeper_name
        then (
          state.msg_queued <- rest;
          (* The request that waited is the request that goes. It was built
             when the operator pressed Enter, so dispatch neither re-reads the
             staged attachments nor mints a second identity for a line the
             conversation already shows. *)
          launch_keeper_request ~promoted:item state ~mailbox request;
          next ())
        else (
          (* The keeper this was written to is no longer registered. Sending it
             would fail; holding it would leave a count reporting work that
             never moves. Say what is being let go, and let it go. *)
          let dropped =
            Chat_queue.waiting state.msg_queued
            |> List.filter (fun item ->
                   String.equal item.Chat_queue.request.Keeper_chat.keeper_name
                     keeper_name)
          in
          let before = Chat_queue.length state.msg_queued in
          state.msg_queued <-
            Chat_queue.drop_for_keeper state.msg_queued ~keeper_name;
          (* Their rows go with them: a line left in the conversation for a
             keeper that will never receive it reads as sent. *)
          List.iter
            (fun item -> forget_queued_history state item.Chat_queue.request)
            dropped;
          add_event state "error"
            (Printf.sprintf
               "Keeper %s is no longer registered; %d queued message(s) for it \
                were not sent"
               (Keeper_chat.terminal_safe_text keeper_name)
               (before - Chat_queue.length state.msg_queued));
          next ())
  in
  next ()
;;

let chat_status_text completed =
  let turn_ref = completed.Keeper_chat.turn_ref in
  match completed.turn_outcome with
  | Keeper_chat.Visible_reply when String.trim completed.reply <> "" ->
      completed.reply
  | Keeper_chat.Visible_reply ->
      Printf.sprintf "Turn completed with non-text visible content (turn %s)"
        turn_ref
  | Keeper_chat.Continuation_checkpoint ->
      Printf.sprintf "Continuation checkpoint recorded (turn %s)" turn_ref
  | Keeper_chat.Terminal_effect_settled ->
      Printf.sprintf "Reply delivered by a terminal tool (turn %s)" turn_ref
  | Keeper_chat.Awaiting_gate_approval ->
      Printf.sprintf "Waiting for Gate approval (turn %s)" turn_ref
  | Keeper_chat.No_visible_reply ->
      Printf.sprintf "Turn completed without a visible reply (turn %s)" turn_ref

(* /task in the composer or the chat pane: create the task first, then hand
   the keeper the operator's words with the task id in front. Creation runs
   on a daemon fiber; only the mailbox result mutates state. The MCP session
   is the one the observer feed keeps; without one, this call opens one and
   the observer reuses it. *)
let launch_task_dispatch state ~mailbox ~keeper_name ~title ~body ~original =
  let host = server_peer_host in
  let port = state.port in
  let session = state.mcp_session in
  (* A JSON-RPC id for this one call: the answer must name it back. Wall
     clock is identity enough for correlation on a single request. *)
  let request_id = Printf.sprintf "tui-task-%.6f" (Unix.gettimeofday ()) in
  let run () =
    let result =
      try
        let session_result =
          match session with
          | Some session_id -> Ok session_id
          | None ->
              Masc_tui_http.open_mcp_session ~host ~port
                ~client_version:Runtime_build_version.current
        in
        match session_result with
        | Error detail -> Error detail
        | Ok session_id -> (
            let arguments =
              ("title", `String title)
              ::
              (if String.trim body = "" then []
               else [ ("description", `String body) ])
            in
            match
              Masc_tui_http.call_mcp_tool ~host ~port ~session_id ~request_id
                ~tool:"masc_add_task" ~arguments
            with
            | Error detail -> Error detail
            | Ok outcome ->
                if outcome.Masc_tui_mcp.is_error then
                  Error outcome.Masc_tui_mcp.text
                else Masc_tui_mcp.task_id_of_add_task outcome.Masc_tui_mcp.text)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox
      (match result with
       | Ok task_id ->
           Task_dispatched { keeper = keeper_name; task_id; title; body }
       | Error detail ->
           Task_dispatch_failed { keeper = keeper_name; detail; original })
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Task_dispatch_failed
           { keeper = keeper_name
           ; detail = "Eio switch is unavailable"
           ; original
           })

(* One reading of what the operator typed, wherever they typed it: the
   composer row or the chat pane's input. Text goes to the keeper as it
   always did; a slash word is the TUI's to act on, and a mistyped one is
   reported rather than sent to the keeper as an instruction. *)
(* A command's answer, drawn into the pane the operator typed it in. Recent
   Events lives on another surface, and a /help answered there is a /help
   that looks ignored. Falls back to the event log when the pane has no
   keeper to file the row under. *)
let chat_notice state ~keeper_name ~role text =
  match keeper_name with
  | Some keeper ->
      state.msg_history <-
        state.msg_history
        @ [ {
              me_role = role;
              me_identity =
                Session_row
                  { request_id = ""
                  ; turn_phase = chat_turn_phase_of_role role
                  ; operation_seq = next_chat_operation_seq state ""
                  };
              me_turn_phase = chat_turn_phase_of_role role;
              me_turn_sequence = None;
              me_operation_seq = next_chat_operation_seq state "";
              me_text = Keeper_chat.terminal_safe_text ~preserve_newlines:true text;
              me_memory_summary = None;
              me_gate = None;
              me_submitted_at = None;
              me_tool_block = None;
              me_skill_activity = None;
              me_timestamp = current_clock_text ();
              me_keeper_name = keeper;
              me_request_id = "";
              me_at = Unix.gettimeofday ();
            } ]
  | None ->
      add_event state
        (match role with Message_error -> "error" | _ -> "system")
        text

(* Ctrl-V. A terminal never delivers a pasted image: bracketed paste carries
   text, and a clipboard holding a screenshot has no text form to send. So the
   bytes are fetched from the clipboard itself and staged the way a dropped
   file is -- same size limit, same media-type sniff, same staging list.

   The answer goes to the chat pane rather than the event log because that is
   the surface the operator is looking at when they press this key; with no
   keeper selected [chat_notice] falls back to the log on its own.

   The draft gets a marker where the image went. Without one, a staged image
   and a keystroke the terminal ate look identical from the composer, and the
   operator would learn which it was only after the turn came back. *)
let paste_clipboard_image state =
  let notice = chat_notice state ~keeper_name:state.msg_target_keeper_name in
  match Masc_tui_clipboard.read_image () with
  | Error error ->
    notice ~role:Message_error
      ("Ctrl-V: " ^ Masc_tui_clipboard.error_to_string error)
  | Ok bytes ->
    (* Numbered by staging order and restarting at 1 with each message, so the
       marker in the draft and the attachment beside it carry the same number:
       the keeper reads "[Image #2]" and has an image-2.png to look at. *)
    let index = List.length state.msg_attachments + 1 in
    let name = Printf.sprintf "image-%d.png" index in
    (match Masc_tui_attachment.of_bytes ~name bytes with
     | Error error ->
       notice ~role:Message_error
         ("Ctrl-V: " ^ Masc_tui_attachment.error_to_string error)
     | Ok attachment ->
       forget_recall state;
       state.msg_attachments <- state.msg_attachments @ [ attachment ];
       note_attachment_staged state;
       (* A marker run into the word before it changes that word. Only a draft
          that does not already end in whitespace needs the separator. *)
       let needs_separator =
         Buffer.length state.msg_input > 0
         && (match Buffer.nth state.msg_input (Buffer.length state.msg_input - 1) with
             | ' ' | '\n' | '\t' -> false
             | _ -> true)
       in
       if needs_separator then Buffer.add_char state.msg_input ' ';
       Buffer.add_string state.msg_input (Printf.sprintf "[Image #%d] " index);
       notice ~role:Message_local
         (Printf.sprintf
            "pasted [Image #%d] (%s, %d bytes) \xe2\x80\x94 %d staged for the next message"
            index
            attachment.Masc_tui_keeper_chat_projection.mime_type
            attachment.Masc_tui_keeper_chat_projection.size
            (List.length state.msg_attachments)))
;;

(* Whether this terminal draws pictures. Asked once, before the first frame,
   and remembered: the answer cannot change while the process runs, and asking
   again would put another reply on the key stream. [None] until asked. *)
let terminal_draws_images = ref None

(* Said the same at both doors a picture comes through: the capability was
   asked once and the answer cannot change, so neither does the sentence that
   reports it. *)
let terminal_draws_no_images =
  "this terminal does not draw images (it did not answer the graphics query)"

(* Read a whole file. Images are the only thing this reads off disk, and a
   picture is not a thing to stream: it goes to the terminal in one write or
   not at all. *)
let read_file_bytes path =
  match open_in_bin path with
  | exception Sys_error detail -> Error detail
  | channel ->
      Fun.protect
        ~finally:(fun () -> close_in_noerr channel)
        (fun () ->
          match really_input_string channel (in_channel_length channel) with
          | contents -> Ok contents
          | exception End_of_file ->
              Error "the file ended sooner than its length said")

(* Everything written for a picture goes through here, wrapped for tmux when
   this process is inside one. tmux eats an escape it does not recognise, so
   these reach the terminal underneath only when they are wrapped -- and only
   when tmux was configured to pass them through, which is the operator's
   setting and not something this can check. *)
let write_to_terminal payload =
  let payload =
    match Sys.getenv_opt "TMUX" with
    | Some _ -> Masc_tui_graphics.tmux_wrapped payload
    | None -> payload
  in
  output_string stdout payload;
  flush stdout

(* Where a reference lands, and what it opens when it gets there.

   The surfaces already print [masc://] references beside what they name and
   [Y] already copies the one under the cursor. Reading that same reference
   back is the other half: without it the screen knows where the answer is and
   the operator still walks over by hand.

   Tasks have no surface of their own -- they are listed on Overview -- so a
   task reference lands there with its detail open, which is what "go to this
   task" means on this screen. *)
let follow_target (kind : Link.kind) (id : string) =
  match kind with
  | Link.Task -> Some (Overview, Some id)
  | Link.Goal -> Some (Planning, Some id)
  | Link.Board_post -> Some (Board, Some id)
  | Link.Schedule -> Some (Schedules, Some id)
  | Link.Fusion_run -> Some (Fusion, Some id)
  | Link.Keeper -> Some (Keepers Keeper_list, Some id)
;;

let approval_row_reference = function
  | Keeper_tool_row ask -> Some (Link.reference Keeper ask.kta_keeper)
  | Gate_row pending -> Some (Link.reference Keeper pending.Tui_decode.gp_keeper)
  | Operator_row item ->
      Option.bind item.ap_target_id (fun target_id ->
          match
            Masc.Operator_action_constants.target_type_of_string
              item.ap_target_type
          with
          | Some Masc.Operator_action_constants.Keeper ->
              Some (Link.reference Keeper target_id)
          | Some Goal -> Some (Link.reference Goal target_id)
          | Some Workspace | None -> None)

let selected_surface_reference state =
  let board () =
    match state.board_mode with
    | Board_read post_id -> Some (Link.reference Board_post post_id)
    | Board_list ->
        Option.map
          (fun post -> Link.reference Board_post post.bp_id)
          (List.nth_opt state.board_posts state.board_cursor)
    | Board_compose -> None
  in
  let planning () =
    match state.planning_mode with
    | Planning_detail goal_id -> Some (Link.reference Goal goal_id)
    | Planning_list ->
        Option.bind state.planning (fun snapshot ->
            planning_visible_goals ~filter:state.planning_filter
              ~sort:state.planning_sort snapshot.pl_goals
            |> Fun.flip List.nth_opt state.planning_cursor
            |> Option.map (fun goal -> Link.reference Goal goal.pg_id))
  in
  match state.view with
  | Board -> board ()
  | Planning -> planning ()
  | Schedules ->
      (match state.schedule_detail_id, state.schedules with
       | Some schedule_id, _ -> Some (Link.reference Schedule schedule_id)
       | None, Some snapshot ->
           Option.map
             (fun row -> Link.reference Schedule row.sch_schedule_id)
             (List.nth_opt snapshot.scs_rows state.schedule_cursor)
       | None, None -> None)
  | Harness ->
      (match state.harness_detail with
       | Some (task_id, _) -> Some (Link.reference Task task_id)
       | None ->
           Option.bind state.harness (fun snapshot ->
               Option.map
                 (fun verdict ->
                    Link.reference Task verdict.Tui_decode.hv_task_id)
                 (List.nth_opt snapshot.Tui_decode.hs_verdicts
                    state.harness_cursor)))
  | Fusion ->
      (match state.fusion_mode, state.fusion_runs with
       | Fusion_detail run_id, _ -> Some (Link.reference Fusion_run run_id)
       | Fusion_list, Some snapshot ->
           Option.map
             (fun (run : Tui_decode.fusion_run) ->
                Link.reference Fusion_run run.fur_run_id)
             (List.nth_opt snapshot.fus_runs state.fusion_cursor)
       | Fusion_list, None -> None)
  (* These four hold an id already and were answering None, so Ctrl-] did
     nothing on them: a lane names its keeper, a verification request names the
     task it is waiting on, the roster names the keeper under the cursor, and
     Overview names the task. Following was built and left switched off for
     most of the screens that could use it. *)
  | Overview ->
      (match state.task_detail_id with
       | Some task_id -> Some (Link.reference Task task_id)
       | None ->
           Option.map
             (fun (row : Tui_decode.task) -> Link.reference Task row.id)
             (List.nth_opt state.tasks state.task_cursor))
  | Keepers _ ->
      Option.map
        (fun (keeper : Tui_decode.keeper) -> Link.reference Keeper keeper.k_name)
        (List.nth_opt state.keepers state.keeper_cursor)
  | Lanes -> None
  | Clients -> None
  | Verification ->
      (* The task, not the request: a verification request is a question about
         a task, and the task is the thing another surface can open. *)
      Option.bind state.verification (fun snapshot ->
          Option.map
            (fun (request : Tui_decode.verification_request) ->
               Link.reference Task request.vr_task_id)
            (List.nth_opt snapshot.Tui_decode.vs_requests
               state.verification_cursor))
  | Approvals ->
      (* An ask names what it is asking about. A keeper's tool ask names the
         keeper; an operator ask carries a typed target, so the kind is read
         through [target_type_of_string] rather than matched as text. A
         Workspace target, or one this build does not know, points at no
         surface and gets no reference. *)
      Option.bind
        (List.nth_opt (approval_items state) state.approval_cursor)
        approval_row_reference
  | Acting
  | Memory | Repositories | Changes | Connectors | Runtime | Config | Resources | Tools
  | Code | System_logs -> None

let next_board_sort = function
  | Board_hot -> Board_trending
  | Board_trending -> Board_recent
  | Board_recent -> Board_updated
  | Board_updated -> Board_discussed
  | Board_discussed -> Board_hot

(* A filter or sort change can leave the cursor past the end of the new
   list; clamp it so the next j/k has somewhere to move from. *)
let clamp_planning_cursor state =
  let count =
    match state.planning with
    | None -> 0
    | Some planning ->
        List.length
          (planning_visible_goals ~filter:state.planning_filter
             ~sort:state.planning_sort planning.pl_goals)
  in
  if state.planning_cursor >= count then
    state.planning_cursor <- max 0 (count - 1)

(* Put a picture's bytes on the terminal, or say why not. Both doors a
   picture comes through -- a path the conversation named and an attachment
   staged for the next message -- end here, so what the terminal can show is
   answered once. [refuse] is the caller's wording: each door names its own
   key and its own label for the thing it could not show, and [title] is the
   line above the picture -- a path for a named file, the attachment's name
   for a staged one, which has no path.

   Asked before the write, not after: [place] is told not to answer, so a
   format the terminal cannot decode leaves a cleared screen and no word
   about why -- the picture that never arrives looks exactly like the picture
   that did. The sniff is the composer's, so both surfaces read bytes by one
   rule. *)
let draw_image state ~refuse ~title data =
  match Masc.Keeper_vision_tool.sniff_image_media_type data with
  | Error detail -> refuse detail
  | Ok media when not (String.equal media Masc_tui_graphics.payload_media_type)
    ->
      refuse
        (Printf.sprintf "the terminal draws %s and this is %s"
           Masc_tui_graphics.payload_media_type media)
  | Ok _ ->
      let rows, columns = get_terminal_size () in
      (* Three rows kept back, not the two this comment used to claim: the
         name above the picture, the way out below it, and one more.
         Counting what is drawn, the picture starts at row 2 and the way
         out is written at row [rows], so [rows - 2] would already clear
         it -- the third row is spare.
         Left as it is on purpose. Some terminals scroll when an image
         reaches the last row, and a spare row is the usual guard, but
         nothing here records whether that is why. Naming it after a reason
         that may not be the real one would put a guess in the code, so the
         comment says what is true and stops there. *)
      let box =
        { Masc_tui_graphics.columns = max 1 (columns - 2)
        ; rows = max 1 (rows - 3)
        }
      in
      write_to_terminal
        (Ansi.clear ^ Masc_tui_graphics.delete_all
        ^ Printf.sprintf "\x1b[1;1H%s\x1b[2;1H"
            (Message_layout.fit_width title (max 1 (columns - 1)))
        ^ Masc_tui_graphics.place ~data box
        ^ Printf.sprintf "\x1b[%d;1H%s" rows
            (Message_layout.fit_width "  any key: back" (max 1 (columns - 1))));
      state.image_open <- true

(* Put a picture on the terminal, or say why not. The refusal is text for the
   pane: there is nothing to draw, and taking the screen away from the frame
   to say so would hide the only surface that can say it. *)
let open_image state ~notice path =
  let refuse reason =
    notice ~role:Message_error (Printf.sprintf "/image %s: %s" path reason)
  in
  match !terminal_draws_images with
  | Some false -> refuse terminal_draws_no_images
  | Some true | None -> (
      match read_file_bytes path with
      | Error detail -> refuse detail
      | Ok data when String.length data = 0 -> refuse "the file is empty"
      | Ok data -> draw_image state ~refuse ~title:path data)

(* The staged door. Ctrl-V leaves the image in the attachment as base64 for
   the wire to the endpoint; the terminal wants the PNG's own bytes, so they
   are decoded back and drawn by the same tail a named file gets. The
   attachment's name titles the screen: a staged image has no path, and the
   name is the label the draft marker already knows it by. *)
let open_staged_image state ~notice attachment =
  let title = attachment.Masc_tui_keeper_chat_projection.name in
  let refuse reason =
    notice ~role:Message_error (Printf.sprintf "Ctrl-O %s: %s" title reason)
  in
  match !terminal_draws_images with
  | Some false -> refuse terminal_draws_no_images
  | Some true | None -> (
      match Base64.decode attachment.Masc_tui_keeper_chat_projection.data with
      | Error (`Msg detail) -> refuse detail
      | Ok data -> draw_image state ~refuse ~title data)

(* The picture this conversation last named, if it named one. Newest first
   because that is why the key is pressed: something just arrived. Older ones
   stay reachable by their path through /image -- cycling would make this key
   a cursor, and a cursor needs state that has to be told when the
   conversation changed underneath it.

   The row's position comes back with the path: when the composer is also
   holding a staged image, Ctrl-O weighs the two by which arrived later, and
   the position is what the weighing compares against the staging marker.

   Read at the keystroke rather than kept beside the history: the scan costs
   one pass over what is loaded, once, and a kept list would have to be
   rewritten at every place a line is appended or a page is paged in. *)
let newest_named_image state =
  let in_this_chat entry =
    match state.msg_target_keeper_name with
    | None -> true
    | Some name -> String.equal entry.me_keeper_name name
  in
  let length = List.length state.msg_history in
  List.rev state.msg_history
  |> List.find_mapi (fun from_newest entry ->
         if not (in_this_chat entry) then None
         else
           match List.rev (Masc_tui_image_ref.paths entry.me_text) with
           | [] -> None
           (* Last named in the newest line: one message can carry several,
              and the reader means the one nearest what they just read. *)
           | last :: _ -> Some (length - 1 - from_newest, last))

(* Both a named path and a staged attachment: which is newer. The marker left
   by [note_attachment_staged] anchors the row that was newest when the newest
   attachment entered the composer, so the naming row sitting at or behind it
   means the paste came after the name. A marker that no longer matches any
   row -- its row was since replaced by the transcript -- orders nothing, and
   the named path keeps the key, which is the answer it gave before the marker
   existed. *)
let named_vs_staged_order state ~named_index =
  match state.msg_attachments_since with
  | None -> Masc_tui_image_preview.Named_is_newer
  | Some since -> (
    match msg_index_of_anchor state.msg_history since with
    | None -> Masc_tui_image_preview.Unordered
    | Some staged_since_index ->
      if named_index <= staged_since_index
      then Masc_tui_image_preview.Staged_is_newer
      else Masc_tui_image_preview.Named_is_newer)

(* Ctrl-O. What it opens is chosen by [Masc_tui_image_preview.choose_preview]:
   the newer of the path the conversation last named and the newest staged
   attachment. A screenshot staged a keystroke ago never enters the
   transcript, so when the staging is the newer act it is what the key was
   pressed to see; when the naming message is newer, what the operator just
   read wins. The refusal when there is neither is text for the pane rather
   than a cleared screen: a key that did nothing and a key that found nothing
   look the same otherwise, which is the shape of failure this whole surface
   keeps having. *)
let open_named_image state =
  let notice = chat_notice state ~keeper_name:state.msg_target_keeper_name in
  let named, order =
    match newest_named_image state with
    | Some (named_index, path) ->
        Some path, named_vs_staged_order state ~named_index
    | None -> None, Masc_tui_image_preview.Unordered
  in
  match
    Masc_tui_image_preview.choose_preview ~named ~staged:state.msg_attachments
      ~order
  with
  | Masc_tui_image_preview.Named_path path -> open_image state ~notice path
  | Masc_tui_image_preview.Staged attachment ->
      open_staged_image state ~notice attachment
  | Masc_tui_image_preview.No_image ->
      notice ~role:Message_local
        (Printf.sprintf
           "Ctrl-O: this conversation names no %s to look at, and no image is staged for the next message"
           Masc_tui_image_ref.extension)

(* Take the picture away and give the frame back. The terminal holds images in
   its own layer, so clearing the screen is not enough to remove one. *)
let close_image state =
  match state.image_open with
  | false -> ()
  | true ->
      state.image_open <- false;
      write_to_terminal Masc_tui_graphics.delete_all

(* [/find] and its arg-less repeat, which differ only in where the walk starts.

   The pane is moved by [set_msg_scroll], the one seam that also pins the row
   the scroll counts back from -- a search that wrote [msg_scroll] directly
   would leave the pin unset and the position would drift under the next
   message that arrived.

   Every outcome says something. A search that silently did nothing and a key
   that did nothing look the same, which is the failure this surface keeps
   having; and running out of older matches is a different fact from having
   none at all, because only one of the two is fixed by starting over. *)
let seek_in_chat state ~target ~restart =
  let notice = chat_notice state ~keeper_name:target in
  match target with
  | None ->
      notice ~role:Message_error "/find needs a Keeper selected on the roster"
  | Some keeper_name -> (
      let older_than = if restart then None else state.msg_find_at in
      (* Normalised here, at the door the operator's text comes through.
         [msg_find] keeps what they typed, because that is what the pane
         echoes back to them. *)
      match
        Masc_tui_render.keeper_message_find_scroll state ~keeper_name
          ~needle:(String.lowercase_ascii (String.trim state.msg_find))
          ~older_than
      with
      | Some (scroll, anchor) ->
          state.msg_find_at <- Some anchor;
          set_msg_scroll state scroll;
          notice ~role:Message_local
            (Printf.sprintf "/find %s \xe2\x80\x94 %d row(s) back (/find repeats)"
               state.msg_find scroll)
      | None ->
          if restart then
            notice ~role:Message_local
              (Printf.sprintf "/find %s \xe2\x80\x94 nothing in this conversation"
                 state.msg_find)
          else
            (* The walk is over, not empty. Said apart from the case above
               because starting again is what fixes this one and not that
               one. *)
            notice ~role:Message_local
              (Printf.sprintf
                 "/find %s \xe2\x80\x94 no older match; /find %s starts again"
                 state.msg_find state.msg_find))

let send_operator_text ?keeper_name state ~base_path ~mailbox text =
  let target =
    match keeper_name with
    | Some _ as named -> named
    | None -> state.msg_target_keeper_name
  in
  let notice = chat_notice state ~keeper_name:target in
  let command = Masc_tui_command.parse text in
  if
    Option.is_some state.msg_recall_replaces
    && match command with Masc_tui_command.Say _ -> false | _ -> true
  then
    notice ~role:Message_error
      "A queued edit is active; press Enter for its text or Ctrl-U to abandon it"
  else
  match command with
  | Masc_tui_command.Say _ ->
      start_keeper_message ?keeper_name state ~base_path ~mailbox text
  | Masc_tui_command.Task_missing_title ->
      add_event state "error" "/task needs a title on the same line"
  | Masc_tui_command.View_image_missing_path ->
      notice ~role:Message_error "/image needs a path on the same line"
  | Masc_tui_command.View_image path ->
      Buffer.clear state.msg_input;
      open_image state ~notice (String.trim path)
  | Masc_tui_command.Attach_image_missing_path ->
      notice ~role:Message_error "/attach needs a path on the same line"
  | Masc_tui_command.Attach_image path -> (
      Buffer.clear state.msg_input;
      match Masc_tui_attachment.of_file ~path:(String.trim path) with
      | Error error ->
          notice ~role:Message_error
            (Masc_tui_attachment.error_to_string error)
      | Ok attachment ->
          state.msg_attachments <- state.msg_attachments @ [ attachment ];
          note_attachment_staged state;
          notice ~role:Message_local
            (Printf.sprintf
               "attached %s (%s, %d bytes) — %d staged for the next message"
               attachment.Masc_tui_keeper_chat_projection.name
               attachment.Masc_tui_keeper_chat_projection.mime_type
               attachment.Masc_tui_keeper_chat_projection.size
               (List.length state.msg_attachments)))
  | Masc_tui_command.Help ->
      Buffer.clear state.msg_input;
      notice ~role:Message_local
        (String.concat "\n" Masc_tui_command.help_lines)
  | Masc_tui_command.Open_settings ->
      Buffer.clear state.msg_input;
      state.config_pane <- Config_params;
      state.config_scroll <- 0;
      state.runtime_params_cursor <- 0;
      state.runtime_param_edit <- None;
      state.runtime_params_notice <- None;
      goto_surface state ~mailbox Config
  | Masc_tui_command.Switch_keeper_missing_name ->
      notice ~role:Message_error "/keeper needs a name on the same line"
  | Masc_tui_command.Switch_keeper name -> (
      let names =
        List.map (fun (keeper : keeper) -> keeper.k_name) state.keepers
      in
      match Masc_tui_command.resolve_keeper_name ~names name with
      | Masc_tui_command.Keeper_found keeper_name ->
          Buffer.clear state.msg_input;
          open_message_for_keeper ~return_to:state.msg_return state keeper_name;
          launch_keeper_history_load state ~mailbox ~keeper_name;
          state.view <- Keepers Keeper_message
      | Masc_tui_command.Keeper_ambiguous candidates ->
          notice ~role:Message_error
            (Printf.sprintf "%S names more than one keeper: %s" name
               (String.concat ", " candidates))
      | Masc_tui_command.Keeper_unknown ->
          notice ~role:Message_error
            (Printf.sprintf "no keeper named %S on the roster" name))
  | Masc_tui_command.Interrupt_turn -> (
      Buffer.clear state.msg_input;
      match state.msg_live with
      | Some live
        when Keeper_chat_transcript.interrupt live
             = Keeper_chat_transcript.Not_requested -> (
          match
            inflight_by_request_id state
              (Keeper_chat_transcript.request_id live)
          with
          | Some request -> launch_keeper_interrupt state ~mailbox request
          | None -> notice ~role:Message_local "no turn of this pane's to interrupt")
      | Some _ ->
          notice ~role:Message_local
            "an interrupt is already outstanding for this turn"
      | None -> notice ~role:Message_local "no turn is streaming in this pane")
  | Masc_tui_command.Steer_missing_message ->
      notice ~role:Message_error "/steer needs replacement text on the same line"
  | Masc_tui_command.Steer_turn message ->
      start_keeper_steer ?keeper_name state ~base_path ~mailbox message
  | Masc_tui_command.Set_thinking mode ->
      Buffer.clear state.msg_input;
      state.msg_reasoning_visibility <-
        (match mode with
         | `Hidden -> Reasoning_hidden
         | `Folded -> Reasoning_folded
         | `Full -> Reasoning_full
         | `Cycle -> next_reasoning_visibility state.msg_reasoning_visibility);
      notice ~role:Message_local
        ("reasoning "
         ^ reasoning_visibility_to_string state.msg_reasoning_visibility)
  | Masc_tui_command.Set_tools mode ->
      Buffer.clear state.msg_input;
      state.msg_tool_visibility <-
        (match mode with
         | `Compact -> Tools_compact
         | `Full -> Tools_full
         | `Toggle -> toggle_tool_visibility state.msg_tool_visibility);
      (match state.msg_tool_visibility, target with
       | Tools_full, Some keeper_name ->
           launch_keeper_chat_tool_details_load ~force:true state ~mailbox
             ~keeper_name
       | Tools_compact, _ | Tools_full, None -> ());
      notice ~role:Message_local
        ("tool calls " ^ tool_visibility_to_string state.msg_tool_visibility)
  | Masc_tui_command.Cycle_memory ->
      Buffer.clear state.msg_input;
      state.msg_memory_visibility <-
        next_memory_visibility state.msg_memory_visibility;
      notice ~role:Message_local
        ("Librarian/Memory timeline: "
         ^ memory_visibility_to_string state.msg_memory_visibility
         ^ " (Ctrl-N or /memory to cycle)")
  | Masc_tui_command.Find_in_chat query ->
      (* A new query starts at the newest message; [Find_next] below carries on
         from wherever this landed. *)
      Buffer.clear state.msg_input;
      state.msg_find <- String.trim query;
      state.msg_find_at <- None;
      seek_in_chat state ~target ~restart:true
  | Masc_tui_command.Find_next ->
      Buffer.clear state.msg_input;
      if String.equal state.msg_find "" then
        notice ~role:Message_error
          "/find needs text the first time; /find on its own repeats it"
      else seek_in_chat state ~target ~restart:false
  | Masc_tui_command.Inspect_context ->
      (match target with
       | Some keeper_name ->
           Buffer.clear state.msg_input;
           open_context_inspector state ~mailbox ~keeper_name
       | None ->
           notice ~role:Message_error
             "/context needs a Keeper selected on the roster")
  | Masc_tui_command.Preset_list ->
      Buffer.clear state.msg_input;
      launch_preset_call state ~mailbox
        ~call:(fun ~host ~port -> Masc_tui_loader.load_presets ~host ~port)
        ~wrap:(fun result -> Presets_listed (Preset_to_chat target, result))
  | Masc_tui_command.Preset_save_missing_name ->
      notice ~role:Message_error "/preset save needs a name on the same line"
  | Masc_tui_command.Preset_save { name; description } ->
      Buffer.clear state.msg_input;
      launch_preset_call state ~mailbox
        ~call:(fun ~host ~port ->
          Masc_tui_loader.save_preset ~host ~port ~name ~description)
        ~wrap:(fun result -> Preset_saved (Preset_to_chat target, result))
  | Masc_tui_command.Preset_restore_missing_name ->
      notice ~role:Message_error "/preset restore needs a name on the same line"
  | Masc_tui_command.Preset_restore name ->
      Buffer.clear state.msg_input;
      notice ~role:Message_local
        (Printf.sprintf "restoring preset %s — the live state is autosaved first" name);
      launch_preset_call state ~mailbox
        ~call:(fun ~host ~port -> Masc_tui_loader.restore_preset ~host ~port ~name)
        ~wrap:(fun result -> Preset_restored (Preset_to_chat target, result))
  | Masc_tui_command.Unknown word ->
      add_event state "error"
        (Printf.sprintf
           "unknown command /%s (text is sent as typed; /help lists commands)"
           word)
  | Masc_tui_command.Task_for_keeper { title; body } -> (
      let target =
        match keeper_name with
        | Some _ as named -> named
        | None -> state.msg_target_keeper_name
      in
      match target with
      | None -> add_event state "error" "/task needs a keeper to hand the work to"
      | Some keeper ->
          Buffer.clear state.msg_input;
          add_event state "task"
            (Printf.sprintf "creating a task for %s: %s" keeper title);
          launch_task_dispatch state ~mailbox ~keeper_name:keeper ~title ~body
            ~original:text)

let apply_keeper_chat_result state request result =
  match inflight_by_request_id state request.Keeper_chat.request_id with
  | Some current when Keeper_chat.same_request_identity current request ->
      (match result with
       | Error error
         when Keeper_chat.error_certainty ~was_unverified:false error
              = Keeper_chat.Outcome_unverified ->
           let detail =
             Keeper_chat.reconciliation_failure_detail
               ~credential_sent:(Masc_tui_http.operator_token_present ())
               error
             |> Keeper_chat.terminal_safe_text
           in
           append_chat_history state request Message_status
             (Printf.sprintf
                "Outcome still unverified for %s; holding NEXT while the exact operation is reconciled. %s"
                request.request_id detail);
           add_event state "error"
             (Printf.sprintf "Keeper request still unverified: %s"
                request.request_id);
           false
       | (Ok _ | Error _) as result ->
         drop_inflight state request;
         (match result with
       | Ok (Keeper_chat.Turn_completed completed) ->
           let role =
             match completed.turn_outcome with
             | Keeper_chat.Visible_reply
               when String.trim completed.reply <> "" ->
                 Message_keeper
             | Keeper_chat.Visible_reply
             | Keeper_chat.Continuation_checkpoint
             | Keeper_chat.Terminal_effect_settled
             | Keeper_chat.Awaiting_gate_approval
             | Keeper_chat.No_visible_reply -> Message_status
           in
           append_chat_history ~turn_phase:Turn_output state request role
             (chat_status_text completed);
           add_event state "message"
             (Printf.sprintf "Keeper turn finished: %s" request.request_id)
       | Ok (Keeper_chat.Replayed_succeeded _) ->
           (* The server answered [Existing] for this id: the turn already ran
              and this POST produced no second one. *)
           append_chat_history ~turn_phase:Turn_output state request
             Message_status
             "Request was already completed; canonical reply is not present in this replay stream";
           add_event state "message"
             (Printf.sprintf "Keeper request already completed: %s"
                request.request_id)
       | Error error ->
           (* A 401 here is a credential problem, and which one depends on
              whether this process presented a bearer at all. Every other
              failure keeps the server's own words. *)
           let detail =
             Keeper_chat.reconciliation_failure_detail
               ~credential_sent:(Masc_tui_http.operator_token_present ())
               error
             |> Keeper_chat.terminal_safe_text
           in
           let detail =
             match Keeper_chat.error_certainty ~was_unverified:false error with
             | Keeper_chat.Verified_rejected | Keeper_chat.Verified_failed ->
                 detail
             | Keeper_chat.Outcome_unverified -> assert false
           in
           let detail =
             match Keeper_chat_history.present_delivery_failure detail with
             | Some (presented, _) -> presented
             | None -> detail
           in
           append_chat_history ~turn_phase:Turn_output state request
             Message_error detail;
           add_event state "error"
             (Printf.sprintf "Keeper message %s: %s" request.request_id detail));
         true)
  | Some _ | None -> false

let remember_surface_error state ~surface ~current_error ~set_error err =
  let changed =
    match current_error with
    | Some current -> not (String.equal current err)
    | None -> true
  in
  set_error (Some err);
  if changed then
    add_event state "error"
      (Printf.sprintf "%s data unreliable: %s" surface err)

let apply_transport_load state = function
  | Ok transport ->
      state.transport <- Some transport;
      state.transport_error <- None
  | Error err ->
      state.transport <- None;
      remember_surface_error state ~surface:"transport health"
        ~current_error:state.transport_error
        ~set_error:(fun value -> state.transport_error <- value)
        err

let apply_overview_load state = function
  | Ok overview ->
      state.overview <- Some overview;
      state.overview_error <- None
  | Error err ->
      state.overview <- None;
      remember_surface_error state ~surface:"overview"
        ~current_error:state.overview_error
        ~set_error:(fun value -> state.overview_error <- value)
        err

let apply_approvals_load state = function
  | Ok snapshot ->
      (* The cursor indexes the merged list; the operator rows sit after the
         keeper tool rows, so reconciliation by token happens in operator
         coordinates and the keeper prefix length converts both ways. A
         cursor on a keeper row is not touched by an operator refresh. *)
      let keeper_prefix = List.length state.keeper_tool_approvals in
      let operator_cursor = state.approval_cursor - keeper_prefix in
      let approval_cursor =
        if operator_cursor < 0 then state.approval_cursor
        else
          keeper_prefix
          + Approval.reconcile_cursor
              ~current_items:(operator_approval_items state)
              ~cursor:operator_cursor ~next_items:snapshot.aps_items
      in
      state.approval_snapshot <- Some snapshot;
      state.approvals_error <- None;
      state.approval_cursor <- approval_cursor;
      (match state.pending_approval_action with
       | Some pending
         when not
                (List.exists
                   (fun item -> String.equal item.ap_token pending.paa_token)
                   snapshot.aps_items) ->
           state.pending_approval_action <- None
       | Some _ | None -> ())
  | Error err ->
      state.approval_snapshot <- None;
      state.approval_cursor <- 0;
      state.pending_approval_action <- None;
      remember_surface_error state ~surface:"approvals"
        ~current_error:state.approvals_error
        ~set_error:(fun value -> state.approvals_error <- value)
        err

(* A read that fails leaves the last snapshot in place rather than blanking
   the pane: an operator mid-decision should not lose the question they were
   reading because one refresh could not reach the server. *)
(* A new question can arrive while the operator is on another surface. The
   bell reaches every terminal; OSC 9 adds a desktop banner on the terminals
   that read it (iTerm2, WezTerm, kitty) and is ignored elsewhere. Neither
   moves the cursor, so this writes out of band rather than through the frame.
   The banner names the Keeper so it says who is waiting. *)
let notify_new_asks (snapshot : Tui_decode.asks_snapshot) arrived_ids =
  let keeper_of id =
    List.find_opt
      (fun (row : Tui_decode.ask_row) -> String.equal row.Tui_decode.ar_id id)
      snapshot.Tui_decode.asn_rows
    |> Option.map (fun (row : Tui_decode.ask_row) -> row.Tui_decode.ar_keeper)
  in
  let message =
    match List.filter_map keeper_of arrived_ids with
    | [ one ] -> Printf.sprintf "%s is waiting on a decision" one
    | _ ->
        Printf.sprintf "%d keepers are waiting on a decision"
          (List.length arrived_ids)
  in
  write_to_terminal (Printf.sprintf "\x07\x1b]9;%s\x07" message)

let apply_asks_load state = function
  | Ok snapshot ->
      (* The delta against the last snapshot, so a poll that re-reads the same
         asks stays silent and only a question that just arrived rings. *)
      let arrived =
        Ask.newly_opened_ask_ids ~previous:state.asks_snapshot ~current:snapshot
      in
      state.asks_snapshot <- Some snapshot;
      state.asks_error <- None;
      (* Silent while the operator is on the Approvals surface -- the panel is
         already in front of them there. A question that arrives on any other
         surface rings, since nothing else on that surface would show it. *)
      let watching_asks = match state.view with Approvals -> true | _ -> false in
      if
        Ask.should_ring_for_new_ask ~new_ids:arrived
          ~operator_is_watching_asks:watching_asks
      then notify_new_asks snapshot arrived
  | Error err ->
      remember_surface_error state ~surface:"asks" ~current_error:state.asks_error
        ~set_error:(fun value -> state.asks_error <- value)
        err

let apply_approval_observation state observation =
  if Approval.Flow.is_current state.approval_flow observation.ao_generation then
    apply_approvals_load state observation.ao_result

let replace_board_posts state posts =
  let source =
    match state.board_mode with
    | Board_list | Board_compose -> Board_selection.List_cursor
    | Board_read post_id -> Board_selection.Detail_post post_id
  in
  let post_ids posts = List.map (fun post -> post.bp_id) posts in
  let cursor =
    Board_selection.reconcile_cursor
      ~current_ids:(post_ids state.board_posts)
      ~cursor:state.board_cursor ~source ~next_ids:(post_ids posts)
  in
  state.board_posts <- posts;
  state.board_cursor <- cursor

let leave_board_detail state =
  state.board_mode <- Board_list;
  state.board_focus <- Right_pane;
  state.board_scroll <- 0;
  state.board_detail <- Board_detail.clear state.board_detail

let leave_missing_board_detail state =
  match state.board_mode with
  | Board_read post_id
    when not (List.exists (fun post -> String.equal post.bp_id post_id) state.board_posts) ->
      leave_board_detail state
  | Board_list | Board_read _ | Board_compose -> ()

let apply_board_hearths_load state = function
  | Ok census -> state.board_hearths <- census
  | Error _ ->
      (* The census is what [f] walks. A failed read keeps the last one rather
         than emptying it: a cycle that has gone quiet because one request
         failed is worse than a cycle one refresh out of date. *)
      ()

let apply_board_list_load state = function
  | Ok posts ->
      replace_board_posts state posts;
      state.board_list_error <- None;
      leave_missing_board_detail state
  | Error err ->
      remember_surface_error state ~surface:"board list"
        ~current_error:state.board_list_error
        ~set_error:(fun value -> state.board_list_error <- value)
        err

(* One request per refresh returns this many lines. The server caps the
   parameter at 3000; a screenful of scrollback is what the surface can show
   without holding the whole ring in memory. *)
let system_log_page = 300

let apply_system_logs_load state = function
  | Ok snapshot ->
      state.system_logs <- Some snapshot;
      state.system_logs_error <- None;
      let visible = Masc_tui_types.visible_system_log_entries state in
      state.system_logs_cursor <-
        max 0 (min state.system_logs_cursor (List.length visible - 1))
  | Error detail ->
      (* The previous page stays on screen; the error line says the count above
         it is stale rather than letting it read as a fresh zero. *)
      state.system_logs_error <- Some detail

(* Refetch the Logs page outside the surface tick — the level floor changes
   what the server sends, so the page cannot be re-trimmed locally. Same
   fiber-and-mailbox shape as the other one-surface loads. *)
let launch_system_logs_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let level =
    Option.map Masc.Tui_decode.system_log_level_query
      state.system_logs_min_level
  in
  let run_load () =
    enqueue_async mailbox
      (System_logs_loaded
         (load_system_logs ~host ~port ?level ~limit:system_log_page ()))
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_load
  | None -> run_load ()

let apply_fleet_safety_load state = function
  | Ok fleet ->
      state.fleet_safety <- Some fleet;
      state.fleet_safety_error <- None
  | Error err ->
      (* The last good reading is dropped: a stale fleet line is worse than an
         absent one, because it reports keepers as running after the reading
         that said so stopped arriving. *)
      state.fleet_safety <- None;
      remember_surface_error state ~surface:"fleet safety"
        ~current_error:state.fleet_safety_error
        ~set_error:(fun value -> state.fleet_safety_error <- value)
        err

let apply_keeper_roster_load state = function
  | Ok roster ->
      state.keeper_roster <- roster;
      state.keeper_roster_error <- None
  | Error failure ->
      (* The last good roster is dropped rather than kept: a stale one reports
         fibers as running after the reading that said so stopped arriving,
         and every lifecycle action on this surface is chosen from it. Going
         back to unobserved withdraws the actions instead of offering the
         wrong one. *)
      state.keeper_roster <- Keeper_control.Roster_unobserved;
      remember_surface_error state ~surface:"keeper roster"
        ~current_error:state.keeper_roster_error
        ~set_error:(fun value -> state.keeper_roster_error <- value)
        (Keeper_control.roster_failure_message
           ~credential_sent:(Masc_tui_http.operator_token_present ())
           failure)

let apply_planning_load state = function
  | Ok planning ->
      let goal_ids planning =
        planning_visible_goals ~filter:state.planning_filter
          ~sort:state.planning_sort planning.pl_goals
        |> List.map (fun goal -> goal.pg_id)
      in
      let current =
        match state.planning_mode with
        | Planning_list ->
            Planning_selection.List_cursor state.planning_cursor
        | Planning_detail goal_id ->
            Planning_selection.Detail_goal
              { goal_id; cursor = state.planning_cursor }
      in
      let current_ids =
        match state.planning with
        | None -> []
        | Some current_planning -> goal_ids current_planning
      in
      let navigation =
        Planning_selection.reconcile ~current_ids
          ~next_ids:(goal_ids planning) ~current
      in
      state.planning <- Some planning;
      state.planning_error <- None;
      (match navigation with
       | Planning_selection.List_cursor cursor ->
           state.planning_cursor <- cursor;
           state.planning_mode <- Planning_list;
           state.planning_scroll <- 0
       | Planning_selection.Detail_goal { goal_id; cursor } ->
           state.planning_cursor <- cursor;
           state.planning_mode <- Planning_detail goal_id)
  | Error err ->
      state.planning <- None;
      state.planning_mode <- Planning_list;
      state.planning_scroll <- 0;
      remember_surface_error state ~surface:"planning"
        ~current_error:state.planning_error
        ~set_error:(fun value -> state.planning_error <- value)
        err

let apply_fusion_runs_load state = function
  | Ok snapshot ->
      let current_selected_id =
        match state.fusion_mode with
        | Fusion_detail run_id -> Some run_id
        | Fusion_list ->
            Option.bind state.fusion_runs (fun current ->
                List.nth_opt current.Tui_decode.fus_runs state.fusion_cursor
                |> Option.map (fun run -> run.Tui_decode.fur_run_id))
      in
      let next_ids =
        List.map
          (fun run -> run.Tui_decode.fur_run_id)
          snapshot.Tui_decode.fus_runs
      in
      let fallback_cursor =
        min (max 0 state.fusion_cursor) (max 0 (List.length next_ids - 1))
      in
      let next_cursor =
        match current_selected_id with
        | None -> fallback_cursor
        | Some run_id ->
            Option.value
              (List.find_index (String.equal run_id) next_ids)
              ~default:fallback_cursor
      in
      state.fusion_runs <- Some snapshot;
      state.fusion_error <- None;
      state.fusion_cursor <- next_cursor;
      (match state.fusion_mode, current_selected_id with
       | Fusion_detail run_id, Some selected
         when String.equal run_id selected
              && List.exists (String.equal run_id) next_ids ->
           ()
       | Fusion_detail _, _ ->
           state.fusion_mode <- Fusion_list;
           state.fusion_scroll <- 0;
           state.fusion_detail <- None;
           state.fusion_detail_error <- None;
           state.fusion_detail_generation <- state.fusion_detail_generation + 1
       | Fusion_list, _ -> ())
  | Error detail ->
      (* Keep the previous rows. The error marks them stale instead of
         translating a failed refresh into an empty registry. *)
      state.fusion_error <- Some detail

let apply_fusion_detail_load state generation run_id result =
  if
    generation = state.fusion_detail_generation
    &&
    match state.fusion_mode with
    | Fusion_detail current -> String.equal current run_id
    | Fusion_list -> false
  then
    match result with
    | Ok detail when String.equal detail.Tui_decode.fud_run.fur_run_id run_id ->
        state.fusion_detail <- Some detail;
        state.fusion_detail_error <- None
    | Ok detail ->
        state.fusion_detail_error <-
          Some
            (Printf.sprintf "fusion detail returned run %s for request %s"
               detail.Tui_decode.fud_run.fur_run_id run_id)
    | Error detail -> state.fusion_detail_error <- Some detail

let refresh_status results =
  let successes =
    List.fold_left
      (fun count -> function
        | Ok () -> count + 1
        | Error () -> count)
      0 results
  in
  match (successes, List.length results) with
  | 0, _ -> Masc_tui_types.Disconnected
  | n, total when n = total -> Masc_tui_types.Connected
  | _ -> Masc_tui_types.Degraded

let load_http_scoped_surfaces ~host ~port ~approval_generation ~board_sort
    ~board_hearth ~system_log_level ~(needs : Masc_tui_types.surface_needs) =
  let when_needed wanted load = if wanted then Some (load ()) else None in
  (* Only the Overview row shows this, so a refresh on another surface does not
     spend a request on it. [None] leaves whatever the last read observed. *)
  let http_transport =
    when_needed needs.needs_transport (fun () ->
        load_transport_health ~host ~port)
  in
  let http_approvals =
    Option.map
      (fun ao_generation ->
         { ao_generation; ao_result = load_approvals ~host ~port })
      approval_generation
  in
  let http_asks =
    when_needed needs.needs_asks (fun () ->
        Masc_tui_http.fetch_keeper_asks ~host ~port ())
  in
  let http_board =
    when_needed needs.needs_board (fun () ->
        load_board_list ~host ~port ~sort_by:(board_sort_label board_sort)
          ~hearth:board_hearth)
  in
  let http_board_hearths =
    when_needed needs.needs_board (fun () -> load_board_hearths ~host ~port)
  in
  let http_planning =
    when_needed needs.needs_planning (fun () -> load_planning ~host ~port)
  in
  let http_system_logs =
    when_needed needs.needs_system_logs (fun () ->
        load_system_logs ~host ~port ?level:system_log_level
          ~limit:system_log_page ())
  in
  let http_fleet_safety =
    when_needed needs.needs_fleet_safety (fun () -> load_fleet_safety ~host ~port)
  in
  let http_keeper_roster =
    when_needed needs.needs_keeper_roster (fun () ->
        load_keeper_roster ~host ~port)
  in
  { http_transport
  ; http_approvals
  ; http_asks
  ; http_board
  ; http_board_hearths
  ; http_planning
  ; http_system_logs
  ; http_fleet_safety
  ; http_keeper_roster
  }

let load_http_surfaces ~host ~port ~approval_generation ~board_sort
    ~board_hearth ~system_log_level ~(needs : Masc_tui_types.surface_needs) =
  let http_overview = load_overview ~host ~port in
  let http_approvals =
    Option.map
      (fun ao_generation ->
         { ao_generation; ao_result = load_approvals ~host ~port })
      approval_generation
  in
  (* A process can disappear and another bind the same endpoint between two
     successful ticks. The compact /health identity is therefore revalidated
     on every refresh rather than inferred from connection failure. *)
  let http_server_identity = load_server_identity ~host ~port in
  let http_scoped =
    (* Asks ride every refresh, not just the Approvals surface. A question that
       arrives while the operator is elsewhere has to be read to be announced,
       so the periodic refresh always fetches them; the surface still decides
       whether the panel renders, only the fetch is unconditional. Targeted
       scoped refreshes keep their own needs. *)
    load_http_scoped_surfaces ~host ~port ~approval_generation:None ~board_sort
      ~board_hearth ~system_log_level
      ~needs:{ needs with needs_asks = true }
  in
  { http_overview; http_approvals; http_scoped; http_server_identity }

let apply_http_scoped_surfaces state results =
  Option.iter (apply_transport_load state) results.http_transport;
  Option.iter (apply_approval_observation state) results.http_approvals;
  Option.iter (apply_asks_load state) results.http_asks;
  Option.iter (apply_board_list_load state) results.http_board;
  Option.iter (apply_board_hearths_load state) results.http_board_hearths;
  Option.iter (apply_planning_load state) results.http_planning;
  Option.iter (apply_system_logs_load state) results.http_system_logs;
  Option.iter (apply_fleet_safety_load state) results.http_fleet_safety;
  Option.iter (apply_keeper_roster_load state) results.http_keeper_roster

let apply_http_surfaces state results =
  apply_overview_load state results.http_overview;
  Option.iter (apply_approval_observation state) results.http_approvals;
  apply_http_scoped_surfaces state results.http_scoped;
  (* This is a current reading, not a last-known cache. A failed probe makes
     the projection unread; every following refresh asks again, so a same-port
     replacement still moves A -> B as soon as /health succeeds. *)
  state.server_identity <-
    Masc_tui_types.server_identity_of_refresh results.http_server_identity;
  state.workspace_identity <-
    Masc_tui_types.workspace_identity_of_refresh
      ~local_base_path:state.local_base_path
      results.http_server_identity;
  (match state.workspace_identity with
   | Masc_tui_types.Workspace_identity_mismatch _ -> clear_local_workspace state
   | Masc_tui_types.Workspace_identity_match ->
     load_from_masc_dir state state.local_base_path
   | Masc_tui_types.Workspace_identity_unread -> ());
  let reached result =
    Result.map (fun _ -> ()) result |> Result.map_error (fun _ -> ())
  in
  let reached_if_asked result = Option.map reached result |> Option.to_list in
  (* Only the requests this refresh actually made say anything about the
     connection. Overview runs on every surface, so the reading never rests on
     an empty list. *)
  state.connection_status <-
    refresh_status
      ([ reached results.http_overview ]
       @ reached_if_asked results.http_scoped.http_board
       @ reached_if_asked results.http_scoped.http_planning
       @ (Option.map
            (fun observation -> reached observation.ao_result)
            results.http_approvals
          |> Option.to_list))

let load_local_workspace_if_safe state base_path =
  match state.workspace_identity with
  | Masc_tui_types.Workspace_identity_match -> load_from_masc_dir state base_path
  | Masc_tui_types.Workspace_identity_unread
  | Masc_tui_types.Workspace_identity_mismatch _ -> ()
;;

let load_live_context_if_safe state base_path keeper =
  match state.workspace_identity with
  | Masc_tui_types.Workspace_identity_match ->
    load_live_context state base_path keeper
  | Masc_tui_types.Workspace_identity_unread
  | Masc_tui_types.Workspace_identity_mismatch _ -> ()
;;

let load_keeper_logs_if_safe state base_path limit keeper =
  match state.workspace_identity with
  | Masc_tui_types.Workspace_identity_match ->
    load_selected_keeper_logs state base_path limit keeper
  | Masc_tui_types.Workspace_identity_unread
  | Masc_tui_types.Workspace_identity_mismatch _ -> ()
;;

let refresh_keeper_detail_selection state ~base_path ~mailbox =
  match selected_keeper state with
  | None -> ()
  | Some keeper ->
      load_live_context_if_safe state base_path keeper;
      (match state.detail_tab with
       | Detail_info -> ()
       | Detail_sandbox ->
           state.keeper_sandbox_view <- None;
           state.keeper_sandbox_view_error <- None;
           launch_keeper_sandbox_view state ~mailbox keeper.k_name;
           let logs_were_open =
             match
               state.keeper_sandbox_logs, state.keeper_sandbox_logs_error
             with
             | Some (stamp, _), _ | _, Some (stamp, _) ->
               String.equal stamp keeper.k_name
             | None, None -> false
           in
           if logs_were_open then
             launch_keeper_sandbox_logs state ~mailbox keeper.k_name
       | Detail_instructions ->
           state.keeper_config_view <- None;
           state.keeper_config_view_error <- None;
           launch_keeper_config_view state ~mailbox keeper.k_name
       | Detail_secrets ->
           (* Nothing to fetch: the projection arrives with the composite
              body the Lanes refresh already reads. *)
           ()
       | Detail_github ->
           state.github_identity_view <- None;
           state.github_identity_view_error <- None;
           launch_github_identity_view state ~mailbox keeper.k_name
       | Detail_identity ->
           state.identity_view <- None;
           state.identity_view_error <- None;
           (* Another keeper's tab opens at the top of its own list rather
              than at whichever row the last one was left on. *)
           state.identity_cursor <- 0;
           state.identity_attempt_error <- None;
           state.identity_filter <- None;
           launch_identity_view state ~mailbox keeper.k_name
       | Detail_channels -> launch_connectors_load state ~mailbox
       | Detail_automation ->
           state.keeper_schedules <- None;
           state.keeper_schedules_error <- None;
           launch_keeper_schedules_load state ~mailbox ~keeper_name:keeper.k_name
       | Detail_runs -> launch_fusion_runs_load state ~mailbox)
;;

let open_keeper_detail state ~base_path ~mailbox (keeper : keeper) =
  state.view <- Keepers Keeper_detail;
  state.keeper_detail_focus <- Right_pane;
  state.detail_scroll <- 0;
  load_live_context_if_safe state base_path keeper;
  load_keeper_logs_if_safe state base_path 200 (Some keeper);
  (* A sticky non-Info tab re-reads for the keeper the cursor now names;
     without this the pane shows "(loading)" forever after a cursor move,
     because the stamped answer names the previous keeper. *)
  match state.detail_tab with
  | Detail_info -> ()
  | Detail_sandbox ->
      state.keeper_sandbox_view <- None;
      state.keeper_sandbox_view_error <- None;
      launch_keeper_sandbox_view state ~mailbox keeper.k_name
  | Detail_instructions ->
      state.keeper_config_view <- None;
      state.keeper_config_view_error <- None;
      launch_keeper_config_view state ~mailbox keeper.k_name
  | Detail_secrets ->
      (* Arrives with the composite body; nothing to fetch on entering the
         tab. *)
      ()
  | Detail_github ->
      state.github_identity_view <- None;
      state.github_identity_view_error <- None;
      launch_github_identity_view state ~mailbox keeper.k_name
  | Detail_identity ->
      state.identity_view <- None;
      state.identity_view_error <- None;
      launch_identity_view state ~mailbox keeper.k_name
  | Detail_channels -> launch_connectors_load state ~mailbox
  | Detail_automation ->
      state.keeper_schedules <- None;
      state.keeper_schedules_error <- None;
      launch_keeper_schedules_load state ~mailbox ~keeper_name:keeper.k_name
  | Detail_runs -> launch_fusion_runs_load state ~mailbox
;;

(* Enter on a Lanes overview row, shared with the mouse: a press on the row
   already selected is Enter, so both paths open through the same two
   helpers. *)
let open_lanes_standalone_selection state ~mailbox =
  match selected_standalone_lane state with
  | Some (lane : Tui_decode.standalone_lane) ->
      state.lanes_action_error <- None;
      open_lane_run_list state ~mailbox lane
  | None ->
      show_lanes_action_error state
        "Cannot open runs: standalone lane observation is unavailable"

(* A left press on the Lanes overview is the cursor keys by another hand: the
   first press lands the selection on the row under it (exactly where j/k
   would put it), and a press on the row already selected is Enter. *)
let handle_lanes_overview_click state ~base_path:_ ~mailbox ~terminal_rows ~row =
  match lanes_overview_hit state ~terminal_rows ~row with
  | Lanes_hit_none -> ()
  | Lanes_hit_standalone index ->
      if
        state.lanes_standalone_cursor = index
      then open_lanes_standalone_selection state ~mailbox
      else begin
        state.lanes_action_error <- None;
        state.lanes_standalone_cursor <- index
      end

(* Open the runtime event feed on a daemon fiber: one MCP initialize for the
   session id, then the stream, read until it ends. Every step reports back
   through the mailbox; the render fiber owns all state. The fiber ends with
   the stream, and whether to open another is the main loop's decision. *)
let launch_observer state ~host ~port ~mailbox =
  state.observer <- Observer_opening;
  let session = state.mcp_session in
  let run () =
    let result =
      try
        match
          match session with
          | Some session_id -> Ok session_id
          | None ->
              Masc_tui_http.open_mcp_session ~host ~port
                ~client_version:Runtime_build_version.current
        with
        | Error detail -> Error detail
        | Ok session_id -> (
            enqueue_async mailbox (Observer_opened session_id);
            match Eio_context.get_clock_opt () with
            | None -> Error "Eio clock is unavailable"
            | Some clock ->
                let reader = Masc_tui_observer.create () in
                let on_chunk chunk =
                  match Masc_tui_observer.feed reader chunk with
                  | [] -> ()
                  | decoded -> enqueue_async mailbox (Observer_received decoded)
                in
                Masc_tui_http.observe_runtime_events ~clock ~host ~port
                  ~session_id ~on_chunk)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox
      (Observer_closed
         (match result with
          | Ok () -> "the server closed the stream"
          | Error detail -> detail))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None -> enqueue_async mailbox (Observer_closed "Eio switch is unavailable")

(* The feed is opened only after a refresh has reached the server: opening
   it blind would report a closed feed every cycle while the TUI runs without
   one, and that row is meant to say the stream dropped, not that there was
   never a server. Once closed it is reopened on the next refresh that
   reaches the server, which is the cadence the operator already chose. *)
(* [retry_closed] separates the first open from a retry. A feed that has never
   run is opened as soon as the server answers, because the row is meant to say
   the stream dropped and there is nothing to say yet. A feed that ran and
   closed waits for the operator's cadence: retrying it once per finished
   refresh made the retry rate whatever the refresh rate was, and a refresh
   also goes out when the open surface needs something the last one did not
   fetch -- so walking the surfaces retried a refused feed once per surface and
   filled the eleven-entry event panel with its own refusals. *)
let open_observer_if_due state ~retry_closed ~host ~port ~mailbox =
  match (state.connection_status, state.observer) with
  | (Connected | Degraded), Observer_off ->
      launch_observer state ~host ~port ~mailbox
  | (Connected | Degraded), Observer_closed _ when retry_closed ->
      launch_observer state ~host ~port ~mailbox
  | (Connected | Degraded), (Observer_closed _ | Observer_opening | Observer_live _)
  | (Disconnected | Connecting | Reconnecting), _ ->
      ()

let start_http_refresh state ~host ~port ~intent ~refresh_inflight
    ~scoped_refresh_inflight ~scoped_refresh_followup ~mailbox =
  scoped_refresh_followup :=
    note_full_refresh_intent ~intent
      ~full_refresh_inflight:!refresh_inflight
      ~scoped_refresh_inflight:!scoped_refresh_inflight
      !scoped_refresh_followup;
  if not !refresh_inflight then begin
    refresh_inflight := true;
    let flow, approval_generation =
      Approval.Flow.reserve_refresh state.approval_flow
    in
    state.approval_flow <- flow;
    state.connection_status <-
      (match state.connection_status with
       | Connected | Degraded -> Masc_tui_types.Reconnecting
       | Disconnected | Connecting | Reconnecting -> Masc_tui_types.Connecting);
    let needs =
      Masc_tui_types.full_refresh_needs
        ~scoped_refresh_inflight:!scoped_refresh_inflight state.view
    in
    (* The chat pane's history comes down its own generation-guarded path, not
       in the surface bundle, so the tick asks for it here. Without this the
       pane read once on open and a message that arrived after that waited for
       the operator to leave and come back. *)
    (if
       needs.Masc_tui_types.needs_keeper_chat
       (* Not while reading back: the reload replaces the transcript with the
          newest window, which throws away every older page the operator
          fetched and snaps the view to the bottom mid-read. The next tick
          after scroll returns to 0 catches the pane up. *)
       && state.msg_scroll = 0
     then
       match state.msg_target_keeper_name with
       | Some keeper_name -> launch_keeper_history_load state ~mailbox ~keeper_name
       | None -> ());
    (* An operator who consented in a browser is standing in front of a tab
       that does not know it happened: the callback lands on the server, not
       here. So while a login this TUI started is still outstanding, the tick
       asks again. It stops as soon as the answer says attached, so this is
       not a poll that runs forever -- it runs exactly as long as somebody is
       waiting for it. Same shape as the chat reload above, and for the same
       reason: a pane that read once on open showed a fact that had since
       changed. *)
    (if
       state.view = Keepers Keeper_detail
       && state.detail_tab = Detail_identity
       && state.identity_login <> None
     then
       match selected_keeper state with
       | Some keeper -> launch_identity_view state ~mailbox keeper.k_name
       | None -> ());
    (* Held tool calls ride every tick, not just the Approvals surface: the
       strip's Approvals badge is drawn from every surface, and a stale count
       there would be worse than none. The payload is a handful of rows. The
       durable Gate rides with them for the same badge — its rows are the
       ones that keep when nobody is watching, which is exactly when the
       badge is how an operator finds out. The server caches the snapshot. *)
    launch_keeper_tool_approvals_load state ~mailbox;
    launch_gate_snapshot_load state ~mailbox;
    (* The "answering now" badge rides every tick for the same reason as the
       approvals above: it is drawn from every surface, and its whole point
       is the operator who walked away from the chat pane. *)
    launch_keeper_turns_load state ~mailbox;
    (* The schedule list rides for the same reason, now that the agenda strip
       names the next wake from every surface. Fetched only on the Schedules
       surface it was empty everywhere else, and a strip that says nothing is
       scheduled while thirteen wakes are queued is worse than no strip.

       Measured on this workspace before it was added: 12.4 kB gzipped, 2.1 ms
       to serve, against a two-second cadence. The projection sorts the active
       rows ahead of the settled ones and cuts at twenty, so the earliest wake
       is in the payload whether or not the tail is. *)
    launch_schedules_load state ~mailbox;

    let run_refresh () =
      try
        enqueue_async mailbox
          (Http_refresh_done
             (load_http_surfaces ~host ~port ~approval_generation
                ~board_sort:state.board_sort
                ~board_hearth:state.board_hearth
                ~system_log_level:
                  (Option.map Masc.Tui_decode.system_log_level_query
                     state.system_logs_min_level)
                ~needs))
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        enqueue_async mailbox
          (Http_refresh_failed
             ( Printf.sprintf "HTTP refresh failed: %s" (Printexc.to_string exn)
             , approval_generation ))
    in
    match Eio_context.get_switch_opt () with
    | Some sw ->
        Eio.Fiber.fork ~sw run_refresh
    | None ->
        Fun.protect
          ~finally:(fun () -> refresh_inflight := false)
          (fun () ->
             apply_http_surfaces state
               (load_http_surfaces ~host ~port ~approval_generation
                  ~board_sort:state.board_sort
                ~board_hearth:state.board_hearth
                ~system_log_level:
                  (Option.map Masc.Tui_decode.system_log_level_query
                     state.system_logs_min_level)
                ~needs))
  end

let start_http_scoped_refresh state ~host ~port ~refresh_inflight ~mailbox
    ~(needs : Masc_tui_types.surface_needs) =
  if not !refresh_inflight then begin
    refresh_inflight := true;
    let approval_generation =
      if needs.needs_operator_approvals then begin
        let flow, generation = Approval.Flow.reserve_refresh state.approval_flow in
        state.approval_flow <- flow;
        generation
      end
      else None
    in
    (* Chat history has its own generation-guarded loader rather than a field
       in the HTTP surface record. It still follows the same delta: entering
       chat asks once; moving among Keeper modes that share the roster does
       not restart it. *)
    (if needs.needs_keeper_chat && state.msg_scroll = 0 then
       match state.msg_target_keeper_name with
       | Some keeper_name -> launch_keeper_history_load state ~mailbox ~keeper_name
       | None -> ());
    let run_refresh () =
      try
        enqueue_async mailbox
          (Http_scoped_refresh_done
             (load_http_scoped_surfaces ~host ~port
                ~approval_generation ~board_sort:state.board_sort
                ~board_hearth:state.board_hearth
                ~system_log_level:
                  (Option.map Masc.Tui_decode.system_log_level_query
                     state.system_logs_min_level)
                ~needs))
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        enqueue_async mailbox
          (Http_scoped_refresh_failed
             ( Printf.sprintf "HTTP surface refresh failed: %s"
                 (Printexc.to_string exn)
             , approval_generation ))
    in
    match Eio_context.get_switch_opt () with
    | Some sw -> Eio.Fiber.fork ~sw run_refresh
    | None ->
        Fun.protect
          ~finally:(fun () -> refresh_inflight := false)
          (fun () ->
             apply_http_scoped_surfaces state
               (load_http_scoped_surfaces ~host ~port
                  ~approval_generation ~board_sort:state.board_sort
                ~board_hearth:state.board_hearth
                ~system_log_level:
                  (Option.map Masc.Tui_decode.system_log_level_query
                     state.system_logs_min_level)
                ~needs))
  end

let start_scoped_refresh_followup state ~host ~port ~refresh_inflight
    ~scoped_refresh_inflight ~scoped_refresh_followup ~mailbox =
  let next, launch =
    take_scoped_refresh_followup
      ~full_refresh_inflight:!refresh_inflight
      ~scoped_refresh_inflight:!scoped_refresh_inflight
      !scoped_refresh_followup
  in
  scoped_refresh_followup := next;
  if launch then
    start_http_refresh state ~host ~port ~intent:Revalidate ~refresh_inflight
      ~scoped_refresh_inflight ~scoped_refresh_followup ~mailbox

let board_detail_request_still_current state request =
  Board_detail.is_current state.board_detail request
  &&
  match state.board_mode with
  | Board_read post_id ->
      String.equal post_id (Board_detail.request_post_id request)
  | Board_list | Board_compose -> false

let apply_board_post_load state request result =
  if board_detail_request_still_current state request then
    let post_id = Board_detail.request_post_id request in
    let fail err =
      state.board_detail <-
        Board_detail.complete state.board_detail request (Error err);
      if state.view <> Board then
        add_event state "error" (Printf.sprintf "Board detail unavailable: %s" err)
    in
    match result with
    | Ok (post, comments) when String.equal post.bp_id post_id ->
        state.board_detail <-
          Board_detail.complete state.board_detail request (Ok (post, comments));
        (* A detail response enriches one list row; it does not rank the list.
           Moving the completed post to the front made rapid j/k navigation
           snap back to row zero as asynchronous responses arrived. *)
        state.board_posts <-
          List.map
            (fun current ->
              if String.equal current.bp_id post_id then post else current)
            state.board_posts
    | Ok (post, _) ->
        fail
          (Printf.sprintf
             "Board detail response ID mismatch: expected %s, received %s"
             post_id post.bp_id)
    | Error err -> fail err

let start_board_post_refresh state ~host ~port ~post_id ~mailbox =
  match Board_detail.start state.board_detail ~post_id with
  | Board_detail.Already_loading -> ()
  | Board_detail.Started (detail, request) ->
    state.board_detail <- detail;
    let run_refresh () =
      try
        enqueue_async mailbox
          (Board_post_refresh_done
             (request, load_board_post ~host ~port ~post_id))
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        enqueue_async mailbox
          (Board_post_refresh_failed
             ( request,
               Printf.sprintf "board post refresh failed: %s"
                 (Printexc.to_string exn) ))
    in
    match Eio_context.get_switch_opt () with
    | Some sw -> Eio.Fiber.fork ~sw run_refresh
    | None ->
        let result =
          try load_board_post ~host ~port ~post_id with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn ->
              Error
                (Printf.sprintf "board post refresh failed: %s"
                   (Printexc.to_string exn))
        in
        apply_board_post_load state request result

let open_board_post state ~mailbox ~focus (post : board_post) =
  state.board_mode <- Board_read post.bp_id;
  state.board_focus <- focus;
  state.board_scroll <- 0;
  start_board_post_refresh state ~host:server_peer_host
    ~port:state.port ~post_id:post.bp_id ~mailbox

let move_board_posts_pane state ~mailbox ~delta =
  let count = List.length state.board_posts in
  let next = max 0 (min (count - 1) (state.board_cursor + delta)) in
  if count > 0 && next <> state.board_cursor then begin
    state.board_cursor <- next;
    Option.iter
      (open_board_post state ~mailbox ~focus:Left_pane)
      (List.nth_opt state.board_posts next)
  end

(* The next post without leaving the one being read. Reading a board meant
   Esc, move, Enter for every post, which is three keys to do what one does on
   Changes and on the Keeper detail tabs -- both of which already spell it
   [ / ]. Focus is carried rather than reset: an operator reading in the wide
   detail stays there, and one browsing from the list pane stays in the list. *)
let step_board_read state ~mailbox ~delta =
  match state.board_mode with
  | Board_list | Board_compose -> ()
  | Board_read _ ->
      let count = List.length state.board_posts in
      let next = max 0 (min (count - 1) (state.board_cursor + delta)) in
      if count > 0 && next <> state.board_cursor then begin
        state.board_cursor <- next;
        Option.iter
          (open_board_post state ~mailbox ~focus:state.board_focus)
          (List.nth_opt state.board_posts next)
      end

let apply_approval_decision_result state approval decision approvals result =
  (match result with
   | Ok (Approval.Completed _) ->
       add_event state "system"
         (Printf.sprintf "%s: %s" (approval_decision_done decision)
            approval.ap_summary)
   | Ok (Approval.Deferred _) ->
       add_event state "system"
         (Printf.sprintf "Confirmation accepted; action deferred: %s"
            approval.ap_summary)
   | Ok (Approval.Execution_failed (_, detail)) ->
       add_event state "error"
         (Printf.sprintf "Confirmation accepted; action failed: %s" detail)
   | Error err ->
       add_event state "error"
         (Printf.sprintf "%s: %s" (approval_decision_unverified decision) err));
  apply_approvals_load state approvals

let apply_approval_decision_completion state generation approval decision result
    approvals =
  state.pending_approval_action <- None;
  let flow, owns_action =
    Approval.Flow.finish_action state.approval_flow generation
  in
  state.approval_flow <- flow;
  if owns_action then
    apply_approval_decision_result state approval decision approvals result

let start_approval_decision state approval decision ~mailbox =
  match Approval.Flow.begin_action state.approval_flow with
  | Error `Already_inflight ->
      state.pending_approval_action <- None;
      add_event state "system" "Approval action already in progress"
  | Ok (flow, generation) ->
    let () = state.approval_flow <- flow in
    let () = state.pending_approval_action <- None in
    let host = server_peer_host in
    let port = state.port in
    let run_action () =
      let result =
        try
          Masc_tui_http.post_operator_confirm ~host ~port
            ~token:approval.ap_token ~decision
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Printexc.to_string exn)
      in
      let approvals =
        try load_approvals ~host ~port with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error ("approvals reload failed: " ^ Printexc.to_string exn)
      in
      let approvals = { ao_generation = generation; ao_result = approvals } in
      enqueue_async mailbox
        (Approval_decision_done (approval, decision, result, approvals))
    in
    match Eio_context.get_switch_opt () with
    | Some sw -> Eio.Fiber.fork ~sw run_action
    | None ->
        let result =
          try
            Masc_tui_http.post_operator_confirm ~host ~port
              ~token:approval.ap_token ~decision
          with exn -> Error (Printexc.to_string exn)
        in
        let approvals =
          try load_approvals ~host ~port with
          | exn -> Error ("approvals reload failed: " ^ Printexc.to_string exn)
        in
        apply_approval_decision_completion state generation approval decision
          result approvals

(* TEL-OK: TUI-local confirmation gate emits user-visible events here; the
   operator confirmation endpoint owns durable approval telemetry. *)
let handle_approval_decision state approval decision ~mailbox =
  match
    Approval.approval_gate_transition
      ~inflight:(Approval.Flow.action_inflight state.approval_flow)
      ~pending:state.pending_approval_action ~token:approval.ap_token ~decision
  with
  | Approval.Gate_blocked_inflight ->
      state.pending_approval_action <- None;
      add_event state "system" "Approval action already in progress"
  | Approval.Gate_submit ->
      start_approval_decision state approval decision ~mailbox
  | Approval.Gate_arm pending ->
      state.pending_approval_action <- Some pending;
      add_event state "system"
        (Printf.sprintf "Press %s again: %s"
           (approval_decision_key decision)
           approval.ap_summary)

(* The asks an operator can act on: the open ones, in the order the server
   sent them. The pane draws the same list through the same function, so this
   cursor and those rows cannot drift apart. *)
let open_ask_rows state =
  match state.asks_snapshot with
  | None -> []
  | Some snapshot ->
      Ask.open_rows snapshot

let selected_ask_row state = List.nth_opt (open_ask_rows state) state.ask_cursor

let selected_ask_question state =
  match selected_ask_row state with
  | None -> None
  | Some (row : Tui_decode.ask_row) ->
      List.nth_opt row.Tui_decode.ar_questions state.ask_question_cursor

(* Leaving the mode drops the draft. An answer half-written against a question
   the operator walked away from is not a thing to restore later; the Keeper
   is still waiting either way, and the row says so. *)
let leave_ask_answering state =
  state.ask_answer_mode <- Ask_browsing;
  state.ask_draft <- None;
  state.ask_text_entry <- None;
  state.pending_ask_submit <- None

let enter_ask_answering state =
  match selected_ask_row state with
  | None -> add_event state "system" "No question is waiting on you"
  | Some (row : Tui_decode.ask_row) ->
      (* The answer flow is drawn by the approvals list. With an approval's
         detail open that surface is not on screen, so [a] used to set the mode
         and change nothing an operator could see -- the keypress landed and
         the questions stayed hidden. Close the detail, which is where the
         operator asked to go. *)
      state.approval_detail_open <- false;
      state.ask_answer_mode <- Ask_answering { aam_ask_id = row.Tui_decode.ar_id };
      state.ask_question_cursor <- 0;
      state.ask_draft <- Some (Ask.draft_for state.ask_draft ~row);
      state.pending_ask_submit <- None

(* Walking to another ask starts a new draft rather than carrying the old one
   across: [draft_for] keys on the ask id, so the answer cannot land under a
   question the operator never read. *)
let move_ask_cursor state delta =
  let rows = open_ask_rows state in
  let count = List.length rows in
  if count = 0 then ()
  else begin
    let next = max 0 (min (count - 1) (state.ask_cursor + delta)) in
    if next <> state.ask_cursor then begin
      state.ask_cursor <- next;
      state.ask_question_cursor <- 0;
      state.pending_ask_submit <- None;
      match (state.ask_answer_mode, List.nth_opt rows next) with
      (* Walking the list while browsing is not answering. Opening a draft
         here would make [ and ] commit to a question the operator was only
         looking at, and [a] is the key that says they mean it. *)
      | Ask_browsing, _ -> ()
      | Ask_answering _, None -> ()
      | Ask_answering _, Some (row : Tui_decode.ask_row) ->
          state.ask_answer_mode <- Ask_answering { aam_ask_id = row.Tui_decode.ar_id };
          state.ask_draft <- Some (Ask.draft_for state.ask_draft ~row)
    end
  end

let move_ask_question_cursor state delta =
  match selected_ask_row state with
  | None -> ()
  | Some (row : Tui_decode.ask_row) ->
      let count = List.length row.Tui_decode.ar_questions in
      if count > 0 then
        state.ask_question_cursor <-
          max 0 (min (count - 1) (state.ask_question_cursor + delta))

let with_ask_draft state f =
  match (selected_ask_row state, selected_ask_question state) with
  | Some row, Some question ->
      let draft = Ask.draft_for state.ask_draft ~row in
      state.ask_draft <- Some (f draft question);
      (* Editing after arming means the armed answer is not the one on screen
         any more, so the next press arms again rather than sending. *)
      state.pending_ask_submit <- None
  | (Some _ | None), _ -> ()

let toggle_ask_choice state index =
  match selected_ask_question state with
  | None -> ()
  | Some (question : Tui_decode.ask_question) -> (
      match List.nth_opt question.Tui_decode.aq_choices index with
      | None -> ()
      | Some choice ->
          with_ask_draft state (fun draft question ->
              Ask.toggle_choice draft ~question ~choice))

(* Open the editor on the question under the cursor.

   A question can arrive with no choices at all -- the domain accepts one as
   long as it welcomes free text -- and on those the digits answer nothing.
   Until this key existed the panel drew "free text welcome" beside a keyboard
   that had no way to write any, so the only answer the terminal could give
   such a question was [s]: skipped. The dashboard has had a textarea for it
   since the surface shipped.

   Reopening on an answer already written starts from that text rather than
   from blank: a typo in a long answer should cost a backspace, not the whole
   sentence. *)
let begin_ask_text_entry state =
  match (selected_ask_row state, selected_ask_question state) with
  | Some row, Some (question : Tui_decode.ask_question) -> (
      match Ask.free_text_slot question with
      | None ->
          add_event state "system"
            (Printf.sprintf "%s takes one of its choices, not free text"
               question.Tui_decode.aq_header)
      | Some slot ->
          let existing =
            match Ask.response_for (Ask.draft_for state.ask_draft ~row) ~question with
            | Some (Ask.Draft_wrote text) -> text
            | Some (Ask.Draft_chose _) | Some Ask.Draft_skipped | None -> ""
          in
          state.ask_text_entry <- Some { ate_slot = slot; ate_text = existing })
  | (Some _ | None), _ -> ()

(* Typing edits the buffer alone. The draft is written once, on the key that
   closes the editor, so a half-typed answer is never a response the submit
   gate would count as answered. *)
let edit_ask_text state f =
  match state.ask_text_entry with
  | None -> ()
  | Some entry -> state.ask_text_entry <- Some { entry with ate_text = f entry.ate_text }

let commit_ask_text_entry state =
  match state.ask_text_entry with
  | None -> ()
  | Some entry ->
      (* Through the slot, which names its own question: the cursor may have
         been moved by a snapshot arriving while the operator typed, and the
         answer belongs to the question the editor was opened on. Blank text
         clears the response rather than recording one -- an editor emptied by
         backspaces means unanswered, and the domain refuses a blank write. *)
      with_ask_draft state (fun draft _question ->
          Ask.set_text draft ~slot:entry.ate_slot ~text:entry.ate_text);
      state.ask_text_entry <- None

let cancel_ask_text_entry state = state.ask_text_entry <- None

let skip_ask_question state =
  with_ask_draft state (fun draft question -> Ask.skip draft ~question)

let clear_ask_question state =
  with_ask_draft state (fun draft question -> Ask.clear draft ~question)

let apply_ask_answer_completion state answered_label result asks =
  state.ask_submit_inflight <- false;
  state.pending_ask_submit <- None;
  (match result with
   | Ok _ ->
       state.ask_draft <- None;
       state.ask_answer_mode <- Ask_browsing;
       add_event state "system" (Printf.sprintf "Answered %s" answered_label)
   | Error err ->
       (* The mode stays open on failure: the draft is still the operator's
          work, and a conflict means someone else answered, which the reloaded
          rows will show. *)
       add_event state "error" (Printf.sprintf "Answer not recorded: %s" err));
  apply_asks_load state asks

(* TEL-OK: the TUI-local submit gate emits user-visible events here; the
   ask-answer endpoint owns the durable answer telemetry. *)
let start_ask_answer state ~keeper_name ~ask_id ~answered_label ~answers ~mailbox =
  state.ask_submit_inflight <- true;
  let host = server_peer_host in
  let port = state.port in
  let run_action () =
    let result =
      try
        Masc_tui_http.post_keeper_ask_answer ~host ~port ~keeper_name ~ask_id
          ~answers ~actor_id:None ~session_id:None
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    let asks =
      try Masc_tui_http.fetch_keeper_asks ~host ~port () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error ("asks reload failed: " ^ Printexc.to_string exn)
    in
    enqueue_async mailbox (Ask_answer_done (answered_label, result, asks))
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_action
  | None ->
      let result =
        try
          Masc_tui_http.post_keeper_ask_answer ~host ~port ~keeper_name ~ask_id
            ~answers ~actor_id:None ~session_id:None
        with exn -> Error (Printexc.to_string exn)
      in
      let asks =
        try Masc_tui_http.fetch_keeper_asks ~host ~port () with
        | exn -> Error ("asks reload failed: " ^ Printexc.to_string exn)
      in
      apply_ask_answer_completion state answered_label result asks

let handle_ask_submit state ~mailbox =
  match selected_ask_row state with
  | None -> ()
  | Some (row : Tui_decode.ask_row) -> (
      let draft = Ask.draft_for state.ask_draft ~row in
      match Ask.readiness draft ~row with
      | Ask.Not_open ->
          add_event state "system" "That question already has an answer"
      | Ask.Missing questions ->
          (* Every gap at once: the domain reports them together, so an
             operator does not learn about the second one after fixing the
             first. *)
          add_event state "system"
            (Printf.sprintf "Still unanswered: %s"
               (String.concat ", "
                  (List.map
                     (fun (q : Tui_decode.ask_question) -> q.Tui_decode.aq_header)
                     questions)))
      | Ask.Ready answers -> (
          match
            Ask.gate_transition ~inflight:state.ask_submit_inflight
              ~pending:state.pending_ask_submit ~ask_id:row.Tui_decode.ar_id
          with
          | Ask.Ask_gate_blocked_inflight ->
              state.pending_ask_submit <- None;
              add_event state "system" "An answer is already on its way"
          | Ask.Ask_gate_arm ask_id ->
              state.pending_ask_submit <- Some ask_id;
              add_event state "system"
                (Printf.sprintf "Press enter again to answer %s"
                   row.Tui_decode.ar_keeper)
          | Ask.Ask_gate_submit ->
              (* Name the Keeper and what was chosen, not the ask's opaque id,
                 so the confirmation says which decision landed and as what. *)
              let answered_label =
                match Ask.summarize_answer draft ~row with
                | "" -> row.Tui_decode.ar_keeper
                | chosen -> Printf.sprintf "%s: %s" row.Tui_decode.ar_keeper chosen
              in
              start_ask_answer state ~keeper_name:row.Tui_decode.ar_keeper
                ~ask_id:row.Tui_decode.ar_id ~answered_label ~answers ~mailbox))

(* Run one lifecycle action's steps against the server.

   The steps come from [Keeper_control.plan]; this only performs them and
   reports the first answer that ends the sequence. The 409 branch is the one
   piece of routing here: /boot refuses a keeper whose owner is durably
   paused, and the pause only clears through the directive endpoint, so a
   conflict on an action that names a recovery continues into it instead of
   surfacing as a failure. Recovery runs once — a conflict raised by the
   recovery itself is the operator's to read. *)
let run_keeper_action_steps ~host ~port ~keeper_name ~operator_operation_id
    action =
  let perform = function
    | Keeper_control.Lifecycle lifecycle_action ->
        Masc_tui_http.post_keeper_lifecycle ~host ~port ~keeper_name
          ~action:lifecycle_action
    | Keeper_control.Directive directive_action ->
        Masc_tui_http.post_keeper_directive ~host ~port ~keeper_name
          ~action:directive_action ~operator_operation_id
  in
  let rec walk ~recovery_available last_outcome steps =
    match steps with
    | [] -> (
        match last_outcome with
        | Some outcome -> Ok outcome
        | None ->
            (* [plan] never returns an empty step list; if it ever did, an
               empty walk must not read as success. *)
            Error
              (Printf.sprintf "%s has no request to send"
                 (Keeper_control.action_label action)))
    | step :: rest -> (
        match perform step with
        | Error transport -> Error transport
        | Ok (status, body) -> (
            match Keeper_control.classify_response ~status ~body with
            | Keeper_control.Accepted _ as outcome ->
                walk ~recovery_available (Some outcome) rest
            | Keeper_control.Paused_owner_conflict detail -> (
                match
                  ( recovery_available
                  , Keeper_control.recovers_from_conflict action )
                with
                | true, Some recovery_steps ->
                    walk ~recovery_available:false last_outcome recovery_steps
                | true, None | false, _ -> Error detail)
            | Keeper_control.Rejected { status; detail } ->
                Error (Printf.sprintf "HTTP %d: %s" status detail)))
  in
  walk ~recovery_available:true None (Keeper_control.plan action)

let apply_keeper_action_result state ~base_path keeper_name action result =
  state.keeper_action_inflight <- None;
  (match result with
   | Ok (Keeper_control.Accepted { already_live = true }) ->
       add_event state "system"
         (Printf.sprintf "%s was already running; woke it instead of starting a second fiber"
            keeper_name)
   | Ok (Keeper_control.Accepted { already_live = false }) ->
       add_event state "system"
         (Printf.sprintf "%s %s accepted" keeper_name
            (Keeper_control.action_label action))
   | Ok (Keeper_control.Paused_owner_conflict detail)
   | Ok (Keeper_control.Rejected { detail; _ }) ->
       (* [run_keeper_action_steps] returns these as [Error]; keeping the
          branch exhaustive rather than wildcarded means a future outcome
          member has to be answered here too. *)
       add_event state "error"
         (Printf.sprintf "%s %s refused: %s" keeper_name
            (Keeper_control.action_label action) detail)
   | Error detail ->
       add_event state "error"
         (Printf.sprintf "%s %s failed: %s" keeper_name
            (Keeper_control.action_label action) detail));
  (* Both readings the row is built from moved: pause is durable metadata on
     disk, the fiber is in the roster. Reloading the local half here shows the
     change without waiting a refresh interval; the roster arrives with the
     HTTP refresh the caller starts. *)
  load_local_workspace_if_safe state base_path

let start_keeper_action state ~base_path:_ ~mailbox keeper_name action =
  let serial = state.keeper_action_serial + 1 in
  state.keeper_action_serial <- serial;
  state.keeper_action_inflight <- Some (keeper_name, action);
  state.keeper_action_pending <- None;
  add_event state "system"
    (Printf.sprintf "%s %s" (Keeper_control.action_gerund action) keeper_name);
  let host = server_peer_host in
  let port = state.port in
  let operator_operation_id =
    Keeper_control.mint_operation_id ~keeper:keeper_name ~serial
  in
  let run_action () =
    let result =
      try
        run_keeper_action_steps ~host ~port ~keeper_name
          ~operator_operation_id action
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_action_done (keeper_name, action, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_action
  | None ->
      let result =
        try
          run_keeper_action_steps ~host ~port ~keeper_name
            ~operator_operation_id action
        with exn -> Error (Printexc.to_string exn)
      in
      enqueue_async mailbox (Keeper_action_done (keeper_name, action, result))

(* The Board draft splits at the first newline: commit-message shape, one
   buffer covering title and body. Trimming the title keeps a draft whose
   first line has stray spaces publishable without surprising the operator. *)
let split_board_draft (text : string) : string * string =
  match String.index_opt text '\n' with
  | None -> (String.trim text, "")
  | Some idx ->
      ( String.trim (String.sub text 0 idx)
      , String.sub text (idx + 1) (String.length text - idx - 1) )

(* Post the draft through the tools endpoint. Runs in a fiber like a keeper
   action: the compose pane must keep accepting keys while the request is
   out, and the outcome lands in the same mailbox everything else does. *)
let start_board_post state ~mailbox ~(title : string) ~(body : string) =
  state.board_post_error <- None;
  state.board_post_inflight <- true;
  add_event state "system" "posting to Board";
  (* What this send answers for: the completion clears and lands against
     these, not against whatever the operator typed while it was out. *)
  let sent_draft = Buffer.contents state.board_draft in
  let host = server_peer_host in
  let port = state.port in
  let run_post () =
    let result =
      match Masc_tui_http.post_board_new ~host ~port ~title ~body with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json
    in
    enqueue_async mailbox
      (Board_new_post_done { reply_to = None; sent_draft; result })
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_post
  | None -> run_post ()

(* Request a goal lifecycle change through the tools route. Runs in a fiber
   like the other writes; the outcome lands in the shared mailbox and the
   server's phase rules decide, so the TUI never pre-guesses a transition. *)
let start_goal_transition state ~mailbox ~(goal_id : string)
    ~(action : Goal_phase.Public_action.t) =
  state.goal_action_error <- None;
  add_event state "system"
    (Printf.sprintf "goal %s: %s" goal_id
       (Goal_phase.Public_action.to_string action));
  let host = server_peer_host in
  let port = state.port in
  let run_transition () =
    let result =
      match
        Masc_tui_http.post_goal_transition ~host ~port ~goal_id ~action
          ~note:None
      with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json
    in
    enqueue_async mailbox (Goal_transition_done result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_transition
  | None -> run_transition ()

(* The lifecycle keys on a goal detail. Arming is the pattern the keeper
   lifecycle already uses: the first press names the action, the same press
   again submits it, and any other key disarms. [Goal_phase.Public_action.t]
   rides along so no string name of an action exists in this file. *)
let goal_public_action_key (action : Goal_phase.Public_action.t) =
  match action with
  | Goal_phase.Public_action.Request_complete -> "c"
  | Goal_phase.Public_action.Drop -> "x"
  | Goal_phase.Public_action.Reopen -> "o"

let handle_goal_action_key state ~mailbox ~(action : Goal_phase.Public_action.t)
    =
  match state.planning_mode with
  | Planning_detail goal_id -> (
      match state.goal_action_armed with
      | Some (armed_goal, armed_action)
        when String.equal armed_goal goal_id
             && armed_action = action ->
          state.goal_action_armed <- None;
          start_goal_transition state ~mailbox ~goal_id ~action
      | Some _ | None ->
          state.goal_action_armed <- Some (goal_id, action);
          state.goal_action_error <- None;
          add_event state "system"
            (Printf.sprintf "press %s again to %s goal %s"
               (goal_public_action_key action)
               (match action with
                | Goal_phase.Public_action.Request_complete ->
                    "request completion of"
                | Goal_phase.Public_action.Drop -> "drop"
                | Goal_phase.Public_action.Reopen -> "reopen")
               goal_id))
  | Planning_list -> ()

(* Compose-mode keys. Sending is armed rather than pressed: esc offers
   send-or-discard, so a stray key during writing cannot publish. Returns
   false for keys this pane does not own, so Tab and quit keep their global
   meaning. *)
(* Send a comment through the tools route. Same fiber-and-mailbox shape as
   the other board writes; the route stamps the author. *)
let start_board_comment state ~mailbox ~(post_id : string)
    ~(content : string) =
  state.board_post_error <- None;
  state.board_post_inflight <- true;
  add_event state "system" "commenting on Board";
  let sent_draft = Buffer.contents state.board_draft in
  let host = server_peer_host in
  let port = state.port in
  let run_comment () =
    let result =
      match Masc_tui_http.post_board_comment ~host ~port ~post_id ~content with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json
    in
    enqueue_async mailbox
      (Board_new_post_done { reply_to = Some post_id; sent_draft; result })
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_comment
  | None -> run_comment ()

(* Send a vote through the tools route. The voter is stamped by the route,
   so the payload says only which post and which way. *)
let start_board_vote state ~mailbox ~(post_id : string) ~(up : bool) =
  add_event state "system"
    (Printf.sprintf "voting %s on %s" (if up then "up" else "down") post_id);
  let host = server_peer_host in
  let port = state.port in
  let run_vote () =
    let result =
      match Masc_tui_http.post_board_vote ~host ~port ~post_id ~up with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json
    in
    enqueue_async mailbox (Board_vote_done result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_vote
  | None -> run_vote ()

(* The vote keys on the list row under the cursor. Two presses: the first
   names the post and direction, the same press again sends it. The post id
   is captured at arm time, so moving the cursor between presses re-arms
   for the new row rather than voting on the one the operator left. *)
let handle_board_vote_key state ~mailbox ~(up : bool) =
  match state.board_mode with
  | Board_list -> (
      match List.nth_opt state.board_posts state.board_cursor with
      | None -> ()
      | Some post -> (
          match state.board_vote_armed with
          | Some (armed_post, armed_up)
            when String.equal armed_post post.bp_id && armed_up = up ->
              state.board_vote_armed <- None;
              start_board_vote state ~mailbox ~post_id:post.bp_id ~up
          | Some _ | None ->
              state.board_vote_armed <- Some (post.bp_id, up);
              add_event state "system"
                (Printf.sprintf "press %s again to vote %s on %s"
                   (if up then "v" else "V")
                   (if up then "up" else "down")
                   post.bp_id)))
  | Board_read _ | Board_compose -> ()

(* Cancel a schedule through the tools route. Same fiber-and-mailbox shape as
   the other writes; the server's store rules decide whether the row is still
   cancellable, so the TUI does not pre-guess from the status column. *)
let start_schedule_cancel state ~mailbox ~(schedule_id : string) =
  state.schedule_cancel_error <- None;
  add_event state "system"
    (Printf.sprintf "cancelling schedule %s" schedule_id);
  let host = server_peer_host in
  let port = state.port in
  let run_cancel () =
    let result =
      match Masc_tui_http.post_schedule_cancel ~host ~port ~schedule_id with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.tool_envelope_outcome json
    in
    enqueue_async mailbox (Schedule_cancel_done result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_cancel
  | None -> run_cancel ()

let selected_schedule_row state =
  let rows =
    match state.schedules with
    | None -> []
    | Some snapshot -> snapshot.scs_rows
  in
  match state.schedule_detail_id with
  | Some schedule_id ->
      List.find_opt
        (fun row -> String.equal row.sch_schedule_id schedule_id)
        rows
  | None -> List.nth_opt rows state.schedule_cursor

(* The cancel key on the row under the cursor. Two presses, like the vote
   keys: the first names the schedule, the same press again sends it. The
   schedule id is captured at arm time, so moving the cursor between presses
   re-arms for the new row rather than cancelling the one the operator left. *)
let handle_schedule_cancel_key state ~mailbox =
  match selected_schedule_row state with
  | None -> ()
  | Some row -> (
      match state.schedule_cancel_armed with
      | Some armed when String.equal armed row.sch_schedule_id ->
          state.schedule_cancel_armed <- None;
          start_schedule_cancel state ~mailbox
            ~schedule_id:row.sch_schedule_id
      | Some _ | None ->
          state.schedule_cancel_armed <- Some row.sch_schedule_id;
          state.schedule_cancel_error <- None;
          add_event state "system"
            (Printf.sprintf "press x again to cancel %s" row.sch_schedule_id))

(* Send the operator's verdict through the verification route. Same
   fiber-and-mailbox shape as the other writes; whether the task still awaits
   verification is the route's store rules to say, so the TUI does not
   pre-guess from the row it rendered a moment ago. *)
let start_verification_verdict state ~mailbox ~(task_id : string)
    ~(verdict : [ `Approve | `Reject of string ]) =
  state.verification_verdict_error <- None;
  let verb = match verdict with `Approve -> "approving" | `Reject _ -> "rejecting" in
  add_event state "system" (Printf.sprintf "%s %s" verb task_id);
  let host = server_peer_host in
  let port = state.port in
  let run_verdict () =
    let result =
      match Masc_tui_http.post_verification_verdict ~host ~port ~task_id ~verdict with
      | Error err -> Error err
      | Ok json -> Masc.Tui_decode.verification_verdict_outcome json
    in
    enqueue_async mailbox (Verification_verdict_done result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> Eio.Fiber.fork ~sw run_verdict
  | None -> run_verdict ()

(* The row under the Verification cursor, if the list has one. *)
let verification_cursor_row state =
  let requests =
    match state.verification with
    | None -> []
    | Some s -> s.Masc.Tui_decode.vs_requests
  in
  match state.verification_detail_request_id with
  | Some request_id ->
      List.find_opt
        (fun row ->
           String.equal row.Masc.Tui_decode.vr_request_id request_id)
        requests
  | None -> List.nth_opt requests state.verification_cursor

(* The approve key on the row under the cursor. Two presses, like the cancel
   and vote keys: the first names the task, the same press again sends the
   verdict. The task id is captured at arm time, so moving the cursor between
   presses re-arms for the new row rather than approving the one the operator
   left. Reject is not armed -- its $EDITOR reason form is the confirmation. *)
(* Opening a detail is one move -- read the row under the cursor, name it, put
   the pane at the top of it, fetch what the detail needs -- and each surface
   spelled that move inside its own Enter arm, guarded on the detail not being
   open yet.

   [ / ] needs the same move with the opposite guard: the detail IS open and
   the cursor just moved. Spelled twice, the two would drift, and the shape
   that drifts here is "which loads run on open" -- a step that forgot one
   draws the previous row's evidence under the new row's title.

   So the move comes out, ungated, and the two callers bring their own guard.
   The list each reads is the list its own surface draws: Planning filters and
   sorts before indexing, and indexing the unsorted goals would open whichever
   goal happens to sit at that position in the store. *)

let open_planning_detail state ~mailbox =
  let goals =
    match state.planning with
    | None -> []
    | Some p ->
        planning_visible_goals ~filter:state.planning_filter
          ~sort:state.planning_sort p.pl_goals
  in
  match List.nth_opt goals state.planning_cursor with
  | None -> ()
  | Some g ->
      state.planning_mode <- Planning_detail g.pg_id;
      state.planning_scroll <- 0;
      state.goal_timeline <- None;
      launch_goal_timeline_load state ~mailbox g.pg_id

(* The list row carries one wake; the whole history comes from the exact
   lookup, so opening a detail asks for it. Clearing the previous schedule's
   history first is what stops the pane showing one schedule's attempts under
   another's name while the answer is in flight. *)
let open_schedule_detail state ~mailbox =
  match state.schedules with
  | None -> ()
  | Some snapshot ->
      Option.iter
        (fun row ->
          state.schedule_detail_id <- Some row.sch_schedule_id;
          state.schedule_scroll <- 0;
          state.schedule_wake_history <- None;
          state.schedule_wake_history_error <- None;
          launch_schedule_wake_history_load state ~mailbox
            ~schedule_id:row.sch_schedule_id)
        (List.nth_opt snapshot.scs_rows state.schedule_cursor)

let open_verification_detail state ~mailbox =
  let requests =
    match state.verification with
    | None -> []
    | Some s -> s.Masc.Tui_decode.vs_requests
  in
  match List.nth_opt requests state.verification_cursor with
  | None -> ()
  | Some row ->
      state.verification_detail_request_id <-
        Some row.Masc.Tui_decode.vr_request_id;
      state.verification_detail_scroll <- 0;
      state.verification_evidence <- None;
      launch_verification_evidence_load state ~mailbox
        row.Masc.Tui_decode.vr_task_id

let open_harness_detail state =
  match state.harness with
  | None -> ()
  | Some snapshot ->
      Option.iter
        (fun verdict ->
          state.harness_detail <-
            Some (verdict.Masc.Tui_decode.hv_task_id, verdict.hv_at);
          state.harness_detail_scroll <- 0)
        (List.nth_opt snapshot.Masc.Tui_decode.hs_verdicts
           state.harness_cursor)

let open_fusion_detail state ~mailbox =
  let runs =
    match state.fusion_runs with
    | None -> []
    | Some snapshot -> snapshot.fus_runs
  in
  match List.nth_opt runs state.fusion_cursor with
  | None -> ()
  | Some run ->
      state.fusion_mode <- Fusion_detail run.fur_run_id;
      state.fusion_scroll <- 0;
      state.fusion_detail <- None;
      state.fusion_detail_error <- None;
      launch_fusion_detail_load state ~mailbox ~run_id:run.fur_run_id

let open_selected_resource state ~mailbox =
  match
    Option.bind state.resources_list (fun resources ->
        List.nth_opt resources state.resources_cursor)
  with
  | None -> ()
  | Some resource ->
      state.resource_focus <- Right_pane;
      launch_resource_read state ~mailbox ~uri:resource.Masc_tui_mcp.uri

let open_selected_system_log state =
  match
    List.nth_opt
      (Masc_tui_types.visible_system_log_entries state)
      state.system_logs_cursor
  with
  | None -> ()
  | Some entry ->
      state.system_logs_detail_seq <- Some entry.Tui_decode.sl_seq;
      state.system_logs_detail_scroll <- 0
(* One step through the list a detail was opened from, without closing it.
   Reading a queue meant Esc, move, Enter for every row -- three keys to do
   what one does on Changes and the Keeper detail tabs, both of which already
   spell it [ / ].

   [count] is the surface's own list length, so a step past either end stays
   put rather than wrapping: a reader walking a queue wants to arrive at the
   end and know it, not to reappear at the top. *)
let step_detail_cursor ~count ~cursor ~delta ~set_cursor ~reopen =
  if count > 0 then begin
    let next = max 0 (min (count - 1) (cursor + delta)) in
    if next <> cursor then begin
      set_cursor next;
      reopen ()
    end
  end

let handle_verification_approve_key state ~mailbox =
  match verification_cursor_row state with
  | None -> ()
  | Some row -> (
      let task_id = row.Masc.Tui_decode.vr_task_id in
      match state.verification_verdict_armed with
      | Some armed when String.equal armed task_id ->
          state.verification_verdict_armed <- None;
          start_verification_verdict state ~mailbox ~task_id ~verdict:`Approve
      | Some _ | None ->
          state.verification_verdict_armed <- Some task_id;
          state.verification_verdict_error <- None;
          add_event state "system"
            (Printf.sprintf "press a again to approve %s" task_id))

let handle_board_compose_key state ~mailbox (key : string) : bool =
  if
    state.board_compose_armed
    && not
         (List.mem key [ "s"; "S"; "d"; "D"; "esc" ])
  then state.board_compose_armed <- false;
  match key with
  | "esc" ->
      state.board_compose_armed <- not state.board_compose_armed;
      true
  | "s" | "S" when state.board_compose_armed -> (
      (* A reply sends the whole draft as one comment; a new post still
         splits title from body at the first line. *)
      match state.board_compose_reply_to with
      | Some post_id ->
          let content = Buffer.contents state.board_draft in
          if String.equal (String.trim content) "" then begin
            state.board_compose_armed <- false;
            state.board_post_error <- Some "the comment is empty";
            true
          end else if state.board_post_inflight then begin
            state.board_compose_armed <- false;
            state.board_post_error <- Some "a send is already in flight";
            true
          end else begin
            state.board_compose_armed <- false;
            start_board_comment state ~mailbox ~post_id ~content;
            true
          end
      | None ->
          let title, body =
            split_board_draft (Buffer.contents state.board_draft)
          in
          match String.split_on_char '\n' (String.trim title) with
          | [] | [ "" ] ->
              state.board_compose_armed <- false;
              state.board_post_error <- Some "the first line (title) is empty";
              true
          | _ when state.board_post_inflight ->
              state.board_compose_armed <- false;
              state.board_post_error <- Some "a send is already in flight";
              true
          | _ ->
              state.board_compose_armed <- false;
              start_board_post state ~mailbox ~title ~body;
              true )
  | "d" | "D" when state.board_compose_armed ->
      Buffer.clear state.board_draft;
      state.board_compose_armed <- false;
      state.board_post_error <- None;
      (match state.board_compose_reply_to with
       | Some post_id -> state.board_mode <- Board_read post_id
       | None -> state.board_mode <- Board_list);
      add_event state "system" "Board draft discarded";
      true
  | "\r" | "\n" ->
      Buffer.add_char state.board_draft '\n';
      true
  | "\127" | "\b" ->
      let new_content =
        Buffer.contents state.board_draft
        |> Masc_tui_message_layout.drop_last_utf8_scalar
      in
      Buffer.clear state.board_draft;
      Buffer.add_string state.board_draft new_content;
      true
  | "\t" | "shift-tab" -> false
  | s when Masc_tui_message_layout.is_printable_utf8_scalar s ->
      (* The same printable test the chat draft uses: a Korean scalar is
         three bytes and one keystroke, and a control byte is neither. *)
      Buffer.add_string state.board_draft s;
      true
  | _ -> true

(* Said by every keypress gate that finds nothing under the cursor. One name
   rather than the sentence written twice: the two gates have to answer the
   same way, and a test can ask whether each of them reaches this. *)
let no_keeper_under_cursor = "no keeper under the cursor; r to reload the roster"

(* The keypress path. The reading decides which actions exist at all, so a key
   that names an action the reading does not offer says why instead of sending
   a request the server would refuse. *)
let handle_keeper_action state ~base_path ~mailbox action =
  match selected_keeper state with
  | None ->
    (* A keypress with nothing under the cursor said nothing at all, which
       reads as a key that does not exist. The comment above already holds
       this rule for the next gate -- an action the reading does not offer
       says why -- and this gate is the one the operator reaches first. *)
    add_event state "system" no_keeper_under_cursor
  | Some keeper ->
      let reading = keeper_reading state keeper in
      if not (List.mem action (Keeper_control.available reading)) then
        add_event state "system"
          (Printf.sprintf "%s cannot %s right now (%s)" keeper.k_name
             (Keeper_control.action_label action)
             (match reading.Keeper_control.liveness with
              | Keeper_control.Unobserved ->
                  "the live roster has not been read"
              | Keeper_control.Absent | Keeper_control.Present _ ->
                  (if reading.Keeper_control.paused then "paused, "
                   else "")
                  ^ Keeper_control.health_label reading
                  ^ " keeper"))
      else
        match
          Keeper_control.gate_transition
            ~inflight:(Option.is_some state.keeper_action_inflight)
            ~pending:state.keeper_action_pending ~keeper:keeper.k_name action
        with
        | Keeper_control.Gate_blocked_inflight ->
            add_event state "system" "A keeper action is already in progress"
        | Keeper_control.Gate_arm pending ->
            state.keeper_action_pending <- Some pending;
            add_event state "system"
              (Printf.sprintf "Press %s again to %s %s"
                 (Keeper_control.action_key action)
                 (Keeper_control.action_label action) keeper.k_name)
        | Keeper_control.Gate_submit ->
            start_keeper_action state ~base_path ~mailbox keeper.k_name action

(* Apply one keystroke the composer claimed. Sending routes through the same
   chat surface the [c] key opens, so a message typed on the roster and one
   typed in the chat view take the identical dispatch path. *)
(* One microphone capture, off the input loop.

   [Voice_bridge.record_and_transcribe] blocks for as long as the operator
   speaks — up to its timeout — so running it inline would freeze the TUI mid
   sentence. It is forked, and what comes back arrives as an [async_msg] like
   every other background result.

   The meter is read from the recording as it grows rather than from the
   microphone: opening a second capture device costs about 2.5 s here, which is
   longer than most utterances. Sox writes the file continuously, so the level
   of the newest bytes is the level being heard now. Nothing else can tell the
   operator their input device is dead — a dead microphone and a quiet room
   both end as an empty draft. *)
let launch_voice_capture state ~mailbox ~keeper =
  let run () =
    let result =
      try
        Ok
          (Masc.Voice_bridge.record_and_transcribe
             ~agent_id:keeper
             ?noise_floor:state.voice_floor
             (* The level the capture makes its own decisions from, so the bar
                and the trigger cannot disagree. It arrives from the capture's
                fiber, which is why it goes through the mailbox rather than
                straight into the field. *)
             ~on_level:(fun db -> enqueue_async mailbox (Voice_level { keeper; db }))
             ~should_stop:(fun () -> state.voice_stop_requested)
             ())
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    let msg =
      match result with
      | Error e -> Voice_failed { keeper; error = e }
      | Ok (Error e) -> Voice_failed { keeper; error = e }
      | Ok (Ok json) -> (
        let field name =
          match json with
          | `Assoc fields -> (
            match List.assoc_opt name fields with
            | Some (`String v) -> Some v
            | Some _ | None -> None)
          | _ -> None
        in
        match field "status", field "text" with
        | Some "no_audio", _ ->
          Voice_silent
            { keeper
            ; reason = Option.value (field "message") ~default:"nothing was heard"
            }
        | _, Some text when String.trim text <> "" ->
          Voice_transcribed { keeper; text = String.trim text }
        | _, _ -> Voice_silent { keeper; reason = "nothing was heard" })
    in
    enqueue_async mailbox msg
  in
  match Eio_context.get_switch_opt () with
  | None ->
    enqueue_async
      mailbox
      (Voice_failed { keeper; error = "Eio switch is unavailable" })
  | Some sw ->
    state.voice_capture <- Some keeper;
    state.voice_level_db <- None;
    state.voice_stop_requested <- None;
    Eio.Fiber.fork_daemon ~sw (fun () -> run (); `Stop_daemon)
;;

(* Continuous mode's only moving part: after each capture settles, start the
   next one. Left as a separate step rather than looping inside the fiber so
   the mode can be turned off between utterances — a fiber that re-armed itself
   would have to be cancelled mid-recording, and that throws away speech
   already said. *)
let rearm_continuous_capture state ~mailbox ~keeper =
  match state.voice_continuous with
  | Some active when String.equal active keeper && state.voice_capture = None ->
      launch_voice_capture state ~mailbox ~keeper
  | Some _ | None -> ()
;;

let handle_composer_key state ~base_path ~mailbox key =
  if state.workspace_identity <> Masc_tui_types.Workspace_identity_match
  then false
  else
  let composer = Composer_projection.of_state state in
  match Composer.classify_key composer key with
  | Composer.Pass_to_surface -> false
  | Composer.Take_focus ->
      (match composer.Composer.target with
       | Composer.Ready keeper_name ->
           (* Taking focus is what names the recipient: the draft that follows
              belongs to the keeper the row showed at that moment. *)
           state.msg_return <- Keeper_chat_return_detail;
           if
             state.msg_target_keeper_name <> Some keeper_name
           then open_message_for_keeper state keeper_name;
           state.composer_focused <- true
       | Composer.No_target | Composer.Unreachable _ -> ());
      true
  | Composer.Start_listening ->
      (* Pressing it while continuous mode is on turns the mode off. That is
         the only way out: a mode that re-arms itself needs a key that stops
         it, and the key that started it is the one the operator will reach
         for. *)
      (match state.voice_continuous with
       | Some _ ->
           state.voice_continuous <- None;
           state.last_action <- Some ("voice: continuous off", Unix.gettimeofday ())
       | None ->
      (* One capture at a time: a second microphone would contend for the same
         input device and the two transcripts would race into one draft.

         The second press stops the running one, which is what the row has
         been telling the operator it does. It used to start another instead,
         leaving two recorders on one device with no way to end either. *)
      (match state.voice_capture, composer.Composer.target with
       | Some _, _ ->
           state.voice_stop_requested <- Some Masc.Voice_bridge.Keep_what_was_heard;
           state.last_action <- Some ("voice: stopping", Unix.gettimeofday ())
       | None, Composer.Ready keeper_name ->
           launch_voice_capture state ~mailbox ~keeper:keeper_name
       | None, (Composer.No_target | Composer.Unreachable _) -> ()));
      true
  | Composer.Toggle_continuous ->
      (match state.voice_continuous, composer.Composer.target with
       | Some _, _ ->
           state.voice_continuous <- None;
           state.last_action <- Some ("voice: continuous off", Unix.gettimeofday ())
       | None, Composer.Ready keeper_name ->
           (* The floor is measured once here rather than per capture, which is
              what makes the gap between utterances short enough to speak
              across. It is dropped when the mode ends, so a session that moves
              to a different room measures again. *)
           state.voice_continuous <- Some keeper_name;
           state.voice_floor <- Masc.Voice_bridge.measure_noise_floor ~agent_id:keeper_name ();
           state.last_action <- Some ("voice: continuous on", Unix.gettimeofday ());
           if state.voice_capture = None
           then launch_voice_capture state ~mailbox ~keeper:keeper_name
       | None, (Composer.No_target | Composer.Unreachable _) -> ());
      true
  | Composer.Release_focus ->
      (* A running capture is the innermost thing Esc can leave, so it goes
         first and the row keeps its focus. ^Y stops one and keeps what was
         said; this abandons it. *)
      (match state.voice_capture with
       | Some _ ->
           state.voice_stop_requested <- Some Masc.Voice_bridge.Discard;
           state.last_action <- Some ("voice: discarding", Unix.gettimeofday ())
       | None ->
           save_message_draft state;
           state.composer_focused <- false);
      true
  | Composer.Send ->
      state.composer_focused <- false;
      let text = Buffer.contents state.msg_input in
      (match Masc_tui_command.parse text with
       | Masc_tui_command.Say _ ->
           set_msg_scroll state 0;
           if state.view <> Keepers Keeper_message then begin
             match state.msg_target_keeper_name with
             | Some keeper_name ->
                 reset_message_file_changes state keeper_name;
                 launch_keeper_history_load state ~mailbox ~keeper_name
             | None -> ()
           end;
           state.view <- Keepers Keeper_message
       | Masc_tui_command.Switch_keeper _ ->
           (* The switch handler owns the view change. *)
           set_msg_scroll state 0
       (* The preset answers are chat notices — a listing, a saved line, a
          restore report. Typed from the roster they would land in a pane the
          operator is not looking at, so the chat pane comes forward the way
          it does for a message. *)
       | Masc_tui_command.Preset_list | Masc_tui_command.Preset_save _
       | Masc_tui_command.Preset_save_missing_name
       | Masc_tui_command.Preset_restore _
       | Masc_tui_command.Preset_restore_missing_name ->
           set_msg_scroll state 0;
           if state.view <> Keepers Keeper_message then begin
             match state.msg_target_keeper_name with
             | Some keeper_name ->
                 reset_message_file_changes state keeper_name;
                 launch_keeper_history_load state ~mailbox ~keeper_name
             | None -> ()
           end;
           state.view <- Keepers Keeper_message
       | Masc_tui_command.Task_for_keeper _ | Masc_tui_command.Task_missing_title
       | Masc_tui_command.Help | Masc_tui_command.Switch_keeper_missing_name
       | Masc_tui_command.Open_settings
       | Masc_tui_command.Interrupt_turn | Masc_tui_command.Steer_turn _
       | Masc_tui_command.Steer_missing_message
       | Masc_tui_command.Set_thinking _
       | Masc_tui_command.Set_tools _ | Masc_tui_command.Cycle_memory
       (* [/find] moves the pane on purpose, so unlike every other command it
          must not be followed by the reset to the newest row above. *)
       | Masc_tui_command.Find_in_chat _ | Masc_tui_command.Find_next
       | Masc_tui_command.Inspect_context
       | Masc_tui_command.View_image _ | Masc_tui_command.View_image_missing_path
       | Masc_tui_command.Attach_image _ | Masc_tui_command.Attach_image_missing_path
       | Masc_tui_command.Unknown _ ->
           (* A command keeps the surface: the operator asked the TUI, not
              the keeper, and the answer lands in Recent Events. *)
           ());
      send_operator_text state ~base_path ~mailbox text;
      true
  | Composer.Edit ->
      (* Annotated: [handle_message_key] takes labelled callbacks, and a
         missing one leaves a partial application that binds to [_handled]
         without a word. Saying the type here turns that into a build
         failure. *)
      let (_handled : bool) =
        handle_message_key state
          (* The composer row is not the chat surface: no turn of its own is
             on screen, so Esc here has nothing to stop. *)
          ~interrupt_turn:(fun () -> false)
          ~submit_message:(fun _ -> ())
          ~answer_approval:(fun ~tool_call_id:_ ~allow:_ -> ())
          ~load_older:(fun ~before:_ -> ())
          ~paste_image:(fun () -> paste_clipboard_image state)
                   ~open_named_image:(fun () -> open_named_image state)
                   ~inspect_context:(fun () ->
                     match state.msg_target_keeper_name with
                     | Some keeper_name ->
                         open_context_inspector state ~mailbox ~keeper_name
                     | None -> ())
          ~load_tool_changes:(fun () ->
            match state.msg_target_keeper_name with
            | Some keeper_name ->
                launch_keeper_chat_tool_details_load ~force:true state ~mailbox
                  ~keeper_name
            | None -> ())
          ~drain_queue:(fun () -> ())
          (* This call site replays one key to reach the paste handlers; a
             capture is not something a replay should start. *)
          ~start_voice:(fun () -> ())
          ~toggle_voice_continuous:(fun () -> ())
          key
      in
      true

(* Where a paste lands.

   The composer row and the chat pane hold one draft between them
   ([msg_input]), so a paste has one destination whatever surface is on
   screen. When the row is idle the paste takes focus for it, through the same
   path the focus key takes: focus is what names the recipient, and text
   dropped into a draft whose keeper was never resolved is a message with
   nowhere to go.

   The text is sanitized the way every other text this process draws is.
   Typed keys reach the draft only through [is_printable_utf8_scalar], so a
   control byte cannot get in one keystroke at a time; a paste is the one way
   a terminal escape could arrive, and it arrives as spaces instead. *)
(* Names for a spilled paste's file. Read from the clock and from the request
   ids this process already mints, so two pastes in the same second cannot
   claim one name. *)
let spill_stamp () =
  let time = Unix.localtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d%02d%02d-%02d%02d" (time.Unix.tm_year + 1900)
    (time.Unix.tm_mon + 1) time.Unix.tm_mday time.Unix.tm_hour time.Unix.tm_min

let spill_nonce () =
  String.sub (Random_id.uuid_v7 ()) 0 8

(* A file dropped on the composer arrives as a paste. An image is meant to be
   looked at, so it is staged rather than spelled out; every other file keeps
   its path in the draft, which is how an operator names a file they want read.

   Shares handle_paste's guard: a staged image with no keeper to send it to is
   the same silence as a paste with nowhere to go. *)
let attach_dropped_image state ~base_path ~mailbox attachment =
  let in_chat = state.view = Keepers Keeper_message in
  if not (in_chat || state.composer_focused) then
    ignore
      (handle_composer_key state ~base_path ~mailbox Composer.focus_key : bool);
  if not (in_chat || state.composer_focused) then
    add_event state "error"
      (Printf.sprintf "Dropped %s with no Keeper to send it to"
         attachment.Masc_tui_keeper_chat_projection.name)
  else begin
    state.msg_attachments <- state.msg_attachments @ [ attachment ];
    note_attachment_staged state;
    add_event state "system"
      (Printf.sprintf "Attached %s (%s, %d bytes) — %d staged for the next message"
         attachment.Masc_tui_keeper_chat_projection.name
         attachment.Masc_tui_keeper_chat_projection.mime_type
         attachment.Masc_tui_keeper_chat_projection.size
         (List.length state.msg_attachments))
  end

let handle_paste state ~base_path ~mailbox ~(paste : Masc_tui_paste.t) =
  if state.workspace_identity <> Masc_tui_types.Workspace_identity_match
  then ()
  else
  let in_chat = state.view = Keepers Keeper_message in
  if not (in_chat || state.composer_focused) then
    ignore
      (handle_composer_key state ~base_path ~mailbox Composer.focus_key : bool);
  if not (in_chat || state.composer_focused) then
    (* No keeper is selected, or the one that is cannot be written to. A paste
       that says nothing and goes nowhere is the silence this surface keeps
       being caught by. *)
    add_event state "error"
      (Printf.sprintf "Pasted %d character(s) with no Keeper to send them to"
         (String.length paste.Masc_tui_paste.text))
  else begin
    forget_recall state;
    let text =
      Keeper_chat.terminal_safe_text ~preserve_newlines:true
        paste.Masc_tui_paste.text
    in
    (match
       Masc_tui_paste_spill.of_paste ~now_iso:(spill_stamp ())
         ~nonce:(spill_nonce ()) text
     with
     | None -> Buffer.add_string state.msg_input text
     | Some spill ->
         (* One line in the draft, the text kept beside it. The composer is
            five rows: a four-hundred-line paste in it is a draft the operator
            cannot read, and a draft they cannot read is a message they cannot
            check before sending. The text goes back in on the way out, so
            what the keeper receives is what was pasted. *)
         state.msg_spill <- Some spill;
         Buffer.add_string state.msg_input
           (Masc_tui_paste_spill.draft_line spill));
    if paste.Masc_tui_paste.dropped > 0 then
      add_event state "error"
        (Printf.sprintf "Paste kept the first %d bytes; %d more were dropped"
           Masc_tui_paste.max_bytes paste.Masc_tui_paste.dropped)
  end

let apply_async_message state ~base_path ~http_refresh_inflight
    ~http_scoped_refresh_inflight ~scoped_refresh_followup ~mailbox =
  function
  (* Every voice message carries the keeper the capture was started for, and
     each is dropped unless that capture is still the one in flight. An
     operator who moved the cursor, or pressed the key again, has said the
     first capture no longer belongs to this draft. *)
  | Voice_config_loaded (result, device) ->
      state.voice_input_device <- device;
      (match result with
       | Ok json ->
           state.voice_config <- Some json;
           state.voice_config_error <- None
       | Error message ->
           state.voice_config <- None;
           state.voice_config_error <- Some message)
  | Voice_level { keeper; db } ->
      if state.voice_capture = Some keeper then state.voice_level_db <- Some db
  | Voice_transcribed { keeper; text } ->
      if state.voice_capture = Some keeper then (
        state.voice_capture <- None;
        state.voice_level_db <- None;
        rearm_continuous_capture state ~mailbox ~keeper;
        (* Appended, not replacing: an operator who typed part of a message and
           then spoke the rest keeps both. A separator only where there is
           something to separate. *)
        if Buffer.length state.msg_input > 0
           && not (String.equal (Buffer.contents state.msg_input) "")
        then Buffer.add_char state.msg_input ' ';
        Buffer.add_string state.msg_input text;
        save_message_draft state;
        state.last_action <- Some ("voice: " ^ text, Unix.gettimeofday ()))
  | Voice_silent { keeper; reason } ->
      if state.voice_capture = Some keeper then (
        state.voice_capture <- None;
        state.voice_level_db <- None;
        (* Silence re-arms too: an operator who paused longer than the
           trailing-silence window has not left the mode. *)
        rearm_continuous_capture state ~mailbox ~keeper;
        (* In the transcript, not only the footer. A capture that heard
           nothing leaves the draft exactly as a capture that was never
           transcribed does, and the footer line saying which is gone by the
           time an operator looks away and back. The reason carries the room
           level and the level speech had to clear, so this row answers "is
           the microphone working" rather than only reporting that it is
           not. *)
        chat_notice state ~keeper_name:(Some keeper) ~role:Message_local
          ("voice: " ^ reason);
        state.last_action <- Some ("voice: " ^ reason, Unix.gettimeofday ()))
  | Voice_failed { keeper; error } ->
      if state.voice_capture = Some keeper then (
        state.voice_capture <- None;
        state.voice_level_db <- None;
        (* A failure ends the mode rather than re-arming into it. Whatever
           stopped the recorder — no input device, a missing binary — will stop
           it again, and a loop that re-arms on failure spins. *)
        state.voice_continuous <- None;
        state.voice_floor <- None;
        chat_notice state ~keeper_name:(Some keeper) ~role:Message_error
          ("voice failed: " ^ error);
        state.last_action <- Some ("voice failed: " ^ error, Unix.gettimeofday ()))
  | Http_refresh_done results ->
      http_refresh_inflight := false;
      apply_http_surfaces state results;
      (* The held-call listing rides the same cadence as the surface that
         draws it. Fetched only while the surface is up: the waits are
         short-lived and every other surface would fetch rows it never
         shows. *)
      (match state.view with
       | Approvals -> launch_keeper_tool_approvals_load state ~mailbox
       | Keepers _ -> launch_keeper_tool_modes_load state ~mailbox
       | _ -> ());
      open_observer_if_due state ~retry_closed:false
        ~host:(server_peer_host) ~port:state.port ~mailbox;
      start_scoped_refresh_followup state ~host:(server_peer_host)
        ~port:state.port ~refresh_inflight:http_refresh_inflight
        ~scoped_refresh_inflight:http_scoped_refresh_inflight
        ~scoped_refresh_followup ~mailbox
  | Observer_opened session_id ->
      state.mcp_session <- Some session_id;
      state.observer <-
        Observer_live { session_id; since = Unix.gettimeofday (); events = 0 };
      add_event state "observer" "runtime event feed open"
  | Observer_received decoded ->
      let received = Unix.gettimeofday () in
      (* One reload per batch, however many turns it carries: the pane
         shows the whole history anyway, and the loader is generation-
         guarded, so the flag only remembers that a reload is due. *)
      let open_chat_gained_turn = ref false in
      List.iter
        (fun item ->
          match item with
          | Masc_tui_observer.Event event ->
              (match state.observer with
               | Observer_live live ->
                   state.observer <-
                     Observer_live { live with events = live.events + 1 }
               | Observer_off | Observer_opening | Observer_closed _ -> ());
              (match Masc_tui_observer.chat_appended_keeper event with
               | Some appended_keeper
                 when state.view = Keepers Keeper_message
                      && state.msg_target_keeper_name = Some appended_keeper ->
                   open_chat_gained_turn := true
               | Some _ | None -> ());
              state.acting <-
                { Masc_tui_acting.ae_at = received; ae_event = event }
                :: state.acting;
              (* A row arriving at the top pushes every row down one. An
                 operator scrolled into the past keeps the rows they were
                 reading and a count of what arrived above them. *)
              if state.acting_scroll > 0 then begin
                state.acting_scroll <- state.acting_scroll + 1;
                state.acting_unseen <- state.acting_unseen + 1
              end
          | Masc_tui_observer.Undecodable reason ->
              state.acting_undecodable <- state.acting_undecodable + 1;
              state.acting_undecodable_last <- Some reason)
        decoded;
      if
        List.length state.acting
        > Masc_tui_types.acting_retained_entries
          + Masc_tui_types.acting_retained_quiet
      then begin
        let kept, dropped =
          Masc_tui_acting.retain
            ~actions:Masc_tui_types.acting_retained_entries
            ~quiet:Masc_tui_types.acting_retained_quiet
            ~event_of:(fun entry -> entry.Masc_tui_acting.ae_event)
            state.acting
        in
        state.acting <- kept;
        state.acting_dropped <- state.acting_dropped + dropped
      end;
      (* The pane otherwise reloads only on open, on its own sends and on
         the operator cadence — a turn appended from anywhere else (API
         chat, another operator, a connector) stayed invisible until the
         operator left and re-entered.  Same guard as the cadence reload:
         an operator scrolled into the past keeps their place. *)
      (if !open_chat_gained_turn && state.msg_scroll = 0 then
         match state.msg_target_keeper_name with
         | Some keeper_name ->
             launch_keeper_history_load ~load_file_changes:false state ~mailbox
               ~keeper_name
         | None -> ())
  | Task_dispatched { keeper; task_id; title; body } ->
      add_event state "task" (Printf.sprintf "%s created for %s" task_id keeper);
      (* The jump lands on a clean screen: a modal or roster search opened
         while the dispatch was in flight would otherwise sit over (or
         zombie under) a surface it was not opened on. *)
      state.help_open <- false;
      state.palette_open <- false;
      state.palette_query <- "";
      state.palette_cursor <- 0;
      state.search <- None;
      set_msg_scroll state 0;
      state.view <- Keepers Keeper_message;
      start_keeper_message ~keeper_name:keeper state ~base_path ~mailbox
        (Masc_tui_command.task_message ~task_id ~title ~body)
  | Task_dispatch_failed { keeper; detail; original } ->
      (* The operator's words come back to the input so nothing typed is
         lost with the failure. *)
      Buffer.clear state.msg_input;
      Buffer.add_string state.msg_input original;
      add_event state "error"
        (Printf.sprintf "task for %s not created: %s" keeper detail)
  | Observer_closed reason ->
      let events =
        match state.observer with
        | Observer_live live -> live.events
        | Observer_off | Observer_opening | Observer_closed _ -> 0
      in
      state.observer <-
        Observer_closed { reason; at = Unix.gettimeofday (); events };
      (* A stream the server refused outright delivered nothing. The session
         it was asked under is dropped so the next attempt opens a fresh one;
         a stream that ran and ended keeps the session for the next. *)
      if events = 0 then state.mcp_session <- None;
      add_event state "observer" ("runtime event feed closed: " ^ reason)
  | Http_refresh_failed (err, approval_generation) ->
      http_refresh_inflight := false;
      Option.iter
        (fun ao_generation ->
           apply_approval_observation state
             { ao_generation; ao_result = Error err })
      approval_generation;
      state.server_identity <- None;
      state.connection_status <- Masc_tui_types.Disconnected;
      add_event state "error" err;
      start_scoped_refresh_followup state ~host:(server_peer_host)
        ~port:state.port ~refresh_inflight:http_refresh_inflight
        ~scoped_refresh_inflight:http_scoped_refresh_inflight
        ~scoped_refresh_followup ~mailbox
  | Http_scoped_refresh_done results ->
      http_scoped_refresh_inflight := false;
      apply_http_scoped_surfaces state results;
      (match state.view with
       | Approvals -> launch_keeper_tool_approvals_load state ~mailbox
       | Keepers _ -> launch_keeper_tool_modes_load state ~mailbox
       | _ -> ());
      start_scoped_refresh_followup state ~host:(server_peer_host)
        ~port:state.port ~refresh_inflight:http_refresh_inflight
        ~scoped_refresh_inflight:http_scoped_refresh_inflight
        ~scoped_refresh_followup ~mailbox
  | Http_scoped_refresh_failed (err, approval_generation) ->
      http_scoped_refresh_inflight := false;
      Option.iter
        (fun ao_generation ->
           apply_approval_observation state
             { ao_generation; ao_result = Error err })
        approval_generation;
      (* A scoped surface read cannot establish that the server disappeared:
         only the full refresh owns /health and connection status. Keep the
         last observed connection and expose the failed dataset read. *)
      add_event state "error" err;
      start_scoped_refresh_followup state ~host:(server_peer_host)
        ~port:state.port ~refresh_inflight:http_refresh_inflight
        ~scoped_refresh_inflight:http_scoped_refresh_inflight
        ~scoped_refresh_followup ~mailbox
  | Board_post_refresh_done (request, result) ->
      apply_board_post_load state request result
  | Board_post_refresh_failed (request, err) ->
      apply_board_post_load state request (Error err)
  | Keeper_action_done (keeper_name, action, result) ->
      apply_keeper_action_result state ~base_path keeper_name action result;
      (* The roster is the half of the row this refresh cannot read from disk,
         and it is what decides which action the row offers next. Asking for it
         now means the row stops offering the action that just ran without
         waiting out the refresh interval. *)
      start_http_refresh state ~host:(server_peer_host)
        ~port:state.port ~intent:Revalidate
        ~refresh_inflight:http_refresh_inflight
        ~scoped_refresh_inflight:http_scoped_refresh_inflight
        ~scoped_refresh_followup ~mailbox
  | Board_new_post_done { reply_to; sent_draft; result } -> (
      (* The completion answers for the draft it carried, not for whatever
         is in the buffer now: a slow server must not clear words typed
         since, nor yank the operator out of a compose they restarted. *)
      state.board_post_inflight <- false;
      let compose_unchanged =
        String.equal (Buffer.contents state.board_draft) sent_draft
      in
      match result with
      | Ok message ->
          add_event state "system" ("Board: " ^ message);
          if compose_unchanged then begin
            Buffer.clear state.board_draft;
            state.board_compose_armed <- false;
            state.board_compose_reply_to <- None;
            state.board_post_error <- None;
            match reply_to with
            | Some post_id -> state.board_mode <- Board_read post_id
            | None -> state.board_mode <- Board_list
          end;
          (* The posted row is the half the periodic refresh has not fetched
             yet; without this the operator returns to a list that does not
             contain what they just published. A comment refreshes the
             detail too, so the reply is visible the moment it lands. *)
          start_http_refresh state ~host:(server_peer_host)
            ~port:state.port ~intent:Revalidate
            ~refresh_inflight:http_refresh_inflight
            ~scoped_refresh_inflight:http_scoped_refresh_inflight
            ~scoped_refresh_followup ~mailbox;
          (match reply_to with
           | Some post_id ->
               start_board_post_refresh state
                 ~host:(server_peer_host)
                 ~port:state.port ~post_id ~mailbox
           | None -> ())
      | Error err ->
          state.board_compose_armed <- false;
          (* The draft stays: a rejected post is usually one field short, and
             losing the text over it would make the error a dead end. *)
          state.board_post_error <- Some err)
  | Board_vote_done result -> (
      match result with
      | Ok message ->
          state.board_vote_armed <- None;
          add_event state "system" ("Board vote: " ^ message);
          (* The score is drawn from the list; refresh it rather than
             waiting out the interval to see the arrow land. *)
          start_http_refresh state ~host:(server_peer_host)
            ~port:state.port ~intent:Revalidate
            ~refresh_inflight:http_refresh_inflight
            ~scoped_refresh_inflight:http_scoped_refresh_inflight
            ~scoped_refresh_followup ~mailbox
      | Error err ->
          state.board_vote_armed <- None;
          add_event state "error" ("Board vote failed: " ^ err))
  | Goal_transition_done result -> (
      match result with
      | Ok message ->
          state.goal_action_armed <- None;
          state.goal_action_error <- None;
          add_event state "system" ("Goal: " ^ message);
          (* The phase shown is the half the periodic refresh has not fetched
             yet; without this the detail keeps the old phase after the
             operator already changed it. *)
          start_http_refresh state ~host:(server_peer_host)
            ~port:state.port ~intent:Revalidate
            ~refresh_inflight:http_refresh_inflight
            ~scoped_refresh_inflight:http_scoped_refresh_inflight
            ~scoped_refresh_followup ~mailbox
      | Error err ->
          state.goal_action_armed <- None;
          state.goal_action_error <- Some err)
  | Verification_evidence_loaded (task_id, result) ->
      (match verification_cursor_row state, state.verification_detail_request_id with
       | Some row, Some _ when String.equal row.Masc.Tui_decode.vr_task_id task_id ->
           state.verification_evidence <- Some (task_id, result)
       | _ -> ())
  | Task_cancel_done (task_id, result) ->
      (match result with
       | Ok _ ->
           add_event state "system"
             (Printf.sprintf "task %s cancelled" task_id);
           (* The backlog row and the detail's history both changed; refresh
              re-reads the backlog, and the history reload draws the cancel
              the operator just performed. *)
           state.task_history <- None;
           launch_task_history_load state ~mailbox task_id;
           start_http_refresh state ~host:server_peer_host ~port:state.port
             ~intent:Revalidate ~refresh_inflight:http_refresh_inflight
             ~scoped_refresh_inflight:http_scoped_refresh_inflight
             ~scoped_refresh_followup ~mailbox
       | Error err -> add_event state "error" ("task cancel failed: " ^ err))
  | Goal_timeline_loaded (goal_id, result) ->
      (* Drawn only while the operator still has this goal open; a stale
         answer for a goal already left is dropped, same as the call log. *)
      (match state.planning_mode with
       | Planning_detail current when String.equal current goal_id ->
           state.goal_timeline <- Some (goal_id, result)
       | _ -> ())
  | Task_history_loaded (task_id, result) ->
      (match state.task_detail_id with
       | Some current when String.equal current task_id ->
           state.task_history <- Some (task_id, result)
       | _ -> ())
  | Keeper_calls_loaded (generation, keeper_name, result) -> (
      let still_current =
        generation = state.keeper_calls_generation
        && Option.equal String.equal state.keeper_calls_keeper
             (Some keeper_name)
      in
      if still_current then begin
        let refresh_pending = state.keeper_calls_refresh_pending in
        state.keeper_calls_loading <- false;
        state.keeper_calls_refresh_pending <- false;
        (match result with
         | Ok snapshot when String.equal snapshot.kcs_keeper keeper_name ->
             state.keeper_calls <- Some snapshot;
             state.keeper_calls_error <- None
         | Ok snapshot ->
             state.keeper_calls_error <-
               Some
                 (Printf.sprintf
                    "tool-call response named keeper %s, expected %s"
                    snapshot.kcs_keeper keeper_name)
         | Error detail -> state.keeper_calls_error <- Some detail);
        let still_visible =
          match state.view with
          | Keepers Keeper_message ->
              state.msg_tool_visibility = Tools_full
              && Option.equal String.equal state.msg_target_keeper_name
                   (Some keeper_name)
          | Keepers Keeper_calls ->
              Option.exists
                (fun (keeper : keeper) -> String.equal keeper.k_name keeper_name)
                (selected_keeper state)
          | _ -> false
        in
        if refresh_pending && still_visible then
          launch_keeper_calls_load ~force:true state ~mailbox keeper_name
      end)
  | Keeper_config_view_loaded (keeper_name, result) -> (
      let still_selected =
        match List.nth_opt state.keepers state.keeper_cursor with
        | Some keeper -> String.equal keeper.k_name keeper_name
        | None -> false
      in
      if still_selected then
        match result with
        | Ok lines ->
            state.keeper_config_view <- Some (keeper_name, lines);
            state.keeper_config_view_error <- None
        | Error detail -> state.keeper_config_view_error <- Some detail)
  | Keeper_sandbox_view_loaded (keeper_name, result) -> (
      let still_selected =
        match List.nth_opt state.keepers state.keeper_cursor with
        | Some keeper -> String.equal keeper.k_name keeper_name
        | None -> false
      in
      if still_selected then
        match result with
        | Ok reading ->
            state.keeper_sandbox_view <- Some (keeper_name, reading);
            state.keeper_sandbox_view_error <- None
        | Error detail -> state.keeper_sandbox_view_error <- Some detail)
  | Keeper_sandbox_logs_loaded (keeper_name, generation, result) -> (
      let is_current =
        state.keeper_sandbox_logs_inflight = Some (keeper_name, generation)
      in
      if is_current then begin
        state.keeper_sandbox_logs_inflight <- None;
        match result with
        | Ok logs ->
          state.keeper_sandbox_logs <- Some (keeper_name, logs);
          state.keeper_sandbox_logs_error <- None
        | Error detail ->
          state.keeper_sandbox_logs_error <- Some (keeper_name, detail)
      end)
  | Prompts_loaded result ->
      (match result with
       | Ok snapshot ->
           state.prompts_snapshot <- Some snapshot;
           state.prompts_cursor <-
             max 0
               (min state.prompts_cursor
                  (prompt_catalog_count_for_state state - 1));
           state.prompts_error <- None
       | Error detail -> state.prompts_error <- Some detail)
  | Presets_listed (sink, result) ->
      (match sink, result with
       | Preset_to_chat target, Ok snapshot ->
           chat_notice state ~keeper_name:target ~role:Message_local
             (String.concat "\n" (Masc_tui_preset_text.listing_lines snapshot))
       | Preset_to_chat target, Error detail ->
           chat_notice state ~keeper_name:target ~role:Message_error detail
       | Preset_to_pane, Ok snapshot ->
           state.presets_snapshot <- Some snapshot;
           state.presets_error <- None;
           state.presets_cursor <-
             max 0
               (min state.presets_cursor
                  (List.length snapshot.Tui_decode.pss_presets - 1))
       | Preset_to_pane, Error detail -> state.presets_error <- Some detail)
  | Preset_saved (sink, result) ->
      (match sink, result with
       | Preset_to_chat target, Ok manifest ->
           chat_notice state ~keeper_name:target ~role:Message_local
             (Masc_tui_preset_text.saved_line manifest)
       | Preset_to_chat target, Error detail ->
           chat_notice state ~keeper_name:target ~role:Message_error detail
       | Preset_to_pane, Ok manifest ->
           state.preset_busy <- false;
           report_action state "system" (Masc_tui_preset_text.saved_line manifest);
           launch_presets_load state ~mailbox
       | Preset_to_pane, Error detail ->
           state.preset_busy <- false;
           report_action state "error" ("preset save: " ^ detail))
  | Preset_restored (sink, result) ->
      (match sink, result with
       | Preset_to_chat target, Ok report ->
           let role =
             if Masc_tui_preset_text.restore_is_clean report then Message_local
             else Message_error
           in
           chat_notice state ~keeper_name:target ~role
             (String.concat "\n" (Masc_tui_preset_text.restore_lines report))
       | Preset_to_chat target, Error detail ->
           chat_notice state ~keeper_name:target ~role:Message_error detail
       | Preset_to_pane, Ok report ->
           state.preset_busy <- false;
           state.preset_report <- Some report;
           report_action state
             (if Masc_tui_preset_text.restore_is_clean report then "system" else "error")
             (Printf.sprintf "%s 복원 · 이전 상태는 %s"
                report.Tui_decode.prr_restored report.Tui_decode.prr_autosave);
           launch_presets_load state ~mailbox
       | Preset_to_pane, Error detail ->
           state.preset_busy <- false;
           report_action state "error" ("preset restore: " ^ detail))
  | Librarian_input_loaded (prompt_key, result) ->
      let still_selected =
        match selected_prompt_for_state state with
        | Some row -> String.equal row.Tui_decode.pr_key prompt_key
        | None -> false
      in
      if still_selected then begin
        state.prompts_librarian_input_loading <- false;
        state.config_scroll <- 0;
        match result with
        | Ok lines ->
            state.prompts_librarian_input <- Some (prompt_key, lines);
            state.prompts_librarian_input_error <- None
        | Error detail ->
            state.prompts_librarian_input <- None;
            state.prompts_librarian_input_error <- Some detail
      end
  | Runtime_params_loaded result -> (
      state.runtime_params_loading <- false;
      match result with
      | Ok rows ->
          state.runtime_params <- rows;
          state.runtime_params_cursor <-
            max 0 (min state.runtime_params_cursor (List.length rows - 1));
          state.runtime_params_error <- None
      | Error detail ->
          (* Reported, not swallowed into an empty list: empty means nothing is
             registered, which is a working state. *)
          state.runtime_params_error <- Some detail)
  | Runtime_config_view_loaded result -> (
      match result with
      | Ok (path, lines) ->
          (* Lexed once here rather than per frame or per row. TOML opens a
             string with a triple quote that closes several rows later, and
             masc's own tool declarations are written that way, so a row cannot
             tell on its own whether it is inside one. The Code surface loads
             the same way for the same reason. *)
          let rows =
            Masc_tui_code_lexer.rows_of_source
              ~language:(Masc_tui_code_lexer.language_of_path path)
              (String.concat "\n" lines)
            |> List.map
                 (List.map (fun (text, kind) ->
                      (Masc.Tui_decode.sanitize_terminal_text text, kind)))
          in
          state.runtime_config_view <- Some (path, rows);
          (* Parsed here, with the lex, so the pane and the scroll bound read
             one list. Parsing per frame would put the count a frame behind
             the keys on a reload. *)
          state.config_models_rows <-
            Masc_tui_model_runtime_table.parse lines;
          set_runtime_config_cursor_near state ~direction:1
            ~target:state.runtime_config_cursor;
          state.runtime_config_view_error <- None;
          (match apply_runtime_config_jump state with
           | None -> ()
           | Some (section, true) ->
             add_event state "info"
               (Printf.sprintf "runtime.toml at [%s] - e to edit" section)
           | Some (section, false) ->
             add_event state "error"
               (Printf.sprintf "runtime.toml has no [%s] section" section))
      | Error detail ->
          state.runtime_config_jump_section <- None;
          state.runtime_config_view_error <- Some detail)
  | Code_entries_loaded (dir, result) ->
      if String.equal dir state.code_dir then (
        match result with
        | Ok entries ->
            state.code_entries <- entries;
            state.code_entries_error <- None;
            state.code_cursor <-
              max 0 (min state.code_cursor (List.length entries - 1))
        | Error detail -> state.code_entries_error <- Some detail)
  | Code_file_loaded (path, result) -> (
      match result with
      | Ok content ->
          (* Lex once at load: comment and string state crosses rows, so a
             window could not answer. Past the budget the file draws plain
             rather than slowly. *)
          let language =
            if String.length content > 500_000 then None
            else Masc_tui_code_lexer.language_of_path path
          in
          let rows =
            Masc_tui_code_lexer.rows_of_source ~language content
            |> List.map
                 (List.map (fun (text, kind) ->
                      (Masc.Tui_decode.sanitize_terminal_text text, kind)))
          in
          state.code_file <- Some (path, rows);
          state.code_file_error <- None;
          (* The jump that asked for this file may have named a line; the
             reset and the jump live together so neither overwrites the
             other. Consumed once -- the next plain open starts at the top. *)
          state.code_file_scroll <-
            (match state.code_target_line with
             | Some line -> max 0 (line - 1)
             | None -> 0);
          state.code_file_cursor <- state.code_file_scroll;
          state.code_lsp_note <- None;
          state.code_target_line <- None;
          state.code_file_hscroll <- 0;
          (* The widest row is the horizontal clamp; measured here, once,
             not on every l press over ten thousand rows. *)
          state.code_file_max_width <-
            List.fold_left
              (fun widest segments ->
                let row_width =
                  List.fold_left
                    (fun acc (text, _) ->
                      acc + Message_layout.display_width text)
                    0 segments
                in
                max widest row_width)
              0 rows;
          state.code_focus_file <- Right_pane;
          (* A new file starts on its content; the old file's history or
             diff would caption the wrong bytes. *)
          state.code_history <- None;
          state.code_history_error <- None;
          state.code_history_open <- false;
          state.code_history_scroll <- 0;
          state.code_diff <- None;
          state.code_diff_error <- None;
          state.code_diff_open <- false;
          state.code_diff_scroll <- 0;
          state.code_notes <- None;
          state.code_notes_error <- None;
          state.code_notes_open <- false;
          state.code_notes_scroll <- 0;
          state.code_blame <- None;
          state.code_blame_error <- None
      | Error detail -> state.code_file_error <- Some detail)
  | Code_blame_loaded (path, result) ->
      (* Stamped by path like the notes below: an answer that arrives after
         the operator moved on describes bytes that are no longer on screen,
         and a margin naming the wrong authors is worse than no margin. *)
      let still_current =
        match state.code_file with
        | Some (open_path, _) -> String.equal open_path path
        | None -> false
      in
      if still_current then (
        match result with
        | Ok blocks ->
            state.code_blame <- Some (path, blocks);
            state.code_blame_error <- None
        | Error detail ->
            state.code_blame <- None;
            state.code_blame_error <- Some detail)
  | Code_notes_loaded (path, result) ->
      let still_current =
        match state.code_file with
        | Some (open_path, _) -> String.equal open_path path
        | None -> false
      in
      if still_current then (
        match result with
        | Ok notes ->
            state.code_notes <- Some (path, notes);
            state.code_notes_error <- None;
            state.code_notes_scroll <- 0
        | Error detail -> state.code_notes_error <- Some detail)
  | Code_note_written (path, result) -> (
      match result with
      | Ok () ->
          add_event state "system" ("note added to " ^ path);
          (* Re-read rather than splice: the server owns ids and order. *)
          let still_current =
            match state.code_file with
            | Some (open_path, _) -> String.equal open_path path
            | None -> false
          in
          if still_current then (
            match code_scope_codebase state with
            | Ok codebase ->
                state.code_notes <- None;
                state.code_notes_error <- None;
                launch_code_notes_load state ~mailbox ~codebase ~path
            | Error _ -> ())
      | Error detail -> state.code_notes_error <- Some detail)
  | Code_lsp_answered (question, symbol, result) ->
      (match result with
       | Error detail ->
           state.code_lsp_note <- Some (symbol ^ ": " ^ detail)
       | Ok (Masc.Tui_decode.Lsp_hover text) ->
           state.code_lsp_note <-
             Some
               (match text with
                | Some t ->
                    symbol ^ ": " ^ Masc.Tui_decode.sanitize_terminal_text t
                | None -> symbol ^ ": the server has nothing to say here")
       | Ok (Masc.Tui_decode.Lsp_locations []) ->
           state.code_lsp_note <-
             Some (Printf.sprintf "no %s found for %S" question symbol)
       | Ok (Masc.Tui_decode.Lsp_locations (location :: _)) ->
           let open Masc.Tui_decode in
           if location.ll_inside then begin
             (* Jump there: same file just moves the cursor, another file
                opens with the line as its target. Either way the place the
                jump left from goes on the back stack first. *)
             push_code_jump state;
             state.code_lsp_note <-
               Some
                 (Printf.sprintf "%s: %s:%d" symbol location.ll_path
                    location.ll_line);
             match state.code_file with
             | Some (open_path, rows)
               when String.equal open_path location.ll_path ->
                 let cursor =
                   max 0
                     (min (location.ll_line - 1) (List.length rows - 1))
                 in
                 state.code_file_cursor <- cursor;
                 (* Follow the jump: a definition past the fold is a cursor
                    the operator cannot see otherwise. *)
                 state.code_file_scroll <-
                   Masc_tui_scroll.ensure_visible ~cursor
                     ~height:(Masc_tui_render.code_pane_content_height state)
                     state.code_file_scroll
             | Some _ | None ->
                 state.code_target_line <- Some location.ll_line;
                 launch_code_file_load state ~mailbox
                   ~path:location.ll_path
           end
           else
             (* Outside the workspace (stdlib, a package): say where rather
                than open a path the surface cannot serve. *)
             state.code_lsp_note <-
               Some
                 (Printf.sprintf "%s: outside the workspace at %s:%d" symbol
                    location.ll_path location.ll_line))
  | Code_diff_loaded (path, result) ->
      (* Keyed to the file still open, as the history is. *)
      let still_current =
        match state.code_file with
        | Some (open_path, _) -> String.equal open_path path
        | None -> false
      in
      if still_current then (
        match result with
        | Ok diff ->
            state.code_diff <- Some (path, diff);
            state.code_diff_error <- None;
            state.code_diff_scroll <- 0
        | Error detail -> state.code_diff_error <- Some detail)
  | Code_history_loaded (scope, path, result) ->
      (* Keyed to the scope and file still open: two repositories can carry
         the same relative path, so path alone would let a slow old response
         put the wrong Keeper activity under the new file. *)
      let still_current =
        state.code_scope = scope
        && match state.code_file with
        | Some (open_path, _) -> String.equal open_path path
        | None -> false
      in
      if still_current then (
        match result with
        | Ok rows ->
            state.code_history <- Some (path, rows);
            state.code_history_error <- None;
            state.code_history_scroll <- 0
        | Error detail -> state.code_history_error <- Some detail)
  | Resources_listed result -> (
      match result with
      | Ok rows ->
          let rows =
            List.map
              (fun (resource : Masc_tui_mcp.resource) ->
                { resource with
                  uri = Masc.Tui_decode.sanitize_terminal_text resource.uri
                ; name = Masc.Tui_decode.sanitize_terminal_text resource.name
                ; title =
                    Option.map Masc.Tui_decode.sanitize_terminal_text
                      resource.title
                ; description =
                    Option.map Masc.Tui_decode.sanitize_terminal_text
                      resource.description
                ; mime_type =
                    Option.map Masc.Tui_decode.sanitize_terminal_text
                      resource.mime_type
                })
              rows
          in
          state.resources_list <- Some rows;
          state.resources_error <- None;
          let open_uri =
            match state.resource_pending_uri, state.resource_content_error,
                  state.resource_content with
            | Some uri, _, _ -> Some uri
            | None, Some (uri, _), _ -> Some uri
            | None, None, Some (uri, _) -> Some uri
            | None, None, None -> None
          in
          let rec index_of_uri index uri = function
            | [] -> None
            | (resource : Masc_tui_mcp.resource) :: rest ->
                if String.equal resource.uri uri then Some index
                else index_of_uri (index + 1) uri rest
          in
          (match Option.bind open_uri (fun uri -> index_of_uri 0 uri rows) with
           | Some cursor -> state.resources_cursor <- cursor
           | None ->
               state.resources_cursor <-
                 max 0 (min state.resources_cursor (List.length rows - 1));
               if Option.is_some open_uri then begin
                 state.resource_pending_uri <- None;
                 state.resource_content <- None;
                 state.resource_content_error <- None;
                 state.resource_scroll <- 0
               end)
      | Error detail -> state.resources_error <- Some detail)
  | Resource_read (uri, result) -> (
      match state.resource_pending_uri with
      | Some pending_uri when String.equal pending_uri uri ->
          state.resource_pending_uri <- None;
          (match result with
           | Ok contents ->
               let sanitize_document text =
                 String.split_on_char '\n' text
                 |> List.map Masc.Tui_decode.sanitize_terminal_text
                 |> String.concat "\n"
               in
               let contents =
                 List.map
                   (fun (content : Masc_tui_mcp.resource_content) ->
                     { Masc_tui_mcp.rc_uri =
                         Option.map Masc.Tui_decode.sanitize_terminal_text
                           content.rc_uri
                     ; rc_mime_type =
                         Option.map Masc.Tui_decode.sanitize_terminal_text
                           content.rc_mime_type
                     ; rc_kind =
                         (match content.rc_kind with
                          | Masc_tui_mcp.Resource_text text ->
                              Masc_tui_mcp.Resource_text (sanitize_document text)
                          | Masc_tui_mcp.Resource_blob _ as blob -> blob)
                     })
                   contents
               in
               state.resource_content <- Some (uri, contents);
               state.resource_content_error <- None;
               state.resource_scroll <- 0
           | Error detail ->
               state.resource_content_error <- Some (uri, detail))
      | Some _ | None -> ())
  | Github_identity_view_loaded (keeper_name, result) -> (
      let still_selected =
        match List.nth_opt state.keepers state.keeper_cursor with
        | Some keeper -> String.equal keeper.k_name keeper_name
        | None -> false
      in
      if still_selected then
        match result with
        | Ok lines ->
            state.github_identity_view <- Some (keeper_name, lines);
            state.github_identity_view_error <- None
        | Error detail -> state.github_identity_view_error <- Some detail)
  | Identity_switch_set (keeper_name, provider_id, enabled, result) ->
      (match result with
       | Ok () ->
           add_event state "system"
             (Printf.sprintf "%s: %s switched %s" keeper_name provider_id
                (if enabled then "on" else "off"));
           (* Re-read rather than patch what is on screen: the switch the
              server just wrote is the answer. *)
           launch_identity_view state ~mailbox keeper_name
       | Error detail ->
           state.identity_attempt_error <-
             Some
               ( Masc_tui_types.Notice_bad
               , Printf.sprintf "switch %s: %s" provider_id detail ))
  | Identity_providers_loaded (keeper_name, result) -> (
      let still_selected =
        match List.nth_opt state.keepers state.keeper_cursor with
        | Some keeper -> String.equal keeper.k_name keeper_name
        | None -> false
      in
      if still_selected then
        match result with
        | Ok providers ->
            state.identity_view <- Some (keeper_name, providers);
            state.identity_view_error <- None;
            (* The login this TUI started has landed once the service it was
               for reports tools. Clearing it is what stops the tick from
               asking again -- a poll with no end condition is a poll that
               runs for the life of the process. *)
            (match state.identity_login with
             | Some login
               when Masc_tui_types.identity_login_landed ~providers ~login ->
                 state.identity_login <- None
             | Some _ | None -> ())
        | Error detail -> state.identity_view_error <- Some detail)
  | Identity_login_started (keeper_name, result) -> (
      match result with
      | Ok (provider, label, url) ->
          state.identity_login <-
            Some
              { ils_keeper = keeper_name
              ; ils_provider = provider
              ; ils_label = label
              ; ils_url = url
              };
          state.identity_attempt_error <- None
      (* Shown on the tab rather than swallowed: the operator pressed a key
         and has to learn that nothing is going to open. Beside the list
         rather than instead of it -- one provider refusing is not a reason
         to take the others off the screen, and the message that matters
         most here is the one telling them what to do about it. *)
      | Error detail -> state.identity_attempt_error <- Some (Masc_tui_types.Notice_bad, detail))
  | Identity_app_saved (provider_id, result) ->
    state.identity_attempt_error <-
      Some
        (match result with
         | Ok 0 ->
           ( Masc_tui_types.Notice_ok
           , Printf.sprintf
               "%s: app recorded. No scopes given, so the service's own list \
                is what will be asked for."
               provider_id )
         | Ok count ->
           ( Masc_tui_types.Notice_ok
           , Printf.sprintf "%s: app recorded, asking for %d scope%s."
               provider_id count (if count = 1 then "" else "s") )
         | Error detail ->
           (Masc_tui_types.Notice_bad, Printf.sprintf "%s: %s" provider_id detail))
  | Identity_refreshed (keeper_name, result) -> (
      match result with
      (* Re-read rather than patch what is on screen: the catalog the server
         just wrote is the answer, and building a second copy of it here is
         how the two come to disagree. *)
      | Ok () ->
          state.identity_view <- None;
          state.identity_view_error <- None;
          launch_identity_view state ~mailbox keeper_name
      | Error detail -> state.identity_view_error <- Some detail)
  | Github_login_lines (keeper_name, lines) ->
      (* Append under the stamped view; a login for another keeper than the
         one on screen still lands on its own stamp. *)
      let existing =
        match state.github_identity_view with
        | Some (stamp, lines_before) when String.equal stamp keeper_name ->
            lines_before
        | Some _ | None -> [ "# github login" ]
      in
      state.github_identity_view <- Some (keeper_name, existing @ lines);
      state.github_identity_view_error <- None
  | Github_login_finished (keeper_name, result) -> (
      (match result with
       | Ok () -> add_event state "system" (keeper_name ^ ": github login stream ended")
       | Error detail ->
           add_event state "error" (keeper_name ^ ": github login: " ^ detail));
      launch_github_identity_view state ~mailbox keeper_name)
  | System_logs_loaded result -> apply_system_logs_load state result
  | Schedules_loaded result -> (
      match result with
      | Ok snapshot ->
          state.schedules <- Some snapshot;
          state.schedules_error <- None;
          (* The cursor can outlive a list whose rows changed underneath it;
             clamping to the new tail keeps the cancel key pointing at a row
             that exists. *)
          let count = List.length snapshot.scs_rows in
          if state.schedule_cursor >= count then
            state.schedule_cursor <- max 0 (count - 1);
          (match state.schedule_detail_id with
           | Some schedule_id
             when not
                    (List.exists
                       (fun row -> String.equal row.sch_schedule_id schedule_id)
                       snapshot.scs_rows) ->
               state.schedule_detail_id <- None;
               state.schedule_scroll <- 0
           | Some _ | None -> ())
      | Error err -> state.schedules_error <- Some err)
  | Schedule_wake_history_loaded (schedule_id, result) ->
      (* A history that arrived for a row the reader has left is not this
         pane's answer; dropping it is what keeps one schedule's attempts from
         being read as another's. *)
      if
        Option.equal String.equal state.schedule_detail_id (Some schedule_id)
      then begin
        (match state.schedule_wake_history_inflight with
         | Some inflight when String.equal inflight schedule_id ->
             state.schedule_wake_history_inflight <- None
         | Some _ | None -> ());
        match result with
        | Ok history ->
            state.schedule_wake_history <- Some history;
            state.schedule_wake_history_error <- None
        | Error err ->
            state.schedule_wake_history <- None;
            state.schedule_wake_history_error <- Some (schedule_id, err)
      end
      else if
        Option.equal String.equal state.schedule_wake_history_inflight
          (Some schedule_id)
      then state.schedule_wake_history_inflight <- None
  | Keeper_schedules_loaded (keeper_name, result) ->
      (match state.keeper_schedules_inflight with
       | Some inflight when String.equal inflight keeper_name ->
           state.keeper_schedules_inflight <- None
       | Some _ | None -> ());
      (* A page that arrived for a keeper the cursor has left is not this tab's
         answer; filing it would show one Keeper's schedules under another's
         name. *)
      (match result with
       | Ok snapshot ->
           state.keeper_schedules <- Some (keeper_name, snapshot);
           state.keeper_schedules_error <- None
       | Error err ->
           state.keeper_schedules <- None;
           state.keeper_schedules_error <- Some (keeper_name, err))
  | Schedule_cancel_done result -> (
      match result with
      | Ok message ->
          state.schedule_cancel_armed <- None;
          state.schedule_cancel_error <- None;
          add_event state "system" ("Schedule: " ^ message);
          (* The row shown still carries the old status until this lands; a
             cancelled row that reads "scheduled" invites a second cancel. *)
          launch_schedules_load state ~mailbox
      | Error err ->
          state.schedule_cancel_armed <- None;
          state.schedule_cancel_error <- Some err)
  | Verification_verdict_done result -> (
      match result with
      | Ok (message, noop) ->
          state.verification_verdict_armed <- None;
          state.verification_verdict_error <- None;
          add_event state "system"
            (if noop then
               Printf.sprintf "Verification: %s (already recorded)" message
             else "Verification: " ^ message);
          (* The row shown still says awaiting until this lands; a judged row
             that stays listed invites a second verdict. *)
          launch_verification_load state ~mailbox
      | Error err ->
          state.verification_verdict_armed <- None;
          state.verification_verdict_error <- Some err)
  | Harness_label_done result -> (
      match result with
      | Ok message -> add_event state "system" ("Harness: " ^ message)
      | Error err -> add_event state "error" ("Harness label: " ^ err))
  | Approval_decision_done (approval, decision, result, approvals) ->
      apply_approval_decision_completion state approvals.ao_generation approval
        decision result approvals.ao_result
  | Ask_answer_done (answered_label, result, asks) ->
      apply_ask_answer_completion state answered_label result asks
  | Keeper_chat_dispatch_started (request, was_replay, acknowledge) ->
      let proceed = ref false in
      Fun.protect
        ~finally:(fun () -> Eio.Promise.resolve acknowledge !proceed)
        (fun () ->
          match
            inflight_entry_by_request_id state request.Keeper_chat.request_id
          with
          | Some entry
            when Keeper_chat.same_request_identity entry.sent_request request ->
              append_user_history_once ~submitted_at:entry.submitted_at state
                request;
              consume_dispatched_message_draft state request;
              add_event state "message"
                (Printf.sprintf "%s Keeper request: %s"
                   (if was_replay then "Replaying exact" else "Dispatching")
                   request.request_id);
              if
                Option.exists
                  (String.equal request.Keeper_chat.keeper_name)
                  state.msg_target_keeper_name
              then state.msg_live <- Some entry.live;
              proceed := true
          | Some _ | None -> ())
  | Keeper_chat_done (request, _was_replay, result, acknowledge) ->
      let terminal =
        match result with
        | Ok _ -> true
        | Error error ->
            Keeper_chat.error_certainty ~was_unverified:false error
            <> Keeper_chat.Outcome_unverified
      in
      if terminal then settle_live_turn state request;
      let applied =
        Fun.protect
          ~finally:(fun () -> Eio.Promise.resolve acknowledge ())
          (fun () ->
            apply_keeper_chat_result state request result)
      in
      if applied then begin
        (* A terminal operation has persisted the user row, reply and tool
           calls. Only this boundary may replace the live projection or hand
           the Keeper slot to NEXT. *)
        if
          Option.exists
            (String.equal request.Keeper_chat.keeper_name)
            state.msg_target_keeper_name
        then begin
          launch_keeper_history_load ~load_file_changes:false state ~mailbox
            ~keeper_name:request.Keeper_chat.keeper_name;
          if state.view = Keepers Keeper_message then
            launch_keeper_chat_tool_details_load ~force:true state ~mailbox
              ~keeper_name:request.Keeper_chat.keeper_name
        end;
        load_local_workspace_if_safe state base_path;
        drain_queued_message state ~base_path ~mailbox
      end
  | Keeper_chat_stream_deltas (request, deltas) ->
      (* Each Keeper can stream independently. Looking up the request keeps a
         background turn from replacing the selected Keeper's transcript and
         keeps its tool rows available when that turn settles. *)
      (match
         inflight_entry_by_request_id state request.Keeper_chat.request_id
       with
       | Some entry
         when Keeper_chat.same_request_identity entry.sent_request request ->
           entry.phase <- Turn_streaming;
           let now = Unix.gettimeofday () in
           List.iter (Keeper_chat_transcript.apply ~now entry.live) deltas
       | Some _ | None -> ())
  | Keeper_chat_stream_unavailable (request, detail) ->
      (match
         inflight_entry_by_request_id state request.Keeper_chat.request_id
       with
       | Some entry
         when Keeper_chat.same_request_identity entry.sent_request request ->
           entry.phase <- Turn_reconciling
       | Some _ | None -> ());
      append_chat_history state request Message_status detail
  | Keeper_chat_approval_answered (request, tool_call_id, allow, result) ->
      (* The operator answered a question that named a tool; echoing the call
         id back tells them nothing they can act on and nothing they can
         match to what they read. The live transcript still holds the call, so
         the answer is said in the same words the question used. *)
      let call_label =
        let by_id =
          match state.msg_live with
          | None -> None
          | Some live ->
            Keeper_chat_transcript.tool_calls live
            |> List.find_opt (fun (activity : Keeper_chat_transcript.tool_activity) ->
                 Option.equal String.equal activity.call_id (Some tool_call_id))
            |> Option.map (fun (activity : Keeper_chat_transcript.tool_activity) ->
                 activity.tool_name)
        in
        match by_id with
        | Some name when String.trim name <> "" -> Keeper_chat.terminal_safe_text name
        | Some _ | None -> Keeper_chat.compact_request_id tool_call_id
      in
      let text =
        match result with
        | Ok { Masc_tui_http.settled = true; _ } ->
            Printf.sprintf "%s %s" (if allow then "allowed" else "denied") call_label
        | Ok { Masc_tui_http.settled = false; remembered = true } ->
            (* The wait was gone, but the server kept the answer for the
               identical retried call -- said so plainly, or an operator reads
               "too late" as their decision having been thrown away. *)
            Printf.sprintf
              "too late for %s, but the answer is remembered -- the next \
               identical call is %s without asking"
              call_label
              (if allow then "allowed" else "denied")
        | Ok { Masc_tui_http.settled = false; remembered = false } ->
            (* The wait was gone and nothing this keeper asked matches: it
               was answered already, or never held. Said plainly rather than
               shown as taken, so an operator is not told a call was allowed
               when nothing was listening. *)
            Printf.sprintf "too late for %s; the call was no longer waiting"
              call_label
        | Error detail -> "could not answer the held call: " ^ detail
      in
      append_chat_history state request
        (match result with
         | Ok { Masc_tui_http.settled = true; _ }
         | Ok { Masc_tui_http.remembered = true; _ } ->
             Message_status
         | _ -> Message_error)
        text
  | Keeper_tool_approvals_loaded result ->
      (match result with
       | Ok held ->
           state.keeper_tool_approvals <- held;
           state.keeper_tool_approvals_error <- None;
           let count = List.length (approval_items state) in
           if state.approval_cursor >= count then
             state.approval_cursor <- max 0 (count - 1)
       | Error detail -> state.keeper_tool_approvals_error <- Some detail)
  | Keeper_turns_loaded result ->
      (match result with
       | Ok rows ->
           (* Two consecutive polls are what "just finished" is made of:
              running in the previous, idle in this one. The glow list is
              advanced before the rows are replaced, or the transition is
              gone. *)
           state.keeper_turn_finishes <-
             Masc_tui_answering.advance_finishes
               ~now:(Unix.gettimeofday ())
               ~previous_rows:state.keeper_turns ~current_rows:rows
               state.keeper_turn_finishes;
           state.keeper_turns <- rows;
           state.keeper_turns_error <- None
       | Error detail ->
           (* Keep the last known rows: a fetch that failed says nothing
              about the turns themselves, and blanking every badge on one
              lost poll would flicker. The error shows on the keeper list. *)
           state.keeper_turns_error <- Some detail)
  | Gate_snapshot_loaded result ->
      (match result with
       | Ok snapshot ->
           state.gate_pending <- snapshot.Tui_decode.gs_pending;
           state.gate_modes <- snapshot.Tui_decode.gs_modes;
           state.gate_queue_unavailable <- snapshot.Tui_decode.gs_queue_unavailable;
           state.gate_rules <- snapshot.Tui_decode.gs_rules;
           state.gate_rules_unavailable <- snapshot.Tui_decode.gs_rules_unavailable;
           state.gate_error <- None;
           let count = List.length (approval_items state) in
           if state.approval_cursor >= count then
             state.approval_cursor <- max 0 (count - 1)
       | Error detail -> state.gate_error <- Some detail)
  | Gate_approval_resolved (approval_id, approve, result, generation) ->
      (* Release the single-action slot [launch_gate_resolve] took, whatever the
         outcome, so the header stops drawing [submitting] and the next decision
         is admitted. [begin_action] serialises decisions, so this completion
         owns its slot; the durable server result applies either way. *)
      let flow, _owns_action =
        Approval.Flow.finish_action state.approval_flow generation
      in
      state.approval_flow <- flow;
      (match result with
       | Ok () ->
           add_event state "system"
             (Printf.sprintf "Gate %s %s"
                (if approve then "approved" else "rejected")
                approval_id);
           (* Durably resolved on the server; the row leaves now rather than
              waiting out the next refresh, and the refresh confirms. *)
           state.gate_pending <-
             List.filter
               (fun (pending : Tui_decode.gate_pending) ->
                 not (String.equal pending.Tui_decode.gp_id approval_id))
               state.gate_pending;
           let count = List.length (approval_items state) in
           if state.approval_cursor >= count then
             state.approval_cursor <- max 0 (count - 1);
           launch_gate_snapshot_load state ~mailbox
       | Error detail ->
           add_event state "error"
             (Printf.sprintf "Gate decision for %s failed: %s" approval_id
                detail))
  | Gate_auto_judge_retried (approval_id, result, generation) ->
      let flow, _owns_action =
        Approval.Flow.finish_action state.approval_flow generation
      in
      state.approval_flow <- flow;
      (match result with
       | Ok () ->
           add_event state "system"
             (Printf.sprintf "Auto Judge retry started for %s" approval_id);
           launch_gate_snapshot_load state ~mailbox
       | Error detail ->
           add_event state "error"
             (Printf.sprintf "Auto Judge retry for %s failed: %s" approval_id
                detail))
  | Gate_external_mode_set (mode, result) ->
      (match result with
       | Ok () ->
           add_event state "system"
             (Printf.sprintf "External-services Gate lane set to %s" mode);
           launch_gate_snapshot_load state ~mailbox
       | Error detail ->
           add_event state "error"
             (Printf.sprintf "External-services Gate lane change failed: %s"
                detail))
  | Keeper_gate_settings_loaded result ->
      (match result with
       | Ok (modes, judges) ->
           state.keeper_gate_modes <- modes;
           state.keeper_gate_judges <- judges
       | Error _ ->
           (* Keep the last known settings rather than showing every Keeper as
              following the workspace, which is the looser reading and the one
              an operator would act on. *)
           ())
  | Keeper_tool_modes_loaded (result, generation) ->
      (* A listing from an older flow describes the stance before the press
         that superseded it. Dropping it is what keeps an armed gate armed
         on screen. *)
      if Approval.Flow.is_current state.approval_flow generation then
        (match result with
         | Ok overrides ->
             state.keeper_yolo_names <-
               List.filter_map
                 (fun (keeper, mode) ->
                   if String.equal mode "yolo" then Some keeper else None)
                 overrides
         | Error _ ->
             (* The stance listing is advisory colouring; a failed fetch keeps
                the last known set rather than flashing every name back. *)
             ())
  | Keeper_tool_mode_set (keeper_name, mode, result, generation) ->
      let flow, owned = Approval.Flow.finish_action state.approval_flow generation in
      state.approval_flow <- flow;
      if not owned then ()
      else
      (match result with
       | Ok () ->
           state.keeper_yolo_names <-
             (let without =
                List.filter
                  (fun name -> not (String.equal name keeper_name))
                  state.keeper_yolo_names
              in
              if String.equal mode "yolo" then keeper_name :: without
              else without);
           add_event state "system"
             (if String.equal mode "yolo" then
                Printf.sprintf
                  "%s runs every tool call unasked (YOLO) until restart or g"
                  keeper_name
              else
                Printf.sprintf "%s is back on the approval policy (auto)"
                  keeper_name)
       | Error detail ->
           add_event state "error"
             (Printf.sprintf "could not set %s's gate: %s" keeper_name detail))
  | Surface_tool_approval_answered
      (keeper_name, tool_call_id, allow, result, generation) ->
      (* Release the single-action slot [launch_surface_tool_approval] took, so
         the header clears [submitting] and the next decision is admitted. *)
      let flow, _owns_action =
        Approval.Flow.finish_action state.approval_flow generation
      in
      state.approval_flow <- flow;
      (* The listing is stale the moment an answer lands, so the settled call
         leaves the local list at once rather than waiting for a refresh. *)
      state.keeper_tool_approvals <-
        List.filter
          (fun (held : Tui_decode.keeper_tool_approval) ->
            not (String.equal held.kta_tool_call_id tool_call_id))
          state.keeper_tool_approvals;
      let count = List.length (approval_items state) in
      if state.approval_cursor >= count then
        state.approval_cursor <- max 0 (count - 1);
      add_event state
        (match result with
         | Ok { Masc_tui_http.settled = true; _ }
         | Ok { Masc_tui_http.remembered = true; _ } ->
             "system"
         | _ -> "error")
        (match result with
         | Ok { Masc_tui_http.settled = true; _ } ->
             Printf.sprintf "%s %s's held call %s"
               (if allow then "allowed" else "denied")
               keeper_name
               (Keeper_chat.compact_request_id tool_call_id)
         | Ok { Masc_tui_http.settled = false; remembered = true } ->
             Printf.sprintf
               "too late for %s's call %s, but the answer is remembered -- \
                the next identical call is %s without asking"
               keeper_name
               (Keeper_chat.compact_request_id tool_call_id)
               (if allow then "allowed" else "denied")
         | Ok { Masc_tui_http.settled = false; remembered = false } ->
             Printf.sprintf
               "too late for %s's call %s; it was no longer waiting"
               keeper_name
               (Keeper_chat.compact_request_id tool_call_id)
         | Error detail -> "could not answer the held call: " ^ detail)
  | Keeper_chat_interrupt_done (request, result) ->
      (match
         inflight_entry_by_request_id state request.Keeper_chat.request_id
       with
       | Some entry
         when Keeper_chat.same_request_identity entry.sent_request request ->
           let live = entry.live in
           let noted =
             match result with
             | Ok (Masc_tui_interrupt_signal.Signalled { turn_id }) ->
                 Keeper_chat_transcript.Signal_sent
                   { turn_id; signalled_at_ns = Mtime_clock.elapsed_ns () }
             | Ok (Masc_tui_interrupt_signal.Not_signalled { reason; detail }) ->
                 Keeper_chat_transcript.Signal_declined
                   (match detail with
                    | None -> reason
                    | Some detail -> reason ^ ": " ^ detail)
             | Error detail -> Keeper_chat_transcript.Signal_error detail
           in
           Keeper_chat_transcript.note_interrupt live noted
       | Some _ | None ->
           (* The turn settled before the answer came back. Nothing to mark,
              and the outcome the transcript already recorded is the one that
              counts. *)
           ())
  | Keeper_chat_dispatch_blocked (request, detail) ->
      (* The POST never left. Nothing durable was written for it, so there is
         nothing to reconcile: say what happened and let the operator send
         again if they want to. *)
      settle_live_turn state request;
      (match inflight_by_request_id state request.Keeper_chat.request_id with
       | Some current when Keeper_chat.same_request_identity current request ->
           drop_inflight state request;
           add_event state "error"
             (Printf.sprintf "Keeper request %s was not dispatched: %s"
                request.request_id detail)
       | Some _ | None -> ())
  | Context_inspector_loaded (generation, keeper_name, reading) ->
      if
        generation = state.context_inspector_generation
        && Option.exists (String.equal keeper_name)
             state.context_inspector_keeper
      then begin
        state.context_inspector_loading <- false;
        state.context_inspector_reading <- Some (keeper_name, reading)
      end
  | Keeper_chat_history_loaded
      (generation, keeper_name, history_result, memory_result) ->
      (* The operator can switch while a previous GET is still in flight. The
         pane owns one loaded-history cache, so a late response for the old
         target or an older request for a target revisited since must not
         replace the transcript now being read. *)
      if
        generation = state.msg_history_load_generation
        && Option.exists (String.equal keeper_name)
             state.msg_target_keeper_name
      then
        let prior_loaded =
          match state.msg_loaded_keeper with
          | Some loaded_keeper when String.equal loaded_keeper keeper_name ->
              state.msg_loaded
          | Some _ | None -> []
        in
        let prior_history, prior_memory =
          List.partition
            (fun entry -> entry.me_role <> Message_memory)
            prior_loaded
        in
        let history_entries =
          match history_result with
          | Ok { Keeper_chat_history.rows; dropped } ->
             state.msg_loaded_error <- None;
             state.msg_loaded_dropped <- dropped;
             let fresh = msg_entries_of_history_rows state keeper_name rows in
             let kept = merge_paged_history ~paged:prior_history ~fresh in
             let cursor = oldest_at kept in
             (* Where reading further back starts: the oldest row now held. A
                refresh that reaches no further back than before has learned
                nothing new about what is behind it, so a "nothing older"
                answer already given is kept rather than asked again on every
                tick. *)
             if state.msg_older_cursor <> cursor then
               state.msg_older_exist <- Option.is_some cursor;
             state.msg_older_cursor <- cursor;
             state.msg_older_error <- None;
             forget_session_rows_the_transcript_holds state keeper_name rows;
             kept
          | Error detail ->
             (* The transcript is left as it was and the session rows stay: a
                failed load must not be the reason the pane goes blank. *)
             state.msg_loaded_error <- Some detail;
             prior_history
        in
        let memory_entries =
          match memory_result with
          | Ok { Keeper_chat_history.rows; dropped } ->
              state.msg_memory_error <- None;
              state.msg_memory_dropped <- dropped;
              msg_entries_of_history_rows state keeper_name rows
          | Error detail ->
              state.msg_memory_error <- Some detail;
              prior_memory
        in
        state.msg_loaded <- history_entries @ memory_entries;
        state.msg_loaded_keeper <- Some keeper_name
  | Tools_loaded result -> (
      match result with
      | Ok snapshot ->
          state.tools_inventory <- Some snapshot;
          state.tools_error <- None;
          normalize_tools_skill_cursor state
      | Error detail -> state.tools_error <- Some detail)
  | Skills_catalog_loaded result -> (
      match result with
      | Ok catalog ->
          state.skills_catalog <- Some catalog;
          state.skills_catalog_error <- None
      | Error detail -> state.skills_catalog_error <- Some detail)
  | Tools_async_observation_loaded result -> (
      match result with
      | Ok observation ->
          state.tools_async_observation <- Some observation;
          state.tools_async_observation_error <- None
      | Error detail -> state.tools_async_observation_error <- Some detail)
  | Runtime_lane_slots_written result ->
      (match result with
       | Ok () ->
           (* The lane order now differs from what this surface drew, and the
              server is the one that just changed it. Re-read rather than
              patching the local snapshot: a hand-applied edit and a rejected
              write look the same on screen. *)
           state.runtime_lane_error <- None;
           state.runtime_lane_pick <- None;
           state.runtime_lane_pick_cursor <- 0;
           launch_runtime_surface_load state ~mailbox ~force:true
       | Error detail -> state.runtime_lane_error <- Some detail)
  | Runtime_catalog_loaded result -> (
      match result with
      | Ok (runtimes, assignments) ->
          state.runtime_catalog <- runtimes;
          state.runtime_assignments <- assignments;
          state.runtime_catalog_error <- None;
          let dispatchable =
            List.length
              (List.filter
                 (fun (o : Tui_decode.runtime_option) -> o.ro_dispatchable)
                 runtimes)
          in
          if state.runtime_pick_cursor >= dispatchable then
            state.runtime_pick_cursor <- max 0 (dispatchable - 1)
      | Error detail -> state.runtime_catalog_error <- Some detail)
  | Runtime_assignment_set (keeper_name, runtime_id, result) -> (
      match result with
      | Ok write ->
          let summary =
            match write with
            | Masc_tui_http.Runtime_assignment_committed receipt ->
              Masc_tui_http.runtime_config_commit_receipt_summary receipt
            | Masc_tui_http.Runtime_assignment_unchanged -> "unchanged"
          in
          add_event state "system"
            ((match runtime_id with
              | Some id -> Printf.sprintf "%s now runs on %s" keeper_name id
              | None ->
                  Printf.sprintf "%s is back on the default runtime" keeper_name)
             ^ " · "
             ^ summary);
          (* The assignment table just changed under the picker; re-read it
             rather than patching a local copy the server may disagree with. *)
          launch_runtime_catalog_load state ~mailbox
      | Error detail ->
          add_event state "error"
            (Printf.sprintf "could not point %s at a runtime: %s" keeper_name
               detail))
  | Connectors_loaded result -> (
      match result with
      | Ok snapshot ->
          let previous_id =
            Option.bind state.connectors (fun previous ->
                Option.map
                  (fun (connector : Tui_decode.connector) -> connector.cn_id)
                  (List.nth_opt previous.cs_connectors state.connectors_cursor))
          in
          state.connectors <- Some snapshot;
          state.connectors_error <- None;
          state.connectors_cursor <-
            (match previous_id with
             | None -> 0
             | Some id ->
                 let rec find index = function
                   | [] -> 0
                   | (connector : Tui_decode.connector) :: rest ->
                       if String.equal connector.cn_id id then index
                       else find (index + 1) rest
                 in
                 find 0 snapshot.cs_connectors);
          state.connectors_binding_cursor <- 0;
          state.connector_unbind_armed <- None
      | Error detail -> state.connectors_error <- Some detail)
  | Runtime_surface_loaded (generation, result) ->
      let is_current = generation = state.runtime_surface_generation in
      (match state.runtime_surface_inflight with
       | Some inflight when inflight = generation ->
           state.runtime_surface_inflight <- None
       | Some _ | None -> ());
      if is_current then
        (match result with
         | Ok load ->
             let previous_probe =
               Option.bind state.runtime_surface (fun snapshot ->
                   snapshot.Tui_decode.rss_probe)
             in
             let probe, probe_error =
               match load.Masc_tui_loader.rsl_probe with
               | Ok current -> Some current, None
               | Error detail -> previous_probe, Some detail
             in
             (match
                Tui_decode.join_runtime_surface ~probe ~probe_error
                  ~resolved:load.rsl_resolved
              with
              | Ok snapshot ->
                  state.runtime_surface <- Some snapshot;
                  state.runtime_surface_error <- probe_error
              | Error detail -> state.runtime_surface_error <- Some detail)
         | Error detail ->
             (* The last joined reading remains visible. An authority read or
                decode failure is not an empty lane inventory. *)
             state.runtime_surface_error <- Some detail);
      if is_current && state.runtime_surface_force_pending then begin
        state.runtime_surface_force_pending <- false;
        launch_runtime_surface_load state ~mailbox ~force:true
      end
  | Repositories_loaded result -> (
      match result with
      | Ok snapshot ->
          state.repositories <- Some snapshot;
          state.repositories_error <- None
      | Error detail -> state.repositories_error <- Some detail)
  | Memory_loaded result -> (
      match result with
      | Ok snapshot ->
          state.memory_health <- Some snapshot;
          state.memory_health_error <- None
      | Error detail -> state.memory_health_error <- Some detail)
  | Memory_facts_loaded (keeper_name, result) ->
      (* Only the keeper the browser is still open on: a late answer for a
         browser that closed, or for the keeper the reader already left,
         is dropped whole. *)
      if
        Option.equal String.equal state.memory_facts_keeper (Some keeper_name)
      then (
        match result with
        | Ok snapshot ->
            state.memory_facts <- Some snapshot;
            state.memory_facts_error <- None
        | Error detail -> state.memory_facts_error <- Some detail)
  | Repository_changes_loaded (scope, result) ->
      if
        state.repository_changes_open
        && Option.equal repository_change_scope_equal
             state.repository_changes_scope (Some scope)
      then
        (match result with
         | Ok snapshot when repository_change_scope_equal snapshot.rcs_scope scope ->
             state.repository_changes <- Some snapshot;
             state.repository_changes_error <- None
         | Ok _ ->
             state.repository_changes_error <-
               Some "Git changes response belongs to a different workspace"
         | Error detail -> state.repository_changes_error <- Some detail)
  | Keeper_chat_file_changes_loaded (generation, keeper_name, result) ->
      let still_current =
        generation = state.msg_file_changes_generation
        && Option.equal String.equal state.msg_file_changes_keeper
             (Some keeper_name)
        && Option.equal String.equal state.msg_target_keeper_name
             (Some keeper_name)
      in
      if still_current then begin
        let refresh_pending = state.msg_file_changes_refresh_pending in
        state.msg_file_changes_loading <- false;
        state.msg_file_changes_refresh_pending <- false;
        let store_error detail =
          state.msg_file_changes_error <- Some detail;
          add_event state "error" ("chat recorded changes unavailable: " ^ detail)
        in
        (match result with
         | Ok snapshot
           when String.equal snapshot.Masc.Tui_decode.fcs_keeper keeper_name ->
             state.msg_file_changes <- Some snapshot;
             state.msg_file_change_index <-
               Masc_tui_keeper_chat_diff.index
                 snapshot.Masc.Tui_decode.fcs_changes;
             state.msg_file_changes_error <- None
         | Ok snapshot ->
             store_error
               (Printf.sprintf
                  "file-change response named keeper %s, expected %s"
                  snapshot.Masc.Tui_decode.fcs_keeper keeper_name)
        | Error detail -> store_error detail);
        if refresh_pending && state.view = Keepers Keeper_message then
          launch_keeper_chat_file_changes_load ~force:true state ~mailbox
            ~keeper_name
      end
  | File_changes_loaded (keeper_name, result) ->
      (* An answer for a keeper the surface has since left is not this
         surface's answer. Dropping it keeps one keeper's files from being
         drawn under another's name. *)
      if Option.equal String.equal state.changes_keeper (Some keeper_name) then (
        match result with
        | Ok snapshot ->
            state.changes <- Some snapshot;
            state.changes_error <- None;
            state.changes_cursor <- 0;
            state.changes_scroll <- 0;
            (* The open row indexes the snapshot it was opened against. A new
               snapshot can hold a different change at the same index, so the
               diff closes rather than silently changing what it shows. *)
            state.changes_diff_row <- None;
            state.changes_diff_scroll <- 0;
            state.changes_tree_diff <- None;
            state.changes_tree_diff_error <- None;
            state.changes_tree_diff_path <- None
        | Error detail -> state.changes_error <- Some detail)
  | Git_diff_loaded (path, result) ->
      (* An answer for a file the view has since left is not this view's
         answer, and drawing it would put one file's diff under another's
         name. *)
      if Option.equal String.equal state.changes_tree_diff_path (Some path) then (
        match result with
        | Ok diff ->
            state.changes_tree_diff <- Some diff;
            state.changes_tree_diff_error <- None
        | Error detail -> state.changes_tree_diff_error <- Some detail)
  | Lanes_loaded result -> (
      match result with
      | Ok (snapshot, secrets) ->
          state.lanes <- Some snapshot;
          state.keeper_secrets <- secrets;
          state.lanes_error <- None
      | Error detail ->
          (* Keep the previous rows visible. The error says that they are
             stale; clearing them would turn a failed refresh into an empty
             reading. *)
          state.lanes_error <- Some detail)
  | Standalone_lanes_loaded (generation, result) ->
      if generation = state.standalone_lanes_generation then (
        match result with
        | Ok snapshot ->
            state.standalone_lanes <- Some snapshot;
            state.standalone_lanes_error <- None;
            (* A refresh may shrink the matrix; the cursor has to stay a valid
               row of the snapshot now in state. The matrix rows never scroll,
               so there is no window to follow. *)
            state.lanes_standalone_cursor <-
              max 0
                (min state.lanes_standalone_cursor
                   (List.length snapshot.Tui_decode.sls_lanes - 1))
        | Error detail -> state.standalone_lanes_error <- Some detail)
  | Clients_loaded (generation, result) ->
      if generation = state.clients_surface_generation then (
        match result with
        | Ok snapshot ->
            state.clients_surface <- Some snapshot;
            state.clients_surface_error <- None;
            (* A refresh may shrink the roster; the cursor has to stay a
               valid row of the snapshot now in state. *)
            state.clients_surface_cursor <-
              max
                0
                (min state.clients_surface_cursor
                   (List.length snapshot.Masc.Tui_decode.cls_clients - 1))
        | Error detail -> state.clients_surface_error <- Some detail)
  | Lane_runs_loaded (lane_id, result) ->
      (match state.lanes_mode with
       | Lanes_run_list open_lane when String.equal open_lane lane_id ->
           (match result with
            | Ok runs ->
                state.lane_runs <- Some runs;
                state.lane_runs_error <- None;
                state.lane_runs_cursor <-
                  max 0 (min state.lane_runs_cursor (List.length runs - 1))
            | Error detail ->
                (* Keep the previous rows visible; the error says they are
                   stale, clearing them would turn a failed refresh into an
                   empty reading. *)
                state.lane_runs_error <- Some detail)
       | Lanes_run_list _ | Lanes_overview | Lanes_run_detail _ -> ())
  | Lane_run_detail_loaded (run_id, result) ->
      (match state.lanes_mode with
       | Lanes_run_detail (_, open_run) when String.equal open_run run_id ->
           (match result with
            | Ok detail ->
                state.lane_run_detail <- Some detail;
                state.lane_run_detail_error <- None
            | Error detail -> state.lane_run_detail_error <- Some detail)
       | Lanes_run_detail _ | Lanes_overview | Lanes_run_list _ -> ())
  | Harness_loaded result -> (
      match result with
      | Ok snapshot ->
          state.harness <- Some snapshot;
          state.harness_error <- None;
          (match state.harness_detail with
           | None -> ()
           | Some (task_id, at) ->
               if not
                    (List.exists
                       (fun verdict ->
                          String.equal verdict.Masc.Tui_decode.hv_task_id task_id
                          && Float.equal verdict.hv_at at)
                       snapshot.Masc.Tui_decode.hs_verdicts)
               then begin
                 state.harness_detail <- None;
                 state.harness_detail_scroll <- 0
               end)
      | Error detail -> state.harness_error <- Some detail)
  | Fusion_runs_loaded (generation, result) ->
      (match state.fusion_runs_inflight with
       | Some inflight when inflight = generation ->
           state.fusion_runs_inflight <- None
       | Some _ | None -> ());
      if generation = state.fusion_runs_generation then
        apply_fusion_runs_load state result
  | Fusion_detail_loaded (generation, run_id, result) ->
      (match state.fusion_detail_inflight with
       | Some (inflight_generation, inflight_run_id)
         when inflight_generation = generation
              && String.equal inflight_run_id run_id ->
           state.fusion_detail_inflight <- None
       | Some _ | None -> ());
      apply_fusion_detail_load state generation run_id result
  | Verification_loaded result -> (
      match result with
      | Ok snapshot ->
          state.verification <- Some snapshot;
          state.verification_error <- None;
          let requests = snapshot.Masc.Tui_decode.vs_requests in
          let count = List.length requests in
          if state.verification_cursor >= count then
            state.verification_cursor <- max 0 (count - 1);
          (match state.verification_detail_request_id with
           | Some request_id
             when not
                    (List.exists
                       (fun row ->
                          String.equal row.Masc.Tui_decode.vr_request_id
                            request_id)
                       requests) ->
               state.verification_detail_request_id <- None;
               state.verification_detail_scroll <- 0
           | Some _ | None -> ())
      | Error detail ->
          (* The previous list stays: a failed reload must not make the queue
             look empty, which reads as "nothing is waiting". *)
          state.verification_error <- Some detail)
  | Keeper_chat_older_loaded (generation, keeper_name, before, result) ->
      (* A page that arrived for a keeper the pane has since left, or after a
         reload moved the cursor, is dropped: prepending it would put rows
         above a transcript they do not belong to. *)
      let still_current =
        generation = state.msg_history_load_generation
        && (match state.msg_loaded_keeper with
            | Some loaded -> String.equal loaded keeper_name
            | None -> false)
        && state.msg_older_cursor = Some before
      in
      if still_current then (
        state.msg_older_loading <- false;
        match result with
        | Ok page ->
            let rows =
              msg_entries_of_history_rows state keeper_name
                page.Keeper_chat_history.decoded.Keeper_chat_history.rows
            in
            (* The paging cursor owns the raw storage window, so an older page
               is prepended here. [chat_timeline] then recomputes the one
               displayed-time projection across that complete window; scroll
               pins retain row identity rather than this cache position. *)
            state.msg_loaded <- rows @ state.msg_loaded;
            state.msg_loaded_dropped <-
              state.msg_loaded_dropped
              + page.Keeper_chat_history.decoded.Keeper_chat_history.dropped;
            state.msg_older_cursor <- page.Keeper_chat_history.next_before;
            (* A page with no cursor cannot be paged past even if the server
               says more exist, so both have to hold for the pane to offer
               another. *)
            state.msg_older_exist <-
              page.Keeper_chat_history.has_more
              && Option.is_some page.Keeper_chat_history.next_before;
            state.msg_older_error <- None
        | Error detail ->
            (* The cursor is kept so the same page can be asked for again;
               what is on screen is untouched. *)
            state.msg_older_error <- Some detail)
let drain_async_messages state ~base_path ~http_refresh_inflight
    ~http_scoped_refresh_inflight ~scoped_refresh_followup mailbox =
  let rec loop changed =
    match Eio.Stream.take_nonblocking mailbox with
    | None -> changed
    | Some msg ->
        apply_async_message state ~base_path ~http_refresh_inflight
          ~http_scoped_refresh_inflight ~scoped_refresh_followup ~mailbox msg;
        loop true
  in
  loop false

let invalidate_frame_for_resize frame_presenter render_schedule =
  invalidate_terminal_size ();
  Frame_presenter.invalidate frame_presenter;
  Render_schedule.request render_schedule Render_schedule.Force

let request_console_write_repair render_schedule =
  Terminal_write_repair.request_repaint render_schedule

let copy_reference_to_terminal render_schedule reference =
  Terminal_write_repair.note ();
  write_to_terminal (Link.osc52_copy reference);
  request_console_write_repair render_schedule

(* One enable/disable pair for SGR mouse reports. Without tracking the
   terminal keeps the wheel for its own scrollback -- which scrolls past the
   TUI's frame on a non-alternate screen -- or turns it into arrow keys only
   if configured to. With it, wheel reports arrive here and read_input maps
   them to the same keys the arrows make. *)
let mouse_tracking_enable = "\x1b[?1006;1000h"
let mouse_tracking_disable = "\x1b[?1006;1000l"

(* Tracking is what the wheel costs the terminal: with reports on, a drag is a
   report and the terminal never highlights anything, so there is no way to
   copy a line off the screen. Ctrl-T hands the mouse back and takes it again.
   A letter would not do -- in the composer every letter is text. *)
let mouse_tracking_on = Atomic.make true
let toggle_mouse_tracking_key = "\020"

(* Ctrl-B, as an editor toggles its side bar. The roster beside a keeper chat
   costs 30 of the terminal's columns, and a reader who knows which keeper
   they are talking to wants them back. A letter would not do -- in the
   composer every letter is text. *)
let toggle_roster_pane_key = "\002"

let terminal_title_visible_keeper state =
  match state.view with
  | Code -> None
  | Keepers Keeper_message -> state.msg_target_keeper_name
  | Keepers
      (Keeper_list | Keeper_detail | Keeper_logs | Keeper_calls
      | Keeper_runtime_pick) ->
      Option.map
        (fun (keeper : keeper) -> keeper.k_name)
        (selected_keeper state)
  | Overview | Acting | Memory | Lanes | Clients | Board | Approvals
  | Planning | Schedules
  | Verification | Harness | Fusion | Repositories | Changes | Connectors
  | Runtime | Config | Resources | Tools | System_logs -> None
;;

let terminal_title_runtime state keeper_name =
  (* Option.bind takes the option first, so it cannot sit after [|>] the way
     Option.map does -- piping handed it the continuation in the option's
     slot and the build stopped compiling. *)
  Option.bind keeper_name (fun name ->
    Option.bind
      (List.find_opt
         (fun (keeper : keeper) -> String.equal keeper.k_name name)
         state.keepers)
      (fun keeper ->
        match (keeper_reading state keeper).Keeper_control.liveness with
        | Keeper_control.Present runtime -> Some runtime.kr_runtime_id
        | Keeper_control.Absent | Keeper_control.Unobserved -> None))
;;

let terminal_title_snapshot state =
  let live =
    Option.map Keeper_chat_transcript.keeper_name state.msg_live
  in
  let inflight =
    List.map
      (fun entry -> entry.sent_request.keeper_name)
      state.msg_inflight
  in
  let keeper_name =
    Terminal_title.select_keeper
      ~live
      ~inflight
      ~visible:(terminal_title_visible_keeper state)
  in
  let activity =
    match live, inflight with
    | Some _, _ | None, _ :: _ -> Terminal_title.Working
    | None, [] -> Terminal_title.Connection state.connection_status
  in
  Terminal_title.make
    ~activity
    ~keeper_name
    ~runtime_id:(terminal_title_runtime state keeper_name)
    ~workspace:state.workspace
;;

let toggle_mouse_tracking () =
  let on = not (Atomic.get mouse_tracking_on) in
  Atomic.set mouse_tracking_on on;
  output_string stdout (if on then mouse_tracking_enable else mouse_tracking_disable);
  flush stdout

(* One enable/disable pair for bracketed paste. Without it the terminal
   delivers a paste as the keys it looks like, so every newline in it is
   Return: a three-line paste is three messages, a pasted Markdown block
   arrives as three sends, and the operator gets a queue full of fragments
   instead of the thing they copied. With it the payload comes wrapped in
   ESC[200~ and ESC[201~ and the text arrives as text.

   Written and cleared beside the mouse mode, for the reasons its comment
   gives about when a byte may be put on this stream. *)
(* How long to wait for the combined palette and graphics answers. A terminal
   replies as soon as it has parsed a supported query; an unsupported query
   says nothing, and this is the whole cost of finding that out, paid once at
   startup. *)
let terminal_probe_wait_seconds = 0.2

let read_terminal_probe reader ~palette_requested =
  Eio_guard.run_in_systhread (fun () ->
      let decoder =
        Masc_tui_terminal_probe.create ~palette_requested
      in
      let timeout_ns =
        Int64.of_float
          (terminal_probe_wait_seconds *. nanoseconds_per_second)
      in
      let deadline_ns = Int64.add (Mtime_clock.elapsed_ns ()) timeout_ns in
      let bytes_read = ref 0 in
      let finished = ref false in
      while
        (not !finished)
        && !bytes_read < Masc_tui_terminal_probe.max_bytes
        && not (Masc_tui_terminal_probe.complete decoder)
      do
        let remaining_ns =
          Int64.sub deadline_ns (Mtime_clock.elapsed_ns ())
        in
        if Int64.compare remaining_ns 0L <= 0 then finished := true
        else
          match
            take_terminal_buffer_byte reader
              ~timeout:(Int64.to_float remaining_ns /. nanoseconds_per_second)
          with
          | None -> finished := true
          | Some byte ->
            incr bytes_read;
            Masc_tui_terminal_probe.feed decoder byte
      done;
      decoder, Masc_tui_terminal_probe.snapshot decoder)
;;

let bracketed_paste_enable = "\x1b[?2004h"
let bracketed_paste_disable = "\x1b[?2004l"

(* Raw mode, and the one key the record cannot ask for.

   [Unix.tcsetattr] writes a C-side termios buffer that its last [tcgetattr]
   filled, and overwrites only the fields [Unix.terminal_io] names. c_cc is not
   among them, so every call puts back the literal-next key (VLNEXT, Ctrl-V)
   that the tty layer uses to swallow the next byte -- and Ctrl-V is the paste
   key. Pairing the two here is what keeps the three places that take raw mode
   back (session start, the return from Ctrl-Z, the return from $EDITOR) from
   taking it back without the key.

   The result is not checked because there is nothing left for it to report:
   the [tcsetattr] on the line above just succeeded on this descriptor, so it
   is a terminal this process can set. What remains is a hangup between the two
   calls, and that ends the session either way. *)
let apply_raw_mode new_term =
  Unix.tcsetattr Unix.stdin Unix.TCSANOW new_term;
  (* See above: a refusal is a hangup, which ends the session either way. *)
  ignore (Masc_tui_termios.disable_literal_next Unix.stdin : bool)
;;

let enter_terminal_session ~cleanup ~terminate ~request_interrupt
    ~request_full_repaint ~suspend ~new_term =
  at_exit cleanup;
  (* After [cleanup] registers, so the summary is written once the terminal is
     back and cannot land in the middle of a restored screen. *)
  at_exit Masc_tui_frame_timing.report;
  (* SIGINT is the only one of these a person sends by hand mid-sentence, so
     it asks the loop rather than ending the process. The rest still mean the
     session is over. *)
  Sys.set_signal Sys.sigint (Sys.Signal_handle request_interrupt);
  Sys.set_signal Sys.sigterm (Sys.Signal_handle terminate);
  Sys.set_signal Sys.sighup (Sys.Signal_handle terminate);
  Sys.set_signal Sys.sigquit (Sys.Signal_handle terminate);
  Sys.set_signal Sys.sigwinch (Sys.Signal_handle request_full_repaint);
  Sys.set_signal Sys.sigcont (Sys.Signal_handle request_full_repaint);
  Sys.set_signal Sys.sigtstp (Sys.Signal_handle suspend);
  apply_raw_mode new_term

(** Main loop *)
let main () =
  (* The provider layer reports through [Llm_provider.Diag], whose default sink
     writes to stderr -- which here is the terminal this draws on. One INFO line
     about the embedded model catalog lands between two frames and the screen is
     no longer what the frame presenter believes it wrote. The server routes
     these into the structured log at boot; this surface has the same terminal
     to protect, so it routes them the same way and before anything can ask the
     catalog a question. *)
  Provider_diag_log_sink.install ();
  let ( base_path_input
      , base_path
      , workspace
      , port
      , refresh
      , reasoning_visibility
      , tool_visibility ) =
    parse_args ()
  in
  (* Publish the path selected by this process before any workspace-backed
     store opens. Otherwise inherited path variables can make the screen read
     local Keeper metadata from a different workspace than its server. *)
  Unix.putenv Env_config_core.base_path_input_env_key base_path_input;
  Unix.putenv Env_config_core.base_path_env_key base_path;
  Workspace_utils_backend_setup.cache_resolved_base_path base_path;
  require_interactive_terminal ();
  (* stderr is this terminal -- [lsof] on a running surface shows fd 1 and fd 2
     on the same [/dev/ttys*]. Everything that writes there writes into the
     drawn screen: the console mirror behind every [Log] record, this binary's
     own decode reports ([Masc_tui_loader.report]), and anything a library
     prints without asking. Raising the level to Warn narrowed that to fewer
     lines; it did not stop them, and it bought the narrowing by dropping Info
     records from the ring the System logs surface reads.

     So the terminal is taken away from stderr instead. The console is a
     mirror by its own contract -- {!Console_sink} names the file sink and the
     ring authoritative -- and a mirror pointed at a file is still a mirror,
     while one pointed here is a corruption. This runs after
     [require_interactive_terminal] so its refusal still reaches a person, and
     before anything can log. *)
  redirect_stderr_off_terminal ~base_path;
  Log.init_from_env ();
  let state =
    create_state ~reasoning_visibility ~tool_visibility ~workspace
      ~local_base_path:base_path ~port
      ~refresh_interval:refresh ()
  in
  state.view <- Overview;

  (* A theme named in runtime.toml's [tui] section is applied at boot, so the
     reader's pick survives a restart instead of being re-chosen each session.
     Absent or unknown, the TUI follows the terminal exactly as before:
     Theme_choice.apply returns false for a name no scheme carries, and the
     [when] guard then leaves theme_choice unset. *)
  (match Masc_tui_config.theme ~base_path with
   | Some name when Masc_tui_theme_choice.apply name ->
       state.theme_choice <- Some name
   | Some _ | None -> ());

  (* Same file, same moment. Absent reads as on, which is what masc drew
     before the key existed -- a reader who never set it sees no change. *)
  Masc_tui_theme.set_lift_enabled
    (Option.value (Masc_tui_config.lift_colours ~base_path) ~default:true);

  (* Same file, same moment: the box a table draws is a look, and a look that
     survives a restart is the point of storing it. *)
  set_table_frame
    (Option.value (Masc_tui_config.table_frame ~base_path) ~default:false);

  (* Same file, same moment. Absent reads as on -- the hints predate the
     key, and a reader who never set it sees no change. *)
  state.hints_visible <-
    Option.value (Masc_tui_config.hints_visible ~base_path) ~default:true;
  state.coalesce_queued_input <-
    Option.value
      (Masc_tui_config.coalesce_queued_input ~base_path)
      ~default:true;

  (* Setup terminal *)
  let old_term = Unix.tcgetattr Unix.stdin in
  (* Read beside [old_term] because the record cannot carry it. The literal-next
     character is turned off for as long as this program owns the terminal
     ([apply_raw_mode]) and handed back whenever the terminal is -- at exit and
     around Ctrl-Z. Restoring [old_term] alone leaves the shell without the
     key, which the PTY harness catches as a terminal this program did not put
     back the way it found it. *)
  let old_literal_next = Masc_tui_termios.literal_next Unix.stdin in
  (* c_icrnl off so Return and Ctrl-J arrive as themselves. With the terminal's
     default translation on, Return is delivered as LF -- the same byte Ctrl-J
     sends -- and the composer cannot tell "send this" from "start a new line".
     LF still submits below if some terminal sends it for Return, so this only
     ever adds a key. *)
  let new_term =
    { old_term with Unix.c_icanon = false; c_echo = false; c_icrnl = false }
  in

  let terminal_profile = Terminal_profile.detect ~getenv:Sys.getenv_opt in
  let frame_presenter =
    Frame_presenter.create
      ~synchronized_output:
        (Terminal_profile.synchronized_output terminal_profile)
      ()
  in
  (* An approval effect belongs to the row the terminal last accepted, not to
     the mutable list that an async refresh may install before the next key.
     This is committed only after [Frame_presenter.present] reports output. *)
  let presented_approval = ref None in
  let terminal_title = Terminal_title.create () in
  let resize_requested = Atomic.make false in

  let restore_terminal () =
    (* No tracking-off here: suspend runs this too, and a terminal that
       re-enters raw mode after Ctrl-Z would silently lose the wheel. The
       off byte is written once, in [cleanup], at real process exit. *)
    Frame_presenter.cleanup frame_presenter ~write:(output_string stdout)
      ~flush:(fun () -> flush stdout);
    if Terminal_profile.dynamic_title terminal_profile then
      Terminal_title.clear terminal_title ~write:(output_string stdout)
        ~flush:(fun () -> flush stdout);
    Unix.tcsetattr Unix.stdin Unix.TCSANOW old_term;
    (* After the record, not before: [tcsetattr] is what puts the rest of the
       terminal back, and this character is the part it cannot reach.
       [-1] means the descriptor was never a terminal, so there is nothing to
       return. *)
    if old_literal_next >= 0
    then
      (* See the guard above: a refusal here is the terminal already gone. *)
      ignore (Masc_tui_termios.set_literal_next Unix.stdin old_literal_next : bool)
  in

  (* Cleanup on exit *)
  let cleanup_started = Atomic.make false in
  let cleanup () =
    if Atomic.compare_and_set cleanup_started false true then begin
      Console_sink.set_after_write_observer None;
      restore_terminal ();
      print_endline "Goodbye!";
      (* Tracking off after Goodbye: a terminal left in report mode keeps
         swallowing the wheel after this process is gone, and the farewell
         line is the last thing a reader matches on -- a byte after it cannot
         disturb that read. *)
      output_string stdout mouse_tracking_disable;
      output_string stdout bracketed_paste_disable;
      (* The mode belongs to this program's screen. A shell that inherited it
         would see its own keys reported in a form it does not read. *)
      if Terminal_profile.kitty_keyboard terminal_profile then
        output_string stdout Masc_tui_csi.disable_kitty_keyboard;
      flush stdout
    end
  in

  let request_full_repaint _ = Atomic.set resize_requested true in
  let terminate _ = exit 0 in
  (* Ctrl-C used to reach [terminate] and the session ended mid-sentence, with
     whatever was in the composer gone. It is one key away from Ctrl-V and
     Ctrl-X on the same hand, and the footer never listed it, so the first
     time an operator meets this binding is the time they lose a draft.

     It cannot simply become a key: turning off ISIG would take Ctrl-Z with
     it, and suspend is wired to a handler that gives the terminal back. So
     the signal stays a signal and the loop decides what it means — the first
     one says what a second one will do, and any other key withdraws it. *)
  let interrupt_requested = Atomic.make false in
  let interrupt_armed = Atomic.make false in
  let request_interrupt _ = Atomic.set interrupt_requested true in
  let rec suspend _ =
    restore_terminal ();
    Sys.set_signal Sys.sigtstp Sys.Signal_default;
    Fun.protect
      ~finally:(fun () ->
        Sys.set_signal Sys.sigtstp (Sys.Signal_handle suspend);
        apply_raw_mode new_term;
        (* restore_terminal above gave the alternate screen back so the shell
           was usable while stopped. Take it again before the repaint, or the
           frame lands on top of whatever the user did meanwhile. *)
        Frame_presenter.setup frame_presenter ~write:(output_string stdout)
          ~flush:(fun () -> flush stdout);
        request_full_repaint 0)
      (fun () -> Unix.kill (Unix.getpid ()) Sys.sigtstp)
  in
  enter_terminal_session ~cleanup ~terminate ~request_interrupt
    ~request_full_repaint ~suspend
    ~new_term;
  let render_schedule =
    Render_schedule.create ~min_interval_ns:frame_interval_ns ()
  in
  if Terminal_write_repair.console_sink_writes_to_terminal () then
    Console_sink.set_after_write_observer
      (Some (fun () -> Terminal_write_repair.note ()));

  (* Written here rather than at session entry, inside enter_terminal_session:
     a byte written the moment raw mode is taken races the handshake reads a
     harness (or terminal) performs on the very first output, and the PTY
     regression's quit scenario reliably loses that race. Between session
     entry and the first frame the stream is quiet, and the enable is not
     urgent anyway -- the first wheel event always arrives after the first
     frame. *)
  (* Before the first frame and after session entry, so the at_exit cleanup
     that gives this back is already installed. *)
  Frame_presenter.setup frame_presenter ~write:(output_string stdout)
    ~flush:(fun () -> flush stdout);
  (* Reads the palette rather than taking a colour, so every caller sends
     whatever is in force at the moment it asks -- picking a scheme, dropping
     one, and the first paint all go through the same answer. *)
  let sync_theme_page () =
    Frame_presenter.sync_page ~write:(output_string stdout)
      ~flush:(fun () -> flush stdout)
      (Option.map
         (fun palette ->
           { Frame_presenter.foreground =
               Masc_tui_terminal_palette.foreground palette
           ; background = Masc_tui_terminal_palette.background palette
           })
         (Masc_tui_terminal_palette.current ()))
  in
  (* The pick, written to the runtime.toml boot reads it back from. Only a
     commit comes here: a preview is a look at a scheme, not a choice of one,
     and storing every row the cursor passes would make Esc a lie.

     A failure is said out loud. The scheme is already on the screen by the
     time this runs, so silence would let the screen stand as proof it was
     kept, and the reader would find the old one back after a restart with
     nothing having told them. *)
  let store_theme_choice choice =
    match Masc_tui_config.set_theme ~base_path choice with
    | Ok () -> ()
    | Error message ->
        add_event state "error"
          (Printf.sprintf
             "테마를 runtime.toml 에 저장하지 못했습니다. 이번 세션에만 적용됩니다: %s"
             message)
  in
  (* Live preview, the way a theme picker is expected to work: moving the
     cursor draws in that scheme so the reader judges it on the screen they
     actually use, Enter keeps it, Esc puts back whatever was in force before
     they walked in.

     The scheme in force is remembered on the first preview rather than on
     entering the pane: entering and leaving without moving should cost
     nothing, and there is no "they might" to record. *)
  let preview_theme_under_cursor () =
    if state.theme_before_preview = None
    then state.theme_before_preview <- Some state.theme_choice;
    match List.nth_opt (Masc_tui_theme_choice.entries ()) state.theme_cursor with
    | None -> ()
    | Some entry ->
      if Masc_tui_theme_choice.apply entry.Masc_tui_theme_choice.name
      then begin
        state.theme_choice <- Some entry.Masc_tui_theme_choice.name;
        sync_theme_page ()
      end
  in
  (* Esc, and leaving the pane. Restoring goes through the same two calls a
     pick does, so a preview cannot leave the screen and the background
     disagreeing. *)
  let cancel_theme_preview () =
    match state.theme_before_preview with
    | None -> ()
    | Some previous ->
      state.theme_before_preview <- None;
      (match previous with
       | Some name -> ignore (Masc_tui_theme_choice.apply name : bool)
       | None -> Masc_tui_theme_choice.follow_terminal ());
      state.theme_choice <- previous;
      sync_theme_page ()
  in
  (* Shadowed on purpose: every surface change in this loop goes through here,
     and a preview must not survive one. Wrapping is what keeps the three call
     sites from each having to remember. *)
  let goto_surface state ~mailbox destination =
    (match state.view with
     | Config when state.config_pane = Config_themes && destination <> Config ->
       cancel_theme_preview ()
     | _ -> ());
    goto_surface state ~mailbox destination
  in

  (* A scheme named in runtime.toml was applied at boot, before this existed.
     Sending it here is what makes a saved choice survive a restart with its
     background rather than only its ink. *)
  sync_theme_page ();
  output_string stdout mouse_tracking_enable;
  output_string stdout bracketed_paste_enable;
  (* Only terminals with an extended profile receive this opt-in. Apple
     Terminal does not implement the protocol; keeping an unsupported control
     sequence off its parser also keeps its crash-sensitive render path small. *)
  if Terminal_profile.kitty_keyboard terminal_profile then
    output_string stdout Masc_tui_csi.enable_kitty_keyboard;
  flush stdout;

  (* Initial load *)
  (* Local workspace state is loaded only after /health proves that this TUI
     and the server resolve the same canonical base path. *)
  let host = server_peer_host in
  let port = state.port in
  let http_refresh_inflight = ref false in
  let http_scoped_refresh_inflight = ref false in
  let scoped_refresh_followup = ref No_scoped_followup in
  let async_messages = Eio.Stream.create 32 in
  let presented_surface_reference () =
    match state.view with
    | Approvals -> Option.bind !presented_approval approval_row_reference
    | Overview | Acting | Keepers _ | Lanes | Clients | Board | Planning
    | Schedules
    | Memory | Verification | Harness | Fusion | Repositories | Changes | Connectors
    | Runtime | Config | Resources | Code | Tools | System_logs ->
        selected_surface_reference state
  in
  (* Shared by every $EDITOR round-trip below (gate rejection here, the
     Keeper-settings flows further down): re-arm raw mode and repaint after
     the child editor exits. Defined before its first use — the gate
     rejection flow landed above the Keeper-settings section that
     originally carried this definition. *)
  let reenter_terminal () =
    apply_raw_mode new_term;
    request_full_repaint 0
  in
  let reject_gate_approval (pending : Tui_decode.gate_pending) =
    match Masc_tui_editor.editor_command () with
    | None ->
      add_event state "error"
        "no $EDITOR set; export EDITOR to reject this Gate approval"
    | Some _ -> (
      let stem = "{\n  \"reason\": \"\"\n}\n" in
      match
        Masc_tui_editor.roundtrip ~restore:restore_terminal
          ~reenter:reenter_terminal stem
      with
      | Error abort -> report_editor_abort state ~action:"Gate rejection" abort
      | Ok body -> (
        match Yojson.Safe.from_string body with
        | exception Yojson.Json_error error ->
          add_event state "error"
            ("Gate rejection: body is not JSON: " ^ error)
        | `Assoc fields -> (
          match List.assoc_opt "reason" fields with
          | Some (`String reason) when String.trim reason <> "" ->
            launch_gate_resolve state ~mailbox:async_messages
              ~approval_id:pending.gp_id ~approve:false
              ~reason:(Some (String.trim reason))
          | Some (`String _) | Some _ | None ->
            add_event state "system" "Gate rejection cancelled (empty reason)" )
        | _ ->
          add_event state "error" "Gate rejection: body must be a JSON object"))
  in
  let answer_presented_approval decision =
    match
      Approval_authority.resolve ~presented:!presented_approval
        ~current:(approval_items state) decision
    with
    | Some { Approval_authority.row = Operator_row approval; decision } ->
        handle_approval_decision state approval decision
          ~mailbox:async_messages
    | Some { Approval_authority.row = Keeper_tool_row held; decision } ->
        launch_surface_tool_approval state ~mailbox:async_messages
          ~keeper_name:held.kta_keeper
          ~tool_call_id:held.kta_tool_call_id
          ~allow:(match decision with Confirm -> true | Deny -> false)
    | Some { Approval_authority.row = Gate_row pending; decision = Confirm } ->
        launch_gate_resolve state ~mailbox:async_messages
          ~approval_id:pending.Tui_decode.gp_id ~approve:true ~reason:None
    | Some { Approval_authority.row = Gate_row pending; decision = Deny } ->
        reject_gate_approval pending
    | None ->
        add_event state "system"
          "Approval list changed; review the updated row before deciding"
  in
  let commit_presented_approval approval =
    presented_approval := approval
  in
  let present_frame frame approval =
    let damaged = Terminal_write_repair.consume_damage () in
    let authority_changed =
      Approval_authority.authority_changed
        ~presented:!presented_approval ~candidate:approval
    in
    (* A selected row's hidden token/call id can change while its clipped
       terminal text stays byte-identical. Only that authority transition
       forces a full presentation; ordinary async row updates stay
       differential. *)
    match
      Frame_presenter.present frame_presenter
        ~invalidate_before:(damaged || authority_changed)
        ~write:(output_string stdout)
        ~flush:(fun () -> flush stdout) frame
    with
    | Frame_presenter.Presented -> commit_presented_approval approval
    | Frame_presenter.Unchanged -> ()
  in
  (* Bind the bearer to the workspace actually opened, before any request is
     built. Reported before the recovery load as well, so when neither source
     holds one the operator sees the cause ahead of the symptom: a tokenless
     process cannot dispatch, and cannot reconcile a dispatch an authenticated
     predecessor left behind. *)
  (match
     Masc_tui_credential.outcome_notice
       (Masc_tui_http.install_operator_token ~base_path ~host ~port)
   with
   | Some notice -> add_event state "error" notice
   | None -> ());
  start_http_refresh state ~host ~port ~intent:Revalidate
    ~refresh_inflight:http_refresh_inflight
    ~scoped_refresh_inflight:http_scoped_refresh_inflight
    ~scoped_refresh_followup
    ~mailbox:async_messages;
  add_event state "system" "TUI started";

  (* Main loop *)
  let refresh_interval_ns =
    Int64.of_float (max 0.0 refresh *. nanoseconds_per_second)
  in
  let last_check_ns = ref (Mtime_clock.elapsed_ns ()) in
  let roster_marquee_target = ref None in
  let roster_marquee_last_step_ns = ref (Mtime_clock.elapsed_ns ()) in
  let activity_last_step_ns = ref (Mtime_clock.elapsed_ns ()) in
  (* A datum that is fetched only while its surface is open has nothing to draw
     the moment that surface opens, and waiting out the refresh interval would
     read as "there is nothing here". What is watched is the set of data the
     open surface needs rather than the surface itself, so moving between two
     surfaces that read the same things -- a keeper list and a keeper's detail --
     costs no request. Watching from the loop catches every way the surface can
     change, rather than asking each of the places that change it to remember. *)
  let drawn_needs = ref (Masc_tui_types.surface_needs state.view) in
  let input_reader = create_input_reader () in
  (* Palette and graphics share one bounded startup probe because both replies
     arrive on the key stream. The probe removes only replies to these exact
     questions and puts every other consumed byte back into this same reader.
     NO_COLOR omits OSC 10/11; the independent graphics query still runs. *)
  let palette_requested = Masc_tui_theme.colors_enabled in
  write_to_terminal (Masc_tui_terminal_probe.query ~palette:palette_requested);
  let terminal_probe_decoder, terminal_probe =
    read_terminal_probe input_reader ~palette_requested
  in
  (* Do not finish the decoder at the startup deadline. A terminal may have
     split OSC 10/11 across that boundary; the same reader continues this
     exact state before serving its replay or unread terminal-buffer tail. *)
  input_reader.terminal_probe <- Some terminal_probe_decoder;
  Masc_tui_terminal_palette.set_current terminal_probe.palette;
  (match palette_requested, terminal_probe.palette with
   | true, None ->
     install_late_palette_publisher input_reader ~request_full_repaint
   | true, Some _ | false, _ -> ());
  terminal_draws_images :=
    Some
      (match terminal_probe.graphics with
       | Some Masc_tui_graphics.Supported -> true
       | Some (Masc_tui_graphics.Refused _) | None -> false);

  (* ── Keeper settings over $EDITOR (#29684) ─────────────────────
     The editor itself is the confirmation step: an exit other than 0
     leaves the settings untouched, so these flows skip Keeper_control's
     arming gate. The terminal handshake around the child is the pair
     [suspend] already runs around Ctrl-Z. [reenter_terminal] lives above
     the gate-rejection flow, the earliest $EDITOR round-trip. *)
  (* An empty object is the honest starting point for a partial patch: the
     config route applies only the fields present in the body, and the TUI
     has no view of the current settings to prefill from -- showing a
     guessed stem would invite an operator to "keep" a value that is not
     the one on disk. *)
  (* runtime.toml edit: $EDITOR over the text the Config surface shows,
     then the server's preview validation; only a preview that passes is
     written. A failed preview keeps the operator's text out of the file
     and puts the validator's words in Recent Events. *)
  (* Connector bind/unbind: the highlighted transport owns the route. The
     form edits only the route body, so its visible selection and mutation
     target cannot disagree. *)
  let handle_connector_form ?fixed_channel_id ~action ~connector
      ~required_fields ~stem ~post () =
    match Masc_tui_editor.editor_command () with
    | None ->
      report_action state "error"
        ("no $EDITOR set; export EDITOR to " ^ action ^ " here")
    | Some _ -> (
      match
        Masc_tui_editor.roundtrip ~restore:restore_terminal
          ~reenter:reenter_terminal stem
      with
      | Error abort -> report_editor_abort state ~action abort
      | Ok body -> (
        match Yojson.Safe.from_string body with
        | exception Yojson.Json_error e ->
          report_action state "error" (action ^ ": body is not JSON: " ^ e)
        | json -> (
          let field key =
            match json with
            | `Assoc fields -> (
                match List.assoc_opt key fields with
                | Some (`String value) when String.trim value <> "" ->
                    Some (String.trim value)
                | _ -> None)
            | _ -> None
          in
          match List.find_opt (fun key -> Option.is_none (field key)) required_fields with
          | Some key ->
              report_action state "error"
                (Printf.sprintf "%s: %S is required" action key)
          | None -> (
              match fixed_channel_id with
              | Some expected when field "channel_id" <> Some expected ->
                  report_action state "error"
                    (action ^ ": channel_id must remain the selected binding")
              | Some _ | None -> (
                  match post ~connector ~json with
                  | Ok _ ->
                      state.connector_unbind_armed <- None;
                      report_action state "system"
                        (action ^ ": ok (" ^ connector ^ ")");
                      launch_connectors_load state ~mailbox:async_messages
                  | Error detail ->
                      report_action state "error" (action ^ ": " ^ detail))))))
  in
  let selected_connector () =
    Option.bind state.connectors (fun snapshot ->
        List.nth_opt snapshot.cs_connectors state.connectors_cursor)
  in
  let selected_connector_binding (connector : Tui_decode.connector) =
    List.nth_opt connector.cn_bindings state.connectors_binding_cursor
  in
  let handle_connector_bind () =
    state.connector_unbind_armed <- None;
    let host = server_peer_host in
    let port = state.port in
    let keeper_name =
      match state.view, selected_keeper state with
      | Keepers Keeper_detail, Some keeper -> keeper.k_name
      | _, _ -> ""
    in
    match selected_connector () with
    | None -> report_action state "error" "bind: select a transport first"
    | Some selected ->
        handle_connector_form ~action:"bind" ~connector:selected.cn_id
          ~required_fields:[ "channel_id"; "keeper_name" ]
          ~stem:
            (Yojson.Safe.pretty_to_string
               (`Assoc
                 [ "channel_id", `String ""
                 ; "keeper_name", `String keeper_name
                 ])
             ^ "\n")
          ~post:(fun ~connector ~json ->
            Masc_tui_http.post_connector_bind ~host ~port ~connector
              ~body_json:(Yojson.Safe.to_string json))
          ()
  in
  let handle_connector_unbind () =
    let host = server_peer_host in
    let port = state.port in
    match selected_connector () with
    | None -> report_action state "error" "unbind: select a transport first"
    | Some selected ->
        let submit ?fixed_channel_id channel_id =
          handle_connector_form ?fixed_channel_id ~action:"unbind"
            ~connector:selected.cn_id ~required_fields:[ "channel_id" ]
            ~stem:
              (Yojson.Safe.pretty_to_string
                 (`Assoc [ "channel_id", `String channel_id ])
               ^ "\n")
            ~post:(fun ~connector ~json ->
              Masc_tui_http.post_connector_unbind ~host ~port ~connector
                ~body_json:(Yojson.Safe.to_string json))
            ()
        in
        (match state.view with
         | Keepers Keeper_detail ->
             (match selected_connector_binding selected with
              | None ->
                  report_action state "error"
                    "unbind: select a binding with J/K"
              | Some binding ->
                  let exact =
                    selected.cn_id, binding.cb_channel_id, binding.cb_keeper_name
                  in
                  if state.connector_unbind_armed = Some exact then begin
                    state.connector_unbind_armed <- None;
                    match
                      Masc_tui_http.post_connector_unbind ~host ~port
                        ~connector:selected.cn_id
                        ~body_json:
                          (Yojson.Safe.to_string
                             (`Assoc
                               [ "channel_id", `String binding.cb_channel_id
                               ; "keeper_name", `String binding.cb_keeper_name
                               ]))
                    with
                    | Ok _ ->
                      report_action state "system"
                        ("unbind: removed " ^ binding.cb_channel_id);
                      launch_connectors_load state ~mailbox:async_messages
                    | Error detail ->
                      report_action state "error" ("unbind: " ^ detail)
                  end else begin
                    state.connector_unbind_armed <- Some exact;
                    report_action state "system"
                      (Printf.sprintf
                         "unbind armed: press u again to remove %s → %s"
                         binding.cb_channel_id binding.cb_keeper_name)
                  end)
         | _ -> submit "")
  in
  let handle_connector_edit () =
    state.connector_unbind_armed <- None;
    match selected_connector (), selected_keeper state with
    | None, _ -> report_action state "error" "edit: select a transport first"
    | _, None -> report_action state "error" "edit: select a Keeper first"
    | Some connector, Some keeper ->
        (match selected_connector_binding connector with
         | None -> report_action state "error" "edit: select a binding with J/K"
         | Some binding ->
             handle_connector_form ~fixed_channel_id:binding.cb_channel_id
               ~action:"edit binding" ~connector:connector.cn_id
               ~required_fields:[ "channel_id"; "keeper_name" ]
               ~stem:
                 (Yojson.Safe.pretty_to_string
                    (`Assoc
                      [ "channel_id", `String binding.cb_channel_id
                      ; "keeper_name", `String keeper.k_name
                      ])
                  ^ "\n")
               ~post:(fun ~connector ~json ->
                 Masc_tui_http.post_connector_bind ~host:server_peer_host
                   ~port:state.port ~connector
                   ~body_json:(Yojson.Safe.to_string json))
               ())
  in
  (* A new note over the open file: $EDITOR is the form, and the editor is
     the confirmation step -- a non-zero exit or an empty content leaves the
     file unannotated. Reachable only from the notes view, which already
     proved the scope has a codebase slug. *)
  let handle_code_note_write () =
    match state.code_file with
    | None -> ()
    | Some (path, _) -> (
        match code_scope_codebase state with
        | Error why -> report_action state "system" ("notes: " ^ why)
        | Ok codebase -> (
            match Masc_tui_editor.editor_command () with
            | None ->
                report_action state "error"
                  "no $EDITOR set; export EDITOR to add a note here"
            | Some _ -> (
                (* The line the cursor is on, which is the line the operator
                   pressed [w] about. This was the literal 1, and it shows:
                   every one of the 51 annotations this workspace has ever
                   stored anchors at line 1, including the two written from
                   here. Nobody declined to anchor -- the form never offered
                   their line, and correcting it meant editing JSON in
                   $EDITOR before writing a word.

                   [code_file_cursor] is 0-based and is the same anchor a
                   language-server question is asked at, so [w] and [K]/[D]/
                   [R] now agree about which line the operator means. *)
                let stem =
                  Masc_tui_types.code_note_stem
                    ~anchor:(state.code_file_cursor + 1)
                in
                match
                  Masc_tui_editor.roundtrip ~restore:restore_terminal
                    ~reenter:reenter_terminal stem
                with
                | Error abort -> report_editor_abort state ~action:"note" abort
                | Ok body -> (
                    match Yojson.Safe.from_string body with
                    | exception Yojson.Json_error e ->
                        report_action state "error"
                          ("note: body is not JSON: " ^ e)
                    | json ->
                        let field key =
                          match json with
                          | `Assoc fields -> List.assoc_opt key fields
                          | _ -> None
                        in
                        let int_field key =
                          match field key with
                          | Some (`Int n) -> Some n
                          | Some _ | None -> None
                        in
                        let content =
                          match field "content" with
                          | Some (`String s) -> String.trim s
                          | Some _ | None -> ""
                        in
                        let kind =
                          match field "kind" with
                          | Some (`String s) -> String.trim s
                          | Some _ | None -> "Comment"
                        in
                        if String.equal content "" then
                          report_action state "system"
                            "note cancelled (empty content)"
                        else (
                          match
                            (int_field "line_start", int_field "line_end")
                          with
                          | Some line_start, Some line_end ->
                              start_code_note_write state
                                ~mailbox:async_messages ~codebase ~path
                                ~line_start ~line_end ~kind ~content
                          | _ ->
                              report_action state "error"
                                "note: line_start and line_end must be \
                                 integers")))))
  in
  (* The verdict row under the Harness cursor, when the list has one. *)
  let harness_cursor_verdict () =
    Option.bind state.harness (fun snapshot ->
        List.nth_opt snapshot.Masc.Tui_decode.hs_verdicts state.harness_cursor)
  in
  (* Operator label on a harness verdict. [y] records the machine's side as
     the human's; [n] records the opposite side and takes its reason through
     $EDITOR, because the reason is the text the divergence teaches the judge
     as a few-shot example. The machine's side is read off the closed
     verdict serialization ("approve" | "approve:<reason>" | "reject:<reason>"). *)
  let harness_machine_approved (row : Masc.Tui_decode.harness_verdict) =
    match Eval_calibration.verdict_of_string row.Masc.Tui_decode.hv_verdict with
    | Some (Task.Anti_rationalization.Approve _) -> Some true
    | Some (Task.Anti_rationalization.Reject _) -> Some false
    | None -> None
  in
  let start_harness_label ~notes_hash ~(verdict : [ `Approve | `Reject ])
      ~reason ~described =
    let host = server_peer_host in
    let port = state.port in
    let run () =
      let result =
        match
          Masc_tui_http.post_harness_label ~host ~port ~notes_hash ~verdict
            ~reason
        with
        | Error err -> Error err
        | Ok _json -> Ok described
      in
      enqueue_async async_messages (Harness_label_done result)
    in
    match Eio_context.get_switch_opt () with
    | Some sw -> Eio.Fiber.fork ~sw run
    | None -> run ()
  in
  let handle_harness_agree () =
    match harness_cursor_verdict () with
    | None -> ()
    | Some row -> (
        match harness_machine_approved row with
        | None ->
            report_action state "error"
              "cannot label: unrecognized verdict format"
        | Some approved ->
            start_harness_label ~notes_hash:row.Masc.Tui_decode.hv_notes_hash
              ~verdict:(if approved then `Approve else `Reject)
              ~reason:""
              ~described:
                (Printf.sprintf "labelled %s: the %s stands"
                   row.Masc.Tui_decode.hv_task_id
                   (if approved then "approve" else "reject")))
  in
  let handle_harness_overrule () =
    match harness_cursor_verdict () with
    | None -> ()
    | Some row -> (
        match Masc_tui_editor.editor_command () with
        | None ->
            report_action state "error"
              "no $EDITOR set; export EDITOR to overrule here"
        | Some _ -> (
            let stem = "{\n  \"reason\": \"\"\n}\n" in
            match
              Masc_tui_editor.roundtrip ~restore:restore_terminal
                ~reenter:reenter_terminal stem
            with
            | Error abort -> report_editor_abort state ~action:"overrule" abort
            | Ok body -> (
                match Yojson.Safe.from_string body with
                | exception Yojson.Json_error e ->
                    report_action state "error" ("overrule: body is not JSON: " ^ e)
                | json ->
                    let reason =
                      match json with
                      | `Assoc fields -> (
                          match List.assoc_opt "reason" fields with
                          | Some (`String s) -> String.trim s
                          | Some _ | None -> "")
                      | _ -> ""
                    in
                    if String.equal reason "" then
                      report_action state "system"
                        "overrule cancelled (empty reason)"
                    else
                      match harness_machine_approved row with
                      | None ->
                          report_action state "error"
                            "cannot overrule: unrecognized verdict format"
                      | Some approved ->
                          start_harness_label
                            ~notes_hash:row.Masc.Tui_decode.hv_notes_hash
                            ~verdict:(if approved then `Reject else `Approve)
                            ~reason
                            ~described:
                              (Printf.sprintf "overruled %s: %s was wrong"
                                 row.Masc.Tui_decode.hv_task_id
                                 (if approved then "the approve" else "the reject")))))
  in
  (* Verification reject: the reason is required, and $EDITOR is the form we
     already have. The editor is the confirmation step -- a non-zero exit or
     an empty reason leaves the task unjudged, so no arming gate sits in
     front of it the way one sits in front of the single-key approve. *)
  let handle_verification_reject () =
    match verification_cursor_row state with
    | None -> ()
    | Some row -> (
        let task_id = row.Masc.Tui_decode.vr_task_id in
        match Masc_tui_editor.editor_command () with
        | None ->
            report_action state "error"
              "no $EDITOR set; export EDITOR to reject here"
        | Some _ -> (
            let stem = "{\n  \"reason\": \"\"\n}\n" in
            match
              Masc_tui_editor.roundtrip ~restore:restore_terminal
                ~reenter:reenter_terminal stem
            with
            | Error abort -> report_editor_abort state ~action:"reject" abort
            | Ok body -> (
                match Yojson.Safe.from_string body with
                | exception Yojson.Json_error e ->
                    report_action state "error" ("reject: body is not JSON: " ^ e)
                | json ->
                    let reason =
                      match json with
                      | `Assoc fields -> (
                          match List.assoc_opt "reason" fields with
                          | Some (`String s) -> String.trim s
                          | Some _ | None -> "")
                      | _ -> ""
                    in
                    if String.equal reason "" then
                      report_action state "system" "reject cancelled (empty reason)"
                    else
                      start_verification_verdict state
                        ~mailbox:async_messages ~task_id
                        ~verdict:(`Reject reason))))
  in
  (* Task cancel: same form discipline as the verification reject — the
     reason is required, $EDITOR is the form, and a non-zero exit or an
     empty reason leaves the task untouched. The server's FSM decides
     whether the task is still cancellable. *)
  let handle_task_cancel () =
    match state.task_detail_id with
    | None -> ()
    | Some task_id -> (
        match Masc_tui_editor.editor_command () with
        | None ->
            report_action state "error"
              "no $EDITOR set; export EDITOR to cancel here"
        | Some _ -> (
            let stem = "{\n  \"reason\": \"\"\n}\n" in
            match
              Masc_tui_editor.roundtrip ~restore:restore_terminal
                ~reenter:reenter_terminal stem
            with
            | Error abort -> report_editor_abort state ~action:"cancel" abort
            | Ok body -> (
                match Yojson.Safe.from_string body with
                | exception Yojson.Json_error e ->
                    report_action state "error" ("cancel: body is not JSON: " ^ e)
                | json ->
                    let reason =
                      match json with
                      | `Assoc fields -> (
                          match List.assoc_opt "reason" fields with
                          | Some (`String s) -> String.trim s
                          | Some _ | None -> "")
                      | _ -> ""
                    in
                    if String.equal reason "" then
                      report_action state "system" "cancel cancelled (empty reason)"
                    else
                      launch_task_cancel state ~mailbox:async_messages
                        ~task_id ~reason)))
  in
  (* From a table row to the line that declares it. The header the source
     pane needs is [models.NAME], quoted when the name carries a dot -- the
     same two spellings the table parser accepts, kept together here so a
     name that parses cannot fail to be found. *)
  let config_models_source_line ~(row : Masc_tui_model_runtime_table.row) rows =
    let bare = "[models." ^ row.Masc_tui_model_runtime_table.model ^ "]" in
    let quoted = "[models.\"" ^ row.Masc_tui_model_runtime_table.model ^ "\"]" in
    let rec scan i = function
      | [] -> None
      | segments :: rest ->
        let text = String.trim (String.concat "" (List.map fst segments)) in
        if String.equal text bare || String.equal text quoted
        then Some i
        else scan (i + 1) rest
    in
    scan 0 rows
  in
  let handle_config_models_open_source () =
    match List.nth_opt state.config_models_rows state.config_models_cursor with
    | None -> add_event state "error" "no model row is selected"
    | Some row -> (
      match state.runtime_config_view with
      | None -> add_event state "error" "config not loaded yet; r to reload"
      | Some (_, source_rows) ->
        state.config_pane <- Config_runtime;
        (* Land a few rows above the header so the section reads as a block
           rather than starting at the top edge. *)
        (match config_models_source_line ~row source_rows with
         | Some i ->
             set_runtime_config_cursor_near state ~direction:1 ~target:i;
             state.config_scroll <- max 0 (i - 3)
         | None -> ());
        add_event state "info"
          (Printf.sprintf "runtime.toml at [models.%s] - e to edit"
             row.Masc_tui_model_runtime_table.model))
  in
  let handle_runtime_config_edit () =
    match state.runtime_config_view with
    | None -> report_action state "error" "config not loaded yet; r to reload"
    | Some (_, rows) -> (
      match Masc_tui_editor.editor_command () with
      | None ->
        report_action state "error"
          "no $EDITOR set; export EDITOR to edit runtime.toml here"
      | Some _ -> (
        (* Rebuilt from the rows on screen rather than kept as a second copy.
           The editor has to receive the file as it is, and the colours are a
           reading of that file rather than a change to it -- dropping the
           kinds gives back exactly what was loaded. *)
        let stem =
          String.concat "\n"
            (List.map
               (fun segments -> String.concat "" (List.map fst segments))
               rows)
        in
        match
          Masc_tui_editor.roundtrip ~restore:restore_terminal
            ~reenter:reenter_terminal stem
        with
        | Error abort ->
          report_editor_abort state ~action:"runtime.toml"
            ~cancelled:"runtime.toml unchanged" abort
        | Ok edited -> (
          let host = server_peer_host in
          let port = state.port in
          match
            Masc_tui_http.post_runtime_config_preview ~host ~port
              ~source_text:edited
          with
          | Error detail -> report_action state "error" ("preview failed: " ^ detail)
          | Ok preview -> (
            let ok =
              match preview with
              | `Assoc fields -> (
                  match List.assoc_opt "validation" fields with
                  | Some (`Assoc v) -> (
                      match List.assoc_opt "ok" v with
                      | Some (`Bool value) -> Some value
                      | _ -> None)
                  | _ -> (
                      match List.assoc_opt "ok" fields with
                      | Some (`Bool value) -> Some value
                      | _ -> None))
              | _ -> None
            in
            match ok with
            | Some false ->
              report_action state "error"
                ("preview rejected the edit: "
                 ^ Terminal_text.single_line
                     (Yojson.Safe.to_string preview))
            | Some true | None -> (
              match
                Masc_tui_http.post_runtime_config_raw ~host ~port
                  ~source_text:edited
              with
              | Ok receipt ->
                report_action state "system"
                  ("runtime.toml saved · "
                   ^ Masc_tui_http.runtime_config_commit_receipt_summary receipt);
                launch_runtime_config_load state ~mailbox:async_messages
              | Error detail -> report_action state "error" ("save failed: " ^ detail))))))
  in
  let selected_runtime_param () =
    List.nth_opt state.runtime_params state.runtime_params_cursor
  in
  let handle_runtime_param_edit_open ~advanced () =
    match selected_runtime_param () with
    | None ->
      state.runtime_params_notice <- Some (false, "No runtime parameter is selected")
    | Some row ->
      state.runtime_param_edit <-
        Some (Masc_tui_types.runtime_param_edit_of_row ~advanced row);
      state.runtime_params_notice <- None
  in
  let handle_runtime_param_edit_apply () =
    match state.runtime_param_edit with
    | None -> ()
    | Some edit -> (
      match Masc_tui_types.runtime_param_edit_value edit with
      | Error detail -> state.runtime_params_notice <- Some (false, detail)
      | Ok value -> (
        match
          Masc_tui_http.post_runtime_param_set ~host:server_peer_host
            ~port:state.port ~key:edit.rpe_key ~value
        with
        | Error detail ->
          state.runtime_params_notice <- Some (false, "Set failed: " ^ detail)
        | Ok _ ->
          state.runtime_param_edit <- None;
          state.runtime_params_notice <-
            Some
              ( true
              , Printf.sprintf "Set %s = %s" edit.rpe_key
                  (Yojson.Safe.to_string value) );
          launch_runtime_params_load state ~mailbox:async_messages))
  in
  let handle_runtime_param_clear () =
    match selected_runtime_param () with
    | None ->
      state.runtime_params_notice <- Some (false, "No runtime parameter is selected")
    | Some row ->
      let key = row.Tui_decode.rpr_key in
      if not row.rpr_has_override then
        state.runtime_params_notice <- Some (true, key ^ " already uses its default")
      else (
        match
          Masc_tui_http.post_runtime_param_clear ~host:server_peer_host
            ~port:state.port ~key
        with
        | Error detail ->
          state.runtime_params_notice <- Some (false, "Reset failed: " ^ detail)
        | Ok _ ->
          state.runtime_params_notice <- Some (true, "Reset " ^ key ^ " to its default");
          launch_runtime_params_load state ~mailbox:async_messages)
  in
  let skill_template ~composition =
    if composition
    then
      {|---
name: new-skill
description: Describe the repeatable job this Skill performs.
---

# New composition Skill

This preset runs one no-argument tool. Add nodes and dependencies after the
first preview succeeds. Change execution to "async" for durable background work.

```toml composition
[[compositions]]
name = "new-skill"
description = "Describe the repeatable job this Skill performs."
execution = "inline"

[[compositions.nodes]]
id = "clock"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
```
|}
    else
      {|---
name: new-skill
description: Describe when an agent should use this Skill.
---

# New instruction Skill

Write the durable procedure here. The body stays out of the eager tool context
and is loaded on demand through keeper_skill.
|}
  in
  let skill_name_from_source source_text =
    source_text
    |> String.split_on_char '\n'
    |> List.find_map (fun line ->
      let prefix = "name:" in
      if String.starts_with ~prefix line
      then
        let value =
          String.sub line (String.length prefix) (String.length line - String.length prefix)
          |> String.trim
        in
        if String.equal value "" then None else Some value
      else None)
  in
  let handle_skill_create ~composition () =
    let host = server_peer_host in
    let port = state.port in
    match Masc_tui_http.fetch_skill_editor_sources ~host ~port with
    | Error detail -> report_action state "error" ("Skill sources failed: " ^ detail)
    | Ok [] -> report_action state "error" "no ready read-write Skill source"
    | Ok (source_id :: _) ->
      (match Masc_tui_editor.editor_command () with
       | None -> report_action state "error" "no $EDITOR set; export EDITOR to create Skills"
       | Some _ ->
         (match
            Masc_tui_editor.roundtrip
              ~restore:restore_terminal
              ~reenter:reenter_terminal
              ~suffix:".md"
              (skill_template ~composition)
          with
          | Error abort ->
            report_editor_abort state ~action:"Skill creation" abort
          | Ok source_text ->
            (match skill_name_from_source source_text with
             | None -> report_action state "error" "Skill template has no name frontmatter"
             | Some "new-skill" ->
               report_action state "error" "change new-skill to a real unique name before creating"
             | Some package_id ->
               (match
                  Masc_tui_http.post_skill_editor_create
                    ~host
                    ~port
                    ~source_id
                    ~package_id
                    ~source_text
                with
                | Error detail -> report_action state "error" ("Skill create failed: " ^ detail)
                | Ok json ->
                  (* The server answers exactly created_and_published or
                     created_but_unpublished(+reason). The old "created"
                     default reported a status the server never sends and
                     swallowed the not-published reason — the save path
                     below already reports it; the create path now does
                     the same. *)
                  (match json_assoc_member_opt "status" json with
                   | Some (`String "created_and_published") ->
                     add_event
                       state
                       "system"
                       (Printf.sprintf
                          "created and published · %s/%s"
                          source_id
                          package_id)
                   | Some (`String "created_but_unpublished") ->
                     let reason =
                       match json_assoc_member_opt "reason" json with
                       | Some (`String reason) -> reason
                       | _ -> "(no reason reported)"
                     in
                     add_event
                       state
                       "error"
                       (Printf.sprintf
                          "%s/%s was created but NOT published: %s"
                          source_id
                          package_id
                          reason)
                   | Some (`String other) ->
                     add_event
                       state
                       "error"
                       (Printf.sprintf
                          "%s/%s: unrecognized create status %S"
                          source_id
                          package_id
                          other)
                   | Some _ | None ->
                     add_event
                       state
                       "error"
                       (Printf.sprintf
                          "%s/%s: create receipt carried no status"
                          source_id
                          package_id));
                  launch_tools_load state ~mailbox:async_messages))))
  in
  let handle_skill_evidence () =
    match selected_tools_skill_profile state with
    | None -> add_event state "error" "no published Skill selected"
    | Some profile ->
      let key =
        Skill_reference.to_yojson profile.esp_reference |> Yojson.Safe.to_string
      in
      (match
         Masc_tui_http.post_skill_evidence
           ~host:server_peer_host
           ~port:state.port
           profile.esp_reference
       with
       | Error detail -> add_event state "error" ("Skill evidence lookup failed: " ^ detail)
       | Ok json -> state.tools_skill_evidence <- Some (key, json))
  in
  let handle_skill_edit () =
    match selected_tools_skill_profile state with
    | None -> report_action state "error" "no published Skill selected"
    | Some profile ->
      let name = profile.Masc.Tui_decode.esp_name in
      let host = server_peer_host in
      let port = state.port in
      (match
         Masc_tui_http.post_skill_editor_read
           ~host
           ~port
           profile.esp_reference
       with
       | Error detail -> report_action state "error" ("Skill read failed: " ^ detail)
       | Ok loaded when not (String.equal loaded.sel_access "read_write") ->
         report_action state "error" (name ^ " belongs to a read-only Skill source")
       | Ok loaded ->
         (match Masc_tui_editor.editor_command () with
          | None ->
            report_action state "error" "no $EDITOR set; export EDITOR to edit Skills"
          | Some _ ->
            (match
               Masc_tui_editor.roundtrip
                 ~restore:restore_terminal
                 ~reenter:reenter_terminal
                 ~suffix:".md"
                 loaded.sel_source_text
             with
             | Error abort ->
               report_editor_abort state ~action:(name ^ " edit") abort
             | Ok edited when String.equal edited loaded.sel_source_text ->
               report_action state "system" (name ^ " unchanged")
             | Ok edited ->
               (match
                  Masc_tui_http.post_skill_editor_preview
                    ~host
                    ~port
                    ~reference:loaded.sel_reference
                    ~source_text:edited
                with
                | Error detail ->
                  report_action state "error" ("Skill preview rejected: " ^ detail)
                | Ok _ ->
                  (match
                     Masc_tui_http.post_skill_editor_save
                       ~host
                       ~port
                       ~reference:loaded.sel_reference
                       ~source_text:edited
                   with
                   | Error detail ->
                     report_action state "error" ("Skill save failed: " ^ detail)
                   | Ok receipt ->
                     (match receipt.ses_status with
                      | Masc_tui_http.Skill_unchanged ->
                        report_action state "system" (name ^ " unchanged")
                      | Skill_saved_and_published ->
                        let revision =
                          Skill_reference.content_revision_to_string
                            receipt.ses_reference.content_revision
                        in
                        let revision_short =
                          String.sub revision 0 (min 12 (String.length revision))
                        in
                        report_action state "system"
                          (Printf.sprintf
                             "%s saved + published · %s%s"
                             name
                             revision_short
                             (match receipt.ses_snapshot_revision with
                              | None -> ""
                              | Some snapshot ->
                                " · snapshot "
                                ^ String.sub snapshot 0 (min 12 (String.length snapshot))));
                        launch_tools_load state ~mailbox:async_messages
                      | Skill_saved_but_unpublished reason ->
                        report_action state "error"
                          (name ^ " was saved but NOT published: " ^ reason)))))))
  in
  (* A prompt is edited the way runtime.toml is: $EDITOR over the text a turn
     actually gets, and the server persists what comes back. The effective
     text is the stem rather than the file's, because an overridden prompt is
     what the keeper reads and editing the file underneath it would change
     nothing the operator can see. *)
  let selected_prompt () =
    selected_prompt_for_state state
  in
  let handle_librarian_input_read () =
    match selected_prompt () with
    | None -> add_event state "error" "prompts not loaded yet; r to reload"
    | Some row when not (String.equal row.Tui_decode.pr_category "librarian") ->
        add_event state "error" "actual input is available on the Librarian prompt"
    | Some row ->
        launch_librarian_input_load state ~mailbox:async_messages
          ~prompt_key:row.Tui_decode.pr_key
  in
  let handle_prompt_edit () =
    match selected_prompt () with
    | None -> report_action state "error" "prompts not loaded yet; r to reload"
    | Some row -> (
      match Masc_tui_editor.editor_command () with
      | None ->
        report_action state "error"
          "no $EDITOR set; export EDITOR to edit prompts here"
      | Some _ -> (
        match
          Masc_tui_editor.roundtrip ~restore:restore_terminal
            ~reenter:reenter_terminal row.Tui_decode.pr_effective
        with
        | Error abort ->
          report_editor_abort state
            ~action:(row.Tui_decode.pr_key ^ " prompt")
            ~cancelled:(row.Tui_decode.pr_key ^ ": prompt unchanged")
            abort
        | Ok edited ->
          (match
             Masc_tui_http.post_prompt_override ~host:server_peer_host
               ~port:state.port ~key:row.Tui_decode.pr_key ~value:edited
           with
           | Ok _ ->
             report_action state "system" (row.Tui_decode.pr_key ^ ": prompt saved");
             launch_prompts_load state ~mailbox:async_messages
           | Error detail ->
             report_action state "error"
               (row.Tui_decode.pr_key ^ ": save failed: " ^ detail))))
  in
  (* Clearing is not editing to empty: it returns the prompt to the file's
     words, which is a different outcome from an override holding "". *)
  let handle_prompt_clear () =
    match selected_prompt () with
    | None -> add_event state "error" "prompts not loaded yet; r to reload"
    | Some row ->
      if not row.Tui_decode.pr_has_override then
        add_event state "system"
          (row.Tui_decode.pr_key ^ ": no override to clear")
      else (
        match
          Masc_tui_http.post_prompt_clear ~host:server_peer_host
            ~port:state.port ~key:row.Tui_decode.pr_key
        with
        | Ok _ ->
          add_event state "system"
            (row.Tui_decode.pr_key ^ ": override cleared");
          launch_prompts_load state ~mailbox:async_messages
        | Error detail ->
          add_event state "error"
            (row.Tui_decode.pr_key ^ ": clear failed: " ^ detail))
  in
  let handle_keeper_settings_edit () =
    match selected_keeper state with
    | None ->
      (* Every other outcome of this handler reports: no $EDITOR, a load
         failure, unparseable JSON, an empty patch. This one returned silently,
         so pressing the key with an empty or stale roster looked exactly like
         a feature that is not there. *)
      report_action state "system" no_keeper_under_cursor
    | Some keeper -> (
      match Masc_tui_editor.editor_command () with
      | None ->
        report_action state "error"
          "no $EDITOR set; export EDITOR to edit keeper settings here"
      | Some _ -> (
        match
          Masc_tui_loader.load_keeper_config_editor ~host ~port
            ~keeper_name:keeper.k_name
        with
        | Error detail -> report_action state "error" detail
        | Ok (observed, stem) -> (
          match
            Masc_tui_editor.roundtrip ~restore:restore_terminal
              ~reenter:reenter_terminal stem
          with
          | Error abort ->
              report_editor_abort state
                ~action:(keeper.k_name ^ " settings")
                ~cancelled:(keeper.k_name ^ ": settings unchanged")
                abort
          | Ok edited -> (
            match Yojson.Safe.from_string edited with
            | exception Yojson.Json_error detail ->
                report_action state "error" ("settings are not JSON: " ^ detail)
            | edited_json -> (
              match
                Masc_tui_keeper_config.patch_of_edit ~before:observed
                  ~after:edited_json
              with
              | Error detail -> report_action state "error" detail
              | Ok (`Assoc []) ->
                  report_action state "system"
                    (keeper.k_name ^ ": no settings changed")
              | Ok patch -> (
                match
                  Masc_tui_http.post_keeper_config ~host ~port
                    ~keeper_name:keeper.k_name
                    ~patch_json:(Yojson.Safe.to_string patch)
                with
                | Error
                    (( Masc_tui_http.Keeper_config_revision_conflict _
                     | Masc_tui_http.Keeper_config_reconciliation_required _
                     | Masc_tui_http.Keeper_config_runtime_sync_failed _ ) as
                     error) ->
                  report_action state "error"
                    (Masc_tui_http.keeper_config_post_error_to_string error);
                  state.keeper_config_view <- None;
                  state.keeper_config_view_error <- None;
                  launch_keeper_config_view state
                    ~mailbox:async_messages keeper.k_name
                | Error error ->
                  report_action state "error"
                    (Masc_tui_http.keeper_config_post_error_to_string error)
                | Ok response ->
                    (match
                       Masc_tui_keeper_config.config_write_status_message
                         ~keeper_name:keeper.k_name response
                     with
                     | Error detail ->
                       report_action state "error"
                         (keeper.k_name ^ ": invalid config write receipt: " ^ detail)
                     | Ok (severity, message) ->
                       report_action state severity message);
                    if
                      state.view = Keepers Keeper_detail
                      && state.detail_tab = Detail_instructions
                    then (
                      state.keeper_config_view <- None;
                      state.keeper_config_view_error <- None;
                      launch_keeper_config_view state
                        ~mailbox:async_messages keeper.k_name)))))))
  in
  let handle_keeper_create () =
    match Masc_tui_editor.editor_command () with
    | None ->
      report_action state "error" "no $EDITOR set; export EDITOR to create a keeper here"
    | Some _ -> (
      (* Which fields a creation cannot omit is [parse]'s business, so the
         stem comes from there rather than being restated here. Restating it
         is what went wrong: this form carried two fields across the whole
         time [sandbox_profile] was required, and every keeper made through
         it came back 400. *)
      let stem = Masc.Keeper_turn_up_args.creation_stem in
      match
        Masc_tui_editor.roundtrip ~restore:restore_terminal
          ~reenter:reenter_terminal stem
      with
      | Error abort -> report_editor_abort state ~action:"create" abort
      | Ok declaration -> (
        let declared_name =
          match Yojson.Safe.from_string declaration with
          | `Assoc fields -> (
            match List.assoc_opt "name" fields with
            | Some (`String value) -> String.trim value
            | _ -> "")
          | _ -> ""
        in
        if String.length declared_name = 0 then
          report_action state "error"
            "declaration needs a non-empty \"name\" string; nothing was created"
        else
          match
            Masc_tui_http.post_keeper_up ~host ~port ~keeper_name:declared_name
              ~declaration_json:declaration
          with
          | Ok _ -> report_action state "system" (declared_name ^ ": keeper created")
          | Error detail -> report_action state "error" detail))
  in
  (* Same shape as [handle_keeper_create]: several fields at once go through
     $EDITOR rather than a modal the TUI does not otherwise have. The stem
     names every field the route reads, with the two that have no sensible
     default left empty. *)
  let handle_repository_add () =
    match Masc_tui_editor.editor_command () with
    | None ->
      report_action state "error"
        "no $EDITOR set; export EDITOR to add a repository here"
    | Some _ -> (
      let stem =
        String.concat "\n"
          [ "{";
            "  \"name\": \"\",";
            "  \"url\": \"\",";
            "  \"default_branch\": \"main\",";
            "  \"auto_sync\": false,";
            "  \"sync_interval\": 300";
            "}";
            "" ]
      in
      match
        Masc_tui_editor.roundtrip ~restore:restore_terminal
          ~reenter:reenter_terminal stem
      with
      | Error abort -> report_editor_abort state ~action:"add" abort
      | Ok declaration -> (
        let declared field =
          match Yojson.Safe.from_string declaration with
          | `Assoc fields -> (
            match List.assoc_opt field fields with
            | Some (`String value) -> String.trim value
            | _ -> "")
          | _ -> ""
        in
        let name = declared "name" in
        let url = declared "url" in
        if String.length name = 0 || String.length url = 0 then
          report_action state "error"
            "declaration needs non-empty \"name\" and \"url\" strings; nothing was added"
        else
          match
            Masc_tui_http.post_repository_add ~host ~port
              ~declaration_json:declaration
          with
          | Ok _ ->
            report_action state "system" (name ^ ": repository added");
            launch_repositories_load state ~mailbox:async_messages
          | Error detail -> report_action state "error" detail))
  in
  let handle_schedule_form ~action ~stem ~post =
    match Masc_tui_editor.editor_command () with
    | None ->
      report_action state "error"
        ("no $EDITOR set; export EDITOR to " ^ action ^ " a schedule here")
    | Some _ ->
      (match
         Masc_tui_editor.roundtrip ~restore:restore_terminal
           ~reenter:reenter_terminal stem
       with
       | Error abort -> report_editor_abort state ~action abort
       | Ok declaration ->
         (match Yojson.Safe.from_string declaration with
          | exception Yojson.Json_error message ->
            report_action state "error"
              (action ^ ": body is not JSON: " ^ message)
          | `Assoc _ ->
            (match post declaration with
             | Error detail -> report_action state "error" (action ^ ": " ^ detail)
             | Ok response ->
               (match Masc.Tui_decode.tool_envelope_outcome response with
                | Error detail ->
                  report_action state "error" (action ^ ": " ^ detail)
                | Ok message ->
                  report_action state "system" (action ^ ": " ^ message);
                  state.schedule_cancel_armed <- None;
                  state.schedule_cancel_error <- None;
                  launch_schedules_load state ~mailbox:async_messages))
          | _ ->
            report_action state "error"
              (action ^ ": the editor form must be a JSON object")))
  in
  let handle_schedule_create () =
    handle_schedule_form ~action:"create"
      ~stem:(Masc_tui_types.schedule_create_form_json ())
      ~post:(fun body_json ->
        Masc_tui_http.post_schedule_create_json ~host:server_peer_host
          ~port:state.port ~body_json)
  in
  let handle_schedule_modify () =
    match selected_schedule_row state with
    | None -> report_action state "error" "modify: no schedule under the cursor"
    | Some row ->
      handle_schedule_form ~action:"modify"
        ~stem:(Masc_tui_types.schedule_update_form_json row)
        ~post:(fun body_json ->
          Masc_tui_http.post_schedule_update ~host:server_peer_host
            ~port:state.port ~body_json)
  in
  let consume_resize_request () =
    if Atomic.exchange resize_requested false then
      invalidate_frame_for_resize frame_presenter render_schedule
  in
  let run_loop () =
    while true do
      request_console_write_repair render_schedule;
      consume_resize_request ();
      (* A second Ctrl-C while the first still stands ends the session; a lone
         one only says so. The notice is an event rather than a footer line
         because it has to survive the frame the operator is looking at, and
         because the answer to "why did nothing happen" belongs in the log
         they can scroll back to. *)
      if Atomic.exchange interrupt_requested false then begin
        state.quit_armed <- false;
        if Atomic.get interrupt_armed then exit 0
        else begin
          Atomic.set interrupt_armed true;
          add_event state "system"
            "Ctrl-C: press again to quit, or any other key to stay";
          Render_schedule.request render_schedule Render_schedule.Background
        end
      end;
      if
        drain_async_messages state ~base_path ~http_refresh_inflight
          ~http_scoped_refresh_inflight ~scoped_refresh_followup async_messages
      then Render_schedule.request render_schedule Render_schedule.Background;
      (* Check for input *)
      let input_timeout =
        Render_schedule.input_timeout_seconds render_schedule
          ~now_ns:(Mtime_clock.elapsed_ns ())
          ~maximum:maximum_input_wait_seconds
      in
      let input = read_input ~timeout:input_timeout input_reader () in
      (* SIGWINCH can arrive while [read_input] is waiting. Consume it before
         this input sees the old frame; the next loop would be one key too
         late. *)
      consume_resize_request ();
      (* One direct ioctl snapshot owns both this interaction's bounds and its
         eventual frame. This also observes resizes from terminals that omit
         SIGWINCH, without allowing nested renderers to disagree mid-frame. *)
      (match refresh_terminal_size () with
       | Render_schedule.Terminal_size_cache.Changed _ ->
           Frame_presenter.invalidate frame_presenter;
           Render_schedule.request render_schedule Render_schedule.Force
       | Render_schedule.Terminal_size_cache.Unchanged _ -> ());
      (* Any deliberate input withdraws a standing Ctrl-C. Without this the
         armed state outlives the moment it was meant for, and a Ctrl-C typed
         minutes apart from another would read as a double press. *)
      if Option.is_some input then Atomic.set interrupt_armed false;
      (* The key channel stays exactly what it was: every surface below reads
         [key] the way it always has, and a paste is simply not one. Splitting
         here rather than inside the surfaces is what keeps a paste from
         needing a name in the key vocabulary. *)
      (* A picture is showing, which means the terminal is not showing this
         program's frame. The next key is the one that takes the picture away
         and is not also a keystroke for the surface underneath -- an operator
         pressing j to dismiss a screenshot did not mean to move a cursor. *)
      let dismissed_image =
        state.image_open && Option.is_some input
      in
      if dismissed_image then begin
        close_image state;
        invalidate_frame_for_resize frame_presenter render_schedule
      end;
      let key =
        if dismissed_image then None
        else
          match input with
          | Some (Key name) -> Some name
          | Some (Pasted _) | Some (Graphics_reply _)
          | Some (Mouse_left_press _) | None -> None
      in
      (* Async agenda state can change the usable row budget after the last
         paint. Read the compact marker from that paint, not from the newer
         state. An invalidated or not-yet-painted frame stays compact until
         presentation succeeds, so its hidden surface cannot consume input. *)
      let compact_viewport =
        Frame_presenter.last_frame_is_compact frame_presenter
      in
      (* The field a typed character would land in, read once for the paste
         below. A paste is the characters the operator would have typed, so
         it goes where they would have gone; the exhaustive match is what
         keeps a field added to [text_input_target] from silently dropping
         pasted text the way the palette, row search and the preset name
         each did. *)
      let text_target = text_input_target state ~compact_viewport in
      (match input with
       (* A paste into a one-line field is the text, on one line: no dropped
          file to classify and no spill to disk, both of which are the
          composer's and mean nothing in a field a single row high. A copied
          secret carries the newline that ended it, and a field is not a
          place for one. *)
       | Some (Pasted paste) when Option.is_some text_target ->
           let text =
             Masc_tui_types.identity_field_paste paste.Masc_tui_paste.text
           in
           (match text_target with
            | None -> ()
            | Some Text_preset_name ->
                state.preset_save_draft <-
                  Some
                    (Option.value state.preset_save_draft ~default:"" ^ text)
            (* The first paste replaces the selected current value; later
               pastes append, matching typed input. *)
            | Some Text_runtime_param ->
                Option.iter
                  (fun edit ->
                    state.runtime_param_edit <-
                      Some (Masc_tui_types.runtime_param_edit_append edit text);
                    state.runtime_params_notice <- None)
                  state.runtime_param_edit
            | Some Text_palette ->
                state.palette_query <- state.palette_query ^ text;
                state.palette_cursor <- 0
            (* Typing in row search moves the cursor to the first match as
               each character lands, so a paste has to jump the same way or
               the query on screen and the row under it disagree. *)
            | Some Text_row_search ->
                let longer =
                  Option.value state.search ~default:"" ^ text
                in
                state.search <- Some longer;
                search_jump state ~query:longer ~after:(-1)
            (* A client secret is exactly the thing an operator pastes, and
               the composer path would put it in a chat draft -- a credential
               in a message nobody meant to write. *)
            | Some Text_identity_app_form ->
                Option.iter
                  (fun form ->
                    state.identity_app_form <-
                      Some
                        (match form.Masc_tui_types.iaf_field with
                         | Masc_tui_types.App_client_id ->
                           { form with
                             Masc_tui_types.iaf_client_id =
                               form.Masc_tui_types.iaf_client_id ^ text
                           }
                         | Masc_tui_types.App_client_secret ->
                           { form with
                             Masc_tui_types.iaf_client_secret =
                               form.Masc_tui_types.iaf_client_secret ^ text
                           }
                         | Masc_tui_types.App_scopes ->
                           { form with
                             Masc_tui_types.iaf_scopes =
                               form.Masc_tui_types.iaf_scopes ^ text
                           }))
                  state.identity_app_form
            | Some Text_identity_filter ->
                state.identity_filter <-
                  Some (Option.value state.identity_filter ~default:"" ^ text);
                state.identity_cursor <- 0
            (* A board post holds many lines, so this one takes the paste
               whole rather than on one line. It does not spill to a file the
               way the chat draft does: that file is written into the keeper's
               workspace for the keeper to read, and a board post has no
               keeper and nowhere to put it. *)
            | Some Text_board_draft ->
                Buffer.add_string state.board_draft
                  (Keeper_chat.terminal_safe_text ~preserve_newlines:true
                     paste.Masc_tui_paste.text))
       (* Both sides of this arm are wanted: the guard decides whether a paste
          is handled at all, and the rewrite decides what text it carries. *)
       | Some (Pasted paste)
         when not dismissed_image && not compact_viewport ->
           (* A dropped or Finder-copied file arrives shell-escaped. The
              filesystem is the check that keeps this from touching text that
              merely looks like a path: an existing file is what the operator
              dropped, and anything else is left byte-for-byte as pasted. *)
           (match Masc_tui_paste.unescaped_path paste.Masc_tui_paste.text with
            | Some path when Sys.file_exists path -> (
                match Masc_tui_attachment.classify_drop ~path with
                | Masc_tui_attachment.Attach attachment ->
                    attach_dropped_image state ~base_path
                      ~mailbox:async_messages attachment
                | Masc_tui_attachment.Keep_path ->
                    handle_paste state ~base_path ~mailbox:async_messages
                      ~paste:{ paste with Masc_tui_paste.text = path }
                | Masc_tui_attachment.Refuse error ->
                    add_event state "error"
                      (Masc_tui_attachment.error_to_string error))
            | Some _ | None ->
                handle_paste state ~base_path ~mailbox:async_messages ~paste)
       (* A left press on the Lanes overview moves the row cursor (and opens
          the row it already named). The modals above the surface -- help,
          agenda, palette, search -- keep the press from reaching rows they
          cover, exactly like a key. *)
       | Some (Mouse_left_press (row, _column))
         when state.view = Lanes
              && state.lanes_mode = Lanes_overview
              && (not dismissed_image)
              && (not compact_viewport)
              && (not state.help_open)
              && (not state.agenda_open)
              && (not state.palette_open)
              && (not state.context_inspector_open)
              && Option.is_none state.search ->
           let terminal_rows, _ = get_terminal_size () in
           handle_lanes_overview_click state ~base_path ~mailbox:async_messages
             ~terminal_rows ~row
       (* A graphics reply is read and dropped. Nothing asks for one outside
          the capability probe, which does its own reading before the loop
          starts; what matters here is that it does not become keys. *)
       | Some (Pasted _) | Some (Graphics_reply _) | Some (Key _)
       | Some (Mouse_left_press _) | None -> ());
      if Option.is_some input then
        Render_schedule.request render_schedule Render_schedule.Input;
      let _terminal_rows, terminal_columns = get_terminal_size () in
      let message_mode =
        (not compact_viewport) && state.view = Keepers Keeper_message
      in
      let quit_key =
        match key with
        | Some k -> Render_schedule.Input_shortcut.is_quit ~message_mode k
        | None -> false
      in
      (* Exit confirmation belongs only to two consecutive quit keys. A paste,
         a mouse report, or any other key means the operator stayed. *)
      if Option.is_some input && not quit_key then state.quit_armed <- false;
      (* An armed shutdown expires on the next unrelated input. Otherwise it
         waits indefinitely and a later press of the same key -- after the
         cursor has moved, after a refresh -- submits work the operator armed
         minutes ago for something else. Same rule for every other armed
         action here, and the same one the quit confirmation above already
         uses: deliberate input that is not the second press ends it.

         One predicate rather than one restatement per field. The connector
         unbind used to spell the rule itself and read a loop turn that
         fetched no input as an unrelated key, so its arm survived a single
         iteration. The viewport is not part of the rule: an armed
         destructive action must not outlive the moment it was armed in,
         least of all across a resize the operator cannot see it through. *)
      let cancelled second_press =
        Masc_tui_keys.cancels_two_press
          ~input_seen:(Option.is_some input) ~key ~second_press
      in
      (match state.view with
       | Approvals ->
           if cancelled [ "y"; "Y"; "n"; "N" ] then
             state.pending_approval_action <- None
       | Keepers _ ->
           if cancelled [ "s"; "S" ] then state.keeper_action_pending <- None
       | Board -> if cancelled [ "v"; "V" ] then state.board_vote_armed <- None
       | Planning ->
           if cancelled [ "c"; "C"; "x"; "X"; "o"; "O" ] then
             state.goal_action_armed <- None
       | Schedules ->
           if cancelled [ "x"; "X" ] then state.schedule_cancel_armed <- None
       | Verification ->
           if cancelled [ "a"; "A" ] then
             state.verification_verdict_armed <- None
       | Config ->
           (* A restore rewrites three surfaces; its arm must not outlive the
              keypress that set it. *)
           if cancelled [ "u"; "U" ] then state.preset_restore_armed <- None
       | Overview | Acting | Lanes | Clients | Harness | Memory | Fusion
       | Repositories
       | Changes | Connectors | Runtime | Resources | Tools
       | System_logs | Code -> ());
      (* Destructive binding removal deliberately requires two consecutive
         [u] presses. Any intervening action invalidates the ownership
         snapshot; the server also compares that owner inside the store lock.
         Not scoped to the Channels tab: an arm the operator left behind on
         another surface is exactly the stale confirmation this cancels. *)
      if cancelled [ "u" ] then state.connector_unbind_armed <- None;
      (* The composer sees the key first, and takes it only when it has one to
         take: unfocused it claims a single key, and only with somewhere to
         send. Everything it does not claim reaches the surface with its
         meaning unchanged, so no existing binding moved when the row
         appeared. The chat surface is excluded — it draws its own composer. *)
      let composer_claimed =
        (not compact_viewport)
        && (not state.help_open)
        && (not state.agenda_open)
        && (not state.context_inspector_open)
        && (not state.palette_open)
        && Option.is_none state.runtime_param_edit
        && Option.is_none state.search
        && not (state.view = Board && state.board_mode = Board_compose)
        && state.view <> Keepers Keeper_message
        && key <> Some toggle_mouse_tracking_key
        && key <> Some toggle_roster_pane_key
        &&
        match key with
        | Some k -> handle_composer_key state ~base_path ~mailbox:async_messages k
        | None -> false
      in
      (match key with
       | Some _ when composer_claimed -> ()
       (* Inline Runtime_params editing is modal: printable keys, including q,
          belong to the value.  Friendly mode turns the registry's declared
          type into a bool/number/string control; capital E is the explicit
          raw-JSON escape hatch.  The server remains the final authority. *)
       (* Typing a preset name. The pane owns every printable key while a
          draft is open, so a name with an s or an r in it does not fire the
          save and restore keys under it. *)
       | Some k
         when text_input_target state ~compact_viewport
              = Some Text_preset_name ->
           (match state.preset_save_draft with
            | None -> ()
            | Some draft ->
              (match k with
               | "esc" ->
                 state.preset_save_draft <- None;
                 report_action state "system" "프리셋 저장 취소"
               | "\r" | "\n" | "enter" ->
                 let name = String.trim draft in
                 if String.equal name "" then
                   report_action state "error" "프리셋 이름이 필요합니다"
                 else begin
                   state.preset_save_draft <- None;
                   state.preset_busy <- true;
                   report_action state "system" (name ^ " 저장 중");
                   launch_preset_call state ~mailbox:async_messages
                     ~call:(fun ~host ~port ->
                       Masc_tui_loader.save_preset ~host ~port ~name ~description:"")
                     ~wrap:(fun result -> Preset_saved (Preset_to_pane, result))
                 end
               | "\127" | "\b" | "backspace" ->
                 let length = String.length draft in
                 if length > 0 then
                   state.preset_save_draft <- Some (String.sub draft 0 (length - 1))
               | s when String.length s = 1 && Char.code s.[0] >= 32 ->
                 state.preset_save_draft <- Some (draft ^ s)
               | _ -> ()))
       | Some k
         when text_input_target state ~compact_viewport
              = Some Text_runtime_param ->
           (match state.runtime_param_edit with
            | None -> ()
            | Some edit ->
              let set value = state.runtime_param_edit <- Some value in
              (match k with
               | "esc" ->
                 state.runtime_param_edit <- None;
                 state.runtime_params_notice <-
                   Some (true, edit.rpe_key ^ ": edit cancelled")
               | "\r" | "\n" | "enter" -> handle_runtime_param_edit_apply ()
               | "\127" | "\b" | "backspace" ->
                 set (Masc_tui_types.runtime_param_edit_backspace edit);
                 state.runtime_params_notice <- None
               | s when String.length s = 1 && Char.code s.[0] = 21 ->
                 set (Masc_tui_types.runtime_param_edit_clear edit);
                 state.runtime_params_notice <- None
               | "left" | "right" | " "
                 when edit.rpe_mode = Masc_tui_types.Friendly_value
                      && List.mem
                           (Masc_tui_types.runtime_param_type_name
                              edit.rpe_value_type)
                           [ "bool"; "boolean" ] ->
                 set (Masc_tui_types.runtime_param_edit_toggle_bool edit);
                 state.runtime_params_notice <- None
               | s
                 when (String.length s = 1 && Char.code s.[0] >= 32)
                      || (String.length s > 1 && Char.code s.[0] >= 0x80) ->
                 set (Masc_tui_types.runtime_param_edit_append edit s);
                 state.runtime_params_notice <- None
               | _ -> ()))
       | Some _
         when quit_key
              && (compact_viewport
                 || (Option.is_none state.search
                    && not
                         (state.view = Board
                         && state.board_mode = Board_compose))) ->
           if state.quit_armed then raise Break
           else begin
             state.quit_armed <- true;
             add_event state "system"
               "q: press again to quit, or any other key to stay"
           end
       (* Above the modals on purpose: the reason to reach for this is to copy
          something already on the screen, and the help overlay is one of the
          screens worth copying from. *)
       | Some k when String.equal k toggle_mouse_tracking_key ->
           toggle_mouse_tracking ();
           Render_schedule.request render_schedule Render_schedule.Force
       (* Also above the modals: the roster is chrome around whatever is
          showing, and reclaiming its columns should not depend on which
          surface is up. *)
       | Some k when String.equal k toggle_roster_pane_key ->
           (match
              Masc_tui_roster_pane.toggle_hidden
                ~hidden:state.roster_pane_hidden ~cols:terminal_columns
            with
            | None ->
                add_event state "system"
                  (Printf.sprintf
                     "Keeper roster needs %d columns; preference unchanged"
                     Masc_tui_roster_pane.threshold_cols)
            | Some hidden ->
                state.roster_pane_hidden <- hidden;
                if hidden then state.keeper_message_focus <- Right_pane;
                Render_schedule.request render_schedule Render_schedule.Force)
       (* The compact fallback owns every remaining key. Put this before every
          modal and surface branch: those states are hidden, and a question,
          search cursor, or draft must not move behind the fallback. *)
       | Some _ when compact_viewport -> ()
       (* Writing an answer takes every printable key, the way the row search
          and the app form do, and it sits above the answering arm because
          that arm reads digits as choices and [s]/[c] as commands. An
          operator typing "1 second" must not have the 1 picked for them. *)
       | Some k
         when state.view = Approvals
              && Option.is_some state.ask_text_entry
              && not state.context_inspector_open ->
           (match k with
            | "esc" -> cancel_ask_text_entry state
            | "\r" | "\n" | "enter" -> commit_ask_text_entry state
            | "\127" | "\b" ->
                edit_ask_text state Masc_tui_message_layout.drop_last_utf8_scalar
            | s
              when (String.length s = 1 && Char.code s.[0] >= 32)
                   || (String.length s > 1 && Char.code s.[0] >= 0x80) ->
                edit_ask_text state (fun text -> text ^ s)
            | _ -> ());
           Render_schedule.request render_schedule Render_schedule.Force
       (* Answering is modal. A question needs a key per choice, and this
          surface already spent its arrows and its y/n on the approval queue,
          so the keys have to come from somewhere. Quit and the chrome
          toggles stay above this on purpose: an operator who wants out of
          the terminal should not have to leave a draft first. *)
       | Some k
         when state.view = Approvals
              && (match state.ask_answer_mode with
                  | Ask_answering _ -> true
                  | Ask_browsing -> false)
              && not state.context_inspector_open ->
           (match k with
            | "esc" -> leave_ask_answering state
            | "up" | "k" | "wheel-up" -> move_ask_question_cursor state (-1)
            | "down" | "j" | "wheel-down" -> move_ask_question_cursor state 1
            | "[" -> move_ask_cursor state (-1)
            | "]" -> move_ask_cursor state 1
            | "s" | "S" -> skip_ask_question state
            | "c" | "C" -> clear_ask_question state
            (* Ahead of the digit arm below, which takes every one-character
               key and drops the ones that are not positions -- [t] landed
               there and did nothing. *)
            | "t" | "T" -> begin_ask_text_entry state
            (* Terminals send Enter as CR. "enter" is the name the Kitty
               protocol gives codepoint 13, and this was the only site in the
               file waiting for it -- the other twelve read "\r" -- so the
               answer could be composed and never sent. *)
            | "\r" | "\n" | "enter" ->
                handle_ask_submit state ~mailbox:async_messages
            | digit when String.length digit = 1 -> (
                (* Parsed, not matched: a choice is picked by its position in
                   the list the server sent, and anything that is not a
                   position is not a choice. *)
                match int_of_string_opt digit with
                | Some position when position >= 1 && position <= 9 ->
                    toggle_ask_choice state (position - 1)
                | Some _ | None -> ())
            | _ -> ());
           Render_schedule.request render_schedule Render_schedule.Force
       (* The same two keys the answering mode uses, so the walk does not
          change shape when the operator commits. j/k cannot serve here: the
          approval queue above owns them, which is why this list had no way to
          move at all -- [a] opened whichever ask the cursor had been left on,
          and with more than one waiting there was no way to reach the rest
          without answering the first. *)
       | Some ("[" | "]" as k)
         when state.view = Approvals
              && (match state.ask_answer_mode with
                  | Ask_browsing -> true
                  | Ask_answering _ -> false)
              && (not state.approval_detail_open)
              && not state.context_inspector_open ->
           move_ask_cursor state (if String.equal k "[" then -1 else 1);
           Render_schedule.request render_schedule Render_schedule.Force
       (* [/context] is modal: the summary and exact input text must not leak
          keys into the composer underneath. The quit confirmation and chrome
          toggles remain global above it, matching Help and Palette. An
          active surface search outranks it: typing during a search is the
          search, and the search arm below owns those keys. *)
       | Some k
         when state.context_inspector_open && Option.is_none state.search ->
           let exact_input_items () =
             match state.context_inspector_reading with
             | Some
                 ( _
                 , { Masc_tui_context_inspector.provider_input = Ok input; _ }
                 ) ->
                 Masc_tui_context_inspector.exact_input_items input
             | Some _ | None -> []
           in
           let input_map_rows () =
             match state.context_inspector_reading with
             | Some
                 ( _
                 , { Masc_tui_context_inspector.turn = Ok selection
                   ; provider_input
                   } ) -> (
                 (* The map is a per-component table, so it needs the
                    attributed record; the render side shows its own "no
                    exact composition" line when the page holds none. *)
                 match selection.Masc_tui_context_inspector.attributed with
                 | None -> []
                 | Some attributed ->
                     let provider_input =
                       match provider_input with
                       | Ok value -> Some value
                       | Error _ -> None
                     in
                     Masc_tui_context_inspector.input_map_rows
                       attributed.Masc_tui_context_inspector.record
                       provider_input)
             | Some _ | None -> []
           in
           let close () =
             state.context_inspector_open <- false;
             state.context_inspector_exact <- None;
             state.context_inspector_scroll <- 0;
             state.context_inspector_detail_scroll <- 0;
             state.context_inspector_focus <- Left_pane;
             state.context_inspector_turn_back <- 0
           in
           (match k with
            | "esc" ->
                (match state.context_inspector_exact with
                 | Some _ ->
                     state.context_inspector_exact <- None;
                     state.context_inspector_scroll <- 0
                 | None -> close ())
            | "[" | "]" ->
                (* Turn navigation: [ steps back through the page's rows, ]
                   steps forward, and the fetch re-reads the exact provider
                   input for the row they name. The keys work on every tab;
                   a row without a snapshot says so on the request tab. *)
                let count =
                  match state.context_inspector_reading with
                  | Some
                      ( _
                      , { Masc_tui_context_inspector.turn =
                            Ok { Masc_tui_context_inspector.rows; _ }
                        ; _ } ) ->
                      List.length rows
                  | _ -> 0
                in
                if count > 0 then begin
                  let moved =
                    if k = "[" then
                      min (count - 1) (state.context_inspector_turn_back + 1)
                    else max 0 (state.context_inspector_turn_back - 1)
                  in
                  if moved <> state.context_inspector_turn_back then begin
                    state.context_inspector_turn_back <- moved;
                    state.context_inspector_cursor <- 0;
                    state.context_inspector_exact <- None;
                    state.context_inspector_scroll <- 0;
                    state.context_inspector_detail_scroll <- 0;
                    Option.iter
                      (fun keeper_name ->
                         launch_context_inspector_load state
                           ~mailbox:async_messages ~keeper_name)
                      state.context_inspector_keeper
                  end
                end
            | "/" when
                state.context_inspector_tab
                = Masc_tui_context_inspector.Exact_input
                && Option.is_some state.context_inspector_reading ->
                (* The surface search's own arm sits below this modal block,
                   so the pane starts the search itself: same state, same
                   keys, and the block above now yields while it runs. *)
                state.search <- Some ""
            | "r" ->
                Option.iter
                  (fun keeper_name ->
                     launch_context_inspector_load state
                       ~mailbox:async_messages ~keeper_name)
                  state.context_inspector_keeper
            | "1" ->
                state.context_inspector_tab <-
                  Masc_tui_context_inspector.Composition;
                state.context_inspector_exact <- None;
                state.context_inspector_cursor <- 0;
                state.context_inspector_scroll <- 0;
                state.context_inspector_detail_scroll <- 0;
                state.context_inspector_focus <- Left_pane
            | "2" ->
                state.context_inspector_tab <-
                  Masc_tui_context_inspector.Exact_input;
                state.context_inspector_exact <- None;
                state.context_inspector_cursor <- 0;
                state.context_inspector_scroll <- 0;
                state.context_inspector_detail_scroll <- 0;
                state.context_inspector_focus <- Left_pane
            | "3" ->
                state.context_inspector_tab <-
                  Masc_tui_context_inspector.Input_map;
                state.context_inspector_exact <- None;
                state.context_inspector_cursor <- 0;
                state.context_inspector_scroll <- 0;
                state.context_inspector_detail_scroll <- 0;
                state.context_inspector_focus <- Left_pane
            | "\t" | "left" | "right" when Option.is_none state.context_inspector_exact ->
                state.context_inspector_tab <-
                  (match state.context_inspector_tab with
                   | Masc_tui_context_inspector.Composition ->
                       Masc_tui_context_inspector.Exact_input
                   | Masc_tui_context_inspector.Exact_input ->
                       Masc_tui_context_inspector.Input_map
                   | Masc_tui_context_inspector.Input_map ->
                       Masc_tui_context_inspector.Composition);
                state.context_inspector_cursor <- 0;
                state.context_inspector_scroll <- 0;
                state.context_inspector_detail_scroll <- 0;
                state.context_inspector_focus <- Left_pane
            | "h" | "l"
              when Option.is_none state.context_inspector_exact
                   && terminal_columns >= keeper_split_threshold_cols
                   && state.context_inspector_tab
                      <> Masc_tui_context_inspector.Composition ->
                (* The same caret the roster and the board carry: which pane
                   hears j/k is a question the reader answers, not the
                   layout. *)
                state.context_inspector_focus <-
                  (if k = "h" then Left_pane else Right_pane)
            | ("j" | "down" | "k" | "up")
              when Option.is_some state.context_inspector_exact
                   || state.context_inspector_tab
                      = Masc_tui_context_inspector.Composition ->
                let count, height =
                  Masc_tui_render.context_inspector_viewport state
                in
                let move =
                  match k with
                  | "j" | "down" -> Masc_tui_scroll.down
                  | _ -> Masc_tui_scroll.up
                in
                state.context_inspector_scroll <-
                  move ~count ~height state.context_inspector_scroll
            | ("j" | "down" | "k" | "up")
              when state.context_inspector_focus = Right_pane
                   && terminal_columns >= keeper_split_threshold_cols ->
                (* The width condition mirrors the h/l arm that set the
                   focus. A terminal narrowed under the threshold keeps the
                   stored focus but renders no split, and without this guard
                   j/k would reach for a detail window that does not exist --
                   while the cursor arms below, which do work, sat
                   shadowed. *)
                let count, height =
                  Masc_tui_render.context_inspector_detail_viewport state
                in
                let move =
                  match k with
                  | "j" | "down" -> Masc_tui_scroll.down
                  | _ -> Masc_tui_scroll.up
                in
                state.context_inspector_detail_scroll <-
                  move ~count ~height state.context_inspector_detail_scroll
            | "j" | "down" ->
                let count =
                  match state.context_inspector_tab with
                  | Masc_tui_context_inspector.Exact_input ->
                      List.length (exact_input_items ())
                  | Masc_tui_context_inspector.Input_map ->
                      List.length (input_map_rows ())
                  | Masc_tui_context_inspector.Composition -> 0
                in
                let last = max 0 (count - 1) in
                state.context_inspector_cursor <-
                  min last (state.context_inspector_cursor + 1);
                (* A new item is a new document; its reader starts at its
                   top, not at the window the previous one was left in. *)
                state.context_inspector_detail_scroll <- 0
            | "k" | "up" ->
                state.context_inspector_cursor <-
                  max 0 (state.context_inspector_cursor - 1);
                state.context_inspector_detail_scroll <- 0
            | "\r" ->
                if
                  state.context_inspector_tab
                  = Masc_tui_context_inspector.Exact_input
                then begin
                  match
                    List.nth_opt (exact_input_items ())
                      state.context_inspector_cursor
                  with
                  | Some _ ->
                      state.context_inspector_exact <-
                        Some state.context_inspector_cursor;
                      state.context_inspector_scroll <- 0
                  | None -> ()
                end
                else if
                  state.context_inspector_tab
                  = Masc_tui_context_inspector.Input_map
                then begin
                  match
                    List.nth_opt (input_map_rows ())
                      state.context_inspector_cursor
                  with
                  | Some { Masc_tui_context_inspector.exact_text = Some _; _ } ->
                      state.context_inspector_exact <-
                        Some state.context_inspector_cursor;
                      state.context_inspector_scroll <- 0
                  | Some _ | None -> ()
                end
            | _ -> ())
       (* The help overlay is modal: it answers scrolling and closing, and
          swallows everything else so a surface binding cannot fire under a
          screen that is describing it. Quit stays global above. *)
       | Some k when state.help_open && k = "h" ->
           (* Session toggle; the persistent form is [tui].hints_visible in
              runtime.toml, named on the help sheet itself. *)
           state.hints_visible <- not state.hints_visible
       | Some k when state.help_open ->
           (match k with
            | "?" | "esc" ->
                state.help_open <- false;
                state.help_scroll <- 0
            | "j" | "down" | "k" | "up" ->
                (* Bounded against the sheet the frame draws, which folds to
                   two columns on a wide terminal and so holds half the rows
                   the lines were written as. *)
                let count, height = Masc_tui_render.help_viewport state in
                let move =
                  match k with
                  | "j" | "down" -> Masc_tui_scroll.down
                  | _ -> Masc_tui_scroll.up
                in
                state.help_scroll <- move ~count ~height state.help_scroll
            | _ -> ())
       (* Modal for the same reason the help sheet is: a panel that is
          answering "what is coming" should not have a surface binding fire
          underneath it. *)
       | Some k when state.agenda_open ->
           (match k with
            | ";" | "esc" ->
                state.agenda_open <- false;
                state.agenda_scroll <- 0
            | "j" | "down" | "k" | "up" ->
                let count, height = Masc_tui_render.agenda_viewport state in
                let move =
                  match k with
                  | "j" | "down" -> Masc_tui_scroll.down
                  | _ -> Masc_tui_scroll.up
                in
                state.agenda_scroll <- move ~count ~height state.agenda_scroll
            | _ -> ())
       (* Modal like the agenda sheet: a panel answering "who is mid-turn"
          should not have a surface binding fire underneath it. j/k walk the
          actionable rows (running and just finished), not raw lines, and
          Enter opens that keeper's chat through the same path the palette
          uses. The scroll follows the cursor instead of moving on its own. *)
       | Some k when state.answering_open ->
           let close () =
             state.answering_open <- false;
             state.answering_scroll <- 0;
             state.answering_cursor <- 0
           in
           (match k with
            | "@" | "esc" -> close ()
            | "j" | "down" | "k" | "up" ->
                let lines = Masc_tui_render.answering_lines state in
                let targets = Masc_tui_answering.target_indexes lines in
                (match targets with
                 | [] -> ()
                 | _ ->
                     let position =
                       let rec find i = function
                         | [] -> 0
                         | index :: rest ->
                             if index = state.answering_cursor then i
                             else find (i + 1) rest
                       in
                       find 0 targets
                     in
                     let next_position =
                       match k with
                       | "j" | "down" ->
                           min (List.length targets - 1) (position + 1)
                       | _ -> max 0 (position - 1)
                     in
                     let cursor = List.nth targets next_position in
                     state.answering_cursor <- cursor;
                     let _, height =
                       Masc_tui_render.answering_viewport state
                     in
                     (* Keep the cursor row on screen: scroll only as far as
                        needed, in either direction. *)
                     if cursor < state.answering_scroll then
                       state.answering_scroll <- cursor
                     else if cursor >= state.answering_scroll + height then
                       state.answering_scroll <- cursor - height + 1)
            | "\r" ->
                let lines = Masc_tui_render.answering_lines state in
                (match List.nth_opt lines state.answering_cursor with
                 | Some { Masc_tui_answering.target = Some keeper_name; _ } ->
                     close ();
                     open_message_for_keeper
                       ~return_to:Keeper_chat_return_list state keeper_name;
                     launch_keeper_history_load state
                       ~mailbox:async_messages ~keeper_name;
                     state.view <- Keepers Keeper_message
                 | Some _ | None -> ())
            | _ -> ())
       (* The palette is the same kind of modal, but typed: printable keys
          build the query, arrows move the cursor, Enter runs the highlighted
          jump through the exact goto/chat paths the bound keys use. *)
       | Some k
         when text_input_target state ~compact_viewport = Some Text_palette ->
           let close () =
             state.palette_open <- false;
             state.palette_query <- "";
             state.palette_cursor <- 0
           in
           (match k with
            | "esc" -> close ()
            | "\r" when
                (let q = String.trim state.palette_query in
                 List.exists
                   (fun (prefix, _) -> String.starts_with ~prefix q)
                   Masc_tui_types.lsp_question_prefixes) ->
                (* A typed command, not an entry: the argument is the symbol
                   the language-server question is asked about, on the Code
                   pane's cursor line. *)
                let q = String.trim state.palette_query in
                let question, symbol =
                  match String.index_opt q ' ' with
                  | Some i ->
                      ( String.sub q 0 i,
                        String.trim
                          (String.sub q (i + 1) (String.length q - i - 1)) )
                  | None -> (q, "")
                in
                (* The typed word back to the question it names, through the
                   same table the entries were built from. *)
                let question =
                  match
                    List.find_opt
                      (fun (prefix, _) ->
                        String.equal (String.trim prefix) question)
                      Masc_tui_types.lsp_question_prefixes
                  with
                  | Some (_, canonical) -> canonical
                  | None -> question
                in
                if String.equal symbol "" then begin
                  (* Bare "def " or "hover ": run the highlighted candidate
                     entry -- the cursor line's names ride the palette list,
                     so Enter alone picks the one in view. *)
                  let matches = Masc_tui_types.palette_matches state in
                  let chosen =
                    List.nth_opt matches
                      (max 0
                         (min state.palette_cursor
                            (List.length matches - 1)))
                  in
                  close ();
                  match chosen with
                  | Some (_, Masc_tui_types.Palette_lsp (question, symbol))
                    ->
                      start_code_lsp_question state
                        ~mailbox:async_messages ~question ~symbol
                  | Some _ | None ->
                      add_event state "error"
                        (question ^ " needs a symbol: :" ^ question
                       ^ " <name>")
                end
                else begin
                  close ();
                  if state.view <> Code || Option.is_none state.code_file
                  then
                    add_event state "error"
                      "hover, def and refs ask about the file open on the \
                       Code surface"
                  else
                    start_code_lsp_question state ~mailbox:async_messages
                      ~question ~symbol
                end
            | "\r" ->
                let matches = Masc_tui_types.palette_matches state in
                let chosen =
                  List.nth_opt matches
                    (max 0 (min state.palette_cursor (List.length matches - 1)))
                in
                close ();
                (match chosen with
                 | Some (_, Masc_tui_types.Palette_goto destination) ->
                     goto_surface state ~mailbox:async_messages destination
                 | Some (_, Masc_tui_types.Palette_config pane) ->
                     state.config_pane <- pane;
                     state.config_scroll <- 0;
                     state.runtime_params_cursor <- 0;
                     state.runtime_param_edit <- None;
                     state.runtime_params_notice <- None;
                     goto_surface state ~mailbox:async_messages Config
                 | Some (_, Masc_tui_types.Palette_chat keeper_name) ->
                     open_message_for_keeper
                       ~return_to:Keeper_chat_return_list state keeper_name;
                     launch_keeper_history_load state
                       ~mailbox:async_messages ~keeper_name;
                     state.view <- Keepers Keeper_message
                 | Some (_, Masc_tui_types.Palette_task task_id) ->
                     (* The palette lands where Enter on the task list would:
                        Overview with the task's detail open and the cursor
                        on its row. *)
                     goto_surface state ~mailbox:async_messages Overview;
                     state.task_detail_id <- Some task_id;
                     state.task_detail_scroll <- 0;
                     state.task_history <- None;
                     launch_task_history_load state ~mailbox:async_messages
                       task_id;
                     let rec index_of i = function
                       | [] -> None
                       | (t : Masc_tui_types.task) :: rest ->
                           if String.equal t.id task_id then Some i
                           else index_of (i + 1) rest
                     in
                     (match index_of 0 state.tasks with
                      | Some index -> state.task_cursor <- index
                      | None -> ())
                 | Some (_, Masc_tui_types.Palette_board_post post_id) ->
                     goto_surface state ~mailbox:async_messages Board;
                     let rec find i = function
                       | [] -> None
                       | (p : Masc_tui_types.board_post) :: rest ->
                           if String.equal p.bp_id post_id then Some (i, p)
                           else find (i + 1) rest
                     in
                     (match find 0 state.board_posts with
                      | Some (index, post) ->
                          state.board_cursor <- index;
                          open_board_post state ~mailbox:async_messages
                            ~focus:Right_pane post
                      | None -> ())
                 | Some (_, Masc_tui_types.Palette_lsp (question, symbol))
                   ->
                     start_code_lsp_question state ~mailbox:async_messages
                       ~question ~symbol
                 | None -> ())
            | "down" -> state.palette_cursor <- state.palette_cursor + 1
            | "up" -> state.palette_cursor <- max 0 (state.palette_cursor - 1)
            | "\127" | "\b" ->
                state.palette_query <-
                  Masc_tui_message_layout.drop_last_utf8_scalar
                    state.palette_query;
                state.palette_cursor <- 0
            | s
              when (String.length s = 1 && Char.code s.[0] >= 32)
                   || (String.length s > 1 && Char.code s.[0] >= 0x80) ->
                state.palette_query <- state.palette_query ^ s;
                state.palette_cursor <- 0
            | _ -> ())
       (* Row search: typing moves the surface's row cursor live to the
          first match from the top; Enter keeps the query for n/N, Esc keeps
          nothing. The list itself never narrows -- see [search] in types. *)
       | Some k
         when text_input_target state ~compact_viewport
              = Some Text_row_search ->
           let query = Option.value state.search ~default:"" in
           (match k with
            | "esc" -> state.search <- None
            | "\r" ->
                state.search <- None;
                state.search_last <- query
            | "\127" | "\b" ->
                let shorter =
                  Masc_tui_message_layout.drop_last_utf8_scalar query
                in
                state.search <- Some shorter;
                search_jump state ~query:shorter ~after:(-1)
            | s
              when (String.length s = 1 && Char.code s.[0] >= 32)
                   || (String.length s > 1 && Char.code s.[0] >= 0x80) ->
                let longer = query ^ s in
                state.search <- Some longer;
                search_jump state ~query:longer ~after:(-1)
            | _ -> ())
       (* The app form takes every printable key while it is open, the way
          the filter does. Three fields in order, enter to advance and to
          send on the last, esc to abandon -- and abandoning clears the
          secret rather than leaving it in the process. *)
       | Some k
         when text_input_target state ~compact_viewport
              = Some Text_identity_app_form -> (
           match state.identity_app_form with
           | None -> ()
           | Some form -> (
               let set text =
                 state.identity_app_form <-
                   Some
                     (match form.Masc_tui_types.iaf_field with
                      | Masc_tui_types.App_client_id ->
                        { form with Masc_tui_types.iaf_client_id = text }
                      | Masc_tui_types.App_client_secret ->
                        { form with Masc_tui_types.iaf_client_secret = text }
                      | Masc_tui_types.App_scopes ->
                        { form with Masc_tui_types.iaf_scopes = text })
               in
               let current =
                 match form.Masc_tui_types.iaf_field with
                 | Masc_tui_types.App_client_id -> form.Masc_tui_types.iaf_client_id
                 | Masc_tui_types.App_client_secret ->
                   form.Masc_tui_types.iaf_client_secret
                 | Masc_tui_types.App_scopes -> form.Masc_tui_types.iaf_scopes
               in
               match k with
               | "esc" -> state.identity_app_form <- None
               | "\127" | "\b" ->
                 set (Masc_tui_message_layout.drop_last_utf8_scalar current)
               | "\r" | "\n" -> (
                   match form.Masc_tui_types.iaf_field with
                   | Masc_tui_types.App_client_id ->
                     state.identity_app_form <-
                       Some
                         { form with
                           Masc_tui_types.iaf_field =
                             Masc_tui_types.App_client_secret
                         }
                   | Masc_tui_types.App_client_secret ->
                     state.identity_app_form <-
                       Some
                         { form with
                           Masc_tui_types.iaf_field = Masc_tui_types.App_scopes
                         }
                   | Masc_tui_types.App_scopes ->
                     launch_identity_app_save state ~mailbox:async_messages
                       ~form;
                     state.identity_app_form <- None)
               | s
                 when (String.length s = 1 && Char.code s.[0] >= 32)
                      || (String.length s > 1 && Char.code s.[0] >= 0x80) ->
                 set (current ^ s)
               | _ -> ()))
       | Some "j" | Some "k" | Some "e" | Some "E" | Some "\r"
         when state.view = Runtime && Option.is_some state.runtime_lane_pick ->
           (* The picker is open: j/k move it, Enter appends, e closes. *)
           let already, catalog = runtime_lane_picker_rows state in
           let count = List.length catalog in
           (match key with
            | Some "j" when state.runtime_lane_pick_cursor < count - 1 ->
                state.runtime_lane_pick_cursor <- state.runtime_lane_pick_cursor + 1
            | Some "k" when state.runtime_lane_pick_cursor > 0 ->
                state.runtime_lane_pick_cursor <- state.runtime_lane_pick_cursor - 1
            | Some "\r" ->
                (match
                   ( state.runtime_lane_pick
                   , List.nth_opt catalog state.runtime_lane_pick_cursor )
                 with
                 | Some lane, Some runtime ->
                     launch_runtime_lane_append state ~mailbox:async_messages
                       ~lane ~runtime_id:runtime.Masc.Tui_decode.ro_id
                       ~existing:already
                 | _ -> ())
            | Some "e" | Some "E" ->
                state.runtime_lane_pick <- None;
                state.runtime_lane_pick_cursor <- 0
            | _ -> ())
       | Some "e" | Some "E"
         when state.view = Runtime
              && state.runtime_mode = Masc_tui_types.Runtime_lanes
              && Option.is_none state.runtime_detail_target ->
           (* Add a failover candidate to the lane under the cursor. The
              catalogue is fetched on open so the list is the server's now. *)
           (* The lane under the row cursor. Rows are lane-by-candidate, so
              two rows can name one lane; either selects it. *)
           (match state.runtime_surface with
            | None -> ()
            | Some snapshot ->
                (match
                   List.nth_opt snapshot.Masc.Tui_decode.rss_candidates
                     state.runtime_cursor
                 with
                 | None -> ()
                 | Some row ->
                     state.runtime_lane_pick <-
                       Some row.Masc.Tui_decode.rcr_lane_id;
                     state.runtime_lane_pick_cursor <- 0;
                     state.runtime_lane_error <- None;
                     launch_runtime_catalog_load state ~mailbox:async_messages))
       | Some "T"
         when state.view = Keepers Keeper_detail
              && state.detail_tab = Detail_identity
              && not compact_viewport -> (
           match (selected_keeper state, state.identity_view) with
           | Some keeper, Some (stamp, providers)
             when String.equal stamp keeper.k_name -> (
               match
                 Masc_tui_types.identity_cursor_provider
                   ~query:(identity_query state) ~providers
                   state.identity_cursor
               with
               | Some (provider_id, _) -> (
                   let row =
                     List.find_map
                       (function
                         | Masc_tui_types.Identity_declared
                             { idp_id
                             ; idp_tools
                             ; idp_enabled
                             ; idp_switch_problem
                             ; _
                             }
                           when String.equal idp_id provider_id ->
                             Some (idp_tools, idp_enabled, idp_switch_problem)
                         | Masc_tui_types.Identity_declared _
                         | Masc_tui_types.Identity_unreadable _ -> None)
                       providers
                   in
                   match row with
                   | Some (Some _, enabled, None) ->
                       state.identity_attempt_error <- None;
                       launch_identity_switch state ~mailbox:async_messages
                         ~keeper_name:keeper.k_name ~provider_id
                         ~enabled:(enabled = Some false)
                   | Some (Some _, _, Some problem) ->
                       state.identity_attempt_error <-
                         Some
                           ( Masc_tui_types.Notice_bad
                           , "switch store unreadable: " ^ problem )
                   | Some (None, _, _) | None ->
                       add_event state "system"
                         "connect it first; the switch is for an attached service")
               | None -> ())
           | Some _, (Some _ | None) | None, _ -> ())
       | Some "A"
         when state.view = Keepers Keeper_detail
              && state.detail_tab = Detail_identity
              && not compact_viewport -> (
           match (selected_keeper state, state.identity_view) with
           | Some keeper, Some (stamp, providers)
             when String.equal stamp keeper.k_name -> (
               match
                 Masc_tui_types.identity_cursor_provider
                   ~query:(identity_query state) ~providers
                   state.identity_cursor
               with
               | Some (provider_id, label) ->
                 state.identity_attempt_error <- None;
                 state.identity_app_form <-
                   Some
                     { Masc_tui_types.iaf_provider = provider_id
                     ; iaf_label = label
                     ; iaf_field = Masc_tui_types.App_client_id
                     ; iaf_client_id = ""
                     ; iaf_client_secret = ""
                     ; iaf_scopes = ""
                     }
               | None -> ())
           | Some _, (Some _ | None) | None, _ -> ())
       (* The Identity list narrows as you type, which the row search above
          deliberately does not: sixty-seven rows is a list to look things up
          in rather than scroll. While it is open every printable key is
          text, so R, q, [ and the rest come back only when it closes -- esc,
          or backspace on an empty query. The arrows are named keys rather
          than characters and keep moving the cursor through what is left. *)
       | Some k
         when text_input_target state ~compact_viewport
              = Some Text_identity_filter -> (
           let query = Option.value state.identity_filter ~default:"" in
           let narrow text =
             state.identity_filter <- Some text;
             (* Back to the top: the row the cursor was on may not be in the
                shorter list, and keeping the index would move the marker to
                whatever happens to sit there now. *)
             state.identity_cursor <- 0
           in
           match k with
           | "esc" -> state.identity_filter <- None
           | "up" -> move_identity_cursor state ~delta:(-1)
           | "down" -> move_identity_cursor state ~delta:1
           | "\127" | "\b" ->
             if String.equal query ""
             then state.identity_filter <- None
             else narrow (Masc_tui_message_layout.drop_last_utf8_scalar query)
           | "\r" | "\n" -> (
               match (selected_keeper state, state.identity_view) with
               | Some keeper, Some (stamp, providers)
                 when String.equal stamp keeper.k_name -> (
                   match
                     Masc_tui_types.identity_cursor_provider
                       ~query:(identity_query state) ~providers
                       state.identity_cursor
                   with
                   | Some (provider_id, label) ->
                     state.identity_login <- None;
                     state.identity_attempt_error <- None;
                     launch_identity_login state ~mailbox:async_messages
                       ~keeper_name:keeper.k_name ~provider_id ~label
                   | None -> ())
               | Some _, (Some _ | None) | None, _ -> ())
           | s
             when (String.length s = 1 && Char.code s.[0] >= 32)
                  || (String.length s > 1 && Char.code s.[0] >= 0x80) ->
             narrow (query ^ s)
           | _ -> ())
       | Some "/"
         when state.view = Keepers Keeper_detail
              && state.detail_tab = Detail_identity
              && not compact_viewport ->
           state.identity_filter <- Some "";
           state.identity_cursor <- 0
       | Some "/"
         when Option.is_some (surface_row_texts state state.view) ->
           state.search <- Some ""
       | Some (("[" | "]") as bracket)
         when state.view = Keepers Keeper_detail ->
           (* Tabs inside the detail pane: [ and ] walk the same short list
              the pane's title row draws. Non-Info tabs read over HTTP on
              entry; the stamped keeper name keeps a slow answer from being
              drawn under a different selection. *)
           let tabs = Masc_tui_types.keeper_detail_tabs in
           let count = List.length tabs in
           let index =
             let rec find i = function
               | [] -> 0
               | tab :: rest ->
                   if tab = state.detail_tab then i else find (i + 1) rest
             in
             find 0 tabs
           in
           let step = if bracket = "]" then 1 else count - 1 in
           state.detail_tab <- List.nth tabs ((index + step) mod count);
           state.detail_scroll <- 0;
           (match selected_keeper state, state.detail_tab with
            | Some keeper, Detail_sandbox ->
                state.keeper_sandbox_view <- None;
                state.keeper_sandbox_view_error <- None;
                launch_keeper_sandbox_view state ~mailbox:async_messages
                  keeper.k_name
            | Some keeper, Detail_instructions ->
                state.keeper_config_view <- None;
                state.keeper_config_view_error <- None;
                launch_keeper_config_view state ~mailbox:async_messages
                  keeper.k_name
            | Some keeper, Detail_github ->
                state.github_identity_view <- None;
                state.github_identity_view_error <- None;
                launch_github_identity_view state ~mailbox:async_messages
                  keeper.k_name
            | Some keeper, Detail_identity ->
                state.identity_view <- None;
                state.identity_view_error <- None;
                launch_identity_view state ~mailbox:async_messages keeper.k_name
            | Some _, Detail_channels ->
                launch_connectors_load state ~mailbox:async_messages
            | Some _, Detail_automation ->
                launch_schedules_load state ~mailbox:async_messages
            | Some _, Detail_runs ->
                launch_fusion_runs_load state ~mailbox:async_messages
            | _, Detail_info | _, Detail_secrets | None, _ -> ())
       (* One step through the list a detail was opened from, on every surface
          that has one. Each reuses the same open the Enter arm uses, so a
          step cannot fetch less than an open does. Guarded on the detail
          being open: with the list showing, [ / ] is free for the surface to
          mean something else, and on Changes and the Keeper detail tabs it
          already does. *)
       | Some (("[" | "]") as bracket)
         when state.view = Schedules && Option.is_some state.schedule_detail_id ->
           step_detail_cursor
             ~count:
               (match state.schedules with
                | None -> 0
                | Some snapshot -> List.length snapshot.scs_rows)
             ~cursor:state.schedule_cursor
             ~delta:(if bracket = "]" then 1 else -1)
             ~set_cursor:(fun n -> state.schedule_cursor <- n)
             ~reopen:(fun () ->
               open_schedule_detail state ~mailbox:async_messages)
       | Some (("[" | "]") as bracket)
         when state.view = Verification
              && Option.is_some state.verification_detail_request_id ->
           step_detail_cursor
             ~count:
               (match state.verification with
                | None -> 0
                | Some s -> List.length s.Masc.Tui_decode.vs_requests)
             ~cursor:state.verification_cursor
             ~delta:(if bracket = "]" then 1 else -1)
             ~set_cursor:(fun n -> state.verification_cursor <- n)
             ~reopen:(fun () ->
               open_verification_detail state ~mailbox:async_messages)
       | Some (("[" | "]") as bracket)
         when state.view = Harness && Option.is_some state.harness_detail ->
           step_detail_cursor
             ~count:
               (match state.harness with
                | None -> 0
                | Some s -> List.length s.Masc.Tui_decode.hs_verdicts)
             ~cursor:state.harness_cursor
             ~delta:(if bracket = "]" then 1 else -1)
             ~set_cursor:(fun n -> state.harness_cursor <- n)
             ~reopen:(fun () -> open_harness_detail state)
       | Some (("[" | "]") as bracket)
         when state.view = Planning
              && (match state.planning_mode with
                  | Planning_detail _ -> true
                  | Planning_list -> false) ->
           step_detail_cursor
             ~count:
               (match state.planning with
                | None -> 0
                | Some p ->
                    List.length
                      (planning_visible_goals ~filter:state.planning_filter
                         ~sort:state.planning_sort p.pl_goals))
             ~cursor:state.planning_cursor
             ~delta:(if bracket = "]" then 1 else -1)
             ~set_cursor:(fun n -> state.planning_cursor <- n)
             ~reopen:(fun () ->
               open_planning_detail state ~mailbox:async_messages)
       | Some (("[" | "]") as bracket)
         when state.view = Fusion
              && (match state.fusion_mode with
                  | Fusion_detail _ -> true
                  | Fusion_list -> false) ->
           step_detail_cursor
             ~count:
               (match state.fusion_runs with
                | None -> 0
                | Some snapshot -> List.length snapshot.fus_runs)
             ~cursor:state.fusion_cursor
             ~delta:(if bracket = "]" then 1 else -1)
             ~set_cursor:(fun n -> state.fusion_cursor <- n)
             ~reopen:(fun () -> open_fusion_detail state ~mailbox:async_messages)
       (* Approvals holds no id -- the detail is a flag over the row under the
          cursor -- so stepping is the cursor move, and the pane follows. *)
       | Some (("[" | "]") as bracket)
         when state.view = Approvals && state.approval_detail_open ->
           step_detail_cursor ~count:(List.length (approval_items state))
             ~cursor:state.approval_cursor
             ~delta:(if bracket = "]" then 1 else -1)
             ~set_cursor:(fun n -> state.approval_cursor <- n)
             ~reopen:(fun () -> state.approval_detail_scroll <- 0)
       | Some (("[" | "]") as bracket)
         when state.view = System_logs
              && Option.is_some state.system_logs_detail_seq ->
           step_detail_cursor
             ~count:
               (List.length (Masc_tui_types.visible_system_log_entries state))
             ~cursor:state.system_logs_cursor
             ~delta:(if bracket = "]" then 1 else -1)
             ~set_cursor:(fun cursor -> state.system_logs_cursor <- cursor)
             ~reopen:(fun () -> open_selected_system_log state)
       | Some (("[" | "]") as bracket) when state.view = Board ->
           step_board_read state ~mailbox:async_messages
             ~delta:(if bracket = "]" then 1 else -1)
       | Some (("[" | "]") as bracket) when state.view = Changes ->
           cycle_changes_keeper state ~mailbox:async_messages
             ~delta:(if bracket = "]" then 1 else -1)
       | Some (("[" | "]") as bracket)
         when state.view = Resources && state.resource_focus = Right_pane ->
           step_detail_cursor
             ~count:
               (match state.resources_list with
                | None -> 0
                | Some resources -> List.length resources)
             ~cursor:state.resources_cursor
             ~delta:(if bracket = "]" then 1 else -1)
             ~set_cursor:(fun cursor -> state.resources_cursor <- cursor)
             ~reopen:(fun () ->
               open_selected_resource state ~mailbox:async_messages)
       | Some (("[" | "]") as bracket) when state.view = Tools ->
           cycle_tools_keeper state ~mailbox:async_messages
             ~delta:(if bracket = "]" then 1 else -1)
       | Some ("J" | "K")
         when state.view = Keepers Keeper_detail
              && state.detail_tab = Detail_channels ->
           let count =
             match selected_connector () with
             | None -> 0
             | Some connector -> List.length connector.cn_bindings
           in
           state.connector_unbind_armed <- None;
           state.connectors_binding_cursor <-
             (if key = Some "J" then
                Masc_tui_scroll.cursor_down ~count
                  state.connectors_binding_cursor
              else
                Masc_tui_scroll.cursor_up ~count
                  state.connectors_binding_cursor)
       | Some "L"
         when state.view = Keepers Keeper_detail
              && state.detail_tab = Detail_github ->
           (match selected_keeper state with
            | Some keeper ->
                state.github_identity_view <-
                  Some (keeper.k_name, [ "# github login"; "(starting gh device flow\xe2\x80\xa6)" ]);
                launch_github_login state ~mailbox:async_messages keeper.k_name
            | None -> ())
       (* The number the Identity tab printed. Both sides index
          [identity_connectable], so what the screen numbered and what this
          starts are the same list. *)
       | Some digit
         when state.view = Keepers Keeper_detail
              && state.detail_tab = Detail_identity
              && String.length digit = 1
              && digit.[0] >= '1'
              && digit.[0] <= '9' -> (
           let wanted = Char.code digit.[0] - Char.code '1' in
           match (selected_keeper state, state.identity_view) with
           | Some keeper, Some (stamp, providers)
             when String.equal stamp keeper.k_name -> (
               match
                 List.nth_opt
                   (Masc_tui_types.identity_connectable
                      ~query:(identity_query state) providers)
                   wanted
               with
               | Some (provider_id, label) ->
                   (* Left where the operator pressed, so the marker and the
                      arrows carry on from the row they just started. *)
                   state.identity_cursor <- wanted;
                   state.identity_login <- None;
                   state.identity_attempt_error <- None;
                   launch_identity_login state ~mailbox:async_messages
                     ~keeper_name:keeper.k_name ~provider_id ~label
               | None -> ())
           | Some _, (Some _ | None) | None, _ -> ())
       | Some "R"
         when state.view = Keepers Keeper_detail
              && state.detail_tab = Detail_identity -> (
           match (selected_keeper state, state.identity_view) with
           | Some keeper, Some (stamp, providers)
             when String.equal stamp keeper.k_name ->
               let attached =
                 List.filter_map
                   (function
                     | Masc_tui_types.Identity_declared
                         { idp_id; idp_tools = Some _; _ } -> Some idp_id
                     | Masc_tui_types.Identity_declared _
                     | Masc_tui_types.Identity_unreadable _ -> None)
                   providers
               in
               if attached <> [] then
                 launch_identity_refresh state ~mailbox:async_messages
                   ~keeper_name:keeper.k_name ~provider_ids:attached
           | Some _, (Some _ | None) | None, _ -> ())
       | Some "R" when state.view = Approvals ->
           (match
              Approval_authority.resolve ~presented:!presented_approval
                ~current:(approval_items state) Confirm
            with
            | Some { Approval_authority.row = Gate_row pending; _ } ->
                launch_gate_auto_judge_retry state ~mailbox:async_messages pending
            | Some { Approval_authority.row = (Operator_row _ | Keeper_tool_row _); _ }
            | None ->
                add_event state "system"
                  "Approval list changed; review the updated row before retrying")
       | Some "\r" when state.view = Resources ->
           open_selected_resource state ~mailbox:async_messages
       | Some "J" when state.view = Resources ->
           state.resource_scroll <- state.resource_scroll + 1
       | Some "K" when state.view = Resources ->
           state.resource_scroll <- max 0 (state.resource_scroll - 1)
       | Some "J" when state.view = Tools -> move_tools_skill_cursor state 1
       | Some "K" when state.view = Tools -> move_tools_skill_cursor state (-1)
       | Some "\r" when state.view = Tools -> handle_skill_evidence ()
       | Some ("\r" | "\n" | "enter")
         when state.view = Config && state.config_pane = Config_params ->
           handle_runtime_param_edit_open ~advanced:false ()
       | Some ("\r" | "\n" | "enter")
         when state.view = Config && state.config_pane = Config_themes ->
           (* Applying draws it: the palette's generation bumps and every
              cached colour rebuilds, which is the same road a theme switch
              reported by the terminal takes. Storing it is what makes the
              pick still be there on the next start -- boot reads the same
              key back. A name no bundled scheme answers to leaves the screen
              alone rather than quietly dropping to colours nobody picked,
              and nothing is stored for it either.

              All three spellings, because a terminal sends CR, a Kitty-
              protocol one sends the name, and a footer that says "Enter" has
              to mean whichever one arrived. *)
           let entries = Masc_tui_theme_choice.entries () in
           (match List.nth_opt entries state.theme_cursor with
            | None -> ()
            | Some entry ->
              if Masc_tui_theme_choice.apply entry.Masc_tui_theme_choice.name
              then begin
                state.theme_choice <- Some entry.Masc_tui_theme_choice.name;
                (* Committed: there is nothing to go back to any more. *)
                state.theme_before_preview <- None;
                (* The ink changed; the page has to change with it. A light
                   scheme picks dark text because it expects a light page, so
                   leaving the terminal's own background is what made "light
                   theme is still black". *)
                sync_theme_page ();
                store_theme_choice (Some entry.Masc_tui_theme_choice.name)
              end)
       | Some "c" when state.view = Tools -> handle_skill_create ~composition:false ()
       | Some "C" when state.view = Tools -> handle_skill_create ~composition:true ()
       | Some "c"
         when state.view = Memory
              && Option.is_some state.memory_facts_keeper ->
           (* Cycle the category filter: All, then each category the loaded
              store holds, in sorted order. The cursor restarts because the
              row under it belongs to the listing being replaced. *)
           state.memory_facts_category <-
             Masc_tui_types.next_memory_category state.memory_facts_category
               (Masc_tui_types.memory_fact_categories state);
           state.memory_facts_cursor <- 0;
           state.memory_facts_scroll <- 0
       (* Resources and Tools hang off Config the way Connectors hangs off
          Runtime: not on the Tab ring, one key from their parent. Both
          cases, like every other hang-off hop (c|C, f|F, p|P), and no
          param-edit guard: while a field is open, the capture arm earlier
          in this match owns every key before these can see one. *)
       | Some ("s" | "S") when state.view = Config ->
           goto_surface state ~mailbox:async_messages Resources
       | Some ("t" | "T") when state.view = Config ->
           goto_surface state ~mailbox:async_messages Tools
       (* System logs hang off Activity the same way: one key from the
          parent, off the Tab ring. *)
       | Some ("l" | "L") when state.view = Acting ->
           goto_surface state ~mailbox:async_messages System_logs
       (* In chat, printable keys normally belong to the draft. Keep [?] as
          the documented global Help key when the draft is empty; once a
          sentence has started it remains an ordinary question mark. This
          makes shortcuts and slash commands discoverable without discarding
          text the operator is already writing. *)
       | Some "?" when message_mode && Buffer.length state.msg_input = 0 ->
           state.help_open <- true;
           state.help_scroll <- 0
        | Some ("right" | "esc" | "\t")
          when message_mode
               && state.keeper_message_focus = Left_pane ->
            state.keeper_message_focus <- Right_pane
       | Some "left"
         when message_mode
              && Masc_tui_render.keeper_roster_pane_shown state
                   ~cols:terminal_columns ->
           state.keeper_message_focus <- Left_pane
       | Some "down"
         when message_mode
              && state.keeper_message_focus = Left_pane ->
           state.keeper_cursor <-
             Masc_tui_scroll.cursor_down ~count:(List.length state.keepers)
               state.keeper_cursor
       | Some "up"
         when message_mode
              && state.keeper_message_focus = Left_pane ->
           state.keeper_cursor <-
             Masc_tui_scroll.cursor_up ~count:(List.length state.keepers)
               state.keeper_cursor
       | Some ("\r" | "\n")
         when message_mode
              && state.keeper_message_focus = Left_pane ->
           (match List.nth_opt state.keepers state.keeper_cursor with
            | Some keeper ->
                open_message_for_keeper ~return_to:state.msg_return state
                  keeper.k_name;
                set_msg_scroll state 0;
                state.msg_loaded <- [];
                state.msg_loaded_keeper <- None;
                state.msg_loaded_error <- None;
                launch_keeper_history_load state ~mailbox:async_messages
                  ~keeper_name:keeper.k_name
            | None -> ())
       | Some k when message_mode ->
           (* Ctrl-R/Ctrl-D/Ctrl-F/Ctrl-N shape what the transcript draws,
              not what the composer holds, so a viewport too small for the
              composer still owes them a working transcript. Named as one set
              because they were admitted one by one and forgotten one by one:
              Ctrl-F never made this list, then Ctrl-N repeated the miss. *)
           let display_toggle_key =
             String.length k = 1
             &&
             let byte = Char.code k.[0] in
             byte = 18 || byte = 4 || byte = 6 || byte = 14
           in
           let switch_key = String.length k = 1 && Char.code k.[0] = 7 in
           let queue_management_key =
             String.length k = 1
             && (Char.code k.[0] = 11 || Char.code k.[0] = 16)
           in
           let scroll_recovery_key =
             String.equal k "down" || String.equal k "pagedown"
             || String.equal k "end"
           in
           if
             keeper_message_input_supported state
             || String.equal k "esc"
             (* Q reaches the composer handler for the same reason Esc does:
                the quiet leave must not disappear exactly when the terminal
                is too small to draw the composer -- a transcript-only
                viewport is when an operator most needs to step away from a
                running turn. Only while the draft is empty: with text in it,
                this condition fails and Q joins the other printables a
                too-small viewport silently holds (not drops into a draft
                nobody can see). *)
             || (String.equal k "Q" && Buffer.length state.msg_input = 0)
             || display_toggle_key
             || switch_key
             || queue_management_key
             || scroll_recovery_key
           then
             if switch_key then begin
               if Option.is_some state.msg_recall_replaces then begin
                 state.msg_recall_replaces <- None;
                 clear_staged_attachments state;
                 drain_queued_message state ~base_path
                   ~mailbox:async_messages
               end;
               switch_to_next_keeper_message state ~mailbox:async_messages
             end else
               let (_handled : bool) =
                 handle_message_key state
                   ~interrupt_turn:(fun () ->
                     (* Answers whether the press was spent on the turn. The
                        keeper the pane is showing is the one Esc can stop:
                        another keeper's turn is not on screen, and stopping
                        it from here would be a keypress the reader cannot
                        see the target of. What the press does is the pure
                        table in Masc_tui_esc_interrupt: launch on a first
                        press, swallow an accidental double press inside the
                        grace window, and leave the view once the signal is
                        stale, declined, or errored. Leaving cancels nothing
                        -- the interrupt proceeds server-side, and a turn
                        parked in an uncancellable section keeps streaming
                        after its signal (masc #29229), so holding Esc until
                        the stream settles could hold it forever. *)
                     match state.msg_live with
                     | Some live
                       when state.msg_target_keeper_name
                            = Some (Keeper_chat_transcript.keeper_name live) ->
                         (match
                            Masc_tui_esc_interrupt.action
                              ~now_ns:(Mtime_clock.elapsed_ns ())
                              (Keeper_chat_transcript.interrupt live)
                          with
                          | Masc_tui_esc_interrupt.Launch_interrupt ->
                            (match
                               inflight_by_request_id state
                                 (Keeper_chat_transcript.request_id live)
                             with
                             | Some request ->
                               launch_keeper_interrupt state
                                 ~mailbox:async_messages request;
                               true
                             | None -> false)
                          | Masc_tui_esc_interrupt.Swallow -> true
                          | Masc_tui_esc_interrupt.Leave -> false)
                     | Some _ | None -> false)
                   ~submit_message:
                     (send_operator_text state ~base_path
                        ~mailbox:async_messages)
                   ~answer_approval:(fun ~tool_call_id ~allow ->
                     match
                       Option.bind state.msg_live (fun live ->
                         inflight_by_request_id state
                           (Keeper_chat_transcript.request_id live))
                     with
                     | Some request ->
                         launch_keeper_approval state ~mailbox:async_messages
                           request ~tool_call_id ~allow
                     | None ->
                         (* No request in flight means no turn to answer for.
                            The prompt belongs to a turn, so this is
                            unreachable while one is shown. *)
                         ())
                   ~load_older:(fun ~before ->
                     match state.msg_target_keeper_name with
                     | Some keeper_name ->
                         launch_keeper_older_page state
                           ~mailbox:async_messages ~keeper_name ~before
                     | None -> ())
                   ~paste_image:(fun () -> paste_clipboard_image state)
                   ~open_named_image:(fun () -> open_named_image state)
                   ~inspect_context:(fun () ->
                     match state.msg_target_keeper_name with
                     | Some keeper_name ->
                         open_context_inspector state ~mailbox:async_messages
                           ~keeper_name
                     | None -> ())
                   ~load_tool_changes:(fun () ->
                     match state.msg_target_keeper_name with
                     | Some keeper_name ->
                         launch_keeper_chat_tool_details_load ~force:true state
                           ~mailbox:async_messages ~keeper_name
                     | None -> ())
                   ~drain_queue:(fun () ->
                     drain_queued_message state ~base_path
                       ~mailbox:async_messages)
                   ~start_voice:(fun () ->
                     match state.msg_target_keeper_name with
                     | Some keeper when state.voice_capture = None ->
                         launch_voice_capture state ~mailbox:async_messages ~keeper
                     (* The same toggle the composer row carries. *)
                     | Some _ ->
                         state.voice_stop_requested <- Some Masc.Voice_bridge.Keep_what_was_heard;
                         state.last_action <-
                           Some ("voice: stopping", Unix.gettimeofday ())
                     | None -> ())
                   ~toggle_voice_continuous:(fun () ->
                     match state.voice_continuous, state.msg_target_keeper_name with
                     | Some _, _ ->
                         state.voice_continuous <- None;
                         state.voice_floor <- None;
                         state.last_action <-
                           Some ("voice: continuous off", Unix.gettimeofday ())
                     | None, Some keeper ->
                         state.voice_continuous <- Some keeper;
                         state.voice_floor <-
                           Masc.Voice_bridge.measure_noise_floor ~agent_id:keeper ();
                         state.last_action <-
                           Some ("voice: continuous on", Unix.gettimeofday ());
                         if state.voice_capture = None
                         then
                           launch_voice_capture state ~mailbox:async_messages ~keeper
                     | None, None -> ())
                   k
               in
               ()
       | Some k
         when text_input_target state ~compact_viewport
              = Some Text_board_draft ->
           (* Same shape as the chat pane: while a draft is being written,
              printable keys belong to the draft. A key the handler declines
              (Tab) keeps its global meaning, so the cycle works mid-compose
              as this comment always claimed. *)
           let handled = handle_board_compose_key state ~mailbox:async_messages k in
           if not handled then
             (match k with
              | "\t" | "shift-tab" ->
                  cycle_surface state ~mailbox:async_messages
                    ~backwards:(k = "shift-tab")
              | _ -> ())
       | Some "?" ->
           state.help_open <- true;
           state.help_scroll <- 0
       | Some ";" ->
           state.agenda_open <- true;
           state.agenda_scroll <- 0
       | Some "@" ->
           state.answering_open <- true;
           state.answering_scroll <- 0;
           (* Open with the cursor on the first actionable row (the badge's
              lead keeper), so Enter straight after @ goes where the badge
              was pointing. Prose-only sheets keep the cursor parked at 0. *)
           state.answering_cursor <-
             (match
                Masc_tui_answering.target_indexes
                  (Masc_tui_render.answering_lines state)
              with
              | index :: _ -> index
              | [] -> 0)
       | Some ":" ->
           state.palette_open <- true;
           state.palette_query <- "";
           state.palette_cursor <- 0
       | Some "\023"
         when state.view = Board
              && terminal_columns >= keeper_split_threshold_cols
              && not state.board_detail_wide ->
           (match state.board_mode with
            | Board_read _ ->
                state.board_focus <-
                  (match state.board_focus with
                   | Left_pane -> Right_pane
                   | Right_pane -> Left_pane)
            | Board_list | Board_compose -> ())
       | Some "\023" when state.view = Resources ->
           state.resource_focus <-
             (match state.resource_focus with
              | Left_pane -> Right_pane
              | Right_pane -> Left_pane)
       | Some "shift-left"
         when state.view = Code && state.code_focus_file = Right_pane
              && not state.code_history_open ->
           state.code_file_hscroll <- max 0 (state.code_file_hscroll - 1)
       | Some "shift-right"
         when state.view = Code && state.code_focus_file = Right_pane
              && not state.code_history_open ->
           state.code_file_hscroll <-
             min
               (max 0 (state.code_file_max_width - 1))
               (state.code_file_hscroll + 1)
       | Some "B" when state.view = Code ->
           (* Walk back through the definition jumps, newest first. The
              stack holds where each jump left from; an empty stack says so
              instead of moving. *)
           (match state.code_jump_back with
            | [] -> add_event state "system" "no jump to walk back from"
            | (scope, dir, file, cursor, scroll) :: rest ->
                state.code_jump_back <- rest;
                let scope_changed = state.code_scope <> scope in
                state.code_scope <- scope;
                let dir_changed = not (String.equal state.code_dir dir) in
                state.code_dir <- dir;
                if scope_changed || dir_changed then begin
                  state.code_cursor <- 0;
                  state.code_entries <- [];
                  state.code_entries_error <- None;
                  launch_code_entries_load state ~mailbox:async_messages
                end;
                (match file with
                 | None ->
                     state.code_file <- None;
                     state.code_file_error <- None;
                     state.code_focus_file <- Left_pane
                 | Some path -> (
                     match state.code_file with
                     | Some (open_path, _)
                       when String.equal open_path path ->
                         state.code_file_cursor <- cursor;
                         state.code_file_scroll <- scroll;
                         state.code_focus_file <- Right_pane
                     | Some _ | None ->
                         state.code_target_line <- Some (cursor + 1);
                         launch_code_file_load state
                           ~mailbox:async_messages ~path)))
       | Some (("K" | "D" | "R") as key_name)
         when state.view = Code && state.code_focus_file = Right_pane
              && Option.is_some state.code_file
              && not state.code_history_open
              && not state.code_diff_open
              && not state.code_notes_open ->
           (* Ask the language server about a name on the cursor line. The
              pane has no character cursor, so the line's own names are the
              candidates: one name is asked about at once, several open the
              palette with each as an entry (typing still narrows, and a
              typed "def <name>" keeps working), and none says so. *)
           let question, prefix =
             match key_name with
             | "K" -> ("hover", "hover ")
             | "R" -> ("references", "refs ")
             | "D" | _ -> ("definition", "def ")
           in
           (match Masc_tui_types.code_cursor_line_symbols state with
            | [] ->
                state.code_lsp_note <-
                  Some "the cursor line has no name to ask about"
            | [ symbol ] ->
                start_code_lsp_question state ~mailbox:async_messages
                  ~question ~symbol
            | _ :: _ :: _ ->
                state.palette_open <- true;
                state.palette_query <- prefix;
                state.palette_cursor <- 0)
       | Some "w" when state.view = Code && state.code_notes_open ->
           (* Adding a note lives inside the notes view: the view proves the
              scope, and the fresh listing lands where the writer looks. *)
           handle_code_note_write ()
       | Some "b" when state.view = Code && state.code_focus_file = Right_pane
                       && Option.is_some state.code_file ->
           (* Who last touched each run of lines, in the margin beside the
              code. A margin rather than a view: blame answers a question
              about the line you are reading, and a separate screen would
              take that line away to answer it.

              Loaded is showing, so this toggles by fetching or dropping.
              Re-fetched rather than kept on a second press: an edit or a
              commit since the last read moves the runs, and a stale margin
              names the wrong author with no sign that it is stale. *)
           (match state.code_file with
            | None -> ()
            | Some (path, _) ->
                if Option.is_some state.code_blame then begin
                  state.code_blame <- None;
                  state.code_blame_error <- None
                end
                else begin
                  state.code_blame_error <- None;
                  launch_code_blame_load state ~mailbox:async_messages ~path
                end)
       | Some "m" when state.view = Code && state.code_focus_file = Right_pane
                       && Option.is_some state.code_file ->
           (* The notes anchored to the open file. Repository scope only:
              the annotation routes are scoped by the server-minted codebase
              slug, and only a Repositories row carries one -- the other
              scopes say so instead of guessing a slug. *)
           (match state.code_file with
            | None -> ()
            | Some (path, _) ->
                if state.code_notes_open then state.code_notes_open <- false
                else
                  match code_scope_codebase state with
                  | Error why -> add_event state "system" ("notes: " ^ why)
                  | Ok codebase ->
                      state.code_notes_open <- true;
                      state.code_diff_open <- false;
                      state.code_history_open <- false;
                      (match state.code_notes with
                       | Some (loaded_path, _)
                         when String.equal loaded_path path ->
                           ()
                       | Some _ | None ->
                           state.code_notes <- None;
                           state.code_notes_error <- None;
                           launch_code_notes_load state
                             ~mailbox:async_messages ~codebase ~path))
       | Some "d" when state.view = Code && state.code_focus_file = Right_pane
                       && Option.is_some state.code_file ->
           (* The working tree against HEAD, over the open file. One overlay
              at a time: opening this closes the history, and H the reverse.
              Same key closes it; a diff already fetched for this path is
              shown as it stands. *)
           (match state.code_file with
            | None -> ()
            | Some (path, _) ->
                if state.code_diff_open then state.code_diff_open <- false
                else begin
                  state.code_diff_open <- true;
                  state.code_history_open <- false;
                  state.code_notes_open <- false;
                  (match state.code_diff with
                   | Some (loaded_path, _)
                     when String.equal loaded_path path ->
                       ()
                   | Some _ | None ->
                       state.code_diff <- None;
                       state.code_diff_error <- None;
                       launch_code_diff_load state ~mailbox:async_messages
                         ~path)
                end)
       | Some "H" when state.view = Code && state.code_focus_file = Right_pane ->
           (* History over the open file. The capital only: lowercase h/l
              choose panes, while shifted arrows pan the file. Same key closes
              it; a listing already fetched for this path is shown as it stands. *)
           (match state.code_file with
            | None -> ()
            | Some (path, _) ->
                if state.code_history_open then
                  state.code_history_open <- false
                else begin
                  state.code_history_open <- true;
                  state.code_diff_open <- false;
                  state.code_notes_open <- false;
                  (match state.code_history with
                   | Some (loaded_path, _)
                     when String.equal loaded_path path ->
                       ()
                   | Some _ | None ->
                       state.code_history <- None;
                       state.code_history_error <- None;
                       launch_code_history_load state
                         ~mailbox:async_messages ~path)
                end)
       | Some ("z" | "Z") when state.view = Board ->
           (match state.board_mode with
            | Board_read _ ->
                state.board_detail_wide <- not state.board_detail_wide;
                state.board_focus <- Right_pane
            | Board_list | Board_compose -> ())
       | Some (("o" | "O" | "l") as sandbox_log_key)
         when state.view = Keepers Keeper_detail
              && state.detail_tab = Detail_sandbox
              && (not (String.equal sandbox_log_key "l")
                  || terminal_columns < keeper_split_threshold_cols
                  || state.keeper_detail_focus = Right_pane) ->
           (match selected_keeper state with
            | None -> ()
            | Some keeper ->
              state.keeper_sandbox_logs <- None;
              state.keeper_sandbox_logs_error <- None;
              launch_keeper_sandbox_logs state ~mailbox:async_messages
                keeper.k_name)
       | Some ("h" | "l")
         when terminal_columns >= keeper_split_threshold_cols
              && (match state.view with
                  | Overview | Keepers Keeper_detail | Resources -> true
                  | Board ->
                      (match state.board_mode with
                       | Board_read _ -> not state.board_detail_wide
                       | Board_list | Board_compose -> false)
                  | Code -> Option.is_some state.code_file
                  | Acting | Keepers _ | Lanes | Clients | Approvals
                  | Planning
                  | Schedules | Verification | Harness | Fusion
                  | Memory | Repositories | Changes | Connectors | Runtime | Config
                  | Tools | System_logs -> false) ->
           let focus = if key = Some "h" then Left_pane else Right_pane in
           (match state.view with
            | Overview -> state.task_focus <- focus
            | Board ->
                (match state.board_mode with
                 | Board_read _ -> state.board_focus <- focus
                 | Board_list | Board_compose -> ())
            | Keepers Keeper_detail -> state.keeper_detail_focus <- focus
            | Resources -> state.resource_focus <- focus
            | Code
              when Option.is_some state.code_file
                   && not state.repository_changes_open ->
                state.code_focus_file <- focus
            | Acting | Keepers _ | Lanes | Clients | Approvals | Planning
            | Schedules
            | Memory | Verification | Harness | Fusion | Repositories | Changes
            | Connectors | Runtime | Config | Code | Tools
            | System_logs -> ())
       | Some k when Masc_tui_keys.opens_keepers ~message_mode k ->
           state.view <- Keepers Keeper_list
       (* Ctrl-] follows the reference under the cursor, and Esc on the surface
          it lands on comes back. vim's tag key for the going; for the coming
          back it was Ctrl-T, which never ran: the mouse-tracking toggle
          claims the same byte 1200 lines above this in the same ordered
          match, and its [when] guard stops the compiler from calling the
          later arm unreachable. So following worked and returning did not.

          Esc rather than another chord. It is what a reader presses to leave
          a screen anyway, and where they were is a better answer than
          Overview -- which is where Esc used to drop them, having thrown away
          the fact that they had come from somewhere. [Y] already copies the
          same reference; following it is what an operator did with the copy
          by hand. *)
       | Some "\x1d" ->
           (match
              Option.bind (presented_surface_reference ()) (fun reference ->
                Option.bind (Link.parse reference) (fun (kind, id) ->
                  Option.map (fun target -> (reference, target))
                    (follow_target kind id)))
            with
            | None -> ()
            | Some (reference, (destination, opened)) ->
                (* Recorded before the move, so the way back is where the
                   operator actually was rather than where they land. *)
                state.followed_from <- Some (state.view, None);
                goto_surface state ~mailbox:async_messages destination;
                (* Landing on the surface is half the move. Every one of
                   these already has a "this one is open" state, and without
                   setting it the operator arrives at the top of a list and
                   goes looking for the row they just followed. *)
                (match destination, opened with
                 | Overview, Some task_id ->
                     state.task_detail_id <- Some task_id;
                     state.task_history <- None;
                     launch_task_history_load state ~mailbox:async_messages
                       task_id
                 | Planning, Some goal_id ->
                     state.planning_mode <- Planning_detail goal_id;
                     state.goal_timeline <- None;
                     launch_goal_timeline_load state ~mailbox:async_messages
                       goal_id
                 | Board, Some post_id -> state.board_mode <- Board_read post_id
                 | Schedules, Some schedule_id ->
                     state.schedule_detail_id <- Some schedule_id;
                     state.schedule_wake_history <- None;
                     state.schedule_wake_history_error <- None;
                     launch_schedule_wake_history_load state
                       ~mailbox:async_messages ~schedule_id
                 | Fusion, Some run_id -> state.fusion_mode <- Fusion_detail run_id
                 | Keepers _, Some keeper_name ->
                     (* The roster is a cursor, not an id, so this puts the
                        cursor on the named keeper and leaves it there. A name
                        the roster does not carry leaves the cursor alone
                        rather than moving it somewhere arbitrary. *)
                     (match
                        List.find_index
                          (fun (keeper : Tui_decode.keeper) ->
                             String.equal keeper.k_name keeper_name)
                          state.keepers
                      with
                      | Some index -> state.keeper_cursor <- index
                      | None -> ())
                 | _, _ -> ());
                add_event state "system" ("followed " ^ reference))
       | Some "Y" ->
           (match presented_surface_reference () with
            | Some reference ->
                copy_reference_to_terminal render_schedule reference;
                add_event state "system" ("copied " ^ reference)
            | None when state.view = Approvals ->
                answer_presented_approval Confirm
            | None -> add_event state "system" "nothing on this surface has a link")
       | Some "y" ->
           (match state.view with
            | Approvals -> answer_presented_approval Confirm
            | Harness -> handle_harness_agree ()
            | _ -> ())
       (* Stepping the last search is what [n] means on a surface that binds
          it to nothing else, so it is the tail of this arm rather than an
          arm of its own above it. As its own arm it sat above every surface
          that binds the key, and [search_last] is one string for the whole
          session: a surface with row texts and its own [n] would lose that
          key permanently after any search anywhere. Nothing is in that
          position today -- Harness was, and its overrule moved to [x] --
          and this shape is what keeps it that way.

          The match is exhaustive on purpose. A surface added later has to
          say whether [n] is its own key or the search step. *)
       | Some (("n" | "N") as direction) ->
           (match state.view with
            | Approvals -> answer_presented_approval Deny
            | Schedules -> handle_schedule_create ()
            (* The presets pane says [n] is its own key: a new preset from
               the live state, named in the line the pane opens. *)
            | Config when state.config_pane = Config_presets ->
                if state.preset_busy then
                  report_action state "system" "프리셋 작업이 아직 끝나지 않았습니다"
                else begin
                  state.preset_restore_armed <- None;
                  state.preset_save_draft <- Some ""
                end
            | Overview | Acting | Keepers _ | Memory | Lanes | Clients | Board
            | Planning
            | Verification | Harness | Fusion | Repositories | Code | Changes
            | Connectors | Runtime | Config | Resources | Tools | System_logs ->
                if
                  state.search_last <> ""
                  && Option.is_some (surface_row_texts state state.view)
                then
                  let after =
                    Option.value (search_row_cursor state) ~default:0
                  in
                  search_jump state ~query:state.search_last ~after
                    ~backwards:(String.equal direction "N"))
       | Some "home" when state.view = Tools -> state.tools_scroll <- 0
       | Some "end" when state.view = Tools ->
           state.tools_scroll <-
             move_surface_to_end state ~rows:(surface_rows state)
               ~current:state.tools_scroll
       | Some ("pageup" | "pagedown") ->
           let page = surface_page_rows state in
           let direction = if key = Some "pagedown" then 1 else -1 in
           (match state.view with
            (* Themes take no page key. Applying a scheme used to live here,
               where the footer never said it was and where PageDown is a
               scroll everywhere else. It answers to Enter now, which is what
               the footer has been advertising. *)
            | Config when state.config_pane = Config_themes -> ()
            | Code when state.repository_changes_open ->
                let cursor, scroll =
                  move_row_cursor state ~delta:(direction * page)
                    ~cursor:state.repository_changes_cursor
                    ~scroll:state.repository_changes_scroll
                in
                state.repository_changes_cursor <- cursor;
                state.repository_changes_scroll <- scroll
            | Code -> ()
            | Board ->
                (match state.board_mode with
                 | Board_list ->
                     let count = List.length state.board_posts in
                     state.board_cursor <-
                       max 0
                         (min (count - 1) (state.board_cursor + (direction * page)))
                 | Board_read _ ->
                     (match state.board_focus with
                      | Left_pane ->
                          move_board_posts_pane state ~mailbox:async_messages
                            ~delta:(direction * page)
                      | Right_pane ->
                          state.board_scroll <-
                            max 0 (state.board_scroll + (direction * page)))
                 | Board_compose -> ())
            | Fusion ->
                (match state.fusion_mode with
                 | Fusion_list ->
                     let count =
                       match state.fusion_runs with
                       | None -> 0
                       | Some snapshot -> List.length snapshot.fus_runs
                     in
                     state.fusion_cursor <-
                       max 0
                         (min (count - 1) (state.fusion_cursor + (direction * page)))
                 | Fusion_detail _ ->
                     state.fusion_scroll <-
                       max 0 (state.fusion_scroll + (direction * page)))
            | Schedules ->
                if Option.is_some state.schedule_detail_id then
                  state.schedule_scroll <-
                    max 0 (state.schedule_scroll + (direction * page))
                else
                  let count =
                    match state.schedules with
                    | None -> 0
                    | Some snapshot -> List.length snapshot.scs_rows
                  in
                  state.schedule_cursor <-
                    max 0
                      (min (count - 1)
                         (state.schedule_cursor + (direction * page)))
            | Verification ->
                if Option.is_some state.verification_detail_request_id then
                  state.verification_detail_scroll <-
                    max 0
                      (state.verification_detail_scroll + (direction * page))
                else
                  let cursor, scroll =
                    move_row_cursor state ~delta:(direction * page)
                      ~cursor:state.verification_cursor
                      ~scroll:state.verification_scroll
                  in
                  state.verification_cursor <- cursor;
                  state.verification_scroll <- scroll
            | Harness ->
                if Option.is_some state.harness_detail then
                  state.harness_detail_scroll <-
                    max 0 (state.harness_detail_scroll + (direction * page))
                else
                  let cursor, scroll =
                    move_row_cursor state ~delta:(direction * page)
                      ~cursor:state.harness_cursor ~scroll:state.harness_scroll
                  in
                  state.harness_cursor <- cursor;
                  state.harness_scroll <- scroll
            | Config when state.config_pane = Config_prompts ->
                state.config_scroll <-
                  max 0 (state.config_scroll + (direction * page))
            | Config when state.config_pane = Config_runtime ->
                set_runtime_config_cursor_near state ~direction
                  ~target:(state.runtime_config_cursor + (direction * page))
            | Runtime when Option.is_some state.runtime_detail_target ->
                state.runtime_detail_scroll <-
                  max 0 (state.runtime_detail_scroll + (direction * page))
            | System_logs when Option.is_some state.system_logs_detail_seq ->
                state.system_logs_detail_scroll <-
                  max 0 (state.system_logs_detail_scroll + (direction * page))
            | Keepers Keeper_detail when state.detail_tab = Detail_channels ->
                state.detail_scroll <-
                  max 0 (state.detail_scroll + (direction * page))
            | Keepers Keeper_detail ->
                state.detail_scroll <-
                  max 0 (state.detail_scroll + (direction * page))
             | Clients ->
                 let cursor, scroll =
                   move_row_cursor state ~delta:(direction * page)
                     ~cursor:state.clients_surface_cursor
                     ~scroll:state.clients_surface_scroll
                 in
                 state.clients_surface_cursor <- cursor;
                 state.clients_surface_scroll <- scroll
             | Lanes ->
                (match state.lanes_mode with
                 | Lanes_run_detail _ ->
                     state.lane_run_detail_scroll <-
                       max 0
                         (state.lane_run_detail_scroll + (direction * page))
                 | Lanes_run_list _ ->
                     let count =
                       match state.lane_runs with
                       | None -> 0
                       | Some runs -> List.length runs
                     in
                     state.lane_runs_cursor <-
                       max 0
                         (min (count - 1)
                            (state.lane_runs_cursor + (direction * page)));
                     (* The page jump names a row; the window has to follow
                        or the cursor walks off the frame. j/k get the follow
                        from [move_row_cursor], which only steps a single
                        row. *)
                     (match scrolled_surface state state.view with
                      | None -> ()
                      | Some scrolled ->
                          let height =
                            surface_body_height
                              ~rows:(surface_rows state) scrolled
                          in
                          state.lane_runs_scroll <-
                            Masc_tui_scroll.ensure_visible
                              ~cursor:state.lane_runs_cursor ~height
                              state.lane_runs_scroll)
                 | Lanes_overview -> ())
            | Overview | Acting | Keepers _ | Approvals | Planning
            | Memory | Repositories | Changes | Connectors
            | Runtime | Config | Tools | Resources | System_logs -> ())
       (* On Config, s and t hop to Resources and Tools and r is the global
          refresh, so the pane takes u, twice, for the destructive restore.
          Its save key is n, answered inside the [n] dispatch below, which
          the surface list there requires. *)
       | Some "u" | Some "U"
         when state.view = Config && state.config_pane = Config_presets ->
           (match selected_preset_for_state state with
            | None -> report_action state "error" "되돌릴 프리셋을 고르세요"
            | Some manifest ->
              let name = manifest.Tui_decode.pm_name in
              if state.preset_busy then
                report_action state "system" "프리셋 작업이 아직 끝나지 않았습니다"
              else if state.preset_restore_armed = Some name then begin
                state.preset_restore_armed <- None;
                state.preset_busy <- true;
                report_action state "system" (name ^ " 복원 중 · 지금 상태는 먼저 저장됩니다");
                launch_preset_call state ~mailbox:async_messages
                  ~call:(fun ~host ~port -> Masc_tui_loader.restore_preset ~host ~port ~name)
                  ~wrap:(fun result -> Preset_restored (Preset_to_pane, result))
              end
              else begin
                state.preset_restore_armed <- Some name;
                report_action state "system"
                  (Printf.sprintf "u 를 한 번 더 누르면 %s 로 되돌립니다" name)
              end)
       | Some "r" | Some "R" ->
           state.pending_approval_action <- None;
           load_local_workspace_if_safe state base_path;
           let host = server_peer_host in
           let port = state.port in
           start_http_refresh state ~host ~port ~intent:Revalidate
             ~refresh_inflight:http_refresh_inflight
             ~scoped_refresh_inflight:http_scoped_refresh_inflight
             ~scoped_refresh_followup
             ~mailbox:async_messages;
           (* Also reload logs / Board detail if viewing them. *)
           (match state.view with
            | Code ->
                if state.repository_changes_open then
                  refresh_repository_changes state ~mailbox:async_messages
                else launch_code_entries_load state ~mailbox:async_messages
            | Keepers Keeper_list ->
                launch_keeper_lanes_load state ~mailbox:async_messages
            | Keepers Keeper_logs ->
                load_keeper_logs_if_safe state base_path 200
                  (List.nth_opt state.keepers state.keeper_cursor)
            | Keepers Keeper_calls ->
                (match selected_keeper state with
                 | Some keeper ->
                     launch_keeper_calls_load ~force:true state
                       ~mailbox:async_messages
                       keeper.k_name
                 | None -> ())
            | Keepers Keeper_detail ->
                refresh_keeper_detail_selection state ~base_path
                  ~mailbox:async_messages
            | Board ->
                (match state.board_mode with
                 | Board_read post_id ->
                     start_board_post_refresh state ~host ~port ~post_id
                       ~mailbox:async_messages
                 | Board_list | Board_compose -> ())
            | Keepers Keeper_message ->
                (match state.msg_target_keeper_name with
                 | Some keeper_name ->
                     launch_keeper_history_load ~load_file_changes:false state
                       ~mailbox:async_messages ~keeper_name;
                     launch_keeper_chat_tool_details_load ~force:true state
                       ~mailbox:async_messages ~keeper_name
                 | None -> ())
            | Planning | Verification ->
                launch_verification_load state ~mailbox:async_messages
             | Clients ->
                 launch_clients_load state ~mailbox:async_messages
             | Lanes ->
                launch_lanes_load state ~mailbox:async_messages;
                (match state.lanes_mode with
                 | Lanes_run_list lane_id ->
                     launch_lane_runs_load state ~mailbox:async_messages
                       ~lane_id
                 | Lanes_run_detail (_, run_id) ->
                     launch_lane_run_detail_load state ~mailbox:async_messages
                       ~run_id
                 | Lanes_overview -> ())
            | Harness -> launch_harness_load state ~mailbox:async_messages
            | Fusion ->
                launch_fusion_runs_load state ~mailbox:async_messages;
                (match state.fusion_mode with
                 | Fusion_list -> ()
                 | Fusion_detail run_id ->
                     launch_fusion_detail_load state ~mailbox:async_messages
                       ~run_id)
            | Memory ->
                launch_memory_health_load state ~mailbox:async_messages;
                (match state.memory_facts_keeper with
                 | Some keeper_name ->
                     launch_memory_facts_load state ~mailbox:async_messages
                       ~keeper_name
                 | None -> ())
            | Repositories ->
                if state.repository_changes_open then
                  refresh_repository_changes state ~mailbox:async_messages
                else launch_repositories_load state ~mailbox:async_messages
            | Changes -> (
                match state.changes_keeper with
                | Some keeper_name ->
                    launch_file_changes_load state ~mailbox:async_messages
                      ~keeper_name
                | None -> ())
            | Connectors -> launch_connectors_load state ~mailbox:async_messages
            | Runtime ->
                launch_runtime_surface_load state ~mailbox:async_messages
                  ~force:true
            | Tools -> launch_tools_load state ~mailbox:async_messages
            | Config ->
                launch_runtime_config_load state ~mailbox:async_messages
            | Resources ->
                launch_resources_list state ~mailbox:async_messages
            | Schedules -> launch_schedules_load state ~mailbox:async_messages
            | Keepers Keeper_runtime_pick ->
                launch_runtime_catalog_load state ~mailbox:async_messages
            | Overview | Acting | Approvals | System_logs -> ());
           add_event state "system" "Manual refresh"
       | Some "\t" | Some "shift-tab" ->
           cycle_surface state ~mailbox:async_messages
             ~backwards:(key = Some "shift-tab")
       (* A followed reference is the outermost thing Esc can return from, and
          the only one that knows a destination other than this surface's own
          default. Checked before the per-surface arms because those answer
          "leave this screen" with a fixed answer, and this one has the
          reader's actual origin. A surface with its own inner state to close
          -- an open detail, a preview -- is not reached this way: the follow
          landed on the row, and closing the row first would need two presses
          to undo one. *)
       | Some "esc" when Option.is_some state.followed_from ->
           (match state.followed_from with
            | None -> ()
            | Some (origin, _) ->
                state.followed_from <- None;
                goto_surface state ~mailbox:async_messages origin;
                add_event state "system" "back")
       | Some "esc" ->
           (* Esc goes back *)
           (* A running preview is the innermost thing Esc can go back from:
              the reader is looking at a scheme they have not picked, and the
              way out is the one they walked in with. Without this the preview
              is not a preview -- moving the cursor would be a decision. *)
           (match state.view with
            | Config
              when state.config_pane = Config_themes
                   && state.theme_before_preview <> None ->
                cancel_theme_preview ()
            | Code ->
                if state.repository_changes_open then
                  close_repository_changes state
                else if state.code_notes_open then state.code_notes_open <- false
                else if state.code_diff_open then state.code_diff_open <- false
                else if state.code_history_open then
                  state.code_history_open <- false
                else if state.code_focus_file = Right_pane then
                  state.code_focus_file <- Left_pane
                else if not (String.equal state.code_dir "") then begin
                  (* Up one directory; "." from Filename.dirname means the
                     root, which this surface spells "". *)
                  let parent = Filename.dirname state.code_dir in
                  state.code_dir <-
                    (if String.equal parent "." then "" else parent);
                  state.code_cursor <- 0;
                  state.code_entries <- [];
                  state.code_entries_error <- None;
                  launch_code_entries_load state ~mailbox:async_messages
                end
                else if state.code_scope <> Code_scope_project then begin
                  (* Above a keeper's or a repository's root sits the
                     project tree the surface started on. *)
                  state.code_scope <- Code_scope_project;
                  state.code_cursor <- 0;
                  state.code_entries <- [];
                  state.code_entries_error <- None;
                  launch_code_entries_load state ~mailbox:async_messages
                end
                else
                  (* Off-ring child: the way out of the project root is the
                     ring parent, loaded, same as Connectors and Lanes. *)
                  goto_surface state ~mailbox:async_messages Repositories
            | Keepers Keeper_detail ->
                state.view <- Keepers Keeper_list;
                state.detail_scroll <- 0
            | Keepers Keeper_runtime_pick ->
                state.runtime_pick_keeper <- None;
                state.runtime_pick_cursor <- 0;
                state.view <- Keepers Keeper_list
            | Keepers Keeper_logs ->
                state.view <- Keepers Keeper_detail;
                state.keeper_detail_focus <- Right_pane;
                state.log_scroll <- 0;
                state.detail_scroll <- 0
            | Keepers Keeper_calls ->
                state.view <- Keepers Keeper_detail;
                state.keeper_detail_focus <- Right_pane;
                state.keeper_calls_scroll <- 0;
                state.detail_scroll <- 0
            (* Esc on this surface never arrives here: the composer takes it
               first ([handle_message_key], which the dispatch above routes
               every key to while the chat is open) and answers it there,
               interrupt included. *)
            | Keepers Keeper_message -> ()
            | Board ->
                (match state.board_mode with
                 | Board_read _ ->
                     leave_board_detail state
                 | Board_list -> state.view <- Overview
                 | Board_compose -> ())
            | Planning ->
                (match state.planning_mode with
                 | Planning_detail _ ->
                     state.planning_mode <- Planning_list;
                     state.planning_scroll <- 0
                 | Planning_list -> state.view <- Overview)
            | Fusion ->
                (match state.fusion_mode with
                 | Fusion_detail _ ->
                     state.fusion_mode <- Fusion_list;
                     state.fusion_scroll <- 0;
                     state.fusion_detail <- None;
                     state.fusion_detail_error <- None;
                     state.fusion_detail_generation <-
                       state.fusion_detail_generation + 1
                 | Fusion_list ->
                     goto_surface state ~mailbox:async_messages Planning)
            | Overview ->
                (* Back out one level: an open task detail closes to the panel,
                   a focused task panel hands j/k back to the event log. *)
                if Option.is_some state.task_detail_id then begin
                  state.task_detail_id <- None;
                  state.task_detail_scroll <- 0
                end
                else state.task_focus <- Left_pane
            | Schedules ->
                if Option.is_some state.schedule_detail_id then begin
                  state.schedule_detail_id <- None;
                  state.schedule_scroll <- 0
                end
                else goto_surface state ~mailbox:async_messages Planning
            | Verification ->
                if Option.is_some state.verification_detail_request_id then begin
                  state.verification_detail_request_id <- None;
                  state.verification_detail_scroll <- 0
                end
                else goto_surface state ~mailbox:async_messages Planning
            | Harness ->
                if Option.is_some state.harness_detail then begin
                  state.harness_detail <- None;
                  state.harness_detail_scroll <- 0
                end
                else goto_surface state ~mailbox:async_messages Planning
            | Resources ->
                if state.resource_focus = Right_pane then
                  state.resource_focus <- Left_pane
                else
                  (* Off-ring child: the way out of the list is the ring
                     parent, loaded, same as Connectors and Code. *)
                  goto_surface state ~mailbox:async_messages Config
             | Clients ->
                 (* Off-ring child: the way out is the ring parent, loaded,
                    the same exit Resources takes to Config. *)
                 goto_surface state ~mailbox:async_messages Runtime
             | Lanes ->
                state.lanes_action_error <- None;
                (match state.lanes_mode with
                 | Lanes_run_detail (lane_id, _) ->
                     state.lanes_mode <- Lanes_run_list lane_id;
                     state.lane_run_detail <- None;
                     state.lane_run_detail_error <- None;
                     state.lane_run_detail_scroll <- 0
                 | Lanes_run_list _ ->
                     state.lanes_mode <- Lanes_overview;
                     state.lane_runs <- None;
                     state.lane_runs_error <- None;
                     state.lane_runs_cursor <- 0;
                     state.lane_runs_scroll <- 0
                 | Lanes_overview ->
                     (* Back to the Runtime parent it hangs off, loaded. *)
                     goto_surface state ~mailbox:async_messages Runtime)
            | Acting | Keepers Keeper_list -> state.view <- Overview
            | Approvals ->
                (* Esc leaves the ask and returns to the list with the cursor
                   where it was, the way the Changes diff does. *)
                if state.approval_detail_open then begin
                  state.approval_detail_open <- false;
                  state.approval_detail_scroll <- 0
                end
                else state.view <- Overview
            | Changes ->
                (* Esc closes the open diff and leaves the list where it was,
                   so the row an operator was reading is still under the
                   cursor when they come back. *)
                if
                  Option.is_some state.changes_diff_row
                  || Option.is_some state.changes_tree_diff_path
                then begin
                  state.changes_diff_row <- None;
                  state.changes_diff_scroll <- 0;
                  state.changes_tree_diff <- None;
                  state.changes_tree_diff_error <- None;
                  state.changes_tree_diff_path <- None
                end
                else
                  (* Changes opens from a keeper surface, so Esc goes back to
                     the one it was opened from rather than to Overview. The
                     detail draws whoever the roster cursor names, and the
                     roster can shrink while this surface is up: with nobody
                     under the cursor the detail has nothing to draw, so the
                     way back is the roster. The chat pane demotes its own
                     return for the same reason. *)
                  state.view <-
                    (match state.changes_return, selected_keeper state with
                     | Changes_return_detail, Some _ -> Keepers Keeper_detail
                     | Changes_return_detail, None
                     | Changes_return_list, (Some _ | None) ->
                         Keepers Keeper_list)
            | Repositories ->
                if state.repository_changes_open then
                  close_repository_changes state
                else state.view <- Overview
            | Runtime ->
                if Option.is_some state.runtime_detail_target then begin
                  state.runtime_detail_target <- None;
                  state.runtime_detail_scroll <- 0
                end
                else state.view <- Overview
            | System_logs ->
                if Option.is_some state.system_logs_detail_seq then begin
                  state.system_logs_detail_seq <- None;
                  state.system_logs_detail_scroll <- 0
                end
                else
                  (* Off-ring child: the way out of the list is Activity,
                     the ring parent, same as the other hang-offs. *)
                  goto_surface state ~mailbox:async_messages Acting
            | Connectors -> state.view <- Keepers Keeper_detail
            | Memory ->
                if Option.is_some state.memory_facts_keeper then begin
                  (* Close the fact browser back to the health table. The
                     listing is dropped with it: facts are cheap to re-ask
                     and a kept copy would redraw stale rows on reopen. *)
                  state.memory_facts_keeper <- None;
                  state.memory_facts <- None;
                  state.memory_facts_error <- None;
                  state.memory_facts_cursor <- 0;
                  state.memory_facts_scroll <- 0;
                  state.memory_facts_category <- None
                end
                else state.view <- Overview
            | Tools ->
                (* Off-ring child: back to the parent that opened it. *)
                goto_surface state ~mailbox:async_messages Config
            | Config -> state.view <- Overview)
       | Some "left" ->
           (* Left is the non-destructive structural back key. Unlike Esc it
              never interrupts a live chat turn; it only closes a detail the
              matching Right key can open. *)
           (match state.view with
            | Code ->
                if state.repository_changes_open then
                  close_repository_changes state
                else if state.code_notes_open then state.code_notes_open <- false
                else if state.code_diff_open then state.code_diff_open <- false
                else if state.code_history_open then
                  state.code_history_open <- false
                else if state.code_focus_file = Right_pane then
                  state.code_focus_file <- Left_pane
                else if not (String.equal state.code_dir "") then begin
                  let parent = Filename.dirname state.code_dir in
                  state.code_dir <-
                    (if String.equal parent "." then "" else parent);
                  state.code_cursor <- 0;
                  state.code_entries <- [];
                  state.code_entries_error <- None;
                  launch_code_entries_load state ~mailbox:async_messages
                end
                else if state.code_scope <> Code_scope_project then begin
                  state.code_scope <- Code_scope_project;
                  state.code_cursor <- 0;
                  state.code_entries <- [];
                  state.code_entries_error <- None;
                  launch_code_entries_load state ~mailbox:async_messages
                end
            | Keepers Keeper_detail ->
                state.view <- Keepers Keeper_list;
                state.detail_scroll <- 0
            | Keepers Keeper_logs | Keepers Keeper_calls ->
                state.view <- Keepers Keeper_detail;
                state.keeper_detail_focus <- Right_pane;
                state.log_scroll <- 0;
                state.keeper_calls_scroll <- 0;
                state.detail_scroll <- 0
            | Board ->
                (match state.board_mode with
                 | Board_read _ -> leave_board_detail state
                 | Board_list | Board_compose -> ())
            | Planning ->
                (match state.planning_mode with
                 | Planning_detail _ ->
                     state.planning_mode <- Planning_list;
                     state.planning_scroll <- 0
                 | Planning_list -> ())
            | Fusion ->
                (match state.fusion_mode with
                 | Fusion_detail _ ->
                     state.fusion_mode <- Fusion_list;
                     state.fusion_scroll <- 0;
                     state.fusion_detail <- None;
                     state.fusion_detail_error <- None;
                     state.fusion_detail_generation <-
                       state.fusion_detail_generation + 1
                 | Fusion_list -> ())
            | Overview ->
                if Option.is_some state.task_detail_id then begin
                  state.task_detail_id <- None;
                  state.task_detail_scroll <- 0
                end
                else state.task_focus <- Left_pane
            | Schedules ->
                state.schedule_detail_id <- None;
                state.schedule_scroll <- 0
            | Verification ->
                state.verification_detail_request_id <- None;
                state.verification_detail_scroll <- 0
            | Harness ->
                state.harness_detail <- None;
                state.harness_detail_scroll <- 0
            | Resources -> state.resource_focus <- Left_pane
            | Repositories when state.repository_changes_open ->
                close_repository_changes state
            | Changes ->
                state.changes_diff_row <- None;
                state.changes_diff_scroll <- 0;
                state.changes_tree_diff <- None;
                state.changes_tree_diff_error <- None;
                state.changes_tree_diff_path <- None
            | Lanes ->
                (* Left closes a drill-down level but never leaves the surface;
                   Esc owns leaving it. *)
                (match state.lanes_mode with
                 | Lanes_run_detail (lane_id, _) ->
                     state.lanes_mode <- Lanes_run_list lane_id;
                     state.lane_run_detail <- None;
                     state.lane_run_detail_error <- None;
                     state.lane_run_detail_scroll <- 0
                 | Lanes_run_list _ ->
                     state.lanes_mode <- Lanes_overview;
                     state.lane_runs <- None;
                     state.lane_runs_error <- None;
                     state.lane_runs_cursor <- 0;
                     state.lane_runs_scroll <- 0
                 | Lanes_overview -> ())
            | Runtime ->
                state.runtime_detail_target <- None;
                state.runtime_detail_scroll <- 0
            | System_logs ->
                state.system_logs_detail_seq <- None;
                state.system_logs_detail_scroll <- 0
            | Keepers Keeper_runtime_pick | Keepers Keeper_message
            | Keepers Keeper_list | Acting | Approvals
             | Memory | Repositories | Connectors | Config | Tools | Clients -> ())
       | Some "j" | Some "down" | Some "wheel-down" ->
           (match state.view with
            | Code ->
                if state.repository_changes_open then
                  let cursor, scroll =
                    move_row_cursor state ~delta:1
                      ~cursor:state.repository_changes_cursor
                      ~scroll:state.repository_changes_scroll
                  in
                  state.repository_changes_cursor <- cursor;
                  state.repository_changes_scroll <- scroll
                else if state.code_focus_file = Right_pane then (
                  if state.code_notes_open then (
                    match state.code_notes with
                    | Some (_, notes) ->
                        state.code_notes_scroll <-
                          min
                            (max 0 (List.length notes - 1))
                            (state.code_notes_scroll + 1)
                    | None -> ())
                  else if state.code_diff_open then (
                    match state.code_diff with
                    | Some (_, diff) ->
                        state.code_diff_scroll <-
                          min
                            (max 0
                               (List.length diff.Masc.Tui_decode.gd_rows - 1))
                            (state.code_diff_scroll + 1)
                    | None -> ())
                  else if state.code_history_open then (
                    match state.code_history with
                    | Some (_, listing) ->
                        state.code_history_scroll <-
                          min
                            (max 0 (List.length listing.chl_entries - 1))
                            (state.code_history_scroll + 1)
                    | None -> ())
                  else
                    match state.code_file with
                    | Some (_, rows) ->
                        let cursor =
                          Masc_tui_scroll.cursor_down
                            ~count:(List.length rows)
                            state.code_file_cursor
                        in
                        state.code_file_cursor <- cursor;
                        state.code_file_scroll <-
                          Masc_tui_scroll.ensure_visible ~cursor
                            ~height:(Masc_tui_render.code_pane_content_height state)
                            state.code_file_scroll
                    | None -> ())
                else
                  state.code_cursor <-
                    Masc_tui_scroll.cursor_down
                      ~count:(List.length state.code_entries)
                      state.code_cursor
            | Keepers Keeper_list ->
                if state.keeper_cursor < List.length state.keepers - 1 then begin
                  state.keeper_cursor <- state.keeper_cursor + 1;
                  (match List.nth_opt state.keepers state.keeper_cursor with
                   | Some k -> load_live_context_if_safe state base_path k
                   | None -> ())
                end
            | Keepers Keeper_detail ->
                if
                  Masc_tui_roster_pane.arrows_go_left
                    ~hidden:state.roster_pane_hidden ~cols:terminal_columns
                    ~preferring_left:(state.keeper_detail_focus = Left_pane)
                then begin
                  state.keeper_cursor <-
                    Masc_tui_scroll.cursor_down
                      ~count:(List.length state.keepers)
                      state.keeper_cursor;
                  state.detail_scroll <- 0;
                  refresh_keeper_detail_selection state ~base_path
                    ~mailbox:async_messages
                end
                else if state.detail_tab = Detail_identity then
                  move_identity_cursor state ~delta:1
                else if state.detail_tab = Detail_channels then begin
                  let count =
                    match state.connectors with
                    | None -> 0
                    | Some snapshot -> List.length snapshot.cs_connectors
                  in
                  state.connectors_cursor <-
                    Masc_tui_scroll.cursor_down ~count state.connectors_cursor;
                  state.connectors_binding_cursor <- 0;
                  state.detail_scroll <- 0
                end
                else state.detail_scroll <- state.detail_scroll + 1
            | Keepers Keeper_logs ->
                state.log_scroll <-
                  Metrics_tail.scroll_down
                    ~entry_count:(List.length state.log_entries)
                    ~content_height:(keeper_log_content_height state)
                    state.log_scroll
            | Keepers Keeper_calls ->
                state.keeper_calls_scroll <- state.keeper_calls_scroll + 1
            | Config when state.config_pane = Config_themes ->
                let last = List.length (Masc_tui_theme_choice.entries ()) - 1 in
                state.theme_cursor <- min (max 0 last) (state.theme_cursor + 1);
                preview_theme_under_cursor ()
            | Config when state.config_pane = Config_presets ->
                let count = List.length (preset_rows_for_state state) in
                if state.presets_cursor < count - 1 then begin
                  state.presets_cursor <- state.presets_cursor + 1;
                  state.config_scroll <- 0;
                  state.preset_restore_armed <- None
                end
            | Config when state.config_pane = Config_prompts ->
                let count = prompt_catalog_count_for_state state in
                if state.prompts_cursor < count - 1 then begin
                  state.prompts_cursor <- state.prompts_cursor + 1;
                  state.config_scroll <- 0;
                  state.prompts_librarian_input <- None;
                  state.prompts_librarian_input_error <- None;
                  state.prompts_librarian_input_loading <- false
                end
            | Config when state.config_pane = Config_params ->
                state.runtime_params_cursor <-
                  min
                    (max 0 (List.length state.runtime_params - 1))
                    (state.runtime_params_cursor + 1);
                state.runtime_params_notice <- None
            | Approvals when state.approval_detail_open ->
                state.approval_detail_scroll <- state.approval_detail_scroll + 1
            | Approvals ->
                let count = List.length (approval_items state) in
                if state.approval_cursor < count - 1 then begin
                  state.pending_approval_action <- None;
                  state.approval_cursor <- state.approval_cursor + 1
                end
            | Board ->
                (match state.board_mode with
                 | Board_list ->
                     if state.board_cursor < List.length state.board_posts - 1 then
                       state.board_cursor <- state.board_cursor + 1
                 | Board_read _ ->
                     (match state.board_focus with
                      | Left_pane ->
                          move_board_posts_pane state ~mailbox:async_messages
                            ~delta:1
                      | Right_pane ->
                          state.board_scroll <- state.board_scroll + 1)
                 | Board_compose -> ())
            | Planning ->
                (match state.planning_mode with
                 | Planning_list ->
                     let goals =
                       match state.planning with
                       | None -> []
                       | Some p ->
                           planning_visible_goals ~filter:state.planning_filter
                             ~sort:state.planning_sort p.pl_goals
                     in
                     if state.planning_cursor < List.length goals - 1 then
                       state.planning_cursor <- state.planning_cursor + 1
                 | Planning_detail _ ->
                     state.planning_scroll <- state.planning_scroll + 1)
            | Fusion ->
                (match state.fusion_mode with
                 | Fusion_list ->
                     let count =
                       match state.fusion_runs with
                       | None -> 0
                       | Some snapshot -> List.length snapshot.fus_runs
                     in
                     if state.fusion_cursor < count - 1 then
                       state.fusion_cursor <- state.fusion_cursor + 1
                 | Fusion_detail _ ->
                     state.fusion_scroll <- state.fusion_scroll + 1)
            | Schedules ->
                if Option.is_some state.schedule_detail_id then
                  state.schedule_scroll <- state.schedule_scroll + 1
                else
                  let count =
                    match state.schedules with
                    | None -> 0
                    | Some snapshot -> List.length snapshot.scs_rows
                  in
                  if state.schedule_cursor < count - 1 then
                    state.schedule_cursor <- state.schedule_cursor + 1
            | Overview ->
                if Option.is_some state.task_detail_id then
                  state.task_detail_scroll <- state.task_detail_scroll + 1
                else if state.task_focus = Right_pane then begin
                  if state.task_cursor < List.length state.tasks - 1 then
                    state.task_cursor <- state.task_cursor + 1
                end
                else begin
                  let _, _, row_budget =
                    overview_layout state ~terminal_rows:(surface_rows state)
                  in
                  state.overview_event_scroll <-
                    Render_schedule.scroll_overview_events_older
                      ~event_count:
                        (List.length
                           (Render_schedule.collapse_consecutive
                              ~key:Masc_tui_types.overview_event_collapse_key
                              state.events))
                      ~visible_rows:row_budget.attention_rows
                      state.overview_event_scroll
                end
            | Verification ->
                if Option.is_some state.verification_detail_request_id then
                  state.verification_detail_scroll <-
                    state.verification_detail_scroll + 1
                else
                  (let cursor, scroll =
                     move_row_cursor state ~delta:1
                       ~cursor:state.verification_cursor
                       ~scroll:state.verification_scroll
                   in
                   state.verification_cursor <- cursor;
                   state.verification_scroll <- scroll)
            | Clients ->
                let cursor, scroll =
                  move_row_cursor state ~delta:1
                    ~cursor:state.clients_surface_cursor
                    ~scroll:state.clients_surface_scroll
                in
                state.clients_surface_cursor <- cursor;
                state.clients_surface_scroll <- scroll
            | Lanes ->
                (match state.lanes_mode with
                 | Lanes_run_detail _ ->
                     state.lane_run_detail_scroll <-
                       state.lane_run_detail_scroll + 1
                 | Lanes_run_list _ ->
                     (let cursor, scroll =
                        move_row_cursor state ~delta:1
                          ~cursor:state.lane_runs_cursor
                          ~scroll:state.lane_runs_scroll
                      in
                     state.lane_runs_cursor <- cursor;
                     state.lane_runs_scroll <- scroll)
                 | Lanes_overview ->
                     let count = lanes_standalone_count state in
                     state.lanes_action_error <- None;
                     state.lanes_standalone_cursor <-
                       max 0
                         (min (count - 1)
                            (state.lanes_standalone_cursor + 1)))
            | Harness ->
                if Option.is_some state.harness_detail then
                  state.harness_detail_scroll <- state.harness_detail_scroll + 1
                else
                  (let cursor, scroll =
                     move_row_cursor state ~delta:1
                       ~cursor:state.harness_cursor ~scroll:state.harness_scroll
                   in
                   state.harness_cursor <- cursor;
                   state.harness_scroll <- scroll)
            | Memory ->
                if Option.is_some state.memory_facts_keeper then begin
                  let cursor, scroll =
                    move_row_cursor state ~delta:1
                      ~cursor:state.memory_facts_cursor
                      ~scroll:state.memory_facts_scroll
                  in
                  state.memory_facts_cursor <- cursor;
                  state.memory_facts_scroll <- scroll
                end
                else begin
                  let cursor, scroll =
                    move_row_cursor state ~delta:1
                      ~cursor:state.memory_health_cursor
                      ~scroll:state.memory_health_scroll
                  in
                  state.memory_health_cursor <- cursor;
                  state.memory_health_scroll <- scroll
                end
            | Repositories ->
                if state.repository_changes_open then
                  let cursor, scroll =
                    move_row_cursor state ~delta:1
                      ~cursor:state.repository_changes_cursor
                      ~scroll:state.repository_changes_scroll
                  in
                  state.repository_changes_cursor <- cursor;
                  state.repository_changes_scroll <- scroll
                else
                  let cursor, scroll =
                    move_row_cursor state ~delta:1
                      ~cursor:state.repositories_cursor
                      ~scroll:state.repositories_scroll
                  in
                  state.repositories_cursor <- cursor;
                  state.repositories_scroll <- scroll
            | Changes -> (
                (* An open diff owns the scroll keys: the list is behind it and
                   moving both would put the cursor somewhere the operator
                   cannot see. *)
                match state.changes_diff_row with
                | Some _ ->
                    state.changes_diff_scroll <- state.changes_diff_scroll + 1
                | None ->
                    let cursor, scroll =
                      move_row_cursor state ~delta:1 ~cursor:state.changes_cursor
                        ~scroll:state.changes_scroll
                    in
                    state.changes_cursor <- cursor;
                    state.changes_scroll <- scroll)
            | Connectors ->
                (let cursor, scroll =
                   move_row_cursor state ~delta:(1)
                     ~cursor:state.connectors_cursor ~scroll:state.connectors_scroll
                 in
                 state.connectors_cursor <- cursor;
                 state.connectors_scroll <- scroll)
            | Runtime ->
                if Option.is_some state.runtime_detail_target then
                  state.runtime_detail_scroll <- state.runtime_detail_scroll + 1
                else
                  (let cursor, scroll =
                     move_row_cursor state ~delta:1
                       ~cursor:state.runtime_cursor
                       ~scroll:state.runtime_surface_scroll
                   in
                   state.runtime_cursor <- cursor;
                   state.runtime_surface_scroll <- scroll)
            | Tools -> state.tools_scroll <-
                  move_surface_scroll state ~rows:(surface_rows state) ~delta:(1)
                    ~current:state.tools_scroll
            | Config when state.config_pane = Config_models ->
                (* A cursor, not a bare scroll: [e] acts on a row, so the
                   reader has to be able to say which one. *)
                let last = max 0 (List.length state.config_models_rows - 1) in
                state.config_models_cursor <-
                  min last (state.config_models_cursor + 1);
                state.config_scroll <-
                  move_surface_scroll state ~rows:(surface_rows state) ~delta:1
                    ~current:state.config_scroll
            | Config when state.config_pane = Config_runtime ->
                move_runtime_config_cursor state ~delta:1
            | Config -> state.config_scroll <-
                  move_surface_scroll state ~rows:(surface_rows state) ~delta:1
                    ~current:state.config_scroll
            | Resources ->
                if state.resource_focus = Right_pane then
                  state.resource_scroll <- state.resource_scroll + 1
                else
                  let total =
                    match state.resources_list with
                    | Some rows -> List.length rows
                    | None -> 0
                  in
                  if state.resources_cursor < total - 1 then
                    state.resources_cursor <- state.resources_cursor + 1
            | Acting -> state.acting_scroll <- state.acting_scroll + 1
            | System_logs ->
                if Option.is_some state.system_logs_detail_seq then
                  state.system_logs_detail_scroll <-
                    state.system_logs_detail_scroll + 1
                else
                  (let cursor, scroll =
                     move_row_cursor state ~delta:1
                       ~cursor:state.system_logs_cursor
                       ~scroll:state.system_logs_scroll
                   in
                   state.system_logs_cursor <- cursor;
                   state.system_logs_scroll <- scroll)
            | Keepers Keeper_runtime_pick ->
                let dispatchable =
                  List.length
                    (List.filter
                       (fun (o : Tui_decode.runtime_option) ->
                         o.ro_dispatchable)
                       state.runtime_catalog)
                in
                if state.runtime_pick_cursor < dispatchable - 1 then
                  state.runtime_pick_cursor <- state.runtime_pick_cursor + 1
            | Keepers Keeper_message -> ())
       | Some "k" | Some "up" | Some "wheel-up" ->
           (match state.view with
            | Code ->
                if state.repository_changes_open then
                  let cursor, scroll =
                    move_row_cursor state ~delta:(-1)
                      ~cursor:state.repository_changes_cursor
                      ~scroll:state.repository_changes_scroll
                  in
                  state.repository_changes_cursor <- cursor;
                  state.repository_changes_scroll <- scroll
                else if state.code_focus_file = Right_pane then (
                  if state.code_notes_open then
                    state.code_notes_scroll <-
                      max 0 (state.code_notes_scroll - 1)
                  else if state.code_diff_open then
                    state.code_diff_scroll <-
                      max 0 (state.code_diff_scroll - 1)
                  else if state.code_history_open then
                    state.code_history_scroll <-
                      max 0 (state.code_history_scroll - 1)
                  else
                    match state.code_file with
                    | Some (_, rows) ->
                        let cursor =
                          Masc_tui_scroll.cursor_up
                            ~count:(List.length rows)
                            state.code_file_cursor
                        in
                        state.code_file_cursor <- cursor;
                        state.code_file_scroll <-
                          Masc_tui_scroll.ensure_visible ~cursor
                            ~height:(Masc_tui_render.code_pane_content_height state)
                            state.code_file_scroll
                    | None -> ())
                else
                  state.code_cursor <-
                    Masc_tui_scroll.cursor_up
                      ~count:(List.length state.code_entries)
                      state.code_cursor
            | Keepers Keeper_list ->
                if state.keeper_cursor > 0 then begin
                  state.keeper_cursor <- state.keeper_cursor - 1;
                  (match List.nth_opt state.keepers state.keeper_cursor with
                   | Some k -> load_live_context_if_safe state base_path k
                   | None -> ())
                end
            | Keepers Keeper_detail ->
                if
                  Masc_tui_roster_pane.arrows_go_left
                    ~hidden:state.roster_pane_hidden ~cols:terminal_columns
                    ~preferring_left:(state.keeper_detail_focus = Left_pane)
                then begin
                  state.keeper_cursor <-
                    Masc_tui_scroll.cursor_up
                      ~count:(List.length state.keepers)
                      state.keeper_cursor;
                  state.detail_scroll <- 0;
                  refresh_keeper_detail_selection state ~base_path
                    ~mailbox:async_messages
                end
                else if state.detail_tab = Detail_identity then
                  move_identity_cursor state ~delta:(-1)
                else if state.detail_tab = Detail_channels then begin
                  let count =
                    match state.connectors with
                    | None -> 0
                    | Some snapshot -> List.length snapshot.cs_connectors
                  in
                  state.connectors_cursor <-
                    Masc_tui_scroll.cursor_up ~count state.connectors_cursor;
                  state.connectors_binding_cursor <- 0;
                  state.detail_scroll <- 0
                end
                else if state.detail_scroll > 0 then
                  state.detail_scroll <- state.detail_scroll - 1
            | Keepers Keeper_logs ->
                state.log_scroll <-
                  Metrics_tail.scroll_up
                    ~entry_count:(List.length state.log_entries)
                    ~content_height:(keeper_log_content_height state)
                    state.log_scroll
            | Keepers Keeper_calls ->
                if state.keeper_calls_scroll > 0 then
                  state.keeper_calls_scroll <- state.keeper_calls_scroll - 1
            | Config when state.config_pane = Config_themes ->
                state.theme_cursor <- max 0 (state.theme_cursor - 1);
                preview_theme_under_cursor ()
            | Config when state.config_pane = Config_presets ->
                let next = max 0 (state.presets_cursor - 1) in
                if next <> state.presets_cursor then begin
                  state.presets_cursor <- next;
                  state.config_scroll <- 0;
                  state.preset_restore_armed <- None
                end
            | Config when state.config_pane = Config_prompts ->
                let next = max 0 (state.prompts_cursor - 1) in
                if next <> state.prompts_cursor then begin
                  state.prompts_cursor <- next;
                  state.config_scroll <- 0;
                  state.prompts_librarian_input <- None;
                  state.prompts_librarian_input_error <- None;
                  state.prompts_librarian_input_loading <- false
                end
            | Config when state.config_pane = Config_params ->
                state.runtime_params_cursor <-
                  max 0 (state.runtime_params_cursor - 1);
                state.runtime_params_notice <- None
            | Approvals when state.approval_detail_open ->
                state.approval_detail_scroll <-
                  max 0 (state.approval_detail_scroll - 1)
            | Approvals ->
                if state.approval_cursor > 0 then begin
                  state.pending_approval_action <- None;
                  state.approval_cursor <- state.approval_cursor - 1
                end
            | Board ->
                (match state.board_mode with
                 | Board_list ->
                     if state.board_cursor > 0 then
                       state.board_cursor <- state.board_cursor - 1
                 | Board_read _ ->
                     (match state.board_focus with
                      | Left_pane ->
                          move_board_posts_pane state ~mailbox:async_messages
                            ~delta:(-1)
                      | Right_pane ->
                          if state.board_scroll > 0 then
                            state.board_scroll <- state.board_scroll - 1)
                 | Board_compose -> ())
            | Planning ->
                (match state.planning_mode with
                 | Planning_list ->
                     if state.planning_cursor > 0 then
                       state.planning_cursor <- state.planning_cursor - 1
                 | Planning_detail _ ->
                     if state.planning_scroll > 0 then
                       state.planning_scroll <- state.planning_scroll - 1)
            | Fusion ->
                (match state.fusion_mode with
                 | Fusion_list ->
                     if state.fusion_cursor > 0 then
                       state.fusion_cursor <- state.fusion_cursor - 1
                 | Fusion_detail _ ->
                     if state.fusion_scroll > 0 then
                       state.fusion_scroll <- state.fusion_scroll - 1)
            | Schedules ->
                if Option.is_some state.schedule_detail_id then
                  state.schedule_scroll <- max 0 (state.schedule_scroll - 1)
                else if state.schedule_cursor > 0 then
                  state.schedule_cursor <- state.schedule_cursor - 1
            | Overview ->
                if Option.is_some state.task_detail_id then begin
                  if state.task_detail_scroll > 0 then
                    state.task_detail_scroll <- state.task_detail_scroll - 1
                end
                else if state.task_focus = Right_pane then begin
                  if state.task_cursor > 0 then
                    state.task_cursor <- state.task_cursor - 1
                end
                else begin
                  let _, _, row_budget =
                    overview_layout state ~terminal_rows:(surface_rows state)
                  in
                  state.overview_event_scroll <-
                    Render_schedule.scroll_overview_events_newer
                      ~event_count:
                        (List.length
                           (Render_schedule.collapse_consecutive
                              ~key:Masc_tui_types.overview_event_collapse_key
                              state.events))
                      ~visible_rows:row_budget.attention_rows
                      state.overview_event_scroll
                end
            | Verification ->
                if Option.is_some state.verification_detail_request_id then
                  state.verification_detail_scroll <-
                    max 0 (state.verification_detail_scroll - 1)
                else
                  (let cursor, scroll =
                     move_row_cursor state ~delta:(-1)
                       ~cursor:state.verification_cursor
                       ~scroll:state.verification_scroll
                   in
                   state.verification_cursor <- cursor;
                   state.verification_scroll <- scroll)
            | Clients ->
                let cursor, scroll =
                  move_row_cursor state ~delta:(-1)
                    ~cursor:state.clients_surface_cursor
                    ~scroll:state.clients_surface_scroll
                in
                state.clients_surface_cursor <- cursor;
                state.clients_surface_scroll <- scroll
            | Lanes ->
                (match state.lanes_mode with
                 | Lanes_run_detail _ ->
                     state.lane_run_detail_scroll <-
                       max 0 (state.lane_run_detail_scroll - 1)
                 | Lanes_run_list _ ->
                     (let cursor, scroll =
                        move_row_cursor state ~delta:(-1)
                          ~cursor:state.lane_runs_cursor
                          ~scroll:state.lane_runs_scroll
                      in
                     state.lane_runs_cursor <- cursor;
                     state.lane_runs_scroll <- scroll)
                 | Lanes_overview ->
                     state.lanes_action_error <- None;
                     state.lanes_standalone_cursor <-
                       max 0 (state.lanes_standalone_cursor - 1))
            | Harness ->
                if Option.is_some state.harness_detail then
                  state.harness_detail_scroll <-
                    max 0 (state.harness_detail_scroll - 1)
                else
                  (let cursor, scroll =
                     move_row_cursor state ~delta:(-1)
                       ~cursor:state.harness_cursor ~scroll:state.harness_scroll
                   in
                   state.harness_cursor <- cursor;
                   state.harness_scroll <- scroll)
            | Memory ->
                if Option.is_some state.memory_facts_keeper then begin
                  let cursor, scroll =
                    move_row_cursor state ~delta:(-1)
                      ~cursor:state.memory_facts_cursor
                      ~scroll:state.memory_facts_scroll
                  in
                  state.memory_facts_cursor <- cursor;
                  state.memory_facts_scroll <- scroll
                end
                else begin
                  let cursor, scroll =
                    move_row_cursor state ~delta:(-1)
                      ~cursor:state.memory_health_cursor
                      ~scroll:state.memory_health_scroll
                  in
                  state.memory_health_cursor <- cursor;
                  state.memory_health_scroll <- scroll
                end
            | Repositories ->
                if state.repository_changes_open then
                  let cursor, scroll =
                    move_row_cursor state ~delta:(-1)
                      ~cursor:state.repository_changes_cursor
                      ~scroll:state.repository_changes_scroll
                  in
                  state.repository_changes_cursor <- cursor;
                  state.repository_changes_scroll <- scroll
                else
                  let cursor, scroll =
                    move_row_cursor state ~delta:(-1)
                      ~cursor:state.repositories_cursor
                      ~scroll:state.repositories_scroll
                  in
                  state.repositories_cursor <- cursor;
                  state.repositories_scroll <- scroll
            | Changes -> (
                match state.changes_diff_row with
                | Some _ ->
                    state.changes_diff_scroll <-
                      max 0 (state.changes_diff_scroll - 1)
                | None ->
                    let cursor, scroll =
                      move_row_cursor state ~delta:(-1)
                        ~cursor:state.changes_cursor
                        ~scroll:state.changes_scroll
                    in
                    state.changes_cursor <- cursor;
                    state.changes_scroll <- scroll)
            | Connectors ->
                (let cursor, scroll =
                   move_row_cursor state ~delta:(-1)
                     ~cursor:state.connectors_cursor ~scroll:state.connectors_scroll
                 in
                 state.connectors_cursor <- cursor;
                 state.connectors_scroll <- scroll)
            | Runtime ->
                if Option.is_some state.runtime_detail_target then
                  state.runtime_detail_scroll <-
                    max 0 (state.runtime_detail_scroll - 1)
                else
                  (let cursor, scroll =
                     move_row_cursor state ~delta:(-1)
                       ~cursor:state.runtime_cursor
                       ~scroll:state.runtime_surface_scroll
                   in
                   state.runtime_cursor <- cursor;
                   state.runtime_surface_scroll <- scroll)
            | Tools ->
                if state.tools_scroll > 0 then
                  state.tools_scroll <-
                  move_surface_scroll state ~rows:(surface_rows state) ~delta:(-1)
                    ~current:state.tools_scroll
            | Config when state.config_pane = Config_models ->
                state.config_models_cursor <-
                  max 0 (state.config_models_cursor - 1);
                if state.config_scroll > 0 then
                  state.config_scroll <-
                  move_surface_scroll state ~rows:(surface_rows state) ~delta:(-1)
                    ~current:state.config_scroll
            | Config when state.config_pane = Config_runtime ->
                move_runtime_config_cursor state ~delta:(-1)
            | Config ->
                if state.config_scroll > 0 then
                  state.config_scroll <-
                  move_surface_scroll state ~rows:(surface_rows state) ~delta:(-1)
                    ~current:state.config_scroll
            | Resources ->
                if state.resource_focus = Right_pane then
                  state.resource_scroll <- max 0 (state.resource_scroll - 1)
                else if state.resources_cursor > 0 then
                  state.resources_cursor <- state.resources_cursor - 1
            | Acting ->
                if state.acting_scroll > 0 then begin
                  state.acting_scroll <- state.acting_scroll - 1;
                  if state.acting_scroll = 0 then state.acting_unseen <- 0
                end
            | System_logs ->
                if Option.is_some state.system_logs_detail_seq then
                  state.system_logs_detail_scroll <-
                    max 0 (state.system_logs_detail_scroll - 1)
                else
                  (let cursor, scroll =
                     move_row_cursor state ~delta:(-1)
                       ~cursor:state.system_logs_cursor
                       ~scroll:state.system_logs_scroll
                   in
                   state.system_logs_cursor <- cursor;
                   state.system_logs_scroll <- scroll)
            | Keepers Keeper_runtime_pick ->
                if state.runtime_pick_cursor > 0 then
                  state.runtime_pick_cursor <- state.runtime_pick_cursor - 1
            | Keepers Keeper_message -> ())
       (* Enter starts the provider the arrows are on. The digits below still
          work for the first nine; past that a number is no longer a key, so
          the cursor is the only way to reach a row. *)
       | Some "\r" | Some "\n"
         when state.view = Keepers Keeper_detail
              && state.detail_tab = Detail_identity -> (
           match (selected_keeper state, state.identity_view) with
           | Some keeper, Some (stamp, providers)
             when String.equal stamp keeper.k_name -> (
               match
                 Masc_tui_types.identity_cursor_provider
                   ~query:(identity_query state) ~providers
                   state.identity_cursor
               with
               | Some (provider_id, label) ->
                   state.identity_login <- None;
                   state.identity_attempt_error <- None;
                   launch_identity_login state ~mailbox:async_messages
                     ~keeper_name:keeper.k_name ~provider_id ~label
               | None -> ())
           | Some _, (Some _ | None) | None, _ -> ())
       | Some "\r" | Some "\n" | Some "right" ->
           (* Enter remains compatible; Right makes list -> detail and Left
              makes detail -> list consistent across the TUI. *)
           (match state.view with
            | Code -> (
                if state.repository_changes_open then
                  (match state.repository_changes, state.repository_changes_scope with
                   | Some snapshot, Some scope ->
                       (match
                          List.nth_opt snapshot.Masc.Tui_decode.rcs_changes
                            state.repository_changes_cursor
                        with
                        | None -> ()
                        | Some change ->
                            open_repository_change_in_code state
                              ~mailbox:async_messages ~scope change)
                   | _ -> ())
                else if state.code_history_open then (
                  (* The top visible row is the selected one, the way the
                     Changes list treats its scroll. A commit answers with
                     its PR; a durable Keeper change jumps to its
                     producer-recorded line without claiming it was
                     committed. *)
                  match state.code_history with
                  | None -> ()
                  | Some (_, listing) -> (
                      match
                        List.nth_opt listing.chl_entries
                          state.code_history_scroll
                      with
                      | None -> ()
                      | Some (Hist_keeper_change change) -> (
                          match state.code_file with
                          | None -> ()
                          | Some (_, rows) ->
                            push_code_jump state;
                            state.code_history_open <- false;
                            let cursor =
                              max 0
                                (min
                                   (Masc.Tui_decode.file_change_target_line change
                                    - 1)
                                   (List.length rows - 1))
                            in
                            state.code_file_cursor <- cursor;
                            state.code_file_scroll <-
                              Masc_tui_scroll.ensure_visible ~cursor
                                ~height:
                                  (Masc_tui_render.code_pane_content_height state)
                                state.code_file_scroll)
                      | Some (Hist_commit row) ->
                          let open Masc.Tui_decode in
                          state.code_lsp_note <-
                            Some
                              (match pr_number_of_subject row.gl_subject with
                               | None ->
                                   Printf.sprintf
                                     "%s: no PR number in this subject"
                                     row.gl_hash
                               | Some number -> (
                                   let remote =
                                     match state.code_scope with
                                     | Code_scope_repo repo_id -> (
                                         match state.repositories with
                                         | None -> None
                                         | Some snapshot ->
                                             Option.map
                                               (fun r -> r.rp_url)
                                               (List.find_opt
                                                  (fun r ->
                                                    String.equal r.rp_id
                                                      repo_id)
                                                  snapshot.rs_repositories))
                                     | Code_scope_keeper _
                                     | Code_scope_project -> None
                                   in
                                   match remote with
                                   | None ->
                                       Printf.sprintf
                                         "#%d -- this scope has no \
                                          registered remote to link into"
                                         number
                                   | Some remote -> (
                                       match
                                         github_pr_url ~remote ~number
                                       with
                                       | Some url -> url
                                       | None ->
                                           Printf.sprintf
                                             "#%d -- the remote is not \
                                              GitHub, so the link shape is \
                                              unknown"
                                             number)))))
                else if state.code_focus_file = Right_pane then ()
                else
                  match List.nth_opt state.code_entries state.code_cursor with
                  | Some node ->
                      if node.Masc.Tui_decode.wt_has_children then begin
                        state.code_dir <- node.Masc.Tui_decode.wt_path;
                        state.code_cursor <- 0;
                        state.code_entries <- [];
                        state.code_entries_error <- None;
                        launch_code_entries_load state
                          ~mailbox:async_messages
                      end
                      else
                        launch_code_file_load state ~mailbox:async_messages
                          ~path:node.Masc.Tui_decode.wt_path
                  | None -> ())
            | Keepers Keeper_runtime_pick ->
                (match state.runtime_pick_keeper with
                 | Some keeper_name ->
                     let options =
                       List.filter
                         (fun (o : Tui_decode.runtime_option) ->
                           o.ro_dispatchable)
                         state.runtime_catalog
                     in
                     (match
                        List.nth_opt options state.runtime_pick_cursor
                      with
                      | Some option ->
                          launch_runtime_assignment_set state
                            ~mailbox:async_messages ~keeper_name
                            ~runtime_id:(Some option.ro_id);
                          state.runtime_pick_keeper <- None;
                          state.runtime_pick_cursor <- 0;
                          state.view <- Keepers Keeper_list
                      | None -> ())
                 | None -> state.view <- Keepers Keeper_list)
            | Overview ->
                (* Only under task focus: Enter while the events own j/k would
                   open whatever row the cursor happens to rest on. *)
                if state.task_focus = Right_pane then
                  (match List.nth_opt state.tasks state.task_cursor with
                   | Some task ->
                       state.task_detail_id <- Some task.id;
                       state.task_detail_scroll <- 0;
                       state.task_history <- None;
                       launch_task_history_load state
                         ~mailbox:async_messages task.id
                   | None -> ())
            | Keepers Keeper_list ->
                (match List.nth_opt state.keepers state.keeper_cursor with
                 | Some keeper ->
                     open_keeper_detail state ~base_path
                       ~mailbox:async_messages keeper
                 | None -> ())
            | Lanes ->
                (match state.lanes_mode with
                 | Lanes_run_list lane_id ->
                     (match state.lane_runs with
                      | Some runs ->
                          (match
                             List.nth_opt runs state.lane_runs_cursor
                           with
                           | Some (run : Tui_decode.lane_run_summary) ->
                               open_lane_run_detail state
                                 ~mailbox:async_messages ~lane_id
                                 ~run_id:run.lrs_run_id
                           | None -> ())
                      | None -> ())
                 | Lanes_run_detail _ -> ()
                 | Lanes_overview ->
                     open_lanes_standalone_selection state
                       ~mailbox:async_messages)
            | Approvals ->
                (* The list draws the ask on one row; this is where the whole
                   thing is readable before [y] answers it. *)
                if List.length (approval_items state) > 0 then begin
                  state.approval_detail_open <- true;
                  state.approval_detail_scroll <- 0
                end
            | Board ->
                (match state.board_mode with
                 | Board_list ->
                     (match List.nth_opt state.board_posts state.board_cursor with
                      | Some p ->
                          open_board_post state ~mailbox:async_messages
                            ~focus:Right_pane p
                      | None -> ())
                 | Board_read _ | Board_compose -> ())
            | Schedules ->
                (match state.schedule_detail_id with
                 | None -> open_schedule_detail state ~mailbox:async_messages
                 | Some _ -> ())
            | Verification ->
                (match state.verification_detail_request_id with
                 | Some _ -> ()
                 | None ->
                     open_verification_detail state ~mailbox:async_messages)
            | Harness ->
                (match state.harness_detail with
                 | None -> open_harness_detail state
                 | Some _ -> ())
            | Planning ->
                (match state.planning_mode with
                 | Planning_list ->
                     open_planning_detail state ~mailbox:async_messages
                 | Planning_detail _ -> ())
            | Fusion ->
                (match state.fusion_mode with
                 | Fusion_list ->
                     open_fusion_detail state ~mailbox:async_messages
                 | Fusion_detail _ -> ())
            | Changes -> (
                (* The row under the cursor, read as the lines it removed and
                   added. Held as an index rather than a copy: a refresh
                   replaces the list, and a copy would keep drawing a change
                   the answer no longer holds. *)
                match state.changes with
                | None -> add_event state "error" "no changes loaded yet"
                | Some snapshot -> (
                    match
                      List.nth_opt snapshot.Masc.Tui_decode.fcs_changes
                        state.changes_cursor
                    with
                    | None ->
                        add_event state "error" "no change under the cursor"
                    | Some _ ->
                        state.changes_diff_row <- Some state.changes_cursor;
                        state.changes_diff_scroll <- 0;
                        state.changes_tree_diff <- None;
                        state.changes_tree_diff_error <- None;
                        state.changes_tree_diff_path <- None))
            | Repositories when state.repository_changes_open -> (
                match state.repository_changes, state.repository_changes_scope with
                | Some snapshot, Some scope ->
                    (match
                       List.nth_opt snapshot.Masc.Tui_decode.rcs_changes
                         state.repository_changes_cursor
                     with
                     | None -> ()
                     | Some change ->
                         open_repository_change_in_code state
                           ~mailbox:async_messages ~scope change)
                | _ -> ())
            | Memory -> (
                match state.memory_facts_keeper with
                | Some _ ->
                    (* The browser's rows are leaves; the detail lines
                       already follow the cursor. *)
                    ()
                | None -> (
                    (* Enter opens what the health row only counts: the
                       keeper's facts themselves. *)
                    match state.memory_health with
                    | None -> ()
                    | Some snapshot -> (
                        match
                          List.nth_opt snapshot.Masc.Tui_decode.mhs_keepers
                            state.memory_health_cursor
                        with
                        | None -> ()
                        | Some keeper ->
                            let keeper_name =
                              keeper.Masc.Tui_decode.mkh_keeper_id
                            in
                            state.memory_facts_keeper <- Some keeper_name;
                            state.memory_facts <- None;
                            state.memory_facts_error <- None;
                            state.memory_facts_cursor <- 0;
                            state.memory_facts_scroll <- 0;
                            state.memory_facts_category <- None;
                            launch_memory_facts_load state
                              ~mailbox:async_messages ~keeper_name)))
            | Repositories -> (
                (* Enter opens the repository's own tree on the Code surface,
                   through the ?repo_id= axis its row already names. *)
                match state.repositories with
                | None -> ()
                | Some snapshot -> (
                    match
                      List.nth_opt
                        snapshot.Masc.Tui_decode.rs_repositories
                        state.repositories_cursor
                    with
                    | None -> ()
                    | Some repo ->
                        state.code_scope <-
                          Code_scope_repo repo.Masc.Tui_decode.rp_id;
                        state.code_dir <- "";
                        state.code_cursor <- 0;
                        state.code_entries <- [];
                        state.code_entries_error <- None;
                        state.code_file <- None;
                        state.code_file_error <- None;
                        state.code_focus_file <- Left_pane;
                        state.view <- Code;
                        launch_code_entries_load state
                          ~mailbox:async_messages))
            | Runtime ->
                (match state.runtime_surface, state.runtime_mode with
                 | Some snapshot, Runtime_lanes ->
                     (match List.nth_opt snapshot.Masc.Tui_decode.rss_candidates
                              state.runtime_cursor with
                      | None -> ()
                      | Some row ->
                          state.runtime_detail_target <-
                            Some
                              (Runtime_lane_candidate
                                 { lane_id = row.rcr_lane_id
                                 ; runtime_id = row.rcr_runtime.ro_id
                                 });
                          state.runtime_detail_scroll <- 0)
                 | Some snapshot, Runtime_all ->
                     (match
                        List.nth_opt
                          snapshot.Masc.Tui_decode.rss_resolved.rrs_runtimes
                          state.runtime_cursor
                      with
                      | None -> ()
                      | Some runtime ->
                          state.runtime_detail_target <-
                            Some
                              (Runtime_catalog_entry
                                 { runtime_id = runtime.ro_id });
                          state.runtime_detail_scroll <- 0)
                 | None, _ -> ())
            | System_logs -> open_selected_system_log state
            | Keepers Keeper_detail | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message
            | Acting
             | Connectors | Config | Resources | Tools | Clients -> ())
       (* Changes reads one keeper's file writes and already binds to the
          roster cursor on entry, so it opens from a keeper surface rather
          than from the Tab ring. Both of them list [f] in their footer and
          both name the keeper with the same cursor; detail listed the key
          with no arm behind it, so the hint was dead there.

          One arm each rather than one arm with a disjunction, because each
          also records where Esc goes back to. *)
       | Some "f" | Some "F" when state.view = Keepers Keeper_list ->
           state.changes_return <- Changes_return_list;
           goto_surface state ~mailbox:async_messages Changes
       | Some "f" | Some "F" when state.view = Keepers Keeper_detail ->
           state.changes_return <- Changes_return_detail;
           goto_surface state ~mailbox:async_messages Changes
       | Some "f" | Some "F" when state.view = Acting ->
           state.acting_filter <- Masc_tui_acting.next_filter state.acting_filter
       | Some "f" | Some "F"
         when state.view = Board && state.board_mode <> Board_compose ->
           (* All, then each hearth the unnarrowed list showed, busiest first,
              then all again. The narrowing is the server's -- see
              [fetch_board] -- so this refetches rather than filtering the
              page in hand. *)
           state.board_hearth <-
             Board_hearth.next ~current:state.board_hearth
               ~census:state.board_hearths;
           state.board_cursor <- 0;
           state.board_mode <- Board_list;
           add_event state "system"
             (match state.board_hearth with
              | None -> "Board: every hearth"
              | Some hearth -> "Board hearth: " ^ hearth);
           start_http_refresh state ~host:server_peer_host ~port:state.port
             ~intent:Revalidate ~refresh_inflight:http_refresh_inflight
             ~scoped_refresh_inflight:http_scoped_refresh_inflight
             ~scoped_refresh_followup ~mailbox:async_messages
       | Some "f" | Some "F" when state.view = Planning ->
           (* Client-side over the loaded goals: no refetch. *)
           state.planning_filter <- next_planning_filter state.planning_filter;
           clamp_planning_cursor state
       | Some "g" when state.view = Acting ->
           state.acting_scroll <- 0;
           state.acting_unseen <- 0
       | Some "g"
         when (match state.view with
               | Keepers Keeper_list | Keepers Keeper_detail -> true
               | _ -> false)
              && state.keeper_cursor < List.length state.keepers ->
           (* Toggle the approval gate for the keeper under the cursor. One
              press: the stance is in-memory and a restart returns it to
              auto, and the event line plus the red roster name say loudly
              what was armed. *)
           let keeper = List.nth state.keepers state.keeper_cursor in
           let mode =
             if List.mem keeper.k_name state.keeper_yolo_names then "auto"
             else "yolo"
           in
           launch_keeper_tool_mode_set state ~mailbox:async_messages
             ~keeper_name:keeper.k_name ~mode
       | Some "u" | Some "U"
         when (match state.view with
               | Keepers Keeper_list -> true
               | Keepers Keeper_detail -> key = Some "U"
               | _ -> false)
              && state.keeper_cursor < List.length state.keepers ->
           (* Open the runtime picker for the keeper under the cursor. The
              catalogue is fetched on open so the list reflects the server
              now, not the last visit. *)
           let keeper = List.nth state.keepers state.keeper_cursor in
           state.runtime_pick_keeper <- Some keeper.k_name;
           state.runtime_pick_cursor <- 0;
           launch_runtime_catalog_load state ~mailbox:async_messages;
           state.view <- Keepers Keeper_runtime_pick
       | Some "d" | Some "D"
         when state.view = Keepers Keeper_runtime_pick ->
           (match state.runtime_pick_keeper with
            | Some keeper_name ->
                launch_runtime_assignment_set state ~mailbox:async_messages
                  ~keeper_name ~runtime_id:None;
                state.runtime_pick_keeper <- None;
                state.runtime_pick_cursor <- 0;
                state.view <- Keepers Keeper_list
            | None -> state.view <- Keepers Keeper_list)
       | Some "d"
         when state.view = Code
              && (state.repository_changes_open
                  || (state.code_scope = Code_scope_project
                      && state.code_focus_file = Left_pane)) ->
           if state.repository_changes_open then
             refresh_repository_changes state ~mailbox:async_messages
           else
             open_repository_changes state ~mailbox:async_messages
               ~scope:Tui_decode.Repository_change_project
       | Some "d" when state.view = Repositories ->
           if state.repository_changes_open then
             refresh_repository_changes state ~mailbox:async_messages
           else
             (match state.repositories with
              | None -> add_event state "error" "no repositories loaded yet"
              | Some snapshot ->
                  (match
                     List.nth_opt snapshot.Masc.Tui_decode.rs_repositories
                       state.repositories_cursor
                   with
                   | None -> add_event state "error" "no repository under the cursor"
                   | Some repo ->
                       let repository_id = repo.Masc.Tui_decode.rp_id in
                       open_repository_changes state ~mailbox:async_messages
                         ~scope:
                           (Tui_decode.Repository_change_repository
                              repository_id)))
       | Some "G" when state.view = Acting ->
           (* Past the end on purpose; the frame clamps it to the last page.
              The held count rather than max_int, because an event arriving
              before that frame adds one to it. *)
           state.acting_scroll <- List.length state.acting
       | Some "t" | Some "T" ->
           (* Focus the Overview task panel. The list is always on screen, but
              j/k belong to the event log until the operator asks for tasks. *)
           (match state.view with
            | Code -> ()
            | Keepers Keeper_runtime_pick -> ()
            | Overview when Option.is_none state.task_detail_id ->
                state.task_focus <-
                  (match state.task_focus with
                   | Left_pane -> Right_pane
                   | Right_pane -> Left_pane);
                if state.task_focus = Left_pane then state.task_cursor <- 0
            | Keepers (Keeper_list | Keeper_detail) ->
                (* Tool calls, from the roster and from detail, the way logs
                   are: the keeper under the cursor is the one asked about. *)
                (match selected_keeper state with
                 | Some keeper ->
                     state.keeper_calls <- None;
                     state.keeper_calls_error <- None;
                     state.keeper_calls_scroll <- 0;
                     launch_keeper_calls_load state ~mailbox:async_messages
                       keeper.k_name;
                     state.view <- Keepers Keeper_calls
                 | None -> ())
            | Overview | Acting | Keepers (Keeper_logs | Keeper_calls | Keeper_message)
            | Lanes | Board | Approvals | Planning | Schedules
            | Memory | Verification | Harness | Fusion | Repositories | Changes | Connectors | Runtime | Config | Resources | Tools | Clients
            | System_logs -> ())
       | Some "d" when state.view = Changes ->
           (* The same file, read from the tree instead of from the log. Two
              keys rather than one view: the log says what the keeper tried to
              write and the tree says what survived, and merging them would
              make both untrue. *)
           (match state.changes with
            | None -> add_event state "error" "no changes loaded yet"
            | Some snapshot -> (
                match
                  List.nth_opt snapshot.Masc.Tui_decode.fcs_changes
                    state.changes_cursor
                with
                | None -> add_event state "error" "no change under the cursor"
                | Some change -> (
                    match change_bundle_relative_path change with
                    | None ->
                        add_event state "error"
                          "this write is outside the playground; the tree \
                           reading needs a path under it"
                    | Some path ->
                        state.changes_diff_row <- Some state.changes_cursor;
                        state.changes_diff_scroll <- 0;
                        state.changes_tree_diff <- None;
                        state.changes_tree_diff_error <- None;
                        state.changes_tree_diff_path <- Some path;
                        launch_git_diff_load state ~mailbox:async_messages
                          ~keeper:(Some change.Masc.Tui_decode.fc_keeper) ~path)))
       | Some "v" | Some "V"
         when state.view = Planning || state.view = Verification
              || state.view = Harness ->
           (* Planning is the parent workspace; [v] walks its child modes
              without putting any of them back on the top-level ring. The
              order is the life of one piece of work: the goals it hangs
              off, the queue waiting for a ruling, and the rulings the judge
              recorded. Wakes and fusion runs left this walk when they became
              tabs of the selected Keeper (RFC-tui-operator-ia section 3.1): they
              belong to one Keeper, not to the fleet's planning workspace. *)
           goto_surface state ~mailbox:async_messages
             (match state.view with
              | Planning -> Verification
              | Verification -> Harness
              | Harness | _ -> Planning)
       | Some "v" when state.view = Changes ->
           (* View the selected change on the Code surface. The clone-relative
              address resolves through the same ?keeper= axis the git-diff
              read uses, so the bytes shown are the keeper's own checkout --
              not a same-named file in the project tree. Absolute-path writes
              have no such address; the row says so instead of guessing. *)
           (match state.changes with
            | None -> add_event state "error" "no changes loaded yet"
            | Some snapshot -> (
                match
                  List.nth_opt snapshot.Masc.Tui_decode.fcs_changes
                    state.changes_cursor
                with
                | None -> add_event state "error" "no change under the cursor"
                | Some change -> (
                    match change_bundle_relative_path change with
                    | None ->
                        add_event state "error"
                          "an absolute-path write has no address in the \
                           keeper's workspace; o opens it in $EDITOR"
                    | Some path ->
                        let keeper = change.Masc.Tui_decode.fc_keeper in
                        state.code_scope <- Code_scope_keeper keeper;
                        let parent = Filename.dirname path in
                        state.code_dir <-
                          (if String.equal parent "." then "" else parent);
                        state.code_entries <- [];
                        state.code_entries_error <- None;
                        state.code_cursor <- 0;
                        state.code_file <- None;
                        state.code_file_error <- None;
                        state.code_focus_file <- Left_pane;
                        state.code_target_line <-
                          Some (Masc.Tui_decode.file_change_target_line change);
                        state.view <- Code;
                        launch_code_entries_load state
                          ~mailbox:async_messages;
                        launch_code_file_load state ~mailbox:async_messages
                          ~path)))
       | Some "o" when state.view = Changes ->
           (* Hand the selected change to the operator's editor. The row is
              the one the list marks, which the arrow keys move. *)
           (match state.changes with
            | None -> add_event state "error" "no changes loaded yet"
            | Some snapshot -> (
                match
                  List.nth_opt snapshot.Masc.Tui_decode.fcs_changes
                    state.changes_cursor
                with
                | None -> add_event state "error" "no change under the cursor"
                | Some change -> (
                    let path = change_absolute_path ~base_path change in
                    if not (Sys.file_exists path) then
                      (* A Docker keeper's bundle is not on this filesystem.
                         Saying so beats opening an empty buffer named after a
                         file that does exist somewhere else. *)
                      add_event state "error"
                        ("not on this machine: " ^ path)
                    else
                      let line = Masc.Tui_decode.file_change_target_line change in
                      let target =
                        { Masc_tui_editor_jump.path; Masc_tui_editor_jump.line }
                      in
                      match Masc_tui_editor_jump.route () with
                      | Masc_tui_editor_jump.No_editor ->
                          add_event state "error"
                            "no editor: run this inside Neovim, or set $EDITOR"
                      | Masc_tui_editor_jump.Remote_neovim { server } -> (
                          (* The editor is already on screen. Nothing here
                             gives up the terminal, so this surface keeps
                             drawing while the buffer opens over there. *)
                          match
                            Masc_tui_editor_jump.send_to_neovim ~server target
                          with
                          | Ok () ->
                              add_event state "system"
                                (Printf.sprintf "opened %s:%d in Neovim" path line)
                          | Error detail -> add_event state "error" detail)
                      | Masc_tui_editor_jump.Terminal_handoff { editor } ->
                          (* No editor to send to, so one is started on this
                             terminal and this surface stands down until it
                             exits -- the same handoff the settings round-trip
                             makes. *)
                          restore_terminal ();
                          let command =
                            Printf.sprintf "%s +%d %s" editor line
                              (Filename.quote path)
                          in
                          let _ : Unix.process_status = Unix.system command in
                          reenter_terminal ();
                          add_event state "system"
                            (Printf.sprintf "closed %s:%d" path line))))
       | Some "c" | Some "C" | Some "x" | Some "X" | Some "o" | Some "O" when state.view = Planning ->
           (* Goal lifecycle, detail only: the list keeps j/k/Enter and the
              letters stay navigation-free there. The first press arms, the
              same press submits; the server owns the phase rules. *)
           let action =
             match key with
             | Some ("c" | "C") -> Goal_phase.Public_action.Request_complete
             | Some ("x" | "X") -> Goal_phase.Public_action.Drop
             | _ -> Goal_phase.Public_action.Reopen
           in
           handle_goal_action_key state ~mailbox:async_messages ~action
       | Some "c" | Some "C" when state.view = Board ->
           (* Reply to the post being read. Same pane as a new post; the
              reply target decides the payload and where the operator
              lands after it sends. *)
           (match state.board_mode with
            | Board_read post_id ->
                state.board_mode <- Board_compose;
                state.board_compose_armed <- false;
                state.board_compose_reply_to <- Some post_id;
                state.board_post_error <- None
            | Board_list | Board_compose -> ())
       | Some "v" | Some "V" when state.view = Board ->
           (* Lowercase votes up, uppercase votes down -- the shift is the
              direction, so neither reading needs a second keypress to
              choose one. *)
           handle_board_vote_key state ~mailbox:async_messages
             ~up:(match key with Some "v" -> true | _ -> false)
       | Some "x" | Some "X" when state.view = Schedules ->
           (* Two presses, like every irreversible action here: the first
              names the schedule, the second cancels it. Whether the row is
              still cancellable is the server's store rules to say. *)
           handle_schedule_cancel_key state ~mailbox:async_messages
       | Some ("l" | "L") when state.view = System_logs ->
           (* The verbose ladder: each press raises the server-side level
              floor, and after error it opens back up. The floor changes what
              the page fetches, so the page is refetched rather than
              re-trimmed locally. *)
           state.system_logs_min_level <-
             Masc.Tui_decode.next_system_log_min_level
               state.system_logs_min_level;
           state.system_logs_scroll <- 0;
           state.system_logs_cursor <- 0;
           launch_system_logs_load state ~mailbox:async_messages
       | Some ("v" | "V") when state.view = System_logs ->
           (* Unlike [l]'s four-step floor ladder, this answers the common
              operational question directly: DEBUG rows on or off. Both
              states refetch because the server owns level filtering. *)
           state.system_logs_min_level <-
             Masc.Tui_decode.toggle_system_log_verbose
               state.system_logs_min_level;
           state.system_logs_scroll <- 0;
           state.system_logs_cursor <- 0;
           launch_system_logs_load state ~mailbox:async_messages
       | Some ("c" | "C") when state.view = System_logs ->
           (* Category narrows what this page shows, not what it fetched.
              The vocabulary is the categories the loaded rows carry, so the
              cycle never offers a name the page cannot show. *)
           let entries =
             match state.system_logs with
             | None -> []
             | Some snapshot -> snapshot.sys_entries
           in
           state.system_logs_category <-
             Masc.Tui_decode.next_system_log_category
               ~current:state.system_logs_category entries;
           state.system_logs_scroll <- 0;
           state.system_logs_cursor <- 0
       | Some "x" | Some "X"
         when state.view = Overview && state.task_detail_id <> None ->
           (* Cancel wants a reason, and $EDITOR is the form we already
              have; the editor itself is the confirmation step. *)
           handle_task_cancel ()
       | Some "x" | Some "X" when state.view = Verification ->
           (* Reject wants a reason, and $EDITOR is the form we already
              have; the editor itself is the confirmation step. *)
           handle_verification_reject ()
       | Some "x" | Some "X" when state.view = Harness ->
           (* The negative verdict, spelled the way Verification spells its
              own. It was [n], which this surface cannot keep: Harness
              answers the row search, and [n] steps that search on every
              surface that does not bind the key itself. *)
           handle_harness_overrule ()
       | Some (("l" | "L" | "o") as log_key)
         when (match log_key, state.view with
               | ("l" | "L"), Keepers (Keeper_list | Keeper_detail)
               | "o", Keepers Keeper_detail -> true
               | _ -> false) ->
           (* Logs, from the roster as well as from detail, for the same reason
              chat is reachable from both: the keeper an operator wants the
              logs of is the one under the cursor. *)
           let keeper = selected_keeper state in
           load_keeper_logs_if_safe state base_path 200 keeper;
           (match keeper with
            | Some _ ->
                state.log_scroll <-
                  Metrics_tail.maximum_scroll
                    ~entry_count:(List.length state.log_entries)
                    ~content_height:(keeper_log_content_height state);
                state.view <- Keepers Keeper_logs
            | None -> ())
| Some "c" | Some "C"
         when state.view = Runtime
              && Option.is_none state.runtime_detail_target ->
            (* The third Runtime reading: not what the lanes call, not what
               the workspace could call, but who is attached to it — the
               clients roster, off the ring under Runtime the way Lanes is.
               This arm sits above the chat arm because that one takes [c]
               unguarded on every surface that names a Keeper. *)
            goto_surface state ~mailbox:async_messages Clients
| Some "m" | Some "M" | Some "c" | Some "C" ->
           (* Chat from every row that names a Keeper. Standalone Lanes carry
              no Keeper identity; Keeper chat is owned by the Keepers surface.
              [c] is an alias for [m] because the footer names the action rather
              than the mnemonic. *)
           (match state.view with
            | Code -> ()
            | Keepers Keeper_runtime_pick -> ()
            | Lanes ->
                (match state.lanes_mode with
                 | Lanes_run_list _ | Lanes_run_detail _ -> ()
                 | Lanes_overview ->
                     show_lanes_action_error state
                       "Cannot open chat: Standalone lanes have no Keeper; use Keepers")
            | Keepers Keeper_list
              when Option.is_none state.keepers_error
                   && state.keeper_cursor < List.length state.keepers ->
                let keeper = List.nth state.keepers state.keeper_cursor in
                open_message_for_keeper ~return_to:Keeper_chat_return_list state
                  keeper.k_name;
                launch_keeper_history_load state ~mailbox:async_messages
                  ~keeper_name:keeper.k_name;
                state.view <- Keepers Keeper_message
            | Keepers Keeper_detail
              when Option.is_none state.keepers_error
                   && state.keeper_cursor < List.length state.keepers ->
                let keeper = List.nth state.keepers state.keeper_cursor in
                open_message_for_keeper ~return_to:Keeper_chat_return_detail
                  state keeper.k_name;
                launch_keeper_history_load state ~mailbox:async_messages
                  ~keeper_name:keeper.k_name;
                state.view <- Keepers Keeper_message
            | Keepers Keeper_detail | Keepers Keeper_list
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message
            | Board | Approvals | Planning | Schedules | Verification | Harness
            | Memory | Fusion | Repositories | Changes | Connectors | Runtime | Config | Resources | Tools | Clients
            | System_logs -> ())
       | Some "x" | Some "X"
         when state.view = Config && state.config_pane = Config_params ->
           handle_runtime_param_clear ()
       | Some "x" | Some "X"
         when state.view = Config && state.config_pane = Config_themes ->
           (* Back to whatever the terminal reports. Not a theme named
              "terminal" -- there is nothing to name, only the absence of a
              choice, which is where masc started. The stored key goes with
              it, for the same reason: absence is the state, so it is written
              by removing the key rather than by naming one. *)
           Masc_tui_theme_choice.follow_terminal ();
           state.theme_choice <- None;
           state.theme_before_preview <- None;
           (* Withdrawing the choice withdraws the background with it. *)
           sync_theme_page ();
           store_theme_choice None
       | Some "i" | Some "I"
         when state.view = Config && state.config_pane = Config_prompts ->
           if state.prompts_show_runtime_assets
           then add_event state "system" "런타임 프롬프트 자산에는 기록된 모델 입력이 없습니다"
           else handle_librarian_input_read ()
       | Some "p" | Some "P"
         when state.view = Runtime
              && Option.is_none state.runtime_detail_target ->
           (* The lane view answers what each lane calls and in what order.
              It cannot answer what this workspace could call: a runtime no
              lane names is absent from it, which is exactly the runtime an
              operator is looking for when they go to assign one. Same [p]
              that moves panes on Tools and Config. The third stop is the
              standalone service lanes, off the ring the way Task Review
              hangs off Planning; [p] there returns here. *)
           (match state.runtime_mode with
            | Masc_tui_types.Runtime_lanes ->
                state.runtime_mode <- Masc_tui_types.Runtime_all;
                (* The scroll belonged to the other list's length. *)
                state.runtime_surface_scroll <- 0
            | Masc_tui_types.Runtime_all ->
                state.runtime_mode <- Masc_tui_types.Runtime_lanes;
                state.runtime_surface_scroll <- 0;
                goto_surface state ~mailbox:async_messages Lanes)
       | Some "p" | Some "P" when state.view = Clients ->
           goto_surface state ~mailbox:async_messages Runtime
       | Some "p" | Some "P"
         when state.view = Lanes && state.lanes_mode = Lanes_overview ->
           goto_surface state ~mailbox:async_messages Runtime
       | Some "p" | Some "P" when state.view = Tools ->
           (* Five sections, one at a time. Concatenated they ran to 326 rows
              on this workspace and the terminal draws twenty, so four of
              them sat behind a per-tool list that never ends. [p] is the
              same key that moves between the Config surface's panes. *)
           state.tools_pane <-
             (match state.tools_pane with
              | Tools_surface -> Tools_async
              | Tools_async -> Tools_activations
              | Tools_activations -> Tools_usage
              | Tools_usage -> Tools_catalog
              | Tools_catalog -> Tools_surface);
           (* The scroll belonged to the list that just went away. Carrying it
              into a shorter section opens it part-way down for no reason the
              reader gave. *)
           state.tools_scroll <- 0
       | Some "p" | Some "P" when state.view = Config ->
           (* One surface, two files the server reads: runtime.toml and the
              prompt registry. [p] moves between them and loads the list the
              first time it is asked for. *)
           (* Two of the three are files the server reads; the third is this
              reader's own colours, which no server has an opinion about. *)
           state.config_pane <-
             (match state.config_pane with
              | Config_runtime -> Config_models
              | Config_models -> Config_params
              | Config_params -> Config_prompts
              | Config_prompts -> Config_presets
              | Config_presets -> Config_themes
              | Config_themes -> Config_voice
              | Config_voice -> Config_runtime);
           state.prompts_cursor <- 0;
           state.config_scroll <- 0;
           state.runtime_config_cursor <- 0;
           state.runtime_params_cursor <- 0;
           state.runtime_param_edit <- None;
           state.runtime_params_notice <- None;
           state.prompts_librarian_input <- None;
           state.prompts_librarian_input_error <- None;
           state.prompts_librarian_input_loading <- false;
           (* Cycling into a pane is entering it. Without this the params pane
              draws whatever the last load left, which for a first visit is an
              empty list -- and empty reads as "nothing registered". *)
           (* Leaving the themes pane ends the preview the same way Esc does.
              A scheme the reader never picked must not follow them out. *)
           cancel_theme_preview ();
           (match state.config_pane with
            | Config_prompts ->
              if state.prompts_snapshot = None
              then launch_prompts_load state ~mailbox:async_messages
            | Config_presets ->
              state.presets_cursor <- 0;
              state.preset_save_draft <- None;
              state.preset_restore_armed <- None;
              if state.presets_snapshot = None
              then launch_presets_load state ~mailbox:async_messages
            | Config_params -> launch_runtime_params_load state ~mailbox:async_messages
            (* Same first-visit load as the prompts pane. The models table is
               a projection of runtime.toml, so entering it without the file
               would draw "(loading)" with nothing on the way. *)
            | Config_models ->
              if state.runtime_config_view = None
              then launch_runtime_config_load state ~mailbox:async_messages
            | Config_runtime ->
              set_runtime_config_cursor_near state ~direction:1 ~target:0
            (* Re-read rather than move a cursor: this pane has no rows, and
               what an operator wants from it after starting a local server is
               a fresh answer. *)
            | Config_voice -> launch_voice_config_load state ~mailbox:async_messages
            | Config_themes -> ())
       | Some "p" | Some "P" ->
           (* The toggle: whichever of pause / resume / boot this reading
              offers first. One key for "stop" and "play" because which one
              applies is a fact about the keeper, not a choice the operator
              should have to make. *)
           (match state.view with
            | Code -> ()
            | Keepers Keeper_runtime_pick -> ()
            | Keepers (Keeper_list | Keeper_detail) -> (
                match
                  Option.map (keeper_reading state) (selected_keeper state)
                  |> Option.map Keeper_control.primary
                with
                | Some (Some action) ->
                    handle_keeper_action state ~base_path
                      ~mailbox:async_messages action
                | Some None ->
                    add_event state "system"
                      "No lifecycle action applies to this keeper yet"
                | None -> ())
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Lanes
            | Board | Approvals | Planning | Schedules | Verification | Harness
            | Memory | Fusion | Repositories | Changes | Connectors | Runtime | Config | Resources | Tools | Clients
            | System_logs -> ())
       | Some "s" | Some "S" ->
           (match state.view with
            | Code -> ()
            | Keepers Keeper_runtime_pick -> ()
            | Keepers (Keeper_list | Keeper_detail) ->
                (match state.connection_status with
                 | Disconnected ->
                     (* RFC tui-server-lifecycle: with no server up there is
                        no keeper to shut down, so "s" starts one here. *)
                     start_masc_server_here ~base_path ~host:server_peer_host
                       ~port:state.port
                       ~note:(fun msg -> add_event state "system" msg)
                       ~on_ready:(fun () ->
                         start_http_refresh state ~host:server_peer_host
                           ~port:state.port ~intent:Revalidate
                           ~refresh_inflight:http_refresh_inflight
                           ~scoped_refresh_inflight:http_scoped_refresh_inflight
                           ~scoped_refresh_followup ~mailbox:async_messages)
                 | Connecting | Reconnecting | Degraded | Connected ->
                     handle_keeper_action state ~base_path
                       ~mailbox:async_messages Keeper_control.Shutdown)
            | Board ->
                (match state.board_mode with
                 | Board_compose -> ()
                 | Board_list | Board_read _ ->
                     state.board_sort <- next_board_sort state.board_sort;
                     add_event state "system"
                       ("Board order: "
                        ^ board_sort_label state.board_sort);
                     start_http_refresh state ~host:server_peer_host
                       ~port:state.port ~intent:Revalidate
                       ~refresh_inflight:http_refresh_inflight
                       ~scoped_refresh_inflight:http_scoped_refresh_inflight
                       ~scoped_refresh_followup
                       ~mailbox:async_messages)
            | Planning ->
                (* Client-side re-order of the loaded goals: no refetch. *)
                state.planning_sort <- next_planning_sort state.planning_sort;
                clamp_planning_cursor state
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Lanes
            | Approvals | Schedules | Verification | Harness
             | Memory | Fusion | Repositories | Changes | Connectors | Runtime | Config | Resources | Tools | System_logs | Clients -> ())
       | Some "w" | Some "W" ->
           (* Two unrelated bindings share a key: "write" on the Board list,
              "wake up" on a keeper row. The surface decides which one is
              live, and Board compose takes the key only from the list --
              inside the compose pane the letter is draft text. *)
           (match state.view with
            | Code -> ()
            | Keepers Keeper_runtime_pick -> ()
            | Board ->
                (match state.board_mode with
                 | Board_list ->
                     state.board_mode <- Board_compose;
                     state.board_compose_armed <- false;
                     state.board_compose_reply_to <- None;
                     state.board_post_error <- None
                 | Board_read _ | Board_compose -> ())
            | Keepers (Keeper_list | Keeper_detail) ->
                handle_keeper_action state ~base_path ~mailbox:async_messages
                  Keeper_control.Wakeup
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Lanes
            | Approvals | Planning | Schedules | Verification | Harness
             | Memory | Fusion | Repositories | Changes | Connectors | Runtime | Config | Resources | Tools | System_logs | Clients
            -> ())
       | Some "E"
         when state.view = Config && state.config_pane = Config_params ->
           handle_runtime_param_edit_open ~advanced:true ()
       | Some "e" | Some "E"
         when state.view = Keepers Keeper_detail
              && state.detail_tab = Detail_channels ->
           handle_connector_edit ()
       | Some "e" | Some "E" ->
           (* Settings edit hands the terminal to $EDITOR, so it cannot live
              inside the keeper-action pipeline: the loop is inside the
              editor, and the POST happens only after the editor returns. *)
           (match state.view with
            | Code -> ()
            | Keepers Keeper_runtime_pick -> ()
            | Keepers (Keeper_list | Keeper_detail) -> handle_keeper_settings_edit ()
            | Lanes ->
                (match state.lanes_mode, selected_standalone_lane state with
                 | Lanes_overview, Some lane ->
                   let section =
                     "runtime.exact_output_lanes." ^ lane.Tui_decode.sl_lane_id
                   in
                   state.view <- Config;
                   state.config_pane <- Config_runtime;
                   state.runtime_config_jump_section <- Some section;
                   (match state.runtime_config_view with
                    | None ->
                      add_event state "info"
                        (Printf.sprintf "loading runtime.toml for [%s]" section);
                      launch_runtime_config_load state ~mailbox:async_messages
                    | Some _ ->
                      (match apply_runtime_config_jump state with
                       | Some (_, true) ->
                         add_event state "info"
                           (Printf.sprintf
                              "runtime.toml at [%s] - e to edit" section)
                       | Some (_, false) ->
                         add_event state "error"
                           (Printf.sprintf
                              "runtime.toml has no [%s] section" section)
                       | None -> ()))
                 | Lanes_overview, None ->
                   show_lanes_action_error state
                     "Cannot open config: no standalone lane is selected"
                 | (Lanes_run_list _ | Lanes_run_detail _), _ -> ())
            | Config ->
                (match state.config_pane with
                 | Config_prompts ->
                   if state.prompts_show_runtime_assets
                   then add_event state "system" "런타임 프롬프트 자산은 읽기 전용입니다"
                   else handle_prompt_edit ()
                 | Config_runtime -> handle_runtime_config_edit ()
                 | Config_params ->
                   handle_runtime_param_edit_open ~advanced:false ()
                 (* The pane cannot write a value: its two columns come
                    from two tables and a writer would have to know which.
                    So [e] hands the reader to the source pane at the
                    selected model's [models.NAME] line, where the existing
                    $EDITOR path takes over. One write path, not two. *)
                 | Config_models -> handle_config_models_open_source ()
                 (* The preset pane writes through s and r, never $EDITOR.
                    The voice pane is a reading; runtime.toml is edited from
                    the runtime pane, where the file already is. *)
                 | Config_presets | Config_themes | Config_voice -> ())
            | Tools -> handle_skill_edit ()
            | Schedules -> handle_schedule_modify ()
            | Approvals ->
                (* Cycle the external-services Gate lane: what happens to a
                   Keeper's call into an attached outside service. Its own
                   switch — the workspace lane never opens it. An unknown
                   stored value cycles to manual, the fail-closed end. *)
                (match state.gate_modes with
                 | None ->
                     add_event state "system"
                       "Gate lanes are not loaded yet; wait for the refresh"
                 | Some modes ->
                     (* Cycle through the closed Keeper_gate_mode variants
                        rather than a string re-spelling: a fourth mode
                        makes this match a compile error instead of a
                        silent fall-through to manual. An unrecognized
                        stored value still cycles to manual, the
                        fail-closed end. *)
                     let next =
                       match
                         Masc.Keeper_gate_mode.of_string
                           modes.Tui_decode.glm_external
                       with
                       | Some Masc.Keeper_gate_mode.Manual ->
                           Masc.Keeper_gate_mode.Auto_judge
                       | Some Masc.Keeper_gate_mode.Auto_judge ->
                           Masc.Keeper_gate_mode.Always_allow
                       | Some Masc.Keeper_gate_mode.Always_allow | None ->
                           Masc.Keeper_gate_mode.Manual
                     in
                     launch_gate_external_mode_set state
                       ~mailbox:async_messages
                       ~mode:(Masc.Keeper_gate_mode.to_string next))
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message
            | Board | Planning | Verification | Harness
             | Memory | Fusion | Repositories | Changes | Connectors | Runtime | Resources | System_logs | Clients -> ())
       | Some "x" | Some "X"
         when state.view = Config && state.config_pane = Config_prompts ->
           if state.prompts_show_runtime_assets
           then add_event state "system" "런타임 프롬프트 자산은 읽기 전용입니다"
           else handle_prompt_clear ()
       | Some "a" | Some "A"
         when state.view = Config && state.config_pane = Config_prompts
              && not state.prompts_show_runtime_assets ->
           state.prompts_show_fragments <- not state.prompts_show_fragments;
           state.prompts_cursor <- 0;
           state.config_scroll <- 0;
           state.prompts_librarian_input <- None;
           state.prompts_librarian_input_error <- None;
           state.prompts_librarian_input_loading <- false;
           add_event state "system"
             (if state.prompts_show_fragments then
                "Prompt 목록에 내부 조각을 표시합니다"
             else "Prompt 목록에 주 프롬프트만 표시합니다")
       | Some "o" | Some "O"
         when state.view = Config && state.config_pane = Config_prompts ->
           state.prompts_show_runtime_assets <- not state.prompts_show_runtime_assets;
           state.prompts_cursor <- 0;
           state.config_scroll <- 0;
           state.prompts_librarian_input <- None;
           state.prompts_librarian_input_error <- None;
           state.prompts_librarian_input_loading <- false;
           add_event state "system"
             (if state.prompts_show_runtime_assets then
                "읽기 전용 런타임 프롬프트 자산을 표시합니다"
              else "재정의 가능한 프롬프트 레지스트리를 표시합니다")
       | Some "b"
         when state.view = Connectors
               || (state.view = Keepers Keeper_detail
                   && state.detail_tab = Detail_channels) ->
            handle_connector_bind ()
       | Some "u"
         when state.view = Connectors
              || (state.view = Keepers Keeper_detail
                  && state.detail_tab = Detail_channels) ->
           handle_connector_unbind ()
       | Some "a" | Some "A" ->
           (match state.view with
            | Code -> ()
            | Keepers Keeper_runtime_pick -> ()
            | Keepers (Keeper_list | Keeper_detail) -> handle_keeper_create ()
            (* The route and its permission already existed; only the TUI had
               no way to reach them, so Workspace could list what was registered
               and never register anything. *)
            | Repositories -> handle_repository_add ()
            | Verification ->
                (* Two presses, like every irreversible action here: the
                   first names the task, the second sends the approval. *)
                handle_verification_approve_key state ~mailbox:async_messages
            | Approvals ->
                (* The approval queue owns this surface's arrows and its y/n,
                   so answering a Keeper's question opens as its own mode. *)
                enter_ask_answering state
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Memory | Lanes
            | Board | Planning | Schedules | Harness
            | Fusion | Changes | Connectors | Runtime | Config | Resources | Tools | System_logs | Clients -> ())
      | _ -> ());

      (* Surface navigation asks only for datasets the destination adds. The
         full refresh owns connection identity and the global badges; replaying
         it for every Tab made an Overview -> Tools walk spend those requests
         once per distinct [surface_needs] record. A scoped refresh neither
         repeats them nor changes connection status. *)
      let needed = Masc_tui_types.surface_needs state.view in
      if
        needed <> !drawn_needs
        && not !http_refresh_inflight
        && not !http_scoped_refresh_inflight
      then begin
        let delta =
          Masc_tui_types.surface_needs_delta ~previous:!drawn_needs ~next:needed
        in
        drawn_needs := needed;
        if Masc_tui_types.surface_needs_any delta then
          start_http_scoped_refresh state ~host:(server_peer_host)
            ~port:state.port ~refresh_inflight:http_scoped_refresh_inflight
            ~mailbox:async_messages ~needs:delta
      end;

      Eio.Fiber.yield ();
      if
        drain_async_messages state ~base_path ~http_refresh_inflight
          ~http_scoped_refresh_inflight ~scoped_refresh_followup async_messages
      then Render_schedule.request render_schedule Render_schedule.Background;

      (* Periodic refresh *)
      let now_ns = Mtime_clock.elapsed_ns () in
      let _, terminal_cols = get_terminal_size () in
      let current_marquee_target =
        keeper_roster_marquee_target state ~cols:terminal_cols
      in
      if current_marquee_target <> !roster_marquee_target then begin
        roster_marquee_target := current_marquee_target;
        roster_marquee_last_step_ns := now_ns;
        state.roster_marquee_frame <- 0
      end
      else if
        Option.is_some current_marquee_target
        && Int64.compare
             (Int64.sub now_ns !roster_marquee_last_step_ns)
             roster_marquee_interval_ns
           >= 0
      then begin
        roster_marquee_last_step_ns := now_ns;
        state.roster_marquee_frame <-
          if state.roster_marquee_frame = max_int then 0
          else state.roster_marquee_frame + 1;
        Render_schedule.request render_schedule Render_schedule.Background
      end;
      (* The running-turn mark, advanced on its own clock rather than the
         poll's. The poll is two seconds; a mark that changed on it would
         read as a stall rather than as work. Nothing is fetched here -- the
         frame is derived and the presenter writes only the cells that
         differ, so a repaint that changes one glyph costs one glyph.

         It runs only while a turn is running, and returns to [-1] when none
         is. A screen with nothing to say stops repainting entirely, which
         is also what makes the elapsed seconds honest: they tick because
         this is what redraws them. *)
      (* Every surface that draws a moving mark, not just the first one. A
         lane can be running while no keeper turn is, and a frame counter
         that only watched turns would leave that mark frozen on whatever
         quarter it stopped at -- which reads as a lane stuck there. *)
      let anything_running =
        Masc_tui_answering.anything_running ~turns:state.keeper_turns
          ~live_transcript:(Option.is_some state.msg_live)
          ~lanes:state.standalone_lanes
      in
      if not anything_running then begin
        if state.activity_frame >= 0 then begin
          state.activity_frame <- -1;
          Render_schedule.request render_schedule Render_schedule.Background
        end
      end
      else if
        Int64.compare
          (Int64.sub now_ns !activity_last_step_ns)
          activity_interval_ns
        >= 0
      then begin
        activity_last_step_ns := now_ns;
        state.activity_frame <-
          (if state.activity_frame < 0 || state.activity_frame = max_int then 0
           else state.activity_frame + 1);
        Render_schedule.request render_schedule Render_schedule.Background
      end;
      if
        Int64.compare (Int64.sub now_ns !last_check_ns) refresh_interval_ns >= 0
      then begin
        (* The armed approval survives the tick: the snapshot apply already
           disarms it when its token leaves the list, so clearing here only
           made the second press race a two-second clock. *)
        load_local_workspace_if_safe state base_path;
        let host = server_peer_host in
        let port = state.port in
        (* The retry a closed feed waits for. *)
        open_observer_if_due state ~retry_closed:true ~host ~port
          ~mailbox:async_messages;
        start_http_refresh state ~host ~port ~intent:Cadence
          ~refresh_inflight:http_refresh_inflight
          ~scoped_refresh_inflight:http_scoped_refresh_inflight
          ~scoped_refresh_followup
          ~mailbox:async_messages;
        (* Also refresh logs / Board detail if viewing them. *)
        (match state.view with
         | Code -> ()
         | Keepers Keeper_runtime_pick -> ()
         | Keepers Keeper_list ->
             launch_keeper_lanes_load state ~mailbox:async_messages
         | Keepers (Keeper_logs | Keeper_detail) ->
             load_keeper_logs_if_safe state base_path 200
               (List.nth_opt state.keepers state.keeper_cursor)
         | Keepers Keeper_calls ->
             (match selected_keeper state with
              | Some keeper ->
                  launch_keeper_calls_load state ~mailbox:async_messages
                    keeper.k_name
              | None -> ())
         | Board ->
             (match state.board_mode with
              | Board_read post_id ->
                  start_board_post_refresh state ~host ~port ~post_id
                    ~mailbox:async_messages
              | Board_list | Board_compose -> ())
         | Verification ->
             (* The queue moves while an operator watches it -- a task settles,
                another arrives. Planning reads this list on entry and on an
                explicit refresh for its child badge, but does not poll a
                hidden 200-row queue on every cadence tick. *)
             launch_verification_load state ~mailbox:async_messages
             | Lanes -> launch_lanes_load state ~mailbox:async_messages
             | Clients -> launch_clients_load state ~mailbox:async_messages
         | Harness -> launch_harness_load state ~mailbox:async_messages
         | Fusion ->
             launch_fusion_runs_load state ~mailbox:async_messages;
             (match state.fusion_mode with
              | Fusion_list -> ()
              | Fusion_detail run_id ->
                  launch_fusion_detail_load state ~mailbox:async_messages
                    ~run_id)
         | Memory ->
             (* Fleet memory health is a reading, so the tick refreshes it
                like the listings above. *)
             launch_memory_health_load state ~mailbox:async_messages
         | Repositories ->
             (* Registration and keeper assignment change from elsewhere, so
                the list is refreshed on the tick like the surfaces above. *)
             launch_repositories_load state ~mailbox:async_messages
         | Connectors ->
             (* Reachability is the column that moves on its own. *)
             launch_connectors_load state ~mailbox:async_messages
         | Runtime ->
             (* Both authorities can move independently. Single-flight keeps
                a slow authenticated read from stacking across ticks. *)
             launch_runtime_surface_load state ~mailbox:async_messages
               ~force:false
         | Tools ->
             (* The inventory is near-static, but a tool whose projection
                changes is exactly what this surface is read for. *)
             launch_tools_load state ~mailbox:async_messages
         | Config ->
             (* The file moves under hot-reload edits from other agents. *)
             launch_runtime_config_load state ~mailbox:async_messages
         | Resources ->
             (* Loaded on arrival and on r. A tick-cadence relist would open
                an MCP session every two seconds for an inventory that moves
                at human speed. *)
             ()
         | Schedules ->
             (* Rows cross their due time and turn terminal while an operator
                watches; the page that answers "why is this keeper awake"
                holds a reading from when the operator arrived otherwise. *)
             launch_schedules_load state ~mailbox:async_messages
         (* Changes is not on the timer. The read parses every row in the
            window's date files -- seconds, not milliseconds -- and the answer
            only moves when the keeper takes a turn. [r] asks for it. *)
         | Changes
         | Overview | Acting | Keepers Keeper_message
         | Approvals | Planning | System_logs -> ());
        last_check_ns := now_ns;
        Render_schedule.request render_schedule Render_schedule.Background
      end;

      (match
         Render_schedule.take render_schedule
           ~now_ns:(Mtime_clock.elapsed_ns ())
       with
       (* The terminal belongs to the picture until it is dismissed. A frame
          drawn now would clear the rows it occupies and leave the rest. *)
       | Render_schedule.Render when state.image_open -> ()
       | Render_schedule.Render ->
           let frame, clamped, approval =
             Masc_tui_frame_timing.time_tagged Masc_tui_frame_timing.Build
               ~tag:(fun (frame, _, _) -> frame.Frame_presenter.surface_key)
               (fun () -> render state)
           in
           (* The frame is what the operator will act on next, so the scroll it
              had to clamp is the scroll the next keypress moves from. Applied
              here rather than inside the drawing: a surface whose row count
              only exists once the frame is built cannot be bounded before it,
              but the drawing does not have to be the thing that stores it. *)
           Option.iter (apply_clamped_scroll state) clamped;
           if Terminal_profile.dynamic_title terminal_profile then
             Terminal_title.present terminal_title ~write:(output_string stdout)
               ~flush:(fun () -> flush stdout)
               (terminal_title_snapshot state);
           Masc_tui_frame_timing.time_tagged Masc_tui_frame_timing.Present
             ~tag:(fun () -> frame.Frame_presenter.surface_key)
             (fun () -> present_frame frame approval)
       | Render_schedule.Idle | Render_schedule.Wait_until _ -> ())
    done
  in
  run_loop ()

let run_with_eio_context f =
  try
    Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
            Eio_guard.enable ();
            Eio.Switch.on_release sw Eio_guard.disable;
            (* RFC tui-server-lifecycle: stop only a server this TUI started;
               a server we merely connected to is not ours to kill. *)
            Eio.Switch.on_release sw (fun () ->
                match !tui_owned_server with
                | Some owned ->
                    Masc_tui_server_lifecycle.stop owned ~grace_sec:2.0
                | None -> ());
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            (* Without this, Process_eio falls back to a Unix path that waits on
               Unix.select. Eio is cooperative, so that blocks the whole domain
               rather than one fiber: a microphone capture forked to keep the
               UI responsive froze every key instead, for as long as the
               recorder ran. The server and fusion_run already init here; the
               TUI did not, and nothing it spawned had been long enough to
               notice until a capture ran for 15 s. *)
            Process_eio.init
              ~cwd_default:(Eio.Stdenv.cwd env)
              ~proc_mgr:(Eio.Stdenv.process_mgr env)
              ~clock:(Eio.Stdenv.clock env);
            Eio_context.set_env env;
            Eio_context.set_switch sw;
            Eio_context.set_net (Eio.Stdenv.net env);
            Eio_context.set_clock (Eio.Stdenv.clock env);
            Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
            f ()))
  with Break -> ()

let () = run_with_eio_context main
