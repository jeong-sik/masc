type rgb =
  { red : int
  ; green : int
  ; blue : int
  }

let make_rgb ~red ~green ~blue =
  let component_in_range component = component >= 0 && component <= 255 in
  if
    not
      (component_in_range red
       && component_in_range green
       && component_in_range blue)
  then invalid_arg "Masc_tui_terminal_palette.make_rgb: component outside 0..255";
  { red; green; blue }
;;

let red color = color.red
let green color = color.green
let blue color = color.blue

type stdout_color_level =
  | True_color
  | Ansi256
  | Ansi16
  | Unknown

type projected_color =
  | Rgb of rgb
  | Indexed of int

let term_is_usable = function
  | Some term ->
    String.length term > 0
    && not (String.equal (String.lowercase_ascii term) "dumb")
  | None -> false
;;

let classify_stdout_color_level ~is_tty ~term ~colorterm ~terminfo_rgb
    ~terminfo_colors =
  let colorterm_is_truecolor =
    match colorterm with
    | Some value -> String.equal (String.lowercase_ascii value) "truecolor"
    | None -> false
  in
  let terminfo_is_truecolor =
    match terminfo_rgb, terminfo_colors with
    | Some true, Some colors -> colors >= 16_777_216
    | (Some false | None), _ | Some true, None -> false
  in
  if not is_tty || not (term_is_usable term) then Unknown
  else if colorterm_is_truecolor || terminfo_is_truecolor then True_color
  else
    match terminfo_colors with
    | Some colors when colors >= 256 -> Ansi256
    | Some colors when colors >= 16 -> Ansi16
    | Some _ | None -> Unknown
;;

external native_terminfo_capabilities_raw : string -> int * int
  = "masc_tui_terminal_palette_terminfo_capabilities"

let native_terminfo_capabilities term =
  let rgb, colors = native_terminfo_capabilities_raw term in
  let terminfo_rgb =
    match rgb with
    | 0 -> Some false
    | 1 -> Some true
    | _ -> None
  in
  let terminfo_colors = if colors >= 0 then Some colors else None in
  terminfo_rgb, terminfo_colors
;;

let detect_stdout_color_level () =
  let is_tty =
    try Unix.isatty Unix.stdout with
    | Unix.Unix_error _ -> false
  in
  let term = Sys.getenv_opt "TERM" in
  let terminfo_rgb, terminfo_colors =
    match is_tty, term with
    | true, Some term when term_is_usable (Some term) ->
      native_terminfo_capabilities term
    | true, (Some _ | None) | false, _ -> None, None
  in
  classify_stdout_color_level ~is_tty ~term
    ~colorterm:(Sys.getenv_opt "COLORTERM") ~terminfo_rgb ~terminfo_colors
;;

(* Stdlib Lazy is intentional: this process fact can be forced during module
   startup and from unit tests, where no Eio context exists. *)
let stdout_color_level_lazy = lazy (detect_stdout_color_level ())
let stdout_color_level () = Lazy.force stdout_color_level_lazy

let xterm_cube_level = function
  | 0 -> 0
  | 1 -> 95
  | 2 -> 135
  | 3 -> 175
  | 4 -> 215
  | 5 -> 255
  | _ -> invalid_arg "Masc_tui_terminal_palette.xterm_cube_level"
;;

let xterm_fixed_rgb index =
  if index >= 16 && index <= 231 then (
    let offset = index - 16 in
    make_rgb ~red:(xterm_cube_level (offset / 36))
      ~green:(xterm_cube_level (offset / 6 mod 6))
      ~blue:(xterm_cube_level (offset mod 6)))
  else if index >= 232 && index <= 255 then
    let component = 8 + (10 * (index - 232)) in
    make_rgb ~red:component ~green:component ~blue:component
  else invalid_arg "Masc_tui_terminal_palette.xterm_fixed_rgb"
;;

let squared_distance left right =
  let square value = value * value in
  square (left.red - right.red)
  + square (left.green - right.green)
  + square (left.blue - right.blue)
;;

