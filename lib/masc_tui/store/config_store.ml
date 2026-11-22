open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

module String_map = Map.Make (String)
module String_set = Set.Make (String)

type settings_pane =
  | Pane_tree
  | Pane_inspector

type settings_tree_section = {
  section_id : string;
  category : Wire_config.config_category;
  tab : Nav.settings_tab;
  title : string;
  subtitle : string;
  is_catalog_group : bool;
  badge_count : int;
  dirty_count : int;
  provenance : Wire_config.provenance;
  reload_scope : Wire_config.reload_scope;
  fields : Wire_config.schema_field list;
}

type settings_tree_row =
  | Tree_category of {
      category : Wire_config.config_category;
      tab : Nav.settings_tab;
      collapsed : bool;
      section_count : int;
      field_count : int;
      dirty_count : int;
    }
  | Tree_models_catalog_toggle of {
      expanded : bool;
      model_count : int;
      dirty_count : int;
    }
  | Tree_section of settings_tree_section

type dry_run_state =
  | Dry_run_idle
  | Dry_run_loading
  | Dry_run_ready of Wire_config.patch_response
  | Dry_run_failed of string

type save_state =
  | Save_idle
  | Save_in_flight
  | Save_succeeded of Wire_config.patch_response
  | Save_failed of string

type t = {
  active_tab : Nav.settings_tab;
  target : Wire_config.config_target;
  preferences : Wire_config.tui_preferences Observed.t;
  schema : Wire_config.config_schema Observed.t;
  field_meta : Wire_config.field_entity_meta String_map.t;
  search_query : string;
  dirty_fields : Wire_config.patch_op String_map.t;
  dry_run_preview : dry_run_state;
  save_state : save_state;
  last_snapshot_id : string option;
  new_keeper_name : string;
  settings_pane : settings_pane;
  selected_section_idx : int;
  tree_scroll_offset : int;
  collapsed_categories : String_set.t;
  models_catalog_expanded : bool;
  selected_field_index : int;
  scroll_offset : int;
  editing_field_key : string option;
  editing_buffer : string;
}

let all_categories_ordered =
  [
    Wire_config.Cat_general_ui;
    Wire_config.Cat_providers_models;
    Wire_config.Cat_routing_failover;
    Wire_config.Cat_keepers_companies;
    Wire_config.Cat_sandbox_ssh;
    Wire_config.Cat_voice_integrations;
    Wire_config.Cat_board_memory_candle;
  ]

let default_collapsed_for_tab tab =
  let active_id =
    Wire_config.config_category_to_string
      (Wire_config.category_of_settings_tab tab)
  in
  List.fold_left
    (fun acc cat ->
      let cid = Wire_config.config_category_to_string cat in
      if String.equal cid active_id then acc else String_set.add cid acc)
    String_set.empty all_categories_ordered

let empty =
  {
    active_tab = Nav.Settings_general_ui;
    target = Wire_config.Target_runtime;
    preferences = Observed.unreported;
    schema = Observed.unreported;
    field_meta = String_map.empty;
    search_query = "";
    dirty_fields = String_map.empty;
    dry_run_preview = Dry_run_idle;
    save_state = Save_idle;
    last_snapshot_id = None;
    new_keeper_name = "";
    settings_pane = Pane_inspector;
    selected_section_idx = 0;
    tree_scroll_offset = 0;
    collapsed_categories = default_collapsed_for_tab Nav.Settings_general_ui;
    models_catalog_expanded = false;
    selected_field_index = 0;
    scroll_offset = 0;
    editing_field_key = None;
    editing_buffer = "";
  }

let contains_ci ~needle haystack =
  let n_len = String.length needle in
  if n_len = 0 then true
  else
    let h_len = String.length haystack in
    if n_len > h_len then false
    else
      let n_low = String.lowercase_ascii needle in
      let h_low = String.lowercase_ascii haystack in
      let limit = h_len - n_len in
      let rec scan i =
        if i > limit then false
        else if String.equal (String.sub h_low i n_len) n_low then true
        else scan (i + 1)
      in
      scan 0

let clamp_index len idx =
  if len <= 0 then 0
  else if idx < 0 then 0
  else if idx >= len then len - 1
  else idx

let equal_config_target a b =
  match a, b with
  | Wire_config.Target_runtime, Wire_config.Target_runtime
  | Wire_config.Target_keeper_create, Wire_config.Target_keeper_create ->
      true
  | Wire_config.Target_keeper x, Wire_config.Target_keeper y -> String.equal x y
  | Wire_config.Target_runtime, (Wire_config.Target_keeper _ | Wire_config.Target_keeper_create)
  | Wire_config.Target_keeper _, (Wire_config.Target_runtime | Wire_config.Target_keeper_create)
  | Wire_config.Target_keeper_create, (Wire_config.Target_runtime | Wire_config.Target_keeper _) ->
      false

let equal_settings_pane a b =
  match (a, b) with
  | Pane_tree, Pane_tree | Pane_inspector, Pane_inspector -> true
  | Pane_tree, Pane_inspector | Pane_inspector, Pane_tree -> false

let equal_config_category a b =
  String.equal
    (Wire_config.config_category_to_string a)
    (Wire_config.config_category_to_string b)

let strip_toml_quotes s =
  let t = String.trim s in
  let len = String.length t in
  if
    len >= 2
    && ((t.[0] = '"' && t.[len - 1] = '"') || (t.[0] = '\'' && t.[len - 1] = '\''))
  then String.sub t 1 (len - 2)
  else t

let split_table_segments table = Wire_config.split_dotted_segments table

