module Acting = Masc_tui_acting
module Layout = Masc_tui_message_layout

(* ── Width ───────────────────────────────────────────────────────────────

   The pane is a column of fleet rows. A row is a border cell, the health
   mark and its gap, a name, a gap, and the reading. Sixteen name cells keep
   the configured names whole that the roster's window keeps whole. The
   reading's budget is set by the longest reading a row states in full:
   [▶ network_read · 3 calls · 12.4s] is 32 cells, and a settled
   [■ 5 calls · 38.2k tok · 41.0s] or a waiting [? approval · tool_execute]
   fits inside it. A budget of 24 cut the tool name off every waiting row and
   the age off every settled one. *)
let border_cells = 1
let mark_cells = 2
let name_cells = 16
let gap_cells = 1
let reading_cells = 32
let pane_cols = border_cells + mark_cells + name_cells + gap_cells + reading_cells

(* What the roster pane leaves a surface is the least a surface lays out
   against anywhere in the TUI. Sharing that floor means a screen wide
   enough for both panes gives the surface no less than the roster alone. *)
let surface_floor_cols =
  Masc_tui_roster_pane.threshold_cols - Masc_tui_roster_pane.pane_cols

let threshold_cols = pane_cols + surface_floor_cols
let shown ~hidden ~cols = (not hidden) && cols >= threshold_cols

let toggle_hidden ~hidden ~cols =
  if cols < threshold_cols then None else Some (not hidden)

let content_cols ~hidden ~cols =
  if shown ~hidden ~cols then cols - pane_cols else cols

(* ── Input ─────────────────────────────────────────────────────────────── *)

type feed =
  | Feed_off
  | Feed_opening
  | Feed_live of int
  | Feed_closed of string

type keeper = {
  name : string;
  mark : string;
  mark_tone : tone;
  trace_id : string;
}

and tone =
  | Plain
  | Dim
  | Accent
  | Ok
  | Warn
  | Bad
  | Info

type approval = {
  approval_keeper : string;
  approval_tool : string;
}

type input = {
  now : float;
  feed : feed;
  keepers : keeper list;
  selected : string option;
  approvals : approval list;
  entries : Acting.entry list;
}

type span = {
  text : string;
  tone : tone;
}

type line = span list

type row_target =
  | Target_none
  | Target_keeper of string
  | Target_more

type rendering = {
  rows : line list;
  targets : row_target list;
  scroll_max : int;
}

(* ── Text ──────────────────────────────────────────────────────────────── *)

let middle_dot = " \xc2\xb7 "
let running_glyph = Acting.glyph_text Acting.Call_started
let settled_glyph = Acting.glyph_text Acting.Turn_settled
let attention_glyph = Acting.glyph_text Acting.Attention
let quiet_glyph = Acting.glyph_text Acting.Quiet
let rule_glyph = "\xe2\x94\x80"
let ellipsis = "\xe2\x80\xa6"
let up_arrow = "\xe2\x86\x91"
let down_arrow = "\xe2\x86\x93"

let age_text ~now at = Acting.elapsed_text (Float.max 0. (now -. at) *. 1000.)

let compact_count n =
  let thousand = 1_000 and million = 1_000_000 in
  if n >= million then Printf.sprintf "%.1fM" (float_of_int n /. float_of_int million)
  else if n >= thousand then
    Printf.sprintf "%.1fk" (float_of_int n /. float_of_int thousand)
  else string_of_int n

let tokens_text = function
  | None, None -> ""
  | Some i, Some o -> compact_count (i + o) ^ " tok"
  | Some n, None | None, Some n -> compact_count n ^ " tok"

let calls_text n = Printf.sprintf "%d call%s" n (if n = 1 then "" else "s")
let more_text n = Printf.sprintf "%d more" n

let cost_text = function
  | Some usd -> Printf.sprintf "$%.4f" usd
  | None -> ""

let join parts = String.concat middle_dot (List.filter (fun s -> s <> "") parts)

(* The tool a running turn is on: the newest call, from the ledger when it
   reported, else the wire. *)
let current_tool (chunk : Acting.chunk) =
  match List.rev (Acting.chunk_tools chunk) with
  | tool :: _ -> Some tool.Acting.ct_tool
  | [] -> None

let chunk_call_count (chunk : Acting.chunk) =
  match Acting.chunk_tools chunk with
  | [] -> Option.value ~default:0 chunk.Acting.ck_calls
  | tools -> List.length tools

