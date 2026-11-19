type t = Ready | Configured | Waiting | Changing | Failing | Off | Not_set_up | Unobserved

let all = [ Ready; Configured; Waiting; Changing; Failing; Off; Not_set_up; Unobserved ]

(* The status marks of RFC tui-one-screen-grammar 7.2, one meaning each:
   ● ready, ◐ changing, ○ waiting, ‖ turned off, ✕ failing. A lane with nothing
   set up has no value, so it wears the confirmed-none mark [—], and one whose
   state could not be read the unknown mark [?] (6.4). *)
let mark = function
  | Ready | Configured -> Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Settled
  | Changing -> Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way
  | Waiting -> Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Waiting
  | Off -> Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Paused
  | Failing -> Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Failed
  | Not_set_up -> Masc_tui_theme.Glyph.no_value
  | Unobserved -> Masc_tui_value.Unknown.glyph Masc_tui_value.Unknown.Unreported

let word ~korean standing =
  match standing with
  | Ready -> if korean then "사용 가능" else "ready"
  | Configured -> if korean then "설정됨" else "configured"
  | Waiting -> if korean then "대기" else "waiting"
  | Changing -> if korean then "전환 중" else "changing"
  | Failing -> if korean then "실패" else "failing"
  | Off -> if korean then "꺼짐" else "off"
  | Not_set_up -> if korean then "미설정" else "not set up"
  | Unobserved -> if korean then "못 읽음" else "not read"

let status : t -> Masc_tui_theme.status = function
  | Ready -> Ok
  | Configured | Changing -> Info
  | Failing -> Bad
  | Waiting | Off | Not_set_up | Unobserved -> Muted

let colour standing =
  Masc_tui_theme.status_readable ~surface:Masc_tui_theme.Page
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