let title_case_segment s =
  String.split_on_char '_' s
  |> List.concat_map (String.split_on_char '-')
  |> List.filter (fun w -> not (String.equal w ""))
  |> List.map String.capitalize_ascii
  |> String.concat " "

let field_label ~lang f = Wire_config.field_leaf_label ~lang f

let field_sub_group t (f : Wire_config.schema_field) =
  match String_map.find_opt f.full_key t.field_meta with
  | Some { sub_group = Some sg; _ } ->
      if String.equal (String.lowercase_ascii (String.trim sg)) "model_bindings"
      then
        match Wire_config.split_dotted_segments f.table with
        | _ :: model_id :: _ when not (String.equal model_id "") ->
            Some ("binding:" ^ model_id)
        | _ -> Some sg
      else Some sg
  | Some { sub_group = None; _ } | None -> Wire_config.field_sub_group f

let reload_rank = function
  | Wire_config.Hot_reload -> 0
  | Wire_config.Next_turn -> 1
  | Wire_config.Restart_required -> 2

let max_reload a b = if reload_rank a >= reload_rank b then a else b

let prov_rank = function
  | Wire_config.Prov_default -> 0
  | Wire_config.Prov_global -> 1
  | Wire_config.Prov_project -> 2
  | Wire_config.Prov_keeper -> 3
  | Wire_config.Prov_env_override -> 4

let dominant_provenance fields =
  List.fold_left
    (fun best (f : Wire_config.schema_field) ->
      if prov_rank f.provenance > prov_rank best then f.provenance else best)
    Wire_config.Prov_default fields

let dominant_reload_scope fields =
  List.fold_left
    (fun best (f : Wire_config.schema_field) -> max_reload best f.reload_scope)
    Wire_config.Hot_reload fields

let field_matches_query ~q (f : Wire_config.schema_field) =
  contains_ci ~needle:q f.full_key
  || contains_ci ~needle:q f.label
  || contains_ci ~needle:q (Wire_config.field_leaf_label ~lang:Say.Lang_ko f)
  || contains_ci ~needle:q (Wire_config.field_leaf_label ~lang:Say.Lang_en f)
  ||
  match f.description with
  | Some d -> contains_ci ~needle:q d
  | None -> false