let keeper_state_text ~now ~approval (chunk : Acting.chunk option) =
  match approval, chunk with
  | Some tool, _ ->
      [ { text = attention_glyph ^ " "; tone = Warn }
      ; { text = join [ "approval"; tool ]; tone = Warn }
      ]
  | None, Some chunk when not chunk.Acting.ck_settled ->
      let calls = chunk_call_count chunk in
      let on =
        match current_tool chunk with
        | Some tool -> tool
        | None -> "running"
      in
      [ { text = running_glyph ^ " "; tone = Ok }
      ; { text = join [ on; (if calls > 0 then calls_text calls else "") ]; tone = Plain }
      ; { text = middle_dot ^ age_text ~now chunk.Acting.ck_at; tone = Dim }
      ]
  | None, Some chunk ->
      [ { text = settled_glyph ^ " "; tone = Dim }
      ; { text =
            join
              [ calls_text (chunk_call_count chunk)
              ; tokens_text chunk.Acting.ck_tokens
              ]
        ; tone = Plain
        }
      ; { text = middle_dot ^ age_text ~now chunk.Acting.ck_at; tone = Dim }
      ]
  | None, None -> [ { text = quiet_glyph ^ " quiet"; tone = Dim } ]

(* ── Lines ─────────────────────────────────────────────────────────────── *)

let width spans =
  List.fold_left (fun acc span -> acc + Layout.display_width span.text) 0 spans

(* Exactly [cols] cells: cut the spans that overflow, pad what falls short.
   A span cut to nothing is dropped so a tone does not open on empty text. *)
let fit_line ~cols spans =
  let rec cut used acc = function
    | [] -> List.rev acc
    | span :: rest ->
        let cells = Layout.display_width span.text in
        if used + cells <= cols then cut (used + cells) (span :: acc) rest
        else
          let room = cols - used in
          if room <= 0 then List.rev acc
          else List.rev ({ span with text = Layout.take_cells span.text room } :: acc)
  in
  let spans = cut 0 [] spans in
  let short = cols - width spans in
  if short > 0 then spans @ [ { text = String.make short ' '; tone = Plain } ]
  else spans

let blank_line ~cols = fit_line ~cols []
let border = { text = "\xe2\x94\x82"; tone = Dim }
let with_border spans = border :: spans

let rule_line ~cols =
  let cells = max 0 (cols - border_cells) in
  fit_line ~cols
    [ border
    ; { text = String.concat "" (List.init cells (fun _ -> rule_glyph)); tone = Dim }
    ]

let header_line ~cols input =
  let keepers = List.length input.keepers in
  let feed =
    match input.feed with
    | Feed_off -> { text = "no feed"; tone = Dim }
    | Feed_opening -> { text = "feed opening"; tone = Dim }
    | Feed_live events ->
        { text = Printf.sprintf "live%s%s events" middle_dot (compact_count events); tone = Ok }
    | Feed_closed reason -> { text = "feed closed: " ^ reason; tone = Bad }
  in
  fit_line ~cols
    (with_border
       [ { text = "Activity"; tone = Accent }
       ; { text = Printf.sprintf "%s%d keeper%s%s" middle_dot keepers
             (if keepers = 1 then "" else "s") middle_dot
         ; tone = Dim
         }
       ; feed
       ])

(* Newest chunk per keeper: the fold returns chunks newest-activity first,
   so the first one met for a keeper is its current or latest turn. *)
let newest_chunk_by_keeper chunks =
  let table = Hashtbl.create 16 in
  List.iter
    (fun (chunk : Acting.chunk) ->
      if not (Hashtbl.mem table chunk.Acting.ck_keeper) then
        Hashtbl.replace table chunk.Acting.ck_keeper chunk)
    chunks;
  table

let approval_for approvals name =
  List.find_map
    (fun approval ->
      if String.equal approval.approval_keeper name then Some approval.approval_tool
      else None)
    approvals

