type reply =
  | Palette of Masc_tui_terminal_palette.slot * Masc_tui_terminal_palette.rgb option
  | Theme_mode of Masc_tui_terminal_palette.theme_mode
  | Cell_pixels of int * int
  | Graphics of string

type event =
  | Key of string
  | Paste of Masc_tui_paste.t
  | Mouse_wheel of Masc.Tui_decode.wheel_direction * int * int
  | Mouse_left_press of int * int
  | Mouse_left_release of int * int
  | Reply of reply

type pending =
  | Prefix
  | Sequence
  | Character
  | Pasting
  | Draining

(* A string-terminated body (OSC, APC). [overflowed] keeps reading to the
   terminator but drops the body: a reply longer than any we asked for is not
   ours, and handing half of it on would be a truncated answer. *)
type body = {
  bytes : Buffer.t;
  mutable after_escape : bool;
  mutable overflowed : bool;
}

type state =
  | Ground
  | Escape
  | Csi of Buffer.t
  | Ss3
  | X10_awaiting_button  (** [CSI M] read; the three report bytes follow. *)
  | X10_awaiting_column of char  (** The button byte. *)
  | X10_awaiting_row of char * char  (** The button and column bytes. *)
  | Osc of body
  | Apc_prefix
  | Apc of body
  | Utf8 of { head : string; expected_length : int }
  | In_paste of Masc_tui_paste.decoder
  | Draining_paste of Masc_tui_paste.decoder

(* An X10 press whose release has not come. X10 sends one release code for
   every button, so the release ends the press made last. *)
type held_button = Held_left | Held_other

type t = { mutable state : state; mutable x10_held : held_button list }

let create () = { state = Ground; x10_held = [] }

(* The same bound [read_input] used: CSI parameters for every key and reply we
   read fit well inside it. *)
let csi_parameters_max_bytes = 16

(* Every reply the protocol defines is short; the probe used this bound. *)
let body_max_bytes = 4096

(* Left, middle and right: a report cannot hold more presses open, so a list
   longer than this is one whose releases never arrived. *)
let x10_buttons = 3
let escape = '\x1b'
let bell = '\x07'
let string_terminator_final = '\\'
let paste_start_parameters = "200"
let theme_mode_final = 'n'
let cell_size_final = 't'
let cell_size_report_code = "6"
let x10_parameters = ""
let x10_final = 'M'

let is_csi_final byte = byte >= '\x40' && byte <= '\x7e'

let new_body () =
  { bytes = Buffer.create 64; after_escape = false; overflowed = false }

let key name = [ Key name ]

let parse_cell_size parameters =
  match String.split_on_char ';' parameters with
  | [ code; height; width ] when String.equal code cell_size_report_code -> (
      match int_of_string_opt width, int_of_string_opt height with
      | Some width, Some height when width > 0 && height > 0 ->
          Some (width, height)
      | _, _ -> None)
  | _ -> None

let csi_key parameters final =
  match Masc_tui_csi.name ~parameters ~final with
  | Some named -> key named
  | None -> key "unknown-esc"

(* A finished CSI. Replies are recognised by shape; anything that is not a
   reply is a key, named by the same table the reader always used. *)
let complete_csi t parameters final =
  t.state <- Ground;
  if String.equal parameters paste_start_parameters && final = '~' then begin
    t.state <- In_paste (Masc_tui_paste.create ());
    []
  end
  else if String.equal parameters x10_parameters && final = x10_final then begin
    t.state <- X10_awaiting_button;
    []
  end
  else if String.length parameters > 0 && parameters.[0] = '<' then
    match Masc.Tui_decode.sgr_wheel_report parameters final with
    | Some (direction, row, column) -> [ Mouse_wheel (direction, row, column) ]
    | None -> (
        match Masc.Tui_decode.sgr_left_press parameters final with
        | Some (row, column) -> [ Mouse_left_press (row, column) ]
        | None -> (
            match Masc.Tui_decode.sgr_left_release parameters final with
            | Some (row, column) -> [ Mouse_left_release (row, column) ]
            | None -> key "unknown-esc"))
  else if final = theme_mode_final then
    match Masc_tui_terminal_palette.parse_theme_mode_parameters parameters with
    | Some mode -> [ Reply (Theme_mode mode) ]
    | None -> csi_key parameters final
  else if final = cell_size_final then
    match parse_cell_size parameters with
    | Some (width, height) -> [ Reply (Cell_pixels (width, height)) ]
    | None -> csi_key parameters final
  else csi_key parameters final

