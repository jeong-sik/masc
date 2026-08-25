open Masc_tui_types
open Masc_tui_ansi
open Masc_tui_render
open Masc_tui_loader

module Approval = Masc_tui_operator_projection
module Board_detail = Masc_tui_board_detail
module Board_selection = Masc_tui_board_selection
module Frame_presenter = Masc_tui_frame_presenter
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_history = Masc_tui_keeper_chat_history
module Chat_queue = Masc_tui_keeper_chat_queue
module Keeper_chat_live = Masc_tui_keeper_chat_live
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Composer = Masc_tui_composer
module Keeper_control = Masc_tui_keeper_control
module Metrics_tail = Masc_tui_metrics_tail
module Planning_selection = Masc_tui_planning_selection
module Render_schedule = Masc_tui_render_schedule
module Terminal_title = Masc_tui_terminal_title
module Terminal_write_repair = Masc_tui_terminal_write_repair

(** Local exception for breaking the main TUI loop without using Exit. *)
exception Break

(** One 60 Hz frame window: bursts are coalesced without delaying an idle
    terminal's first changed frame. *)
let frame_interval_ns = 16_000_000L
(* What one wheel detent moves. Terminals report three lines per detent, so a
   notch here is worth what a notch is worth in a pager. *)
let wheel_notch_rows = 3

let maximum_input_wait_seconds = 0.016
let nanoseconds_per_second = 1_000_000_000.0

let synchronized_output_enabled () =
  match Sys.getenv_opt "MASC_TUI_SYNC" with
  | Some value ->
      (match String.lowercase_ascii (String.trim value) with
       | "0" | "false" | "no" | "off" -> false
       | "" | "1" | "true" | "yes" | "on" | _ -> true)
  | None -> true

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
      Log.info ~ctx:"masc-tui" "stderr redirected to %s" path
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
let move_surface_scroll (state : state) ~rows ~delta ~current =
  match scrolled_surface state state.view with
  | None -> current + delta
  | Some { sc_count; sc_chrome } ->
      let height = max 1 (rows - sc_chrome) in
      if delta >= 0 then Masc_tui_scroll.down ~count:sc_count ~height current
      else Masc_tui_scroll.up ~count:sc_count ~height current

(* The rows a surface has to draw in: the terminal's, less the composer's,
   which owns the last row. The same arithmetic the drawing does -- a bound
   worked out from a different height than the frame uses is not a bound.
   Reading the terminal's own rows here, as this did, left the log surface's
   keypress bound one row looser than the frame it moved within. *)
let surface_rows () =
  let terminal_rows, _columns = get_terminal_size () in
  max 1 (terminal_rows - Composer.rows_for ~terminal_rows)

(* Page keys move almost one visible body, leaving a few rows of overlap so
   the reader keeps their place across the jump. Individual renderers clamp
   the result against their exact wrapped-line count. *)
let surface_page_rows () = max 1 (surface_rows () - 8)

(* A row cursor over a plain listing: the keypress moves the cursor and the
   window follows with the smallest move that keeps it visible. Reads the
   same [scrolled_surface] bound the drawing uses, so the cursor cannot name
   a row the frame will not draw. *)
let move_row_cursor (state : state) ~delta ~cursor ~scroll =
  match scrolled_surface state state.view with
  | None -> (cursor, scroll + delta)
  | Some { sc_count; sc_chrome } ->
      let height = max 1 (surface_rows () - sc_chrome) in
      let cursor =
        if delta >= 0 then Masc_tui_scroll.cursor_down ~count:sc_count cursor
        else Masc_tui_scroll.cursor_up ~count:sc_count cursor
      in
      (cursor, Masc_tui_scroll.ensure_visible ~cursor ~height scroll)

let keeper_log_content_height (state : state) =
  Metrics_tail.content_height ~terminal_rows:(surface_rows ())
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
                  surface's scroll binding answers the wheel; a report nothing
                  consumes stays unclaimed rather than leaking into a key. *)
               | Some (params, final)
                 when String.length params > 0 && params.[0] = '<' -> (
                   match Masc.Tui_decode.sgr_wheel_key params final with
                   | Some wheel_key -> key wheel_key
                   | None -> key "unknown-esc")
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
  (base, r, !port, !refresh, reasoning_visibility, tool_visibility)

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

(* Where a keeper can read a file this process writes.

   [Keeper_sandbox_config.host_root_abs_of_agent] is the same answer the
   server gives: it reads the keeper's own TOML for the sandbox profile and
   returns the backend-scoped root -- [.masc/playground/<name>/] for a local
   keeper and [.masc/playground/docker/<name>/] for a Docker one. Working the
   path out here instead would be this process copying a layout the server
   owns, and the two roots differ by a directory that is easy to get right
   once and wrong afterwards.

   [None] when the root cannot be named or does not exist. A keeper that has
   never run has no playground, and creating one from outside would be this
   process deciding something about the keeper's own space. *)
let keeper_readable_dir ~base_path ~keeper_name =
  match
    Keeper_sandbox_config.host_root_abs_of_agent ~base_path
      ~agent_name:keeper_name
  with
  (* [sandbox_profile_of_agent] raises on a keeper TOML it cannot read, and
     [Sys.is_directory] raises on a path that went away between the two
     calls. Neither is a reason to lose the paste -- the caller falls back to
     sending the text. *)
  | exception _ -> None
  | dir -> (
      match Sys.file_exists dir && Sys.is_directory dir with
      | true -> Some dir
      | false -> None
      | exception Sys_error _ -> None)

let write_file path contents =
  match open_out_bin path with
  | exception Sys_error detail -> Error detail
  | channel -> (
      match
        Fun.protect
          ~finally:(fun () -> close_out_noerr channel)
          (fun () -> output_string channel contents)
      with
      | () -> Ok ()
      | exception Sys_error detail -> Error detail)

(* Hand a spilled paste to the keeper as a file it can read, and put a line
   naming that file where the placeholder stands.

   Measured before it was built: a keeper reads paths relative to its own
   sandbox root and refuses anything outside it, so [/tmp] comes back as
   [path_outside_sandbox] and a workspace-relative path is simply not found.
   The file goes into the root and the message names it bare.

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
          match keeper_readable_dir ~base_path ~keeper_name with
          | None ->
              add_event state "system"
                (Printf.sprintf
                   "%s has no workspace on disk; sending the pasted text in \
                    the message instead"
                   (Keeper_chat.terminal_safe_text keeper_name));
              inline ()
          | Some dir -> (
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
                  add_event state "system"
                    (Printf.sprintf "Wrote %s (%d bytes) into %s's workspace"
                       spill.Masc_tui_paste_spill.file_name
                       spill.Masc_tui_paste_spill.bytes
                       (Keeper_chat.terminal_safe_text keeper_name));
                  pointed)))

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
  state.msg_target_keeper_name <- Some keeper_name;
  state.msg_live <- live_for_keeper state keeper_name;
  state.msg_return <- return_to;
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
    Keepers
      (match state.msg_return, target_registered with
       | Keeper_chat_return_detail, true -> Keeper_detail
       | Keeper_chat_return_list, _ | Keeper_chat_return_detail, false ->
           Keeper_list);
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
  (* The pane's fixed chrome is 7 rows (render_keeper_message names them);
     composer growth is already inside [keeper_message_status_rows]. Adding
     composer_max_rows here counted it twice, and every PgUp jumped four
     rows short of the screenful the comment promises. *)
  let chrome = 7 in
  max 1 (rows - chrome - keeper_message_status_rows state)

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
            | Message_user label -> String.equal label "you"
            | Message_keeper | Message_autonomous | Message_status
            | Message_error | Message_tool
            | Message_thinking | Message_memory ->
                false)
           && String.equal entry.me_keeper_name target)
    |> List.map (fun entry -> entry.me_text)
  in
  (* Newest last, same as [sent], so one walk crosses both without a seam.
     A line leaves the queue and enters the history in the same step it is
     dispatched, so it is in exactly one of the two lists at any moment. *)
  let queued =
    Chat_queue.waiting state.msg_queued
    |> List.filter (fun (queued_keeper, _) ->
           String.equal queued_keeper target)
    |> List.map snd
  in
  sent @ queued

let set_composer_text (state : state) text =
  Buffer.clear state.msg_input;
  Buffer.add_string state.msg_input text

(* The draft is put aside on the first step back and handed over on the way
   forward past the newest, so a walk through the history never costs what was
   already typed. *)
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
    set_composer_text state (List.nth sent (count - 1 - at))
  end

let recall_newer (state : state) =
  match state.msg_recall_at with
  | None -> ()
  | Some 0 ->
      state.msg_recall_at <- None;
      set_composer_text state state.msg_recall_draft
  | Some at ->
      let sent = own_typed_messages state in
      let at = at - 1 in
      state.msg_recall_at <- Some at;
      let count = List.length sent in
      if count > at then set_composer_text state (List.nth sent (count - 1 - at))

(* Typing makes the composer the operator's again: the walk is over, so a step
   forward must not replace what they just wrote with a draft from before it. *)
let forget_recall (state : state) = state.msg_recall_at <- None

let handle_message_key (state : state) ~(submit_message : string -> unit)
    ~(answer_approval : tool_call_id:string -> allow:bool -> unit)
    ~(load_older : before:float -> unit) (key : string) : bool =
  (* y and n answer a held call, and only while one is held -- otherwise they
     are letters someone is typing. The prompt on screen is what makes them
     mean anything, so it is also what decides whether they are taken. *)
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
  match key with
  | "esc" ->
    leave_keeper_message state;
    true
  | "\r" ->
    let text = Buffer.contents state.msg_input in
    if String.trim text <> "" then begin
      (* Back to the newest row: the turn that is about to start is drawn
         there, and staying scrolled back would hide the send. *)
      state.msg_scroll <- 0;
      forget_recall state;
      submit_message text
    end;
    true
  | "\n" | "shift-enter" ->
    (* Ctrl-J, Shift+Enter with enhanced keys, or Return on a terminal that
       still translates it. A composer that cannot hold two lines makes an
       operator send two messages for one thought. *)
    forget_recall state;
    Buffer.add_char state.msg_input '\n';
    true
  | "up" when state.msg_scroll > 0 ->
    state.msg_scroll <- state.msg_scroll + 1;
    (match state.msg_older_cursor with
     | Some before when state.msg_older_exist && not state.msg_older_loading ->
         load_older ~before
     | Some _ | None -> ());
    true
  | "down" when state.msg_scroll > 0 ->
    state.msg_scroll <- max 0 (state.msg_scroll - 1);
    true
  | "up" ->
    recall_older state;
    true
  | "down" ->
    recall_newer state;
    true
  | "wheel-up" ->
    (* A notch is worth more than a row. The wheel used to arrive as the arrow
       key and moved one row with it, so reading back through a keeper turn --
       hundreds of rows -- took hundreds of notches. Three is what a terminal
       reports per detent, so a notch here covers what a notch covers
       everywhere else. *)
    state.msg_scroll <- state.msg_scroll + wheel_notch_rows;
    (match state.msg_older_cursor with
     | Some before when state.msg_older_exist && not state.msg_older_loading ->
         load_older ~before
     | Some _ | None -> ());
    true
  | "wheel-down" ->
    state.msg_scroll <- max 0 (state.msg_scroll - wheel_notch_rows);
    true
  | "pageup" ->
    (* A keeper's turn is many rows, so one row per press walks back through a
       single message. A page is the unit the reader actually moves in. *)
    state.msg_scroll <- state.msg_scroll + keeper_message_page_rows state;
    true
  | "pagedown" ->
    state.msg_scroll <-
      max 0 (state.msg_scroll - keeper_message_page_rows state);
    true
  | "end" ->
    state.msg_scroll <- 0;
    true
  | "\127" | "\b" ->
    forget_recall state;
    let new_content =
      Buffer.contents state.msg_input
      |> Masc_tui_message_layout.drop_last_utf8_scalar
    in
    Buffer.clear state.msg_input;
    Buffer.add_string state.msg_input new_content;
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
      state.msg_tool_visibility <- toggle_tool_visibility state.msg_tool_visibility;
      true
    end else if c = Some 6 then begin
      (* Ctrl-F folds the origin headings into the body's margin and then
         drops the clock from it, handing those rows back to the messages.
         Ctrl-O would have read better for an origin, but it is VDISCARD on
         this platform and [Unix.terminal_io] carries no IEXTEN field to turn
         that off, so the terminal would eat the key before the loop saw it. *)
      state.msg_origin_display <- next_origin_display state.msg_origin_display;
      true
    end else if c = Some 21 then begin
      (* Ctrl-U: clear the composer. The pasted text goes with it -- clearing
         is the operator saying they do not want what is there, and a spill
         that outlived it would attach to the next message. *)
      state.msg_spill <- None;
      Buffer.clear state.msg_input;
      true
    end else if c = Some 5 then begin
      (* Ctrl-E: back to the newest row. Scrolling down one row at a time from
         far back is worse than a key that ends the trip. *)
      state.msg_scroll <- 0;
      true
    end else if c = Some 11 then begin
      (* Ctrl-K: drop the newest waiting line without sending it. The queue
         shows what waits in the order it will go; the newest is the one a
         mis-send just hit, and dropping it is local — nothing was
         dispatched. *)
      (match Chat_queue.take_newest state.msg_queued with
       | None -> () (* nothing waits; consume quietly like Ctrl-U on empty *)
       | Some ((queued_keeper, _), rest) ->
         state.msg_queued <- rest;
         add_event state "info"
           (Printf.sprintf "Cancelled queued message to %s"
              (Keeper_chat.terminal_safe_text queued_keeper)));
      true
    end else if c = Some 16 then begin
      (* Ctrl-P: pull the newest waiting line back into the composer. That is
         the edit: fix it and Enter queues it again. *)
      (match Chat_queue.take_newest state.msg_queued with
       | None -> ()
       | Some ((_, text), rest) ->
         state.msg_queued <- rest;
         Buffer.clear state.msg_input;
         Buffer.add_string state.msg_input text);
      true
    end else if Masc_tui_message_layout.is_printable_utf8_scalar s then begin
      forget_recall state;
      Buffer.add_string state.msg_input s;
      true
    end else
      true  (* Consume but ignore other control chars *)

