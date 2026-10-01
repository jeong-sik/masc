(** Pure command-palette entries, typed destinations and matching.
    Navigation, model calls and gate mutations remain with the input dispatcher. *)

open Masc_tui_types

module Rows = Masc_tui_rows

(* Prefix match: the label starts with the query. An empty query is a prefix
   of everything. *)
let palette_starts_with ~needle haystack =
  String.starts_with
    ~prefix:(String.lowercase_ascii needle)
    (String.lowercase_ascii haystack)

let palette_contains ~needle haystack =
  Masc_tui_pick_list.lowercase_contains ~needle haystack

(* Command-palette jump targets. Surfaces come from the same ring the strip
   draws; keepers come from the loaded roster, so the palette can only offer
   a chat the roster can open. *)
type gate_lane = Workspace_gate | External_gate

let gate_lane_label = function
  | Workspace_gate -> "Workspace"
  | External_gate -> "Outside services"

let gate_mode_label = function
  | Masc.Keeper_gate_mode.Manual -> "Ask me for each decision"
  | Masc.Keeper_gate_mode.Auto_judge -> "Let Auto Judge decide"
  | Masc.Keeper_gate_mode.Always_allow -> "Allow every call without review"

type palette_action =
  | Palette_browser_lane
  | Palette_hide_browser_lane
  (* Connectors draws two screens: the transport list, and the Browser Lane
     that [show_browser_lane] opens under the same view. A plain
     [Palette_goto Connectors] lands on whichever the lane's visibility says,
     so the list -- the half with no key of its own -- would still be
     unreachable whenever the lane had been opened once. This one names the
     list and closes the lane to get there. *)
  | Palette_connectors
  | Palette_msx
  | Palette_dos
  | Palette_lane_addons
  | Palette_goto of surface
  | Palette_config of config_pane
  | Palette_gate_mode of gate_lane * Masc.Keeper_gate_mode.t
  | Palette_chat of string
  | Palette_task of string
  | Palette_board_hearth of string option
  | Palette_board_post of string
  (* (question, symbol): a language-server question about a name on the
     Code pane's cursor line — the K/D candidates ride the palette as
     entries so one keypress can also be a choice among several names. *)
  | Palette_lsp of string * string

(* The identifier names on the file pane's cursor line, in reading order,
   first occurrence only. The open file already carries its lexed segments,
   so the scan skips what the lexer called a keyword, a string, a comment,
   or a number -- those offer no name a language server answers about --
   rather than keeping a second keyword list that could drift. *)