let hold t button =
  t.x10_held <- List.filteri (fun index _ -> index < x10_buttons) (button :: t.x10_held)

(* A release is the left button's only when the press it ends is a left one:
   SGR says which button went up, and X10 leaves it to the order of presses. *)
let x10_event t ~button ~column ~row =
  match Masc.Tui_decode.x10_mouse_report ~button ~column ~row with
  | Some (Masc.Tui_decode.X10_wheel (direction, row, column)) ->
      [ Mouse_wheel (direction, row, column) ]
  | Some (Masc.Tui_decode.X10_left_press (row, column)) ->
      hold t Held_left;
      [ Mouse_left_press (row, column) ]
  | Some Masc.Tui_decode.X10_other_press ->
      hold t Held_other;
      key "unknown-esc"
  | Some (Masc.Tui_decode.X10_release (row, column)) -> (
      match t.x10_held with
      | Held_left :: rest ->
          t.x10_held <- rest;
          [ Mouse_left_release (row, column) ]
      | Held_other :: rest ->
          t.x10_held <- rest;
          key "unknown-esc"
      | [] -> key "unknown-esc")
  | None -> key "unknown-esc"

(* Feed one byte of a string-terminated body. [Some body] once [ESC \\] (or
   BEL, where [bell_terminates]) closes it. *)
let body_byte body ~bell_terminates byte =
  if body.after_escape then begin
    body.after_escape <- false;
    if byte = string_terminator_final then Some body
    else begin
      if not body.overflowed then begin
        Buffer.add_char body.bytes escape;
        Buffer.add_char body.bytes byte
      end;
      if byte = escape then body.after_escape <- true;
      None
    end
  end
  else if byte = escape then begin
    body.after_escape <- true;
    None
  end
  else if bell_terminates && byte = bell then Some body
  else begin
    if not body.overflowed then Buffer.add_char body.bytes byte;
    if Buffer.length body.bytes > body_max_bytes then begin
      body.overflowed <- true;
      Buffer.clear body.bytes
    end;
    None
  end

let osc_event body =
  if body.overflowed then []
  else
    match Masc_tui_terminal_palette.parse_response (Buffer.contents body.bytes) with
    | Masc_tui_terminal_palette.Palette_response { slot; color } ->
        [ Reply (Palette (slot, color)) ]
    | Masc_tui_terminal_palette.Not_palette_response -> []

let apc_event body =
  if body.overflowed then [] else [ Reply (Graphics (Buffer.contents body.bytes)) ]

let rec feed t byte =
  match t.state with
  | Ground -> ground t byte
  | Escape -> (
      t.state <- Ground;
      match byte with
      | '[' ->
          t.state <- Csi (Buffer.create 4);
          []
      | 'O' ->
          t.state <- Ss3;
          []
      | '_' ->
          t.state <- Apc_prefix;
          []
      | ']' ->
          t.state <- Osc (new_body ());
          []
      (* Alt+Backspace: ESC DEL, or ESC BS where Backspace sends BS. *)
      | '\x7f' | '\x08' -> key "alt-backspace"
      | _ -> key "esc")
  | Csi parameters ->
      if is_csi_final byte then complete_csi t (Buffer.contents parameters) byte
      else begin
        Buffer.add_char parameters byte;
        if Buffer.length parameters > csi_parameters_max_bytes then begin
          t.state <- Ground;
          key "esc"
        end
        else []
      end
  | Ss3 ->
      t.state <- Ground;
      csi_key "" byte
  | X10_awaiting_button ->
      t.state <- X10_awaiting_column byte;
      []
  | X10_awaiting_column button ->
      t.state <- X10_awaiting_row (button, byte);
      []
  | X10_awaiting_row (button, column) ->
      t.state <- Ground;
      x10_event t ~button ~column ~row:byte
  | Osc body -> (
      match body_byte body ~bell_terminates:true byte with
      | Some body ->
          t.state <- Ground;
          osc_event body
      | None -> [])
  | Apc_prefix ->
      t.state <- Ground;
      if byte = 'G' then begin
        t.state <- Apc (new_body ());
        []
      end
      else key "esc"
  | Apc body -> (
      match body_byte body ~bell_terminates:false byte with
      | Some body ->
          t.state <- Ground;
          apc_event body
      | None -> [])
  | Utf8 { head; expected_length } -> utf8 t ~head ~expected_length byte
  | In_paste decoder -> (
      match Masc_tui_paste.feed decoder byte with
      | Some paste ->
          t.state <- Ground;
          [ Paste paste ]
      | None -> [])
  | Draining_paste decoder -> (
      match Masc_tui_paste.feed decoder byte with
      | Some _ ->
          t.state <- Ground;
          []
      | None -> [])

