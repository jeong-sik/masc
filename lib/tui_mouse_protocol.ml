(** Which way a wheel notch turned. The two are the whole vocabulary: the
    horizontal wheel is not a scroll and stays unclaimed. *)
type wheel_direction =
  | Wheel_up
  | Wheel_down

(* The key a wheel notch becomes for a surface's scroll binding: its own,
   not the arrow's. A notch moves further than one row, and the chat
   composer answers the arrows with its history, so a shared key made one
   of the two wrong. *)
let wheel_key = function
  | Wheel_up -> "wheel-up"
  | Wheel_down -> "wheel-down"

(** Decode one SGR-encoded mouse report ([CSI ?1006;1000h] mode) into a wheel
    notch and where it happened.

    The position travels with the notch because more than one thing on the
    screen can scroll: the Activity pane beside a surface takes the notches
    over its own columns, and the surface takes the rest. Wheel-up is button
    [64], wheel-down [65]; the horizontal wheel, clicks, and releases stay
    [None] -- the terminal sends them, but this function claims none of them,
    and an unconsumed report must not masquerade as a claimed key.
    [parameters] is the raw CSI parameter span (["<64;10;5"] for a wheel-up at
    column 10, row 5) and [final] the CSI final byte. The position is 1-based,
    the way the terminal reports it, and stays row/column ordered the way a
    frame thinks. *)
let sgr_wheel_report (parameters : string) (final : char)
    : (wheel_direction * int * int) option =
  if final <> 'M' then None
  else
    match String.split_on_char ';' parameters with
    | [ button; column; row ] -> (
        let direction =
          if String.equal button "<64" then Some Wheel_up
          else if String.equal button "<65" then Some Wheel_down
          else None
        in
        match direction, int_of_string_opt column, int_of_string_opt row with
        | Some direction, Some column, Some row when column > 0 && row > 0 ->
            Some (direction, row, column)
        | _, _, _ -> None)
    | _ -> None

(** Decode an SGR mouse report into the position of a plain left-button press.

    Only the unmodified press (button [0], final [M]) answers: a release
    (final [m]) would act twice per click, and modifier/motion bits mean the
    operator was dragging or chord-clicking rather than choosing a row. The
    position is 1-based, the way the terminal reports it, and stays row/column
    ordered the way a frame thinks. Everything else stays [None] for the same
    reason [sgr_wheel_report] gives: an unconsumed report must not masquerade as
    a claimed key. *)
let sgr_left_press (parameters : string) (final : char) : (int * int) option =
  if final <> 'M' then None
  else
    match String.split_on_char ';' parameters with
    | [ "<0"; column; row ] -> (
        match int_of_string_opt column, int_of_string_opt row with
        | Some column, Some row when column > 0 && row > 0 -> Some (row, column)
        | _, _ -> None)
    | _ -> None

(** Browser screenshots use release coordinates to distinguish a click from a drag.
    Other surfaces continue to consume only presses. *)
let sgr_left_release parameters final =
  if final = 'm' then sgr_left_press parameters 'M' else None

(** Decode a legacy X10 mouse report ([CSI M] followed by three raw bytes: the
    button, the column and the row) into the events an SGR report gives.

    Terminals that do not implement SGR ([?1006]) still answer the tracking
    request ([?1000]) in this older shape. Apple Terminal is one, and it is the
    macOS default: the combined [?1006;1000h] request leaves it reporting X10,
    so a reader that only understands SGR sees [CSI M], calls the sequence
    unknown, and leaves the three coordinate bytes in the stream to be typed as
    text. Live shape 2026-08-24: one wheel notch put three characters in the
    chat composer. Reading only the button kept the notch and dropped where it
    happened, so a press never reached what it was on and a notch over a
    reading moved the list behind it.

    Each byte is offset by 32, and the buttons are SGR's numbers: wheel-up 64,
    wheel-down 65, a plain left press 0. Any other press -- middle, right, or
    a button held with shift, meta or ctrl -- is [X10_other_press]: no surface
    reads it, but its release comes next and must not be taken for the left
    button's. X10 has one release code, 3 in the button bits, for whichever
    button went up, so the reader claims a left release only while the left
    press is the only one held: once presses overlap, lifting either button
    first reads the same.
    Motion reports, the horizontal wheel and a position byte below the offset
    stay [None]. The caller consumes the three bytes whatever this returns. *)
type x10_mouse =
  | X10_wheel of wheel_direction * int * int
  | X10_left_press of int * int
  | X10_other_press
  | X10_release of int * int

let x10_byte_offset = 32
let x10_button_bits = 3
let x10_release_code = 3
let x10_motion_bit = 32
let x10_wheel_bit = 64
let x10_left_press_button = 0
let x10_wheel_up_button = 64
let x10_wheel_down_button = 65

let x10_mouse_report ~(button : char) ~(column : char) ~(row : char)
    : x10_mouse option =
  let decoded byte = Char.code byte - x10_byte_offset in
  let row = decoded row and column = decoded column and code = decoded button in
  if row <= 0 || column <= 0 || code land x10_motion_bit <> 0 then None
  else if code land x10_wheel_bit <> 0 then
    if code = x10_wheel_up_button then Some (X10_wheel (Wheel_up, row, column))
    else if code = x10_wheel_down_button then
      Some (X10_wheel (Wheel_down, row, column))
    else None
  else if code land x10_button_bits = x10_release_code then
    Some (X10_release (row, column))
  else if code = x10_left_press_button then Some (X10_left_press (row, column))
  else Some X10_other_press
;;