let tree_sections t =
  match Observed.to_option t.schema with
  | None -> []
  | Some schema ->
      let q = String.trim t.search_query in
      let all_fields_with_cat =
        List.concat_map
          (fun (s : Wire_config.schema_section) ->
            List.map (fun f -> (s.category, f)) s.fields)
          schema.sections
      in
      let known_provider_ids : (string, unit) Hashtbl.t = Hashtbl.create 32 in
      let provider_titles : (string, string) Hashtbl.t = Hashtbl.create 32 in
      List.iter
        (fun (_, (f : Wire_config.schema_field)) ->
          match split_table_segments f.table with
          | "providers" :: pid :: rest when not (String.equal pid "") ->
              Hashtbl.replace known_provider_ids pid ();
              let leaf = String.lowercase_ascii (strip_toml_quotes f.key) in
              if
                rest = []
                && (String.equal leaf "display-name"
                   || String.equal leaf "display_name")
              then (
                match f.value with
                | Wire_config.Val_string s
                  when not (String.equal (String.trim s) "") ->
                    Hashtbl.replace provider_titles pid (String.trim s)
                | Wire_config.Val_string _
                | Wire_config.Val_bool _
                | Wire_config.Val_int _
                | Wire_config.Val_float _
                | Wire_config.Val_string_list _
                | Wire_config.Val_structured _
                | Wire_config.Val_secret _
                | Wire_config.Val_null ->
                    ())
          | _ -> ())
        all_fields_with_cat;
      let is_hex8_token s =
        String.length s = 8
        &&
        let rec loop i =
          if i >= 8 then true
          else
            match s.[i] with
            | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> loop (i + 1)
            | _ -> false
        in
        loop 0
      in
      let is_raw_or_titlecased_hex_slug ~pid disp =
        let d = String.trim disp in
        if String.equal d "" || String.equal d pid then true
        else
          let tokens_of s =
            String.lowercase_ascii s
            |> String.split_on_char '_'
            |> List.concat_map (String.split_on_char '-')
            |> List.concat_map (String.split_on_char ' ')
            |> List.filter (fun w -> not (String.equal w ""))
          in
          match List.rev (tokens_of pid) with
          | last :: _ when is_hex8_token last ->
              List.equal String.equal (tokens_of d) (tokens_of pid)
          | _ -> false
      in
      let usable_display_name ~pid raw =
        let trimmed = String.trim raw in
        if String.equal trimmed "" || is_raw_or_titlecased_hex_slug ~pid trimmed
        then None
        else Some trimmed
      in
      let provider_title ?explicit pid =
        let display_name =
          match Option.bind explicit (usable_display_name ~pid) with
          | Some _ as d -> d
          | None ->
              Option.bind
                (Hashtbl.find_opt provider_titles pid)
                (usable_display_name ~pid)
        in
        Wire_runtime.human_provider_id_label ?display_name pid
      in
      let classify_field cat (f : Wire_config.schema_field) =
        let from_meta =
          match String_map.find_opt f.full_key t.field_meta with
          | Some { entity_group = Some eg; entity_title; _ }
            when not (String.equal (String.trim eg) "") ->
              let eg = String.trim eg in
              if String.starts_with ~prefix:"provider:" eg then
                let pid = String.sub eg 9 (String.length eg - 9) in
                let title = provider_title ?explicit:entity_title pid in
                Some
                  ( eg
                  , Wire_config.Cat_providers_models
                  , title
                  , "providers." ^ pid
                  , false )
              else if String.starts_with ~prefix:"model:" eg then
                let mid = String.sub eg 6 (String.length eg - 6) in
                let title =
                  match entity_title with
                  | Some et when not (String.equal (String.trim et) "") ->
                      String.trim et
                  | Some _ | None -> mid
                in
                Some
                  ( eg
                  , Wire_config.Cat_providers_models
                  , title
                  , "models." ^ mid
                  , true )
              else if
                String.starts_with ~prefix:"section:" eg
                && equal_config_category cat Wire_config.Cat_providers_models
              then
                let pid = String.sub eg 8 (String.length eg - 8) in
                let title = provider_title ?explicit:entity_title pid in
                let subtitle =
                  if String.equal (String.trim f.table) "" then eg else f.table
                in
                Some (eg, cat, title, subtitle, false)
              else
                let title =
                  match entity_title with
                  | Some et when not (String.equal (String.trim et) "") ->
                      String.trim et
                  | Some _ | None -> title_case_segment eg
                in
                let subtitle =
                  if String.equal (String.trim f.table) "" then eg else f.table
                in
                Some (eg, cat, title, subtitle, false)
          | Some _ | None -> None
        in
        match from_meta with
        | Some res -> res
        | None -> (
        match split_table_segments f.table with
        | "providers" :: pid :: _ when not (String.equal pid "") ->
            ( "provider:" ^ pid
            , Wire_config.Cat_providers_models
            , provider_title pid
            , "providers." ^ pid
            , false )
        | pid :: _ when Hashtbl.mem known_provider_ids pid ->
            ( "provider:" ^ pid
            , Wire_config.Cat_providers_models
            , provider_title pid
            , "providers." ^ pid
            , false )
        | "models" :: mid :: _ when not (String.equal mid "") ->
            ( "model:" ^ mid
            , Wire_config.Cat_providers_models
            , mid
            , "models." ^ mid
            , true )
        | "runtime" :: "lanes" :: lid :: _ when not (String.equal lid "") ->
            ( "lane:" ^ lid
            , Wire_config.Cat_routing_failover
            , lid
            , "runtime.lanes." ^ lid
            , false )
        | "runtime" :: "exact_output_lanes" :: lid :: _
          when not (String.equal lid "") ->
            ( "exact_lane:" ^ lid
            , Wire_config.Cat_routing_failover
            , "Exact · " ^ lid
            , "runtime.exact_output_lanes." ^ lid
            , false )
        | "runtime" :: "addon_exact_lanes" :: lid :: _
          when not (String.equal lid "") ->
            ( "addon_lane:" ^ lid
            , Wire_config.Cat_routing_failover
            , "Addon · " ^ lid
            , "runtime.addon_exact_lanes." ^ lid
            , false )
        | "runtime" :: "assignments" :: _ ->
            ( "runtime:assignments"
            , Wire_config.Cat_routing_failover
            , "Keeper Assignments"
            , "runtime.assignments"
            , false )
        | "runtime" :: _ ->
            ( "runtime:default"
            , Wire_config.Cat_routing_failover
            , "Default Routing"
            , "runtime"
            , false )
        | "fusion" :: _ ->
            ("fusion", Wire_config.Cat_routing_failover, "Fusion", "fusion", false)
        | "exec" :: "ssh" :: ("pools" | "endpoints") :: pool :: _
          when not (String.equal pool "") ->
            ( "ssh_pool:" ^ pool
            , Wire_config.Cat_sandbox_ssh
            , "SSH · " ^ pool
            , "exec.ssh.pools." ^ pool
            , false )
        | "exec" :: "ssh" :: _ ->
            ("ssh:global", Wire_config.Cat_sandbox_ssh, "SSH Global", "exec.ssh", false)
        | "sandbox" :: _ ->
            ("sandbox", Wire_config.Cat_sandbox_ssh, "microVM Sandbox", "sandbox", false)
        | "voice" :: _ ->
            ("voice", Wire_config.Cat_voice_integrations, "Voice TTS/STT", "voice", false)
        | "slack" :: _ ->
            ("slack", Wire_config.Cat_voice_integrations, "Slack", "slack", false)
        | "discord" :: _ ->
            ("discord", Wire_config.Cat_voice_integrations, "Discord", "discord", false)
        | "browser" :: _ ->
            ("browser", Wire_config.Cat_voice_integrations, "Browser", "browser", false)
        | "candle" :: _ ->
            ("candle", Wire_config.Cat_board_memory_candle, "Candle", "candle", false)
        | "board" :: _ ->
            ("board", Wire_config.Cat_board_memory_candle, "Board", "board", false)
        | "memory" :: _ ->
            ("memory", Wire_config.Cat_board_memory_candle, "Memory", "memory", false)
        | "typesafeai" :: _ ->
            ("typesafeai", Wire_config.Cat_board_memory_candle, "TypeSafeAI", "typesafeai", false)
        | "web_search" :: _ ->
            ("web_search", Wire_config.Cat_board_memory_candle, "Web Search", "web_search", false)
        | "skills" :: _ ->
            ("skills", Wire_config.Cat_board_memory_candle, "Skills", "skills", false)
        | "repositories" :: _ ->
            ("repositories", Wire_config.Cat_board_memory_candle, "Repositories", "repositories", false)
        | "tui" :: _ ->
            ("tui", Wire_config.Cat_general_ui, "TUI & Display", "tui", false)
        | "turn" :: _ ->
            ("turn", Wire_config.Cat_keepers_companies, "Keeper Turns", "turn", false)
        | "wire_capture" :: _ ->
            ("wire_capture", Wire_config.Cat_general_ui, "Wire Capture", "wire_capture", false)
        | "keeper" :: _ ->
            let cat_str = Wire_config.config_category_to_string cat in
            ( "keeper:" ^ cat_str
            , cat
            , "Keeper (" ^ title_case_segment cat_str ^ ")"
            , "keeper"
            , false )
        | top :: _ ->
            let cat_str = Wire_config.config_category_to_string cat in
            if not (String.equal top "") then
              let title =
                if equal_config_category cat Wire_config.Cat_providers_models
                then provider_title top
                else title_case_segment top
              in
              ( cat_str ^ ":" ^ top
              , cat
              , title
              , top
              , false )
            else
              ( cat_str ^ ":general"
              , cat
              , title_case_segment cat_str
              , cat_str
              , false )
        | [] ->
            let cat_str = Wire_config.config_category_to_string cat in
            ( cat_str ^ ":general"
            , cat
            , title_case_segment cat_str
            , cat_str
            , false ))
      in
      let order = ref [] in
      let groups :
          ( string
          , Wire_config.config_category * string * string * bool * Wire_config.schema_field list )
          Hashtbl.t =
        Hashtbl.create 64
      in
      List.iter
        (fun (cat, f) ->
          let sid, eff_cat, title, subtitle, is_cat = classify_field cat f in
          let matches =
            String.equal q ""
            || contains_ci ~needle:q title
            || contains_ci ~needle:q subtitle
            || field_matches_query ~q f
          in
          if matches then
            match Hashtbl.find_opt groups sid with
            | Some (c, ttl, sub, isc, rev_fs) ->
                Hashtbl.replace groups sid (c, ttl, sub, isc, f :: rev_fs)
            | None ->
                order := sid :: !order;
                Hashtbl.replace groups sid (eff_cat, title, subtitle, is_cat, [ f ]))
        all_fields_with_cat;
      List.rev !order
      |> List.filter_map (fun sid ->
             match Hashtbl.find_opt groups sid with
             | None -> None
             | Some (category, title, subtitle, is_catalog_group, rev_fields) ->
                 let fields = List.rev rev_fields in
                 let dirty_count =
                   List.fold_left
                     (fun n (f : Wire_config.schema_field) ->
                       if String_map.mem f.full_key t.dirty_fields then n + 1
                       else n)
                     0 fields
                 in
                 Some
                   {
                     section_id = sid;
                     category;
                     tab = Wire_config.settings_tab_of_category category;
                     title;
                     subtitle;
                     is_catalog_group;
                     badge_count = List.length fields;
                     dirty_count;
                     provenance = dominant_provenance fields;
                     reload_scope = dominant_reload_scope fields;
                     fields;
                   })

