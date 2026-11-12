type t = Ready | Configured | Waiting | Changing | Failing | Off | Not_set_up | Unobserved

let all = [ Ready; Configured; Waiting; Changing; Failing; Off; Not_set_up; Unobserved ]

(* The marks the rest of the TUI already draws: ● done, ◌ pending, ✗ failed,
   ○ empty. *)
let mark = function
  | Ready | Configured -> "●"
  | Waiting -> "◌"
  | Changing -> "◐"
  | Failing -> "✗"
  | Off | Not_set_up -> "○"
  | Unobserved -> "?"

let word ~korean standing =
  match standing with
  | Ready -> if korean then "사용 가능" else "ready"
  | Configured -> if korean then "설정됨" else "configured"
  | Waiting -> if korean then "대기" else "waiting"
  | Changing -> if korean then "전환 중" else "changing"
  | Failing -> if korean then "실패" else "failing"
  | Off -> if korean then "꺼짐" else "off"
  | Not_set_up -> if korean then "미설정" else "not set up"
  | Unobserved -> if korean then "미관측" else "unknown"

let status : t -> Masc_tui_theme.status = function
  | Ready -> Ok
  | Waiting -> Warn
  | Configured | Changing -> Info
  | Failing -> Bad
  | Off | Not_set_up | Unobserved -> Muted

let colour standing =
  Masc_tui_theme.status_readable
    (Masc_tui_terminal_palette.snapshot_palette (Masc_tui_terminal_palette.snapshot ()))
    (status standing)

let recedes = function
  | Off | Not_set_up | Unobserved -> true
  | Ready | Configured | Waiting | Changing | Failing -> false

let count_items ~korean standings =
  List.filter_map (fun standing ->
      match List.length (List.filter (( = ) standing) standings) with
      | 0 -> None
      | count ->
          Some
            (if korean then Printf.sprintf "%s %d" (word ~korean standing) count
             else Printf.sprintf "%d %s" count (word ~korean standing)))
    all