and ground t byte =
  if byte = escape then begin
    t.state <- Escape;
    []
  end
  else
    match Masc_tui_message_layout.utf8_scalar_byte_length byte with
    | Some 1 -> key (String.make 1 byte)
    | Some expected_length ->
        t.state <- Utf8 { head = String.make 1 byte; expected_length };
        []
    | None -> key "invalid-utf8"

and utf8 t ~head ~expected_length byte =
  let offered = ref (Some byte) in
  let next_byte () =
    let next = !offered in
    offered := None;
    next
  in
  match
    Masc_tui_utf8_input.read_scalar ~prefix:head ~expected_length ~next_byte
  with
  | Masc_tui_utf8_input.Complete scalar ->
      t.state <- Ground;
      key scalar
  | Masc_tui_utf8_input.Incomplete head ->
      t.state <- Utf8 { head; expected_length };
      []
  | Masc_tui_utf8_input.Malformed { pushback } -> (
      t.state <- Ground;
      (* The rejected byte begins whatever comes next. *)
      match pushback with
      | Some byte -> Key "invalid-utf8" :: feed t byte
      | None -> key "invalid-utf8")

let idle t =
  match t.state with
  | Escape | Ss3 | Apc_prefix ->
      t.state <- Ground;
      key "esc"
  (* A report cut short has no position to act at. *)
  | X10_awaiting_button | X10_awaiting_column _ | X10_awaiting_row _ ->
      t.state <- Ground;
      key "unknown-esc"
  (* A terminal sends a reply in one burst. A body with a gap in it is not
     one we asked for, and holding it open would swallow the keys typed
     after Alt+] or Alt+_. *)
  | Osc body | Apc body ->
      t.state <- Ground;
      if Buffer.length body.bytes = 0 && not body.overflowed then key "esc"
      else []
  (* Still arriving: a CSI's final byte, a character's tail, a paste's tail.
     A quiet read is not the end of any of them. *)
  | Ground | Csi _ | Utf8 _ | In_paste _ | Draining_paste _ -> []

let pending t =
  match t.state with
  | Ground -> None
  | Escape | Ss3 | X10_awaiting_button | X10_awaiting_column _ | X10_awaiting_row _ | Osc _ | Apc_prefix | Apc _ -> Some Prefix
  | Csi _ -> Some Sequence
  | Utf8 _ -> Some Character
  | In_paste _ -> Some Pasting
  | Draining_paste _ -> Some Draining

let cancel_pending t =
  match t.state with
  | Escape | Csi _ | Ss3 | X10_awaiting_button | X10_awaiting_column _ | X10_awaiting_row _ | Osc _ | Apc_prefix | Apc _ -> t.state <- Ground
  | Ground | Utf8 _ | In_paste _ | Draining_paste _ -> ()

let recover_paste t =
  match t.state with
  | In_paste decoder ->
      t.state <- Draining_paste decoder;
      Some (Masc_tui_paste.snapshot_payload decoder)
  | Ground | Escape | Csi _ | Ss3 | X10_awaiting_button | X10_awaiting_column _ | X10_awaiting_row _ | Osc _ | Apc_prefix | Apc _ | Utf8 _
  | Draining_paste _ ->
      None

let abandon_draining t =
  match t.state with
  | Draining_paste _ -> t.state <- Ground
  | Ground | Escape | Csi _ | Ss3 | X10_awaiting_button | X10_awaiting_column _ | X10_awaiting_row _ | Osc _ | Apc_prefix | Apc _ | Utf8 _
  | In_paste _ ->
      ()
