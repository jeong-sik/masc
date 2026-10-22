type t = Ready | Waiting | Changing | Failing | Off | Not_set_up | Unobserved

let all = [ Ready; Waiting; Changing; Failing; Off; Not_set_up; Unobserved ]

(* The marks the rest of the TUI already draws: ● done, ◌ pending, ✗ failed,
   ○ empty. *)
let mark = function
  | Ready -> "●"
  | Waiting -> "◌"
  | Changing -> "◐"
  | Failing -> "✗"
  | Off | Not_set_up -> "○"
  | Unobserved -> "?"

let word = function
  | Ready -> "ready"
  | Waiting -> "waiting"
  | Changing -> "changing"
  | Failing -> "failing"
  | Off -> "off"
  | Not_set_up -> "not set up"
  | Unobserved -> "unknown"

let status : t -> Masc_tui_theme.status = function
  | Ready -> Ok
  | Waiting -> Warn
  | Changing -> Info
  | Failing -> Bad
  | Off | Not_set_up | Unobserved -> Muted

let colour standing =
  Masc_tui_theme.status_readable
    (Masc_tui_terminal_palette.snapshot_palette (Masc_tui_terminal_palette.snapshot ()))
    (status standing)

let recedes = function
  | Off | Not_set_up | Unobserved -> true
  | Ready | Waiting | Changing | Failing -> false

let counts standings =
  List.filter_map (fun standing ->
      match List.length (List.filter (( = ) standing) standings) with
      | 0 -> None
      | count -> Some (Printf.sprintf "%d %s" count (word standing)))
    all
  |> String.concat " · "