let visible_tree_rows t =
  let sections = tree_sections t in
  let has_search = not (String.equal (String.trim t.search_query) "") in
  List.concat_map
    (fun cat ->
      let cat_sections =
        List.filter
          (fun (s : settings_tree_section) -> equal_config_category s.category cat)
          sections
      in
      if has_search && cat_sections = [] then []
      else
        let cid = Wire_config.config_category_to_string cat in
        let collapsed =
          (not has_search) && String_set.mem cid t.collapsed_categories
        in
        let field_count =
          List.fold_left (fun n s -> n + s.badge_count) 0 cat_sections
        in
        let dirty_count =
          List.fold_left (fun n s -> n + s.dirty_count) 0 cat_sections
        in
        let header =
          Tree_category
            {
              category = cat;
              tab = Wire_config.settings_tab_of_category cat;
              collapsed;
              section_count = List.length cat_sections;
              field_count;
              dirty_count;
            }
        in
        if collapsed then [ header ]
        else
          let regular, catalog =
            List.partition (fun s -> not s.is_catalog_group) cat_sections
          in
          let regular_rows = List.map (fun s -> Tree_section s) regular in
          let catalog_rows =
            match catalog with
            | [] -> []
            | models ->
                let expanded = has_search || t.models_catalog_expanded in
                let cat_dirty =
                  List.fold_left (fun n s -> n + s.dirty_count) 0 models
                in
                let toggle =
                  Tree_models_catalog_toggle
                    {
                      expanded;
                      model_count = List.length models;
                      dirty_count = cat_dirty;
                    }
                in
                if expanded then
                  toggle :: List.map (fun s -> Tree_section s) models
                else [ toggle ]
          in
          header :: (regular_rows @ catalog_rows))
    all_categories_ordered

let selected_tree_row t =
  let rows = visible_tree_rows t in
  List.nth_opt rows (clamp_index (List.length rows) t.selected_section_idx)

let first_section_index_for_tab tab t =
  let rows = visible_tree_rows t in
  let target_cat = Wire_config.category_of_settings_tab tab in
  let rec find i = function
    | [] -> None
    | Tree_section s :: _ when equal_config_category s.category target_cat ->
        Some i
    | (Tree_section _ | Tree_category _ | Tree_models_catalog_toggle _) :: rest ->
        find (i + 1) rest
  in
  match find 0 rows with
  | Some idx -> idx
  | None ->
      let rec find_cat i = function
        | [] -> 0
        | Tree_category { category; _ } :: _
          when equal_config_category category target_cat ->
            i
        | (Tree_category _ | Tree_section _ | Tree_models_catalog_toggle _)
          :: rest ->
            find_cat (i + 1) rest
      in
      find_cat 0 rows

