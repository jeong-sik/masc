open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

module String_set = Set.Make (String)
module String_map = Map.Make (String)

type memory_diff_window =
  | Window_24h
  | Window_7d
  | Window_30d
  | Window_revs of { from_rev : int; to_rev : int }

let compare_memory_diff_window a b =
  match a, b with
  | Window_24h, Window_24h | Window_7d, Window_7d | Window_30d, Window_30d -> 0
  | Window_revs x, Window_revs y -> (
      match Int.compare x.from_rev y.from_rev with
      | 0 -> Int.compare x.to_rev y.to_rev
      | c -> c)
  | Window_24h, (Window_7d | Window_30d | Window_revs _)
  | Window_7d, (Window_30d | Window_revs _)
  | Window_30d, Window_revs _ ->
      -1
  | Window_7d, Window_24h
  | Window_30d, (Window_24h | Window_7d)
  | Window_revs _, (Window_24h | Window_7d | Window_30d) ->
      1

module Memory_diff_map = Map.Make (struct
  type t = string option * memory_diff_window

  let compare (keeper_a, window_a) (keeper_b, window_b) =
    match Option.compare String.compare keeper_a keeper_b with
    | 0 -> compare_memory_diff_window window_a window_b
    | c -> c
end)

type memory_view_mode =
  | View_evolution
  | View_facts
  | View_diff

type memory_facts_sort =
  | Sort_recency
  | Sort_retrieved

type memory_left_row =
  | Left_conflict of Wire_knowledge.memory_conflict
  | Left_world_scope
  | Left_writer of Wire_knowledge.librarian_writer_row

type memory_fact_row =
  | Fact_ordinary of {
      revision : int;
      fact : Wire_knowledge.keeper_ordinary_fact;
    }
  | Fact_source of Wire_knowledge.keeper_source_fact
  | Fact_source_invalidation of Wire_knowledge.keeper_source_invalidation

type memory_diff_item =
  | Keeper_added of Wire_knowledge.memory_fact_entry
  | Keeper_updated of Wire_knowledge.memory_updated_fact
  | Keeper_retracted of Wire_knowledge.memory_retracted_fact
  | Keeper_invalidated of Wire_knowledge.memory_invalidated_fact
  | World_added of Wire_knowledge.world_change_entry
  | World_updated of Wire_knowledge.world_updated_entry
  | World_retracted of Wire_knowledge.world_change_entry

type memory_reading_entry =
  | Reading_activity of {
      keeper : string;
      event : Wire_knowledge.memory_activity_event;
      notes : string list;
    }
  | Reading_ordinary_fact of {
      keeper : string;
      revision : int;
      fact : Wire_knowledge.keeper_ordinary_fact;
    }
  | Reading_source_fact of {
      keeper : string;
      fact : Wire_knowledge.keeper_source_fact;
    }
  | Reading_source_invalidation of {
      keeper : string;
      invalidation : Wire_knowledge.keeper_source_invalidation;
    }
  | Reading_diff_item of {
      keeper : string option;
      item : memory_diff_item;
    }

type memory_diagram_kind =
  | Diagram_pele_card
  | Diagram_formation_tree

type memory_diagram_mode =
  | Diagram_mode_auto
  | Diagram_mode_mermaid
  | Diagram_mode_tree

type memory_diagram_payload =
  | Diagram_pele_png of {
      png : string;
      pixel_size : (int * int) option;
      format_label : string;
      fallback_lines : string list;
    }
  | Diagram_text of {
      lines : string list;
      note : string option;
    }

type memory_diagram_source =
  | Diagram_source_event of string
  | Diagram_source_fact_snapshot of string

type memory_diagram_state = {
  request_id : int;
  keeper : string;
  event_identity : string;
  source : memory_diagram_source;
  revision : int;
  kind : memory_diagram_kind;
  mode : memory_diagram_mode;
  payload : memory_diagram_payload Observed.t;
  scroll : int;
  copy_source : string;
}

type wiki_edit_base = {
  slug : string;
  revision : int;
  sha256 : string;
  source : Wire_knowledge.wiki_source;
  tags : string list;
}

type vote_target =
  | Vote_post of string
  | Vote_comment of { post_id : string; comment_id : string }

type threaded_comment = {
  comment : Wire_knowledge.board_comment;
  depth : int;
  is_reply : bool;
}

type thread_view = Thread_post | Thread_comments

type memory_subview =
  | Mem_diff_flow
  | Mem_health_ledger
  | Mem_context

type keeper_memory_subview =
  | Kmem_diff_flow
  | Kmem_health
  | Kmem_facts_tree
  | Kmem_journal

type t = {
  active_tab : Nav.knowledge_tab;
  board_recovery : Board_recovery.t;
  board : Wire_knowledge.board_feed Observed.t;
  board_hearths : Wire_knowledge.board_hearth_entry list Observed.t;
  board_signal_only : bool;
  board_sort_by : string;
  board_hearth : string option;
  expanded_succession_chains : String_set.t;
  active_thread :
    (Wire_knowledge.board_post * Wire_knowledge.board_comment list) Observed.t;
  active_thread_target : string option;
  thread_view : thread_view;
  thread_selected_comment : string option;
  thread_comment_scroll : int;
  armed_vote : (vote_target * [ `Up | `Down ]) option;
  wiki_index : Wire_knowledge.wiki_index Observed.t;
  wiki_pages : Wire_knowledge.wiki_page_detail Observed.t String_map.t;
  wiki_log : Wire_knowledge.wiki_log_response Observed.t;
  wiki_search : Wire_knowledge.wiki_search_response Observed.t;
  wiki_lint : Wire_knowledge.wiki_lint_report Observed.t;
  wiki_edit_base : wiki_edit_base option;
  pending_wiki_edit_slug : string option;
  artifacts : Wire_knowledge.artifact_entry list Observed.t;
  active_artifact_detail : Wire_knowledge.published_artifact_detail Observed.t;
  active_artifact_detail_target : string option;
  pending_artifact_revision : (string * int option) option;
  artifact_view_mode : [ `Document | `Raw_source ];
  artifact_checks : Wire_knowledge.artifact_check list Observed.t;
  artifact_search_query : string;
  artifact_search_match_idx : int;
  world_memory : Wire_knowledge.world_memory Observed.t;
  memory_diffs : Wire_knowledge.memory_diff Observed.t Memory_diff_map.t;
  memory_os_internals :
    Wire_knowledge.memory_os_internals Observed.t String_map.t;
  keeper_memory_facts :
    Wire_knowledge.keeper_memory_facts Observed.t String_map.t;
  keeper_memory_activity :
    Wire_knowledge.keeper_memory_activity Observed.t String_map.t;
  keeper_memory_health : Wire_knowledge.keeper_memory_health_fleet Observed.t;
  memory_subview : memory_subview;
  keeper_memory_subview : keeper_memory_subview;
  memory_health_keeper :
    (string * Wire_knowledge.keeper_memory_health_row option) Observed.t;
  workspace_memory_ledger : Wire_knowledge.workspace_memory_ledger Observed.t;
  workspace_memory_ledger_auth_denied : bool;
  workspace_memory_context : Wire_knowledge.workspace_memory_context Observed.t;
  workspace_memory_context_auth_denied : bool;
  keeper_memory_facts_auth_denied : String_set.t;
  collapsed_fact_categories : String_set.t;
  facts_selected_index : int;
  keeper_memory_journal :
    (string * Wire_knowledge.keeper_memory_journal) Observed.t;
  keeper_memory_journal_auth_denied : String_set.t;
  memory_subview_scroll : int;
  memory_diff_window : memory_diff_window;
  memory_diff_keeper : string option;
  memory_view_mode : memory_view_mode;
  memory_facts_sort : memory_facts_sort;
  selected_fact_index : int;
  facts_scroll_offset : int;
  selected_activity_index : int;
  activity_scroll_offset : int;
  selected_diff_index : int;
  memory_reading : memory_reading_entry option;
  memory_reading_scroll : int;
  memory_diagram : memory_diagram_state option;
  memory_diagram_seq : int;
  memory_flow_mode : Masc_tui_ui.Memory_flow.chart_mode;
  last_memory_act_answer : (string * Wire_knowledge.memory_act_answer) option;
  selected_index : int;
  scroll_offset : int;
  diff_scroll_offset : int;
  detail_scroll_offset : int;
  pulse_thread_index : int;
  filter_query : string;
}

