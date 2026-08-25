type rgb =
  { red : int
  ; green : int
  ; blue : int
  }

let red color = color.red
let green color = color.green
let blue color = color.blue

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