let selected_section t =
  let rows = visible_tree_rows t in
  match List.nth_opt rows (clamp_index (List.length rows) t.selected_section_idx) with
  | Some (Tree_section s) -> Some s
  | Some (Tree_category { category; _ }) ->
      List.find_opt
        (fun (s : settings_tree_section) -> equal_config_category s.category category)
        (tree_sections t)
  | Some (Tree_models_catalog_toggle _) ->
      List.find_opt (fun (s : settings_tree_section) -> s.is_catalog_group)
        (tree_sections t)
  | None ->
      let active_cat = Wire_config.category_of_settings_tab t.active_tab in
      let secs = tree_sections t in
      (match
         List.find_opt
           (fun (s : settings_tree_section) ->
             equal_config_category s.category active_cat)
           secs
       with
      | Some _ as hit -> hit
      | None -> List.nth_opt secs 0)

let selected_section_fields t =
  match selected_section t with Some s -> s.fields | None -> []

let set_tab active_tab t =
  let active_cid =
    Wire_config.config_category_to_string
      (Wire_config.category_of_settings_tab active_tab)
  in
  let collapsed_categories =
    String_set.remove active_cid (default_collapsed_for_tab active_tab)
  in
  let next =
    {
      t with
      active_tab;
      collapsed_categories;
      selected_field_index = 0;
      scroll_offset = 0;
      editing_field_key = None;
      editing_buffer = "";
    }
  in
  let selected_section_idx = first_section_index_for_tab active_tab next in
  { next with selected_section_idx; tree_scroll_offset = 0 }

let cycle_tab dir t =
  let next_tab =
    match dir with
    | Keymap.Next -> Nav.next_settings_tab t.active_tab
    | Keymap.Prev -> Nav.prev_settings_tab t.active_tab
  in
  set_tab next_tab t

let set_target target t =
  if equal_config_target target t.target then t
  else
    {
      t with
      target;
      schema = Observed.loading ~since_ns:Clock.Mono.zero;
      field_meta = String_map.empty;
      dirty_fields = String_map.empty;
      dry_run_preview = Dry_run_idle;
      save_state = Save_idle;
      selected_section_idx = 0;
      tree_scroll_offset = 0;
      selected_field_index = 0;
      scroll_offset = 0;
      editing_field_key = None;
      editing_buffer = "";
    }

let set_new_keeper_name new_keeper_name t = { t with new_keeper_name }

let set_search_query search_query t =
  let next =
    {
      t with
      search_query;
      selected_section_idx = 0;
      tree_scroll_offset = 0;
      selected_field_index = 0;
      scroll_offset = 0;
    }
  in
  let rows = visible_tree_rows next in
  let first_sec =
    let rec find i = function
      | [] -> 0
      | Tree_section _ :: _ -> i
      | (Tree_category _ | Tree_models_catalog_toggle _) :: rest ->
          find (i + 1) rest
    in
    find 0 rows
  in
  { next with selected_section_idx = first_sec }

let set_pane settings_pane t = { t with settings_pane }

let toggle_pane t =
  let settings_pane =
    match t.settings_pane with
    | Pane_tree -> Pane_inspector
    | Pane_inspector -> Pane_tree
  in
  { t with settings_pane }

let enter_inspector t =
  { t with settings_pane = Pane_inspector; selected_field_index = 0; scroll_offset = 0 }

let leave_inspector t = { t with settings_pane = Pane_tree }

let default_viewport_rows = 15

let adjust_scroll ?(viewport_rows = default_viewport_rows) ~scroll selected =
  let vr = max 1 viewport_rows in
  if selected < scroll then selected
  else if selected >= scroll + vr then max 0 (selected - vr + 1)
  else scroll

let move_tree_selection ?viewport_rows ~delta t =
  let rows = visible_tree_rows t in
  let len = List.length rows in
  let selected_section_idx = clamp_index len (t.selected_section_idx + delta) in
  let tree_scroll_offset =
    adjust_scroll ?viewport_rows ~scroll:t.tree_scroll_offset
      selected_section_idx
  in
  let active_tab =
    match List.nth_opt rows selected_section_idx with
    | Some (Tree_category { tab; _ }) -> tab
    | Some (Tree_section s) -> s.tab
    | Some (Tree_models_catalog_toggle _) -> Nav.Settings_providers_models
    | None -> t.active_tab
  in
  {
    t with
    active_tab;
    selected_section_idx;
    tree_scroll_offset;
    selected_field_index = 0;
    scroll_offset = 0;
  }

let toggle_tree_node t =
  match selected_tree_row t with
  | None -> t
  | Some (Tree_category { category; collapsed; _ }) ->
      let cid = Wire_config.config_category_to_string category in
      let collapsed_categories =
        if collapsed then String_set.remove cid t.collapsed_categories
        else String_set.add cid t.collapsed_categories
      in
      { t with collapsed_categories }
  | Some (Tree_models_catalog_toggle { expanded; _ }) ->
      { t with models_catalog_expanded = not expanded }
  | Some (Tree_section _) -> enter_inspector t

let collapse_or_leave t =
  match t.settings_pane with
  | Pane_inspector -> leave_inspector t
  | Pane_tree -> (
      match selected_tree_row t with
      | Some (Tree_category { category; collapsed = false; _ }) ->
          let cid = Wire_config.config_category_to_string category in
          {
            t with
            collapsed_categories = String_set.add cid t.collapsed_categories;
          }
      | Some (Tree_models_catalog_toggle { expanded = true; _ }) ->
          { t with models_catalog_expanded = false }
      | Some (Tree_section s) ->
          let cid = Wire_config.config_category_to_string s.category in
          let rows = visible_tree_rows t in
          let cat_idx =
            let rec find i = function
              | [] -> 0
              | Tree_category { category; _ } :: _
                when equal_config_category category s.category ->
                  i
              | (Tree_category _ | Tree_section _ | Tree_models_catalog_toggle _)
                :: rest ->
                  find (i + 1) rest
            in
            find 0 rows
          in
          let tree_scroll_offset =
            if cat_idx < t.tree_scroll_offset then cat_idx
            else t.tree_scroll_offset
          in
          {
            t with
            collapsed_categories = String_set.add cid t.collapsed_categories;
            selected_section_idx = cat_idx;
            tree_scroll_offset;
          }
      | Some (Tree_category { collapsed = true; _ })
      | Some (Tree_models_catalog_toggle { expanded = false; _ })
      | None ->
          t)