let empty =
  {
    active_tab = Nav.Knowledge_board;
    board_recovery = Board_recovery.empty;
    board = Observed.unreported;
    board_hearths = Observed.unreported;
    board_signal_only = true;
    board_sort_by = "recent";
    board_hearth = None;
    expanded_succession_chains = String_set.empty;
    active_thread = Observed.absent;
    active_thread_target = None;
    thread_view = Thread_post;
    thread_selected_comment = None;
    thread_comment_scroll = 0;
    armed_vote = None;
    wiki_index = Observed.unreported;
    wiki_pages = String_map.empty;
    wiki_log = Observed.unreported;
    wiki_search = Observed.absent;
    wiki_lint = Observed.unreported;
    wiki_edit_base = None;
    pending_wiki_edit_slug = None;
    artifacts = Observed.unreported;
    active_artifact_detail = Observed.absent;
    active_artifact_detail_target = None;
    pending_artifact_revision = None;
    artifact_view_mode = `Document;
    artifact_checks = Observed.unreported;
    artifact_search_query = "";
    artifact_search_match_idx = 0;
    world_memory = Observed.unreported;
    memory_diffs = Memory_diff_map.empty;
    memory_os_internals = String_map.empty;
    keeper_memory_facts = String_map.empty;
    keeper_memory_activity = String_map.empty;
    keeper_memory_health = Observed.unreported;
    memory_subview = Mem_diff_flow;
    keeper_memory_subview = Kmem_diff_flow;
    memory_health_keeper = Observed.unreported;
    workspace_memory_ledger = Observed.unreported;
    workspace_memory_ledger_auth_denied = false;
    workspace_memory_context = Observed.unreported;
    workspace_memory_context_auth_denied = false;
    keeper_memory_facts_auth_denied = String_set.empty;
    collapsed_fact_categories = String_set.empty;
    facts_selected_index = 0;
    keeper_memory_journal = Observed.unreported;
    keeper_memory_journal_auth_denied = String_set.empty;
    memory_subview_scroll = 0;
    memory_diff_window = Window_24h;
    memory_diff_keeper = None;
    memory_view_mode = View_evolution;
    memory_facts_sort = Sort_recency;
    selected_fact_index = 0;
    facts_scroll_offset = 0;
    selected_activity_index = 0;
    activity_scroll_offset = 0;
    selected_diff_index = 0;
    memory_reading = None;
    memory_reading_scroll = 0;
    memory_diagram = None;
    memory_diagram_seq = 0;
    memory_flow_mode = Masc_tui_ui.Memory_flow.Flow_io;
    last_memory_act_answer = None;
    selected_index = 0;
    scroll_offset = 0;
    diff_scroll_offset = 0;
    detail_scroll_offset = 0;
    pulse_thread_index = 0;
    filter_query = "";
  }

let wiki_page_for ~slug t =
  match String_map.find_opt slug t.wiki_pages with
  | Some obs -> obs
  | None -> Observed.unreported

let set_wiki_page ~slug obs t =
  { t with wiki_pages = String_map.add slug obs t.wiki_pages }

let memory_diff_for ~keeper ~window t =
  match Memory_diff_map.find_opt (keeper, window) t.memory_diffs with
  | Some obs -> obs
  | None -> Observed.unreported

let set_memory_diff ~keeper ~window obs t =
  {
    t with
    memory_diffs = Memory_diff_map.add (keeper, window) obs t.memory_diffs;
  }

let current_memory_diff t =
  memory_diff_for ~keeper:t.memory_diff_keeper ~window:t.memory_diff_window t

let memory_os_internals_for ~keeper t =
  match String_map.find_opt keeper t.memory_os_internals with
  | Some obs -> obs
  | None -> Observed.unreported

let set_memory_os_internals ~keeper obs t =
  {
    t with
    memory_os_internals = String_map.add keeper obs t.memory_os_internals;
  }

let keeper_memory_facts_for ~keeper t =
  match String_map.find_opt keeper t.keeper_memory_facts with
  | Some obs -> obs
  | None -> Observed.unreported

let set_keeper_memory_facts ~keeper obs t =
  let keeper_memory_facts_auth_denied =
    match obs with
    | Observed.Value _ ->
        String_set.remove keeper t.keeper_memory_facts_auth_denied
    | Observed.Loading _ | Observed.Absent | Observed.Unreported
    | Observed.Failed _ ->
        t.keeper_memory_facts_auth_denied
  in
  {
    t with
    keeper_memory_facts = String_map.add keeper obs t.keeper_memory_facts;
    keeper_memory_facts_auth_denied;
  }

let keeper_memory_activity_for ~keeper t =
  match String_map.find_opt keeper t.keeper_memory_activity with
  | Some obs -> obs
  | None -> Observed.unreported

let set_keeper_memory_activity ~keeper obs t =
  {
    t with
    keeper_memory_activity = String_map.add keeper obs t.keeper_memory_activity;
  }

let equal_vote_target a b =
  match a, b with
  | Vote_post x, Vote_post y -> String.equal x y
  | Vote_comment x, Vote_comment y ->
      String.equal x.post_id y.post_id && String.equal x.comment_id y.comment_id
  | Vote_post _, Vote_comment _ | Vote_comment _, Vote_post _ -> false
let memory_diff_window_query = function
  | Window_24h -> Some "24h"
  | Window_7d -> Some "7d"
  | Window_30d -> Some "30d"
  | Window_revs _ -> None

let equal_memory_diff_window a b =
  match a, b with
  | Window_24h, Window_24h | Window_7d, Window_7d | Window_30d, Window_30d ->
      true
  | Window_revs x, Window_revs y ->
      Int.equal x.from_rev y.from_rev && Int.equal x.to_rev y.to_rev
  | Window_24h, (Window_7d | Window_30d | Window_revs _)
  | Window_7d, (Window_24h | Window_30d | Window_revs _)
  | Window_30d, (Window_24h | Window_7d | Window_revs _)
  | Window_revs _, (Window_24h | Window_7d | Window_30d) ->
      false

let memory_view_mode_rank = function
  | View_evolution -> 0
  | View_facts -> 1
  | View_diff -> 2

let equal_memory_view_mode a b =
  Int.equal (memory_view_mode_rank a) (memory_view_mode_rank b)

let memory_facts_sort_rank = function
  | Sort_recency -> 0
  | Sort_retrieved -> 1

let equal_memory_facts_sort a b =
  Int.equal (memory_facts_sort_rank a) (memory_facts_sort_rank b)

let memory_diagram_kind_rank = function
  | Diagram_pele_card -> 0
  | Diagram_formation_tree -> 1

let equal_memory_diagram_kind a b =
  Int.equal (memory_diagram_kind_rank a) (memory_diagram_kind_rank b)

let memory_diagram_mode_rank = function
  | Diagram_mode_auto -> 0
  | Diagram_mode_mermaid -> 1
  | Diagram_mode_tree -> 2

let equal_memory_diagram_mode a b =
  Int.equal (memory_diagram_mode_rank a) (memory_diagram_mode_rank b)

let next_memory_diagram_mode = function
  | Diagram_mode_auto -> Diagram_mode_mermaid
  | Diagram_mode_mermaid -> Diagram_mode_tree
  | Diagram_mode_tree -> Diagram_mode_auto

let contains_ci = Store_scroll.contains_ci
let adjust_grouped_scroll = Store_scroll.adjust_grouped_scroll
let clamp_index = Store_scroll.clamp_index

type succession_group = {
  chain_root_id : string option;
  lead : Wire_knowledge.board_post;
  members : Wire_knowledge.board_post list;
  chain_count : int;
  unique_keepers : int;
}

let unique_strings xs =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun s ->
      if Hashtbl.mem seen s then false
      else begin
        Hashtbl.add seen s ();
        true
      end)
    xs

let group_succession_chains (posts : Wire_knowledge.board_post list) :
    succession_group list =
  let order = ref [] in
  let tbl : (string, Wire_knowledge.board_post list) Hashtbl.t =
    Hashtbl.create 32
  in
  List.iter
    (fun (p : Wire_knowledge.board_post) ->
      let key =
        match p.succession_chain_root_id with
        | Some root when not (String.equal (String.trim root) "") ->
            "chain:" ^ root
        | Some _ | None -> "post:" ^ p.id
      in
      match Hashtbl.find_opt tbl key with
      | None ->
          order := key :: !order;
          Hashtbl.add tbl key [ p ]
      | Some prev -> Hashtbl.replace tbl key (prev @ [ p ]))
    posts;
  List.rev !order
  |> List.filter_map (fun key ->
         match Hashtbl.find_opt tbl key with
         | None | Some [] -> None
         | Some (first :: _ as members) ->
             let lead =
               List.fold_left
                 (fun (best : Wire_knowledge.board_post)
                      (cur : Wire_knowledge.board_post) ->
                   let best_d =
                     match best.chain_depth with Some d -> d | None -> 0
                   in
                   let cur_d =
                     match cur.chain_depth with Some d -> d | None -> 0
                   in
                   if cur_d > best_d then cur
                   else if
                     Int.equal cur_d best_d
                     && cur.created_at_unix > best.created_at_unix
                   then cur
                   else best)
                 first members
             in
             let declared_depth =
               List.fold_left
                 (fun acc (p : Wire_knowledge.board_post) ->
                   match p.chain_depth with Some d -> Int.max acc d | None -> acc)
                 1 members
             in
             let chain_count = Int.max (List.length members) declared_depth in
             let unique_keepers =
               members
               |> List.map (fun (p : Wire_knowledge.board_post) -> p.author)
               |> unique_strings |> List.length
             in
             Some
               {
                 chain_root_id = lead.succession_chain_root_id;
                 lead;
                 members;
                 chain_count;
                 unique_keepers;
               })

let cluster_wiki_pages (pages : Wire_knowledge.wiki_page_summary list) :
    (string option * Wire_knowledge.wiki_page_summary list) list =
  let order = ref [] in
  let tbl : (string option, Wire_knowledge.wiki_page_summary list) Hashtbl.t =
    Hashtbl.create 16
  in
  List.iter
    (fun (p : Wire_knowledge.wiki_page_summary) ->
      let topic =
        match p.tags with
        | tag :: _ when not (String.equal (String.trim tag) "") ->
            Some (String.trim tag)
        | _ -> None
      in
      match Hashtbl.find_opt tbl topic with
      | None ->
          order := topic :: !order;
          Hashtbl.add tbl topic [ p ]
      | Some prev -> Hashtbl.replace tbl topic (prev @ [ p ]))
    pages;
  List.rev !order
  |> List.filter_map (fun topic ->
         match Hashtbl.find_opt tbl topic with
         | Some xs -> Some (topic, xs)
         | None -> None)

let is_succession_chain_expanded ~root_id t =
  String_set.mem root_id t.expanded_succession_chains

let filtered_posts t =
  let posts =
    match Observed.to_option t.board with Some f -> f.posts | None -> []
  in
  let signal_filtered =
    if t.board_signal_only then
      List.filter (fun (p : Wire_knowledge.board_post) -> p.is_signal) posts
    else posts
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then signal_filtered
  else
    List.filter
      (fun (p : Wire_knowledge.board_post) ->
        contains_ci ~needle:q p.title
        || contains_ci ~needle:q p.author
        || contains_ci ~needle:q p.body)
      signal_filtered

let is_group_expanded t (grp : succession_group) =
  match grp.chain_root_id with
  | Some root_id when not (String.equal (String.trim root_id) "") ->
      is_succession_chain_expanded ~root_id t && List.length grp.members > 1
  | Some _ | None -> false

let board_display_posts t =
  let groups = group_succession_chains (filtered_posts t) in
  List.concat_map
    (fun (grp : succession_group) ->
      if is_group_expanded t grp then grp.members else [ grp.lead ])
    groups

let wiki_pages_filtered t =
  let pages =
    match Observed.to_option t.wiki_index with Some idx -> idx.pages | None -> []
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then pages
  else
    List.filter
      (fun (p : Wire_knowledge.wiki_page_summary) ->
        contains_ci ~needle:q p.title
        || contains_ci ~needle:q p.slug
        || contains_ci ~needle:q p.summary)
      pages

let wiki_display_pages t =
  cluster_wiki_pages (wiki_pages_filtered t) |> List.concat_map snd

let visual_row_for_selection t ~selected_index =
  match t.active_tab with
  | Nav.Knowledge_board ->
      let groups = group_succession_chains (filtered_posts t) in
      let rec walk vis_row item_idx = function
        | [] -> (selected_index, selected_index)
        | (grp : succession_group) :: rest ->
            if is_group_expanded t grp then
              let n = List.length grp.members in
              if selected_index < item_idx + n then
                let offset = selected_index - item_idx in
                let row = vis_row + 1 + offset in
                ((if offset = 0 then vis_row else row), row)
              else walk (vis_row + 1 + n) (item_idx + n) rest
            else if selected_index <= item_idx then (vis_row, vis_row)
            else walk (vis_row + 1) (item_idx + 1) rest
      in
      walk 0 0 groups
  | Nav.Knowledge_wiki ->
      let clusters = cluster_wiki_pages (wiki_pages_filtered t) in
      let rec walk vis_row item_idx = function
        | [] -> (selected_index, selected_index)
        | (_, ps) :: rest ->
            let n = List.length ps in
            if selected_index < item_idx + n then
              let offset = selected_index - item_idx in
              let row = vis_row + 1 + offset in
              ((if offset = 0 then vis_row else row), row)
            else walk (vis_row + 1 + n) (item_idx + n) rest
      in
      walk 0 0 clusters
  | Nav.Knowledge_artifacts | Nav.Knowledge_memory ->
      (selected_index, selected_index)

let selected_post t =
  let ps = board_display_posts t in
  List.nth_opt ps (clamp_index (List.length ps) t.selected_index)

type board_space_effect =
  | Board_space_toggle_chain of string
  | Board_space_toggle_signal_only

let selected_post_expandable_chain_root t =
  match selected_post t with
  | Some { Wire_knowledge.succession_chain_root_id = Some root_id; _ } ->
      let has_multi =
        List.exists
          (fun (grp : succession_group) ->
            Option.equal String.equal grp.chain_root_id (Some root_id)
            && List.length grp.members > 1)
          (group_succession_chains (filtered_posts t))
      in
      if has_multi then Some root_id else None
  | Some { Wire_knowledge.succession_chain_root_id = None; _ } | None -> None

let board_space_effect t =
  match selected_post_expandable_chain_root t with
  | Some root_id -> Board_space_toggle_chain root_id
  | None -> Board_space_toggle_signal_only

let selected_wiki_page t =
  let ps = wiki_display_pages t in
  List.nth_opt ps (clamp_index (List.length ps) t.selected_index)

let index_of_post_id id (posts : Wire_knowledge.board_post list) =
  let rec find i = function
    | [] -> None
    | (p : Wire_knowledge.board_post) :: rest ->
        if String.equal p.id id then Some i else find (i + 1) rest
  in
  find 0 posts

let index_of_chain_root root_id (posts : Wire_knowledge.board_post list) =
  let rec find i = function
    | [] -> None
    | (p : Wire_knowledge.board_post) :: rest -> (
        match p.succession_chain_root_id with
        | Some r when String.equal r root_id -> Some i
        | Some _ | None -> find (i + 1) rest)
  in
  find 0 posts

let index_of_wiki_slug slug (pages : Wire_knowledge.wiki_page_summary list) =
  let rec find i = function
    | [] -> None
    | (p : Wire_knowledge.wiki_page_summary) :: rest ->
        if String.equal p.slug slug then Some i else find (i + 1) rest
  in
  find 0 pages

let set_tab active_tab t =
  {
    t with
    active_tab;
    armed_vote = None;
    pending_artifact_revision = None;
    selected_index = 0;
    scroll_offset = 0;
    diff_scroll_offset = 0;
    detail_scroll_offset = 0;
    memory_reading = None;
    memory_reading_scroll = 0;
    memory_diagram = None;
    pending_wiki_edit_slug = None;
  }

let cycle_tab dir t =
  let next_tab =
    match dir with
    | Keymap.Next -> Nav.next_knowledge_tab t.active_tab
    | Keymap.Prev -> Nav.prev_knowledge_tab t.active_tab
  in
  set_tab next_tab t

let toggle_signal_only t =
  {
    t with
    board_signal_only = not t.board_signal_only;
    board = Observed.mark_stale t.board;
    armed_vote = None;
    selected_index = 0;
    scroll_offset = 0;
  }

let set_board_sort board_sort_by t =
  {
    t with
    board_sort_by;
    board = Observed.mark_stale t.board;
    armed_vote = None;
    selected_index = 0;
    scroll_offset = 0;
  }

let cycle_board_sort t =
  let next =
    match String.lowercase_ascii (String.trim t.board_sort_by) with
    | "recent" -> "active"
    | "active" -> "top"
    | _ -> "recent"
  in
  set_board_sort next t

let set_board_hearth board_hearth t =
  {
    t with
    board_hearth;
    board = Observed.mark_stale t.board;
    armed_vote = None;
    selected_index = 0;
    scroll_offset = 0;
  }

let cycle_board_hearth t =
  let names =
    match Observed.to_option t.board_hearths with
    | Some hs when hs <> [] ->
        List.map (fun (h : Wire_knowledge.board_hearth_entry) -> h.name) hs
    | Some _ | None -> (
        match Observed.to_option t.board with
        | Some f ->
            f.posts
            |> List.filter_map (fun (p : Wire_knowledge.board_post) -> p.hearth)
            |> List.filter (fun s -> not (String.equal (String.trim s) ""))
            |> unique_strings
        | None -> [])
  in
  let options = None :: List.map Option.some names in
  let rec find_next = function
    | [] -> None
    | [ _ ] -> None
    | cur :: next :: rest ->
        if Option.equal String.equal cur t.board_hearth then next
        else find_next (next :: rest)
  in
  set_board_hearth (find_next options) t

let max_comment_depth = 4

let order_comments_threaded (comments : Wire_knowledge.board_comment list) :
    threaded_comment list =
  let by_id : (string, Wire_knowledge.board_comment) Hashtbl.t =
    Hashtbl.create (max 8 (List.length comments))
  in
  List.iter
    (fun (c : Wire_knowledge.board_comment) -> Hashtbl.replace by_id c.id c)
    comments;
  let cmp_comment (a : Wire_knowledge.board_comment)
      (b : Wire_knowledge.board_comment) =
    let tc = Float.compare a.created_at_unix b.created_at_unix in
    if tc <> 0 then tc else String.compare a.id b.id
  in
  let children_tbl : (string, Wire_knowledge.board_comment list) Hashtbl.t =
    Hashtbl.create (max 8 (List.length comments))
  in
  let roots = ref [] in
  List.iter
    (fun (c : Wire_knowledge.board_comment) ->
      match c.parent_id with
      | Some pid when Hashtbl.mem by_id pid && not (String.equal pid c.id) ->
          let prev =
            match Hashtbl.find_opt children_tbl pid with
            | Some xs -> xs
            | None -> []
          in
          Hashtbl.replace children_tbl pid (c :: prev)
      | Some _ | None -> roots := c :: !roots)
    comments;
  let visited = Hashtbl.create (max 8 (List.length comments)) in
  let out = ref [] in
  let rec emit ~depth (c : Wire_knowledge.board_comment) =
    if not (Hashtbl.mem visited c.id) then begin
      Hashtbl.add visited c.id ();
      let d = min max_comment_depth depth in
      out := { comment = c; depth = d; is_reply = depth > 0 } :: !out;
      let kids =
        match Hashtbl.find_opt children_tbl c.id with
        | Some xs -> List.sort cmp_comment xs
        | None -> []
      in
      List.iter (emit ~depth:(depth + 1)) kids
    end
  in
  List.iter (emit ~depth:0) (List.sort cmp_comment !roots);
  (* Any remaining comments belonged to a parent_id cycle: promote safely. *)
  List.iter
    (fun (c : Wire_knowledge.board_comment) ->
      if not (Hashtbl.mem visited c.id) then emit ~depth:0 c)
    (List.sort cmp_comment comments);
  List.rev !out

let thread_comments ~post_id t =
  match Observed.to_option t.active_thread with
  | Some (post, comments) when String.equal post.id post_id ->
      order_comments_threaded comments
  | Some _ | None -> []

let comment_index selected comments =
  match selected with
  | None -> Some 0
  | Some id ->
      List.find_index (fun tc -> String.equal tc.comment.id id) comments

let selected_thread_comment_at ~post_id t =
  match t.thread_view with
  | Thread_post -> None
  | Thread_comments ->
      let comments = thread_comments ~post_id t in
      Option.bind (comment_index t.thread_selected_comment comments) (fun i ->
          Option.map (fun comment -> (i, comment)) (List.nth_opt comments i))

let selected_thread_comment ~post_id t =
  Option.map snd (selected_thread_comment_at ~post_id t)

let thread_comment_id ~post_id t =
  match t.thread_selected_comment with
  | Some _ as id -> id
  | None ->
      Option.map (fun tc -> tc.comment.id)
        (List.nth_opt (thread_comments ~post_id t) 0)

let reset_thread_view t =
  {
    t with
    thread_view = Thread_post;
    thread_selected_comment = None;
    thread_comment_scroll = 0;
  }

let toggle_thread_view t =
  let thread_view =
    match t.thread_view with
    | Thread_post -> Thread_comments
    | Thread_comments -> Thread_post
  in
  { t with thread_view; armed_vote = None }

let thread_reading_rect ~bp t rect =
  let card = Rect.inset ~left:1 ~right:1 ~top:2 ~bottom:1 rect in
  let header =
    match t.thread_view with
    | Thread_post when card.h >= 7 -> 2
    | Thread_post | Thread_comments -> 1
  in
  let vote_row = if Option.is_some t.armed_vote then 1 else 0 in
  Rect.inset ~top:(header + vote_row) card
  |> Masc_tui_ui.Card.pad_inner ~pad_x:(Masc_tui_ui.Layout.card_pad_x bp)

let step_thread_comment ~post_id ~delta t =
  let comments = thread_comments ~post_id t in
  let next = { t with thread_view = Thread_comments; armed_vote = None } in
  if List.is_empty comments then next
  else
    let last = List.length comments - 1 in
    let index =
      match t.thread_view, t.thread_selected_comment with
      | Thread_post, None -> if delta < 0 then last else 0
      | (Thread_post | Thread_comments), (Some _ | None) ->
          Option.value (comment_index t.thread_selected_comment comments) ~default:0
          + delta
    in
    let thread_selected_comment =
      Option.map (fun tc -> tc.comment.id)
        (List.nth_opt comments (Int.max 0 (Int.min last index)))
    in
    let thread_comment_scroll =
      if Option.equal String.equal thread_selected_comment (thread_comment_id ~post_id t)
      then t.thread_comment_scroll
      else 0
    in
    { next with thread_selected_comment; thread_comment_scroll }

let restore_thread_comment ~post_id ~previous current =
  let thread_selected_comment =
    if not (Option.equal String.equal previous.active_thread_target (Some post_id))
    then None
    else
      match thread_comment_id ~post_id previous with
      | Some id
        when List.exists (fun tc -> String.equal tc.comment.id id)
               (thread_comments ~post_id current) ->
          Some id
      | Some _ | None -> None
  in
  let thread_comment_scroll =
    if Option.is_some thread_selected_comment then previous.thread_comment_scroll
    else 0
  in
  { current with thread_selected_comment; thread_comment_scroll }

let equal_vote_dir a b =
  match a, b with
  | `Up, `Up | `Down, `Down -> true
  | `Up, `Down | `Down, `Up -> false

let press_vote ~target ~dir t =
  match t.armed_vote with
  | Some (prev_target, prev_dir)
    when equal_vote_target prev_target target && equal_vote_dir prev_dir dir ->
      `Confirmed { t with armed_vote = None }
  | Some _ | None -> `Armed { t with armed_vote = Some (target, dir) }

let clear_armed_vote t =
  match t.armed_vote with None -> t | Some _ -> { t with armed_vote = None }

let toggle_artifact_view_mode t =
  let artifact_view_mode =
    match t.artifact_view_mode with
    | `Document -> `Raw_source
    | `Raw_source -> `Document
  in
  { t with artifact_view_mode; detail_scroll_offset = 0 }

let apply_artifact_checks ~observed_at checks t =
  { t with artifact_checks = Observed.value ~observed_at checks }

let apply_artifact_check_update ~observed_at
    (chk : Wire_knowledge.artifact_check) t =
  let prev =
    match Observed.to_option t.artifact_checks with Some xs -> xs | None -> []
  in
  let without =
    List.filter
      (fun (c : Wire_knowledge.artifact_check) ->
        not (String.equal c.id chk.id && Int.equal c.revision chk.revision))
      prev
  in
  { t with artifact_checks = Observed.value ~observed_at (chk :: without) }

let artifact_check_for ~id ?revision t =
  match Observed.to_option t.artifact_checks with
  | None -> None
  | Some xs -> (
      match revision with
      | Some rev ->
          List.find_opt
            (fun (c : Wire_knowledge.artifact_check) ->
              String.equal c.id id && Int.equal c.revision rev)
            xs
      | None ->
          List.find_opt
            (fun (c : Wire_knowledge.artifact_check) -> String.equal c.id id)
            xs)

let set_pending_artifact_revision pending_artifact_revision t =
  { t with pending_artifact_revision }

let clear_pending_artifact_revision t =
  { t with pending_artifact_revision = None }

let is_json_artifact (a : Wire_knowledge.artifact_entry) =
  String.starts_with ~prefix:"application/json"
    (String.lowercase_ascii (String.trim a.body.mime))
  || Filename.check_suffix (String.lowercase_ascii (String.trim a.title)) ".json"

let matches_pending_artifact_revision ~id ~revision t =
  match t.pending_artifact_revision with
  | None -> true
  | Some (req_id, req_rev_opt) -> (
      String.equal req_id id
      &&
      match req_rev_opt with
      | None -> true
      | Some req_rev -> Int.equal req_rev revision)

let apply_artifact_share_result ~observed_at
    (res : Wire_knowledge.artifact_share_result) t =
  let active_artifact_detail =
    match Observed.to_option t.active_artifact_detail with
    | Some d when String.equal d.artifact.id res.id ->
        Observed.value ~observed_at
          { d with shared = res.shared; share_version = res.version }
    | Some _ | None -> t.active_artifact_detail
  in
  { t with active_artifact_detail }

let set_artifact_search query t =
  { t with artifact_search_query = query; artifact_search_match_idx = 0 }

let step_artifact_search_match ~delta ~match_count t =
  if match_count <= 0 then { t with artifact_search_match_idx = 0 }
  else
    let next = (t.artifact_search_match_idx + delta) mod match_count in
    let idx = if next < 0 then next + match_count else next in
    { t with artifact_search_match_idx = idx }

let artifact_revision_step ~delta t =
  match Observed.to_option t.active_artifact_detail with
  | None -> None
  | Some d ->
      let revs =
        d.revisions
        |> List.map (fun (r : Wire_knowledge.artifact_revision_summary) -> r.revision)
        |> List.sort_uniq Int.compare
      in
      let rec index_of i = function
        | [] -> None
        | r :: rest ->
            if Int.equal r d.artifact.revision then Some i else index_of (i + 1) rest
      in
      (match index_of 0 revs with
      | None -> None
      | Some idx ->
          let target_idx = idx + delta in
          if target_idx < 0 || target_idx >= List.length revs then None
          else
            Option.map
              (fun rev -> (d.artifact.id, rev))
              (List.nth_opt revs target_idx))

let toggle_succession_chain ~root_id t =
  let prev_post = selected_post t in
  let expanded_succession_chains =
    if String_set.mem root_id t.expanded_succession_chains then
      String_set.remove root_id t.expanded_succession_chains
    else String_set.add root_id t.expanded_succession_chains
  in
  let next = { t with expanded_succession_chains } in
  let display = board_display_posts next in
  let len = List.length display in
  let selected_index =
    match prev_post with
    | None -> clamp_index len next.selected_index
    | Some p -> (
        match index_of_post_id p.id display with
        | Some idx -> idx
        | None -> (
            let fallback_root =
              match p.succession_chain_root_id with
              | Some r -> Some r
              | None -> Some root_id
            in
            match Option.bind fallback_root (fun r -> index_of_chain_root r display) with
            | Some idx -> idx
            | None -> clamp_index len next.selected_index))
  in
  let header_row, vis_row = visual_row_for_selection next ~selected_index in
  let scroll_offset =
    adjust_grouped_scroll ~scroll:next.scroll_offset ~header_row vis_row
  in
  { next with selected_index; scroll_offset }

let set_memory_diff_window memory_diff_window t =
  {
    t with
    memory_diff_window;
    selected_diff_index = 0;
    diff_scroll_offset = 0;
    memory_reading = None;
    memory_reading_scroll = 0;
  }

let cycle_memory_diff_window t =
  let next =
    match t.memory_diff_window with
    | Window_24h -> Window_7d
    | Window_7d -> Window_30d
    | Window_30d -> Window_24h
    | Window_revs _ -> Window_24h
  in
  set_memory_diff_window next t

let reset_scoped_slot_on_switch ~changed obs =
  if not changed then Observed.mark_stale obs
  else
    match obs with
    | Observed.Failed _ | Observed.Absent -> Observed.unreported
    | Observed.Loading _ | Observed.Value _ | Observed.Unreported ->
        Observed.mark_stale obs

let set_memory_diff_keeper memory_diff_keeper t =
  let changed =
    not (Option.equal String.equal t.memory_diff_keeper memory_diff_keeper)
  in
  {
    t with
    memory_diff_keeper;
    memory_health_keeper =
      reset_scoped_slot_on_switch ~changed t.memory_health_keeper;
    keeper_memory_journal =
      reset_scoped_slot_on_switch ~changed t.keeper_memory_journal;
    selected_fact_index = if changed then 0 else t.selected_fact_index;
    facts_scroll_offset = if changed then 0 else t.facts_scroll_offset;
    selected_activity_index = if changed then 0 else t.selected_activity_index;
    activity_scroll_offset = if changed then 0 else t.activity_scroll_offset;
    selected_diff_index = if changed then 0 else t.selected_diff_index;
    diff_scroll_offset = if changed then 0 else t.diff_scroll_offset;
    memory_reading = if changed then None else t.memory_reading;
    memory_reading_scroll = if changed then 0 else t.memory_reading_scroll;
    memory_diagram = if changed then None else t.memory_diagram;
  }

let set_memory_view_mode memory_view_mode t =
  {
    t with
    memory_view_mode;
    memory_reading = None;
    memory_reading_scroll = 0;
    memory_diagram = None;
    pending_wiki_edit_slug = None;
  }

let cycle_memory_view_mode t =
  let next =
    match t.memory_view_mode with
    | View_evolution -> View_facts
    | View_facts -> View_diff
    | View_diff -> View_evolution
  in
  set_memory_view_mode next t

let set_memory_facts_sort memory_facts_sort t =
  {
    t with
    memory_facts_sort;
    selected_fact_index = 0;
    facts_scroll_offset = 0;
  }

let toggle_memory_facts_sort t =
  let next =
    match t.memory_facts_sort with
    | Sort_recency -> Sort_retrieved
    | Sort_retrieved -> Sort_recency
  in
  set_memory_facts_sort next t

let open_memory_reading entry t =
  {
    t with
    memory_reading = Some entry;
    memory_reading_scroll = 0;
    memory_diagram = None;
    pending_wiki_edit_slug = None;
  }

let close_memory_reading t =
  { t with memory_reading = None; memory_reading_scroll = 0 }

let memory_reading_matches_scope ~keeper_opt = function
  | Reading_activity { keeper; _ }
  | Reading_ordinary_fact { keeper; _ }
  | Reading_source_fact { keeper; _ }
  | Reading_source_invalidation { keeper; _ } ->
      Option.equal String.equal keeper_opt (Some keeper)
  | Reading_diff_item { keeper; _ } ->
      Option.equal String.equal keeper_opt keeper

let scroll_memory_reading ~max_scroll ~delta t =
  let memory_reading_scroll =
    Store_scroll.clamp_scroll ~max_scroll:(max 0 max_scroll)
      (t.memory_reading_scroll + delta)
  in
  { t with memory_reading_scroll }

let next_memory_diagram_request_id t = t.memory_diagram_seq + 1

let open_memory_diagram (state : memory_diagram_state) t =
  {
    t with
    memory_diagram = Some state;
    memory_diagram_seq = Int.max t.memory_diagram_seq state.request_id;
    memory_reading = None;
    memory_reading_scroll = 0;
  }

let close_memory_diagram t = { t with memory_diagram = None }

let memory_diagram_matches_scope ~keeper_opt (d : memory_diagram_state) =
  Option.equal String.equal keeper_opt (Some d.keeper)

let scroll_memory_diagram ~max_scroll ~delta t =
  match t.memory_diagram with
  | None -> t
  | Some d ->
      let scroll =
        Store_scroll.clamp_scroll ~max_scroll:(max 0 max_scroll)
          (d.scroll + delta)
      in
      { t with memory_diagram = Some { d with scroll } }

let apply_memory_diagram_result ~observed_at ~request_id ~keeper ~event_identity
    ~kind ~mode result t =
  match t.memory_diagram with
  | Some d
    when Int.equal d.request_id request_id
         && String.equal d.keeper keeper
         && String.equal d.event_identity event_identity
         && equal_memory_diagram_kind d.kind kind
         && equal_memory_diagram_mode d.mode mode ->
      let payload =
        match result with
        | Ok p -> Observed.value ~observed_at p
        | Error reason ->
            Observed.failed ~reason ~retryable:true ~at:observed_at
      in
      { t with memory_diagram = Some { d with payload; scroll = 0 } }
  | Some _ | None -> t

type reading_line_tone =
  | Reading_anchor
  | Reading_primary
  | Reading_structure of { bold : bool }
  | Reading_whisper of { italic : bool }
  | Reading_status of { tone : Theme.status_token; bold : bool }

type reading_line = {
  rail : Theme.status_token option;
  tone : reading_line_tone;
  text : string;
}

let split_graphemes_to_width ~max_w text =
  let clusters = Masc_tui_term.Grapheme.split_clusters text in
  let lines = ref [] in
  let cur = Buffer.create 64 in
  let cur_w = ref 0 in
  let flush () =
    lines := Buffer.contents cur :: !lines;
    Buffer.clear cur;
    cur_w := 0
  in
  List.iter
    (fun (bytes, width) ->
      let gw = Int.max 1 width in
      if !cur_w + gw > max_w && !cur_w > 0 then flush ();
      Buffer.add_string cur bytes;
      cur_w := !cur_w + gw)
    clusters;
  if !cur_w > 0 || !lines = [] then flush ();
  List.rev !lines

let wrap_single_paragraph ~max_width text =
  let max_w = Int.max 1 max_width in
  if String.equal text "" then [ "" ]
  else if Masc_tui_term.Grapheme.display_width text <= max_w then [ text ]
  else
    let words = String.split_on_char ' ' text in
    let lines = ref [] in
    let cur = Buffer.create 64 in
    let cur_w = ref 0 in
    let flush () =
      lines := Buffer.contents cur :: !lines;
      Buffer.clear cur;
      cur_w := 0
    in
    let push_long_word word =
      match split_graphemes_to_width ~max_w word with
      | [] -> ()
      | chunks ->
          let rec emit = function
            | [] -> ()
            | [ last ] ->
                Buffer.add_string cur last;
                cur_w := Masc_tui_term.Grapheme.display_width last
            | hd :: tl ->
                lines := hd :: !lines;
                emit tl
          in
          emit chunks
    in
    List.iter
      (fun word ->
        let ww = Masc_tui_term.Grapheme.display_width word in
        if !cur_w = 0 then begin
          if ww <= max_w then begin
            Buffer.add_string cur word;
            cur_w := ww
          end
          else push_long_word word
        end
        else if !cur_w + 1 + ww <= max_w then begin
          Buffer.add_char cur ' ';
          Buffer.add_string cur word;
          cur_w := !cur_w + 1 + ww
        end
        else begin
          flush ();
          if ww <= max_w then begin
            Buffer.add_string cur word;
            cur_w := ww
          end
          else push_long_word word
        end)
      words;
    if !cur_w > 0 || !lines = [] then flush ();
    List.rev !lines

let wrap_lines ~max_width text =
  let max_w = Int.max 1 max_width in
  let paragraphs = String.split_on_char '\n' text in
  List.concat_map (wrap_single_paragraph ~max_width:max_w) paragraphs

let reading_say (lang : Say.lang) ~ko ~en = Say.resolve lang (Say.make ~ko ~en)

let reading_sanitize_single_line s =
  let buf = Buffer.create (String.length s) in
  let prev_space = ref false in
  String.iter
    (fun c ->
      let code = Char.code c in
      if c = '\n' || c = '\r' || c = '\t' then begin
        if not !prev_space then Buffer.add_char buf ' ';
        prev_space := true
      end
      else if code >= 32 then begin
        Buffer.add_char buf c;
        prev_space := c = ' '
      end)
    s;
  String.trim (Buffer.contents buf)

let memory_change_time ~rev ~at =
  match rev, at with
  | Some revision, _ -> Printf.sprintf "@r%d" revision
  | None, Some t -> Wire_common.format_unix_rfc3339 t
  | None, None -> ""

let memory_successor_source ~lang = function
  | Some Wire_knowledge.Current_snapshot ->
    Some (reading_say lang ~ko:"현재 스냅샷에서 찾은 후속 사실" ~en:"Successor body from the current snapshot")
  | Some Archived_fact ->
    Some (reading_say lang ~ko:"보관 이력에서 찾은 후속 사실" ~en:"Successor body from the archive")
  | Some (Same_commit | Held_before) | None -> None

let reading_format_age ~now_unix ts_unix =
  if
    (not (Float.is_finite now_unix))
    || (not (Float.is_finite ts_unix))
    || now_unix <= 0.0
    || ts_unix <= 0.0
  then Glyph.to_utf8 Glyph.Missing_absent
  else
    let delta = Float.max 0.0 (now_unix -. ts_unix) in
    if delta < 5.0 then "now" else Format_val.format_duration_s delta

let reading_activity_kind_spec ~lang = function
  | Wire_knowledge.Activity_created ->
      ("+", reading_say lang ~ko:"생성" ~en:"Created", Theme.Status_ok)
  | Wire_knowledge.Activity_reobserved ->
      ("↻", reading_say lang ~ko:"재관측" ~en:"Reobserved", Theme.Status_active)
  | Wire_knowledge.Activity_revised ->
      ("~", reading_say lang ~ko:"수정" ~en:"Revised", Theme.Status_active)
  | Wire_knowledge.Activity_absorbed ->
      ("⊕", reading_say lang ~ko:"흡수" ~en:"Absorbed", Theme.Status_ai)
  | Wire_knowledge.Activity_retracted ->
      ("-", reading_say lang ~ko:"철회" ~en:"Retracted", Theme.Status_critical)
  | Wire_knowledge.Activity_removed ->
      ("✕", reading_say lang ~ko:"삭제" ~en:"Removed", Theme.Status_critical)
  | Wire_knowledge.Activity_invalidated ->
      ("!", reading_say lang ~ko:"무효화" ~en:"Invalidated", Theme.Status_attention)
  | Wire_knowledge.Activity_relation_unavailable ->
      ( "?"
      , reading_say lang ~ko:"관계 미확인" ~en:"Relation N/A"
      , Theme.Status_attention )

let reading_relation_label ~lang = function
  | Wire_knowledge.Revision -> reading_say lang ~ko:"개정" ~en:"rev"
  | Wire_knowledge.Program_revision ->
      reading_say lang ~ko:"규칙 개정" ~en:"prog-rev"
  | Wire_knowledge.Program_absorption ->
      reading_say lang ~ko:"흡수" ~en:"absorb"

let reading_heat_label = function
  | Wire_knowledge.Heat_hot -> "HOT"
  | Wire_knowledge.Heat_warm -> "WARM"
  | Wire_knowledge.Heat_cold -> "COLD"
  | Wire_knowledge.Heat_never_retrieved -> "0x"

let reading_json_kv_summary = function
  | `Assoc fields ->
      List.filter_map
        (fun (k, v) ->
          match v with
          | `String s -> Some (k, reading_sanitize_single_line s)
          | `Int n -> Some (k, string_of_int n)
          | `Float f -> Some (k, Printf.sprintf "%.2f" f)
          | `Bool b -> Some (k, string_of_bool b)
          | `Null | `List _ | `Assoc _ | `Intlit _ -> None)
        fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> []

let reading_format_basis_lines ~lang = function
  | Wire_knowledge.Basis_observed ->
      [ reading_say lang ~ko:"관측 (Observed)" ~en:"Observed" ]
  | Wire_knowledge.Basis_observed_board { post_id; comment_id } ->
      let c_part =
        match comment_id with Some c -> " / comment:" ^ c | None -> ""
      in
      [
        Printf.sprintf "%s (board post:%s%s)"
          (reading_say lang ~ko:"관측 · 보드" ~en:"Observed · Board")
          post_id c_part;
      ]
  | Wire_knowledge.Basis_derived derivs ->
      List.map
        (fun (d : Wire_knowledge.memory_derivation_ref) ->
          Printf.sprintf "%s %s ← [%s]"
            (reading_say lang ~ko:"유도 규칙" ~en:"Derived rule")
            d.rule_id
            (String.concat ", " d.premise_ids))
        derivs

let project_memory_reading_lines ~width ~lang ~now_unix entry =
  let text_w = Int.max 1 (width - 2) in
  let acc = ref [] in
  let push ?rail ~tone text = acc := { rail; tone; text } :: !acc in
  let push_wrapped ?rail ~tone text =
    List.iter (fun ln -> push ?rail ~tone ln) (wrap_lines ~max_width:text_w text)
  in
  let push_blank () = push ~tone:Reading_primary "" in
  let push_section ?rail label =
    push ?rail ~tone:(Reading_structure { bold = true }) label
  in
  let push_kv key value =
    push_wrapped ~tone:Reading_primary (Printf.sprintf "%s: %s" key value)
  in
  (match entry with
  | Reading_activity { keeper; event; notes } ->
      let g, lbl, tone = reading_activity_kind_spec ~lang event.kind in
      push_wrapped ~rail:tone ~tone:(Reading_status { tone; bold = true })
        (Printf.sprintf "%s %s  ·  @%s  ·  r%d  ·  %s (%s)" g lbl keeper
           event.revision
           (Wire_common.format_unix_rfc3339 event.recorded_at_unix)
           (reading_format_age ~now_unix event.recorded_at_unix));
      push_wrapped ~tone:(Reading_whisper { italic = true })
        ("ID: " ^ event.identity);
      push_blank ();
      (match event.reason with
      | Some r when not (String.equal (String.trim r) "") ->
          push_section ~rail:Theme.Status_attention
            (reading_say lang ~ko:"사유 (Reason)" ~en:"Reason");
          push_wrapped ~rail:Theme.Status_attention ~tone:Reading_primary r;
          push_blank ()
      | Some _ | None -> ());
      push_section ~rail:Theme.Status_critical
        (Printf.sprintf "%s (%d)"
           (reading_say lang ~ko:"이전 기억 (Before)" ~en:"Before")
           (List.length event.before));
      if event.before = [] then
        push ~tone:(Reading_whisper { italic = true })
          (reading_say lang ~ko:"(없음 — 신규 생성)" ~en:"(none — newly created)")
      else
        List.iteri
          (fun idx (f : Wire_knowledge.memory_activity_fact) ->
            push_wrapped ~rail:Theme.Status_critical
              ~tone:(Reading_whisper { italic = false })
              (Printf.sprintf "#%d  %s" (idx + 1) f.memory_id);
            let claim_s =
              Option.value f.claim
                ~default:
                  (reading_say lang ~ko:"(본문 미기록)" ~en:"(claim unavailable)")
            in
            push_wrapped ~rail:Theme.Status_critical ~tone:Reading_primary
              claim_s)
          event.before;
      push_blank ();
      push_section ~rail:Theme.Status_ok
        (Printf.sprintf "%s (%d)"
           (reading_say lang ~ko:"이후 기억 (After)" ~en:"After")
           (List.length event.after));
      if event.after = [] then
        push ~tone:(Reading_whisper { italic = true })
          (reading_say lang ~ko:"(없음 — 철회/삭제/무효화)"
             ~en:"(none — retracted/removed/invalidated)")
      else
        List.iteri
          (fun idx (f : Wire_knowledge.memory_activity_fact) ->
            push_wrapped ~rail:Theme.Status_ok
              ~tone:(Reading_whisper { italic = false })
              (Printf.sprintf "#%d  %s" (idx + 1) f.memory_id);
            let claim_s =
              Option.value f.claim
                ~default:
                  (reading_say lang ~ko:"(본문 미기록)" ~en:"(claim unavailable)")
            in
            push_wrapped ~rail:Theme.Status_ok ~tone:Reading_primary claim_s)
          event.after;
      if notes <> [] then begin
        push_blank ();
        push_section (reading_say lang ~ko:"저널 노트 (Notes)" ~en:"Journal Notes");
        List.iter
          (fun n ->
            push_wrapped ~tone:(Reading_whisper { italic = true }) ("· " ^ n))
          notes
      end
  | Reading_ordinary_fact { keeper; revision; fact } ->
      let cat_s = Wire_knowledge.memory_fact_category_to_string fact.category in
      let orig_s = Wire_knowledge.memory_fact_origin_to_string fact.origin in
      push_wrapped ~rail:Theme.Status_active ~tone:Reading_anchor
        (Printf.sprintf "@%s  ·  [%s]  ·  %s  ·  r%d" keeper cat_s orig_s
           revision);
      push_wrapped ~tone:(Reading_whisper { italic = true })
        ("ID: " ^ fact.memory_id);
      push_blank ();
      push_section ~rail:Theme.Status_ok
        (reading_say lang ~ko:"전체 기억 내용 (Claim)" ~en:"Full Claim");
      push_wrapped ~rail:Theme.Status_ok ~tone:Reading_primary fact.claim;
      push_blank ();
      push_section
        (reading_say lang ~ko:"메타데이터 · 조회 이력" ~en:"Metadata & Retrieval");
      push_kv
        (reading_say lang ~ko:"최초 관측" ~en:"First seen")
        (Printf.sprintf "%s (%s)"
           (Wire_common.format_unix_rfc3339 fact.first_seen_unix)
           (reading_format_age ~now_unix fact.first_seen_unix));
      push_kv
        (reading_say lang ~ko:"최근 관측" ~en:"Last seen")
        (Printf.sprintf "%s (%s)"
           (Wire_common.format_unix_rfc3339 fact.last_seen_unix)
           (reading_format_age ~now_unix fact.last_seen_unix));
      let ret_str =
        match fact.events.retrieval with
        | Wire_knowledge.Never_retrieved ->
            reading_say lang ~ko:"미조회 (0회)" ~en:"Never retrieved (0x)"
        | Wire_knowledge.Retrieved { count; distinct_days; last_at_unix } ->
            Printf.sprintf "%dx · %dd · %s (%s)" count distinct_days
              (Wire_common.format_unix_rfc3339 last_at_unix)
              (reading_format_age ~now_unix last_at_unix)
      in
      push_kv (reading_say lang ~ko:"조회 기록" ~en:"Retrieval") ret_str;
      if fact.events.retracted_count > 0 then
        push_kv
          (reading_say lang ~ko:"철회 횟수" ~en:"Retracted count")
          (string_of_int fact.events.retracted_count);
      push_blank ();
      push_section ~rail:Theme.Status_ai
        (reading_say lang ~ko:"근거 (Basis)" ~en:"Basis");
      List.iter
        (fun ln -> push_wrapped ~rail:Theme.Status_ai ~tone:Reading_primary ln)
        (reading_format_basis_lines ~lang fact.basis);
      if fact.events.revised_from <> [] then begin
        push_blank ();
        push_section ~rail:Theme.Status_active
          (reading_say lang ~ko:"개정 계보 (Supersedes / Revised From)"
             ~en:"Lineage (Revised From)");
        List.iter
          (fun prev_id ->
            push_wrapped ~rail:Theme.Status_active
              ~tone:(Reading_structure { bold = false })
              ("← " ^ prev_id))
          fact.events.revised_from
      end
  | Reading_source_fact { keeper; fact } ->
      push_wrapped ~rail:Theme.Status_ai ~tone:Reading_anchor
        (Printf.sprintf "@%s  ·  [source-bound]" keeper);
      push_kv (reading_say lang ~ko:"소스 경로" ~en:"Source path") fact.path;
      push_kv "SHA-256" fact.sha256;
      push_kv
        (reading_say lang ~ko:"최초 관측" ~en:"First seen")
        (Wire_common.format_unix_rfc3339 fact.first_seen_unix);
      push_blank ();
      push_section ~rail:Theme.Status_ai
        (reading_say lang ~ko:"전체 기억 내용 (Claim)" ~en:"Full Claim");
      push_wrapped ~rail:Theme.Status_ai ~tone:Reading_primary fact.claim
  | Reading_source_invalidation { keeper; invalidation } ->
      push_wrapped ~rail:Theme.Status_attention
        ~tone:(Reading_status { tone = Theme.Status_attention; bold = true })
        (Printf.sprintf "! @%s  ·  %s" keeper
           (reading_say lang ~ko:"소스 기반 기억 무효화"
              ~en:"Source-bound Invalidation"));
      push_blank ();
      push_kv
        (reading_say lang ~ko:"소스 경로" ~en:"Source path")
        invalidation.source_path;
      push_kv
        (reading_say lang ~ko:"사유" ~en:"Reason")
        (Wire_knowledge.source_invalidation_reason_to_string invalidation.reason);
      push_kv
        (reading_say lang ~ko:"무효화 시각" ~en:"Invalidated at")
        (Wire_common.format_unix_rfc3339 invalidation.invalidated_at_unix)
  | Reading_diff_item { keeper; item } -> (
      let scope_s =
        match keeper with
        | Some kp -> "@" ^ kp
        | None -> reading_say lang ~ko:"월드 메모리" ~en:"World Memory"
      in
      match item with
      | Keeper_added f ->
          let h_lbl = reading_heat_label f.heat in
          push_wrapped ~rail:Theme.Status_ok
            ~tone:(Reading_status { tone = Theme.Status_ok; bold = true })
            (Printf.sprintf "+ %s  ·  [%s] %s  ·  %s %dx" scope_s f.category
               f.origin h_lbl f.retrieval_count);
          push_wrapped ~tone:(Reading_whisper { italic = true })
            ("ID: " ^ f.memory_id);
          push_blank ();
          push_wrapped ~rail:Theme.Status_ok ~tone:Reading_primary f.text
      | Keeper_updated u ->
          push_wrapped ~rail:Theme.Status_active
            ~tone:(Reading_status { tone = Theme.Status_active; bold = true })
            (Printf.sprintf "~ %s  ·  [%s] %s %s" scope_s u.after.category
               (reading_relation_label ~lang u.relation)
               (memory_change_time ~rev:u.at_rev ~at:u.at_unix));
          push_blank ();
          push_section ~rail:Theme.Status_critical
            (reading_say lang ~ko:"이전 (Before)" ~en:"Before");
          push_wrapped ~rail:Theme.Status_critical ~tone:Reading_primary
            u.before.text;
          push_blank ();
          push_section ~rail:Theme.Status_ok
            (reading_say lang ~ko:"이후 (After)" ~en:"After");
          Option.iter (fun source -> push_wrapped ~rail:Theme.Status_ok ~tone:(Reading_whisper { italic = false }) source)
            (memory_successor_source ~lang u.after_source);
          push_wrapped ~rail:Theme.Status_ok ~tone:Reading_primary u.after.text
      | Keeper_retracted r ->
          push_wrapped ~rail:Theme.Status_critical
            ~tone:(Reading_status { tone = Theme.Status_critical; bold = true })
            (Printf.sprintf "- %s  ·  [%s] %s  ·  %s" scope_s r.category
               (memory_change_time ~rev:r.removed_at_rev ~at:r.at_unix) (Option.value ~default:"" r.removed_by));
          (match r.drop_reason with
          | Some rs -> push_kv (reading_say lang ~ko:"사유" ~en:"Reason") rs
          | None -> ());
          push_blank ();
          push_wrapped ~rail:Theme.Status_critical ~tone:Reading_primary r.text
      | Keeper_invalidated inv ->
          push_wrapped ~rail:Theme.Status_attention
            ~tone:(Reading_status { tone = Theme.Status_attention; bold = true })
            (Printf.sprintf "! %s  ·  %s" scope_s (memory_change_time ~rev:inv.at_rev ~at:inv.at_unix));
          push_kv
            (reading_say lang ~ko:"유실된 전제" ~en:"Missing premises")
            (String.concat ", " inv.missing_premise_ids);
          push_blank ();
          push_wrapped ~rail:Theme.Status_attention ~tone:Reading_primary
            inv.text
      | World_added e ->
          let tone = Theme.Status_ok in
          push_wrapped ~rail:tone ~tone:(Reading_status { tone; bold = true })
            (Printf.sprintf "+ %s  ·  #%d [%s]" scope_s e.seq e.fact_id);
          push_kv (reading_say lang ~ko:"시각" ~en:"Recorded at") e.recorded_at;
          push_blank ();
          push_wrapped ~rail:tone ~tone:Reading_primary e.summary;
          let kvs = reading_json_kv_summary e.payload in
          if kvs <> [] then begin
            push_blank ();
            List.iter (fun (k, v) -> push_kv k v) kvs
          end
      | World_retracted e ->
          let tone = Theme.Status_critical in
          push_wrapped ~rail:tone ~tone:(Reading_status { tone; bold = true })
            (Printf.sprintf "- %s  ·  #%d [%s]" scope_s e.seq e.fact_id);
          push_kv (reading_say lang ~ko:"시각" ~en:"Recorded at") e.recorded_at;
          push_blank ();
          push_wrapped ~rail:tone ~tone:Reading_primary e.summary;
          let kvs = reading_json_kv_summary e.payload in
          if kvs <> [] then begin
            push_blank ();
            List.iter (fun (k, v) -> push_kv k v) kvs
          end
      | World_updated u ->
          push_wrapped ~rail:Theme.Status_active
            ~tone:(Reading_status { tone = Theme.Status_active; bold = true })
            (Printf.sprintf "~ %s  ·  #%d [%s]" scope_s u.seq u.fact_id);
          push_kv (reading_say lang ~ko:"시각" ~en:"Recorded at") u.recorded_at;
          push_blank ();
          push_wrapped ~rail:Theme.Status_active ~tone:Reading_primary u.summary;
          let b_kvs = reading_json_kv_summary u.before in
          if b_kvs <> [] then begin
            push_blank ();
            push_section ~rail:Theme.Status_critical
              (reading_say lang ~ko:"이전 (Before)" ~en:"Before");
            List.iter (fun (k, v) -> push_kv k v) b_kvs
          end;
          let a_kvs = reading_json_kv_summary u.after in
          if a_kvs <> [] then begin
            push_blank ();
            push_section ~rail:Theme.Status_ok
              (reading_say lang ~ko:"이후 (After)" ~en:"After");
            List.iter (fun (k, v) -> push_kv k v) a_kvs
          end));
  List.rev !acc

let apply_board ~observed_at feed t =
  let prev_id =
    if Nav.equal_knowledge_tab t.active_tab Nav.Knowledge_board then
      Option.map (fun (p : Wire_knowledge.board_post) -> p.id) (selected_post t)
    else None
  in
  let next = { t with board = Observed.value ~observed_at feed } in
  if not (Nav.equal_knowledge_tab next.active_tab Nav.Knowledge_board) then next
  else
    let display = board_display_posts next in
    let len = List.length display in
    let selected_index =
      match Option.bind prev_id (fun id -> index_of_post_id id display) with
      | Some idx -> idx
      | None -> clamp_index len next.selected_index
    in
    let header_row, vis_row = visual_row_for_selection next ~selected_index in
    let scroll_offset =
      adjust_grouped_scroll ~scroll:next.scroll_offset ~header_row vis_row
    in
    { next with selected_index; scroll_offset }

let apply_board_hearths ~observed_at hearths t =
  { t with board_hearths = Observed.value ~observed_at hearths }

let apply_thread ~observed_at ((p, _) as thread) t =
  {
    t with
    active_thread = Observed.value ~observed_at thread;
    active_thread_target = Some p.Wire_knowledge.id;
    thread_selected_comment = None;
    armed_vote = None;
  }

let mark_thread_loading ?(force = false) ~post_id ~since_ns t =
  let keep_existing =
    (not force)
    &&
    match t.active_thread with
    | Observed.Value { data = tp, _; _ } -> String.equal tp.id post_id
    | Observed.Failed { retryable = false; _ } ->
        Option.equal String.equal t.active_thread_target (Some post_id)
    | Observed.Loading _ ->
        Option.equal String.equal t.active_thread_target (Some post_id)
    | Observed.Absent
    | Observed.Unreported
    | Observed.Failed { retryable = true; _ } ->
        false
  in
  if keep_existing then t
  else
    let same_thread =
      Option.equal String.equal t.active_thread_target (Some post_id)
    in
    {
      t with
      active_thread = Observed.loading ~since_ns;
      active_thread_target = Some post_id;
      thread_selected_comment =
        (if same_thread then thread_comment_id ~post_id t else None);
      thread_comment_scroll = (if same_thread then t.thread_comment_scroll else 0);
      armed_vote = None;
    }

let mark_thread_failed ?target ~at ~reason ~retryable t =
  let thread_selected_comment =
    match target with
    | Some post_id when retryable && Option.equal String.equal t.active_thread_target target ->
        thread_comment_id ~post_id t
    | Some _ | None -> None
  in
  {
    t with
    active_thread = Observed.failed ~reason ~retryable ~at;
    active_thread_target = target;
    thread_selected_comment;
    thread_comment_scroll =
      (if Option.is_some thread_selected_comment then t.thread_comment_scroll else 0);
    armed_vote = None;
  }

let apply_wiki_index ~observed_at idx t =
  let on_wiki = Nav.equal_knowledge_tab t.active_tab Nav.Knowledge_wiki in
  let prev_slug =
    if on_wiki then
      Option.map
        (fun (p : Wire_knowledge.wiki_page_summary) -> p.slug)
        (selected_wiki_page t)
    else None
  in
  let next = { t with wiki_index = Observed.value ~observed_at idx } in
  if not on_wiki then next
  else
    let display = wiki_display_pages next in
    let len = List.length display in
    let selected_index =
      match Option.bind prev_slug (fun sl -> index_of_wiki_slug sl display) with
      | Some idx -> idx
      | None -> clamp_index len next.selected_index
    in
    let header_row, vis_row = visual_row_for_selection next ~selected_index in
    let scroll_offset =
      adjust_grouped_scroll ~scroll:next.scroll_offset ~header_row vis_row
    in
    { next with selected_index; scroll_offset }

let apply_wiki_log ~observed_at log t =
  { t with wiki_log = Observed.value ~observed_at log }

let apply_wiki_search ~observed_at search t =
  { t with wiki_search = Observed.value ~observed_at search }

let apply_wiki_lint ~observed_at lint t =
  { t with wiki_lint = Observed.value ~observed_at lint }

let apply_artifacts ~observed_at artifacts t =
  { t with artifacts = Observed.value ~observed_at artifacts }

let apply_world_memory ~observed_at mem t =
  { t with world_memory = Observed.value ~observed_at mem }

let apply_keeper_memory_facts ~observed_at ?keeper
    (facts : Wire_knowledge.keeper_memory_facts) t =
  let keeper_key = Option.value ~default:facts.keeper keeper in
  set_keeper_memory_facts ~keeper:keeper_key
    (Observed.value ~observed_at facts)
    t
let apply_keeper_memory_health ~observed_at
    (fleet : Wire_knowledge.keeper_memory_health_fleet) t =
  { t with keeper_memory_health = Observed.value ~observed_at fleet }

let fail_keeper_memory_health ~reason ~retryable ~at t =
  let keeper_memory_health =
    match t.keeper_memory_health with
    | Observed.Value _ -> Observed.mark_stale t.keeper_memory_health
    | Observed.Loading _
    | Observed.Absent
    | Observed.Unreported
    | Observed.Failed _ ->
        Observed.failed ~reason ~retryable ~at
  in
  { t with keeper_memory_health }

let record_memory_act_answer ~keeper ans t =
  { t with last_memory_act_answer = Some (keeper, ans) }

let request_wiki_edit ~slug t = { t with pending_wiki_edit_slug = Some slug }

let clear_pending_wiki_edit t = { t with pending_wiki_edit_slug = None }

let begin_wiki_edit (page : Wire_knowledge.wiki_page_detail) t =
  {
    t with
    pending_wiki_edit_slug = None;
    wiki_edit_base =
      Some
        {
          slug = page.slug;
          revision = page.frontmatter.revision;
          sha256 = page.sha256;
          source = page.frontmatter.source;
          tags = page.frontmatter.tags;
        };
  }

let end_wiki_edit t =
  { t with wiki_edit_base = None; pending_wiki_edit_slug = None }

let artifacts_filtered t =
  let items =
    match Observed.to_option t.artifacts with Some xs -> xs | None -> []
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then items
  else
    List.filter
      (fun (a : Wire_knowledge.artifact_entry) ->
        contains_ci ~needle:q a.title
        || contains_ci ~needle:q a.id
        || contains_ci ~needle:q a.body.sha256
        || contains_ci ~needle:q a.body.mime
        || contains_ci ~needle:q a.author)
      items

let selected_artifact t =
  let items = artifacts_filtered t in
  List.nth_opt items (clamp_index (List.length items) t.selected_index)

let artifact_by_id t id =
  match Observed.to_option t.artifacts with
  | Some items ->
      List.find_opt
        (fun (a : Wire_knowledge.artifact_entry) -> String.equal a.id id)
        items
  | None -> None

let find_artifact_by_id_or_sha target t =
  let items =
    match Observed.to_option t.artifacts with Some xs -> xs | None -> []
  in
  List.find_opt
    (fun (a : Wire_knowledge.artifact_entry) ->
      String.equal a.id target || String.equal a.body.sha256 target)
    items

let artifact_detail_for_entry (a : Wire_knowledge.artifact_entry) t =
  match Observed.to_option t.active_artifact_detail with
  | Some detail
    when String.equal detail.artifact.id a.id
         || String.equal detail.artifact.body.sha256 a.body.sha256 ->
      Some detail
  | Some _ | None -> None

let artifact_detail_failure_for_entry (a : Wire_knowledge.artifact_entry) t =
  match t.active_artifact_detail with
  | Observed.Failed { reason; _ } -> (
      match t.active_artifact_detail_target with
      | None -> Some reason
      | Some target
        when String.equal target a.id || String.equal target a.body.sha256 ->
          Some reason
      | Some _ -> None)
  | Observed.Loading _
  | Observed.Value _
  | Observed.Absent
  | Observed.Unreported ->
      None

let artifact_preview_lines (_a : Wire_knowledge.artifact_entry)
    (detail_opt : Wire_knowledge.published_artifact_detail option) =
  let raw_opt =
    match detail_opt with
    | Some d when not (String.equal d.content "") -> Some d.content
    | Some _ | None -> None
  in
  match raw_opt with
  | None -> []
  | Some raw ->
      String.split_on_char '\n' raw
      |> List.map (fun line ->
             let len = String.length line in
             if len > 0 && Char.equal line.[len - 1] '\r' then
               String.sub line 0 (len - 1)
             else line)

let toggle_memory_flow_mode t =
  {
    t with
    memory_flow_mode = Masc_tui_ui.Memory_flow.toggle_mode t.memory_flow_mode;
  }

let apply_artifact_detail ~observed_at detail t =
  {
    t with
    active_artifact_detail = Observed.value ~observed_at detail;
    active_artifact_detail_target = Some detail.artifact.id;
    pending_artifact_revision = None;
  }

let mark_artifact_detail_failed ?target ~at ~reason ~retryable t =
  {
    t with
    active_artifact_detail = Observed.failed ~reason ~retryable ~at;
    active_artifact_detail_target = target;
    pending_artifact_revision = None;
  }

let memory_flow_input_of_diff (diff : Wire_knowledge.memory_diff)
    (window : memory_diff_window) : Masc_tui_ui.Memory_flow.input =
  let win_kind =
    match window with
    | Window_24h -> Masc_tui_ui.Memory_flow.Window_24h
    | Window_7d -> Masc_tui_ui.Memory_flow.Window_7d
    | Window_30d -> Masc_tui_ui.Memory_flow.Window_30d
    | Window_revs { from_rev; to_rev } ->
        Masc_tui_ui.Memory_flow.Window_revs { from_rev; to_rev }
  in
  match diff.body with
  | Wire_knowledge.Keeper_diff { counts; revisions; _ } ->
      let revs =
        List.map
          (fun (r : Wire_knowledge.memory_revision_tick) ->
            {
              Masc_tui_ui.Memory_flow.rev = r.rev;
              at_unix = r.at_unix;
              added = r.added;
              removed = r.removed + r.invalidated;
            })
          revisions
      in
      {
        Masc_tui_ui.Memory_flow.revisions = revs;
        from_unix = diff.range.from_unix;
        to_unix = diff.range.to_unix;
        total_now = counts.total_facts_now;
        is_world = false;
        window = win_kind;
      }
  | Wire_knowledge.World_diff { counts; revisions; _ } ->
      let revs =
        List.filter_map
          (fun (r : Wire_knowledge.world_revision_tick) ->
            match Wire_common.parse_rfc3339_unix r.recorded_at with
            | Error _ -> None
            | Ok at_unix ->
                let added, removed =
                  match String.lowercase_ascii (String.trim r.op) with
                  | "added" -> (1, 0)
                  | "retracted" -> (0, 1)
                  | _ -> (0, 0)
                in
                Some
                  {
                    Masc_tui_ui.Memory_flow.rev = r.rev;
                    at_unix;
                    added;
                    removed;
                  })
          revisions
      in
      {
        Masc_tui_ui.Memory_flow.revisions = revs;
        from_unix = diff.range.from_unix;
        to_unix = diff.range.to_unix;
        total_now = counts.total_claims_now;
        is_world = true;
        window = win_kind;
      }

let memory_diff_matches_filter t text =
  let q = String.trim t.filter_query in
  String.equal q "" || contains_ci ~needle:q text

let filtered_memory_conflicts t =
  let all =
    match Observed.to_option t.world_memory with
    | Some w -> w.active_conflicts
    | None -> []
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then all
  else
    List.filter
      (fun (c : Wire_knowledge.memory_conflict) ->
        contains_ci ~needle:q c.conflict_id
        || contains_ci ~needle:q c.description
        || List.exists
             (fun (cl : Wire_knowledge.competing_claim) ->
               contains_ci ~needle:q cl.keeper_id
               ||
               match cl.claim with
               | Some s -> contains_ci ~needle:q s
               | None -> false)
             c.competing_claims)
      all

let filtered_memory_claims t =
  let all =
    match Observed.to_option t.world_memory with
    | Some w -> w.claims
    | None -> []
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then all
  else
    List.filter
      (fun (c : Wire_knowledge.world_claim) ->
        contains_ci ~needle:q c.claim
        || contains_ci ~needle:q c.claim_id
        || List.exists (contains_ci ~needle:q) c.supporting_keepers)
      all

let filtered_librarian_writers t =
  let all =
    match Observed.to_option t.world_memory with
    | Some w -> (
        match w.librarian_writers with
        | Wire_knowledge.Writers_running { keepers; _ } -> keepers
        | Wire_knowledge.Writers_none_in_process -> [])
    | None -> []
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then all
  else
    List.filter
      (fun (w : Wire_knowledge.librarian_writer_row) ->
        contains_ci ~needle:q w.keeper)
      all

let memory_left_rows t =
  let conflicts =
    List.map (fun c -> Left_conflict c) (filtered_memory_conflicts t)
  in
  let writers = filtered_librarian_writers t in
  if writers = [] then conflicts
  else conflicts @ (Left_world_scope :: List.map (fun w -> Left_writer w) writers)

let selected_memory_left_row t =
  let rows = memory_left_rows t in
  List.nth_opt rows (clamp_index (List.length rows) t.selected_index)

let health_row_for_keeper ~keeper t =
  match Observed.to_option t.keeper_memory_health with
  | None -> None
  | Some fleet ->
      List.find_opt
        (fun (row : Wire_knowledge.keeper_memory_health_row) ->
          String.equal row.keeper_id keeper)
        fleet.keepers

let filtered_memory_activity_events ~keeper t =
  match Observed.to_option (keeper_memory_activity_for ~keeper t) with
  | Some act ->
      let q = String.trim t.filter_query in
      if String.equal q "" then act.events
      else
        List.filter
          (fun (ev : Wire_knowledge.memory_activity_event) ->
            contains_ci ~needle:q ev.identity
            || contains_ci ~needle:q
                 (Wire_knowledge.memory_activity_kind_to_string ev.kind)
            || (match ev.reason with
               | Some r -> contains_ci ~needle:q r
               | None -> false)
            || List.exists
                 (fun (f : Wire_knowledge.memory_activity_fact) ->
                   contains_ci ~needle:q f.memory_id
                   ||
                   match f.claim with
                   | Some c -> contains_ci ~needle:q c
                   | None -> false)
                 ev.before
            || List.exists
                 (fun (f : Wire_knowledge.memory_activity_fact) ->
                   contains_ci ~needle:q f.memory_id
                   ||
                   match f.claim with
                   | Some c -> contains_ci ~needle:q c
                   | None -> false)
                 ev.after)
          act.events
  | None -> []

let selected_activity_event_for ~keeper t =
  let events = filtered_memory_activity_events ~keeper t in
  List.nth_opt events (clamp_index (List.length events) t.selected_activity_index)

let selected_activity_event t =
  match t.memory_diff_keeper with
  | Some kp -> selected_activity_event_for ~keeper:kp t
  | None -> None

let fact_retrieval_sort_key (f : Wire_knowledge.keeper_ordinary_fact) =
  match f.events.retrieval with
  | Wire_knowledge.Never_retrieved -> (0, 0, f.last_seen_unix)
  | Wire_knowledge.Retrieved { count; distinct_days; last_at_unix } ->
      (count, distinct_days, last_at_unix)

let filtered_memory_fact_rows ~keeper t =
  match Observed.to_option (keeper_memory_facts_for ~keeper t) with
  | Some mf ->
      let q = String.trim t.filter_query in
      let matches_text s = String.equal q "" || contains_ci ~needle:q s in
      let ord_rows =
        match mf.ordinary with
        | Wire_knowledge.Memory_store_present ord ->
            let filtered =
              List.filter
                (fun (f : Wire_knowledge.keeper_ordinary_fact) ->
                  matches_text f.claim || matches_text f.memory_id
                  || matches_text
                       (Wire_knowledge.memory_fact_category_to_string f.category)
                  || matches_text
                       (Wire_knowledge.memory_fact_origin_to_string f.origin))
                ord.facts
            in
            let sorted =
              match t.memory_facts_sort with
              | Sort_recency ->
                  List.stable_sort
                    (fun (a : Wire_knowledge.keeper_ordinary_fact)
                         (b : Wire_knowledge.keeper_ordinary_fact) ->
                      let c = Float.compare b.last_seen_unix a.last_seen_unix in
                      if c <> 0 then c
                      else Float.compare b.first_seen_unix a.first_seen_unix)
                    filtered
              | Sort_retrieved ->
                  List.stable_sort
                    (fun (a : Wire_knowledge.keeper_ordinary_fact)
                         (b : Wire_knowledge.keeper_ordinary_fact) ->
                      let ca, da, ta = fact_retrieval_sort_key a in
                      let cb, db, tb = fact_retrieval_sort_key b in
                      if cb <> ca then Int.compare cb ca
                      else if db <> da then Int.compare db da
                      else Float.compare tb ta)
                    filtered
            in
            List.map
              (fun fact -> Fact_ordinary { revision = ord.revision; fact })
              sorted
        | Wire_knowledge.Memory_store_absent
        | Wire_knowledge.Memory_store_read_error _ ->
            []
      in
      let src_rows =
        match mf.source_bound with
        | Wire_knowledge.Memory_store_present src ->
            let fs =
              List.filter_map
                (fun (sf : Wire_knowledge.keeper_source_fact) ->
                  if matches_text sf.claim || matches_text sf.path then
                    Some (Fact_source sf)
                  else None)
                src.facts
            in
            let invs =
              List.filter_map
                (fun (inv : Wire_knowledge.keeper_source_invalidation) ->
                  if
                    matches_text inv.source_path
                    || matches_text
                         (Wire_knowledge.source_invalidation_reason_to_string
                            inv.reason)
                  then Some (Fact_source_invalidation inv)
                  else None)
                src.invalidations
            in
            fs @ invs
        | Wire_knowledge.Memory_store_absent
        | Wire_knowledge.Memory_store_read_error _ ->
            []
      in
      ord_rows @ src_rows
  | None -> []

let selected_memory_fact_row ~keeper t =
  let rows = filtered_memory_fact_rows ~keeper t in
  List.nth_opt rows (clamp_index (List.length rows) t.selected_fact_index)

let move_memory_activity ~keeper ?viewport_rows ~delta t =
  let len = List.length (filtered_memory_activity_events ~keeper t) in
  let selected_activity_index =
    clamp_index len (t.selected_activity_index + delta)
  in
  let activity_scroll_offset =
    Store_scroll.adjust_scroll ?viewport_rows ~scroll:t.activity_scroll_offset
      selected_activity_index
  in
  { t with selected_activity_index; activity_scroll_offset }

let move_memory_facts ~keeper ?viewport_rows ~delta t =
  let len = List.length (filtered_memory_fact_rows ~keeper t) in
  let selected_fact_index = clamp_index len (t.selected_fact_index + delta) in
  let facts_scroll_offset =
    Store_scroll.adjust_scroll ?viewport_rows ~scroll:t.facts_scroll_offset
      selected_fact_index
  in
  { t with selected_fact_index; facts_scroll_offset }

let hottest_signal_threads t =
  match Observed.to_option t.board with
  | None -> []
  | Some feed ->
      feed.posts
      |> List.filter (fun (p : Wire_knowledge.board_post) ->
             p.is_signal
             && Wire_knowledge.is_signal_board_post ~post_kind:p.post_kind
                  ~hearth:p.hearth ~title:p.title ~body:p.body)
      |> List.sort
           (fun (a : Wire_knowledge.board_post) (b : Wire_knowledge.board_post)
            ->
             let sa = (a.comment_count * 3) + a.score in
             let sb = (b.comment_count * 3) + b.score in
             if sb <> sa then Int.compare sb sa
             else Float.compare b.created_at_unix a.created_at_unix)

let selected_pulse_thread t =
  let ts = hottest_signal_threads t in
  List.nth_opt ts (clamp_index (List.length ts) t.pulse_thread_index)

let move_pulse_thread ?viewport_rows:_ ~delta t =
  let len = List.length (hottest_signal_threads t) in
  let pulse_thread_index = clamp_index len (t.pulse_thread_index + delta) in
  { t with pulse_thread_index }

let filtered_memory_diff_items_for ~keeper_opt t =
  match
    ( keeper_opt,
      Observed.to_option
        (memory_diff_for ~keeper:keeper_opt ~window:t.memory_diff_window t) )
  with
  | _, None -> []
  | ( Some kp
    , Some
        {
          scope = Wire_knowledge.Scope_keeper k;
          body =
            Wire_knowledge.Keeper_diff
              { added; updated; retracted; invalidated; _ };
          _;
        } )
    when String.equal kp k ->
      let a =
        List.filter_map
          (fun (f : Wire_knowledge.memory_fact_entry) ->
            if
              memory_diff_matches_filter t
                (f.category ^ " " ^ f.origin ^ " " ^ f.text)
            then Some (Keeper_added f)
            else None)
          added
      in
      let u =
        List.filter_map
          (fun (uf : Wire_knowledge.memory_updated_fact) ->
            if
              memory_diff_matches_filter t
                (uf.after.category ^ " " ^ uf.before.text ^ " " ^ uf.after.text)
            then Some (Keeper_updated uf)
            else None)
          updated
      in
      let r =
        List.filter_map
          (fun (rf : Wire_knowledge.memory_retracted_fact) ->
            if
              memory_diff_matches_filter t
                (rf.category ^ " " ^ Option.value ~default:"" rf.removed_by ^ " " ^ rf.text)
            then Some (Keeper_retracted rf)
            else None)
          retracted
      in
      let inv =
        List.filter_map
          (fun (iv : Wire_knowledge.memory_invalidated_fact) ->
            if
              memory_diff_matches_filter t
                (iv.text ^ " " ^ String.concat " " iv.missing_premise_ids)
            then Some (Keeper_invalidated iv)
            else None)
          invalidated
      in
      let order = function
        | Keeper_added x -> x.Wire_knowledge.event_order
        | Keeper_updated x -> x.event_order | Keeper_retracted x -> x.event_order
        | Keeper_invalidated x -> x.event_order
        | World_added _ | World_updated _ | World_retracted _ -> None in
      List.stable_sort (fun x y -> Option.compare Int.compare (order x) (order y)) (a @ u @ r @ inv)
  | ( None
    , Some
        {
          scope = Wire_knowledge.Scope_world;
          body = Wire_knowledge.World_diff { added; updated; retracted; _ };
          _;
        } ) ->
      let a =
        List.filter_map
          (fun (e : Wire_knowledge.world_change_entry) ->
            if memory_diff_matches_filter t (e.fact_id ^ " " ^ e.summary) then
              Some (World_added e)
            else None)
          added
      in
      let u =
        List.filter_map
          (fun (ue : Wire_knowledge.world_updated_entry) ->
            if memory_diff_matches_filter t (ue.fact_id ^ " " ^ ue.summary) then
              Some (World_updated ue)
            else None)
          updated
      in
      let r =
        List.filter_map
          (fun (e : Wire_knowledge.world_change_entry) ->
            if memory_diff_matches_filter t (e.fact_id ^ " " ^ e.summary) then
              Some (World_retracted e)
            else None)
          retracted
      in
      a @ u @ r
  | ( (Some _ | None)
    , Some
        {
          scope = Wire_knowledge.Scope_world | Wire_knowledge.Scope_keeper _;
          body = Wire_knowledge.Keeper_diff _ | Wire_knowledge.World_diff _;
          _;
        } ) ->
      []

let filtered_memory_diff_items t =
  filtered_memory_diff_items_for ~keeper_opt:t.memory_diff_keeper t

let memory_diff_entry_count t = List.length (filtered_memory_diff_items t)

let selected_memory_diff_item_for ~keeper_opt t =
  let items = filtered_memory_diff_items_for ~keeper_opt t in
  List.nth_opt items (clamp_index (List.length items) t.selected_diff_index)

let selected_memory_diff_item t =
  selected_memory_diff_item_for ~keeper_opt:t.memory_diff_keeper t

let move_memory_diff_cursor ~delta t =
  let len = memory_diff_entry_count t in
  let selected_diff_index = clamp_index len (t.selected_diff_index + delta) in
  { t with selected_diff_index }

(* A [Memory_diff_dive] fetches into the [Window_revs] slot of its own
   revision range, which is not the slot of the Memory tab's window. Every
   reader of the dive's diff (render, scroll bound, cursor, Enter) goes
   through this scope; the tab keeps reading the unscoped [t]. *)
let scope_memory_diff_dive ~keeper ~from_rev ~to_rev t =
  {
    t with
    memory_diff_keeper = keeper;
    memory_diff_window = Window_revs { from_rev; to_rev };
  }

let move_memory_diff_dive_cursor ~keeper ~from_rev ~to_rev ~delta t =
  let moved =
    move_memory_diff_cursor ~delta
      (scope_memory_diff_dive ~keeper ~from_rev ~to_rev t)
  in
  { t with selected_diff_index = moved.selected_diff_index }

let json_has_kv_summary = function
  | `Assoc (_ :: _) -> true
  | `Assoc [] | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _
  | `Null ->
      false

let memory_diff_item_lines = function
  | Keeper_added _ | Keeper_retracted _ | Keeper_invalidated _ -> 2
  | Keeper_updated _ -> 3
  | World_added _ | World_retracted _ -> 1
  | World_updated u ->
      1
      + (if json_has_kv_summary u.before then 1 else 0)
      + (if json_has_kv_summary u.after then 1 else 0)

let memory_diff_line_count t =
  List.fold_left
    (fun acc it -> acc + memory_diff_item_lines it)
    0
    (filtered_memory_diff_items t)

let keeper_memory_diff_line_count ~name t =
  match
    Observed.to_option
      (memory_diff_for ~keeper:(Some name) ~window:t.memory_diff_window t)
  with
  | Some
      {
        scope = Wire_knowledge.Scope_keeper k;
        body =
          Wire_knowledge.Keeper_diff
            { added; updated; retracted; invalidated; _ };
        _;
      }
    when String.equal k name ->
      let total =
        (List.length added * 2)
        + (List.length updated * 3)
        + (List.length retracted * 2)
        + (List.length invalidated * 2)
      in
      if total = 0 then 1 else total
  | Some
      {
        scope = Wire_knowledge.Scope_world | Wire_knowledge.Scope_keeper _;
        body = Wire_knowledge.Keeper_diff _ | Wire_knowledge.World_diff _;
        _;
      }
  | None ->
      0

let reset_detail_scroll t = { t with detail_scroll_offset = 0 }

let active_list_len t =
  match t.active_tab with
  | Nav.Knowledge_board -> List.length (board_display_posts t)
  | Nav.Knowledge_wiki -> List.length (wiki_display_pages t)
  | Nav.Knowledge_artifacts -> List.length (artifacts_filtered t)
  | Nav.Knowledge_memory -> List.length (memory_left_rows t)

let move_selection ?(pane_index = 0) ?viewport_rows ?max_detail_scroll ~delta t =
  match t.active_tab with
  | Nav.Knowledge_board | Nav.Knowledge_wiki | Nav.Knowledge_artifacts ->
      if pane_index = 1 then
        let max_scroll =
          match max_detail_scroll with
          | Some ms -> max 0 ms
          | None -> (
              let vis =
                max 1
                  (Option.value viewport_rows
                     ~default:Store_scroll.default_viewport_rows)
              in
              match t.active_tab with
              | Nav.Knowledge_board -> (
                  match selected_post t with
                  | Some p ->
                      max 0 (List.length (String.split_on_char '\n' p.body) - vis)
                  | None -> 0)
              | Nav.Knowledge_wiki -> (
                  let body_opt =
                    Option.bind (selected_wiki_page t)
                      (fun (s : Wire_knowledge.wiki_page_summary) ->
                        Option.map
                          (fun (p : Wire_knowledge.wiki_page_detail) ->
                            p.body_markdown)
                          (Observed.to_option (wiki_page_for ~slug:s.slug t)))
                  in
                  match body_opt with
                  | Some body ->
                      max 0 (List.length (String.split_on_char '\n' body) - vis)
                  | None -> 0)
              | Nav.Knowledge_artifacts -> (
                  match selected_artifact t with
                  | Some a ->
                      let body_lines =
                        match artifact_detail_for_entry a t with
                        | Some d ->
                            List.length (String.split_on_char '\n' d.content)
                        | None -> 0
                      in
                      max 0 (8 + body_lines - vis)
                  | None -> 0)
              | Nav.Knowledge_memory -> 0)
        in
        let detail_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll (t.detail_scroll_offset + delta)
        in
        { t with detail_scroll_offset }
      else
        let len = active_list_len t in
        let selected_index = clamp_index len (t.selected_index + delta) in
        let header_row, vis_row = visual_row_for_selection t ~selected_index in
        let scroll_offset =
          adjust_grouped_scroll ?viewport_rows ~scroll:t.scroll_offset
            ~header_row vis_row
        in
        let detail_scroll_offset =
          if Int.equal selected_index t.selected_index then
            t.detail_scroll_offset
          else 0
        in
        let pending_wiki_edit_slug =
          if Int.equal selected_index t.selected_index then
            t.pending_wiki_edit_slug
          else None
        in
        {
          t with
          selected_index;
          scroll_offset;
          detail_scroll_offset;
          pending_wiki_edit_slug;
          pending_artifact_revision =
            (if Int.equal selected_index t.selected_index then
               t.pending_artifact_revision
             else None);
          armed_vote =
            (if Int.equal selected_index t.selected_index then t.armed_vote
            else None);
        }
  | Nav.Knowledge_memory ->
      if pane_index = 1 then
        match t.memory_diagram with
        | Some d
          when memory_diagram_matches_scope ~keeper_opt:t.memory_diff_keeper d
          ->
            let max_scroll = Option.value max_detail_scroll ~default:0 in
            scroll_memory_diagram ~max_scroll ~delta t
        | Some _ | None -> (
            match t.memory_reading with
            | Some entry
              when memory_reading_matches_scope ~keeper_opt:t.memory_diff_keeper
                     entry ->
                let max_scroll = Option.value max_detail_scroll ~default:0 in
                scroll_memory_reading ~max_scroll ~delta t
            | Some _ | None -> (
                match t.memory_diff_keeper, t.memory_view_mode with
                | Some kp, View_evolution ->
                    move_memory_activity ~keeper:kp ?viewport_rows ~delta t
                | Some kp, View_facts ->
                    move_memory_facts ~keeper:kp ?viewport_rows ~delta t
                | Some _, View_diff
                | None, (View_evolution | View_facts | View_diff) ->
                    let max_scroll =
                      match max_detail_scroll with
                      | Some ms -> max 0 ms
                      | None ->
                          let vis =
                            max 1
                              (Option.value viewport_rows
                                 ~default:Store_scroll.default_viewport_rows)
                          in
                          max 0 (memory_diff_line_count t - vis)
                    in
                    let diff_scroll_offset =
                      Store_scroll.clamp_scroll ~max_scroll
                        (t.diff_scroll_offset + delta)
                    in
                    let entry_delta =
                      let ad = abs delta in
                      if ad <= 1 || ad >= 100_000 then delta
                      else
                        let step = max 1 (ad / 3) in
                        if delta < 0 then -step else step
                    in
                    let selected_diff_index =
                      clamp_index (memory_diff_entry_count t)
                        (t.selected_diff_index + entry_delta)
                    in
                    { t with diff_scroll_offset; selected_diff_index }))
      else
        let len = active_list_len t in
        let selected_index = clamp_index len (t.selected_index + delta) in
        let scroll_offset =
          Store_scroll.adjust_scroll ?viewport_rows ~scroll:t.scroll_offset
            selected_index
        in
        let moved = { t with selected_index; scroll_offset } in
        match selected_memory_left_row moved with
        | Some Left_world_scope -> set_memory_diff_keeper None moved
        | Some (Left_writer w) -> set_memory_diff_keeper (Some w.keeper) moved
        | Some (Left_conflict _) | None -> moved

let set_filter filter_query t =
  {
    t with
    filter_query;
    armed_vote = None;
    pending_artifact_revision = None;
    selected_index = 0;
    scroll_offset = 0;
    diff_scroll_offset = 0;
    detail_scroll_offset = 0;
    selected_fact_index = 0;
    facts_scroll_offset = 0;
    selected_activity_index = 0;
    activity_scroll_offset = 0;
    selected_diff_index = 0;
    memory_reading = None;
    memory_reading_scroll = 0;
    memory_diagram = None;
    pending_wiki_edit_slug = None;
  }

let mark_stale_all t =
  {
    t with
    board = Observed.mark_stale t.board;
    board_hearths = Observed.mark_stale t.board_hearths;
    active_thread = Observed.mark_stale t.active_thread;
    wiki_index = Observed.mark_stale t.wiki_index;
    wiki_pages = String_map.map Observed.mark_stale t.wiki_pages;
    wiki_log = Observed.mark_stale t.wiki_log;
    wiki_lint = Observed.mark_stale t.wiki_lint;
    artifacts = Observed.mark_stale t.artifacts;
    active_artifact_detail = Observed.mark_stale t.active_artifact_detail;
    pending_artifact_revision = None;
    artifact_checks = Observed.mark_stale t.artifact_checks;
    world_memory = Observed.mark_stale t.world_memory;
    memory_diffs = Memory_diff_map.map Observed.mark_stale t.memory_diffs;
    memory_os_internals =
      String_map.map Observed.mark_stale t.memory_os_internals;
    keeper_memory_facts =
      String_map.map Observed.mark_stale t.keeper_memory_facts;
    keeper_memory_activity =
      String_map.map Observed.mark_stale t.keeper_memory_activity;
    keeper_memory_health = Observed.mark_stale t.keeper_memory_health;
    memory_health_keeper = Observed.mark_stale t.memory_health_keeper;
    workspace_memory_ledger = Observed.mark_stale t.workspace_memory_ledger;
    workspace_memory_ledger_auth_denied = false;
    workspace_memory_context = Observed.mark_stale t.workspace_memory_context;
    workspace_memory_context_auth_denied = false;
    keeper_memory_facts_auth_denied = String_set.empty;
    keeper_memory_journal = Observed.mark_stale t.keeper_memory_journal;
    keeper_memory_journal_auth_denied = String_set.empty;
  }

let memory_subview_rank = function
  | Mem_diff_flow -> 0
  | Mem_health_ledger -> 1
  | Mem_context -> 2

let equal_memory_subview a b =
  Int.equal (memory_subview_rank a) (memory_subview_rank b)

let set_memory_subview memory_subview t =
  { t with memory_subview; memory_subview_scroll = 0; diff_scroll_offset = 0 }

let cycle_memory_subview t =
  let next =
    match t.memory_subview with
    | Mem_diff_flow -> Mem_health_ledger
    | Mem_health_ledger -> Mem_context
    | Mem_context -> Mem_diff_flow
  in
  set_memory_subview next t

let keeper_memory_subview_rank = function
  | Kmem_diff_flow -> 0
  | Kmem_health -> 1
  | Kmem_facts_tree -> 2
  | Kmem_journal -> 3

let equal_keeper_memory_subview a b =
  Int.equal (keeper_memory_subview_rank a) (keeper_memory_subview_rank b)

let set_keeper_memory_subview keeper_memory_subview t =
  {
    t with
    keeper_memory_subview;
    memory_subview_scroll = 0;
    facts_selected_index = 0;
  }

let cycle_keeper_memory_subview t =
  let next =
    match t.keeper_memory_subview with
    | Kmem_diff_flow -> Kmem_health
    | Kmem_health -> Kmem_facts_tree
    | Kmem_facts_tree -> Kmem_journal
    | Kmem_journal -> Kmem_diff_flow
  in
  set_keeper_memory_subview next t

let apply_memory_health_fleet ~observed_at fleet t =
  apply_keeper_memory_health ~observed_at fleet t

let keeper_matches_slot ~active_keeper ~keeper slot t =
  let expected =
    match active_keeper with
    | Some active -> Some active
    | None -> (
        match t.memory_diff_keeper with
        | Some _ as k -> k
        | None -> (
            match Observed.to_option slot with
            | Some (k, _) -> Some k
            | None -> None))
  in
  match expected with
  | None -> true
  | Some exp -> String.equal exp keeper

let apply_memory_health_keeper ~observed_at ~keeper row t =
  { t with memory_health_keeper = Observed.value ~observed_at (keeper, row) }

let mark_memory_health_keeper_failed ~at ?active_keeper ~keeper ~reason
    ~retryable t =
  if not (keeper_matches_slot ~active_keeper ~keeper t.memory_health_keeper t)
  then t
  else
    { t with memory_health_keeper = Observed.failed ~reason ~retryable ~at }

let apply_workspace_memory_ledger ~observed_at ledger t =
  {
    t with
    workspace_memory_ledger = Observed.value ~observed_at ledger;
    workspace_memory_ledger_auth_denied = false;
  }

let mark_workspace_memory_ledger_failed ~at ~reason ~retryable ~auth_denied t =
  {
    t with
    workspace_memory_ledger = Observed.failed ~reason ~retryable ~at;
    workspace_memory_ledger_auth_denied =
      t.workspace_memory_ledger_auth_denied || auth_denied;
  }

let apply_workspace_memory_context ~observed_at ctx t =
  {
    t with
    workspace_memory_context = Observed.value ~observed_at ctx;
    workspace_memory_context_auth_denied = false;
  }

let mark_workspace_memory_context_failed ~at ~reason ~retryable ~auth_denied t =
  {
    t with
    workspace_memory_context = Observed.failed ~reason ~retryable ~at;
    workspace_memory_context_auth_denied =
      t.workspace_memory_context_auth_denied || auth_denied;
  }

let mark_keeper_memory_facts_failed ~at ?active_keeper ~keeper ~reason
    ~retryable ~auth_denied t =
  let _ = active_keeper in
  let keeper_memory_facts_auth_denied =
    if auth_denied then String_set.add keeper t.keeper_memory_facts_auth_denied
    else t.keeper_memory_facts_auth_denied
  in
  {
    t with
    keeper_memory_facts =
      String_map.add keeper (Observed.failed ~reason ~retryable ~at)
        t.keeper_memory_facts;
    keeper_memory_facts_auth_denied;
  }

let apply_keeper_memory_journal ~observed_at ~keeper journal t =
  {
    t with
    keeper_memory_journal = Observed.value ~observed_at (keeper, journal);
    keeper_memory_journal_auth_denied =
      String_set.remove keeper t.keeper_memory_journal_auth_denied;
  }

let mark_keeper_memory_journal_failed ~at ?active_keeper ~keeper ~reason
    ~retryable ~auth_denied t =
  let keeper_memory_journal_auth_denied =
    if auth_denied then
      String_set.add keeper t.keeper_memory_journal_auth_denied
    else t.keeper_memory_journal_auth_denied
  in
  if not (keeper_matches_slot ~active_keeper ~keeper t.keeper_memory_journal t)
  then { t with keeper_memory_journal_auth_denied }
  else
    {
      t with
      keeper_memory_journal = Observed.failed ~reason ~retryable ~at;
      keeper_memory_journal_auth_denied;
    }

let memory_health_for_keeper ~keeper t =
  match Observed.to_option t.memory_health_keeper with
  | Some (k, Some row) when String.equal k keeper -> Some row
  | Some (_, None) | Some _ | None -> (
      match Observed.to_option t.keeper_memory_health with
      | Some fl ->
          List.find_opt
            (fun (r : Wire_knowledge.keeper_memory_health_row) ->
              String.equal r.keeper_id keeper)
            fl.keepers
      | None -> None)

let memory_facts_for_keeper ~keeper t =
  match Observed.to_option (keeper_memory_facts_for ~keeper t) with
  | Some facts when String.equal facts.keeper keeper -> Some facts
  | Some _ | None -> None

let memory_journal_for_keeper ~keeper t =
  match Observed.to_option t.keeper_memory_journal with
  | Some (k, j) when String.equal k keeper -> Some j
  | Some _ | None -> None

let toggle_fact_category cat t =
  let collapsed_fact_categories =
    if String_set.mem cat t.collapsed_fact_categories then
      String_set.remove cat t.collapsed_fact_categories
    else String_set.add cat t.collapsed_fact_categories
  in
  { t with collapsed_fact_categories }

let move_memory_subview_scroll ?(max_scroll = 0) ~delta t =
  let memory_subview_scroll =
    Store_scroll.clamp_scroll ~max_scroll:(max 0 max_scroll)
      (t.memory_subview_scroll + delta)
  in
  { t with memory_subview_scroll }

let move_facts_selection ~count ~delta t =
  { t with facts_selected_index = clamp_index count (t.facts_selected_index + delta) }