let code_cursor_line_symbols (state : state) =
  match Masc_tui_fetched.current state.code_file with
  | Some (_, Masc_tui_fetched.Ready rows) -> (
      match Rows.at (Rows.of_array rows) state.code_file_cursor with
      | None -> []
      | Some segments ->
          let name_kind kind =
            not
              (List.exists (String.equal kind)
                 [ Masc_tui_code_lexer.kind_keyword;
                   Masc_tui_code_lexer.kind_string;
                   Masc_tui_code_lexer.kind_comment;
                   Masc_tui_code_lexer.kind_number ])
          in
          let starts c =
            (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
          in
          let continues c =
            starts c || (c >= '0' && c <= '9') || c = '\''
          in
          let names = ref [] in
          List.iter
            (fun (text, kind) ->
              if name_kind kind then begin
                let n = String.length text in
                let i = ref 0 in
                while !i < n do
                  if starts text.[!i] then begin
                    let j = ref (!i + 1) in
                    while !j < n && continues text.[!j] do
                      incr j
                    done;
                    let name = String.sub text !i (!j - !i) in
                    if not (List.exists (String.equal name) !names) then
                      names := name :: !names;
                    i := !j
                  end
                  else incr i
                done
              end)
            segments;
          List.rev !names)
  (* No open file, still reading, or the read failed: nothing to name. *)
  | Some (_, (Masc_tui_fetched.Loading | Masc_tui_fetched.Stale _ | Masc_tui_fetched.Failed _))
  | Some (_, Masc_tui_fetched.Absent)
  | None -> []

(* The prefixes a typed palette line uses to ask the language server, paired
   with the question each names. One list, because two readers use it: the
   entries the palette offers are built from it, and the palette's Enter arm
   parses a typed line with it. A question spelled in one and not the other
   is a line the operator can type and nothing answers. *)
let lsp_question_prefixes =
  [ "def ", "definition"; "hover ", "hover"; "refs ", "references" ]

let palette_typed_question query =
  let query = String.trim query in
  let word, symbol =
    match String.index_opt query ' ' with
    | None -> query, None
    | Some index ->
        let symbol = String.trim (String.sub query (index + 1)
            (String.length query - index - 1)) in
        String.sub query 0 index,
        (if String.equal symbol "" then None else Some symbol)
  in
  List.find_map (fun (prefix, question) ->
      if String.equal word (String.trim prefix) then Some (question, symbol)
      else None) lsp_question_prefixes

let palette_entries (state : state) =
  [ "settings", Palette_config Config_params ]
  @ List.concat_map (fun lane ->
      List.map (fun mode ->
        ("gate " ^ gate_lane_label lane ^ " / " ^ gate_mode_label mode,
         Palette_gate_mode (lane, mode)))
        [Masc.Keeper_gate_mode.Manual; Masc.Keeper_gate_mode.Auto_judge; Masc.Keeper_gate_mode.Always_allow])
      [Workspace_gate; External_gate]
  (* Both halves, because they are one reading split in two: Task Review lists
     what waits for a ruling and Task Verdicts what was ruled. They sit one [v]
     apart under Planning, so offering a jump to one and not the other makes the
     nearer half look like the only one there is. *)
  @ [ "go Task Review", Palette_goto Verification ]
  @ [ "go Task Verdicts", Palette_goto Harness ]
  @ [ "go Lanes", Palette_goto Lanes ]
  @ [ "go Clients", Palette_goto Clients ]
  @ [ "go Schedules", Palette_goto Schedules ]
  @ [ "go Code", Palette_goto Code ]
  @ [ "go Resources", Palette_goto Resources ]
  @ [ "go Tools", Palette_goto Tools ]
  (* Two surfaces had no row: Runtime sits under Config behind [9], Changes
     under Keepers behind [f], and the palette is where a destination is
     reached by name when the key path to it is not known. Changes follows the
     keeper selected on Keepers and says so when there is none. *)
  @ [ "go Runtime", Palette_goto Runtime ]
  @ [ "go Changes", Palette_goto Changes ]
  @ (match browser_lane_on_screen state with
      | None -> []
      | Some _ -> [ "hide Browser Lane", Palette_hide_browser_lane ])
  @ [ "go Browser Lane", Palette_browser_lane ]
  (* The transport list had no way in at all between #32242 and now: the one
     place that sets [view <- Connectors] is [show_browser_lane], which opens
     the lane in the same breath, and neither the surface ring nor Esc comes
     back to the list. The palette is where a destination is reached by name
     when there is no key path to it. *)
  @ [ "go Connectors", Palette_connectors ]
  @ [ "go MSX", Palette_msx ]
  @ [ "go DOS", Palette_dos ]
  @ [ "go Lane Add-ons", Palette_lane_addons ]
  @ [ "go Logs", Palette_goto System_logs ]
  @ [ "go Activity", Palette_goto Acting ]
  @ [ "go Approvals", Palette_goto Approvals ]
  @ [ "go Memory", Palette_goto Memory ]
  @ [ "go Fusion", Palette_goto Fusion ]
  @ List.map
      (fun (surface, label) -> ("go " ^ label, Palette_goto surface))
      surface_ring
  (* After the ring, so "go system" still leads with the System surface: the
     ranks tie on a label that starts with the query, and a tie keeps entry
     order. *)
  @ List.map
      (fun (pane, label) -> ("go System / " ^ label, Palette_config pane))
      config_panes
  @ List.map
      (fun (keeper : keeper) ->
        ("keeper " ^ keeper.k_name, Palette_chat keeper.k_name))
      state.keepers
  @ List.map
      (fun (t : task) -> ("task " ^ t.id ^ " " ^ t.title, Palette_task t.id))
      state.tasks
  @ [ "hearth all", Palette_board_hearth None ]
  @ List.map (fun (name, count) ->
      (Printf.sprintf "hearth %s (%s)" name (Masc_tui_message_layout.count_noun count "post"), Palette_board_hearth (Some name)))
      state.board_hearths
  @ List.map
      (fun (p : board_post) ->
        ("post " ^ p.bp_title, Palette_board_post p.bp_id))
      state.board_posts
  @ (* With a file focused on the Code surface, the cursor line's names are
       askable: K/D/R pre-fill the matching prefix, and [palette_matches]
       ranks a label that starts with the query first, so these lead the
       list. *)
  (if state.view = Code && state.code_focus_file = Right_pane then
     List.concat_map
       (fun name ->
         List.map
           (fun (prefix, question) -> (prefix ^ name, Palette_lsp (question, name)))
           lsp_question_prefixes)
       (code_cursor_line_symbols state)
   else [])

(* Subsequence match: every query character appears in order. "kadm" finds
   "keeper adm-race". *)
let palette_subsequence ~needle haystack =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let hl = String.length h and nl = String.length n in
  let rec walk hi ni =
    if ni >= nl then true
    else if hi >= hl then false
    else if Char.equal h.[hi] n.[ni] then walk (hi + 1) (ni + 1)
    else walk (hi + 1) ni
  in
  walk 0 0

(* Other words an entry answers to, kept off its row. Metrics used to be five
   rows -- "go Metrics", "metrics", "telemetry", "charts", "stats" -- each the
   same jump, so an empty query listed one destination five times. The slash
   commands fold their aliases into one entry the same way
   (Masc_tui_command.spelled_catalog). *)
let palette_action_words = function
  | Palette_goto Metrics -> [ "metrics"; "telemetry"; "charts"; "stats" ]
  | Palette_goto
      ( Overview | Acting | Keepers _ | Memory | Lanes | Clients | Board
      | Approvals | Planning | Schedules | Verification | Harness | Fusion
      | Repositories | Code | Changes | Connectors | Runtime | Config
      | Resources | Tools | System_logs )
  | Palette_browser_lane | Palette_hide_browser_lane | Palette_connectors
  | Palette_msx | Palette_dos
  | Palette_lane_addons | Palette_config _ | Palette_gate_mode _
  | Palette_chat _ | Palette_task _ | Palette_board_hearth _
  | Palette_board_post _ | Palette_lsp _ ->
      []

let palette_matches (state : state) =
  let needle = String.trim state.palette_query in
  let entries =
    match state.palette_mode with
    | Palette_jump ->
        let entries = palette_entries state in
        (match palette_typed_question state.palette_query with
         | None -> entries
         | Some (question, None) ->
             List.filter (function
               | _, Palette_lsp (candidate_question, _) ->
                   String.equal question candidate_question
               | _ -> false) entries
         | Some (_, Some _) -> [])
    | Palette_choice { choice_question; _ } ->
        List.map
          (fun name -> (name, Palette_lsp (choice_question, name)))
          (code_cursor_line_symbols state)
  in
  (* Three ranks, entry order kept inside each: a label that starts with the
     query, then one that contains it, then one that only has its characters
     in order. Typed Code questions retain only executable symbol candidates;
     ordinary jump filters continue ranking destinations and content. *)
  let rank (label, action) =
    let texts = label :: palette_action_words action in
    if List.exists (palette_starts_with ~needle) texts then Some 0
    else if List.exists (palette_contains ~needle) texts then Some 1
    else if List.exists (palette_subsequence ~needle) texts then Some 2
    else None
  in
  entries
  |> List.filter_map (fun entry ->
         Option.map (fun r -> (r, entry)) (rank entry))
  |> List.stable_sort (fun (a, _) (b, _) -> Int.compare a b)
  |> List.map snd