let expand_or_enter t =
  match t.settings_pane with
  | Pane_inspector -> t
  | Pane_tree -> (
      match selected_tree_row t with
      | Some (Tree_category { category; collapsed = true; _ }) ->
          let cid = Wire_config.config_category_to_string category in
          {
            t with
            collapsed_categories = String_set.remove cid t.collapsed_categories;
          }
      | Some (Tree_models_catalog_toggle { expanded = false; _ }) ->
          { t with models_catalog_expanded = true }
      | Some (Tree_category { collapsed = false; _ })
      | Some (Tree_models_catalog_toggle { expanded = true; _ })
      | Some (Tree_section _) ->
          enter_inspector t
      | None -> t)

let apply_preferences ~observed_at preferences t =
  { t with preferences = Observed.value ~observed_at preferences }

let field_meta_map_of_list pairs =
  List.fold_left
    (fun acc (k, v) -> String_map.add k v acc)
    String_map.empty pairs

let apply_schema_meta ~target meta t =
  if equal_config_target target t.target then
    let next = { t with field_meta = field_meta_map_of_list meta } in
    if Observed.is_value next.schema then
      let idx = first_section_index_for_tab next.active_tab next in
      { next with selected_section_idx = idx; selected_field_index = 0 }
    else next
  else t

let apply_schema ?field_meta ~observed_at (schema : Wire_config.config_schema) t =
  if equal_config_target schema.target t.target then
    let field_meta =
      match field_meta with
      | Some pairs -> field_meta_map_of_list pairs
      | None -> t.field_meta
    in
    let next =
      { t with schema = Observed.value ~observed_at schema; field_meta }
    in
    let idx = first_section_index_for_tab next.active_tab next in
    { next with selected_section_idx = idx; selected_field_index = 0 }
  else t

let mark_dry_run_loading t = { t with dry_run_preview = Dry_run_loading }
let mark_save_in_flight t = { t with save_state = Save_in_flight }

let apply_patch_response ~dry_run (resp : Wire_config.patch_response) t =
  if dry_run then { t with dry_run_preview = Dry_run_ready resp }
  else
    let last_snapshot_id =
      match resp.snapshot_id with
      | Some _ as sid -> sid
      | None -> t.last_snapshot_id
    in
    {
      t with
      dirty_fields = String_map.empty;
      dry_run_preview = Dry_run_idle;
      save_state = Save_succeeded resp;
      last_snapshot_id;
      schema = Observed.mark_stale t.schema;
    }

let apply_patch_error ~dry_run reason t =
  if dry_run then { t with dry_run_preview = Dry_run_failed reason }
  else { t with save_state = Save_failed reason }

let visible_fields t =
  match Observed.to_option t.schema with
  | None -> []
  | Some schema ->
      let q = String.trim t.search_query in
      let active_cat = Wire_config.category_of_settings_tab t.active_tab in
      let sections =
        if String.equal q "" then
          List.filter
            (fun (s : Wire_config.schema_section) ->
              equal_config_category s.category active_cat)
            schema.sections
        else schema.sections
      in
      let fields =
        List.concat_map
          (fun (s : Wire_config.schema_section) -> s.fields)
          sections
      in
      if String.equal q "" then fields
      else List.filter (field_matches_query ~q) fields

let inspector_fields t =
  match selected_section_fields t with
  | _ :: _ as fs -> fs
  | [] -> visible_fields t

let selected_field t =
  let fs = inspector_fields t in
  List.nth_opt fs (clamp_index (List.length fs) t.selected_field_index)

let stage_patch ~full_key op t =
  {
    t with
    dirty_fields = String_map.add full_key op t.dirty_fields;
    dry_run_preview = Dry_run_idle;
  }

let unstage_patch ~full_key t =
  {
    t with
    dirty_fields = String_map.remove full_key t.dirty_fields;
    dry_run_preview = Dry_run_idle;
  }

let clear_dirty t =
  {
    t with
    dirty_fields = String_map.empty;
    dry_run_preview = Dry_run_idle;
    editing_field_key = None;
    editing_buffer = "";
  }

let dirty_count t = String_map.cardinal t.dirty_fields

let build_patch_request ~dry_run t =
  let ops =
    String_map.fold (fun _ op acc -> op :: acc) t.dirty_fields [] |> List.rev
  in
  match ops with
  | [] -> Error "No staged configuration changes to patch"
  | _ :: _ -> (
      match t.target with
      | Wire_config.Target_keeper_create
        when String.equal (String.trim t.new_keeper_name) "" ->
          Error "New keeper name is required before creating keeper config"
      | Wire_config.Target_runtime
      | Wire_config.Target_keeper _
      | Wire_config.Target_keeper_create -> (
          let sha_res =
            match Observed.to_option t.schema with
            | Some s ->
                if not (equal_config_target s.target t.target) then
                  Error "Loaded configuration schema does not match active target"
                else Ok (if s.file_exists then Some s.file_sha256 else None)
            | None -> (
                match t.target with
                | Wire_config.Target_keeper_create -> Ok None
                | Wire_config.Target_runtime | Wire_config.Target_keeper _ ->
                    Error "Configuration schema is still loading for active target")
          in
          match sha_res with
          | Error _ as err -> err
          | Ok expected_sha256 ->
              let keeper_name =
                match t.target with
                | Wire_config.Target_runtime -> None
                | Wire_config.Target_keeper name -> Some name
                | Wire_config.Target_keeper_create ->
                    Some (String.trim t.new_keeper_name)
              in
              Ok
                {
                  Wire_config.target = t.target;
                  keeper_name;
                  expected_sha256;
                  dry_run;
                  ops;
                }))

