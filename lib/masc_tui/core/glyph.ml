type t =
  | Action_required
  | Live_healthy
  | Live_working
  | Live_working_frame of int
  | Live_idle
  | Live_paused
  | Live_failing
  | Historical_incident
  | Recovered
  | Transport_reconnecting
  | Transport_stale
  | Focus_caret
  | Expand_open
  | Expand_closed
  | Delta_up
  | Delta_down
  | Delta_flat
  | Missing_unreported
  | Missing_absent
  | Separator_dot
  | Prompt_caret
  | External_arrow
  | Tool_square
  | Spark_mark
  | Warning_triangle
  | Check_mark
  | Ellipsis
  | Left_rail
  | Ai_spark
  | Flow_down
  | Tree_tee
  | Tree_corner
  | Tree_pipe
  | Box_tl
  | Box_tr
  | Box_bl
  | Box_br
  | Box_h
  | Box_v
  | Box_heavy_tl
  | Box_heavy_tr
  | Box_heavy_bl
  | Box_heavy_br
  | Box_heavy_h
  | Box_heavy_v
  | Box_tee_l
  | Box_tee_r
  | Box_tee_t
  | Box_tee_b
  | Box_cross

let working_frames = [| "◐"; "◓"; "◑"; "◒" |]
let working_ascii_frames = [| "|"; "/"; "-"; "\\" |]

let frame_index n =
  let m = n mod 4 in
  if m < 0 then m + 4 else m

let to_utf8 = function
  | Action_required -> "◆"
  | Live_healthy -> "●"
  | Live_working -> "◐"
  | Live_working_frame n -> working_frames.(frame_index n)
  | Live_idle -> "○"
  | Live_paused -> "‖"
  | Live_failing -> "✕"
  | Historical_incident -> "▴"
  | Recovered -> "◂"
  | Transport_reconnecting -> "◌"
  | Transport_stale -> "△"
  | Focus_caret -> "▸"
  | Expand_open -> "▾"
  | Expand_closed -> "▸"
  | Delta_up -> "▲"
  | Delta_down -> "▼"
  | Delta_flat -> "─"
  | Missing_unreported -> "?"
  | Missing_absent -> "—"
  | Separator_dot -> "·"
  | Prompt_caret -> "›"
  | External_arrow -> "◀"
  | Tool_square -> "■"
  | Spark_mark -> "*"
  | Warning_triangle -> "△"
  | Check_mark -> "✓"
  | Ellipsis -> "…"
  | Left_rail -> "▎"
  | Ai_spark -> "✦"
  | Flow_down -> "↓"
  | Tree_tee -> "├"
  | Tree_corner -> "└"
  | Tree_pipe -> "│"
  | Box_tl -> "╭"
  | Box_tr -> "╮"
  | Box_bl -> "╰"
  | Box_br -> "╯"
  | Box_h -> "─"
  | Box_v -> "│"
  | Box_heavy_tl -> "┏"
  | Box_heavy_tr -> "┓"
  | Box_heavy_bl -> "┗"
  | Box_heavy_br -> "┛"
  | Box_heavy_h -> "━"
  | Box_heavy_v -> "┃"
  | Box_tee_l -> "├"
  | Box_tee_r -> "┤"
  | Box_tee_t -> "┬"
  | Box_tee_b -> "┴"
  | Box_cross -> "┼"

let to_ascii_fallback = function
  | Action_required -> "!"
  | Live_healthy -> "*"
  | Live_working -> "~"
  | Live_working_frame n -> working_ascii_frames.(frame_index n)
  | Live_idle -> "o"
  | Live_paused -> "="
  | Live_failing -> "x"
  | Historical_incident -> "^"
  | Recovered -> "<"
  | Transport_reconnecting -> "~"
  | Transport_stale -> "!"
  | Focus_caret -> ">"
  | Expand_open -> "v"
  | Expand_closed -> ">"
  | Delta_up -> "^"
  | Delta_down -> "v"
  | Delta_flat -> "-"
  | Missing_unreported -> "?"
  | Missing_absent -> "-"
  | Separator_dot -> "."
  | Prompt_caret -> ">"
  | External_arrow -> "<"
  | Tool_square -> "#"
  | Spark_mark -> "*"
  | Warning_triangle -> "!"
  | Check_mark -> "+"
  | Ellipsis -> "."
  | Left_rail -> "|"
  | Ai_spark -> "*"
  | Flow_down -> "v"
  | Tree_tee -> "+"
  | Tree_corner -> "`"
  | Tree_pipe -> "|"
  | Box_tl -> "+"
  | Box_tr -> "+"
  | Box_bl -> "+"
  | Box_br -> "+"
  | Box_h -> "-"
  | Box_v -> "|"
  | Box_heavy_tl -> "+"
  | Box_heavy_tr -> "+"
  | Box_heavy_bl -> "+"
  | Box_heavy_br -> "+"
  | Box_heavy_h -> "="
  | Box_heavy_v -> "|"
  | Box_tee_l -> "+"
  | Box_tee_r -> "+"
  | Box_tee_t -> "+"
  | Box_tee_b -> "+"
  | Box_cross -> "+"

let all =
  [
    Action_required;
    Live_healthy;
    Live_working;
    Live_working_frame 0;
    Live_working_frame 1;
    Live_working_frame 2;
    Live_working_frame 3;
    Live_idle;
    Live_paused;
    Live_failing;
    Historical_incident;
    Recovered;
    Transport_reconnecting;
    Transport_stale;
    Focus_caret;
    Expand_open;
    Expand_closed;
    Delta_up;
    Delta_down;
    Delta_flat;
    Missing_unreported;
    Missing_absent;
    Separator_dot;
    Prompt_caret;
    External_arrow;
    Tool_square;
    Spark_mark;
    Warning_triangle;
    Check_mark;
    Ellipsis;
    Left_rail;
    Ai_spark;
    Flow_down;
    Tree_tee;
    Tree_corner;
    Tree_pipe;
    Box_tl;
    Box_tr;
    Box_bl;
    Box_br;
    Box_h;
    Box_v;
    Box_heavy_tl;
    Box_heavy_tr;
    Box_heavy_bl;
    Box_heavy_br;
    Box_heavy_h;
    Box_heavy_v;
    Box_tee_l;
    Box_tee_r;
    Box_tee_t;
    Box_tee_b;
    Box_cross;
  ]
