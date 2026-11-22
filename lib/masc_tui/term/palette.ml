type rgb = {
  red : int;
  green : int;
  blue : int;
}

let make_rgb ~red ~green ~blue =
  let in_range v = v >= 0 && v <= 255 in
  if not (in_range red && in_range green && in_range blue) then
    invalid_arg "Masc_tui_term.Palette.make_rgb: component outside 0..255";
  { red; green; blue }

let red c = c.red
let green c = c.green
let blue c = c.blue
let to_packed_rgb c = Color.make_rgb ~r:c.red ~g:c.green ~b:c.blue

let of_packed_rgb packed =
  { red = Color.red packed; green = Color.green packed; blue = Color.blue packed }

let equal_rgb a b =
  Int.equal a.red b.red && Int.equal a.green b.green && Int.equal a.blue b.blue

type stdout_color_level =
  | True_color
  | Ansi256
  | Ansi16
  | Unknown

type classifier_input = {
  is_tty : bool;
  term : string option;
  colorterm : string option;
  terminfo_rgb : bool option;
  terminfo_colors : int option;
}

let term_is_usable = function
  | Some term ->
      String.length term > 0
      && not (String.equal (String.lowercase_ascii term) "dumb")
  | None -> false

let classify_stdout_color_level
    { is_tty; term; colorterm; terminfo_rgb; terminfo_colors } =
  let colorterm_is_truecolor =
    match colorterm with
    | Some value ->
        let lc = String.lowercase_ascii value in
        String.equal lc "truecolor" || String.equal lc "24bit"
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

external native_terminfo_capabilities_raw : string -> int * int
  = "masc_tui_v2_palette_terminfo_capabilities"

let native_terminfo_capabilities term =
  let rgb, colors = native_terminfo_capabilities_raw term in
  let terminfo_rgb =
    match rgb with
    | 0 -> Some false
    | 1 -> Some true
    | _ -> None
  in
  let terminfo_colors = if colors >= 0 then Some colors else None in
  (terminfo_rgb, terminfo_colors)

let detect_stdout_color_level () =
  let is_tty =
    match Unix.isatty Unix.stdout with
    | v -> v
    | exception Unix.Unix_error _ -> false
  in
  let term = Sys.getenv_opt "TERM" in
  let terminfo_rgb, terminfo_colors =
    match is_tty, term with
    | true, Some t when term_is_usable (Some t) -> native_terminfo_capabilities t
    | true, (Some _ | None) | false, _ -> (None, None)
  in
  classify_stdout_color_level
    {
      is_tty;
      term;
      colorterm = Sys.getenv_opt "COLORTERM";
      terminfo_rgb;
      terminfo_colors;
    }

(* Stdlib.Lazy is intentional per ocaml-coding §5: read during process startup
   and in pure non-Eio tests where no Eio context exists. *)
let stdout_color_level_lazy = lazy (detect_stdout_color_level ())
let stdout_color_level () = Lazy.force stdout_color_level_lazy

let color_depth_of_level = function
  | True_color -> Color.Truecolor
  | Ansi256 -> Color.Ansi256
  | Ansi16 | Unknown -> Color.Ansi16

let ansi_slot_count = 16

type t = {
  foreground : rgb;
  background : rgb;
  ansi : rgb option array;
}

let foreground p = p.foreground
let background p = p.background

let ansi p index =
  if index < 0 || index >= ansi_slot_count then None else p.ansi.(index)

let equal a b =
  equal_rgb a.foreground b.foreground
  && equal_rgb a.background b.background
  && Array.length a.ansi = Array.length b.ansi
  &&
  let rec loop i =
    if i >= Array.length a.ansi then true
    else if Option.equal equal_rgb a.ansi.(i) b.ansi.(i) then loop (i + 1)
    else false
  in
  loop 0

type slot =
  | Foreground
  | Background
  | Ansi of int

type response =
  | Not_palette_response
  | Palette_response of {
      slot : slot;
      color : rgb option;
    }

let osc_query slot = Printf.sprintf "\x1b]%s;?\x1b\\" slot

let query =
  String.concat ""
    (osc_query "10"
     :: osc_query "11"
     :: List.init ansi_slot_count (fun i -> osc_query (Printf.sprintf "4;%d" i)))

let hex_component text =
  let is_hex = function
    | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
    | _ -> false
  in
  if not (String.for_all is_hex text) then None
  else
    match String.length text with
    | 2 -> int_of_string_opt ("0x" ^ text)
    | 4 -> Option.map (fun v -> v / 257) (int_of_string_opt ("0x" ^ text))
    | _ -> None

let rgb_of_payload payload =
  let components kind_length =
    String.sub payload kind_length (String.length payload - kind_length)
    |> String.split_on_char '/'
  in
  let color r_s g_s b_s =
    Option.bind (hex_component r_s) (fun red ->
        Option.bind (hex_component g_s) (fun green ->
            Option.map
              (fun blue -> { red; green; blue })
              (hex_component b_s)))
  in
  if String.starts_with ~prefix:"rgb:" payload then
    match components 4 with
    | [ r; g; b ] -> color r g b
    | _ -> None
  else if String.starts_with ~prefix:"rgba:" payload then
    match components 5 with
    | [ r; g; b; a ] when Option.is_some (hex_component a) -> color r g b
    | _ -> None
  else None

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
    match String.index_opt body ';' with
    | None -> Not_palette_response
    | Some first -> (
        let rest = String.sub body (first + 1) (String.length body - first - 1) in
        match String.index_opt rest ';' with
        | None -> Not_palette_response
        | Some second -> (
            let index_text = String.sub rest 0 second in
            match int_of_string_opt index_text with
            | Some idx when idx >= 0 && idx < ansi_slot_count ->
                parse (Ansi idx) (Printf.sprintf "4;%d;" idx)
            | Some _ | None -> Not_palette_response))
  else Not_palette_response

let of_responses ~foreground ~background ~ansi =
  match foreground, background with
  | Some foreground, Some background ->
      let ansi =
        if Array.length ansi = ansi_slot_count then Array.copy ansi
        else Array.make ansi_slot_count None
      in
      Some { foreground; background; ansi }
  | Some _, None | None, Some _ | None, None -> None

type snapshot = {
  palette : t option;
  generation : int;
}

let process_palette = Atomic.make { palette = None; generation = 0 }
let snapshot () = Atomic.get process_palette
let snapshot_palette s = s.palette
let snapshot_generation s = s.generation
let current () = (snapshot ()).palette

let rec set_current palette =
  let previous = snapshot () in
  let next = { palette; generation = previous.generation + 1 } in
  if not (Atomic.compare_and_set process_palette previous next) then
    set_current palette