let keeper_message_input_supported state =
  let rows, cols = get_terminal_size () in
  Masc_tui_message_layout.message_viewport_supported ~terminal_rows:rows
    ~terminal_cols:cols ~status_rows:(keeper_message_status_rows state)

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

type http_surface_results = {
  http_overview: (overview_snapshot, string) result;
  http_transport: (Tui_decode.transport_health, string) result option;
  http_approvals: approval_observation option;
  (* [None] on surfaces that do not draw them. Each is read by one surface, and
     leaving it out keeps whatever that surface last observed rather than
     dropping it. *)
  http_board: (board_post list, string) result option;
  http_planning: (planning_snapshot, string) result option;
  http_system_logs: (system_log_snapshot, string) result option;
  http_fleet_safety: (Tui_decode.fleet_safety, string) result option;
  (* Mandatory on every refresh: the same endpoint may name a different
     server after a restart, without a failed request reaching this process. *)
  http_server_identity: (Tui_decode.server_identity, string) result;
  (* [None] on surfaces that do not show it: the roster costs a request and
     only the Keepers surface reads it, so leaving it out keeps whatever the
     last Keepers refresh observed rather than dropping it. *)
  http_keeper_roster:
    (Keeper_control.roster, Keeper_control.roster_failure) result option;
}

type async_msg =
  | Http_refresh_done of http_surface_results
  | Http_refresh_failed of string * Approval.Flow.generation option
  | Board_post_refresh_done of
      Board_detail.request * (board_post * board_comment list, string) result
  | Board_post_refresh_failed of Board_detail.request * string
  | Approval_decision_done of
      approval_item
      * approval_decision
      * (Approval.confirm_outcome, string) result
      * approval_observation
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
      Keeper_chat.request * (Masc_tui_http.interrupt_signal, string) result
  | Keeper_chat_history_loaded of
      int
      * string
      * (Keeper_chat_history.decoded, string) result
      * (Keeper_chat_history.decoded, string) result
  | Keeper_chat_older_loaded of
      int * string * float * (Keeper_chat_history.page, string) result
  | Lanes_loaded of (Masc.Tui_decode.keeper_lanes_snapshot, string) result
  | Verification_loaded of (Masc.Tui_decode.verification_snapshot, string) result
  | Harness_loaded of (Masc.Tui_decode.harness_snapshot, string) result
  | Fusion_runs_loaded of
      int * (Masc.Tui_decode.fusion_snapshot, string) result
  | Fusion_detail_loaded of
      int * string * (Masc.Tui_decode.fusion_detail, string) result
  | Repositories_loaded of (Masc.Tui_decode.repository_snapshot, string) result
  (* Carries the keeper it was asked about. The surface can be pointed at a
     different keeper while a load is in flight, and an answer that did not
     say whose it was would be filed under whoever is selected when it
     lands. *)
  | File_changes_loaded of
      string * (Masc.Tui_decode.file_change_snapshot, string) result
  (* Keyed by the path it answers for, for the same reason the file-change
     message carries a keeper: an answer for a file the operator has since
     left is not this view's answer. *)
  | Git_diff_loaded of string * (Masc.Tui_decode.git_diff, string) result
  | Connectors_loaded of (Masc.Tui_decode.connector_snapshot, string) result
  | Runtime_surface_loaded of
      int * (Masc_tui_loader.runtime_surface_load, string) result
  | Tools_loaded of (Masc.Tui_decode.tool_snapshot, string) result
  | Runtime_catalog_loaded of
      ( Masc.Tui_decode.runtime_option list
        * Masc.Tui_decode.runtime_assignment list,
        string )
      result
  | Runtime_assignment_set of
      string * string option * (unit, string) result
      (** keeper, the runtime it was pointed at ([None] = back to default),
          and whether the server took it. *)
  | Keeper_chat_approval_answered of
      Keeper_chat.request * string * bool * (bool, string) result
  | Keeper_tool_approvals_loaded of
      (Tui_decode.keeper_tool_approval list, string) result
  | Surface_tool_approval_answered of
      string * string * bool * (bool, string) result
  | Keeper_tool_modes_loaded of ((string * string) list, string) result
  | Keeper_tool_mode_set of string * string * (unit, string) result
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
  | Schedule_cancel_done of (string, string) result
  (* (message, noop): [noop = true] says the verdict already stood. *)
  | Verification_verdict_done of (string * bool, string) result
  | Keeper_calls_loaded of
      string * (Masc.Tui_decode.keeper_calls_snapshot, string) result
  | Keeper_config_view_loaded of string * (string list, string) result
  | Runtime_config_view_loaded of (string * string list, string) result
  | Prompts_loaded of (Tui_decode.prompts_snapshot, string) result
  | Resources_listed of ((string * string) list, string) result
  | Code_entries_loaded of
      string * (Masc.Tui_decode.workspace_tree_node list, string) result
  | Code_file_loaded of string * (string, string) result
  | Code_history_loaded of
      string * (Masc.Tui_decode.git_log_row list, string) result
  | Resource_read of string * (string list, string) result
  | Github_identity_view_loaded of string * (string list, string) result
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

let append_chat_history ?tool_block state request role text =
  let text = Keeper_chat.terminal_safe_text ~preserve_newlines:true text in
  state.msg_history <-
    state.msg_history
    @ [ {
          me_role = role;
          me_text = text;
          me_tool_block = tool_block;
          me_timestamp = current_clock_text ();
          me_keeper_name = request.Keeper_chat.keeper_name;
          me_request_id = request.request_id;
          me_at = Unix.gettimeofday ();
        } ]


let append_user_history_once state (request : Keeper_chat.request) =
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
    append_chat_history state request (Message_user "you") request.message

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
      let decoder = Keeper_chat_live.create () in
      (* Runs on this fiber between reads, so it only decodes and hands the
         result to the render loop; drawing happens there. *)
      let on_chunk chunk =
        match Keeper_chat_live.feed decoder chunk with
        | [] -> ()
        | deltas ->
            enqueue_async mailbox (Keeper_chat_stream_deltas (request, deltas))
      in
      Masc_tui_http.post_keeper_chat_streaming ~clock ~host ~port ~on_chunk
        request

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
      let block =
        Keeper_chat_transcript.tool_block
          (Keeper_chat_transcript.tool_calls live)
      in
      let projection =
        Keeper_chat_transcript.project_tool_block Keeper_chat_transcript.Full
          block
      in
      (match projection.rows with
       | [] -> ()
       | rows ->
           append_chat_history ~tool_block:block state request Message_tool
             (String.concat "\n" rows));
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
      (Surface_tool_approval_answered (keeper_name, tool_call_id, allow, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Surface_tool_approval_answered
           (keeper_name, tool_call_id, allow, Error "Eio switch is unavailable"))

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

let launch_keeper_tool_modes_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_keeper_tool_approval_modes ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_tool_modes_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_tool_modes_loaded (Error "Eio switch is unavailable"))

let launch_keeper_tool_mode_set state ~mailbox ~keeper_name ~mode =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        Masc_tui_http.post_keeper_tool_approval_mode ~host ~port ~keeper_name
          ~mode
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_tool_mode_set (keeper_name, mode, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_tool_mode_set
           (keeper_name, mode, Error "Eio switch is unavailable"))

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
  let run () =
    let result =
      try Masc_tui_loader.load_tools ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Tools_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None -> enqueue_async mailbox (Tools_loaded (Error "Eio switch is unavailable"))

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
let launch_keeper_calls_load state ~mailbox keeper_name =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_http.fetch_keeper_calls ~host ~port ~keeper_name ~limit:100
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Keeper_calls_loaded (keeper_name, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Keeper_calls_loaded (keeper_name, Error "Eio switch is unavailable"))

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
        | Ok session_id -> (
            match
              Masc_tui_http.call_mcp_resources_read ~host ~port ~session_id
                ~request_id ~uri
            with
            | Ok text ->
                Ok
                  (String.split_on_char '\n' text
                   |> List.map Masc.Tui_decode.sanitize_terminal_text)
            | Error _ as error -> error)
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
let code_scope_axes state =
  match state.code_scope with
  | Code_scope_project -> (None, None)
  | Code_scope_keeper keeper -> (Some keeper, None)
  | Code_scope_repo repo -> (None, Some repo)

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

let launch_code_history_load state ~mailbox ~path =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        let keeper, repo = code_scope_axes state in
        Masc_tui_http.fetch_git_log ?keeper ?repo ~host ~port ~path
          ~limit:code_history_limit ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Code_history_loaded (path, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (Code_history_loaded (path, Error "Eio switch is unavailable"))

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

(* Which line to open at.

   The tool call records what was written and not where it landed, so the line
   is found rather than known: the first line of the text the change wrote is
   looked up in the file as it stands. That is a match, not a record -- the
   same line may appear twice, and a later edit may have moved or removed it --
   so a miss falls back to the top of the file rather than to a guess. Opening
   at line 1 is visibly the top; opening at a wrong line looks like an answer.

   Only the first line is compared. An edit's text is usually several lines and
   the later ones are as likely to have changed since. *)
let change_line ~path (change : Masc.Tui_decode.file_change) =
  let wrote =
    match change.Masc.Tui_decode.fc_kind with
    | Masc.Tui_decode.Fc_edited { after; _ } -> after
    | Masc.Tui_decode.Fc_written _ -> ""
  in
  let needle =
    String.split_on_char '\n' wrote
    |> List.map String.trim
    |> List.find_opt (fun line -> String.length line > 0)
  in
  match needle with
  | None -> 1
  | Some needle -> (
      match open_in path with
      | exception Sys_error _ -> 1
      | channel ->
          let contains haystack =
            let n = String.length needle and h = String.length haystack in
            let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
            n > 0 && at 0
          in
          let rec scan number =
            match input_line channel with
            | exception End_of_file -> 1
            | line -> if contains line then number else scan (number + 1)
          in
          Fun.protect
            ~finally:(fun () -> try close_in channel with Sys_error _ -> ())
            (fun () -> scan 1))

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
let tree_diff_base_ref = "HEAD"

let launch_git_diff_load state ~mailbox ~keeper ~path =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try
        Masc_tui_loader.load_git_diff ~host ~port ~keeper ~path
          ~base_ref:tree_diff_base_ref
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

let launch_lanes_load state ~mailbox =
  let host = server_peer_host in
  let port = state.port in
  let run () =
    let result =
      try Masc_tui_loader.load_keeper_lanes ~host ~port with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    enqueue_async mailbox (Lanes_loaded result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None -> enqueue_async mailbox (Lanes_loaded (Error "Eio switch is unavailable"))

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
  | Lanes -> Some state.lanes_cursor
  | Verification -> Some state.verification_cursor
  | Harness -> Some state.harness_cursor
  | Repositories -> Some state.repositories_cursor
  | Connectors -> Some state.connectors_cursor
  | Runtime -> Some state.runtime_cursor
  | System_logs -> Some state.system_logs_cursor
  | Code -> Some state.code_cursor
  | _ -> None

let search_land state index =
  let follow scroll set_scroll =
    match scrolled_surface state state.view with
    | None -> ()
    | Some { sc_count = _; sc_chrome } ->
        let height = max 1 (surface_rows () - sc_chrome) in
        set_scroll (Masc_tui_scroll.ensure_visible ~cursor:index ~height scroll)
  in
  match state.view with
  | Keepers Keeper_list -> state.keeper_cursor <- index
  | Lanes ->
      state.lanes_cursor <- index;
      follow state.lanes_scroll (fun s -> state.lanes_scroll <- s)
  | Verification ->
      state.verification_cursor <- index;
      follow state.verification_scroll (fun s -> state.verification_scroll <- s)
  | Harness ->
      state.harness_cursor <- index;
      follow state.harness_scroll (fun s -> state.harness_scroll <- s)
  | Repositories ->
      state.repositories_cursor <- index;
      follow state.repositories_scroll (fun s -> state.repositories_scroll <- s)
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
      (* The tree pane windows itself around the cursor; no scroll follows. *)
      state.code_cursor <- index
  | _ -> ()

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
            if matches index then search_land state index else scan (step + 1)
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
  (match destination with
   | Lanes -> launch_lanes_load state ~mailbox
   | Approvals -> launch_keeper_tool_approvals_load state ~mailbox
   | Schedules -> launch_schedules_load state ~mailbox
   | Verification -> launch_verification_load state ~mailbox
   | Harness -> launch_harness_load state ~mailbox
   | Fusion ->
       launch_fusion_runs_load state ~mailbox;
       (match state.fusion_mode with
        | Fusion_list -> ()
        | Fusion_detail run_id ->
            launch_fusion_detail_load state ~mailbox ~run_id)
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
   | Config ->
       if state.config_prompts then launch_prompts_load state ~mailbox
       else launch_runtime_config_load state ~mailbox
   | Resources -> launch_resources_list state ~mailbox
   | Code -> launch_code_entries_load state ~mailbox
   | Overview | Acting | Keepers _ | Board | Planning | System_logs -> ());
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

let launch_keeper_history_load state ~mailbox ~keeper_name =
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
  match Eio_context.get_switch_opt () with
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
           , Error "Eio switch is unavailable" ))

let switch_to_next_keeper_message state ~mailbox =
  match next_keeper_message_target state with
  | Masc_tui_keeper_selection.No_alternative -> ()
  | Masc_tui_keeper_selection.Switch_to { keeper_name; cursor } ->
      open_message_for_keeper ~return_to:state.msg_return state keeper_name;
      state.keeper_cursor <- cursor;
      state.msg_scroll <- 0;
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
  let failures_the_transcript_holds =
    List.filter_map
      (fun (row : Keeper_chat_history.row) ->
        match row.Keeper_chat_history.kind with
        | Keeper_chat_history.Delivery_failed { origin_request_id } ->
            origin_request_id
        | Keeper_chat_history.Addressed_to_keeper _
        | Keeper_chat_history.Said_by_keeper
        | Keeper_chat_history.Autonomous_reply
        | Keeper_chat_history.Tool_calls _
        | Keeper_chat_history.Reasoning _
        | Keeper_chat_history.Memory_activity -> None)
      rows
  in
  state.msg_history <-
    List.filter
      (fun entry ->
        (not (String.equal entry.me_keeper_name keeper_name))
        ||
        match entry.me_role with
        | Message_status -> true
        | Message_error ->
            String.equal entry.me_request_id ""
            || not
                 (List.exists
                    (String.equal entry.me_request_id)
                    failures_the_transcript_holds)
        | Message_user _ | Message_keeper | Message_autonomous | Message_tool
        | Message_thinking | Message_memory ->
            false)
      state.msg_history

let msg_entry_of_history_row keeper_name (row : Keeper_chat_history.row) =
  let role, text, tool_block =
    match row.Keeper_chat_history.kind with
    | Keeper_chat_history.Addressed_to_keeper { speaker; surface } ->
        ( Message_user (Keeper_chat_history.addressed_label speaker surface)
        , row.text
        , None )
    | Keeper_chat_history.Said_by_keeper -> (Message_keeper, row.text, None)
    | Keeper_chat_history.Autonomous_reply ->
        ( Message_autonomous
        , (if String.trim row.text = "" then "\xc2\xb7" else row.text)
        , None )
    | Keeper_chat_history.Delivery_failed _ -> (Message_error, row.text, None)
    | Keeper_chat_history.Tool_calls block ->
        ( Message_tool
        , String.concat "\n" (Keeper_chat_history.tool_rows block)
        , Some block )
    | Keeper_chat_history.Reasoning lines ->
        (Message_thinking, String.concat "\n" lines, None)
    | Keeper_chat_history.Memory_activity -> (Message_memory, row.text, None)
  in
  let timestamp =
    match row.Keeper_chat_history.kind with
    | Keeper_chat_history.Memory_activity
      when Float.equal row.Keeper_chat_history.at 0.0 ->
        "--:--:--"
    | _ -> clock_text_of_unix row.Keeper_chat_history.at
  in
  { me_role = role
  ; me_text = Keeper_chat.terminal_safe_text ~preserve_newlines:true text
  ; me_tool_block = tool_block
  ; me_timestamp = timestamp
  ; me_keeper_name = keeper_name
  ; (* The transcript carries no request id: these rows predate this session, or
       came from another client. The pane shows the compacted id beside a row,
       so an empty one is what says "not from a request this session made". *)
    me_request_id = ""
  ; me_at = row.Keeper_chat_history.at
  }

let launch_keeper_interrupt state ~mailbox (request : Keeper_chat.request) =
  let host = server_peer_host in
  let port = state.port in
  let keeper_name = request.Keeper_chat.keeper_name in
  let run () =
    let result =
      try Masc_tui_http.post_keeper_turn_interrupt ~host ~port ~keeper_name
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
        Masc_tui_http.post_runtime_assignment ~host ~port ~keeper_name
          ~runtime_id
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
let launch_keeper_request state ~mailbox request =
  let live =
    Keeper_chat_transcript.create
      ~keeper_name:request.Keeper_chat.keeper_name
      ~request_id:request.request_id
      ~started_at:(Unix.gettimeofday ())
  in
  state.msg_inflight <-
    { sent_request = request; sent_at = Unix.gettimeofday (); live }
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

let queue_keeper_message state ~keeper_name text =
  match Chat_queue.push state.msg_queued ~keeper_name text with
  | Error _ as error -> error
  | Ok (queue, waiting) ->
      state.msg_queued <- queue;
      Ok waiting
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
      (* Read through [send_disposition] rather than the state directly: the
         footer answers the same question the same way, and the two drifting
         apart is what put "Enter:blocked" on a screen that also said
         "queued 1". *)
      match send_disposition state ~keeper_name:target with
      | Sends ->
          let request =
            Keeper_chat.create_request ~keeper_name:target ~message:text
          in
          launch_keeper_request state ~mailbox request
      | Queues_behind request -> (
          (* A turn to this keeper is already running. Hold the line rather than
             refusing it: the operator pressed Enter meaning "send this next",
             and the turn settling is what "next" is. *)
          match queue_keeper_message state ~keeper_name:target text with
          | Error detail -> add_event state "error" detail
          | Ok waiting ->
              clear_current_message_draft state;
              add_event state "message"
                (Printf.sprintf "Queued for %s behind %s (%d waiting)"
                   (Keeper_chat.terminal_safe_text target)
                   request.Keeper_chat.request_id waiting)))