let string_of_field_value = function
  | Wire_config.Val_bool b -> if b then "true" else "false"
  | Wire_config.Val_int n -> Int.to_string n
  | Wire_config.Val_float f -> Float.to_string f
  | Wire_config.Val_string s -> s
  | Wire_config.Val_string_list xs -> String.concat ", " xs
  | Wire_config.Val_structured json -> Yojson.Safe.to_string json
  | Wire_config.Val_secret _ -> ""
  | Wire_config.Val_null -> ""

let string_of_staged_op = function
  | Wire_config.Set_scalar { value; _ } -> value
  | Wire_config.Set_int { value; _ } -> Int.to_string value
  | Wire_config.Set_float { value; _ } -> Float.to_string value
  | Wire_config.Set_bool { value; _ } -> if value then "true" else "false"
  | Wire_config.Set_string_array { values; _ } -> String.concat ", " values
  | Wire_config.Remove_key _ -> ""

let new_keeper_name_field_key = "__masc_new_keeper_name__"

let is_editing_field t = Option.is_some t.editing_field_key

let is_editing_new_keeper_name t =
  match t.editing_field_key with
  | Some k -> String.equal k new_keeper_name_field_key
  | None -> false

let begin_edit_new_keeper_name t =
  {
    t with
    editing_field_key = Some new_keeper_name_field_key;
    editing_buffer = t.new_keeper_name;
  }

let stage_remove_selected t =
  match selected_field t with
  | None -> Error "No configuration field selected"
  | Some f when not f.writable ->
      Error (Printf.sprintf "Field %s is read-only" f.full_key)
  | Some f -> (
      match String_map.find_opt f.full_key t.dirty_fields with
      | Some (Wire_config.Remove_key _) ->
          Ok (unstage_patch ~full_key:f.full_key t)
      | Some
          ( Wire_config.Set_scalar _
          | Wire_config.Set_int _
          | Wire_config.Set_float _
          | Wire_config.Set_bool _
          | Wire_config.Set_string_array _ )
      | None ->
          let op = Wire_config.Remove_key { table = f.table; key = f.key } in
          Ok (stage_patch ~full_key:f.full_key op t))

let begin_edit_selected t =
  match selected_field t with
  | None -> Error "No configuration field selected"
  | Some f when not f.writable ->
      Error (Printf.sprintf "Field %s is read-only" f.full_key)
  | Some f when f.secret ->
      Error
        (Printf.sprintf
           "Secret %s cannot be edited inline; set via environment variable"
           f.full_key)
  | Some f -> (
      match f.kind with
      | Wire_config.Field_secret ->
          Error
            (Printf.sprintf
               "Secret %s cannot be edited inline; set via environment variable"
               f.full_key)
      | Wire_config.Field_structured ->
          Error
            (Printf.sprintf
               "Structured field %s requires opt-in Ctrl+E editor" f.full_key)
      | Wire_config.Field_bool ->
          let orig_val =
            match f.value with
            | Wire_config.Val_bool b -> Some b
            | Wire_config.Val_int _
            | Wire_config.Val_float _
            | Wire_config.Val_string _
            | Wire_config.Val_string_list _
            | Wire_config.Val_structured _
            | Wire_config.Val_secret _
            | Wire_config.Val_null ->
                None
          in
          let current_val =
            match String_map.find_opt f.full_key t.dirty_fields with
            | Some (Wire_config.Set_bool { value; _ }) -> value
            | Some
                ( Wire_config.Set_scalar _
                | Wire_config.Set_int _
                | Wire_config.Set_float _
                | Wire_config.Set_string_array _
                | Wire_config.Remove_key _ )
            | None -> (
                match orig_val with Some b -> b | None -> false)
          in
          let next_val = not current_val in
          if Option.equal Bool.equal (Some next_val) orig_val then
            Ok (unstage_patch ~full_key:f.full_key t)
          else
            let op =
              Wire_config.Set_bool
                { table = f.table; key = f.key; value = next_val }
            in
            Ok (stage_patch ~full_key:f.full_key op t)
      | Wire_config.Field_int _
      | Wire_config.Field_float _
      | Wire_config.Field_string
      | Wire_config.Field_enum _
      | Wire_config.Field_string_list ->
          let initial_buf =
            match String_map.find_opt f.full_key t.dirty_fields with
            | Some staged -> string_of_staged_op staged
            | None -> string_of_field_value f.value
          in
          Ok
            {
              t with
              editing_field_key = Some f.full_key;
              editing_buffer = initial_buf;
            })

let update_edit_buffer editing_buffer t = { t with editing_buffer }

let append_edit_char s t =
  { t with editing_buffer = t.editing_buffer ^ s }

let is_utf8_cont b = b land 0xC0 = 0x80

