let environment_variable = "MASC_TUI_NAV_TRACE"

(* A line is about 120 bytes, so the cap keeps the file under half a megabyte.
   Holding a key that does nothing writes one line per frame; the cap is what
   keeps an unattended TUI from filling a disk. *)
let default_max_lines = 4096

type input =
  | Key of string
  | Other_input
  | No_input

type phase =
  | Writing
  | Stopped

type live =
  { path : string
  ; max_lines : int
  ; clock : unit -> float
  ; mutable phase : phase
  ; mutable channel : out_channel option
  ; mutable lines : int
  ; mutable previous_surface : string option
  ; mutable pressed : string option
  }

type t =
  | Off
  | On of live

let announced = ref ""
let announce hints = announced := hints

let create ~path ~max_lines ~clock =
  On
    { path
    ; max_lines
    ; clock
    ; phase = Writing
    ; channel = None
    ; lines = 0
    ; previous_surface = None
    ; pressed = None
    }
;;

let from_environment ~clock =
  match Sys.getenv_opt environment_variable with
  | Some path when not (String.equal (String.trim path) "") ->
    create ~path ~max_lines:default_max_lines ~clock
  | Some _ | None -> Off
;;

let stop live =
  live.phase <- Stopped;
  Option.iter (fun channel -> try close_out channel with Sys_error _ -> ()) live.channel;
  live.channel <- None
;;

let channel_of live =
  match live.channel with
  | Some _ as opened -> opened
  | None ->
    let opened =
      try Some (open_out_gen [ Open_wronly; Open_creat; Open_append ] 0o600 live.path) with
      | Sys_error _ -> None
    in
    live.channel <- opened;
    opened
;;

let write_line live channel event =
  try
    output_string channel (Masc_tui_nav_trace.to_json_line ~at:(live.clock ()) event);
    output_char channel '\n';
    flush channel;
    true
  with
  | Sys_error _ -> false
;;

let append live event =
  match live.phase with
  | Stopped -> ()
  | Writing ->
    (match channel_of live with
     | None -> stop live
     | Some channel ->
       if live.lines >= live.max_lines
       then (
         ignore (write_line live channel (Masc_tui_nav_trace.Capped { limit = live.max_lines }));
         stop live)
       else if write_line live channel event
       then live.lines <- live.lines + 1
       else stop live)
;;

let note_input t input =
  match t with
  | Off -> ()
  | On live ->
    (match input with
     | Key name -> live.pressed <- Some name
     | Other_input -> live.pressed <- None
     | No_input -> ())
;;

let note_frame t ~surface ~result =
  match t with
  | Off -> ()
  | On live ->
    let hints = !announced in
    announced := "";
    let key = live.pressed in
    live.pressed <- None;
    let advertised =
      match key with
      | Some _ -> Masc_tui_footer.advertised_key_atoms hints
      | None -> []
    in
    let events =
      Masc_tui_nav_trace.observe
        ~previous_surface:live.previous_surface
        ~surface
        ~key
        ~result
        ~advertised
    in
    live.previous_surface <- Some surface;
    List.iter (append live) events
;;