;;

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
        Option.is_none (inflight_for state keeper_name))
    with
    | None -> ()
    | Some ((keeper_name, text), rest) ->
        if keeper_available_for_new_message state keeper_name
        then (
          state.msg_queued <- rest;
          start_keeper_message ~keeper_name state ~base_path ~mailbox text;
          next ())
        else (
          (* The keeper this was written to is no longer registered. Sending it
             would fail; holding it would leave a count reporting work that
             never moves. Say what is being let go, and let it go. *)
          let before = Chat_queue.length state.msg_queued in
          state.msg_queued <-
            Chat_queue.drop_for_keeper state.msg_queued ~keeper_name;
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
  | Keeper_chat.External_effect_completed ->
      Printf.sprintf "External effect completed (turn %s)" turn_ref
  | Keeper_chat.External_effect_pending ->
      Printf.sprintf "External effect remains pending (turn %s)" turn_ref
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
              me_text = Keeper_chat.terminal_safe_text ~preserve_newlines:true text;
              me_tool_block = None;
              me_timestamp = current_clock_text ();
              me_keeper_name = keeper;
              me_request_id = "";
              me_at = Unix.gettimeofday ();
            } ]
  | None ->
      add_event state
        (match role with Message_error -> "error" | _ -> "system")
        text

(* Whether this terminal draws pictures. Asked once, before the first frame,
   and remembered: the answer cannot change while the process runs, and asking
   again would put another reply on the key stream. [None] until asked. *)
let terminal_draws_images = ref None

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

(* Put a picture on the terminal, or say why not. The refusal is text for the
   pane: there is nothing to draw, and taking the screen away from the frame
   to say so would hide the only surface that can say it. *)
let open_image state ~notice path =
  let refuse reason =
    notice ~role:Message_error (Printf.sprintf "/image %s: %s" path reason)
  in
  match !terminal_draws_images with
  | Some false ->
      refuse
        "this terminal does not draw images (it did not answer the graphics query)"
  | Some true | None -> (
      match read_file_bytes path with
      | Error detail -> refuse detail
      | Ok data when String.length data = 0 -> refuse "the file is empty"
      | Ok data ->
          let rows, columns = get_terminal_size () in
          (* Two rows kept back: one names the file above the picture, one
             says how to leave below it. *)
          let box =
            { Masc_tui_graphics.columns = max 1 (columns - 2)
            ; rows = max 1 (rows - 3)
            }
          in
          write_to_terminal
            (Ansi.clear ^ Masc_tui_graphics.delete_all
            ^ Printf.sprintf "\x1b[1;1H%s\x1b[2;1H"
                (Message_layout.fit_width path (max 1 (columns - 1)))
            ^ Masc_tui_graphics.place ~data box
            ^ Printf.sprintf "\x1b[%d;1H%s" rows
                (Message_layout.fit_width "  any key: back"
                   (max 1 (columns - 1))));
          state.image_open <-
            Some { image_path = path; image_bytes = String.length data })

(* Take the picture away and give the frame back. The terminal holds images in
   its own layer, so clearing the screen is not enough to remove one. *)
let close_image state =
  match state.image_open with
  | None -> ()
  | Some _ ->
      state.image_open <- None;
      write_to_terminal Masc_tui_graphics.delete_all