(* Who acted last comes first. A keeper waiting on an approval outranks a
   working one: it is the row the reader can do something about. Keepers the
   feed has not shown acting sit at the bottom in the roster's own order. *)
let fleet_order input newest =
  let rank keeper =
    match approval_for input.approvals keeper.name, Hashtbl.find_opt newest keeper.name with
    | Some _, _ -> (0, 0.)
    | None, Some (chunk : Acting.chunk) when not chunk.Acting.ck_settled -> (1, -. chunk.Acting.ck_at)
    | None, Some chunk -> (2, -. chunk.Acting.ck_at)
    | None, None -> (3, 0.)
  in
  List.stable_sort (fun a b -> compare (rank a) (rank b)) input.keepers

let fleet_row ~cols input newest keeper =
  let chunk = Hashtbl.find_opt newest keeper.name in
  let approval = approval_for input.approvals keeper.name in
  let selected =
    match input.selected with
    | Some name -> String.equal name keeper.name
    | None -> false
  in
  ( fit_line ~cols
      (with_border
         ([ { text = Layout.fit_width keeper.mark mark_cells; tone = keeper.mark_tone }
          ; { text = Layout.fit_middle name_cells keeper.name
            ; tone = (if selected then Accent else Plain)
            }
          ; { text = String.make gap_cells ' '; tone = Plain }
          ]
          @ keeper_state_text ~now:input.now ~approval chunk))
  , Target_keeper keeper.name )

let more_line ~cols n =
  ( fit_line ~cols
      (with_border [ { text = ellipsis ^ " " ^ more_text n; tone = Dim } ])
  , Target_more )

let indicator_line ~cols arrow n =
  ( fit_line ~cols (with_border [ { text = arrow ^ " " ^ more_text n; tone = Dim } ])
  , Target_none )

(* The focus block: the selected keeper's current turn, call by call, then
   the turns before it. *)
let focus_keeper input newest =
  match input.selected with
  | Some name -> Some name
  | None ->
      (* No cursor: the keeper that acted last. *)
      Hashtbl.fold
        (fun name (chunk : Acting.chunk) acc ->
          match acc with
          | Some (_, at) when at >= chunk.Acting.ck_at -> acc
          | Some _ | None -> Some (name, chunk.Acting.ck_at))
        newest None
      |> Option.map fst

let tool_line ~cols ~now (chunk : Acting.chunk) (tool : Acting.chunk_tool) ~is_last =
  let duration =
    match tool.Acting.ct_duration_ms with
    | Some ms -> { text = Acting.elapsed_text ms; tone = Dim }
    | None when is_last && not chunk.Acting.ck_settled ->
        { text = "running" ^ middle_dot ^ age_text ~now chunk.Acting.ck_at; tone = Ok }
    | None -> { text = ""; tone = Dim }
  in
  let glyph =
    if is_last && (not chunk.Acting.ck_settled) && Option.is_none tool.Acting.ct_duration_ms
    then { text = running_glyph ^ " "; tone = Ok }
    else { text = settled_glyph ^ " "; tone = Dim }
  in
  let inner = cols - border_cells - mark_cells in
  let right = Layout.display_width duration.text in
  let name_room = max 0 (inner - right - (if right > 0 then gap_cells else 0)) in
  fit_line ~cols
    (with_border
       [ glyph
       ; { text = Layout.fit_width tool.Acting.ct_tool name_room; tone = Plain }
       ; { text = (if right > 0 then String.make gap_cells ' ' else ""); tone = Plain }
       ; duration
       ])

let turn_summary_line ~cols ~now (chunk : Acting.chunk) =
  fit_line ~cols
    (with_border
       [ { text = settled_glyph ^ " "; tone = Dim }
       ; { text = Acting.turn_text chunk.Acting.ck_turn; tone = Plain }
       ; { text =
             middle_dot
             ^ join
                 [ calls_text (chunk_call_count chunk)
                 ; tokens_text chunk.Acting.ck_tokens
                 ; cost_text chunk.Acting.ck_cost_usd
                 ]
         ; tone = Dim
         }
       ; { text = middle_dot ^ age_text ~now chunk.Acting.ck_at; tone = Dim }
       ])

(* Every focus row, oldest call first, then the earlier turns. The caller
   cuts to its budget. *)
let focus_lines ~cols input chunks name =
  let own =
    List.filter (fun (c : Acting.chunk) -> String.equal c.Acting.ck_keeper name) chunks
  in
  let approval = approval_for input.approvals name in
  let header =
    match own with
    | (current : Acting.chunk) :: _ ->
        fit_line ~cols
          (with_border
             [ { text = name; tone = Accent }
             ; { text = middle_dot ^ Acting.turn_text current.Acting.ck_turn; tone = Plain }
             ; { text =
                   middle_dot
                   ^ (if current.Acting.ck_settled then "settled" else "in turn")
               ; tone = (if current.Acting.ck_settled then Dim else Ok)
               }
             ])
    | [] ->
        fit_line ~cols
          (with_border
             [ { text = name; tone = Accent }
             ; { text = middle_dot ^ "no turn on this feed yet"; tone = Dim }
             ])
  in
  let approval_line =
    match approval with
    | Some tool ->
        [ fit_line ~cols
            (with_border
               [ { text = attention_glyph ^ " "; tone = Warn }
               ; { text = "waiting on approval" ^ middle_dot ^ tool; tone = Warn }
               ])
        ]
    | None -> []
  in
  let body =
    match own with
    | [] -> []
    | current :: earlier ->
        let tools = Acting.chunk_tools current in
        let count = List.length tools in
        let calls =
          List.mapi
            (fun index tool ->
              tool_line ~cols ~now:input.now current tool ~is_last:(index = count - 1))
            tools
        in
        let calls =
          if calls = [] && not current.Acting.ck_settled then
            [ fit_line ~cols
                (with_border
                   [ { text = running_glyph ^ " "; tone = Ok }
                   ; { text = "running" ^ middle_dot ^ age_text ~now:input.now current.Acting.ck_at
                     ; tone = Ok
                     }
                   ])
            ]
          else calls
        in
        calls @ List.map (turn_summary_line ~cols ~now:input.now) earlier
  in
  List.map (fun line -> (line, Target_none)) ((header :: approval_line) @ body)

(* The least each block needs before the two share the rows: the fleet one
   keeper and its fold line, the focus its rule and one row. Below that the
   fleet keeps every row it can use and the focus block waits for a taller
   terminal. *)
let fleet_min_rows = 2
let focus_min_rows = 2

(* The overview: the fleet folded to at most half the rows, the focus block
   after a rule. What the Activity pane opens on. *)
let overview_rows ~cols ~below input newest ordered focus focus_rows =
  let fleet_budget =
    match focus with
    | Some _ when below >= fleet_min_rows + focus_min_rows ->
        min (List.length ordered) (below / 2)
    | Some _ | None -> min (List.length ordered) below
  in
  let fleet =
    if List.length ordered > fleet_budget && fleet_budget >= 2 then
      let shown = List.filteri (fun index _ -> index < fleet_budget - 1) ordered in
      List.map (fleet_row ~cols input newest) shown
      @ [ more_line ~cols (List.length ordered - (fleet_budget - 1)) ]
    else
      List.filteri (fun index _ -> index < fleet_budget) ordered
      |> List.map (fleet_row ~cols input newest)
  in
  let after_fleet = below - List.length fleet in
  let focus_block =
    match focus with
    | Some _ when after_fleet >= focus_min_rows ->
        (rule_line ~cols, Target_none)
        :: List.filteri (fun index _ -> index < after_fleet - 1) focus_rows
    | Some _ | None -> []
  in
  fleet @ focus_block

(* The full list from [scroll], one row of it given to each indicator. The
   top indicator always draws once scrolled: it is how the reader knows the
   header is not the first row. The bottom one draws only when content is
   still hidden, and the row it takes counts as hidden too. *)
let scrolled_rows ~cols ~below ~scroll body =
  let total = List.length body in
  let room = below - 1 in
  let slice = List.filteri (fun index _ -> index >= scroll && index < scroll + room) body in
  let hidden_below = total - (scroll + room) in
  let slice =
    if hidden_below > 0 && room >= 1 then
      List.filteri (fun index _ -> index < room - 1) slice
      @ [ indicator_line ~cols down_arrow (hidden_below + 1) ]
    else slice
  in
  indicator_line ~cols up_arrow scroll :: slice

let lines ~rows ~cols ~scroll input =
  let rows = max 0 rows in
  if rows = 0 then { rows = []; targets = []; scroll_max = 0 }
  else
    let traces = List.map (fun keeper -> (keeper.name, keeper.trace_id)) input.keepers in
    let chunks = Acting.chunks ~traces input.entries in
    let newest = newest_chunk_by_keeper chunks in
    let focus = focus_keeper input newest in
    let header = (header_line ~cols input, Target_none) in
    let below = rows - 1 in
    let ordered = fleet_order input newest in
    let focus_rows =
      match focus with
      | Some name -> focus_lines ~cols input chunks name
      | None -> []
    in
    (* The full list: every fleet row, then the rule and the focus block when
       there is one. Scrolling walks this; the overview folds it. *)
    let body =
      List.map (fleet_row ~cols input newest) ordered
      @ (match focus_rows with
         | [] -> []
         | _ :: _ -> (rule_line ~cols, Target_none) :: focus_rows)
    in
    let total = List.length body in
    (* At the largest scroll the last row is on screen under the top
       indicator alone; one row of the window belongs to that indicator. *)
    let scroll_max = if total <= below then 0 else max 0 (total - (below - 1)) in
    let scroll = max 0 (min scroll scroll_max) in
    let drawn =
      if total <= below then body
      else if scroll = 0 then
        overview_rows ~cols ~below input newest ordered focus focus_rows
      else scrolled_rows ~cols ~below ~scroll body
    in
    let drawn = header :: drawn in
    let padding =
      List.init (max 0 (rows - List.length drawn)) (fun _ -> (blank_line ~cols, Target_none))
    in
    let drawn = List.filteri (fun index _ -> index < rows) (drawn @ padding) in
    { rows = List.map fst drawn; targets = List.map snd drawn; scroll_max }