let nearest_xterm_fixed_index target =
  let best_index = ref 16 in
  let best_distance = ref max_int in
  for index = 16 to 255 do
    let distance = squared_distance target (xterm_fixed_rgb index) in
    if distance < !best_distance then (
      best_index := index;
      best_distance := distance)
  done;
  !best_index
;;

let project_color_for_level ~level color =
  match level with
  | True_color -> Some (Rgb color)
  | Ansi256 -> Some (Indexed (nearest_xterm_fixed_index color))
  | Ansi16 | Unknown -> None
;;

let best_color color = project_color_for_level ~level:(stdout_color_level ()) color

let fold_projected_color ~rgb ~indexed = function
  | Rgb color -> rgb color
  | Indexed index -> indexed index
;;

module For_testing = struct
  type classifier_input =
    { is_tty : bool
    ; term : string option
    ; colorterm : string option
    ; terminfo_rgb : bool option
    ; terminfo_colors : int option
    }

  let classify input =
    classify_stdout_color_level ~is_tty:input.is_tty ~term:input.term
      ~colorterm:input.colorterm ~terminfo_rgb:input.terminfo_rgb
      ~terminfo_colors:input.terminfo_colors
  ;;

  let best_color_for_level = project_color_for_level
end

(* The sixteen slots an SGR colour code selects. A terminal answers for each
   one separately, and may answer for none of them. *)
let ansi_slot_count = 16

type t =
  { foreground : rgb
  ; background : rgb
  ; ansi : rgb option array (* [ansi_slot_count] entries *)
  }

let foreground palette = palette.foreground
let background palette = palette.background

let ansi palette index =
  if index < 0 || index >= ansi_slot_count then None else palette.ansi.(index)
;;

(* Whether the terminal calls its own page light or dark, asked and answered
   without any colour crossing the wire.

   OSC 10, 11 and 4 do not survive a multiplexer: tmux and screen can be
   attached to several terminals at once, so they have no one page to report.
   DECSET 996 and 2031 are a later answer to the same question that they do
   pass through, and that Ghostty, Kitty, VTE, Zellij and Contour answer too.
   It carries no colours, so it cannot replace the palette -- it says which
   way a colour has to move, which is the half that matters when nothing else
   is known. *)
type theme_mode =
  | Dark
  | Light

type slot =
  | Foreground
  | Background
  | Ansi of int

type response =
  | Not_palette_response
  | Palette_response of
      { slot : slot
      ; color : rgb option
      }

(* OSC 10 and 11 are the text and the page. OSC 4 asks what each of the
   sixteen palette entries actually is, which is the only way to know what an
   SGR colour code will draw on this terminal rather than on the one the
   colours were picked against.

   All eighteen go out together and the answers are read as they arrive.
   Nothing waits on the OSC 4 replies: a terminal that answers 10 and 11 but
   not 4 -- or a multiplexer that answers none -- leaves those slots unknown,
   which is a state the readers already have to handle. *)
let osc_query slot = Printf.sprintf "\x1b]%s;?\x1b\\" slot

(* DECSET 996 asks once; 2031 asks to be told again whenever the answer
   changes, which is how a terminal that follows the desktop's light and dark
   switch reports it mid-session. Both replies arrive in the same shape, so
   one parser reads them. *)
let theme_mode_query = "\x1b[?996n"
let theme_mode_subscribe = "\x1b[?2031h"
let theme_mode_unsubscribe = "\x1b[?2031l"

let query =
  String.concat ""
    (theme_mode_subscribe :: theme_mode_query :: osc_query "10"
     :: osc_query "11"
     :: List.init ansi_slot_count (fun index ->
            osc_query (Printf.sprintf "4;%d" index)))
;;

(* [CSI ? 997 ; 1 n] dark, [CSI ? 997 ; 2 n] light. The same reply answers the
   996 question and arrives unasked after 2031, so nothing here cares which
   prompted it. Any other parameter is a mode this does not know, and an
   unknown page is not a dark one. *)
let dark_mode_parameter = 1
let light_mode_parameter = 2

let parse_theme_mode_parameters body =
  match String.split_on_char ';' body with
  | [ "?997"; parameter ] | [ "997"; parameter ] -> (
    match int_of_string_opt parameter with
    | Some value when value = dark_mode_parameter -> Some Dark
    | Some value when value = light_mode_parameter -> Some Light
    | Some _ | None -> None)
  | _ -> None