let send_operator_text ?keeper_name state ~base_path ~mailbox text =
  let target =
    match keeper_name with
    | Some _ as named -> named
    | None -> state.msg_target_keeper_name
  in
  let notice = chat_notice state ~keeper_name:target in
  match Masc_tui_command.parse text with
  | Masc_tui_command.Say _ ->
      start_keeper_message ?keeper_name state ~base_path ~mailbox text
  | Masc_tui_command.Task_missing_title ->
      add_event state "error" "/task needs a title on the same line"
  | Masc_tui_command.View_image_missing_path ->
      notice ~role:Message_error "/image needs a path on the same line"
  | Masc_tui_command.View_image path ->
      Buffer.clear state.msg_input;
      open_image state ~notice (String.trim path)
  | Masc_tui_command.Help ->
      Buffer.clear state.msg_input;
      notice ~role:Message_status
        (String.concat "\n" Masc_tui_command.help_lines)
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
          | None -> notice ~role:Message_status "no turn of this pane's to interrupt")
      | Some _ ->
          notice ~role:Message_status
            "an interrupt is already outstanding for this turn"
      | None -> notice ~role:Message_status "no turn is streaming in this pane")
  | Masc_tui_command.Set_thinking mode ->
      Buffer.clear state.msg_input;
      state.msg_reasoning_visibility <-
        (match mode with
         | `Hidden -> Reasoning_hidden
         | `Folded -> Reasoning_folded
         | `Full -> Reasoning_full
         | `Cycle -> next_reasoning_visibility state.msg_reasoning_visibility);
      notice ~role:Message_status
        ("reasoning "
         ^ reasoning_visibility_to_string state.msg_reasoning_visibility)
  | Masc_tui_command.Set_tools mode ->
      Buffer.clear state.msg_input;
      state.msg_tool_visibility <-
        (match mode with
         | `Compact -> Tools_compact
         | `Full -> Tools_full
         | `Toggle -> toggle_tool_visibility state.msg_tool_visibility);
      notice ~role:Message_status
        ("tool calls " ^ tool_visibility_to_string state.msg_tool_visibility)
  | Masc_tui_command.Toggle_memory ->
      Buffer.clear state.msg_input;
      state.msg_memory_visible <- not state.msg_memory_visible;
      notice ~role:Message_status
        (if state.msg_memory_visible
         then "Librarian/Memory timeline shown (/memory to hide)"
         else "Librarian/Memory timeline hidden (/memory to show)")
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
             | Keeper_chat.External_effect_completed
             | Keeper_chat.External_effect_pending
             | Keeper_chat.No_visible_reply -> Message_status
           in
           append_chat_history state request role (chat_status_text completed);
           add_event state "message"
             (Printf.sprintf "Keeper turn finished: %s" request.request_id)
       | Ok (Keeper_chat.Replayed_succeeded _) ->
           (* The server answered [Existing] for this id: the turn already ran
              and this POST produced no second one. *)
           append_chat_history state request Message_status
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
             match
               Keeper_chat.error_certainty ~was_unverified:false error
             with
             | Keeper_chat.Verified_rejected | Keeper_chat.Verified_failed ->
                 detail
             | Keeper_chat.Outcome_unverified ->
                 (* The POST did not come back with an answer, so the turn may
                    have run anyway. Nothing here has to reconcile it: the
                    transcript reloads from the server after every settle, and
                    a turn that ran appears there. Sending the line again is
                    safe too — that request carries a new id, so the server
                    treats it as the new message it is. *)
                 Printf.sprintf
                   "Outcome unverified for %s; the turn may still be running. The transcript reload will show it. %s"
                   request.request_id detail
           in
           append_chat_history state request Message_error detail;
           add_event state "error"
             (Printf.sprintf "Keeper message %s: %s" request.request_id detail));
      true
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
  state.board_focus <- Board_detail_pane;
  state.board_scroll <- 0;
  state.board_detail <- Board_detail.clear state.board_detail

let leave_missing_board_detail state =
  match state.board_mode with
  | Board_read post_id
    when not (List.exists (fun post -> String.equal post.bp_id post_id) state.board_posts) ->
      leave_board_detail state
  | Board_list | Board_read _ | Board_compose -> ()

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
      state.system_logs_error <- None
  | Error detail ->
      (* The previous page stays on screen; the error line says the count above
         it is stale rather than letting it read as a fresh zero. *)
      state.system_logs_error <- Some detail

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
        planning_visible_goals planning.pl_goals
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

let load_http_surfaces ~host ~port ~approval_generation
    ~(needs : Masc_tui_types.surface_needs) =
  let when_needed wanted load = if wanted then Some (load ()) else None in
  let http_overview = load_overview ~host ~port in
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
  let http_board =
    when_needed needs.needs_board (fun () -> load_board_list ~host ~port)
  in
  let http_planning =
    when_needed needs.needs_planning (fun () -> load_planning ~host ~port)
  in
  let http_system_logs =
    when_needed needs.needs_system_logs (fun () ->
        load_system_logs ~host ~port ~limit:system_log_page)
  in
  let http_fleet_safety =
    when_needed needs.needs_fleet_safety (fun () -> load_fleet_safety ~host ~port)
  in
  (* A process can disappear and another bind the same endpoint between two
     successful ticks. The compact /health identity is therefore revalidated
     on every refresh rather than inferred from connection failure. *)
  let http_server_identity = load_server_identity ~host ~port in
  let http_keeper_roster =
    when_needed needs.needs_keeper_roster (fun () ->
        load_keeper_roster ~host ~port)
  in
  { http_overview
  ; http_transport
  ; http_approvals
  ; http_board
  ; http_planning
  ; http_system_logs
  ; http_fleet_safety
  ; http_server_identity
  ; http_keeper_roster
  }

let apply_http_surfaces state results =
  apply_overview_load state results.http_overview;
  Option.iter (apply_transport_load state) results.http_transport;
  Option.iter (apply_approval_observation state) results.http_approvals;
  Option.iter (apply_board_list_load state) results.http_board;
  Option.iter (apply_planning_load state) results.http_planning;
  Option.iter (apply_system_logs_load state) results.http_system_logs;
  Option.iter (apply_fleet_safety_load state) results.http_fleet_safety;
  (* This is a current reading, not a last-known cache. A failed probe makes
     the projection unread; every following refresh asks again, so a same-port
     replacement still moves A -> B as soon as /health succeeds. *)
  state.server_identity <-
    Masc_tui_types.server_identity_of_refresh results.http_server_identity;
  Option.iter (apply_keeper_roster_load state) results.http_keeper_roster;
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
       @ reached_if_asked results.http_board
       @ reached_if_asked results.http_planning
       @ (Option.map
            (fun observation -> reached observation.ao_result)
            results.http_approvals
          |> Option.to_list))

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

let start_http_refresh state ~host ~port ~refresh_inflight ~mailbox =
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
    let needs = Masc_tui_types.surface_needs state.view in
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
    (* Held tool calls ride every tick, not just the Approvals surface: the
       strip's Approvals badge is drawn from every surface, and a stale count
       there would be worse than none. The payload is a handful of rows. *)
    launch_keeper_tool_approvals_load state ~mailbox;

    let run_refresh () =
      try
        enqueue_async mailbox
          (Http_refresh_done
             (load_http_surfaces ~host ~port ~approval_generation ~needs))
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
               (load_http_surfaces ~host ~port ~approval_generation ~needs))
  end

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
      (open_board_post state ~mailbox ~focus:Board_posts_pane)
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
  load_from_masc_dir state base_path

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

(* The cancel key on the row under the cursor. Two presses, like the vote
   keys: the first names the schedule, the same press again sends it. The
   schedule id is captured at arm time, so moving the cursor between presses
   re-arms for the new row rather than cancelling the one the operator left. *)
let handle_schedule_cancel_key state ~mailbox =
  let rows =
    match state.schedules with
    | None -> []
    | Some snapshot -> snapshot.scs_rows
  in
  let selected =
    match state.schedule_detail_id with
    | Some schedule_id ->
        List.find_opt
          (fun row -> String.equal row.sch_schedule_id schedule_id)
          rows
    | None -> List.nth_opt rows state.schedule_cursor
  in
  match selected with
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
  List.nth_opt requests state.verification_cursor

(* The approve key on the row under the cursor. Two presses, like the cancel
   and vote keys: the first names the task, the same press again sends the
   verdict. The task id is captured at arm time, so moving the cursor between
   presses re-arms for the new row rather than approving the one the operator
   left. Reject is not armed -- its $EDITOR reason form is the confirmation. *)
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

(* The keypress path. The reading decides which actions exist at all, so a key
   that names an action the reading does not offer says why instead of sending
   a request the server would refuse. *)
let handle_keeper_action state ~base_path ~mailbox action =
  match selected_keeper state with
  | None -> ()
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

(* The composer as the key loop sees it. The renderer builds the same reading
   for the row it draws, so the key that lands and the row the operator read
   before pressing it agree on who the recipient is. *)
let composer_state (state : state) : Composer.t =
  let target =
    match selected_keeper state with
    | None -> Composer.No_target
    | Some keeper ->
        if keeper_available_for_new_message state keeper.k_name then
          Composer.Ready keeper.k_name
        else
          Composer.Unreachable
            { keeper = keeper.k_name
            ; reason =
                (match state.keepers_error with
                 | Some _ -> "keeper list unread"
                 | None -> "no longer in the roster")
            }
  in
  { Composer.target
  ; focus =
      (if state.composer_focused then Composer.Focused else Composer.Unfocused)
  ; draft = Buffer.contents state.msg_input
  }

(* Apply one keystroke the composer claimed. Sending routes through the same
   chat surface the [c] key opens, so a message typed on the roster and one
   typed in the chat view take the identical dispatch path. *)
let handle_composer_key state ~base_path ~mailbox key =
  let composer = composer_state state in
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
  | Composer.Release_focus ->
      save_message_draft state;
      state.composer_focused <- false;
      true
  | Composer.Send ->
      state.composer_focused <- false;
      let text = Buffer.contents state.msg_input in
      (match Masc_tui_command.parse text with
       | Masc_tui_command.Say _ ->
           state.msg_scroll <- 0;
           state.view <- Keepers Keeper_message
       | Masc_tui_command.Switch_keeper _ ->
           (* The switch handler owns the view change. *)
           state.msg_scroll <- 0
       | Masc_tui_command.Task_for_keeper _ | Masc_tui_command.Task_missing_title
       | Masc_tui_command.Help | Masc_tui_command.Switch_keeper_missing_name
       | Masc_tui_command.Interrupt_turn | Masc_tui_command.Set_thinking _
       | Masc_tui_command.Set_tools _ | Masc_tui_command.Toggle_memory
       | Masc_tui_command.View_image _ | Masc_tui_command.View_image_missing_path
       | Masc_tui_command.Unknown _ ->
           (* A command keeps the surface: the operator asked the TUI, not
              the keeper, and the answer lands in Recent Events. *)
           ());
      send_operator_text state ~base_path ~mailbox text;
      true
  | Composer.Edit ->
      let _handled =
        handle_message_key state
          ~submit_message:(fun _ -> ())
          ~answer_approval:(fun ~tool_call_id:_ ~allow:_ -> ())
          ~load_older:(fun ~before:_ -> ())
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

let handle_paste state ~base_path ~mailbox ~(paste : Masc_tui_paste.t) =
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

let apply_async_message state ~base_path ~http_refresh_inflight ~mailbox =
  function
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
        ~host:(server_peer_host) ~port:state.port ~mailbox
  | Observer_opened session_id ->
      state.mcp_session <- Some session_id;
      state.observer <-
        Observer_live { session_id; since = Unix.gettimeofday (); events = 0 };
      add_event state "observer" "runtime event feed open"
  | Observer_received decoded ->
      let received = Unix.gettimeofday () in
      List.iter
        (fun item ->
          match item with
          | Masc_tui_observer.Event event ->
              (match state.observer with
               | Observer_live live ->
                   state.observer <-
                     Observer_live { live with events = live.events + 1 }
               | Observer_off | Observer_opening | Observer_closed _ -> ());
              state.acting <-
                { ae_at = received; ae_event = event } :: state.acting;
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
            ~event_of:(fun entry -> entry.Masc_tui_types.ae_event)
            state.acting
        in
        state.acting <- kept;
        state.acting_dropped <- state.acting_dropped + dropped
      end
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
      state.msg_scroll <- 0;
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
      add_event state "error" err
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
        ~port:state.port ~refresh_inflight:http_refresh_inflight ~mailbox
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
            ~port:state.port ~refresh_inflight:http_refresh_inflight ~mailbox;
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
            ~port:state.port ~refresh_inflight:http_refresh_inflight ~mailbox
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
            ~port:state.port ~refresh_inflight:http_refresh_inflight ~mailbox
      | Error err ->
          state.goal_action_armed <- None;
          state.goal_action_error <- Some err)
  | Keeper_calls_loaded (keeper_name, result) -> (
      let still_selected =
        match List.nth_opt state.keepers state.keeper_cursor with
        | Some keeper -> String.equal keeper.k_name keeper_name
        | None -> false
      in
      if still_selected then
        match result with
        | Ok snapshot ->
            state.keeper_calls <- Some snapshot;
            state.keeper_calls_error <- None
        | Error detail -> state.keeper_calls_error <- Some detail)
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
  | Prompts_loaded result ->
      (match result with
       | Ok snapshot ->
           state.prompts_snapshot <- Some snapshot;
           state.prompts_error <- None
       | Error detail -> state.prompts_error <- Some detail)
  | Runtime_config_view_loaded result -> (
      match result with
      | Ok view ->
          state.runtime_config_view <- Some view;
          state.runtime_config_view_error <- None
      | Error detail -> state.runtime_config_view_error <- Some detail)
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
          state.code_focus_file <- true;
          (* A new file starts on its content; the old file's history would
             caption the wrong bytes. *)
          state.code_history <- None;
          state.code_history_error <- None;
          state.code_history_open <- false;
          state.code_history_scroll <- 0
      | Error detail -> state.code_file_error <- Some detail)
  | Code_history_loaded (path, result) ->
      (* Keyed to the file still open: a listing that raced a file switch
         describes bytes no longer on screen. *)
      let still_current =
        match state.code_file with
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
              (fun (uri, name) ->
                ( Masc.Tui_decode.sanitize_terminal_text uri,
                  Masc.Tui_decode.sanitize_terminal_text name ))
              rows
          in
          state.resources_list <- Some rows;
          state.resources_error <- None;
          state.resources_cursor <-
            max 0 (min state.resources_cursor (List.length rows - 1))
      | Error detail -> state.resources_error <- Some detail)
  | Resource_read (uri, result) -> (
      match result with
      | Ok lines ->
          state.resource_content <- Some (uri, lines);
          state.resource_content_error <- None;
          state.resource_scroll <- 0
      | Error detail -> state.resource_content_error <- Some detail)
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
  | Approval_decision_done (approval, decision, result, approvals) ->
      apply_approval_decision_completion state approvals.ao_generation approval
        decision result approvals.ao_result
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
              append_user_history_once state request;
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
  | Keeper_chat_done (request, was_replay, result, acknowledge) ->
      settle_live_turn state request;
      (* The server persists the user row, the reply and the tool calls before
         it ends the stream, so by now the transcript holds this turn. While
         the pane still points here, reloading makes that record the thing on
         screen; the rows settle_live_turn just committed are what stands if
         the load fails. A background Keeper does not supersede the visible
         Keeper's history generation. *)
      if
        Option.exists
          (String.equal request.Keeper_chat.keeper_name)
          state.msg_target_keeper_name
      then
        launch_keeper_history_load state ~mailbox
          ~keeper_name:request.Keeper_chat.keeper_name;
      let applied =
        Fun.protect
          ~finally:(fun () -> Eio.Promise.resolve acknowledge ())
          (fun () ->
            apply_keeper_chat_result state request result)
      in
      if applied then load_from_masc_dir state base_path;
      (* The turn settled, so "next" has arrived for whatever was waiting. *)
      drain_queued_message state ~base_path ~mailbox
  | Keeper_chat_stream_deltas (request, deltas) ->
      (* Each Keeper can stream independently. Looking up the request keeps a
         background turn from replacing the selected Keeper's transcript and
         keeps its tool rows available when that turn settles. *)
      (match
         inflight_entry_by_request_id state request.Keeper_chat.request_id
       with
       | Some entry
         when Keeper_chat.same_request_identity entry.sent_request request ->
           List.iter (Keeper_chat_transcript.apply entry.live) deltas
       | Some _ | None -> ())
  | Keeper_chat_stream_unavailable (request, detail) ->
      append_chat_history state request Message_status detail
  | Keeper_chat_approval_answered (request, tool_call_id, allow, result) ->
      let text =
        match result with
        | Ok true ->
            Printf.sprintf "%s %s"
              (if allow then "allowed" else "denied")
              (Keeper_chat.compact_request_id tool_call_id)
        | Ok false ->
            (* The wait was gone: it timed out, or something answered it
               first. Said plainly rather than shown as taken, so an operator
               is not told a call was allowed when nothing was listening. *)
            Printf.sprintf
              "too late for %s; the call was no longer waiting"
              (Keeper_chat.compact_request_id tool_call_id)
        | Error detail -> "could not answer the held call: " ^ detail
      in
      append_chat_history state request
        (match result with Ok true -> Message_status | _ -> Message_error)
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
  | Keeper_tool_modes_loaded result ->
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
  | Keeper_tool_mode_set (keeper_name, mode, result) ->
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
  | Surface_tool_approval_answered (keeper_name, tool_call_id, allow, result) ->
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
        (match result with Ok true -> "system" | _ -> "error")
        (match result with
         | Ok true ->
             Printf.sprintf "%s %s's held call %s"
               (if allow then "allowed" else "denied")
               keeper_name
               (Keeper_chat.compact_request_id tool_call_id)
         | Ok false ->
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
             | Ok (Masc_tui_http.Signalled { turn_id }) ->
                 Keeper_chat_transcript.Signal_sent { turn_id }
             | Ok (Masc_tui_http.Not_signalled { reason; detail }) ->
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
             (* Where reading further back starts. The oldest row this load
                carried is the cursor; if it carried none there is nothing to
                page back from. Whether older rows exist is only learned by
                asking, so the pane assumes they might and finds out on the
                first page. *)
             state.msg_older_cursor <-
               List.fold_left
                 (fun oldest (row : Keeper_chat_history.row) ->
                   match oldest with
                   | None -> Some row.Keeper_chat_history.at
                   | Some at ->
                       Some (Float.min at row.Keeper_chat_history.at))
                 None rows;
             state.msg_older_exist <- Option.is_some state.msg_older_cursor;
             state.msg_older_error <- None;
             forget_session_rows_the_transcript_holds state keeper_name rows;
             List.map (msg_entry_of_history_row keeper_name) rows
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
              List.map (msg_entry_of_history_row keeper_name) rows
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
          state.tools_error <- None
      | Error detail -> state.tools_error <- Some detail)
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
      | Ok () ->
          add_event state "system"
            (match runtime_id with
             | Some id -> Printf.sprintf "%s now runs on %s" keeper_name id
             | None ->
                 Printf.sprintf "%s is back on the default runtime" keeper_name);
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
          state.connectors <- Some snapshot;
          state.connectors_error <- None
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
                  state.runtime_surface_error <- None
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
  | File_changes_loaded (keeper_name, result) ->
      (* An answer for a keeper the surface has since left is not this
         surface's answer. Dropping it keeps one keeper's files from being
         drawn under another's name. *)
      if Option.equal String.equal state.changes_keeper (Some keeper_name) then (
        match result with
        | Ok snapshot ->
            state.changes <- Some snapshot;
            state.changes_error <- None;
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
      | Ok snapshot ->
          state.lanes <- Some snapshot;
          state.lanes_error <- None
      | Error detail ->
          (* Keep the previous rows visible. The error says that they are
             stale; clearing them would turn a failed refresh into an empty
             reading. *)
          state.lanes_error <- Some detail)
  | Harness_loaded result -> (
      match result with
      | Ok snapshot ->
          state.harness <- Some snapshot;
          state.harness_error <- None
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
          state.verification_error <- None
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
              List.map
                (msg_entry_of_history_row keeper_name)
                page.Keeper_chat_history.decoded.Keeper_chat_history.rows
            in
            (* Prepended, not merged: these are strictly older than everything
               loaded, and the pane orders the whole list by time anyway. *)
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
let drain_async_messages state ~base_path ~http_refresh_inflight mailbox =
  let rec loop changed =
    match Eio.Stream.take_nonblocking mailbox with
    | None -> changed
    | Some msg ->
        apply_async_message state ~base_path ~http_refresh_inflight ~mailbox
          msg;
        loop true
  in
  loop false

let invalidate_frame_for_resize frame_presenter render_schedule =
  invalidate_terminal_size ();
  Frame_presenter.invalidate frame_presenter;
  Render_schedule.request render_schedule Render_schedule.Force

let request_console_write_repair render_schedule =
  Terminal_write_repair.request_repaint render_schedule

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
  | Overview | Acting | Lanes | Board | Approvals | Planning | Schedules
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

let enter_terminal_session ~cleanup ~terminate ~request_interrupt
    ~request_full_repaint ~suspend ~new_term =
  at_exit cleanup;
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
  Unix.tcsetattr Unix.stdin Unix.TCSANOW new_term

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
  let ( base_path
      , workspace
      , port
      , refresh
      , reasoning_visibility
      , tool_visibility ) =
    parse_args ()
  in
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
    create_state ~reasoning_visibility ~tool_visibility ~workspace ~port
      ~refresh_interval:refresh ()
  in
  state.view <- Overview;

  (* Setup terminal *)
  let old_term = Unix.tcgetattr Unix.stdin in
  (* c_icrnl off so Return and Ctrl-J arrive as themselves. With the terminal's
     default translation on, Return is delivered as LF -- the same byte Ctrl-J
     sends -- and the composer cannot tell "send this" from "start a new line".
     LF still submits below if some terminal sends it for Return, so this only
     ever adds a key. *)
  let new_term =
    { old_term with Unix.c_icanon = false; c_echo = false; c_icrnl = false }
  in

  let frame_presenter =
    Frame_presenter.create
      ~synchronized_output:(synchronized_output_enabled ()) ()
  in
  let terminal_title = Terminal_title.create () in
  let resize_requested = Atomic.make false in

  let restore_terminal () =
    (* No tracking-off here: suspend runs this too, and a terminal that
       re-enters raw mode after Ctrl-Z would silently lose the wheel. The
       off byte is written once, in [cleanup], at real process exit. *)
    Frame_presenter.cleanup frame_presenter ~write:(output_string stdout)
      ~flush:(fun () -> flush stdout);
    Terminal_title.clear terminal_title ~write:(output_string stdout)
      ~flush:(fun () -> flush stdout);
    Unix.tcsetattr Unix.stdin Unix.TCSANOW old_term
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
        Unix.tcsetattr Unix.stdin Unix.TCSANOW new_term;
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
  output_string stdout mouse_tracking_enable;
  output_string stdout bracketed_paste_enable;
  (* Asks the terminal to report which modifiers were held. A terminal that
     does not know the request ignores it and keeps sending the legacy forms,
     which the same vocabulary already reads -- so this is written without a
     capability query, the way the two modes above are. *)
  output_string stdout Masc_tui_csi.enable_kitty_keyboard;
  flush stdout;

  (* Initial load *)
  load_from_masc_dir state base_path;
  let host = server_peer_host in
  let port = state.port in
  let http_refresh_inflight = ref false in
  let async_messages = Eio.Stream.create 32 in
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
  start_http_refresh state ~host ~port ~refresh_inflight:http_refresh_inflight
    ~mailbox:async_messages;
  add_event state "system" "TUI started";

  (* Main loop *)
  let refresh_interval_ns =
    Int64.of_float (max 0.0 refresh *. nanoseconds_per_second)
  in
  let last_check_ns = ref (Mtime_clock.elapsed_ns ()) in
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
     [suspend] already runs around Ctrl-Z. *)
  let reenter_terminal () =
    Unix.tcsetattr Unix.stdin Unix.TCSANOW new_term;
    request_full_repaint 0
  in
  (* An empty object is the honest starting point for a partial patch: the
     config route applies only the fields present in the body, and the TUI
     has no view of the current settings to prefill from -- showing a
     guessed stem would invite an operator to "keep" a value that is not
     the one on disk. *)
  (* runtime.toml edit: $EDITOR over the text the Config surface shows,
     then the server's preview validation; only a preview that passes is
     written. A failed preview keeps the operator's text out of the file
     and puts the validator's words in Recent Events. *)
  (* Connector bind/unbind: the form is three fields, and $EDITOR is the
     form we already have. The name field picks the connector; the rest is
     the route's body. *)
  let handle_connector_form ~action ~stem ~post () =
    match Masc_tui_editor.editor_command () with
    | None ->
      add_event state "error"
        ("no $EDITOR set; export EDITOR to " ^ action ^ " here")
    | Some _ -> (
      match
        Masc_tui_editor.roundtrip ~restore:restore_terminal
          ~reenter:reenter_terminal stem
      with
      | None -> add_event state "system" (action ^ " cancelled")
      | Some body -> (
        match Yojson.Safe.from_string body with
        | exception Yojson.Json_error e ->
          add_event state "error" (action ^ ": body is not JSON: " ^ e)
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
          match field "name" with
          | None -> add_event state "error" (action ^ ": \"name\" is required")
          | Some connector -> (
            match post ~connector ~json with
            | Ok _ ->
              add_event state "system" (action ^ ": ok (" ^ connector ^ ")");
              launch_connectors_load state ~mailbox:async_messages
            | Error detail -> add_event state "error" (action ^ ": " ^ detail)))))
  in
  let handle_connector_bind () =
    let host = server_peer_host in
    let port = state.port in
    handle_connector_form ~action:"bind"
      ~stem:
        "{\n  \"name\": \"discord\",\n  \"channel_id\": \"\",\n  \"keeper_name\": \"\"\n}\n"
      ~post:(fun ~connector ~json ->
        Masc_tui_http.post_connector_bind ~host ~port ~connector
          ~body_json:(Yojson.Safe.to_string json))
      ()
  in
  let handle_connector_unbind () =
    let host = server_peer_host in
    let port = state.port in
    handle_connector_form ~action:"unbind"
      ~stem:"{\n  \"name\": \"discord\",\n  \"channel_id\": \"\"\n}\n"
      ~post:(fun ~connector ~json ->
        Masc_tui_http.post_connector_unbind ~host ~port ~connector
          ~body_json:(Yojson.Safe.to_string json))
      ()
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
            add_event state "error"
              "no $EDITOR set; export EDITOR to reject here"
        | Some _ -> (
            let stem = "{\n  \"reason\": \"\"\n}\n" in
            match
              Masc_tui_editor.roundtrip ~restore:restore_terminal
                ~reenter:reenter_terminal stem
            with
            | None -> add_event state "system" "reject cancelled"
            | Some body -> (
                match Yojson.Safe.from_string body with
                | exception Yojson.Json_error e ->
                    add_event state "error" ("reject: body is not JSON: " ^ e)
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
                      add_event state "system" "reject cancelled (empty reason)"
                    else
                      start_verification_verdict state
                        ~mailbox:async_messages ~task_id
                        ~verdict:(`Reject reason))))
  in
  let handle_runtime_config_edit () =
    match state.runtime_config_view with
    | None -> add_event state "error" "config not loaded yet; r to reload"
    | Some (_, lines) -> (
      match Masc_tui_editor.editor_command () with
      | None ->
        add_event state "error"
          "no $EDITOR set; export EDITOR to edit runtime.toml here"
      | Some _ -> (
        let stem = String.concat "\n" lines in
        match
          Masc_tui_editor.roundtrip ~restore:restore_terminal
            ~reenter:reenter_terminal stem
        with
        | None -> add_event state "system" "runtime.toml unchanged"
        | Some edited -> (
          let host = server_peer_host in
          let port = state.port in
          match
            Masc_tui_http.post_runtime_config_preview ~host ~port
              ~source_text:edited
          with
          | Error detail -> add_event state "error" ("preview failed: " ^ detail)
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
              add_event state "error"
                ("preview rejected the edit: "
                 ^ Terminal_text.single_line
                     (Yojson.Safe.to_string preview))
            | Some true | None -> (
              match
                Masc_tui_http.post_runtime_config_raw ~host ~port
                  ~source_text:edited
              with
              | Ok _ ->
                add_event state "system" "runtime.toml saved";
                launch_runtime_config_load state ~mailbox:async_messages
              | Error detail -> add_event state "error" ("save failed: " ^ detail))))))
  in
  (* A prompt is edited the way runtime.toml is: $EDITOR over the text a turn
     actually gets, and the server persists what comes back. The effective
     text is the stem rather than the file's, because an overridden prompt is
     what the keeper reads and editing the file underneath it would change
     nothing the operator can see. *)
  let selected_prompt () =
    match state.prompts_snapshot with
    | None -> None
    | Some snapshot ->
        List.nth_opt snapshot.Tui_decode.ps_rows state.prompts_cursor
  in
  let handle_prompt_edit () =
    match selected_prompt () with
    | None -> add_event state "error" "prompts not loaded yet; r to reload"
    | Some row -> (
      match Masc_tui_editor.editor_command () with
      | None ->
        add_event state "error"
          "no $EDITOR set; export EDITOR to edit prompts here"
      | Some _ -> (
        match
          Masc_tui_editor.roundtrip ~restore:restore_terminal
            ~reenter:reenter_terminal row.Tui_decode.pr_effective
        with
        | None ->
          add_event state "system"
            (row.Tui_decode.pr_key ^ ": prompt unchanged")
        | Some edited ->
          (match
             Masc_tui_http.post_prompt_override ~host:server_peer_host
               ~port:state.port ~key:row.Tui_decode.pr_key ~value:edited
           with
           | Ok _ ->
             add_event state "system" (row.Tui_decode.pr_key ^ ": prompt saved");
             launch_prompts_load state ~mailbox:async_messages
           | Error detail ->
             add_event state "error"
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
    | None -> ()
    | Some keeper -> (
      match Masc_tui_editor.editor_command () with
      | None ->
        add_event state "error"
          "no $EDITOR set; export EDITOR to edit keeper settings here"
      | Some _ -> (
        match
          Masc_tui_editor.roundtrip ~restore:restore_terminal
            ~reenter:reenter_terminal "{\n}\n"
        with
        | None -> add_event state "system" (keeper.k_name ^ ": settings unchanged")
        | Some patch -> (
          match
            Masc_tui_http.post_keeper_config ~host ~port
              ~keeper_name:keeper.k_name ~patch_json:patch
          with
          | Ok _ -> add_event state "system" (keeper.k_name ^ ": settings applied")
          | Error detail -> add_event state "error" detail)))
  in
  let handle_keeper_create () =
    match Masc_tui_editor.editor_command () with
    | None ->
      add_event state "error" "no $EDITOR set; export EDITOR to create a keeper here"
    | Some _ -> (
      (* The stem names the only two fields a keeper cannot come up without;
         the name is edited in place and the route name comes from it. *)
      let stem =
        "{\n  \"name\": \"new-keeper\",\n  \"instructions\": \"\"\n}\n"
      in
      match
        Masc_tui_editor.roundtrip ~restore:restore_terminal
          ~reenter:reenter_terminal stem
      with
      | None -> add_event state "system" "create cancelled"
      | Some declaration -> (
        let declared_name =
          match Yojson.Safe.from_string declaration with
          | `Assoc fields -> (
            match List.assoc_opt "name" fields with
            | Some (`String value) -> String.trim value
            | _ -> "")
          | _ -> ""
        in
        if String.length declared_name = 0 then
          add_event state "error"
            "declaration needs a non-empty \"name\" string; nothing was created"
        else
          match
            Masc_tui_http.post_keeper_up ~host ~port ~keeper_name:declared_name
              ~declaration_json:declaration
          with
          | Ok _ -> add_event state "system" (declared_name ^ ": keeper created")
          | Error detail -> add_event state "error" detail))
  in
  let run_loop () =
    while true do
      request_console_write_repair render_schedule;
      if Atomic.exchange resize_requested false then begin
        invalidate_frame_for_resize frame_presenter render_schedule
      end;
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
          async_messages
      then Render_schedule.request render_schedule Render_schedule.Background;
      (* Check for input *)
      let input_timeout =
        Render_schedule.input_timeout_seconds render_schedule
          ~now_ns:(Mtime_clock.elapsed_ns ())
          ~maximum:maximum_input_wait_seconds
      in
      let input = read_input ~timeout:input_timeout input_reader () in
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
        Option.is_some state.image_open && Option.is_some input
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
          | Some (Pasted _) | Some (Graphics_reply _) | None -> None
      in
      (match input with
       (* Both sides of this arm are wanted: the guard decides whether a paste
          is handled at all, and the rewrite decides what text it carries. *)
       | Some (Pasted paste) when not dismissed_image ->
           (* A dropped or Finder-copied file arrives shell-escaped. The
              filesystem is the check that keeps this from touching text that
              merely looks like a path: an existing file is what the operator
              dropped, and anything else is left byte-for-byte as pasted. *)
           let paste =
             match Masc_tui_paste.unescaped_path paste.Masc_tui_paste.text with
             | Some path when Sys.file_exists path ->
                 { paste with Masc_tui_paste.text = path }
             | Some _ | None -> paste
           in
           handle_paste state ~base_path ~mailbox:async_messages ~paste
       (* A graphics reply is read and dropped. Nothing asks for one outside
          the capability probe, which does its own reading before the loop
          starts; what matters here is that it does not become keys. *)
       | Some (Pasted _) | Some (Graphics_reply _) | Some (Key _) | None -> ());
      if Option.is_some input then
        Render_schedule.request render_schedule Render_schedule.Input;
      let terminal_rows, terminal_columns = get_terminal_size () in
      let compact_viewport =
        Render_schedule.Viewport.requires_compact_frame ~rows:terminal_rows
      in
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
      (match state.view, key with
       | _ when compact_viewport -> ()
       | Approvals, Some ("y" | "Y" | "n" | "N") -> ()
       | Approvals, Some _ -> state.pending_approval_action <- None
       (* An armed shutdown expires on the next unrelated key. Otherwise it
          waits indefinitely and a later press of the same key -- after the
          cursor has moved, after a refresh -- submits work the operator armed
          minutes ago for something else. Same rule for an armed goal action. *)
       | Keepers _, Some ("s" | "S") -> ()
       | Keepers _, Some _ -> state.keeper_action_pending <- None
       | Board, Some ("v" | "V") -> ()
       | Board, Some _ -> state.board_vote_armed <- None
       | Planning, Some ("c" | "C" | "x" | "X" | "o" | "O") -> ()
       | Planning, Some _ -> state.goal_action_armed <- None
       | Schedules, Some ("x" | "X") -> ()
       | Schedules, Some _ -> state.schedule_cancel_armed <- None
       | Verification, Some ("a" | "A") -> ()
       | Verification, Some _ -> state.verification_verdict_armed <- None
       | _ -> ());
      (* The composer sees the key first, and takes it only when it has one to
         take: unfocused it claims a single key, and only with somewhere to
         send. Everything it does not claim reaches the surface with its
         meaning unchanged, so no existing binding moved when the row
         appeared. The chat surface is excluded — it draws its own composer. *)
      let composer_claimed =
        (not compact_viewport)
        && (not state.help_open)
        && (not state.palette_open)
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
       | Some _
         when quit_key
              && Option.is_none state.search
              && not
                   (state.view = Board
                   && state.board_mode = Board_compose) ->
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
           state.roster_pane_hidden <- not state.roster_pane_hidden;
           Render_schedule.request render_schedule Render_schedule.Force
       (* The help overlay is modal: it answers scrolling and closing, and
          swallows everything else so a surface binding cannot fire under a
          screen that is describing it. Quit stays global above. *)
       | Some k when state.help_open && not compact_viewport ->
           (match k with
            | "?" | "esc" ->
                state.help_open <- false;
                state.help_scroll <- 0
            | "j" | "down" | "k" | "up" ->
                (* Bounded against the sheet the frame draws, which folds to
                   two columns on a wide terminal and so holds half the rows
                   the lines were written as. *)
                let count, height = Masc_tui_render.help_viewport () in
                let move =
                  match k with
                  | "j" | "down" -> Masc_tui_scroll.down
                  | _ -> Masc_tui_scroll.up
                in
                state.help_scroll <- move ~count ~height state.help_scroll
            | _ -> ())
       (* The palette is the same kind of modal, but typed: printable keys
          build the query, arrows move the cursor, Enter runs the highlighted
          jump through the exact goto/chat paths the bound keys use. *)
       | Some k when state.palette_open && not compact_viewport ->
           let close () =
             state.palette_open <- false;
             state.palette_query <- "";
             state.palette_cursor <- 0
           in
           (match k with
            | "esc" -> close ()
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
                            ~focus:Board_detail_pane post
                      | None -> ())
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
         when Option.is_some state.search && not compact_viewport ->
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
       | Some "/"
         when Option.is_some (surface_row_texts state state.view)
              && not compact_viewport ->
           state.search <- Some ""
       | Some (("[" | "]") as bracket)
         when state.view = Keepers Keeper_detail && not compact_viewport ->
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
            | _, Detail_info | None, _ -> ())
       | Some (("[" | "]") as bracket)
         when state.view = Changes && not compact_viewport ->
           cycle_changes_keeper state ~mailbox:async_messages
             ~delta:(if bracket = "]" then 1 else -1)
       | Some "L"
         when state.view = Keepers Keeper_detail
              && state.detail_tab = Detail_github
              && not compact_viewport ->
           (match selected_keeper state with
            | Some keeper ->
                state.github_identity_view <-
                  Some (keeper.k_name, [ "# github login"; "(starting gh device flow\xe2\x80\xa6)" ]);
                launch_github_login state ~mailbox:async_messages keeper.k_name
            | None -> ())
       | Some "\r" when state.view = Resources && not compact_viewport ->
           (match
              Option.bind state.resources_list (fun rows ->
                  List.nth_opt rows state.resources_cursor)
            with
            | Some (uri, _) ->
                state.resource_focus <- true;
                launch_resource_read state ~mailbox:async_messages ~uri
            | None -> ())
       | Some "J" when state.view = Resources && not compact_viewport ->
           state.resource_scroll <- state.resource_scroll + 1
       | Some "K" when state.view = Resources && not compact_viewport ->
           state.resource_scroll <- max 0 (state.resource_scroll - 1)
       | Some (("n" | "N") as direction)
         when state.search_last <> ""
              && Option.is_some (surface_row_texts state state.view) ->
           let after = Option.value (search_row_cursor state) ~default:0 in
           search_jump state ~query:state.search_last ~after
             ~backwards:(String.equal direction "N")
       | Some _ when compact_viewport -> ()
       | Some k when message_mode ->
           let reasoning_key =
             String.length k = 1 && Char.code k.[0] = 18
           in
           let tool_view_key =
             String.length k = 1 && Char.code k.[0] = 4
           in
           let switch_key = String.length k = 1 && Char.code k.[0] = 7 in
           if
             keeper_message_input_supported state
             || String.equal k "esc"
             || reasoning_key
             || tool_view_key
             || switch_key
           then
             if switch_key then
               switch_to_next_keeper_message state ~mailbox:async_messages
             else
               let _handled =
                 handle_message_key state
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
                   k
               in
               ()
       | Some k
         when (not message_mode)
              && state.view = Board
              && state.board_mode = Board_compose ->
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
       | Some "?" when not compact_viewport ->
           state.help_open <- true;
           state.help_scroll <- 0
       | Some ":" when not compact_viewport ->
           state.palette_open <- true;
           state.palette_query <- "";
           state.palette_cursor <- 0
       | Some "\023"
         when state.view = Board
              && terminal_columns >= keeper_split_threshold_cols ->
           (match state.board_mode with
            | Board_read _ ->
                state.board_focus <-
                  (match state.board_focus with
                   | Board_posts_pane -> Board_detail_pane
                   | Board_detail_pane -> Board_posts_pane)
            | Board_list | Board_compose -> ())
       | Some "\023" when state.view = Resources ->
           state.resource_focus <- not state.resource_focus
       | Some "h" when state.view = Code && state.code_focus_file
                       && not state.code_history_open ->
           (* One cell per press: precise, and holding the key repeats it.
              The lowercase only -- H is the history toggle below. *)
           state.code_file_hscroll <- max 0 (state.code_file_hscroll - 1)
       | Some "H" when state.view = Code && state.code_focus_file ->
           (* History over the open file. The capital only: h stays free for
              the horizontal scroll the file pane is due. Same key closes it;
              a listing already fetched for this path is shown as it stands. *)
           (match state.code_file with
            | None -> ()
            | Some (path, _) ->
                if state.code_history_open then
                  state.code_history_open <- false
                else begin
                  state.code_history_open <- true;
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
       | Some ("h" | "H")
         when state.view = Board
              && terminal_columns >= keeper_split_threshold_cols ->
           (match state.board_mode with
            | Board_read _ -> state.board_focus <- Board_posts_pane
            | Board_list | Board_compose -> ())
       | Some ("l" | "L")
         when state.view = Board
              && terminal_columns >= keeper_split_threshold_cols ->
           (match state.board_mode with
            | Board_read _ -> state.board_focus <- Board_detail_pane
            | Board_list | Board_compose -> ())
       | Some k when Render_schedule.Input_shortcut.opens_keepers ~message_mode k ->
           state.view <- Keepers Keeper_list
       | Some "y" | Some "Y" ->
           (match state.view with
            | Approvals ->
                (match List.nth_opt (approval_items state) state.approval_cursor with
                 | Some (Operator_row a) ->
                     handle_approval_decision state a Confirm
                       ~mailbox:async_messages
                 | Some (Keeper_tool_row held) ->
                     (* One press, matching the chat pane's [y]: the wait runs
                        out on a short clock, so the two-press arming the
                        operator actions use would spend it. *)
                     launch_surface_tool_approval state
                       ~mailbox:async_messages
                       ~keeper_name:held.kta_keeper
                       ~tool_call_id:held.kta_tool_call_id ~allow:true
                 | None -> ())
            | _ -> ())
       | Some "n" | Some "N" ->
           (match state.view with
            | Approvals ->
                (match List.nth_opt (approval_items state) state.approval_cursor with
                 | Some (Operator_row a) ->
                     handle_approval_decision state a Deny
                       ~mailbox:async_messages
                 | Some (Keeper_tool_row held) ->
                     launch_surface_tool_approval state
                       ~mailbox:async_messages
                       ~keeper_name:held.kta_keeper
                       ~tool_call_id:held.kta_tool_call_id ~allow:false
                 | None -> ())
            | _ -> ())
       | Some ("pageup" | "pagedown") ->
           let page = surface_page_rows () in
           let direction = if key = Some "pagedown" then 1 else -1 in
           (match state.view with
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
                      | Board_posts_pane ->
                          move_board_posts_pane state ~mailbox:async_messages
                            ~delta:(direction * page)
                      | Board_detail_pane ->
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
            | Overview | Acting | Keepers _ | Lanes | Approvals | Planning
            | Verification | Harness | Repositories | Changes | Connectors
            | Runtime | Config | Tools | Resources | System_logs -> ())
       | Some "r" | Some "R" ->
           state.pending_approval_action <- None;
           load_from_masc_dir state base_path;
           let host = server_peer_host in
           let port = state.port in
           start_http_refresh state ~host ~port
             ~refresh_inflight:http_refresh_inflight
             ~mailbox:async_messages;
           (* Also reload logs / Board detail if viewing them. *)
           (match state.view with
            | Code -> launch_code_entries_load state ~mailbox:async_messages
            | Keepers Keeper_logs ->
                load_selected_keeper_logs state base_path 200
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
            | Keepers Keeper_message ->
                (match state.msg_target_keeper_name with
                 | Some keeper_name ->
                     launch_keeper_history_load state ~mailbox:async_messages
                       ~keeper_name
                 | None -> ())
            | Verification ->
                launch_verification_load state ~mailbox:async_messages
            | Lanes -> launch_lanes_load state ~mailbox:async_messages
            | Harness -> launch_harness_load state ~mailbox:async_messages
            | Fusion ->
                launch_fusion_runs_load state ~mailbox:async_messages;
                (match state.fusion_mode with
                 | Fusion_list -> ()
                 | Fusion_detail run_id ->
                     launch_fusion_detail_load state ~mailbox:async_messages
                       ~run_id)
            | Repositories ->
                launch_repositories_load state ~mailbox:async_messages
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
            | Overview | Acting | Keepers Keeper_list | Keepers Keeper_detail
            | Approvals | Planning | System_logs -> ());
           add_event state "system" "Manual refresh"
       | Some "\t" | Some "shift-tab" ->
           cycle_surface state ~mailbox:async_messages
             ~backwards:(key = Some "shift-tab")
       | Some "esc" ->
           (* Esc goes back *)
           (match state.view with
            | Code ->
                if state.code_history_open then
                  state.code_history_open <- false
                else if state.code_focus_file then state.code_focus_file <- false
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
            | Keepers Keeper_detail ->
                state.view <- Keepers Keeper_list;
                state.detail_scroll <- 0
            | Keepers Keeper_runtime_pick ->
                state.runtime_pick_keeper <- None;
                state.runtime_pick_cursor <- 0;
                state.view <- Keepers Keeper_list
            | Keepers Keeper_logs ->
                state.view <- Keepers Keeper_detail;
                state.log_scroll <- 0;
                state.detail_scroll <- 0
            | Keepers Keeper_calls ->
                state.view <- Keepers Keeper_detail;
                state.keeper_calls_scroll <- 0;
                state.detail_scroll <- 0
            | Keepers Keeper_message ->
                (* While a turn is streaming, Esc interrupts it instead of
                   leaving: leaving is one keypress away again once it settles,
                   and a turn an operator wants stopped is the more urgent of
                   the two. Asking twice does not stack -- the second press is
                   ignored while the first is unanswered. *)
                (match state.msg_live with
                 | Some live
                   when state.msg_target_keeper_name
                        = Some (Keeper_chat_transcript.keeper_name live)
                        && Keeper_chat_transcript.interrupt live
                           = Keeper_chat_transcript.Not_requested ->
                     (match
                        inflight_by_request_id state
                          (Keeper_chat_transcript.request_id live)
                      with
                      | Some request ->
                          launch_keeper_interrupt state
                            ~mailbox:async_messages request
                      | None -> leave_keeper_message state)
                 | Some _ ->
                     (* An interrupt is already outstanding for this turn. *)
                     ()
                 | None -> leave_keeper_message state)
            | Board ->
                (match state.board_mode with
                 | Board_read _ ->
                     leave_board_detail state
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
                (* Back out one level: an open task detail closes to the panel,
                   a focused task panel hands j/k back to the event log. *)
                if Option.is_some state.task_detail_id then begin
                  state.task_detail_id <- None;
                  state.task_detail_scroll <- 0
                end
                else state.task_focus <- false
            | Schedules ->
                state.schedule_detail_id <- None;
                state.schedule_scroll <- 0
            | Resources -> state.resource_focus <- false
            | Acting | Keepers Keeper_list | Lanes -> ()
            | Approvals ->
                (* Esc leaves the ask and returns to the list with the cursor
                   where it was, the way the Changes diff does. *)
                state.approval_detail_open <- false;
                state.approval_detail_scroll <- 0
            | Changes ->
                (* Esc closes the open diff and leaves the list where it was,
                   so the row an operator was reading is still under the
                   cursor when they come back. *)
                state.changes_diff_row <- None;
                state.changes_diff_scroll <- 0;
                state.changes_tree_diff <- None;
                state.changes_tree_diff_error <- None;
                state.changes_tree_diff_path <- None
            | Verification | Harness | Repositories | Connectors | Runtime
            | Config | Tools
            | System_logs -> ())
       | Some "left" ->
           (* Left is the non-destructive structural back key. Unlike Esc it
              never interrupts a live chat turn; it only closes a detail the
              matching Right key can open. *)
           (match state.view with
            | Code ->
                if state.code_history_open then
                  state.code_history_open <- false
                else if state.code_focus_file then state.code_focus_file <- false
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
                else state.task_focus <- false
            | Schedules ->
                state.schedule_detail_id <- None;
                state.schedule_scroll <- 0
            | Resources -> state.resource_focus <- false
            | Changes ->
                state.changes_diff_row <- None;
                state.changes_diff_scroll <- 0;
                state.changes_tree_diff <- None;
                state.changes_tree_diff_error <- None;
                state.changes_tree_diff_path <- None
            | Keepers Keeper_runtime_pick | Keepers Keeper_message
            | Keepers Keeper_list | Acting | Lanes | Approvals | Verification
            | Harness | Repositories | Connectors | Runtime | Config | Tools
            | System_logs -> ())
       | Some "j" | Some "down" | Some "wheel-down" ->
           (match state.view with
            | Code ->
                if state.code_focus_file then (
                  if state.code_history_open then (
                    match state.code_history with
                    | Some (_, rows) ->
                        state.code_history_scroll <-
                          min
                            (max 0 (List.length rows - 1))
                            (state.code_history_scroll + 1)
                    | None -> ())
                  else
                    match state.code_file with
                    | Some (_, rows) ->
                        state.code_file_scroll <-
                          min
                            (max 0 (List.length rows - 1))
                            (state.code_file_scroll + 1)
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
                   | Some k -> load_live_context state base_path k
                   | None -> ())
                end
            | Keepers Keeper_detail ->
                state.detail_scroll <- state.detail_scroll + 1
            | Keepers Keeper_logs ->
                state.log_scroll <-
                  Metrics_tail.scroll_down
                    ~entry_count:(List.length state.log_entries)
                    ~content_height:(keeper_log_content_height state)
                    state.log_scroll
            | Keepers Keeper_calls ->
                state.keeper_calls_scroll <- state.keeper_calls_scroll + 1
            | Config when state.config_prompts ->
                let count =
                  match state.prompts_snapshot with
                  | Some snapshot -> List.length snapshot.Tui_decode.ps_rows
                  | None -> 0
                in
                if state.prompts_cursor < count - 1 then
                  state.prompts_cursor <- state.prompts_cursor + 1
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
                      | Board_posts_pane ->
                          move_board_posts_pane state ~mailbox:async_messages
                            ~delta:1
                      | Board_detail_pane ->
                          state.board_scroll <- state.board_scroll + 1)
                 | Board_compose -> ())
            | Planning ->
                (match state.planning_mode with
                 | Planning_list ->
                     let goals =
                       match state.planning with
                       | None -> []
                       | Some p -> planning_visible_goals p.pl_goals
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
                else if state.task_focus then begin
                  if state.task_cursor < List.length state.tasks - 1 then
                    state.task_cursor <- state.task_cursor + 1
                end
                else begin
                  let _, _, row_budget =
                    overview_layout state ~terminal_rows
                  in
                  state.overview_event_scroll <-
                    Render_schedule.scroll_overview_events_older
                      ~event_count:(List.length state.events)
                      ~visible_rows:row_budget.attention_rows
                      state.overview_event_scroll
                end
            | Verification ->
                (let cursor, scroll =
                   move_row_cursor state ~delta:(1)
                     ~cursor:state.verification_cursor ~scroll:state.verification_scroll
                 in
                 state.verification_cursor <- cursor;
                 state.verification_scroll <- scroll)
            | Lanes ->
                (let cursor, scroll =
                   move_row_cursor state ~delta:(1)
                     ~cursor:state.lanes_cursor ~scroll:state.lanes_scroll
                 in
                 state.lanes_cursor <- cursor;
                 state.lanes_scroll <- scroll)
            | Harness -> (let cursor, scroll =
                   move_row_cursor state ~delta:(1)
                     ~cursor:state.harness_cursor ~scroll:state.harness_scroll
                 in
                 state.harness_cursor <- cursor;
                 state.harness_scroll <- scroll)
            | Repositories ->
                (let cursor, scroll =
                   move_row_cursor state ~delta:(1)
                     ~cursor:state.repositories_cursor ~scroll:state.repositories_scroll
                 in
                 state.repositories_cursor <- cursor;
                 state.repositories_scroll <- scroll)
            | Changes -> (
                (* An open diff owns the scroll keys: the list is behind it and
                   moving both would put the cursor somewhere the operator
                   cannot see. *)
                match state.changes_diff_row with
                | Some _ ->
                    state.changes_diff_scroll <- state.changes_diff_scroll + 1
                | None ->
                    state.changes_scroll <-
                      move_surface_scroll state ~rows:(surface_rows ()) ~delta:1
                        ~current:state.changes_scroll)
            | Connectors ->
                (let cursor, scroll =
                   move_row_cursor state ~delta:(1)
                     ~cursor:state.connectors_cursor ~scroll:state.connectors_scroll
                 in
                 state.connectors_cursor <- cursor;
                 state.connectors_scroll <- scroll)
            | Runtime ->
                (let cursor, scroll =
                   move_row_cursor state ~delta:(1)
                     ~cursor:state.runtime_cursor ~scroll:state.runtime_surface_scroll
                 in
                 state.runtime_cursor <- cursor;
                 state.runtime_surface_scroll <- scroll)
            | Tools -> state.tools_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:(1)
                    ~current:state.tools_scroll
            | Config -> state.config_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:1
                    ~current:state.config_scroll
            | Resources ->
                if state.resource_focus then
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
            | System_logs -> (let cursor, scroll =
                   move_row_cursor state ~delta:(1)
                     ~cursor:state.system_logs_cursor ~scroll:state.system_logs_scroll
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
                if state.code_focus_file then (
                  if state.code_history_open then
                    state.code_history_scroll <-
                      max 0 (state.code_history_scroll - 1)
                  else
                    state.code_file_scroll <-
                      max 0 (state.code_file_scroll - 1))
                else
                  state.code_cursor <-
                    Masc_tui_scroll.cursor_up
                      ~count:(List.length state.code_entries)
                      state.code_cursor
            | Keepers Keeper_list ->
                if state.keeper_cursor > 0 then begin
                  state.keeper_cursor <- state.keeper_cursor - 1;
                  (match List.nth_opt state.keepers state.keeper_cursor with
                   | Some k -> load_live_context state base_path k
                   | None -> ())
                end
            | Keepers Keeper_detail ->
                if state.detail_scroll > 0 then
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
            | Config when state.config_prompts ->
                state.prompts_cursor <- max 0 (state.prompts_cursor - 1)
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
                      | Board_posts_pane ->
                          move_board_posts_pane state ~mailbox:async_messages
                            ~delta:(-1)
                      | Board_detail_pane ->
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
                else if state.task_focus then begin
                  if state.task_cursor > 0 then
                    state.task_cursor <- state.task_cursor - 1
                end
                else begin
                  let _, _, row_budget =
                    overview_layout state ~terminal_rows
                  in
                  state.overview_event_scroll <-
                    Render_schedule.scroll_overview_events_newer
                      ~event_count:(List.length state.events)
                      ~visible_rows:row_budget.attention_rows
                      state.overview_event_scroll
                end
            | Verification ->
                (let cursor, scroll =
                   move_row_cursor state ~delta:(-1)
                     ~cursor:state.verification_cursor ~scroll:state.verification_scroll
                 in
                 state.verification_cursor <- cursor;
                 state.verification_scroll <- scroll)
            | Lanes ->
                (let cursor, scroll =
                   move_row_cursor state ~delta:(-1)
                     ~cursor:state.lanes_cursor ~scroll:state.lanes_scroll
                 in
                 state.lanes_cursor <- cursor;
                 state.lanes_scroll <- scroll)
            | Harness ->
                (let cursor, scroll =
                   move_row_cursor state ~delta:(-1)
                     ~cursor:state.harness_cursor ~scroll:state.harness_scroll
                 in
                 state.harness_cursor <- cursor;
                 state.harness_scroll <- scroll)
            | Repositories ->
                (let cursor, scroll =
                   move_row_cursor state ~delta:(-1)
                     ~cursor:state.repositories_cursor ~scroll:state.repositories_scroll
                 in
                 state.repositories_cursor <- cursor;
                 state.repositories_scroll <- scroll)
            | Changes -> (
                match state.changes_diff_row with
                | Some _ ->
                    state.changes_diff_scroll <-
                      max 0 (state.changes_diff_scroll - 1)
                | None ->
                    if state.changes_scroll > 0 then
                      state.changes_scroll <-
                        move_surface_scroll state ~rows:(surface_rows ())
                          ~delta:(-1) ~current:state.changes_scroll)
            | Connectors ->
                (let cursor, scroll =
                   move_row_cursor state ~delta:(-1)
                     ~cursor:state.connectors_cursor ~scroll:state.connectors_scroll
                 in
                 state.connectors_cursor <- cursor;
                 state.connectors_scroll <- scroll)
            | Runtime ->
                (let cursor, scroll =
                   move_row_cursor state ~delta:(-1)
                     ~cursor:state.runtime_cursor ~scroll:state.runtime_surface_scroll
                 in
                 state.runtime_cursor <- cursor;
                 state.runtime_surface_scroll <- scroll)
            | Tools ->
                if state.tools_scroll > 0 then
                  state.tools_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:(-1)
                    ~current:state.tools_scroll
            | Config ->
                if state.config_scroll > 0 then
                  state.config_scroll <-
                  move_surface_scroll state ~rows:(surface_rows ()) ~delta:(-1)
                    ~current:state.config_scroll
            | Resources ->
                if state.resource_focus then
                  state.resource_scroll <- max 0 (state.resource_scroll - 1)
                else if state.resources_cursor > 0 then
                  state.resources_cursor <- state.resources_cursor - 1
            | Acting ->
                if state.acting_scroll > 0 then begin
                  state.acting_scroll <- state.acting_scroll - 1;
                  if state.acting_scroll = 0 then state.acting_unseen <- 0
                end
            | System_logs ->
                (let cursor, scroll =
                   move_row_cursor state ~delta:(-1)
                     ~cursor:state.system_logs_cursor ~scroll:state.system_logs_scroll
                 in
                 state.system_logs_cursor <- cursor;
                 state.system_logs_scroll <- scroll)
            | Keepers Keeper_runtime_pick ->
                if state.runtime_pick_cursor > 0 then
                  state.runtime_pick_cursor <- state.runtime_pick_cursor - 1
            | Keepers Keeper_message -> ())
       | Some "\r" | Some "\n" | Some "right" ->
           (* Enter remains compatible; Right makes list -> detail and Left
              makes detail -> list consistent across the TUI. *)
           (match state.view with
            | Code -> (
                if state.code_focus_file then ()
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
                if state.task_focus then
                  (match List.nth_opt state.tasks state.task_cursor with
                   | Some task ->
                       state.task_detail_id <- Some task.id;
                       state.task_detail_scroll <- 0
                   | None -> ())
            | Keepers Keeper_list ->
                (match List.nth_opt state.keepers state.keeper_cursor with
                 | Some k ->
                     state.view <- Keepers Keeper_detail;
                     state.detail_scroll <- 0;
                     load_live_context state base_path k;
                     load_selected_keeper_logs state base_path 200 (Some k);
                     (* A sticky non-Info tab re-reads for the keeper the
                        cursor now names; without this the pane shows
                        "(loading)" forever after a cursor move, because the
                        stamped answer names the previous keeper. *)
                     (match state.detail_tab with
                      | Detail_info -> ()
                      | Detail_instructions ->
                          state.keeper_config_view <- None;
                          state.keeper_config_view_error <- None;
                          launch_keeper_config_view state
                            ~mailbox:async_messages k.k_name
                      | Detail_github ->
                          state.github_identity_view <- None;
                          state.github_identity_view_error <- None;
                          launch_github_identity_view state
                            ~mailbox:async_messages k.k_name)
                 | None -> ())
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
                            ~focus:Board_detail_pane p
                      | None -> ())
                 | Board_read _ | Board_compose -> ())
            | Schedules ->
                (match state.schedule_detail_id, state.schedules with
                 | None, Some snapshot ->
                     Option.iter
                       (fun row ->
                          state.schedule_detail_id <- Some row.sch_schedule_id;
                          state.schedule_scroll <- 0)
                       (List.nth_opt snapshot.scs_rows state.schedule_cursor)
                 | Some _, _ | None, None -> ())
            | Planning ->
                (match state.planning_mode with
                 | Planning_list ->
                     let goals =
                       match state.planning with
                       | None -> []
                       | Some p -> planning_visible_goals p.pl_goals
                     in
                     (match List.nth_opt goals state.planning_cursor with
                      | Some g ->
                          state.planning_mode <- Planning_detail g.pg_id;
                          state.planning_scroll <- 0
                      | None -> ())
                 | Planning_detail _ -> ())
            | Fusion ->
                (match state.fusion_mode with
                 | Fusion_list ->
                     let runs =
                       match state.fusion_runs with
                       | None -> []
                       | Some snapshot -> snapshot.fus_runs
                     in
                     (match List.nth_opt runs state.fusion_cursor with
                      | Some run ->
                          state.fusion_mode <- Fusion_detail run.fur_run_id;
                          state.fusion_scroll <- 0;
                          state.fusion_detail <- None;
                          state.fusion_detail_error <- None;
                          launch_fusion_detail_load state
                            ~mailbox:async_messages ~run_id:run.fur_run_id
                      | None -> ())
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
                        state.changes_scroll
                    with
                    | None ->
                        add_event state "error" "no change under the cursor"
                    | Some _ ->
                        state.changes_diff_row <- Some state.changes_scroll;
                        state.changes_diff_scroll <- 0;
                        state.changes_tree_diff <- None;
                        state.changes_tree_diff_error <- None;
                        state.changes_tree_diff_path <- None))
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
                        state.code_focus_file <- false;
                        state.view <- Code;
                        launch_code_entries_load state
                          ~mailbox:async_messages))
            | Keepers Keeper_detail | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message
            | Acting | Lanes | Verification | Harness
            | Connectors | Runtime | Config | Resources | Tools
            | System_logs -> ())
       | Some "f" | Some "F" when state.view = Acting ->
           state.acting_filter <- Masc_tui_acting.next_filter state.acting_filter
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
               | Keepers Keeper_list | Keepers Keeper_detail -> true
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
                state.task_focus <- not state.task_focus;
                if not state.task_focus then state.task_cursor <- 0
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
            | Verification | Harness | Fusion | Repositories | Changes | Connectors | Runtime | Config | Resources | Tools
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
                    state.changes_scroll
                with
                | None -> add_event state "error" "no change under the cursor"
                | Some change -> (
                    match change_bundle_relative_path change with
                    | None ->
                        add_event state "error"
                          "this write is outside the playground; the tree \
                           reading needs a path under it"
                    | Some path ->
                        state.changes_diff_row <- Some state.changes_scroll;
                        state.changes_diff_scroll <- 0;
                        state.changes_tree_diff <- None;
                        state.changes_tree_diff_error <- None;
                        state.changes_tree_diff_path <- Some path;
                        launch_git_diff_load state ~mailbox:async_messages
                          ~keeper:(Some change.Masc.Tui_decode.fc_keeper) ~path)))
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
                    state.changes_scroll
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
                        state.code_focus_file <- false;
                        (* The line is found in the local copy when one
                           exists (a Docker keeper's bundle is not on this
                           filesystem); a miss opens at the top, which is
                           visibly the top rather than a wrong answer. *)
                        state.code_target_line <-
                          (let local = change_absolute_path ~base_path change in
                           if Sys.file_exists local then
                             Some (change_line ~path:local change)
                           else None);
                        state.view <- Code;
                        launch_code_entries_load state
                          ~mailbox:async_messages;
                        launch_code_file_load state ~mailbox:async_messages
                          ~path)))
       | Some "o" when state.view = Changes ->
           (* Hand the selected change to the operator's editor. The row is
              the one the list marks, which is the top of the visible page. *)
           (match state.changes with
            | None -> add_event state "error" "no changes loaded yet"
            | Some snapshot -> (
                match
                  List.nth_opt snapshot.Masc.Tui_decode.fcs_changes
                    state.changes_scroll
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
                      let line = change_line ~path change in
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
       | Some "x" | Some "X" when state.view = Verification ->
           (* Reject wants a reason, and $EDITOR is the form we already
              have; the editor itself is the confirmation step. *)
           handle_verification_reject ()
       | Some "l" | Some "L" ->
           (* Logs, from the roster as well as from detail, for the same reason
              chat is reachable from both: the keeper an operator wants the
              logs of is the one under the cursor. *)
           (match state.view with
            | Code ->
                (* The lowercase scrolls the open file right, one cell per
                   press; the clamp is the widest row so the pane cannot
                   scroll into blank space. *)
                if
                  key = Some "l" && state.code_focus_file
                  && not state.code_history_open
                then
                  state.code_file_hscroll <-
                    min
                      (max 0 (state.code_file_max_width - 1))
                      (state.code_file_hscroll + 1)
            | Keepers Keeper_runtime_pick -> ()
            | Keepers (Keeper_list | Keeper_detail) ->
                let keeper = selected_keeper state in
                load_selected_keeper_logs state base_path 200 keeper;
                (match keeper with
                 | Some _ ->
                     state.log_scroll <-
                       Metrics_tail.maximum_scroll
                         ~entry_count:(List.length state.log_entries)
                         ~content_height:(keeper_log_content_height state);
                     state.view <- Keepers Keeper_logs
                 | None -> ())
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Lanes
            | Board | Approvals | Planning | Schedules | Verification | Harness
            | Fusion | Repositories | Changes | Connectors | Runtime | Config | Resources | Tools | System_logs -> ())
       | Some "m" | Some "M" | Some "c" | Some "C" ->
           (* Chat, from the roster as well as from detail, for the same reason
              logs are reachable from both: the keeper an operator wants to
              talk to is the one under the cursor. [c] is an alias for [m]
              because the footer names the action rather than the mnemonic. *)
           (match state.view with
            | Code -> ()
            | Keepers Keeper_runtime_pick -> ()
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
            | Keepers Keeper_message | Lanes
            | Board | Approvals | Planning | Schedules | Verification | Harness
            | Fusion | Repositories | Changes | Connectors | Runtime | Config | Resources | Tools | System_logs -> ())
       | Some "p" | Some "P" when state.view = Config && not compact_viewport ->
           (* One surface, two files the server reads: runtime.toml and the
              prompt registry. [p] moves between them and loads the list the
              first time it is asked for. *)
           state.config_prompts <- not state.config_prompts;
           state.prompts_cursor <- 0;
           if state.config_prompts && state.prompts_snapshot = None then
             launch_prompts_load state ~mailbox:async_messages
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
            | Fusion | Repositories | Changes | Connectors | Runtime | Config | Resources | Tools | System_logs -> ())
       | Some "s" | Some "S" ->
           (match state.view with
            | Code -> ()
            | Keepers Keeper_runtime_pick -> ()
            | Keepers (Keeper_list | Keeper_detail) ->
                handle_keeper_action state ~base_path ~mailbox:async_messages
                  Keeper_control.Shutdown
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Lanes
            | Board | Approvals | Planning | Schedules | Verification | Harness
            | Fusion | Repositories | Changes | Connectors | Runtime | Config | Resources | Tools | System_logs -> ())
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
            | Fusion | Repositories | Changes | Connectors | Runtime | Config | Resources | Tools | System_logs
            -> ())
       | Some "e" | Some "E" ->
           (* Settings edit hands the terminal to $EDITOR, so it cannot live
              inside the keeper-action pipeline: the loop is inside the
              editor, and the POST happens only after the editor returns. *)
           (match state.view with
            | Code -> ()
            | Keepers Keeper_runtime_pick -> ()
            | Keepers (Keeper_list | Keeper_detail) -> handle_keeper_settings_edit ()
            | Config ->
                if state.config_prompts then handle_prompt_edit ()
                else handle_runtime_config_edit ()
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Lanes
            | Board | Approvals | Planning | Schedules | Verification | Harness
            | Fusion | Repositories | Changes | Connectors | Runtime | Resources | Tools | System_logs -> ())
       | Some "x" | Some "X"
         when state.view = Config && state.config_prompts
              && not compact_viewport ->
           handle_prompt_clear ()
       | Some "b" when state.view = Connectors && not compact_viewport ->
           handle_connector_bind ()
       | Some "u" when state.view = Connectors && not compact_viewport ->
           handle_connector_unbind ()
       | Some "a" | Some "A" ->
           (match state.view with
            | Code -> ()
            | Keepers Keeper_runtime_pick -> ()
            | Keepers (Keeper_list | Keeper_detail) -> handle_keeper_create ()
            | Verification ->
                (* Two presses, like every irreversible action here: the
                   first names the task, the second sends the approval. *)
                handle_verification_approve_key state ~mailbox:async_messages
            | Overview | Acting | Keepers Keeper_logs | Keepers Keeper_calls
            | Keepers Keeper_message | Lanes
            | Board | Approvals | Planning | Schedules | Harness
            | Fusion | Repositories | Changes | Connectors | Runtime | Config | Resources | Tools | System_logs -> ())
      | _ -> ());

      (* A refresh already running was asked for what the surface open when it
         started needed, so it brings nothing for this one. The need is recorded
         as fetched only once a request has actually gone out; until then the
         next pass through the loop tries again. *)
      let needed = Masc_tui_types.surface_needs state.view in
      if needed <> !drawn_needs && not !http_refresh_inflight then begin
        drawn_needs := needed;
        start_http_refresh state ~host:(server_peer_host)
          ~port:state.port ~refresh_inflight:http_refresh_inflight
          ~mailbox:async_messages
      end;

      Eio.Fiber.yield ();
      if
        drain_async_messages state ~base_path ~http_refresh_inflight
          async_messages
      then Render_schedule.request render_schedule Render_schedule.Background;

      (* Periodic refresh *)
      let now_ns = Mtime_clock.elapsed_ns () in
      if
        Int64.compare (Int64.sub now_ns !last_check_ns) refresh_interval_ns >= 0
      then begin
        (* The armed approval survives the tick: the snapshot apply already
           disarms it when its token leaves the list, so clearing here only
           made the second press race a two-second clock. *)
        load_from_masc_dir state base_path;
        let host = server_peer_host in
        let port = state.port in
        (* The retry a closed feed waits for. *)
        open_observer_if_due state ~retry_closed:true ~host ~port
          ~mailbox:async_messages;
        start_http_refresh state ~host ~port
          ~refresh_inflight:http_refresh_inflight
          ~mailbox:async_messages;
        (* Also refresh logs / Board detail if viewing them. *)
        (match state.view with
         | Code -> ()
         | Keepers Keeper_runtime_pick -> ()
         | Keepers (Keeper_logs | Keeper_detail) ->
             load_selected_keeper_logs state base_path 200
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
                another arrives. Refreshed on the same tick as the surfaces
                above rather than only on a keypress. *)
             launch_verification_load state ~mailbox:async_messages
         | Lanes -> launch_lanes_load state ~mailbox:async_messages
         | Harness -> launch_harness_load state ~mailbox:async_messages
         | Fusion ->
             launch_fusion_runs_load state ~mailbox:async_messages;
             (match state.fusion_mode with
              | Fusion_list -> ()
              | Fusion_detail run_id ->
                  launch_fusion_detail_load state ~mailbox:async_messages
                    ~run_id)
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
         | Overview | Acting | Keepers Keeper_list | Keepers Keeper_message
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
       | Render_schedule.Render when Option.is_some state.image_open -> ()
       | Render_schedule.Render ->
           let frame, clamped = render state in
           (* The frame is what the operator will act on next, so the scroll it
              had to clamp is the scroll the next keypress moves from. Applied
              here rather than inside the drawing: a surface whose row count
              only exists once the frame is built cannot be bounded before it,
              but the drawing does not have to be the thing that stores it. *)
           Option.iter (apply_clamped_scroll state) clamped;
           Terminal_title.present terminal_title ~write:(output_string stdout)
             ~flush:(fun () -> flush stdout)
             (terminal_title_snapshot state);
           Frame_presenter.present frame_presenter
             ~invalidate_before:(Terminal_write_repair.consume_damage ())
             ~write:(output_string stdout)
             ~flush:(fun () -> flush stdout) frame
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
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            Eio_context.set_env env;
            Eio_context.set_switch sw;
            Eio_context.set_net (Eio.Stdenv.net env);
            Eio_context.set_clock (Eio.Stdenv.clock env);
            Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
            f ()))
  with Break -> ()

let () = run_with_eio_context main
