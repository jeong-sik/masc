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

(* Whole match: the text is the query, whatever the case. *)
let palette_equals ~needle haystack =
  String.equal (String.lowercase_ascii needle) (String.lowercase_ascii haystack)

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
  | Palette_collab
  | Palette_msx
  | Palette_dos
  | Palette_lane_addons
  | Palette_lane_history of Lane_run_identity.t
  (* One installation's Results, by its declaration id. *)
  | Palette_addon_results of string
  | Palette_goto of surface
  | Palette_usage_scope of string option
  | Palette_config of config_pane
  | Palette_ui_language of ui_language
  | Palette_gate_mode of gate_lane * Masc.Keeper_gate_mode.t
  | Palette_chat of string
  | Palette_task of string
  | Palette_task_creation of task_dispatch_request
  | Palette_board_hearth of string option
  | Palette_board_post of string
  (* (question, symbol): a language-server question about a name on the
     Code pane's cursor line — the K/D candidates ride the palette as
     entries so one keypress can also be a choice among several names. *)
  | Palette_lsp of string * string
  | Palette_code_file of string
  | Palette_code_location of code_location_offer * Masc.Tui_decode.lsp_location
  | Palette_code_branch of Masc.Tui_decode.git_branch
  | Palette_code_worktree of Masc.Tui_decode.git_worktree
  | Palette_code_search_match of Masc.Tui_decode.workspace_search_match

(* The identifier names on the file pane's cursor line, in reading order,
   first occurrence only. The open file already carries its lexed segments,
   so the scan skips what the lexer called a keyword, a string, a comment,
   a number, or a JSON literal -- those offer no name a language server
   answers about -- rather than keeping a second keyword list that could
   drift. *)
let code_cursor_line_symbols (state : state) =
  match Masc_tui_fetched.current state.code_file with
  | Some (_, Masc_tui_fetched.Ready { cfd_rows = rows; _ }) -> (
      match Rows.at (Rows.of_array rows) state.code_file_cursor with
      | None -> []
      | Some segments ->
          let name_kind kind =
            not
              (List.exists (String.equal kind)
                 [ Masc_tui_code_lexer.kind_keyword;
                   Masc_tui_code_lexer.kind_string;
                   Masc_tui_code_lexer.kind_comment;
                   Masc_tui_code_lexer.kind_number;
                   Masc_tui_code_lexer.kind_json_number;
                   Masc_tui_code_lexer.kind_json_literal ])
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

(* The installations whose Results the palette can open, as (declaration id,
   title), from what this TUI has already read: an installation that asked a
   question, one the Lanes list showed live, one the Lane Add-ons screen read
   live. An installation none of them has shown is not offered; the first
   title read for an id names it. *)
let addon_result_targets (state : state) =
  let module Asks = Masc.Tui_decode_asks in
  let module Inventory = Masc.Tui_decode_lane_inventory in
  let module Addons = Masc_tui_lane_addons in
  let from_asks = match state.asks_snapshot with
    | None -> []
    | Some snapshot -> List.filter_map (fun (row : Asks.ask_row) ->
        match row.ar_asker with
        | Asks.Ask_installation { ai_declaration_id; ai_title } -> Some (ai_declaration_id, ai_title)
        | Asks.Ask_keeper _ -> None) snapshot.asn_rows in
  let from_inventory = match state.lane_inventory with
    | None -> []
    | Some snapshot -> List.filter_map (fun (row : Inventory.row) ->
        match row.state with
        | Inventory.Package_state { declaration = Some (Inventory.Valid { installation_id; title; _ }); instances } ->
            if List.exists (fun (instance : Inventory.instance) -> instance.presence = Inventory.Live) instances
            then Some (installation_id, title) else None
        | Inventory.Package_state
            { declaration = (Some (Inventory.Invalid _ | Inventory.Absent | Inventory.Unobserved) | None); _ }
        | Inventory.Exact_state _ | Inventory.Browser_clients _
        | Inventory.Machine_state _ -> None) snapshot.rows in
  let from_addons =
    let view = Option.value ~default:state.lane_addons_cached state.lane_addons in
    match view.snapshot with
    | None -> []
    | Some snapshot -> List.filter_map (fun (instance : Addons.instance) ->
        match instance.installation_id, instance.runtime_presence with
        | Some id, Addons.Live_entry -> Some (id, instance.title)
        | Some _, (Addons.Retained_binding | Addons.Presence_unknown)
        | None, (Addons.Live_entry | Addons.Retained_binding | Addons.Presence_unknown) -> None)
        snapshot.instances in
  List.fold_left (fun targets (id, title) ->
    if List.mem_assoc id targets then targets else targets @ [ (id, title) ])
    [] (from_asks @ from_inventory @ from_addons)

let main_entries =
  List.map (fun (surface, label) -> "go " ^ label, Palette_goto surface) surface_ring

let palette_entries (state : state) =
  main_entries
  @ [ "go Work / Task Review", Palette_goto Verification
    ; "go Work / Task Verdicts", Palette_goto Harness
    ; "go Work / Requests", Palette_goto Approvals
    ; "go Keepers / Memory", Palette_goto Memory
    ; "go Keepers / Schedules", Palette_goto Schedules
    ; "go Keepers / Fusion", Palette_goto Fusion
    ; "go Keepers / Changes", Palette_goto Changes
    ; "go Keepers / Channels", Palette_connectors
    ; "go Workspace / Code", Palette_goto Code
    ; "go System / Runtime", Palette_goto Runtime
    ; "go System / Features", Palette_goto Lanes
    ; "go System / Clients", Palette_goto Clients
    ; "go System / Resources", Palette_goto Resources
    ; "go System / Tools & Skills", Palette_goto Tools
    ; "go System / Activity", Palette_goto Acting
    ; "go System / Logs", Palette_goto System_logs
    ; "go System / Browser", Palette_browser_lane
    ; "go System / Plugins", Palette_lane_addons
    ]
  @ List.map
      (fun (pane, label) -> ("go System / " ^ label, Palette_config pane))
      config_panes
  @ List.map (fun lane ->
      ("go System / Features / " ^ Lane_run_identity.label lane ^ " history", Palette_lane_history lane))
      Lane_run_identity.all
  @ [ "go Play / Links", Palette_collab
    ; "go Play / MSX", Palette_msx
    ; "go Play / DOS", Palette_dos
    ]
  @ List.map (fun (id, title) -> ("go System / Plugins / " ^ title ^ " Results", Palette_addon_results id))
      (addon_result_targets state)
  @ (match browser_lane_on_screen state with
      | None -> []
      | Some _ -> [ "hide Browser Lane", Palette_hide_browser_lane ])
  @ List.concat_map (fun lane ->
      List.map (fun mode ->
        ("gate " ^ gate_lane_label lane ^ " / " ^ gate_mode_label mode,
         Palette_gate_mode (lane, mode)))
        [Masc.Keeper_gate_mode.Manual; Masc.Keeper_gate_mode.Auto_judge; Masc.Keeper_gate_mode.Always_allow])
      [Workspace_gate; External_gate]
  @ [ "language: 한국어", Palette_ui_language Lang_ko
    ; "language: English", Palette_ui_language Lang_en
    ]
  @ ["usage account / all accounts", Palette_usage_scope None]
  @ List.map (fun scope_id ->
      let accounts = match state.overview_providers with
        | Providers_unread | Providers_failed _ -> []
        | Providers_read reading -> reading.puws_accounts in
      let account = List.find_opt (fun account ->
        String.equal account.Masc.Tui_decode_usage.pua_scope_id scope_id) accounts in
      let label = Option.fold ~none:("scope " ^ scope_id)
          ~some:(fun account ->
            Masc_tui_overview_providers.scope_name account
            ^ Option.fold ~none:"" ~some:(fun email -> " · " ^ email)
                (Masc_tui_overview_providers.account_email
                   ~account_emails:state.overview_account_emails account)) account in
      "usage account / " ^ label, Palette_usage_scope (Some scope_id))
      (usage_scope_ids state)
  @ List.map
      (fun (keeper : keeper) ->
        ("keeper " ^ keeper.k_name, Palette_chat keeper.k_name))
      state.keepers
  @ List.map
      (fun (t : task) -> ("task " ^ t.id ^ " " ^ t.title, Palette_task t.id))
      state.tasks
  @ (match state.msg_target_keeper_name with
      | None -> []
      | Some keeper ->
          List.map (fun original ->
            let intent = Masc_tui_task_dispatch.intent original.tdr_dispatch in
            "inspect Task creation / " ^ keeper ^ " / " ^ intent.title,
            Palette_task_creation original)
            (task_creation_inspectable state ~keeper))
  @ [ "hearth all", Palette_board_hearth None ]
  @ (let retained=match Masc_tui_types.board_census_reading state with
       | Masc_tui_fetched.Ready _,false -> false
       | (Absent | Loading | Ready _ | Stale _ | Failed _),_ -> true in
     List.map (fun (name, count) ->
       (Printf.sprintf "hearth %s (%s%s)" name (Masc_tui_message_layout.count_noun count "post")
          (if retained then "; last observed" else ""), Palette_board_hearth (Some name)))
       (Masc_tui_types.board_census_values state))
  @ (let retained=match board_posts_reading state with
       | Masc_tui_fetched.Ready _,false -> not (board_listing_matches_requested state)
       | (Absent | Loading | Ready _ | Stale _ | Failed _),_ -> true in
     let suffix=if retained then
       " (last observed: " ^ board_query_label (board_posts_query state) ^ ")" else "" in
     List.map
      (fun (p : board_post) ->
        ("post " ^ p.bp_title ^ suffix, Palette_board_post p.bp_id))
      (board_posts state))
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

(* Search names belong to their typed destination, independently of its path. *)
let palette_action_words action =
  let words = match action with
  | Palette_goto surface ->
      let aliases = match surface with
        | Resources -> [ "artifacts"; "reports"; "resources"; "리소스"; "산출물" ]
        | Metrics -> [ "metrics"; "telemetry"; "charts"; "stats"; "사용량"; "비용" ]
        | Overview -> [ "대시보드"; "홈" ]
        | Planning -> [ "goals"; "candle"; "작업"; "목표" ]
        | Keepers _ -> [ "키퍼"; "에이전트" ]
        | Board -> [ "보드"; "게시판" ]
        | Repositories -> [ "워크스페이스"; "저장소" ]
        | Config -> [ "시스템"; "설정"; "환경설정" ]
        | Approvals -> [ "approvals"; "requests"; "승인"; "질문" ]
        | Verification -> [ "task review"; "작업리뷰"; "검증" ]
        | Harness -> [ "task verdicts"; "작업판정"; "판정" ]
        | Memory -> [ "memory"; "메모리"; "기억" ]
        | Lanes -> [ "features"; "lanes"; "기능"; "레인" ]
        | Clients -> [ "clients"; "클라이언트" ]
        | Schedules -> [ "schedules"; "스케줄"; "일정" ]
        | Fusion -> [ "fusion"; "퓨전" ]
        | Code -> [ "code"; "코드" ]
        | Changes -> [ "changes"; "변경사항" ]
        | Connectors -> [ "connectors"; "channels"; "커넥터"; "채널" ]
        | Runtime -> [ "runtime"; "런타임" ]
        | Tools -> [ "tools"; "skills"; "도구"; "스킬" ]
        | Acting -> [ "activity"; "활동"; "이벤트" ]
        | System_logs -> [ "logs"; "로그"; "시스템로그" ] in
      Option.to_list (List.assoc_opt surface surface_ring) @ aliases
  | Palette_config pane ->
      (match pane with
       | Config_runtime -> [ "설정파일"; "런타임설정" ]
       | Config_models -> [ "모델"; "모델바인딩" ]
       | Config_params -> [ "settings"; "params"; "파라미터"; "런타임파라미터" ]
       | Config_prompts -> [ "프롬프트" ]
       | Config_presets -> [ "프리셋" ]
       | Config_themes -> [ "테마"; "언어" ]
       | Config_voice -> [ "음성"; "보이스" ])
  | Palette_ui_language Lang_ko -> [ "한글"; "한국어"; "언어"; "한영" ]
  | Palette_ui_language Lang_en -> [ "영문"; "영어"; "언어"; "한영" ]
  | Palette_usage_scope (Some scope_id) -> [scope_id]
  | Palette_addon_results id -> [id]
  | Palette_task_creation _ -> ["task-inspect"; "original Task"]
  | Palette_lane_history lane -> [Lane_run_identity.to_id lane]
  | Palette_browser_lane -> [ "browser"; "browser lane"; "브라우저" ]
  | Palette_connectors -> [ "connectors"; "channels"; "커넥터"; "채널" ]
  | Palette_collab -> [ "collab"; "play"; "play links"; "초대" ]
  | Palette_msx -> [ "msx" ]
  | Palette_dos -> [ "dos" ]
  | Palette_lane_addons -> [ "plugins"; "add-ons"; "플러그인" ]
  | Palette_hide_browser_lane | Palette_usage_scope None | Palette_gate_mode _
  | Palette_chat _ | Palette_task _ | Palette_board_hearth _
  | Palette_board_post _ | Palette_lsp _ | Palette_code_file _ ->
      []
  | Palette_code_location (_, location) -> [location.Masc.Tui_decode.ll_path]
  | Palette_code_branch branch -> [branch.Masc.Tui_decode.gb_name; branch.gb_subject]
  | Palette_code_worktree worktree -> [worktree.Masc.Tui_decode.gw_name]
  | Palette_code_search_match found -> [found.Masc.Tui_decode.wsm_path]
  in
  words @ List.map (fun word -> "go " ^ word) words

(* One branch row: the checked-out mark, the name, how it stands against its
   upstream, the tip's UTC date and its subject. The date comes from the tip
   itself, so a row reads the same whenever it is drawn. *)
let branch_label (branch : Masc.Tui_decode.git_branch) =
  let open Masc.Tui_decode in
  let upstream =
    match branch.gb_upstream with
    | Repository_no_upstream -> "no upstream"
    | Repository_upstream_gone upstream -> upstream ^ " (gone)"
    | Repository_tracking { upstream; ahead; behind } ->
        String.concat " "
          (upstream
           :: (if ahead > 0 then [ Printf.sprintf "↑%d" ahead ] else [])
           @ (if behind > 0 then [ Printf.sprintf "↓%d" behind ] else []))
  in
  let date =
    let tm = Unix.gmtime (float_of_int branch.gb_commit_epoch) in
    Printf.sprintf "%04d-%02d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
      tm.Unix.tm_mday
  in
  Printf.sprintf "%s %s  %s  %s  %s"
    (if branch.gb_current then "*" else " ")
    branch.gb_name upstream date branch.gb_subject

(* One worktree row: the main mark, the directory name, what is checked out and
   the flags git reports. The path is not here: the server sends only the last
   name. *)
let worktree_label (worktree : Masc.Tui_decode.git_worktree) =
  let open Masc.Tui_decode in
  let checkout =
    match worktree.gw_state with
    | Git_worktree_branch name -> name
    | Git_worktree_detached ->
        (match worktree.gw_head with
         | Some head -> "detached " ^ String.sub head 0 (min 8 (String.length head))
         | None -> "detached")
    | Git_worktree_bare -> "bare"
  in
  let flags =
    (if worktree.gw_locked then [ "locked" ] else [])
    @ (if worktree.gw_prunable then [ "prunable" ] else [])
  in
  Printf.sprintf "%s %s  %s%s"
    (if worktree.gw_main then "*" else " ")
    worktree.gw_name checkout
    (match flags with [] -> "" | flags -> "  " ^ String.concat " " flags)

(* One Ctrl-G answer row: where the match is and what the line says. The
   line starts at its first character that is not a space. The file shows
   the indentation once the match is opened; in the row it only spends
   cells the text needs, because the frame cuts the row at its right edge.
   Tabs are expanded first, so a tab-indented line is trimmed the same as a
   space-indented one. *)
let search_match_label (found : Masc.Tui_decode.workspace_search_match) =
  let expanded, _ =
    Masc_tui_message_layout.expand_tabs ~column:0 found.wsm_text
  in
  let length = String.length expanded in
  let rec first_visible index =
    if index < length && Char.equal expanded.[index] ' ' then
      first_visible (index + 1)
    else index
  in
  let start = first_visible 0 in
  Printf.sprintf "%s:%d  %s" found.wsm_path found.wsm_line
    (String.sub expanded start (length - start))

(* How an entry answers the query. [answer_order] is the ranking; it is
   written out so that adding an answer is a compile error here and not a
   position that depends on where the constructor was typed. *)
type answer =
  | Whole_query
  | Starts_with_query
  | Contains_query
  | Characters_in_order

let answer_order = function
  | Whole_query -> 0
  | Starts_with_query -> 1
  | Contains_query -> 2
  | Characters_in_order -> 3

let palette_matches (state : state) =
  let needle = String.trim state.palette_query in
  let entries =
    match state.palette_mode with
    | Palette_jump when String.equal needle "" -> main_entries
    | Palette_jump ->
        let entries = palette_entries state in
        (match palette_typed_question state.palette_query with
         | None -> entries
         | Some (question, None) ->
             List.filter (function
               | _, Palette_lsp (candidate_question, _) ->
                   String.equal question candidate_question
               | ( _
                 , ( Palette_browser_lane | Palette_hide_browser_lane
                   | Palette_connectors | Palette_collab | Palette_msx
                   | Palette_dos | Palette_lane_addons | Palette_lane_history _ | Palette_addon_results _ | Palette_goto _
                   | Palette_usage_scope _ | Palette_config _ | Palette_ui_language _ | Palette_gate_mode _ | Palette_chat _
                   | Palette_task _ | Palette_task_creation _ | Palette_board_hearth _
                   | Palette_board_post _ | Palette_code_file _
                   | Palette_code_location _ | Palette_code_branch _
                   | Palette_code_worktree _ | Palette_code_search_match _ ) ) -> false) entries
         | Some (_, Some _) -> [])
    | Palette_choice { choice_question; _ } ->
        List.map
          (fun name -> (name, Palette_lsp (choice_question, name)))
          (code_cursor_line_symbols state)
    | Palette_files _ ->
        (match code_finder_catalog state with
         | Masc_tui_fetched.Ready catalog ->
             List.map (fun path -> path, Palette_code_file path) catalog.Tui_decode.wfc_files
         | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
         | Masc_tui_fetched.Stale _ | Masc_tui_fetched.Failed _ -> [])
    | Palette_branches _ ->
        (match code_branches_view state with
         | Masc_tui_fetched.Ready listing | Masc_tui_fetched.Stale (listing, _) ->
             List.map (fun branch -> branch_label branch, Palette_code_branch branch)
               listing.Tui_decode.gbs_branches
         | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
         | Masc_tui_fetched.Failed _ -> [])
    | Palette_worktrees _ ->
        (match code_worktrees_view state with
         | Masc_tui_fetched.Ready listing | Masc_tui_fetched.Stale (listing, _) ->
             List.map (fun worktree -> worktree_label worktree, Palette_code_worktree worktree)
               listing.Tui_decode.gws_worktrees
         | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
         | Masc_tui_fetched.Failed _ -> [])
    | Palette_search _ ->
        (* The typed text is the search, not a filter over its answer: the
           server already matched every row, so none is ranked away below. *)
        (match code_search_current state with
         | Some (_, (Masc_tui_fetched.Ready search | Masc_tui_fetched.Stale (search, _))) ->
             List.map (fun (found : Masc.Tui_decode.workspace_search_match) ->
               search_match_label found, Palette_code_search_match found)
               search.Masc.Tui_decode.wss_matches
         | Some (_, (Masc_tui_fetched.Absent | Masc_tui_fetched.Loading
                    | Masc_tui_fetched.Failed _))
         | None -> [])
    | Palette_locations offer ->
        if not (code_location_offer_current state offer) then []
        else List.map (fun location ->
          let open Masc.Tui_decode in
          Printf.sprintf "%s:%d%s" location.ll_path location.ll_line
            (if location.ll_inside then "" else " (outside workspace)"),
          Palette_code_location (offer, location)) offer.clo_locations
  in
  (* Four ranks, entry order kept inside each: a label or word that is the
     whole query, then a label that starts with it, then one that contains it,
     then one that only has its characters in order. The whole-query rank is
     why "go Board" lands on Board and not on "go Board Attention history",
     which starts with the same text and was listed first. Typed Code
     questions retain only executable symbol candidates; ordinary jump filters
     continue ranking destinations and content. *)
  let rank (label, action) =
    let texts = label :: palette_action_words action in
    if List.exists (palette_equals ~needle) texts then Some Whole_query
    else if List.exists (palette_starts_with ~needle) texts then Some Starts_with_query
    else if List.exists (palette_contains ~needle) texts then Some Contains_query
    else if List.exists (palette_subsequence ~needle) texts then Some Characters_in_order
    else None
  in
  match state.palette_mode with
  | Palette_search _ -> entries
  | Palette_jump | Palette_choice _ | Palette_files _ | Palette_locations _ | Palette_branches _ | Palette_worktrees _ ->
      entries
      |> List.filter_map (fun entry ->
             Option.map (fun r -> (r, entry)) (rank entry))
      |> List.stable_sort (fun (a, _) (b, _) -> Int.compare (answer_order a) (answer_order b))
      |> List.map snd

let selected_file state =
  let matches = palette_matches state in
  let cursor = max 0 (min state.palette_cursor (List.length matches - 1)) in
  match List.nth_opt matches cursor with
  | Some (_, Palette_code_file path) -> Some path
  | Some (_, (Palette_browser_lane | Palette_hide_browser_lane | Palette_connectors
    | Palette_collab | Palette_msx | Palette_dos | Palette_lane_addons | Palette_lane_history _ | Palette_addon_results _
    | Palette_goto _
    | Palette_usage_scope _ | Palette_config _ | Palette_ui_language _ | Palette_gate_mode _ | Palette_chat _
    | Palette_task _ | Palette_task_creation _ | Palette_board_hearth _ | Palette_board_post _ | Palette_lsp _
    | Palette_code_location _ | Palette_code_branch _ | Palette_code_worktree _ | Palette_code_search_match _))
  | None -> None

let selected_location state =
  let matches = palette_matches state in
  let cursor = max 0 (min state.palette_cursor (List.length matches - 1)) in
  match List.nth_opt matches cursor with
  | Some (_, Palette_code_location (offer, location)) -> Some (offer, location)
  | Some (_, (Palette_browser_lane | Palette_hide_browser_lane | Palette_connectors
    | Palette_collab | Palette_msx | Palette_dos | Palette_lane_addons | Palette_lane_history _ | Palette_addon_results _
    | Palette_goto _
    | Palette_usage_scope _ | Palette_config _ | Palette_ui_language _ | Palette_gate_mode _ | Palette_chat _
    | Palette_task _ | Palette_task_creation _ | Palette_board_hearth _ | Palette_board_post _ | Palette_lsp _
    | Palette_code_file _ | Palette_code_branch _ | Palette_code_worktree _ | Palette_code_search_match _))
  | None -> None

let selected_search_match state =
  let matches = palette_matches state in
  let cursor = max 0 (min state.palette_cursor (List.length matches - 1)) in
  match List.nth_opt matches cursor with
  | Some (_, Palette_code_search_match found) -> Some found
  | Some (_, (Palette_browser_lane | Palette_hide_browser_lane | Palette_connectors
    | Palette_collab | Palette_msx | Palette_dos | Palette_lane_addons | Palette_lane_history _ | Palette_addon_results _
    | Palette_goto _
    | Palette_usage_scope _ | Palette_config _ | Palette_ui_language _ | Palette_gate_mode _ | Palette_chat _
    | Palette_task _ | Palette_task_creation _ | Palette_board_hearth _ | Palette_board_post _ | Palette_lsp _
    | Palette_code_file _ | Palette_code_location _ | Palette_code_branch _
    | Palette_code_worktree _))
  | None -> None

type search_enter =
  | Enter_opens of Masc.Tui_decode.workspace_search_match
  | Enter_searches

let search_enter state =
  if not (code_search_answer_is_for_prompt state) then Enter_searches
  else
    match selected_search_match state with
    | Some found -> Enter_opens found
    | None -> Enter_searches

let command_enter_has_nothing state =
  match state.palette_mode with
  | Palette_jump ->
      Option.is_none (palette_typed_question state.palette_query)
      && (match palette_matches state with [] -> true | _ :: _ -> false)
  | Palette_choice _ | Palette_files _ | Palette_locations _ | Palette_branches _
  | Palette_worktrees _ | Palette_search _ -> false