;;

let hex_component text =
  let is_hex = function
    | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
    | _ -> false
  in
  if not (String.for_all is_hex text) then None
  else
    match String.length text with
    | 2 -> int_of_string_opt ("0x" ^ text)
    | 4 ->
      Option.map
        (fun component -> component / 257)
        (int_of_string_opt ("0x" ^ text))
    | _ -> None
;;

let rgb_of_payload payload =
  let components kind_length =
    String.sub payload kind_length (String.length payload - kind_length)
    |> String.split_on_char '/'
  in
  let color red_text green_text blue_text =
    Option.bind (hex_component red_text) (fun red ->
        Option.bind (hex_component green_text) (fun green ->
            Option.map
              (fun blue -> { red; green; blue })
              (hex_component blue_text)))
  in
  if String.starts_with ~prefix:"rgb:" payload then
    (match components 4 with
     | [ red; green; blue ] -> color red green blue
     | _ -> None)
  else if String.starts_with ~prefix:"rgba:" payload then
    (match components 5 with
     | [ red; green; blue; alpha ] when Option.is_some (hex_component alpha) ->
       color red green blue
     | _ -> None)
  else None
;;

let parse_response body =
  let parse slot prefix =
    let payload =
      String.sub body (String.length prefix)
        (String.length body - String.length prefix)
    in
    Palette_response { slot; color = rgb_of_payload payload }
  in
  if String.starts_with ~prefix:"10;" body then parse Foreground "10;"
  else if String.starts_with ~prefix:"11;" body then parse Background "11;"
  else if String.starts_with ~prefix:"4;" body then
    (* [4;<index>;<colour>]. The index is the terminal's own echo of what was
       asked, so an answer for a slot outside the sixteen is not an answer to
       any question this sent. *)
    match String.index_opt body ';' with
    | None -> Not_palette_response
    | Some first -> (
      let rest =
        String.sub body (first + 1) (String.length body - first - 1)
      in
      match String.index_opt rest ';' with
      | None -> Not_palette_response
      | Some second -> (
        let index_text = String.sub rest 0 second in
        match int_of_string_opt index_text with
        | Some index when index >= 0 && index < ansi_slot_count ->
          parse (Ansi index) (Printf.sprintf "4;%d;" index)
        | Some _ | None -> Not_palette_response))
  else Not_palette_response
;;

let of_responses ~foreground ~background ~ansi =
  match foreground, background with
  | Some foreground, Some background ->
    (* The sixteen are optional and the two are not: without a background
       there is nothing to measure a colour against, and every reader here
       measures against it. A short or long [ansi] is a caller that did not
       build one slot per code, so it is taken as none rather than silently
       shifting which colour each code means. *)
    let ansi =
      if Array.length ansi = ansi_slot_count then Array.copy ansi
      else Array.make ansi_slot_count None
    in
    Some { foreground; background; ansi }
  | Some _, None | None, Some _ | None, None -> None
;;

type snapshot =
  { palette : t option
  ; theme_mode : theme_mode option
  ; generation : int
  }

let process_palette =
  Atomic.make { palette = None; theme_mode = None; generation = 0 }
;;

let snapshot () = Atomic.get process_palette
let snapshot_palette snapshot = snapshot.palette
let snapshot_theme_mode snapshot = snapshot.theme_mode
let snapshot_generation snapshot = snapshot.generation
let current () = (snapshot ()).palette

(* One generation over both, because both decide what a colour comes out as
   and a reader caching by generation has to be woken by either. A theme
   switch arrives here through DECSET 2031 long after start-up and can arrive
   again, so this is not a set-once. *)
let rec update field =
  let previous = snapshot () in
  let next = { (field previous) with generation = previous.generation + 1 } in
  if not (Atomic.compare_and_set process_palette previous next) then
    update field
;;

let set_current palette = update (fun previous -> { previous with palette })

let set_theme_mode theme_mode =
  update (fun previous -> { previous with theme_mode })
;;
