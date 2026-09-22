(* Why a TUI session ended. See the .mli for what the split is for. *)

type t =
  | Quit_key
  | Interrupt
  | Terminate of string
  | Exception of string

let label = function
  | Quit_key -> "quit key"
  | Interrupt -> "interrupt"
  | Terminate signal -> "signal " ^ signal
  | Exception detail -> "exception " ^ detail
;;

let is_normal = function
  | Quit_key | Interrupt | Terminate _ -> true
  | Exception _ -> false
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

let line t =
  Printf.sprintf "exit: %s (%s)"
    (if is_normal t then "normal" else "abnormal")
    (one_row (label t))
;;
