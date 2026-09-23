(* The DOS spectator screen (#38424). The machine lives in the server; this
   screen draws the frame the server hands over, through the same
   [Masc_tui_machine_view] the MSX spectator draws with.

   It is a spectator and only that. DOS time moves by tool calls -- a Keeper's
   masc_dos_step, press, click or type -- and neither watching nor a key
   pressed here moves it: the poll is a read, and no key is sent to the
   machine. [esc] hands the terminal back; the size keys change only how big
   this terminal draws the frame; every other key repaints. *)

module View = Masc_tui_machine_view
module Terminal_text = Masc_tui_ansi.Terminal_text

(* What a spectator's key does. The size keys are the view's own; nothing
   here is a machine key. *)
type key_action = Close | Resize of float | Repaint

let key_action = function
  | "esc" -> Close
  | "+" | "=" -> Resize 1.0
  | "-" | "_" -> Resize (-1.0)
  (* A key name is open-ended text from the decoder, so the rest cannot be
     listed: every other key only repaints, and none is forwarded. *)
  | _unbound -> Repaint

(* The controller in words: who may move the machine now. *)
let controller_label = function
  | Some holder -> "controller: " ^ Terminal_text.single_line holder
  | None -> "controller: free"

(* An empty cache has two causes, as on the MSX screen: the server said no
   machine is loaded, or it could not be asked. The connection the refresh
   loop keeps is what separates them. *)
let title_of ~(connection : Masc_tui_types.connection_status)
    (frame : Masc_tui_types.dos_frame option) =
  match frame with
  | None -> (
    match connection with
    | Masc_tui_types.Connected | Masc_tui_types.Degraded ->
      " DOS \xe2\x80\x94 no machine loaded. A keeper loads one with masc_dos_load."
    | (Masc_tui_types.Disconnected | Masc_tui_types.Connecting
      | Masc_tui_types.Booting | Masc_tui_types.Reconnecting) as status ->
      Printf.sprintf
        " DOS \xe2\x80\x94 no frame: the server is %s, so nothing could be asked for."
        (Masc_tui_types.connection_status_label status))
  | Some f ->
    let program =
      Terminal_text.single_line_or ~default:"(no program)" f.dos_program
    in
    Printf.sprintf " DOS \xe2\x80\x94 %s   %s   step %d   (spectating the server)"
      program (controller_label f.dos_controller) f.dos_steps

let footer () =
  Printf.sprintf " Esc: back  +/-: %d%%  (spectator: keys never reach the machine)"
    (View.size_percent ())

let surface_of (frame : Masc_tui_types.dos_frame option) =
  Option.map
    (fun (f : Masc_tui_types.dos_frame) ->
      Masc_tui_interactive.Pixels { width = f.dos_width; height = f.dos_height; rgb = f.dos_rgb })
    frame

let render ~(write : string -> unit) ~(connection : Masc_tui_types.connection_status)
    ?notice (frame : Masc_tui_types.dos_frame option) =
  View.draw ~write ~title:(title_of ~connection frame) ?notice ~footer:(footer ())
    ~retain:(Option.is_some frame) (surface_of frame)

(* One key while the screen is open. Returns whether the screen is still
   open; a closed screen owes the surface underneath a repaint. *)
let consume ~(write : string -> unit) (state : Masc_tui_types.state) key =
  match key_action key with
  | Close ->
    View.release ~write;
    state.dos_open <- false;
    false
  | Resize step ->
    View.adjust_size step;
    render ~write ~connection:state.connection_status ?notice:state.dos_notice state.dos_frame;
    true
  | Repaint ->
    render ~write ~connection:state.connection_status ?notice:state.dos_notice state.dos_frame;
    true
