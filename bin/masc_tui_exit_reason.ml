(* Why a TUI session ended. See the .mli for what the split is for. *)

type t =
  | Quit_key
  | Interrupt
  | Terminate of string
  | Exception of string
  | Unrecorded

let label = function
  | Quit_key -> "quit key"
  | Interrupt -> "interrupt"
  | Terminate signal -> "signal " ^ signal
  | Exception detail -> "exception " ^ detail
  | Unrecorded -> "no cause was recorded"
;;

let is_normal = function
  | Quit_key | Interrupt | Terminate _ -> true
  | Exception _ | Unrecorded -> false
;;

(* One row: the log is read a line at a time, and an exception message can
   carry a newline or another control byte. *)
let one_row text =
  String.map
    (fun c ->
      let code = Char.code c in
      if code < 0x20 || code = 0x7F then ' ' else c)
    text
;;

(* An uncaught exception's message can carry a whole backtrace, and the row
   for that session would then run to kilobytes -- the opposite of what this
   line is for, since a reader greps these rows and reads them beside each
   other. So the cause is bounded. A bounded cause says how much it dropped
   rather than trailing off into an ellipsis: a reader has to know the text
   continues, and by how much, to decide whether to go looking for the rest. *)
let cause_limit = 200

(* Cut on a character, not a byte: a UTF-8 continuation byte (0b10xxxxxx)
   cannot start a character, so back up to its lead byte rather than leave
   half of one in the log. *)
let rec character_boundary text index =
  if index <= 0 then 0
  else if Char.code text.[index] land 0xC0 = 0x80 then
    character_boundary text (index - 1)
  else index
;;

let bounded text =
  let length = String.length text in
  if length <= cause_limit then text
  else
    let cut = character_boundary text cause_limit in
    Printf.sprintf "%s [+%d bytes]" (String.sub text 0 cut) (length - cut)
;;

let line t =
  Printf.sprintf "exit: %s (%s)"
    (if is_normal t then "normal" else "abnormal")
    (bounded (one_row (label t)))
;;