let backspace_edit_buffer t =
  let s = t.editing_buffer in
  let len = String.length s in
  if len <= 0 then t
  else
    let rec prev i =
      if i <= 0 then 0
      else if is_utf8_cont (Char.code s.[i]) then prev (i - 1)
      else i
    in
    let cut = prev (len - 1) in
    { t with editing_buffer = String.sub s 0 cut }

let cancel_edit_field t =
  { t with editing_field_key = None; editing_buffer = "" }

let parse_strict_bool s =
  match String.lowercase_ascii (String.trim s) with
  | "true" -> Ok true
  | "false" -> Ok false
  | other -> Error (Printf.sprintf "Expected true or false, got %S" other)

let is_valid_keeper_name s =
  let len = String.length s in
  len > 0 && len <= 64
  &&
  let rec check i =
    if i >= len then true
    else
      match s.[i] with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> check (i + 1)
      | _ -> false
  in
  check 0

let commit_edit_field t =
  match t.editing_field_key with
  | None -> Error "Not currently editing a field"
  | Some key when String.equal key new_keeper_name_field_key ->
      let trimmed = String.trim t.editing_buffer in
      if not (is_valid_keeper_name trimmed) then
        Error
          "Keeper name must be 1..64 ASCII letters, digits, '-' or '_'"
      else
        let updated = set_new_keeper_name trimmed t in
        Ok { updated with editing_field_key = None; editing_buffer = "" }
  | Some key -> (
      let all_fields =
        match Observed.to_option t.schema with
        | Some s ->
            List.concat_map
              (fun (sec : Wire_config.schema_section) -> sec.fields)
              s.sections
        | None -> []
      in
      let field_opt =
        List.find_opt
          (fun (f : Wire_config.schema_field) -> String.equal f.full_key key)
          all_fields
      in
      match field_opt with
      | None -> Error (Printf.sprintf "Field %s is no longer visible" key)
      | Some f -> (
          let raw = String.trim t.editing_buffer in
          let op_res =
            match f.kind with
            | Wire_config.Field_bool ->
                Result.map
                  (fun value ->
                    Wire_config.Set_bool { table = f.table; key = f.key; value })
                  (parse_strict_bool raw)
            | Wire_config.Field_int { min = min_v; max = max_v } -> (
                match int_of_string_opt raw with
                | None -> Error (Printf.sprintf "Expected integer, got %S" raw)
                | Some v ->
                    let check_min =
                      match min_v with
                      | Some lo when v < lo ->
                          Error (Printf.sprintf "Value %d below minimum %d" v lo)
                      | Some _ | None -> Ok ()
                    in
                    let check_max =
                      match max_v with
                      | Some hi when v > hi ->
                          Error (Printf.sprintf "Value %d above maximum %d" v hi)
                      | Some _ | None -> Ok ()
                    in
                    Result.bind check_min (fun () ->
                        Result.map
                          (fun () ->
                            Wire_config.Set_int
                              { table = f.table; key = f.key; value = v })
                          check_max))
            | Wire_config.Field_float { min = min_v; max = max_v } -> (
                match float_of_string_opt raw with
                | None -> Error (Printf.sprintf "Expected number, got %S" raw)
                | Some v when not (Float.is_finite v) ->
                    Error "Value must be a finite number"
                | Some v ->
                    let check_min =
                      match min_v with
                      | Some lo when v < lo ->
                          Error
                            (Printf.sprintf "Value %g below minimum %g" v lo)
                      | Some _ | None -> Ok ()
                    in
                    let check_max =
                      match max_v with
                      | Some hi when v > hi ->
                          Error
                            (Printf.sprintf "Value %g above maximum %g" v hi)
                      | Some _ | None -> Ok ()
                    in
                    Result.bind check_min (fun () ->
                        Result.map
                          (fun () ->
                            Wire_config.Set_float
                              { table = f.table; key = f.key; value = v })
                          check_max))
            | Wire_config.Field_string ->
                Ok
                  (Wire_config.Set_scalar
                     { table = f.table; key = f.key; value = t.editing_buffer })
            | Wire_config.Field_enum allowed ->
                if List.exists (String.equal raw) allowed then
                  Ok
                    (Wire_config.Set_scalar
                       { table = f.table; key = f.key; value = raw })
                else
                  Error
                    (Printf.sprintf "Expected one of [%s], got %S"
                       (String.concat ", " allowed)
                       raw)
            | Wire_config.Field_string_list ->
                let values =
                  if String.equal raw "" then []
                  else
                    String.split_on_char ',' raw
                    |> List.map String.trim
                    |> List.filter (fun s -> not (String.equal s ""))
                in
                Ok
                  (Wire_config.Set_string_array
                     { table = f.table; key = f.key; values })
            | Wire_config.Field_structured ->
                Error "Structured fields cannot be committed from scalar editor"
            | Wire_config.Field_secret ->
                Error "Secret fields cannot be committed inline"
          in
          match op_res with
          | Error _ as err -> err
          | Ok op ->
              let staged = stage_patch ~full_key:f.full_key op t in
              Ok { staged with editing_field_key = None; editing_buffer = "" }))

let move_selection ?viewport_rows ~delta t =
  match t.settings_pane with
  | Pane_tree -> move_tree_selection ?viewport_rows ~delta t
  | Pane_inspector ->
      let len = List.length (inspector_fields t) in
      let selected_field_index =
        clamp_index len (t.selected_field_index + delta)
      in
      let scroll_offset =
        adjust_scroll ?viewport_rows ~scroll:t.scroll_offset
          selected_field_index
      in
      { t with selected_field_index; scroll_offset }

let mark_stale_all t =
  {
    t with
    preferences = Observed.mark_stale t.preferences;
    schema = Observed.mark_stale t.schema;
  }
