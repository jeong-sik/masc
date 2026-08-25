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

module For_testing = struct
  type classifier_input =
    { is_tty : bool
    ; term : string option
    ; colorterm : string option
    ; terminfo_rgb : bool option
    ; terminfo_colors : int option
    }

  let classify input =
    let colorterm_is_truecolor =
      match input.colorterm with
      | Some value ->
        String.equal (String.lowercase_ascii value) "truecolor"
      | None -> false
    in
    if not input.is_tty || not (term_is_usable input.term) then Unknown
    else if input.terminfo_rgb = Some true || colorterm_is_truecolor then
      True_color
    else
      match input.terminfo_colors with
      | Some colors when colors >= 256 -> Ansi256
      | Some colors when colors >= 16 -> Ansi16
      | Some _ | None -> Unknown
  ;;
end

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
  For_testing.classify
    { is_tty
    ; term
    ; colorterm = Sys.getenv_opt "COLORTERM"
    ; terminfo_rgb
    ; terminfo_colors
    }
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

let best_color_for_level ~level color =
  match level with
  | True_color -> Some (Rgb color)
  | Ansi256 -> Some (Indexed (nearest_xterm_fixed_index color))
  | Ansi16 | Unknown -> None
;;

let best_color color = best_color_for_level ~level:(stdout_color_level ()) color

type t =
  { foreground : rgb
  ; background : rgb
  }

let foreground palette = palette.foreground
let background palette = palette.background

type slot =
  | Foreground
  | Background

type response =
  | Not_palette_response
  | Palette_response of
      { slot : slot
      ; color : rgb option
      }

let query = "\x1b]10;?\x1b\\\x1b]11;?\x1b\\"

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
  else Not_palette_response
;;

let of_responses ~foreground ~background =
  match foreground, background with
  | Some foreground, Some background -> Some { foreground; background }
  | Some _, None | None, Some _ | None, None -> None
;;

let process_palette : t option Atomic.t = Atomic.make None
let current () = Atomic.get process_palette
let set_current palette = Atomic.set process_palette palette
