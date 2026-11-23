open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

module String_set = Set.Make (String)

type memory_diff_window =
  | Window_24h
  | Window_7d
  | Window_30d
  | Window_revs of { from_rev : int; to_rev : int }

type wiki_edit_draft = {
  slug : string;
  expected_revision : int option;
  expected_sha256 : string option;
  title : string;
  summary : string;
  source : Wire_knowledge.wiki_source;
  tags : string list;
  body : string;
  note : string;
  dirty : bool;
  saving : bool;
}

type t = {
  active_tab : Nav.knowledge_tab;
  board : Wire_knowledge.board_feed Observed.t;
  board_signal_only : bool;
  board_sort_by : string;
  board_hearth : string option;
  expanded_succession_chains : String_set.t;
  active_thread :
    (Wire_knowledge.board_post * Wire_knowledge.board_comment list) Observed.t;
  quarantines : Wire_knowledge.quarantine_candidate list Observed.t;
  wiki_artifacts_submode : [ `Wiki | `Artifacts ];
  wiki_index : Wire_knowledge.wiki_index Observed.t;
  wiki_page : Wire_knowledge.wiki_page_detail Observed.t;
  wiki_log : Wire_knowledge.wiki_log_response Observed.t;
  wiki_search : Wire_knowledge.wiki_search_response Observed.t;
  wiki_lint : Wire_knowledge.wiki_lint_report Observed.t;
  wiki_edit_draft : wiki_edit_draft option;
  artifacts : Wire_knowledge.artifact_entry list Observed.t;
  world_memory : Wire_knowledge.world_memory Observed.t;
  memory_diff : Wire_knowledge.memory_diff Observed.t;
  memory_os_internals : Wire_knowledge.memory_os_internals Observed.t;
  memory_diff_window : memory_diff_window;
  memory_diff_keeper : string option;
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
    board = Observed.unreported;
    board_signal_only = true;
    board_sort_by = "recent";
    board_hearth = None;
    expanded_succession_chains = String_set.empty;
    active_thread = Observed.absent;
    quarantines = Observed.unreported;
    wiki_artifacts_submode = `Wiki;
    wiki_index = Observed.unreported;
    wiki_page = Observed.absent;
    wiki_log = Observed.unreported;
    wiki_search = Observed.absent;
    wiki_lint = Observed.unreported;
    wiki_edit_draft = None;
    artifacts = Observed.unreported;
    world_memory = Observed.unreported;
    memory_diff = Observed.unreported;
    memory_os_internals = Observed.unreported;
    memory_diff_window = Window_24h;
    memory_diff_keeper = None;
    last_memory_act_answer = None;
    selected_index = 0;
    scroll_offset = 0;
    diff_scroll_offset = 0;
    detail_scroll_offset = 0;
    pulse_thread_index = 0;
    filter_query = "";
  }

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
  | Nav.Knowledge_wiki_artifacts -> (
      match t.wiki_artifacts_submode with
      | `Wiki ->
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
      | `Artifacts -> (selected_index, selected_index))
  | Nav.Knowledge_memory -> (selected_index, selected_index)

let selected_post t =
  let ps = board_display_posts t in
  List.nth_opt ps (clamp_index (List.length ps) t.selected_index)

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
    selected_index = 0;
    scroll_offset = 0;
    diff_scroll_offset = 0;
    detail_scroll_offset = 0;
  }

let cycle_tab dir t =
  let next_tab =
    match dir with
    | Keymap.Next -> Nav.next_knowledge_tab t.active_tab
    | Keymap.Prev -> Nav.prev_knowledge_tab t.active_tab
  in
  set_tab next_tab t

let toggle_wiki_artifacts_submode t =
  let wiki_artifacts_submode =
    match t.wiki_artifacts_submode with `Wiki -> `Artifacts | `Artifacts -> `Wiki
  in
  {
    t with
    wiki_artifacts_submode;
    selected_index = 0;
    scroll_offset = 0;
    detail_scroll_offset = 0;
  }

let toggle_signal_only t =
  {
    t with
    board_signal_only = not t.board_signal_only;
    board = Observed.mark_stale t.board;
    selected_index = 0;
    scroll_offset = 0;
  }

let set_board_sort board_sort_by t =
  { t with board_sort_by; board = Observed.mark_stale t.board }

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
  { t with memory_diff_window; memory_diff = Observed.mark_stale t.memory_diff }

let cycle_memory_diff_window t =
  let next =
    match t.memory_diff_window with
    | Window_24h -> Window_7d
    | Window_7d -> Window_30d
    | Window_30d -> Window_24h
    | Window_revs _ -> Window_24h
  in
  set_memory_diff_window next t

let set_memory_diff_keeper memory_diff_keeper t =
  {
    t with
    memory_diff_keeper;
    memory_diff = Observed.mark_stale t.memory_diff;
    memory_os_internals = Observed.mark_stale t.memory_os_internals;
  }

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

let apply_thread ~observed_at thread t =
  { t with active_thread = Observed.value ~observed_at thread }

let apply_quarantines ~observed_at quarantines t =
  { t with quarantines = Observed.value ~observed_at quarantines }

let apply_wiki_index ~observed_at idx t =
  let on_wiki =
    Nav.equal_knowledge_tab t.active_tab Nav.Knowledge_wiki_artifacts
    &&
    match t.wiki_artifacts_submode with `Wiki -> true | `Artifacts -> false
  in
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

let apply_wiki_page ~observed_at page t =
  { t with wiki_page = Observed.value ~observed_at page }

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

let apply_memory_diff ~observed_at diff t =
  { t with memory_diff = Observed.value ~observed_at diff }

let apply_memory_os_internals ~observed_at internals t =
  { t with memory_os_internals = Observed.value ~observed_at internals }

let record_memory_act_answer ~keeper ans t =
  { t with last_memory_act_answer = Some (keeper, ans) }

let begin_wiki_edit (page : Wire_knowledge.wiki_page_detail) t =
  let draft =
    {
      slug = page.slug;
      expected_revision = Some page.frontmatter.revision;
      expected_sha256 = Some page.sha256;
      title = page.frontmatter.title;
      summary = page.frontmatter.summary;
      source = page.frontmatter.source;
      tags = page.frontmatter.tags;
      body = page.body_markdown;
      note = "";
      dirty = false;
      saving = false;
    }
  in
  { t with wiki_edit_draft = Some draft }

let update_wiki_edit_body body t =
  match t.wiki_edit_draft with
  | None -> t
  | Some d -> { t with wiki_edit_draft = Some { d with body; dirty = true } }

let update_wiki_edit_note note t =
  match t.wiki_edit_draft with
  | None -> t
  | Some d -> { t with wiki_edit_draft = Some { d with note; dirty = true } }

let mark_wiki_edit_saving saving t =
  match t.wiki_edit_draft with
  | None -> t
  | Some d -> { t with wiki_edit_draft = Some { d with saving } }

let cancel_wiki_edit t = { t with wiki_edit_draft = None }

let wiki_put_request_of_draft (d : wiki_edit_draft) :
    Wire_knowledge.wiki_put_request =
  {
    expected_revision = d.expected_revision;
    expected_sha256 = d.expected_sha256;
    title = d.title;
    summary = d.summary;
    source = d.source;
    tags = d.tags;
    body = d.body;
    note =
      if String.equal (String.trim d.note) "" then "Edited in MASC TUI"
      else d.note;
  }

let quarantines_list t =
  match Observed.to_option t.quarantines with Some xs -> xs | None -> []

let artifacts_filtered t =
  let items =
    match Observed.to_option t.artifacts with Some xs -> xs | None -> []
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then items
  else
    List.filter
      (fun (a : Wire_knowledge.artifact_entry) ->
        contains_ci ~needle:q a.name || contains_ci ~needle:q a.sha256)
      items

let selected_artifact t =
  let items = artifacts_filtered t in
  List.nth_opt items (clamp_index (List.length items) t.selected_index)

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

type memory_diff_item =
  | Keeper_added of Wire_knowledge.memory_fact_entry
  | Keeper_updated of Wire_knowledge.memory_updated_fact
  | Keeper_retracted of Wire_knowledge.memory_retracted_fact
  | Keeper_invalidated of Wire_knowledge.memory_invalidated_fact
  | World_added of Wire_knowledge.world_change_entry
  | World_updated of Wire_knowledge.world_updated_entry
  | World_retracted of Wire_knowledge.world_change_entry

let filtered_memory_diff_items t =
  match Observed.to_option t.memory_diff with
  | None -> []
  | Some
      {
        body =
          Wire_knowledge.Keeper_diff
            { added; updated; retracted; invalidated; _ };
        _;
      } ->
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
                (rf.category ^ " " ^ rf.removed_by ^ " " ^ rf.text)
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
      a @ u @ r @ inv
  | Some
      {
        body = Wire_knowledge.World_diff { added; updated; retracted; _ };
        _;
      } ->
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

let memory_diff_entry_count t = List.length (filtered_memory_diff_items t)

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
  match Observed.to_option t.memory_diff with
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
  | Nav.Knowledge_wiki_artifacts -> (
      match t.wiki_artifacts_submode with
      | `Wiki -> List.length (wiki_display_pages t)
      | `Artifacts -> List.length (artifacts_filtered t))
  | Nav.Knowledge_memory ->
      let conflicts = filtered_memory_conflicts t in
      if conflicts <> [] then List.length conflicts
      else List.length (filtered_librarian_writers t)

let move_selection ?(pane_index = 0) ?viewport_rows ?max_detail_scroll ~delta t =
  match t.active_tab with
  | Nav.Knowledge_board | Nav.Knowledge_wiki_artifacts ->
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
              | Nav.Knowledge_wiki_artifacts -> (
                  match t.wiki_artifacts_submode with
                  | `Wiki -> (
                      let body_opt =
                        match t.wiki_edit_draft with
                        | Some d -> Some d.body
                        | None ->
                            Option.map
                              (fun (p : Wire_knowledge.wiki_page_detail) ->
                                p.body_markdown)
                              (Observed.to_option t.wiki_page)
                      in
                      match body_opt with
                      | Some body ->
                          max 0 (List.length (String.split_on_char '\n' body) - vis)
                      | None -> 0)
                  | `Artifacts -> (
                      match selected_artifact t with
                      | Some _ -> max 0 (12 - vis)
                      | None -> 0))
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
        { t with selected_index; scroll_offset; detail_scroll_offset }
  | Nav.Knowledge_memory ->
      if pane_index = 1 then
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
          Store_scroll.clamp_scroll ~max_scroll (t.diff_scroll_offset + delta)
        in
        { t with diff_scroll_offset }
      else
        let len = active_list_len t in
        let selected_index = clamp_index len (t.selected_index + delta) in
        let scroll_offset =
          Store_scroll.adjust_scroll ?viewport_rows ~scroll:t.scroll_offset
            selected_index
        in
        { t with selected_index; scroll_offset }

let set_filter filter_query t =
  {
    t with
    filter_query;
    selected_index = 0;
    scroll_offset = 0;
    diff_scroll_offset = 0;
    detail_scroll_offset = 0;
  }

let mark_stale_all t =
  {
    t with
    board = Observed.mark_stale t.board;
    active_thread = Observed.mark_stale t.active_thread;
    quarantines = Observed.mark_stale t.quarantines;
    wiki_index = Observed.mark_stale t.wiki_index;
    wiki_page = Observed.mark_stale t.wiki_page;
    wiki_log = Observed.mark_stale t.wiki_log;
    wiki_lint = Observed.mark_stale t.wiki_lint;
    artifacts = Observed.mark_stale t.artifacts;
    world_memory = Observed.mark_stale t.world_memory;
    memory_diff = Observed.mark_stale t.memory_diff;
    memory_os_internals = Observed.mark_stale t.memory_os_internals;
  }
