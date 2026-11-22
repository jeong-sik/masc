open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

let caps = Presenter.default_capabilities

(* ---------- Shared Modal Geometry Helpers ---------- *)

let center_rect ~(outer : Rect.t) ~w ~h =
  let cw = Int.max 0 (Int.min outer.w w) in
  let ch = Int.max 0 (Int.min outer.h h) in
  let x = outer.x + ((outer.w - cw) / 2) in
  let y = outer.y + ((outer.h - ch) / 2) in
  Rect.make ~x ~y ~w:cw ~h:ch

let palette_modal_rect ~(rect : Rect.t) =
  let desired_w = Int.max 74 (rect.w * 2 / 3) in
  let w = Int.min (Int.max 0 (rect.w - 2)) (Int.min 104 desired_w) in
  let h = Int.min (Int.max 0 (rect.h - 2)) 22 in
  center_rect ~outer:rect ~w ~h

(* ---------- Overlay 1: Ctrl+K Universal Command & Entity Palette ---------- *)

type palette_row =
  | Palette_header of string
  | Palette_item of {
      selectable_idx : int option;
      badge : string;
      title : string;
      meta : string;
      tone : Theme.status_token option;
    }

let build_universal_palette_rows (m : Model.t) =
  let lang = m.lang in
  let q = String.trim m.palette.query in
  let fuzzy_opt s = Render_util.fuzzy_score ~query:q s in
  let rows = ref [] in
  let push_section header items =
    if items <> [] then begin
      rows := Palette_header header :: !rows;
      List.iter (fun item -> rows := item :: !rows) items
    end
  in
  let cmds = Update_nav.palette_filtered_commands m in
  let cmd_items =
    List.mapi
      (fun idx (c : Keymap.palette_command) ->
        let slash_s =
          match c.slash_twin with Some s -> " " ^ s | None -> ""
        in
        Palette_item
          {
            selectable_idx = Some idx;
            badge = c.shortcut;
            title = c.title;
            meta = String.trim slash_s;
            tone = Some Theme.Status_active;
          })
      cmds
  in
  let take n xs =
    let rec go k acc = function
      | _ when k <= 0 -> List.rev acc
      | [] -> List.rev acc
      | x :: rest -> go (k - 1) (x :: acc) rest
    in
    go n [] xs
  in
  push_section
    (Say.resolve lang (Say.make ~ko:"명령" ~en:"Commands"))
    cmd_items;
  let ws_items =
    Nav.all_workspaces
    |> List.filter_map (fun ws ->
           let lbl = Say.resolve lang (Nav.workspace_label ws) in
           let idx = Nav.workspace_index ws in
           let search_s = Printf.sprintf "%d %s" idx lbl in
           match fuzzy_opt search_s with
           | None -> None
           | Some _ ->
               Some
                 (Palette_item
                    {
                      selectable_idx = None;
                      badge = Printf.sprintf "[%d]" idx;
                      title = lbl;
                      meta =
                        Say.resolve lang
                          (Say.make ~ko:"워크스페이스" ~en:"Workspace");
                      tone = Some Theme.Status_ok;
                    }))
  in
  push_section
    (Say.resolve lang (Say.make ~ko:"워크스페이스" ~en:"Workspaces"))
    (take (if String.equal q "" then 3 else 6) ws_items);
  let keeper_items =
    Fleet_store.filtered_keepers { m.fleet with filter_query = "" }
    |> List.filter_map (fun (k : Wire_fleet.keeper_summary) ->
           match fuzzy_opt (k.name ^ " " ^ k.company) with
           | None -> None
           | Some _ ->
               let g, tone = Render_util.keeper_health_glyph_and_tone k.health in
               Some
                 (Palette_item
                    {
                      selectable_idx = None;
                      badge = Glyph.to_utf8 g;
                      title = k.name;
                      meta = Printf.sprintf "%s · %s" k.company k.runtime_id;
                      tone = Some tone;
                    }))
  in
  push_section
    (Say.resolve lang (Say.make ~ko:"키퍼" ~en:"Keepers"))
    (take (if String.equal q "" then 3 else 6) keeper_items);
  let company_items =
    Fleet_store.company_groups m.fleet
    |> List.filter_map (fun (g : Wire_fleet.company_group) ->
           match fuzzy_opt g.company with
           | None -> None
           | Some _ ->
               Some
                 (Palette_item
                    {
                      selectable_idx = None;
                      badge = "CO";
                      title = g.company;
                      meta = Printf.sprintf "%d keepers" (List.length g.keepers);
                      tone = None;
                    }))
  in
  push_section
    (Say.resolve lang (Say.make ~ko:"조직" ~en:"Companies"))
    (take (if String.equal q "" then 2 else 5) company_items);
  let goal_items =
    Work_store.goals m.work
    |> List.filter_map (fun (g : Wire_work.goal) ->
           match fuzzy_opt (g.id ^ " " ^ g.title) with
           | None -> None
           | Some _ ->
               Some
                 (Palette_item
                    {
                      selectable_idx = None;
                      badge = "G";
                      title = g.title;
                      meta = Wire_work.goal_phase_to_string g.phase;
                      tone = Some Theme.Status_ok;
                    }))
  in
  let task_items =
    Work_store.tasks m.work
    |> List.filter_map (fun (t : Wire_work.task) ->
           match fuzzy_opt (t.id ^ " " ^ t.title) with
           | None -> None
           | Some _ ->
               Some
                 (Palette_item
                    {
                      selectable_idx = None;
                      badge = "T";
                      title = t.title;
                      meta = t.id;
                      tone = None;
                    }))
  in
  push_section
    (Say.resolve lang (Say.make ~ko:"목표 · 작업" ~en:"Goals & Tasks"))
    (take (if String.equal q "" then 2 else 5) (goal_items @ task_items));
  let board_items =
    Knowledge_store.filtered_posts m.knowledge
    |> List.filter_map (fun (p : Wire_knowledge.board_post) ->
           match fuzzy_opt (p.title ^ " " ^ p.author) with
           | None -> None
           | Some _ ->
               Some
                 (Palette_item
                    {
                      selectable_idx = None;
                      badge = "#";
                      title = p.title;
                      meta = p.author;
                      tone = None;
                    }))
  in
  let wiki_items =
    match Observed.to_option m.knowledge.wiki_index with
    | None -> []
    | Some wi ->
        wi.pages
        |> List.filter_map (fun (p : Wire_knowledge.wiki_page_summary) ->
               match fuzzy_opt (p.slug ^ " " ^ p.title) with
               | None -> None
               | Some _ ->
                   Some
                     (Palette_item
                        {
                          selectable_idx = None;
                          badge = "W";
                          title = p.title;
                          meta = p.slug;
                          tone = Some Theme.Status_active;
                        }))
  in
  push_section
    (Say.resolve lang (Say.make ~ko:"보드 · 위키" ~en:"Board & Wiki"))
    (take (if String.equal q "" then 2 else 5) (board_items @ wiki_items));
  let sandbox_items =
    match Observed.to_option m.infra.sandboxes with
    | None -> []
    | Some sb ->
        let vms =
          List.filter_map
            (fun (g : Wire_infra.microvm_guest) ->
              match fuzzy_opt (g.keeper ^ " " ^ g.guest_name) with
              | None -> None
              | Some _ ->
                  Some
                    (Palette_item
                       {
                         selectable_idx = None;
                         badge = "VM";
                         title = g.keeper;
                         meta = g.backend;
                         tone = Some Theme.Status_active;
                       }))
            sb.microvm_guests
        in
        let sshs =
          List.filter_map
            (fun (p : Wire_infra.ssh_pool) ->
              match fuzzy_opt (p.pool_name ^ " " ^ p.host) with
              | None -> None
              | Some _ ->
                  Some
                    (Palette_item
                       {
                         selectable_idx = None;
                         badge = "SSH";
                         title = p.pool_name;
                         meta = Printf.sprintf "%s:%d" p.host p.port;
                         tone = Some Theme.Status_active;
                       }))
            sb.ssh_pools
        in
        vms @ sshs
  in
  push_section
    (Say.resolve lang (Say.make ~ko:"샌드박스" ~en:"Sandboxes"))
    (take (if String.equal q "" then 2 else 4) sandbox_items);
  let settings_items =
    match Observed.to_option m.config.schema with
    | None -> []
    | Some sc ->
        sc.sections
        |> List.concat_map (fun (s : Wire_config.schema_section) -> s.fields)
        |> List.filter_map (fun (f : Wire_config.schema_field) ->
               let leaf = Config_store.field_label ~lang f in
               match fuzzy_opt (f.full_key ^ " " ^ leaf) with
               | None -> None
               | Some _ ->
                   Some
                     (Palette_item
                        {
                          selectable_idx = None;
                          badge = "CFG";
                          title = leaf;
                          meta = f.full_key;
                          tone = None;
                        }))
  in
  push_section
    (Say.resolve lang (Say.make ~ko:"설정 키" ~en:"Settings Keys"))
    (take (if String.equal q "" then 2 else 5) settings_items);
  let slash_items =
    Slash.filter ~query:q ~lang
    |> List.map (fun (s : Slash.spec) ->
           Palette_item
             {
               selectable_idx = None;
               badge = s.name;
               title = Say.resolve lang s.description;
               meta =
                 (match s.arg_hint with
                  | Some h -> Say.resolve lang h
                  | None -> "");
               tone = Some Theme.Status_active;
             })
  in
  push_section
    (Say.resolve lang
       (Say.make
          ~ko:(Printf.sprintf "슬래시 명령 (%d)" (List.length Slash.all))
          ~en:(Printf.sprintf "Slash Commands (%d)" (List.length Slash.all))))
    (take (if String.equal q "" then 4 else 8) slash_items);
  List.rev !rows

let render_palette grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) =
  let modal_r = palette_modal_rect ~rect in
  if Rect.is_empty modal_r then ()
  else
    let lang = model.lang in
    let title =
      match model.palette.mode with
      | Model.Palette_commands ->
          Say.resolve lang
            (Say.make ~ko:"Ctrl+K · 통합 명령 · 엔티티 팔레트"
               ~en:"Ctrl+K · Universal Command & Entity Palette")
      | Model.Palette_keepers ->
          Say.resolve lang
            (Say.make ~ko:"Ctrl+G · 키퍼 빠른 전환" ~en:"Ctrl+G · Keeper Switcher")
      | Model.Palette_models ->
          Say.resolve lang
            (Say.make ~ko:"Ctrl+L · 런타임 · 모델 선택" ~en:"Ctrl+L · Runtime / Model Picker")
    in
    let inner =
      Card.draw ~cache grid ~rect:modal_r ~theme
        {
          (Card.default_spec ~title) with
          badge = None;
          hotkey =
            Some
              (Say.resolve lang
                 (Say.make ~ko:"[Enter] 실행 · [Esc] 닫기"
                    ~en:"[Enter] Run · [Esc] Close"));
          focused = true;
          elevated = true;
        }
    in
    if not (Rect.is_empty inner) then begin
      let pad_x = if inner.w >= 60 then 2 else 1 in
      let bg = Color.of_rgb theme.surface_2 in
      let anchor_st = Typography.anchor ~bg theme in
      let whisper_st = Typography.whisper ~bg theme in
      let acc_st = Typography.accent ~bg ~bold:true theme in
      let q_left = inner.x + pad_x in
      let q_w = Int.max 0 (inner.w - (2 * pad_x)) in
      let q_row = Rect.make ~x:q_left ~y:inner.y ~w:q_w ~h:1 in
      let prompt = Glyph.to_utf8 Glyph.Prompt_caret ^ " " in
      let p_adv =
        Cell_grid.put_text ~clip:q_row grid ~x:q_left ~y:inner.y ~style:acc_st
          prompt
      in
      let cursor_style =
        Style.make ~fg:(Color.of_rgb theme.selection_fg)
          ~bg:(Color.of_rgb theme.selection_bg) ()
      in
      if String.equal model.palette.query "" then begin
        (* Render block cursor BEFORE placeholder so cell 0 of wide CJK glyphs
           (e.g. '검') is never overwritten by a 1-cell cursor cell. *)
        let cur_x = q_left + p_adv in
        if cur_x < Rect.right q_row then
          Cell_grid.put_ascii ~clip:q_row grid ~x:cur_x ~y:inner.y
            ~style:cursor_style ' ';
        let placeholder_x = cur_x + 2 in
        if placeholder_x < Rect.right q_row then
          let placeholder =
            Say.resolve lang
              (Say.make ~ko:"검색어 입력 (워크스페이스, 키퍼, 목표, 설정, /명령)..."
                 ~en:"Fuzzy search workspaces, keepers, goals, settings, /commands...")
          in
          ignore
            (Cell_grid.put_text ~clip:q_row grid ~x:placeholder_x ~y:inner.y
               ~style:whisper_st
               (Grapheme.truncate_to_width
                  ~max_width:(Int.max 0 (Rect.right q_row - placeholder_x))
                  placeholder))
      end
      else begin
        let q_adv =
          Cell_grid.put_text ~clip:q_row grid ~x:(q_left + p_adv) ~y:inner.y
            ~style:anchor_st
            (Grapheme.truncate_to_width
               ~max_width:(Int.max 0 (q_w - p_adv - 2))
               model.palette.query)
        in
        let cur_x = q_left + p_adv + q_adv in
        if cur_x < Rect.right q_row then
          Cell_grid.put_ascii ~clip:q_row grid ~x:cur_x ~y:inner.y
            ~style:cursor_style ' '
      end;
      if inner.h >= 2 then
        Card.draw_hairline ~pad_x ~bg grid ~rect:inner ~y:(inner.y + 1) ~theme;
      let list_y = inner.y + 2 in
      let list_h = Int.max 0 (Rect.bottom inner - list_y) in
      if list_h > 0 then begin
        let rows =
          match model.palette.mode with
          | Model.Palette_commands -> build_universal_palette_rows model
          | Model.Palette_keepers ->
              Update_nav.palette_filtered_keepers model
              |> List.mapi (fun idx (k : Wire_fleet.keeper_summary) ->
                     let g, tone =
                       Render_util.keeper_health_glyph_and_tone k.health
                     in
                     Palette_item
                       {
                         selectable_idx = Some idx;
                         badge = Glyph.to_utf8 g;
                         title = k.name;
                         meta = Printf.sprintf "%s · %s" k.company k.runtime_id;
                         tone = Some tone;
                       })
          | Model.Palette_models ->
              Update_nav.palette_filtered_models model
              |> List.mapi (fun idx (r : Wire_runtime.runtime_option) ->
                     let def = if r.is_default then " [default]" else "" in
                     let mdl =
                       match r.model with Some s -> s | None -> r.provider
                     in
                     Palette_item
                       {
                         selectable_idx = Some idx;
                         badge = r.provider;
                         title = r.id ^ def;
                         meta = mdl;
                         tone =
                           Some
                             (if r.is_default then Theme.Status_ok
                              else Theme.Status_active);
                       })
        in
        if rows = [] then
          ignore
            (Cell_grid.put_text ~clip:inner grid ~x:q_left ~y:list_y
               ~style:whisper_st
               (Say.resolve lang
                  (Say.make ~ko:"일치하는 항목이 없습니다."
                     ~en:"No matching items.")))
        else
          let arr = Array.of_list rows in
          let total = Array.length arr in
          let selectable_count =
            List.fold_left
              (fun acc row ->
                match row with
                | Palette_item { selectable_idx = Some _; _ } -> acc + 1
                | Palette_header _ | Palette_item { selectable_idx = None; _ } ->
                    acc)
              0 rows
          in
          let clamped_sel =
            Update_nav.clamp_index selectable_count model.palette.selected
          in
          let selected_row_pos =
            let rec find i =
              if i >= total then 0
              else
                match arr.(i) with
                | Palette_item { selectable_idx = Some si; _ }
                  when selectable_count > 0 && Int.equal si clamped_sel ->
                    i
                | Palette_header _ | Palette_item _ -> find (i + 1)
            in
            find 0
          in
          let start =
            if selected_row_pos >= list_h then
              Int.min (Int.max 0 (total - list_h)) (selected_row_pos - list_h + 1)
            else 0
          in
          let right_edge = Rect.right inner - pad_x in
          for i = 0 to list_h - 1 do
            let idx = start + i in
            if idx < total then begin
              let py = list_y + i in
              let row_r = Rect.make ~x:inner.x ~y:py ~w:inner.w ~h:1 in
              match arr.(idx) with
              | Palette_header hdr ->
                  Card.draw_hairline ~pad_x ~label:hdr ~bg grid ~rect:inner
                    ~y:py ~theme
              | Palette_item { selectable_idx; badge; title; meta; tone } ->
                  let is_sel =
                    match selectable_idx with
                    | Some si ->
                        selectable_count > 0 && Int.equal si clamped_sel
                    | None -> false
                  in
                  let rbg =
                    Color.of_rgb
                      (if is_sel then theme.selection_bg else theme.surface_2)
                  in
                  let title_st =
                    if is_sel then Typography.anchor ~bg:rbg theme
                    else Typography.primary ~bg:rbg theme
                  in
                  let meta_st = Typography.whisper ~bg:rbg theme in
                  (* Preserve semantic badge colors on calm selection_bg! *)
                  let badge_st =
                    match tone with
                    | Some tok -> Typography.status ~bg:rbg ~bold:true theme tok
                    | None -> Typography.accent ~bg:rbg ~bold:true theme
                  in
                  Cell_grid.fill_rect ~clip:inner grid ~rect:row_r
                    ~style:(Typography.primary ~bg:rbg theme) ();
                  if is_sel then
                    Cell_grid.put_glyph ~clip:row_r grid ~x:inner.x ~y:py
                      ~style:(Typography.accent ~bg:rbg ~bold:true theme)
                      Glyph.Left_rail;
                  let bx = inner.x + Int.max 2 pad_x in
                  let badge_w =
                    Int.min 12 (Int.max 4 (Grapheme.display_width badge))
                  in
                  ignore
                    (Cell_grid.put_text ~clip:row_r grid ~x:bx ~y:py
                       ~style:badge_st
                       (Grapheme.truncate_to_width ~max_width:badge_w badge));
                  let tx = bx + badge_w + 2 in
                  let meta_w =
                    if String.equal meta "" then 0
                    else Int.min (inner.w / 3) (Grapheme.display_width meta)
                  in
                  let mx = right_edge - meta_w in
                  let tw =
                    Int.max 0
                      ((if meta_w > 0 then mx - 2 else right_edge) - tx)
                  in
                  if tw > 0 then
                    ignore
                      (Cell_grid.put_text ~clip:row_r grid ~x:tx ~y:py
                         ~style:title_st
                         (Grapheme.truncate_to_width ~max_width:tw title));
                  if meta_w > 0 && mx > tx then
                    ignore
                      (Cell_grid.put_text ~clip:row_r grid ~x:mx ~y:py
                         ~style:meta_st
                         (Grapheme.truncate_to_width ~max_width:meta_w meta))
            end
          done
      end
    end

(* ---------- Overlay 2: , / Ctrl+, Complete 2-Pane Tree -> Property Inspector Settings ---------- *)

let compact_settings_tab_label ~(lang : Say.lang) ~compact tab =
  if not compact then Say.resolve lang (Nav.settings_tab_label tab)
  else
    match tab with
    | Nav.Settings_general_ui -> Say.resolve lang (Say.make ~ko:"일반·UI" ~en:"General")
    | Nav.Settings_providers_models -> Say.resolve lang (Say.make ~ko:"프로바이더" ~en:"Providers")
    | Nav.Settings_routing_failover -> Say.resolve lang (Say.make ~ko:"라우팅" ~en:"Routing")
    | Nav.Settings_keepers_companies -> Say.resolve lang (Say.make ~ko:"키퍼·조직" ~en:"Keepers")
    | Nav.Settings_sandbox_ssh -> Say.resolve lang (Say.make ~ko:"샌드박스" ~en:"Sandbox")
    | Nav.Settings_voice_integrations -> Say.resolve lang (Say.make ~ko:"음성·연동" ~en:"Voice")
    | Nav.Settings_board_memory_candle -> Say.resolve lang (Say.make ~ko:"기억·캔들" ~en:"Memory")

let settings_tab_number = function
  | Nav.Settings_general_ui -> 1
  | Nav.Settings_providers_models -> 2
  | Nav.Settings_routing_failover -> 3
  | Nav.Settings_keepers_companies -> 4
  | Nav.Settings_sandbox_ssh -> 5
  | Nav.Settings_voice_integrations -> 6
  | Nav.Settings_board_memory_candle -> 7

let form_provenance_of_wire ~target ~env = function
  | Wire_config.Prov_default -> Form.Prov_default
  | Wire_config.Prov_global | Wire_config.Prov_project -> Form.Prov_global_toml
  | Wire_config.Prov_keeper -> (
      match target with
      | Wire_config.Target_keeper name -> Form.Prov_keeper_toml name
      | Wire_config.Target_runtime | Wire_config.Target_keeper_create ->
          Form.Prov_keeper_toml "keeper")
  | Wire_config.Prov_env_override ->
      Form.Prov_env (match env with Some e -> e | None -> "ENV")

let form_reload_of_wire = function
  | Wire_config.Hot_reload -> Form.Hot_reload
  | Wire_config.Next_turn -> Form.Next_turn
  | Wire_config.Restart_required -> Form.Restart_required

let reload_token_of_form = function
  | Form.Hot_reload -> Theme.Status_ok
  | Form.Next_turn -> Theme.Status_active
  | Form.Restart_required -> Theme.Status_attention

let summarize_structured_json : Yojson.Safe.t -> string = function
  | `Assoc kvs -> Printf.sprintf "{%d keys}" (List.length kvs)
  | `List xs -> Printf.sprintf "[%d items]" (List.length xs)
  | `Bool b -> if b then "true" else "false"
  | `Int n -> Int.to_string n
  | `Intlit s -> s
  | `Float f -> Printf.sprintf "%g" f
  | `String s -> Grapheme.truncate_to_width ~max_width:24 s
  | `Null -> "null"

let form_value_of_wire_field (f : Wire_config.schema_field) =
  match f.kind with
  | Wire_config.Field_bool -> (
      match f.value with
      | Wire_config.Val_bool b -> Form.Bool_val b
      | Wire_config.Val_int _
      | Wire_config.Val_float _
      | Wire_config.Val_string _
      | Wire_config.Val_string_list _
      | Wire_config.Val_structured _
      | Wire_config.Val_secret _
      | Wire_config.Val_null ->
          Form.Bool_val false)
  | Wire_config.Field_int _ -> (
      match f.value with
      | Wire_config.Val_int n -> Form.int_val n
      | Wire_config.Val_float x -> Form.int_val (int_of_float x)
      | Wire_config.Val_string s -> Form.int_val_of_raw s
      | Wire_config.Val_bool _
      | Wire_config.Val_string_list _
      | Wire_config.Val_structured _
      | Wire_config.Val_secret _
      | Wire_config.Val_null ->
          Form.int_val_of_raw "")
  | Wire_config.Field_float _ -> (
      match f.value with
      | Wire_config.Val_float x -> Form.float_val x
      | Wire_config.Val_int n -> Form.float_val (float_of_int n)
      | Wire_config.Val_string s -> Form.float_val_of_raw s
      | Wire_config.Val_bool _
      | Wire_config.Val_string_list _
      | Wire_config.Val_structured _
      | Wire_config.Val_secret _
      | Wire_config.Val_null ->
          Form.float_val_of_raw "")
  | Wire_config.Field_enum allowed ->
      let cur =
        match f.value with
        | Wire_config.Val_string s -> s
        | Wire_config.Val_bool _
        | Wire_config.Val_int _
        | Wire_config.Val_float _
        | Wire_config.Val_string_list _
        | Wire_config.Val_structured _
        | Wire_config.Val_secret _
        | Wire_config.Val_null ->
            ""
      in
      let selected =
        let rec find i = function
          | [] -> 0
          | x :: _ when String.equal x cur -> i
          | _ :: rest -> find (i + 1) rest
        in
        find 0 allowed
      in
      let opts = List.map (fun s -> (s, Say.literal s)) allowed in
      Form.enum_val ~selected opts
  | Wire_config.Field_secret -> (
      match f.value with
      | Wire_config.Val_secret { configured = false; source = _ } ->
          Form.secret_val ~revealed:false ""
      | Wire_config.Val_secret
          { configured = true; source = Wire_config.Secret_env env_name } ->
          Form.Text_val (Printf.sprintf "[env:%s]" env_name)
      | Wire_config.Val_secret
          { configured = true; source = Wire_config.Secret_inline_redacted } ->
          Form.secret_val ~revealed:false "redacted"
      | Wire_config.Val_secret
          { configured = true; source = Wire_config.Secret_unset } ->
          Form.secret_val ~revealed:false ""
      | Wire_config.Val_bool _
      | Wire_config.Val_int _
      | Wire_config.Val_float _
      | Wire_config.Val_string _
      | Wire_config.Val_string_list _
      | Wire_config.Val_structured _
      | Wire_config.Val_null ->
          Form.secret_val ~revealed:false "")
  | Wire_config.Field_string -> (
      match f.value with
      | Wire_config.Val_string s -> Form.Text_val s
      | Wire_config.Val_null -> Form.Text_val ""
      | Wire_config.Val_bool b -> Form.Text_val (if b then "true" else "false")
      | Wire_config.Val_int n -> Form.Text_val (Int.to_string n)
      | Wire_config.Val_float x -> Form.Text_val (Printf.sprintf "%g" x)
      | Wire_config.Val_string_list xs -> Form.Text_val (String.concat ", " xs)
      | Wire_config.Val_structured j ->
          Form.Text_val (summarize_structured_json j)
      | Wire_config.Val_secret _ -> Form.secret_val ~revealed:false "redacted")
  | Wire_config.Field_string_list -> (
      match f.value with
      | Wire_config.Val_string_list xs -> Form.Text_val (String.concat ", " xs)
      | Wire_config.Val_string s -> Form.Text_val s
      | Wire_config.Val_bool _
      | Wire_config.Val_int _
      | Wire_config.Val_float _
      | Wire_config.Val_structured _
      | Wire_config.Val_secret _
      | Wire_config.Val_null ->
          Form.Text_val "")
  | Wire_config.Field_structured -> (
      match f.value with
      | Wire_config.Val_structured j ->
          Form.Text_val (summarize_structured_json j)
      | Wire_config.Val_bool _
      | Wire_config.Val_int _
      | Wire_config.Val_float _
      | Wire_config.Val_string _
      | Wire_config.Val_string_list _
      | Wire_config.Val_secret _
      | Wire_config.Val_null ->
          Form.Text_val "{structured}")

let apply_staged_op_to_value ~(kind : Wire_config.field_kind)
    (op : Wire_config.patch_op) =
  match op with
  | Wire_config.Set_bool { value; _ } -> Form.Bool_val value
  | Wire_config.Set_int { value; _ } -> Form.int_val value
  | Wire_config.Set_float { value; _ } -> Form.float_val value
  | Wire_config.Set_string_array { values; _ } ->
      Form.Text_val (String.concat ", " values)
  | Wire_config.Remove_key _ -> Form.Text_val "(removed)"
  | Wire_config.Set_scalar { value; _ } -> (
      match kind with
      | Wire_config.Field_enum allowed ->
          let selected =
            let rec find i = function
              | [] -> 0
              | x :: _ when String.equal x value -> i
              | _ :: rest -> find (i + 1) rest
            in
            find 0 allowed
          in
          Form.enum_val ~selected (List.map (fun s -> (s, Say.literal s)) allowed)
      | Wire_config.Field_bool
      | Wire_config.Field_int _
      | Wire_config.Field_float _
      | Wire_config.Field_string
      | Wire_config.Field_string_list
      | Wire_config.Field_structured
      | Wire_config.Field_secret ->
          Form.Text_val value)

let general_ui_fallback_fields (m : Model.t) =
  let theme_opts =
    List.map
      (fun p -> (Theme.preset_name p, Theme.preset_label p))
      Theme.all_presets
  in
  let theme_idx =
    let rec find i = function
      | [] -> 0
      | p :: _ when Theme.equal_preset p m.theme_preset -> i
      | _ :: rest -> find (i + 1) rest
    in
    find 0 Theme.all_presets
  in
  let lang_idx =
    match m.lang with Say.Lang_ko -> 0 | Say.Lang_en -> 1
  in
  let prefs = Observed.to_option m.config.preferences in
  let reduce_motion =
    match prefs with Some { reduce_motion = Some b; _ } -> b | _ -> false
  in
  let hints_visible =
    match prefs with Some { hints_visible = Some b; _ } -> b | _ -> true
  in
  let audio_dev =
    match prefs with
    | Some { audio_input_device = Some d; _ } -> d
    | _ -> "default"
  in
  [
    Form.make_field ~key:"tui.theme"
      ~label:(Say.make ~ko:"테마 프리셋" ~en:"Theme Preset")
      ~help:
        (Say.make ~ko:"WCAG >= 4.5:1 Oklab 4단계 표면 대비 보장 프리셋"
           ~en:"WCAG >= 4.5:1 Oklab 4-surface contrast theme preset")
      ~provenance:Form.Prov_tui_pref ~reload_scope:Form.Hot_reload
      (Form.enum_val ~selected:theme_idx theme_opts);
    Form.make_field ~key:"tui.language"
      ~label:(Say.make ~ko:"UI 언어" ~en:"UI Language")
      ~help:
        (Say.make ~ko:"KO / EN 전체 화면 원자적 전환"
           ~en:"Atomic KO / EN switch across all screens")
      ~provenance:Form.Prov_tui_pref ~reload_scope:Form.Hot_reload
      (Form.enum_val ~selected:lang_idx
         [
           ("ko", Say.make ~ko:"한국어" ~en:"Korean (KO)");
           ("en", Say.make ~ko:"English" ~en:"English (EN)");
         ]);
    Form.make_field ~key:"tui.hints_visible"
      ~label:(Say.make ~ko:"하단 단축키 힌트" ~en:"Footer Key Hints")
      ~help:
        (Say.make ~ko:"하단 키캡 단축키 안내 표시 여부"
           ~en:"Show quiet keycap hints in the bottom chrome bar")
      ~provenance:Form.Prov_tui_pref ~reload_scope:Form.Hot_reload
      (Form.Bool_val hints_visible);
    Form.make_field ~key:"tui.reduce_motion"
      ~label:(Say.make ~ko:"모션 줄이기" ~en:"Reduce Motion")
      ~help:
        (Say.make ~ko:"스피너·애니메이션 프레임 빈도 감소"
           ~en:"Reduce spinner and animation frame cadence")
      ~provenance:Form.Prov_tui_pref ~reload_scope:Form.Hot_reload
      (Form.Bool_val reduce_motion);
    Form.make_field ~key:"tui.audio_input_device"
      ~label:(Say.make ~ko:"음성 입력 장치" ~en:"Audio Input Device")
      ~help:
        (Say.make ~ko:"음성 PTT 녹음에 사용할 오디오 입력 장치"
           ~en:"Audio input device used for Voice PTT recording")
      ~provenance:Form.Prov_tui_pref ~reload_scope:Form.Hot_reload
      (Form.Text_val audio_dev);
  ]

let form_field_of_schema_field ~(m : Model.t) (f : Wire_config.schema_field) :
    Form.field =
  let initial = form_value_of_wire_field f in
  let value =
    match m.config.editing_field_key with
    | Some ek when String.equal ek f.full_key -> (
        match f.kind with
        | Wire_config.Field_int _ ->
            Form.int_val_of_raw m.config.editing_buffer
        | Wire_config.Field_float _ ->
            Form.float_val_of_raw m.config.editing_buffer
        | Wire_config.Field_bool
        | Wire_config.Field_string
        | Wire_config.Field_enum _
        | Wire_config.Field_string_list
        | Wire_config.Field_structured
        | Wire_config.Field_secret ->
            Form.Text_val m.config.editing_buffer)
    | Some _ | None -> (
        match
          Config_store.String_map.find_opt f.full_key m.config.dirty_fields
        with
        | Some op -> apply_staged_op_to_value ~kind:f.kind op
        | None -> initial)
  in
  let validators =
    match f.kind with
    | Wire_config.Field_int { min; max } -> [ Form.Int_range { min; max } ]
    | Wire_config.Field_float { min; max } -> [ Form.Float_range { min; max } ]
    | Wire_config.Field_bool
    | Wire_config.Field_string
    | Wire_config.Field_enum _
    | Wire_config.Field_string_list
    | Wire_config.Field_structured
    | Wire_config.Field_secret ->
        []
  in
  (* Always use clean KO/EN human leaf labels — ZERO raw truncated dotted keys *)
  let leaf_label =
    Say.make
      ~ko:(Config_store.field_label ~lang:Say.Lang_ko f)
      ~en:(Config_store.field_label ~lang:Say.Lang_en f)
  in
  let base =
    Form.make_field ~key:f.full_key ~label:leaf_label
      ?help:(Option.map Say.literal f.description)
      ~provenance:
        (form_provenance_of_wire ~target:m.config.target ~env:f.env
           f.provenance)
      ~reload_scope:(form_reload_of_wire f.reload_scope)
      ~validators ~read_only:(not f.writable || f.secret) initial
  in
  let updated = { base with value } in
  { updated with error = Form.validate_field updated }

let inspector_schema_fields (m : Model.t) =
  match Config_store.selected_section_fields m.config with
  | _ :: _ as fs -> fs
  | [] -> Config_store.visible_fields m.config

let settings_form_of_model (m : Model.t) : Form.state =
  let schema_fields = inspector_schema_fields m in
  let fields =
    if
      schema_fields = []
      && Nav.equal_settings_tab m.config.active_tab Nav.Settings_general_ui
      && String.equal (String.trim m.config.search_query) ""
    then general_ui_fallback_fields m
    else List.map (form_field_of_schema_field ~m) schema_fields
  in
  let st0 = Form.create fields in
  let n = Array.length st0.fields in
  let focused =
    if n <= 0 then 0
    else Int.max 0 (Int.min (n - 1) m.config.selected_field_index)
  in
  {
    st0 with
    focused;
    editing = Config_store.is_editing_field m.config;
    filter = "";
  }

let numbered_diff_of_patch_response (resp : Wire_config.patch_response) =
  if resp.diff_hunks <> [] then
    List.concat_map
      (fun (h : Wire_config.diff_hunk) ->
        let old_l = ref h.old_start in
        let new_l = ref h.new_start in
        List.map
          (fun line ->
            let len = String.length line in
            if len > 0 && Char.equal line.[0] '-' then begin
              let cur = !old_l in
              incr old_l;
              {
                Diff.nrow = Diff.Removed (String.sub line 1 (len - 1));
                old_line = Some cur;
                new_line = None;
              }
            end
            else if len > 0 && Char.equal line.[0] '+' then begin
              let cur = !new_l in
              incr new_l;
              {
                Diff.nrow = Diff.Added (String.sub line 1 (len - 1));
                old_line = None;
                new_line = Some cur;
              }
            end
            else begin
              let o = !old_l in
              let n = !new_l in
              incr old_l;
              incr new_l;
              let body =
                if len > 0 && Char.equal line.[0] ' ' then
                  String.sub line 1 (len - 1)
                else line
              in
              {
                Diff.nrow = Diff.Context body;
                old_line = Some o;
                new_line = Some n;
              }
            end)
          h.lines)
      resp.diff_hunks
  else if not (String.equal (String.trim resp.unified_diff) "") then
    let lines = String.split_on_char '\n' resp.unified_diff in
    let old_l = ref 1 in
    let new_l = ref 1 in
    List.filter_map
      (fun line ->
        let len = String.length line in
        if
          String.starts_with ~prefix:"--- " line
          || String.starts_with ~prefix:"+++ " line
          || String.starts_with ~prefix:"@@ " line
        then None
        else if len > 0 && Char.equal line.[0] '-' then begin
          let o = !old_l in
          incr old_l;
          Some
            {
              Diff.nrow = Diff.Removed (String.sub line 1 (len - 1));
              old_line = Some o;
              new_line = None;
            }
        end
        else if len > 0 && Char.equal line.[0] '+' then begin
          let n = !new_l in
          incr new_l;
          Some
            {
              Diff.nrow = Diff.Added (String.sub line 1 (len - 1));
              old_line = None;
              new_line = Some n;
            }
        end
        else begin
          let o = !old_l in
          let n = !new_l in
          incr old_l;
          incr new_l;
          let body =
            if len > 0 && Char.equal line.[0] ' ' then
              String.sub line 1 (len - 1)
            else line
          in
          Some
            {
              Diff.nrow = Diff.Context body;
              old_line = Some o;
              new_line = Some n;
            }
        end)
      lines
  else []

(* Multi-subgroup renderer: uses Wave A's 2-row surface_2 section header +
   Card.draw_hairline ~label sub-group dividers + exception-only chips +
   4-row Tier-4 italic help/diff footer when a Provider/Entity section spans
   2+ sub-groups (e.g. credentials, headers, healthcheck, usage-read). *)

type grouped_inspector_row =
  | Group_divider of string
  | Group_field of int * Form.field

let format_inspector_value ~lang = function
  | Form.Text_val s -> s
  | Form.Multiline_val s ->
      let lines = String.split_on_char '\n' s in
      let first = match lines with h :: _ -> h | [] -> "" in
      let count = List.length lines in
      if count <= 1 then first else Printf.sprintf "%s (+%dL)" first (count - 1)
  | Form.Int_val { raw; _ } | Form.Float_val { raw; _ } -> raw
  | Form.Bool_val b ->
      if b then
        Glyph.to_utf8 Glyph.Check_mark
        ^ " "
        ^ Say.resolve lang (Say.make ~ko:"켜짐" ~en:"ON")
      else
        Glyph.to_utf8 Glyph.Live_idle
        ^ " "
        ^ Say.resolve lang (Say.make ~ko:"꺼짐" ~en:"OFF")
  | Form.Enum_val { selected; options } ->
      if selected >= 0 && selected < Array.length options then
        Printf.sprintf "\xe2\x80\xb9 %s \xe2\x80\xba"
          (Say.resolve lang (snd options.(selected)))
      else "\xe2\x80\xb9\xe2\x80\xba"
  | Form.Secret_val { raw; revealed } ->
      if revealed then raw else Form.masked_display raw

let format_footer_diff_val ~after = function
  | Form.Text_val s -> Printf.sprintf "\"%s\"" s
  | Form.Multiline_val s -> Printf.sprintf "\"%s\"" (String.escaped s)
  | Form.Int_val { raw; _ } | Form.Float_val { raw; _ } -> raw
  | Form.Bool_val b -> if b then "true" else "false"
  | Form.Enum_val { selected; options } ->
      if selected >= 0 && selected < Array.length options then
        Printf.sprintf "\"%s\"" (fst options.(selected))
      else "\"\""
  | Form.Secret_val { raw; _ } ->
      if String.length raw = 0 then "\"(empty)\""
      else if after then "\"[redacted] (modified)\""
      else "\"[redacted]\""

let grouped_exception_chip ~lang ~(theme : Theme.t) ~bg
    ~(hdr : Form.section_header) (f : Form.field) =
  if not (Form.equal_field_value f.value f.initial) then
    Some
      ( Glyph.to_utf8 Glyph.Live_healthy
        ^ " "
        ^ Say.resolve lang (Say.make ~ko:"수정됨" ~en:"Modified"),
        Typography.status ~bg ~bold:true theme Theme.Status_attention )
  else
    match f.value with
    | Form.Secret_val { revealed = false; _ } ->
        Some
          ( Say.resolve lang (Say.make ~ko:"[비밀·마스킹]" ~en:"[Secret]"),
            Typography.whisper ~bg theme )
    | Form.Text_val _
    | Form.Multiline_val _
    | Form.Int_val _
    | Form.Float_val _
    | Form.Bool_val _
    | Form.Enum_val _
    | Form.Secret_val { revealed = true; _ } -> (
        match f.provenance with
        | Form.Prov_env _
          when not (Form.equal_provenance f.provenance hdr.provenance) ->
            Some
              ( Say.resolve lang (Say.make ~ko:"[환경변수]" ~en:"[Env]"),
                Typography.status ~bg theme Theme.Status_active )
        | Form.Prov_default
          when not (Form.equal_provenance f.provenance hdr.provenance) ->
            Some
              ( Say.resolve lang (Say.make ~ko:"[기본값]" ~en:"[Default]"),
                Typography.whisper ~bg theme )
        | Form.Prov_keeper_toml _
        | Form.Prov_global_toml
        | Form.Prov_tui_pref
        | Form.Prov_env _
        | Form.Prov_default ->
            if not (Form.equal_reload_scope f.reload_scope hdr.reload_scope) then
              Some
                ( Say.resolve lang (Form.reload_scope_label f.reload_scope),
                  Typography.status ~bg theme
                    (reload_token_of_form f.reload_scope) )
            else None)

let draw_grouped_section_form grid ~(rect : Rect.t) ~(theme : Theme.t) ~lang
    ~pad_x ~(hdr : Form.section_header) ~(form_state : Form.state)
    ~(schema_fields : Wire_config.schema_field list) ~(model : Model.t)
    ~insp_focused =
  if Rect.is_empty rect then ()
  else
    let bg_card = Color.of_rgb theme.surface_1 in
    let bg_hdr = Color.of_rgb theme.surface_2 in
    Cell_grid.fill_rect ~clip:rect grid ~rect
      ~style:(Typography.primary ~bg:bg_card theme) ();
    (* 1. Single 2-row surface_2 Section Provenance & Reload-Scope Header Band *)
    let hdr_h = if rect.h >= 5 then (if rect.h >= 8 then 3 else 2) else 0 in
    if hdr_h >= 2 then begin
      let band_r = Rect.make ~x:rect.x ~y:rect.y ~w:rect.w ~h:2 in
      Cell_grid.fill_rect ~clip:rect grid ~rect:band_r
        ~style:(Typography.primary ~bg:bg_hdr theme) ();
      let px = Int.max 0 (Int.min pad_x ((rect.w - 1) / 2)) in
      let ix = rect.x + px in
      let iw = Int.max 0 (rect.w - (2 * px)) in
      if iw > 0 then begin
        let row0 = Rect.make ~x:ix ~y:rect.y ~w:iw ~h:1 in
        let title = Say.resolve lang hdr.title in
        let pfx =
          match hdr.canonical_prefix with Some s -> String.trim s | None -> ""
        in
        let pw = Grapheme.display_width pfx in
        let tmax = if pw > 0 && iw > pw + 4 then iw - pw - 2 else iw in
        let adv =
          Cell_grid.put_text ~clip:row0 grid ~x:ix ~y:rect.y
            ~style:
              (if insp_focused then Typography.accent ~bg:bg_hdr ~bold:true theme
               else Typography.structure ~bg:bg_hdr ~bold:true theme)
            (Grapheme.truncate_to_width ~max_width:tmax title)
        in
        if pw > 0 && adv + 2 < iw then begin
          let fit_p = Grapheme.truncate_to_width ~max_width:(iw - adv - 2) pfx in
          let fw = Grapheme.display_width fit_p in
          ignore
            (Cell_grid.put_text ~clip:row0 grid ~x:(ix + iw - fw) ~y:rect.y
               ~style:(Typography.whisper ~bg:bg_hdr theme) fit_p)
        end;
        let row1 = Rect.make ~x:ix ~y:(rect.y + 1) ~w:iw ~h:1 in
        let prov_s =
          Say.resolve lang (Say.make ~ko:"출처: " ~en:"Source: ")
          ^ Say.resolve lang (Form.provenance_label hdr.provenance)
        in
        let apply_lbl =
          Typography.sep_dot
          ^ Say.resolve lang (Say.make ~ko:"적용: " ~en:"Apply: ")
        in
        let scope_s = Say.resolve lang (Form.reload_scope_label hdr.reload_scope) in
        let cx = ref ix in
        let a1 =
          Cell_grid.put_text ~clip:row1 grid ~x:!cx ~y:(rect.y + 1)
            ~style:(Typography.structure ~bg:bg_hdr theme) prov_s
        in
        cx := !cx + a1;
        let a2 =
          Cell_grid.put_text ~clip:row1 grid ~x:!cx ~y:(rect.y + 1)
            ~style:(Typography.whisper ~bg:bg_hdr ~italic:false theme) apply_lbl
        in
        cx := !cx + a2;
        ignore
          (Cell_grid.put_text ~clip:row1 grid ~x:!cx ~y:(rect.y + 1)
             ~style:
               (Typography.status ~bg:bg_hdr theme
                  (reload_token_of_form hdr.reload_scope))
             scope_s)
      end
    end;
    let body_top = rect.y + hdr_h in
    let body_avail = Int.max 0 (rect.h - hdr_h) in
    let footer_h = if body_avail >= 7 then 4 else 0 in
    let fields_h = Int.max 0 (body_avail - footer_h) in
    let fields_r = Rect.make ~x:rect.x ~y:body_top ~w:rect.w ~h:fields_h in
    let footer_r =
      Rect.make ~x:rect.x ~y:(Rect.bottom fields_r) ~w:rect.w ~h:footer_h
    in
    (* Build virtual row list interleaving Card.draw_hairline sub-group dividers *)
    let items_rev = ref [] in
    let prev_sg = ref None in
    let fields_arr = form_state.fields in
    if schema_fields = [] then
      Array.iteri
        (fun idx f -> items_rev := Group_field (idx, f) :: !items_rev)
        fields_arr
    else
      List.iteri
        (fun idx (sf : Wire_config.schema_field) ->
          if idx < Array.length fields_arr then begin
            let sg = Config_store.field_sub_group model.config sf in
            (match sg with
             | Some g when not (Option.equal String.equal !prev_sg (Some g)) ->
                 items_rev :=
                   Group_divider (Wire_config.sub_group_label ~lang g)
                   :: !items_rev
             | None when Option.is_some !prev_sg ->
                 items_rev :=
                   Group_divider
                     (Say.resolve lang (Say.make ~ko:"일반" ~en:"General"))
                   :: !items_rev
             | Some _ | None -> ());
            prev_sg := sg;
            items_rev := Group_field (idx, fields_arr.(idx)) :: !items_rev
          end)
        schema_fields;
    let rows_arr = Array.of_list (List.rev !items_rev) in
    let total_vrows = Array.length rows_arr in
    let focused_vpos =
      let rec find i =
        if i >= total_vrows then 0
        else
          match rows_arr.(i) with
          | Group_field (idx, _) when Int.equal idx form_state.focused -> i
          | Group_divider _ | Group_field _ -> find (i + 1)
      in
      find 0
    in
    let vrow_heights =
      Array.init total_vrows (fun i ->
          match rows_arr.(i) with
          | Group_divider _ -> 1
          | Group_field (_, f) -> (
              match f.error with Some _ -> 2 | None -> 1))
    in
    let start_vpos =
      if total_vrows = 0 || fields_r.h <= 0 then 0
      else
        let pos = Int.max 0 (Int.min (total_vrows - 1) focused_vpos) in
        let sum_to_pos = ref 0 in
        for i = 0 to pos do
          sum_to_pos := !sum_to_pos + vrow_heights.(i)
        done;
        if !sum_to_pos <= fields_r.h then 0
        else
          let used = ref vrow_heights.(pos) in
          let start = ref pos in
          while !start > 0 && !used + vrow_heights.(!start - 1) <= fields_r.h do
            decr start;
            used := !used + vrow_heights.(!start)
          done;
          !start
    in
    let rpad = Int.max 0 (Int.min pad_x ((fields_r.w - 1) / 4)) in
    let rail_x = fields_r.x + rpad in
    let label_x = rail_x + 2 in
    let usable_w = Int.max 0 (fields_r.w - (2 * rpad)) in
    let label_w = Int.max 12 (Int.min 22 (usable_w / 3)) in
    let right_edge = Rect.right fields_r - rpad in
    let y = ref fields_r.y in
    let bottom = Rect.bottom fields_r in
    for vpos = start_vpos to total_vrows - 1 do
      if !y < bottom then
        match rows_arr.(vpos) with
        | Group_divider label ->
            Card.draw_hairline ~pad_x:rpad ~label ~bg:bg_card grid ~rect:fields_r
              ~y:!y ~theme;
            incr y
        | Group_field (idx, f) ->
            let is_selected = Int.equal idx form_state.focused in
            let is_focused = is_selected && insp_focused in
            let row_bg_rgb =
              if is_focused then theme.selection_bg else theme.surface_1
            in
            let rbg = Color.of_rgb row_bg_rgb in
            let row_r = Rect.make ~x:fields_r.x ~y:!y ~w:fields_r.w ~h:1 in
            Cell_grid.fill_rect ~clip:fields_r grid ~rect:row_r
              ~style:(Typography.primary ~bg:rbg theme) ();
            if is_focused then
              Cell_grid.put_glyph ~clip:row_r grid ~x:rail_x ~y:!y
                ~style:(Typography.accent ~bg:rbg ~bold:true theme)
                Glyph.Left_rail;
            let lbl_st =
              if is_focused then Typography.anchor ~bg:rbg theme
              else if is_selected then Typography.primary ~bg:rbg theme
              else Typography.structure ~bg:rbg theme
            in
            ignore
              (Cell_grid.put_text ~clip:row_r grid ~x:label_x ~y:!y
                 ~style:lbl_st
                 (Grapheme.truncate_to_width ~max_width:label_w
                    (Say.resolve lang f.label)));
            let val_x = label_x + label_w + 2 in
            let avail_right = Int.max 0 (right_edge - val_x) in
            let chip = grouped_exception_chip ~lang ~theme ~bg:rbg ~hdr f in
            let chip_w =
              match chip with
              | Some (s, _) -> Grapheme.display_width s
              | None -> 0
            in
            let show_chip = chip_w > 0 && avail_right > chip_w + 8 in
            let val_w =
              if show_chip then avail_right - chip_w - 2 else avail_right
            in
            let val_str = format_inspector_value ~lang f.value in
            let val_fg =
              match f.value with
              | Form.Bool_val true -> theme.status_ok
              | Form.Bool_val false -> theme.text_muted
              | Form.Secret_val { revealed = false; _ } -> theme.status_attention
              | Form.Text_val _
              | Form.Multiline_val _
              | Form.Int_val _
              | Form.Float_val _
              | Form.Enum_val _
              | Form.Secret_val { revealed = true; _ } ->
                  if f.read_only then theme.text_muted
                  else if is_focused then theme.text_bright
                  else theme.text_primary
            in
            let val_attrs =
              if is_focused && form_state.editing then Attr.underline
              else
                match f.value with
                | Form.Bool_val true -> Attr.bold
                | Form.Bool_val false
                | Form.Text_val _
                | Form.Multiline_val _
                | Form.Int_val _
                | Form.Float_val _
                | Form.Enum_val _
                | Form.Secret_val _ ->
                    Attr.none
            in
            let val_st =
              Style.make ~fg:(Color.of_rgb val_fg) ~bg:rbg ~attrs:val_attrs ()
            in
            if val_w > 0 then
              ignore
                (Cell_grid.put_text ~clip:row_r grid ~x:val_x ~y:!y
                   ~style:val_st
                   (Grapheme.truncate_to_width ~max_width:val_w val_str));
            (match chip with
             | Some (cs, cst) when show_chip ->
                 ignore
                   (Cell_grid.put_text ~clip:row_r grid
                      ~x:(right_edge - chip_w) ~y:!y ~style:cst cs)
             | Some _ | None -> ());
            incr y;
            (match f.error with
             | Some err when !y < bottom ->
                 let err_r = Rect.make ~x:fields_r.x ~y:!y ~w:fields_r.w ~h:1 in
                 let err_st =
                   Typography.status ~bg:bg_card ~bold:true theme
                     Theme.Status_critical
                 in
                 Cell_grid.put_glyph ~clip:err_r grid ~x:rail_x ~y:!y
                   ~style:err_st Glyph.Left_rail;
                 ignore
                   (Cell_grid.put_text ~clip:err_r grid ~x:label_x ~y:!y
                      ~style:err_st
                      (Grapheme.truncate_to_width
                         ~max_width:(Int.max 0 (right_edge - label_x))
                         (Glyph.to_utf8 Glyph.Live_failing
                          ^ " "
                          ^ Say.resolve lang err)));
                 incr y
             | Some _ | None -> ())
    done;
    (* 3. Dedicated 4-row Tier-4 italic focused field key/help/diff footer *)
    if footer_h >= 3 then begin
      Card.draw_hairline ~pad_x:rpad ~bg:bg_card grid ~rect:footer_r
        ~y:footer_r.y ~theme;
      let focused_f =
        if
          form_state.focused >= 0
          && form_state.focused < Array.length form_state.fields
        then Some form_state.fields.(form_state.focused)
        else None
      in
      let fx = footer_r.x + rpad in
      let fw = Int.max 0 (footer_r.w - (2 * rpad)) in
      match focused_f with
      | None -> ()
      | Some f ->
          let y1 = footer_r.y + 1 in
          if y1 < Rect.bottom footer_r then begin
            let r1 = Rect.make ~x:fx ~y:y1 ~w:fw ~h:1 in
            let kp = Say.resolve lang (Say.make ~ko:"키: " ~en:"Key: ") in
            let adv =
              Cell_grid.put_text ~clip:r1 grid ~x:fx ~y:y1
                ~style:(Typography.whisper ~bg:bg_card ~italic:false theme) kp
            in
            ignore
              (Cell_grid.put_text ~clip:r1 grid ~x:(fx + adv) ~y:y1
                 ~style:(Typography.structure ~bg:bg_card theme)
                 (Grapheme.truncate_to_width ~max_width:(Int.max 0 (fw - adv))
                    f.key))
          end;
          let y2 = footer_r.y + 2 in
          if y2 < Rect.bottom footer_r then begin
            let r2 = Rect.make ~x:fx ~y:y2 ~w:fw ~h:1 in
            match (f.error, f.help) with
            | Some err, _ ->
                ignore
                  (Cell_grid.put_text ~clip:r2 grid ~x:fx ~y:y2
                     ~style:
                       (Typography.status ~bg:bg_card ~bold:true theme
                          Theme.Status_critical)
                     (Grapheme.truncate_to_width ~max_width:fw
                        (Glyph.to_utf8 Glyph.Live_failing
                         ^ " "
                         ^ Say.resolve lang err)))
            | None, Some h ->
                ignore
                  (Cell_grid.put_text ~clip:r2 grid ~x:fx ~y:y2
                     ~style:(Typography.whisper ~bg:bg_card theme)
                     (Grapheme.truncate_to_width ~max_width:fw
                        (Say.resolve lang h)))
            | None, None ->
                ignore
                  (Cell_grid.put_text ~clip:r2 grid ~x:fx ~y:y2
                     ~style:(Typography.whisper ~bg:bg_card theme)
                     (Grapheme.truncate_to_width ~max_width:fw
                        (Say.resolve lang
                           (Say.make
                              ~ko:"[Enter] 편집 · [Space] Dry-run · [Ctrl+S] 저장"
                              ~en:"[Enter] Edit · [Space] Dry-run · [Ctrl+S] Save"))))
          end;
          let y3 = footer_r.y + 3 in
          if y3 < Rect.bottom footer_r then begin
            let r3 = Rect.make ~x:fx ~y:y3 ~w:fw ~h:1 in
            if not (Form.equal_field_value f.value f.initial) then begin
              let before_s = format_footer_diff_val ~after:false f.initial in
              let after_s = format_footer_diff_val ~after:true f.value in
              let lbl =
                Say.resolve lang (Say.make ~ko:"변경: " ~en:"Changed: ")
              in
              let cx = ref fx in
              let a0 =
                Cell_grid.put_text ~clip:r3 grid ~x:!cx ~y:y3
                  ~style:(Typography.whisper ~bg:bg_card ~italic:false theme) lbl
              in
              cx := !cx + a0;
              let a1 =
                Cell_grid.put_text ~clip:r3 grid ~x:!cx ~y:y3
                  ~style:
                    (Typography.status ~bg:bg_card theme Theme.Status_critical)
                  before_s
              in
              cx := !cx + a1;
              let a2 =
                Cell_grid.put_text ~clip:r3 grid ~x:!cx ~y:y3
                  ~style:(Typography.whisper ~bg:bg_card ~italic:false theme)
                  " -> "
              in
              cx := !cx + a2;
              ignore
                (Cell_grid.put_text ~clip:r3 grid ~x:!cx ~y:y3
                   ~style:
                     (Typography.status ~bg:bg_card ~bold:true theme
                        Theme.Status_ok)
                   (Grapheme.truncate_to_width
                      ~max_width:(Int.max 0 (fx + fw - !cx))
                      after_s))
            end
            else
              ignore
                (Cell_grid.put_text ~clip:r3 grid ~x:fx ~y:y3
                   ~style:(Typography.whisper ~bg:bg_card theme)
                   (Grapheme.truncate_to_width ~max_width:fw
                      (Say.resolve lang
                         (Say.make
                            ~ko:"[Tab] 좌/우 전환 · [Enter] 편집 · [Space] Dry-run"
                            ~en:"[Tab] Switch pane · [Enter] Edit · [Space] Dry-run"))))
          end
    end

let render_settings_tree_pane grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) =
  if Rect.is_empty rect then ()
  else
    let lang = model.lang in
    let bg = Color.of_rgb theme.surface_1 in
    Cell_grid.fill_rect ~clip:rect grid ~rect
      ~style:(Typography.primary ~bg theme) ();
    let rows = Config_store.visible_tree_rows model.config in
    let arr = Array.of_list rows in
    let total = Array.length arr in
    let tree_focused =
      Config_store.equal_settings_pane model.config.settings_pane
        Config_store.Pane_tree
    in
    let body_r =
      if rect.h >= 4 then begin
        let hdr_r = Rect.make ~x:rect.x ~y:rect.y ~w:rect.w ~h:1 in
        let hdr_bg =
          Color.of_rgb (if tree_focused then theme.surface_2 else theme.surface_1)
        in
        Cell_grid.fill_rect ~clip:rect grid ~rect:hdr_r
          ~style:(Typography.primary ~bg:hdr_bg theme) ();
        if tree_focused then
          Cell_grid.put_glyph ~clip:hdr_r grid ~x:rect.x ~y:rect.y
            ~style:(Typography.accent ~bg:hdr_bg ~bold:true theme)
            Glyph.Left_rail;
        let hdr_lbl =
          if tree_focused then
            Say.resolve lang
              (Say.make ~ko:"▸ 탐색 트리 · 활성" ~en:"▸ TREE · FOCUS")
          else
            Say.resolve lang
              (Say.make ~ko:"  탐색 트리 [Tab]" ~en:"  Tree [Tab]")
        in
        let hdr_st =
          if tree_focused then Typography.accent ~bg:hdr_bg ~bold:true theme
          else Typography.whisper ~bg:hdr_bg theme
        in
        ignore
          (Cell_grid.put_text ~clip:hdr_r grid ~x:(rect.x + 1) ~y:rect.y
             ~style:hdr_st
             (Grapheme.truncate_to_width ~max_width:(Int.max 0 (rect.w - 2))
                hdr_lbl));
        Rect.make ~x:rect.x ~y:(rect.y + 1) ~w:rect.w ~h:(rect.h - 1)
      end
      else rect
    in
    let sel_idx =
      if total <= 0 then 0
      else Int.max 0 (Int.min (total - 1) model.config.selected_section_idx)
    in
    let active_sec_id =
      match Config_store.selected_section model.config with
      | Some s -> Some s.section_id
      | None -> None
    in
    let active_sec_row_idx =
      match active_sec_id with
      | None -> None
      | Some sid ->
          let rec find i =
            if i >= total then None
            else
              match arr.(i) with
              | Config_store.Tree_section s
                when String.equal s.section_id sid ->
                  Some i
              | Config_store.Tree_section _
              | Config_store.Tree_category _
              | Config_store.Tree_models_catalog_toggle _ ->
                  find (i + 1)
          in
          find 0
    in
    let effective_sel_idx =
      if tree_focused then sel_idx
      else match active_sec_row_idx with Some i -> i | None -> sel_idx
    in
    let start, _ =
      Table.compute_viewport ~total_rows:total ~viewport_rows:body_r.h
        ~scroll:model.config.tree_scroll_offset
        ~selected:(Some effective_sel_idx)
    in
    let compact_tree = body_r.w <= 25 in
    for i = 0 to body_r.h - 1 do
      let idx = start + i in
      if idx < total then begin
        let py = body_r.y + i in
        let row_r = Rect.make ~x:body_r.x ~y:py ~w:body_r.w ~h:1 in
        match arr.(idx) with
        | Config_store.Tree_category
            { category = _; tab; collapsed; section_count; field_count; dirty_count } ->
            let is_sel = Int.equal idx effective_sel_idx in
            let rbg =
              Color.of_rgb
                (if is_sel then theme.selection_bg else theme.surface_1)
            in
            Cell_grid.fill_rect ~clip:body_r grid ~rect:row_r
              ~style:(Typography.primary ~bg:rbg theme) ();
            if is_sel && tree_focused then
              Cell_grid.put_glyph ~clip:row_r grid ~x:body_r.x ~y:py
                ~style:
                  (Style.make ~fg:(Color.of_rgb theme.accent) ~bg:rbg
                     ~attrs:Attr.bold ())
                Glyph.Left_rail;
            let chev =
              if collapsed then Glyph.to_utf8 Glyph.Expand_closed
              else Glyph.to_utf8 Glyph.Expand_open
            in
            let num = settings_tab_number tab in
            let lbl =
              compact_settings_tab_label ~lang ~compact:compact_tree tab
            in
            let count_n =
              if field_count > 0 then field_count else section_count
            in
            let count_s =
              if count_n > 0 then Printf.sprintf "(%d)" count_n else ""
            in
            let dirty_s =
              if dirty_count > 0 then Glyph.to_utf8 Glyph.Live_healthy ^ " "
              else ""
            in
            let right_w =
              Grapheme.display_width dirty_s + Grapheme.display_width count_s
            in
            let left_x = body_r.x + 1 in
            let right_edge = Rect.right body_r - 1 in
            let left_max =
              Int.max 0 (right_edge - left_x - right_w - (if right_w > 0 then 1 else 0))
            in
            let txt = Printf.sprintf "%s %d %s" chev num lbl in
            let txt_st =
              if is_sel && tree_focused then Typography.anchor ~bg:rbg theme
              else if is_sel then Typography.structure ~bg:rbg ~bold:true theme
              else Typography.structure ~bg:rbg ~bold:true theme
            in
            if left_max > 0 then
              ignore
                (Cell_grid.put_text ~clip:row_r grid ~x:left_x ~y:py
                   ~style:txt_st
                   (Grapheme.truncate_to_width ~max_width:left_max txt));
            let rx = ref (right_edge - right_w) in
            if dirty_count > 0 && !rx > left_x then begin
              let d_adv =
                Cell_grid.put_text ~clip:row_r grid ~x:!rx ~y:py
                  ~style:
                    (Typography.status ~bg:rbg ~bold:true theme
                       Theme.Status_attention)
                  dirty_s
              in
              rx := !rx + d_adv
            end;
            if String.length count_s > 0 && !rx > left_x then
              ignore
                (Cell_grid.put_text ~clip:row_r grid ~x:!rx ~y:py
                   ~style:(Typography.whisper ~bg:rbg theme) count_s)
        | Config_store.Tree_models_catalog_toggle
            { expanded; model_count; dirty_count } ->
            let is_sel = Int.equal idx effective_sel_idx in
            let rbg =
              Color.of_rgb
                (if is_sel then theme.selection_bg else theme.surface_1)
            in
            Cell_grid.fill_rect ~clip:body_r grid ~rect:row_r
              ~style:(Typography.primary ~bg:rbg theme) ();
            if is_sel && tree_focused then
              Cell_grid.put_glyph ~clip:row_r grid ~x:body_r.x ~y:py
                ~style:
                  (Style.make ~fg:(Color.of_rgb theme.accent) ~bg:rbg
                     ~attrs:Attr.bold ())
                Glyph.Left_rail;
            let chev =
              if expanded then Glyph.to_utf8 Glyph.Expand_open
              else Glyph.to_utf8 Glyph.Expand_closed
            in
            let lbl =
              Say.resolve lang
                (Say.make
                   ~ko:(Printf.sprintf "%s 모델 카탈로그 (%d개)" chev model_count)
                   ~en:(Printf.sprintf "%s Models Catalog (%d)" chev model_count))
            in
            let left_x = body_r.x + 3 in
            let right_edge = Rect.right body_r - 1 in
            let dirty_w = if dirty_count > 0 then 2 else 0 in
            let max_w = Int.max 0 (right_edge - left_x - dirty_w) in
            let st =
              if is_sel && tree_focused then Typography.anchor ~bg:rbg theme
              else Typography.whisper ~bg:rbg theme
            in
            if max_w > 0 then
              ignore
                (Cell_grid.put_text ~clip:row_r grid ~x:left_x ~y:py ~style:st
                   (Grapheme.truncate_to_width ~max_width:max_w lbl));
            if dirty_count > 0 then
              Cell_grid.put_glyph ~clip:row_r grid ~x:(right_edge - 1) ~y:py
                ~style:
                  (Typography.status ~bg:rbg ~bold:true theme
                     Theme.Status_attention)
                Glyph.Live_healthy
        | Config_store.Tree_section sec ->
            let is_sel = Int.equal idx effective_sel_idx in
            let rbg =
              Color.of_rgb
                (if is_sel then theme.selection_bg else theme.surface_1)
            in
            Cell_grid.fill_rect ~clip:body_r grid ~rect:row_r
              ~style:(Typography.primary ~bg:rbg theme) ();
            if is_sel && tree_focused then
              Cell_grid.put_glyph ~clip:row_r grid ~x:body_r.x ~y:py
                ~style:
                  (Style.make ~fg:(Color.of_rgb theme.accent) ~bg:rbg
                     ~attrs:Attr.bold ())
                Glyph.Left_rail;
            let indent = if sec.is_catalog_group then 4 else 3 in
            let left_x = body_r.x + indent in
            let right_edge = Rect.right body_r - 1 in
            let right_str, right_st =
              if sec.dirty_count > 0 then
                ( Glyph.to_utf8 Glyph.Live_healthy,
                  Typography.status ~bg:rbg ~bold:true theme
                    Theme.Status_attention )
              else
                ( Printf.sprintf "%d" sec.badge_count,
                  Typography.whisper ~bg:rbg theme )
            in
            let rw = Grapheme.display_width right_str in
            let max_w = Int.max 0 (right_edge - left_x - rw - 1) in
            let title_st =
              if is_sel && tree_focused then Typography.anchor ~bg:rbg theme
              else if is_sel then Typography.structure ~bg:rbg ~bold:true theme
              else Typography.primary ~bg:rbg theme
            in
            if max_w > 0 then
              ignore
                (Cell_grid.put_text ~clip:row_r grid ~x:left_x ~y:py
                   ~style:title_st
                   (Grapheme.truncate_to_width ~max_width:max_w sec.title));
            if rw > 0 && right_edge - rw > left_x then
              ignore
                (Cell_grid.put_text ~clip:row_r grid ~x:(right_edge - rw) ~y:py
                   ~style:right_st right_str)
      end
    done

let render_dry_run_pane grid ~(rect : Rect.t) ~(theme : Theme.t) ~lang ~pad_x
    ~(dry_run_preview : Config_store.dry_run_state) =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    Cell_grid.fill_rect ~clip:rect grid ~rect
      ~style:(Typography.primary ~bg theme) ();
    Card.draw_hairline ~pad_x ~label:"Dry-run TOML Diff" ~bg grid ~rect
      ~y:rect.y ~theme;
    let content = Rect.inset ~left:pad_x ~right:pad_x rect in
    let y = ref (rect.y + 1) in
    let bottom = Rect.bottom rect in
    let put style txt =
      if !y < bottom && content.w > 0 then begin
        let rr = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:1 in
        ignore
          (Cell_grid.put_text ~clip:rr grid ~x:content.x ~y:!y ~style
             (Grapheme.truncate_to_width ~max_width:content.w txt));
        incr y
      end
    in
    match dry_run_preview with
    | Config_store.Dry_run_idle -> ()
    | Config_store.Dry_run_loading ->
        put (Typography.status ~bg ~bold:true theme Theme.Status_attention)
          (Say.resolve lang
             (Say.make
                ~ko:(Glyph.to_utf8 Glyph.Transport_reconnecting ^ " TOML Diff 검증 중 (dry_run)...")
                ~en:(Glyph.to_utf8 Glyph.Transport_reconnecting ^ " Computing TOML dry_run diff...")))
    | Config_store.Dry_run_failed err ->
        put (Typography.status ~bg ~bold:true theme Theme.Status_critical)
          (Printf.sprintf "%s dry_run: %s" (Glyph.to_utf8 Glyph.Live_failing) err)
    | Config_store.Dry_run_ready resp ->
        let rel =
          Say.resolve lang
            (Form.reload_scope_label (form_reload_of_wire resp.reload_scope))
        in
        put (Typography.status ~bg ~bold:true theme Theme.Status_ok)
          (Say.resolve lang
             (Say.make
                ~ko:(Printf.sprintf "%s Dry-run 검증 통과 · %s"
                       (Glyph.to_utf8 Glyph.Check_mark) rel)
                ~en:(Printf.sprintf "%s Dry-run valid · %s"
                       (Glyph.to_utf8 Glyph.Check_mark) rel)));
        List.iter
          (fun w ->
            put (Typography.status ~bg ~bold:true theme Theme.Status_attention)
              (Printf.sprintf "%s %s" (Glyph.to_utf8 Glyph.Warning_triangle) w))
          resp.validation_warnings;
        let diff_rows = numbered_diff_of_patch_response resp in
        if diff_rows <> [] && !y < bottom && content.w > 0 then
          let diff_r =
            Rect.make ~x:content.x ~y:!y ~w:content.w ~h:(Int.max 0 (bottom - !y))
          in
          ignore
            (Diff.draw grid ~rect:diff_r ~theme ~language:Code_lexer.Toml
               diff_rows)

let section_base_provenance ~target (sec : Config_store.settings_tree_section) =
  (* Prefer file-level provenance (Global/Project/Keeper TOML) as the section
     header when any non-env field carries it, so single env-overridden secrets
     render cleanly as exception chips instead of relabeling the whole entity
     as "Env:ENV". *)
  let file_prov =
    List.find_map
      (fun (f : Wire_config.schema_field) ->
        match f.provenance with
        | Wire_config.Prov_keeper ->
            Some (form_provenance_of_wire ~target ~env:f.env f.provenance)
        | Wire_config.Prov_global | Wire_config.Prov_project ->
            Some Form.Prov_global_toml
        | Wire_config.Prov_default | Wire_config.Prov_env_override -> None)
      sec.fields
  in
  match file_prov with
  | Some p -> p
  | None ->
      let first_env =
        List.find_map (fun (f : Wire_config.schema_field) -> f.env) sec.fields
      in
      form_provenance_of_wire ~target ~env:first_env sec.provenance

let render_settings_inspector_pane grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) =
  if Rect.is_empty rect then ()
  else
    let lang = model.lang in
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = if rect.w >= 50 then 2 else 1 in
    let insp_focused =
      Config_store.equal_settings_pane model.config.settings_pane
        Config_store.Pane_inspector
    in
    Cell_grid.fill_rect ~clip:rect grid ~rect
      ~style:(Typography.primary ~bg theme) ();
    (* Pane Focus Header Bar so Tab switch between Tree and Inspector is unmistakable *)
    let rect =
      if rect.h >= 4 then begin
        let hdr_r = Rect.make ~x:rect.x ~y:rect.y ~w:rect.w ~h:1 in
        let hdr_bg =
          Color.of_rgb (if insp_focused then theme.surface_2 else theme.surface_1)
        in
        Cell_grid.fill_rect ~clip:rect grid ~rect:hdr_r
          ~style:(Typography.primary ~bg:hdr_bg theme) ();
        if insp_focused then
          Cell_grid.put_glyph ~clip:hdr_r grid ~x:rect.x ~y:rect.y
            ~style:(Typography.accent ~bg:hdr_bg ~bold:true theme)
            Glyph.Left_rail;
        let hdr_lbl =
          if insp_focused then
            Say.resolve lang
              (Say.make ~ko:"▸ 속성 검사기 · 활성  [Enter] 편집 · [Del] 삭제"
                 ~en:"▸ INSPECTOR · FOCUS  [Enter] Edit · [Del] Remove")
          else
            Say.resolve lang
              (Say.make ~ko:"  속성 검사기  [Tab]으로 포커스 이동"
                 ~en:"  Inspector  [Tab] to focus")
        in
        let hdr_st =
          if insp_focused then Typography.accent ~bg:hdr_bg ~bold:true theme
          else Typography.whisper ~bg:hdr_bg theme
        in
        ignore
          (Cell_grid.put_text ~clip:hdr_r grid ~x:(rect.x + pad_x) ~y:rect.y
             ~style:hdr_st
             (Grapheme.truncate_to_width
                ~max_width:(Int.max 0 (rect.w - (2 * pad_x)))
                hdr_lbl));
        Rect.make ~x:rect.x ~y:(rect.y + 1) ~w:rect.w ~h:(rect.h - 1)
      end
      else rect
    in
    (* Optional 1-row New Keeper Name input banner when Target_keeper_create *)
    let rect =
      match model.config.target with
      | Wire_config.Target_keeper_create when rect.h >= 5 ->
          let kr = Rect.make ~x:rect.x ~y:rect.y ~w:rect.w ~h:1 in
          let editing_name = Config_store.is_editing_new_keeper_name model.config in
          let kbg =
            Color.of_rgb (if editing_name then theme.selection_bg else theme.surface_2)
          in
          Cell_grid.fill_rect ~clip:rect grid ~rect:kr
            ~style:(Typography.primary ~bg:kbg theme) ();
          let kst, ktxt =
            if editing_name then
              ( Typography.anchor ~bg:kbg theme
              , Say.resolve lang
                  (Say.make
                     ~ko:(Printf.sprintf "새 키퍼 이름: %s_  [Enter] 확정 · [Esc] 취소"
                            model.config.editing_buffer)
                     ~en:(Printf.sprintf "New keeper name: %s_  [Enter] Confirm · [Esc] Cancel"
                            model.config.editing_buffer)) )
            else if String.equal (String.trim model.config.new_keeper_name) "" then
              ( Typography.status ~bg:kbg ~bold:true theme Theme.Status_attention
              , Say.resolve lang
                  (Say.make
                     ~ko:"△ 새 키퍼 이름 미지정 — [n] 키로 이름을 입력하세요"
                     ~en:"△ New keeper name unset — press [n] to enter name") )
            else
              ( Typography.status ~bg:kbg ~bold:true theme Theme.Status_ok
              , Say.resolve lang
                  (Say.make
                     ~ko:(Printf.sprintf "✓ 새 키퍼: %s  ([n] 변경 · [Space] 검증 · [Ctrl+S] 생성)"
                            model.config.new_keeper_name)
                     ~en:(Printf.sprintf "✓ New keeper: %s  ([n] Rename · [Space] Diff · [Ctrl+S] Create)"
                            model.config.new_keeper_name)) )
          in
          ignore
            (Cell_grid.put_text ~clip:kr grid ~x:(rect.x + pad_x) ~y:rect.y
               ~style:kst
               (Grapheme.truncate_to_width
                  ~max_width:(Int.max 0 (rect.w - (2 * pad_x)))
                  ktxt));
          Rect.make ~x:rect.x ~y:(rect.y + 1) ~w:rect.w ~h:(rect.h - 1)
      | Wire_config.Target_keeper_create
      | Wire_config.Target_runtime
      | Wire_config.Target_keeper _ ->
          rect
    in
    (* Optional 1-row Save Receipt / Snapshot Banner at top when present *)
    let save_banner_opt =
      match model.config.save_state with
      | Config_store.Save_in_flight ->
          Some
            ( Typography.status ~bg ~bold:true theme Theme.Status_attention,
              Say.resolve lang
                (Say.make
                   ~ko:(Glyph.to_utf8 Glyph.Live_working ^ " 원자적 저장 중...")
                   ~en:(Glyph.to_utf8 Glyph.Live_working ^ " Saving atomically..."))
            )
      | Config_store.Save_succeeded resp ->
          let sid =
            match resp.snapshot_id with Some s -> s | None -> resp.new_sha256
          in
          let rel =
            Say.resolve lang
              (Form.reload_scope_label (form_reload_of_wire resp.reload_scope))
          in
          Some
            ( Typography.status ~bg ~bold:true theme Theme.Status_ok,
              Say.resolve lang
                (Say.make
                   ~ko:(Printf.sprintf "%s 저장됨 · snapshot:%s · %s"
                          (Glyph.to_utf8 Glyph.Check_mark) sid rel)
                   ~en:(Printf.sprintf "%s Saved · snapshot:%s · %s"
                          (Glyph.to_utf8 Glyph.Check_mark) sid rel)) )
      | Config_store.Save_failed err ->
          Some
            ( Typography.status ~bg ~bold:true theme Theme.Status_critical,
              Printf.sprintf "%s %s" (Glyph.to_utf8 Glyph.Live_failing) err )
      | Config_store.Save_idle -> (
          match model.config.last_snapshot_id with
          | Some sid ->
              Some
                ( Typography.status ~bg theme Theme.Status_ok,
                  Say.resolve lang
                    (Say.make
                       ~ko:(Printf.sprintf "%s 최근 스냅샷: %s"
                              (Glyph.to_utf8 Glyph.Check_mark) sid)
                       ~en:(Printf.sprintf "%s Last snapshot: %s"
                              (Glyph.to_utf8 Glyph.Check_mark) sid)) )
          | None -> None)
    in
    let work_r =
      match save_banner_opt with
      | Some (st, txt) when rect.h >= 6 ->
          let br = Rect.make ~x:rect.x ~y:rect.y ~w:rect.w ~h:1 in
          Cell_grid.fill_rect ~clip:rect grid ~rect:br
            ~style:(Typography.primary ~bg:(Color.of_rgb theme.surface_2) theme)
            ();
          ignore
            (Cell_grid.put_text ~clip:br grid ~x:(rect.x + pad_x) ~y:rect.y
               ~style:
                 { st with bg = Color.of_rgb theme.surface_2 }
               (Grapheme.truncate_to_width
                  ~max_width:(Int.max 0 (rect.w - (2 * pad_x)))
                  txt));
          Rect.make ~x:rect.x ~y:(rect.y + 1) ~w:rect.w ~h:(rect.h - 1)
      | Some _ | None -> rect
    in
    let has_dry_run =
      match model.config.dry_run_preview with
      | Config_store.Dry_run_idle -> false
      | Config_store.Dry_run_loading
      | Config_store.Dry_run_ready _
      | Config_store.Dry_run_failed _ ->
          true
    in
    let form_r, dry_r =
      if has_dry_run && work_r.h >= 10 then
        let desired_dry =
          match model.config.dry_run_preview with
          | Config_store.Dry_run_ready resp ->
              let n_rows = List.length (numbered_diff_of_patch_response resp) in
              Int.min (work_r.h / 2) (Int.max 5 (n_rows + 3))
          | Config_store.Dry_run_loading | Config_store.Dry_run_failed _ -> 3
          | Config_store.Dry_run_idle -> 0
        in
        let top_h = Int.max 5 (work_r.h - desired_dry) in
        Rect.split_v work_r ~top_h
      else (work_r, Rect.empty)
    in
    let schema_fields = inspector_schema_fields model in
    let form_state = settings_form_of_model model in
    let section_header : Form.section_header =
      match Config_store.selected_section model.config with
      | Some sec ->
          {
            title = Say.literal sec.title;
            canonical_prefix = Some sec.subtitle;
            provenance =
              section_base_provenance ~target:model.config.target sec;
            reload_scope = form_reload_of_wire sec.reload_scope;
          }
      | None ->
          if Nav.equal_settings_tab model.config.active_tab Nav.Settings_general_ui
          then
            {
              title = Say.make ~ko:"일반 · UI 환경설정" ~en:"General & UI Preferences";
              canonical_prefix = Some "tui";
              provenance = Form.Prov_tui_pref;
              reload_scope = Form.Hot_reload;
            }
          else
            {
              title = Nav.settings_tab_label model.config.active_tab;
              canonical_prefix = None;
              provenance = Form.Prov_default;
              reload_scope = Form.Hot_reload;
            }
    in
    if Array.length form_state.fields = 0 then begin
      (* Calm empty / loading state inside Right Inspector *)
      let msg =
        match model.config.schema with
        | Observed.Loading _ ->
            Say.resolve lang
              (Say.make
                 ~ko:(Glyph.to_utf8 Glyph.Transport_reconnecting ^ " 설정 스키마 불러오는 중...")
                 ~en:(Glyph.to_utf8 Glyph.Transport_reconnecting ^ " Loading configuration schema..."))
        | Observed.Failed { reason; _ } ->
            Printf.sprintf "%s %s" (Glyph.to_utf8 Glyph.Live_failing) reason
        | Observed.Value _ | Observed.Absent | Observed.Unreported ->
            if not (String.equal (String.trim model.config.search_query) "") then
              Say.resolve lang
                (Say.make ~ko:"검색어와 일치하는 설정 항목이 없습니다."
                   ~en:"No configuration fields match the search query.")
            else
              Say.resolve lang
                (Say.make ~ko:"왼쪽 트리에서 카테고리 또는 엔티티를 선택하세요."
                   ~en:"Select a category or entity from the left tree.")
      in
      let st =
        match model.config.schema with
        | Observed.Failed _ ->
            Typography.status ~bg ~bold:true theme Theme.Status_critical
        | Observed.Loading _ | Observed.Value _ | Observed.Absent
        | Observed.Unreported ->
            Typography.whisper ~bg theme
      in
      ignore
        (Cell_grid.put_text ~clip:form_r grid ~x:(form_r.x + pad_x)
           ~y:(form_r.y + 1) ~style:st
           (Grapheme.truncate_to_width
              ~max_width:(Int.max 0 (form_r.w - (2 * pad_x)))
              msg))
    end
    else
      draw_grouped_section_form grid ~rect:form_r ~theme ~lang ~pad_x
        ~hdr:section_header ~form_state ~schema_fields ~model ~insp_focused;
    if not (Rect.is_empty dry_r) then
      render_dry_run_pane grid ~rect:dry_r ~theme ~lang ~pad_x
        ~dry_run_preview:model.config.dry_run_preview

let render_settings grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~active_tab:_ =
  (* Full overlay rect so underlying workspace chrome never bleeds at col 0 / right wall *)
  let modal_r = rect in
  if Rect.is_empty modal_r then ()
  else
    let lang = model.lang in
    let dirty_n = Config_store.dirty_count model.config in
    let title =
      Say.resolve lang
        (Say.make ~ko:"설정 · Configuration" ~en:"Settings · Configuration")
    in
    let badge =
      if dirty_n > 0 then
        Some
          {
            Card.glyph = Some Glyph.Live_healthy;
            text =
              Say.resolve lang
                (Say.make
                   ~ko:(Printf.sprintf "변경 %d건" dirty_n)
                   ~en:(Printf.sprintf "%d modified" dirty_n));
            tone = Some Theme.Status_attention;
          }
      else None
    in
    let hotkey =
      if modal_r.w < 110 then
        Say.resolve lang
          (Say.make ~ko:"[^S] 저장 · [Space] 검증 · [Esc] 닫기"
             ~en:"[^S] Save · [Space] Diff · [Esc] Close")
      else
        Say.resolve lang
          (Say.make ~ko:"[Space] Dry-run · [Ctrl+S] 저장 · [Esc] 닫기"
             ~en:"[Space] Dry-run · [Ctrl+S] Save · [Esc] Close")
    in
    let footer_hint =
      Say.resolve lang
        (Say.make ~ko:"[Tab] 좌/우 전환 · [Enter] 편집 · [Del] 삭제 · [/] 검색"
           ~en:"[Tab] Switch pane · [Enter] Edit · [Del] Remove · [/] Search")
    in
    let inner =
      Card.draw ~cache grid ~rect:modal_r ~theme
        {
          (Card.default_spec ~title) with
          badge;
          hotkey = Some hotkey;
          footer_hint = Some footer_hint;
          focused = true;
          elevated = false;
        }
    in
    if not (Rect.is_empty inner) then begin
      let bg = Color.of_rgb theme.surface_1 in
      let pill_bg = Color.of_rgb theme.surface_2 in
      let pad_x = if inner.w >= 96 then 2 else 1 in
      let struct_st = Typography.structure ~bg theme in
      let whisper_st = Typography.whisper ~bg theme in
      let attn_st =
        Typography.status ~bg ~bold:true theme Theme.Status_attention
      in
      (* Row 0: Target Switcher + Global / Search Pill + Dirty / Keycap Strip *)
      let top_r = Rect.make ~x:inner.x ~y:inner.y ~w:inner.w ~h:1 in
      let tx = ref (inner.x + pad_x) in
      let target_prefix =
        Say.resolve lang (Say.make ~ko:"대상: " ~en:"Target: ")
      in
      let p_adv =
        Cell_grid.put_text ~clip:top_r grid ~x:!tx ~y:inner.y ~style:struct_st
          target_prefix
      in
      tx := !tx + p_adv;
      let target_pill =
        match model.config.target with
        | Wire_config.Target_runtime -> " runtime.toml "
        | Wire_config.Target_keeper name -> Printf.sprintf " keeper:%s " name
        | Wire_config.Target_keeper_create ->
            let kn =
              if Config_store.is_editing_new_keeper_name model.config then
                model.config.editing_buffer ^ "_"
              else if String.equal (String.trim model.config.new_keeper_name) ""
              then "<new: press n>"
              else model.config.new_keeper_name
            in
            Printf.sprintf " + %s " kn
      in
      let tp_adv =
        Cell_grid.put_text ~clip:top_r grid ~x:!tx ~y:inner.y
          ~style:(Typography.accent ~bg:pill_bg ~bold:true theme)
          (" " ^ Glyph.to_utf8 Glyph.Live_healthy)
      in
      tx := !tx + tp_adv;
      let tn_adv =
        Cell_grid.put_text ~clip:top_r grid ~x:!tx ~y:inner.y
          ~style:(Typography.anchor ~bg:pill_bg theme)
          target_pill
      in
      tx := !tx + tn_adv + 2;
      (* Global / Search Pill with live cross-section match count *)
      let q_trimmed = String.trim model.config.search_query in
      let match_sec_count, match_field_count =
        if String.equal q_trimmed "" then (0, 0)
        else
          let secs = Config_store.tree_sections model.config in
          let f_tot =
            List.fold_left
              (fun acc (s : Config_store.settings_tree_section) ->
                acc + s.badge_count)
              0 secs
          in
          (List.length secs, f_tot)
      in
      let search_txt, search_st =
        if model.nav.filter_focused then
          let count_tag =
            if String.equal q_trimmed "" then ""
            else
              Say.resolve lang
                (Say.make
                   ~ko:(Printf.sprintf " (%d섹션·%d항목)" match_sec_count
                          match_field_count)
                   ~en:(Printf.sprintf " (%d sec · %d)" match_sec_count
                          match_field_count))
          in
          ( Printf.sprintf " / %s_%s " model.config.search_query count_tag,
            Typography.anchor ~bg:(Color.of_rgb theme.selection_bg) theme )
        else if not (String.equal q_trimmed "") then
          ( Printf.sprintf " / %s · %d " q_trimmed match_field_count,
            Typography.accent ~bg:pill_bg ~bold:true theme )
        else
          ( Say.resolve lang
              (Say.make ~ko:"[/] 모든 설정 검색..." ~en:"[/] Search all settings..."),
            whisper_st )
      in
      let right_edge = Rect.right inner - pad_x in
      let right_dirty_txt =
        if dirty_n > 0 then
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "%s 변경 %d건"
                      (Glyph.to_utf8 Glyph.Live_healthy) dirty_n)
               ~en:(Printf.sprintf "%s %d modified"
                      (Glyph.to_utf8 Glyph.Live_healthy) dirty_n))
        else ""
      in
      let rd_w = Grapheme.display_width right_dirty_txt in
      let search_max_w =
        Int.max 0 (right_edge - rd_w - (if rd_w > 0 then 2 else 0) - !tx)
      in
      if search_max_w > 6 then
        ignore
          (Cell_grid.put_text ~clip:top_r grid ~x:!tx ~y:inner.y ~style:search_st
             (Grapheme.truncate_to_width ~max_width:search_max_w search_txt));
      if rd_w > 0 && right_edge - rd_w > !tx + 4 then
        ignore
          (Cell_grid.put_text ~clip:top_r grid ~x:(right_edge - rd_w) ~y:inner.y
             ~style:attn_st right_dirty_txt);
      (* Row 1: Subtle border_subtle horizontal hairline *)
      if inner.h >= 2 then
        Card.draw_hairline ~bg grid ~rect:inner ~y:(inner.y + 1) ~theme;
      (* Rows 2..end: 2-Pane Tree -> Property Inspector *)
      let body_r =
        Rect.make ~x:inner.x ~y:(inner.y + 2) ~w:inner.w
          ~h:(Int.max 0 (inner.h - 2))
      in
      if not (Rect.is_empty body_r) then begin
        if body_r.w >= 72 then
          let tree_w = if body_r.w >= 100 then 32 else 24 in
          let tree_r = Rect.make ~x:body_r.x ~y:body_r.y ~w:tree_w ~h:body_r.h in
          let div_x = Rect.right tree_r in
          let insp_x = div_x + 1 in
          let insp_r =
            Rect.make ~x:insp_x ~y:body_r.y
              ~w:(Int.max 0 (Rect.right body_r - insp_x))
              ~h:body_r.h
          in
          render_settings_tree_pane grid ~rect:tree_r ~theme ~model;
          Card.draw_v_hairline ~bg grid ~x:div_x ~y:body_r.y ~h:body_r.h ~theme;
          render_settings_inspector_pane grid ~rect:insp_r ~theme ~model
        else begin
          (* Micro (<72 cols): 1-row breadcrumb picker + full-width Property Inspector *)
          let crumb_r = Rect.make ~x:body_r.x ~y:body_r.y ~w:body_r.w ~h:1 in
          let sec_title =
            match Config_store.selected_section model.config with
            | Some s -> s.title
            | None ->
                Say.resolve lang (Nav.settings_tab_label model.config.active_tab)
          in
          let crumb =
            Printf.sprintf "%s %d %s %s %s"
              (Glyph.to_utf8 Glyph.Expand_open)
              (settings_tab_number model.config.active_tab)
              (compact_settings_tab_label ~lang ~compact:true
                 model.config.active_tab)
              (Glyph.to_utf8 Glyph.Prompt_caret)
              sec_title
          in
          ignore
            (Cell_grid.put_text ~clip:crumb_r grid ~x:(crumb_r.x + 1) ~y:crumb_r.y
               ~style:(Typography.accent ~bg ~bold:true theme)
               (Grapheme.truncate_to_width ~max_width:(Int.max 0 (crumb_r.w - 2))
                  crumb));
          let insp_r =
            Rect.make ~x:body_r.x ~y:(body_r.y + 1) ~w:body_r.w
              ~h:(Int.max 0 (body_r.h - 1))
          in
          render_settings_inspector_pane grid ~rect:insp_r ~theme ~model
        end
      end
    end

(* ---------- Overlay 3: I / Alt+I Muted Incident & Diagnostics Drawer ---------- *)

let incident_source_label ~lang = function
  | Health.Source_keeper name ->
      Say.resolve lang (Say.make ~ko:("키퍼:" ^ name) ~en:("Keeper:" ^ name))
  | Health.Source_runtime id ->
      Say.resolve lang (Say.make ~ko:("런타임:" ^ id) ~en:("Runtime:" ^ id))
  | Health.Source_sandbox name ->
      Say.resolve lang (Say.make ~ko:("샌드박스:" ^ name) ~en:("Sandbox:" ^ name))
  | Health.Source_client_http ->
      Say.resolve lang (Say.make ~ko:"클라이언트 HTTP" ~en:"Client HTTP")
  | Health.Source_stream ->
      Say.resolve lang (Say.make ~ko:"SSE 스트림" ~en:"SSE Stream")

let incident_status_label ~lang = function
  | Health.Resolved ->
      (Glyph.Historical_incident, Say.resolve lang (Say.make ~ko:"해결됨" ~en:"RESOLVED"))
  | Health.Retried ->
      (Glyph.Recovered, Say.resolve lang (Say.make ~ko:"재시도됨" ~en:"RETRIED"))
  | Health.Superseded ->
      (Glyph.Historical_incident, Say.resolve lang (Say.make ~ko:"대체됨" ~en:"SUPERSEDED"))
  | Health.Dismissed ->
      (Glyph.Live_idle, Say.resolve lang (Say.make ~ko:"숨김" ~en:"DISMISSED"))

let render_incidents_drawer grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) =
  let drawer_w =
    if rect.w >= 110 then Int.min 94 (rect.w * 2 / 3)
    else Int.max 0 (rect.w - 2)
  in
  let drawer_h = Int.max 0 (rect.h - 2) in
  let drawer_r =
    if rect.w >= 110 then
      Rect.make ~x:(Rect.right rect - drawer_w - 1) ~y:(rect.y + 1) ~w:drawer_w
        ~h:drawer_h
    else center_rect ~outer:rect ~w:drawer_w ~h:drawer_h
  in
  if Rect.is_empty drawer_r then ()
  else
    let lang = model.lang in
    let active_n = Incidents.active_count model.incidents in
    let title =
      Say.resolve lang
        (Say.make
           ~ko:(Printf.sprintf "%s 장애 · 진단 이력 (Ch 3)"
                  (Glyph.to_utf8 Glyph.Historical_incident))
           ~en:(Printf.sprintf "%s Incident & Diagnostics Ledger (Ch 3)"
                  (Glyph.to_utf8 Glyph.Historical_incident)))
    in
    let badge : Card.badge =
      {
        glyph = Some Glyph.Historical_incident;
        text =
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "활성 %d" active_n)
               ~en:(Printf.sprintf "%d active" active_n));
        tone = Some Theme.Status_historical;
      }
    in
    let hotkey =
      Say.resolve lang
        (Say.make ~ko:"[d] 숨김 · [c/D] 전체 비우기 · [o] 리소스 이동 · [Esc]"
           ~en:"[d] Dismiss · [c/D] Clear · [o] Jump · [Esc]")
    in
    let inner =
      Card.draw ~cache grid ~rect:drawer_r ~theme
        {
          (Card.default_spec ~title) with
          badge = Some badge;
          hotkey = Some hotkey;
          focused = true;
          elevated = true;
        }
    in
    if not (Rect.is_empty inner) then begin
      let pad_x = if inner.w >= 56 then 2 else 1 in
      let bg = Color.of_rgb theme.surface_2 in
      let hist_st =
        Typography.status ~bg ~bold:true theme Theme.Status_historical
      in
      let struct_st = Typography.structure ~bg theme in
      let whisper_st = Typography.whisper ~bg theme in
      let entries = Incidents.visible_entries model.incidents in
      let hdr_r =
        Rect.make ~x:(inner.x + pad_x) ~y:inner.y
          ~w:(Int.max 0 (inner.w - (2 * pad_x)))
          ~h:1
      in
      let note =
        Say.resolve lang
          (Say.make
             ~ko:"과거/해결 이력은 실시간 상태 표시줄을 붉게 물들이지 않습니다."
             ~en:"Historical Channel-3 trail — never taints live SSOT health.")
      in
      ignore
        (Cell_grid.put_text ~clip:hdr_r grid ~x:hdr_r.x ~y:inner.y
           ~style:whisper_st
           (Grapheme.truncate_to_width ~max_width:hdr_r.w note));
      let content_r =
        Rect.make ~x:inner.x ~y:(inner.y + 1) ~w:inner.w
          ~h:(Int.max 0 (inner.h - 1))
      in
      if entries = [] then
        ignore
          (Cell_grid.put_text ~clip:content_r grid ~x:(content_r.x + pad_x)
             ~y:(content_r.y + 1) ~style:whisper_st
             (Say.resolve lang
                (Say.make
                   ~ko:(Glyph.to_utf8 Glyph.Live_healthy ^ " 기록된 과거 장애 이력이 없습니다.")
                   ~en:(Glyph.to_utf8 Glyph.Live_healthy ^ " No historical incidents recorded."))))
      else
        let list_r, detail_r =
          if content_r.h >= 10 then
            match
              Layout.split_v ~gap:1 content_r
                [ Layout.Ratio 0.45; Layout.Flex 1 ]
            with
            | [ l; d ] -> (l, d)
            | _ -> (content_r, Rect.empty)
          else (content_r, Rect.empty)
        in
        let arr = Array.of_list entries in
        let total = Array.length arr in
        let sel =
          Int.max 0 (Int.min (total - 1) model.incidents.selected_index)
        in
        let start, _ =
          Table.compute_viewport ~total_rows:total ~viewport_rows:list_r.h
            ~scroll:model.incidents.scroll_offset ~selected:(Some sel)
        in
        let right_edge = Rect.right list_r - pad_x in
        for i = 0 to list_r.h - 1 do
          let idx = start + i in
          if idx < total then begin
            let inc = arr.(idx) in
            let py = list_r.y + i in
            let row_r = Rect.make ~x:list_r.x ~y:py ~w:list_r.w ~h:1 in
            let is_sel = Int.equal idx sel in
            let rbg =
              Color.of_rgb
                (if is_sel then theme.selection_bg else theme.surface_2)
            in
            let main_st =
              if is_sel then Typography.anchor ~bg:rbg theme
              else Typography.primary ~bg:rbg theme
            in
            let badge_st =
              Typography.status ~bg:rbg ~bold:true theme Theme.Status_historical
            in
            let age_st = Typography.whisper ~bg:rbg theme in
            Cell_grid.fill_rect ~clip:list_r grid ~rect:row_r
              ~style:(Typography.primary ~bg:rbg theme) ();
            if is_sel then
              Cell_grid.put_glyph ~clip:row_r grid ~x:list_r.x ~y:py
                ~style:badge_st Glyph.Left_rail;
            let g, st_lbl = incident_status_label ~lang inc.status in
            let src = incident_source_label ~lang inc.source in
            let age =
              match
                Render_util.format_relative_age
                  ~now_unix:model.freshness.last_wall_unix
                  ~at_unix:inc.occurred_at_unix
              with
              | Some a -> a
              | None -> (
                  match
                    Render_util.format_hhmm_with_offset
                      ~tz_offset_sec:model.tz_offset_sec inc.occurred_at_unix
                  with
                  | Some hh -> hh
                  | None -> "")
            in
            let lx = list_r.x + Int.max 2 pad_x in
            let prefix =
              Printf.sprintf "%s [%s] %s · " (Glyph.to_utf8 g) st_lbl src
            in
            let p_adv =
              Cell_grid.put_text ~clip:row_r grid ~x:lx ~y:py ~style:badge_st
                prefix
            in
            let age_w = Grapheme.display_width age in
            let ax = right_edge - age_w in
            let sw = Int.max 0 (ax - (lx + p_adv) - 1) in
            if sw > 2 then
              ignore
                (Cell_grid.put_text ~clip:row_r grid ~x:(lx + p_adv) ~y:py
                   ~style:main_st
                   (Grapheme.truncate_to_width ~max_width:sw
                      (Say.resolve lang inc.summary)));
            if age_w > 0 && ax > lx + p_adv then
              ignore
                (Cell_grid.put_text ~clip:row_r grid ~x:ax ~y:py ~style:age_st
                   age)
          end
        done;
        if not (Rect.is_empty detail_r) then begin
          Card.draw_hairline ~pad_x ~bg grid ~rect:content_r
            ~y:(Int.max content_r.y (detail_r.y - 1))
            ~theme;
          let d_pad = Card.pad_inner ~pad_x detail_r in
          match Incidents.selected_entry model.incidents with
          | None -> ()
          | Some inc ->
              let g, st_lbl = incident_status_label ~lang inc.status in
              let src = incident_source_label ~lang inc.source in
              let head =
                Printf.sprintf "%s [%s] %s · %s" (Glyph.to_utf8 g) st_lbl src
                  (Say.resolve lang inc.summary)
              in
              ignore
                (Cell_grid.put_text ~clip:d_pad grid ~x:d_pad.x ~y:d_pad.y
                   ~style:hist_st
                   (Grapheme.truncate_to_width ~max_width:d_pad.w head));
              let payload_r =
                Rect.make ~x:d_pad.x ~y:(d_pad.y + 1) ~w:d_pad.w
                  ~h:(Int.max 0 (d_pad.h - 1))
              in
              if not (Rect.is_empty payload_r) then
                match Render_util.extract_embedded_json inc.detail with
                | Some (prefix_opt, json) ->
                    let tree_r =
                      match prefix_opt with
                      | Some prefix when payload_r.h >= 2 ->
                          let safe_prefix =
                            Render_util.redact_plain_text_secrets prefix
                          in
                          let prefix_r =
                            Rect.make ~x:payload_r.x ~y:payload_r.y
                              ~w:payload_r.w ~h:1
                          in
                          ignore
                            (Cell_grid.put_text ~clip:prefix_r grid
                               ~x:payload_r.x ~y:payload_r.y ~style:struct_st
                               (Grapheme.truncate_to_width
                                  ~max_width:payload_r.w safe_prefix));
                          Rect.make ~x:payload_r.x ~y:(payload_r.y + 1)
                            ~w:payload_r.w ~h:(payload_r.h - 1)
                      | Some _ | None -> payload_r
                    in
                    let lines =
                      Json_tree.flatten ~max_depth:4 ~redact_secrets:true json
                    in
                    ignore (Json_tree.draw grid ~rect:tree_r ~theme lines)
                | None ->
                    let safe_detail =
                      Render_util.redact_plain_text_secrets inc.detail
                    in
                    ignore
                      (Markdown.draw grid ~rect:payload_r ~theme
                         ~osc8:caps.osc8_hyperlinks safe_detail)
        end
    end

(* ---------- Overlay 4: Ctrl+T Keeper Queue, Context & Schedules Drawer ---------- *)

let render_queue_context_drawer grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~active_tab =
  let w = Int.min (Int.max 0 (rect.w - 2)) (Int.max 76 (rect.w * 3 / 4)) in
  let h = Int.min (Int.max 0 (rect.h - 2)) 24 in
  let modal_r = center_rect ~outer:rect ~w ~h in
  if Rect.is_empty modal_r then ()
  else
    let lang = model.lang in
    let keeper = Render_util.target_keeper_of_model model in
    let display_keeper = Render_util.display_target_keeper_of_model model in
    let title =
      Say.resolve lang
        (Say.make
           ~ko:(Printf.sprintf "Ctrl+T · @%s 대기열 · 컨텍스트 · 일정" display_keeper)
           ~en:(Printf.sprintf "Ctrl+T · @%s Queue, Context & Schedules" display_keeper))
    in
    let inner =
      Card.draw ~cache grid ~rect:modal_r ~theme
        {
          (Card.default_spec ~title) with
          hotkey =
            Some
              (Say.resolve lang
                 (Say.make ~ko:"[ ] 탭 · [Esc] 닫기" ~en:"[ ] Tab · [Esc] Close"));
          focused = true;
          elevated = true;
        }
    in
    if not (Rect.is_empty inner) then begin
      let pad_x = if inner.w >= 56 then 2 else 1 in
      let bg = Color.of_rgb theme.surface_2 in
      let pri_st = Typography.primary ~bg theme in
      let struct_st = Typography.structure ~bg theme in
      let whisper_st = Typography.whisper ~bg theme in
      let acc_st = Typography.accent ~bg ~bold:true theme in
      let ok_st = Typography.status ~bg ~bold:true theme Theme.Status_ok in
      let attn_st =
        Typography.status ~bg ~bold:true theme Theme.Status_attention
      in
      let crit_st =
        Typography.status ~bg ~bold:true theme Theme.Status_critical
      in
      (* Calm v2.5 Sub-tabs — Left_rail + Bold underlined text_bright, ZERO cobalt block *)
      let tab_r = Rect.make ~x:inner.x ~y:inner.y ~w:inner.w ~h:1 in
      let tx = ref (inner.x + pad_x) in
      List.iter
        (fun t ->
          let lbl =
            match t with
            | Nav.Drawer_queue ->
                Say.resolve lang
                  (Say.make ~ko:"대기열 [Steer/FollowUp/Carry]"
                     ~en:"Queue [Steer/FollowUp/Carry]")
            | Nav.Drawer_context ->
                Say.resolve lang
                  (Say.make ~ko:"컨텍스트 · 캐시" ~en:"Context Window & Cache")
            | Nav.Drawer_schedules ->
                Say.resolve lang
                  (Say.make ~ko:"일정 (Schedules)" ~en:"Schedules")
          in
          let is_act = Nav.equal_queue_context_tab t active_tab in
          if is_act then begin
            let a0 =
              Cell_grid.put_text ~clip:tab_r grid ~x:!tx ~y:inner.y ~style:acc_st
                (Glyph.to_utf8 Glyph.Left_rail ^ " ")
            in
            tx := !tx + a0;
            let a1 =
              Cell_grid.put_text ~clip:tab_r grid ~x:!tx ~y:inner.y
                ~style:(Typography.anchor ~bg ~underline:true theme)
                lbl
            in
            tx := !tx + a1 + 3
          end
          else begin
            let adv =
              Cell_grid.put_text ~clip:tab_r grid ~x:!tx ~y:inner.y
                ~style:struct_st lbl
            in
            tx := !tx + adv + 3
          end)
        Nav.all_queue_context_tabs;
      if inner.h >= 2 then
        Card.draw_hairline ~pad_x ~bg grid ~rect:inner ~y:(inner.y + 1) ~theme;
      let body_r =
        Card.pad_inner ~pad_x
          (Rect.make ~x:inner.x ~y:(inner.y + 2) ~w:inner.w
             ~h:(Int.max 0 (inner.h - 2)))
      in
      if not (Rect.is_empty body_r) then
        match active_tab with
        | Nav.Drawer_queue ->
            let y = ref body_r.y in
            let bottom = Rect.bottom body_r in
            let put style txt =
              if !y < bottom then begin
                let r = Rect.make ~x:body_r.x ~y:!y ~w:body_r.w ~h:1 in
                ignore
                  (Cell_grid.put_text ~clip:r grid ~x:body_r.x ~y:!y ~style
                     (Grapheme.truncate_to_width ~max_width:body_r.w txt));
                incr y
              end
            in
            let txs = Drafts.pending_txs_for_keeper ~keeper model.drafts in
            let draft = Drafts.draft_for ~keeper model.drafts in
            put (Typography.anchor ~bg theme)
              (Say.resolve lang
                 (Say.make
                    ~ko:(Printf.sprintf "전송 대기열 (%d건)" (List.length txs))
                    ~en:(Printf.sprintf "Pending Transmissions (%d)"
                           (List.length txs))));
            if txs = [] then
              put whisper_st
                (Say.resolve lang
                   (Say.make ~ko:"  진행 중인 전송 없음"
                      ~en:"  No active transmissions"))
            else
              List.iter
                (fun (tx : Drafts.pending_message) ->
                  let mode_s =
                    match tx.mode with
                    | Drafts.Mode_steer -> "[Steer]"
                    | Drafts.Mode_follow_up -> "[FollowUp]"
                  in
                  let st_s, st_style =
                    match tx.state with
                    | Drafts.Delivered ->
                        ( Say.resolve lang
                            (Say.make ~ko:"전송 완료" ~en:"Delivered"),
                          ok_st )
                    | Drafts.Failed_retryable { reason } ->
                        ( Say.resolve lang
                            (Say.make ~ko:("재시도: " ^ reason)
                               ~en:("Retry: " ^ reason)),
                          crit_st )
                    | Drafts.Queued
                    | Drafts.Sending
                    | Drafts.Pending_processing
                    | Drafts.Confirming_delivery ->
                        let lbl =
                          match Drafts.tx_state_label tx.state with
                          | Some s -> Say.resolve lang s
                          | None -> "Active"
                        in
                        (lbl, attn_st)
                  in
                  let body_one =
                    String.map (function '\n' | '\r' -> ' ' | c -> c) tx.body
                  in
                  put st_style
                    (Printf.sprintf "  %s %s (%s) · %s" mode_s st_s tx.request_id
                       body_one))
                txs;
            if !y < bottom then incr y;
            put (Typography.anchor ~bg theme)
              (Say.resolve lang
                 (Say.make ~ko:"보존 초안 (Carry)" ~en:"Preserved Draft (Carry)"));
            let draft_empty = String.equal (String.trim draft.text) "" in
            if draft_empty then
              put whisper_st
                (Say.resolve lang (Say.make ~ko:"  비어 있음" ~en:"  Empty"))
            else
              put pri_st
                ("  "
                 ^ String.map (function '\n' | '\r' -> ' ' | c -> c) draft.text);
            let others = Drafts.other_keepers_draft_count model.drafts in
            if others > 0 then
              put whisper_st
                (Say.resolve lang
                   (Say.make
                      ~ko:(Printf.sprintf "  다른 키퍼 초안 %d건 보존 중" others)
                      ~en:(Printf.sprintf "  %d other keeper draft(s) preserved"
                             others)))
        | Nav.Drawer_context ->
            let keeper_opt = Fleet_store.find_keeper ~name:keeper model.fleet in
            let eff_row =
              match Observed.to_option model.runtime.efficiency with
              | None -> None
              | Some eff ->
                  List.find_opt
                    (fun (r : Wire_runtime.keeper_efficiency_row) ->
                      String.equal r.keeper keeper)
                    eff.keepers
            in
            let y = ref body_r.y in
            let bottom = Rect.bottom body_r in
            let ctx_obs =
              match keeper_opt with
              | Some k -> Observed.map (fun r -> r *. 100.0) k.context_ratio
              | None -> Observed.unreported
            in
            if body_r.h >= 3 then begin
              let gauge_r = Rect.make ~x:body_r.x ~y:!y ~w:body_r.w ~h:2 in
              let spec : Chart.Spec.t =
                {
                  title =
                    Say.make ~ko:"컨텍스트 윈도우 점유율"
                      ~en:"Context Window Fill";
                  kind =
                    Chart.Spec.Ratio_gauge
                      {
                        used = ctx_obs;
                        limit = Observed.value ~observed_at:Clock.Mono.zero 100.0;
                        unit = Format_val.Percent;
                        gradient = Chart.Gradient.Thermal;
                        reset_hint = None;
                      };
                  hotkey_hint = None;
                }
              in
              ignore (Chart.draw grid ~rect:gauge_r ~theme ~caps ~lang spec);
              y := !y + 3
            end;
            (match eff_row with
             | Some r when !y + 2 <= bottom ->
                 let cache_r =
                   match Observed.to_option r.cache_read_tokens with
                   | Some v -> float_of_int v
                   | None -> 0.0
                 in
                 let cache_w =
                   match Observed.to_option r.cache_creation_tokens with
                   | Some v -> float_of_int v
                   | None -> 0.0
                 in
                 let uncached =
                   Float.max 0.0
                     (float_of_int r.input_tokens -. cache_r -. cache_w)
                 in
                 let out_tok = float_of_int r.output_tokens in
                 let bar_r = Rect.make ~x:body_r.x ~y:!y ~w:body_r.w ~h:3 in
                 let spec : Chart.Spec.t =
                   {
                     title =
                       Say.make ~ko:"프롬프트 캐시 구성"
                         ~en:"Prompt Cache Breakdown";
                     kind =
                       Chart.Spec.Stacked_bar
                         {
                           segments =
                             [
                               ( Say.make ~ko:"캐시 읽기" ~en:"Cache Read",
                                 cache_r,
                                 Theme.Status_ok );
                               ( Say.make ~ko:"캐시 쓰기" ~en:"Cache Write",
                                 cache_w,
                                 Theme.Status_active );
                               ( Say.make ~ko:"비캐시 입력" ~en:"Uncached",
                                 uncached,
                                 Theme.Status_attention );
                               ( Say.make ~ko:"출력" ~en:"Output",
                                 out_tok,
                                 Theme.Status_historical );
                             ];
                           total_label =
                             Say.make
                               ~ko:(Printf.sprintf "적중률 %s"
                                      (Format_val.format_observed
                                         Format_val.Percent r.cache_hit_pct ~lang))
                               ~en:(Printf.sprintf "Hit %s"
                                      (Format_val.format_observed
                                         Format_val.Percent r.cache_hit_pct ~lang));
                           unit = Format_val.Tokens;
                         };
                     hotkey_hint = None;
                   }
                 in
                 ignore (Chart.draw grid ~rect:bar_r ~theme ~caps ~lang spec);
                 y := !y + 4
             | Some _ | None ->
                 if !y < bottom then begin
                   let msg =
                     Say.resolve lang
                       (Say.make ~ko:"토큰·캐시 효율 스냅샷 대기 중"
                          ~en:"Awaiting token & cache breakdown snapshot")
                   in
                   ignore
                     (Cell_grid.put_text ~clip:body_r grid ~x:body_r.x ~y:!y
                        ~style:whisper_st msg);
                   incr y
                 end);
            (match keeper_opt with
             | Some k when !y < bottom ->
                 let info =
                   Printf.sprintf "Runtime: %s · Turns: %s · Cost 24h: %s"
                     k.runtime_id
                     (Format_val.format_observed Format_val.Count
                        (Observed.map float_of_int k.total_turns)
                        ~lang)
                     (Format_val.format_observed Format_val.Usd k.cost_24h_usd
                        ~lang)
                 in
                 ignore
                   (Cell_grid.put_text ~clip:body_r grid ~x:body_r.x ~y:!y
                      ~style:struct_st
                      (Grapheme.truncate_to_width ~max_width:body_r.w info))
             | Some _ | None -> ())
        | Nav.Drawer_schedules ->
            let scheds = Work_store.schedules_list model.work in
            let sorted =
              List.sort
                (fun (a : Wire_work.schedule_row) (b : Wire_work.schedule_row) ->
                  let ma =
                    Option.equal String.equal a.payload_keeper_name (Some keeper)
                  in
                  let mb =
                    Option.equal String.equal b.payload_keeper_name (Some keeper)
                  in
                  if ma && not mb then -1
                  else if mb && not ma then 1
                  else Float.compare a.due_at_unix b.due_at_unix)
                scheds
            in
            if sorted = [] then
              ignore
                (Cell_grid.put_text ~clip:body_r grid ~x:body_r.x ~y:body_r.y
                   ~style:whisper_st
                   (Say.resolve lang
                      (Say.make ~ko:"등록된 예약 일정이 없습니다."
                         ~en:"No schedules registered.")))
            else
              let arr = Array.of_list sorted in
              let max_show = Int.min body_r.h (Array.length arr) in
              for i = 0 to max_show - 1 do
                let s = arr.(i) in
                let py = body_r.y + i in
                let row_r = Rect.make ~x:body_r.x ~y:py ~w:body_r.w ~h:1 in
                let g, st_style =
                  match s.status with
                  | Wire_work.Sched_running -> (Glyph.Live_working, acc_st)
                  | Wire_work.Sched_due -> (Glyph.Action_required, attn_st)
                  | Wire_work.Sched_scheduled -> (Glyph.Live_healthy, ok_st)
                  | Wire_work.Sched_succeeded -> (Glyph.Check_mark, ok_st)
                  | Wire_work.Sched_failed -> (Glyph.Live_failing, crit_st)
                  | Wire_work.Sched_cancelled | Wire_work.Sched_expired ->
                      (Glyph.Live_idle, whisper_st)
                in
                let disp =
                  match s.last_disposition with
                  | Wire_work.Wake_succeeded ->
                      Glyph.to_utf8 Glyph.Check_mark ^ " ok"
                  | Wire_work.Wake_skipped r ->
                      Glyph.to_utf8 Glyph.Live_idle ^ " skip: " ^ r
                  | Wire_work.Wake_failed r ->
                      Glyph.to_utf8 Glyph.Live_failing ^ " fail: " ^ r
                  | Wire_work.Wake_running ->
                      Glyph.to_utf8 Glyph.Live_working ^ " running"
                  | Wire_work.Wake_never -> Glyph.to_utf8 Glyph.Missing_absent
                in
                let target =
                  match s.payload_keeper_name with
                  | Some kn -> "@" ^ kn
                  | None -> (
                      match s.payload_target with Some t -> t | None -> s.source)
                in
                let line =
                  Printf.sprintf "%s %-14s %-12s %s · %s"
                    (Glyph.to_utf8 g)
                    (Grapheme.truncate_to_width ~max_width:14 target)
                    (Grapheme.truncate_to_width ~max_width:12
                       s.recurrence_summary)
                    disp
                    (match s.payload_summary with
                     | Some ps -> ps
                     | None -> s.schedule_id)
                in
                ignore
                  (Cell_grid.put_text ~clip:row_r grid ~x:body_r.x ~y:py
                     ~style:st_style
                     (Grapheme.truncate_to_width ~max_width:body_r.w line))
              done
    end

(* ---------- Overlay 5: Inline Action & /btw Side-Query Modal ---------- *)

type inline_form_kind =
  | Form_standard of Nav.inline_action_kind
  | Form_board_goal_proposal
  | Form_goal_confirmation_proof
  | Form_memory_act
  | Form_wiki_edit
  | Form_fusion_launch
  | Form_runtime_assign
  | Form_setup_account_key
  | Form_setup_login_start

let classify_inline_form (modal : Model.inline_modal_state) : inline_form_kind =
  match modal.kind with
  | Nav.Board_new_post -> (
      match modal.fields with
      | { key = "proposal_title"; _ } :: _ -> Form_board_goal_proposal
      | { key = "confirm_goal_id"; _ } :: _ -> Form_goal_confirmation_proof
      | { key = "memory_keeper"; _ } :: _ -> Form_memory_act
      | { key = "wiki_slug"; _ } :: _ -> Form_wiki_edit
      | { key = "fusion_keeper"; _ } :: _ -> Form_fusion_launch
      | { key = "assign_keeper"; _ } :: _ -> Form_runtime_assign
      | { key = "setup_key_integration"; _ } :: _ -> Form_setup_account_key
      | { key = "setup_login_integration"; _ } :: _ -> Form_setup_login_start
      | _ -> Form_standard Nav.Board_new_post)
  | ( Nav.Btw_query
    | Nav.Gate_reject _
    | Nav.Verification_reject _
    | Nav.Harness_overrule _
    | Nav.Task_cancel _
    | Nav.Schedule_form
    | Nav.Connector_form
    | Nav.Repo_add_form ) as std ->
      Form_standard std

let inline_action_title ~lang ~(modal : Model.inline_modal_state) _kind =
  match classify_inline_form modal with
  | Form_board_goal_proposal ->
      Say.resolve lang
        (Say.make ~ko:"#goals 보드 제안 작성" ~en:"Board #goals Proposal")
  | Form_goal_confirmation_proof ->
      Say.resolve lang
        (Say.make ~ko:"목표 완료 확정 증명 입력"
           ~en:"Goal Confirmation Proof")
  | Form_memory_act ->
      Say.resolve lang
        (Say.make ~ko:"사서 기억 복구 (/memory/act)" ~en:"Memory Recovery Act")
  | Form_wiki_edit ->
      Say.resolve lang (Say.make ~ko:"위키 문서 편집" ~en:"Edit Wiki Page")
  | Form_fusion_launch ->
      Say.resolve lang (Say.make ~ko:"퓨전 패널 실행" ~en:"Launch Fusion Panel")
  | Form_runtime_assign ->
      Say.resolve lang
        (Say.make ~ko:"키퍼 런타임 배정 / 기본 경로"
           ~en:"Assign Keeper Runtime / Default Route")
  | Form_setup_account_key ->
      Say.resolve lang
        (Say.make ~ko:"프로바이더 API 키 등록" ~en:"Register Provider API Key")
  | Form_setup_login_start ->
      Say.resolve lang
        (Say.make ~ko:"공식 CLI 계정 로그인" ~en:"Start Official CLI Login")
  | Form_standard Nav.Btw_query ->
      Say.resolve lang (Say.make ~ko:"임시 질문 (/btw)" ~en:"Side-Query (/btw)")
  | Form_standard (Nav.Gate_reject id) ->
      Say.resolve lang
        (Say.make ~ko:("게이트 거절 · " ^ id) ~en:("Gate Reject · " ^ id))
  | Form_standard (Nav.Verification_reject id) ->
      Say.resolve lang
        (Say.make ~ko:("검증 거절 · " ^ id) ~en:("Verification Reject · " ^ id))
  | Form_standard (Nav.Harness_overrule id) ->
      Say.resolve lang
        (Say.make ~ko:("판정 재정의 · " ^ id) ~en:("Harness Overrule · " ^ id))
  | Form_standard (Nav.Task_cancel id) ->
      Say.resolve lang
        (Say.make ~ko:("작업 취소 · " ^ id) ~en:("Cancel Task · " ^ id))
  | Form_standard Nav.Schedule_form ->
      Say.resolve lang (Say.make ~ko:"새 일정 생성" ~en:"Create Schedule")
  | Form_standard Nav.Connector_form ->
      Say.resolve lang (Say.make ~ko:"새 커넥터 연결" ~en:"Add Connector")
  | Form_standard Nav.Repo_add_form ->
      Say.resolve lang (Say.make ~ko:"저장소 추가" ~en:"Add Repository")
  | Form_standard Nav.Board_new_post ->
      Say.resolve lang (Say.make ~ko:"보드 새 글 작성" ~en:"New Board Post")

let form_of_inline_modal (modal : Model.inline_modal_state) =
  let fields =
    List.map
      (fun (f : Model.modal_form_field) ->
        let validators = if f.required then [ Form.Required ] else [] in
        Form.make_field ~key:f.key ~label:f.label ~validators
          ~provenance:Form.Prov_tui_pref ~reload_scope:Form.Hot_reload
          (Form.Text_val f.value))
      modal.fields
  in
  let st = Form.create fields in
  let n = Array.length st.fields in
  let focused =
    if n <= 0 then 0 else Int.max 0 (Int.min (n - 1) modal.active_field)
  in
  { st with focused; editing = not modal.submitting }

let render_inline_action_modal grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~kind =
  let lang = model.lang in
  let modal =
    match model.inline_modal with
    | Some m -> m
    | None -> Model.inline_modal_for kind
  in
  let w = Int.min (Int.max 0 (rect.w - 4)) 84 in
  let desired_h =
    match kind with
    | Nav.Btw_query -> (
        match model.drafts.btw with
        | Drafts.Btw_idle | Drafts.Btw_sending _ -> 7
        | Drafts.Btw_streaming _ | Drafts.Btw_answered _ | Drafts.Btw_failed _ ->
            13)
    | Nav.Gate_reject _
    | Nav.Verification_reject _
    | Nav.Harness_overrule _
    | Nav.Task_cancel _
    | Nav.Schedule_form
    | Nav.Connector_form
    | Nav.Repo_add_form
    | Nav.Board_new_post ->
        Int.max 7 (List.length modal.fields + 5)
  in
  let h = Int.min (Int.max 0 (rect.h - 2)) desired_h in
  let x = rect.x + ((rect.w - w) / 2) in
  let y = Int.max rect.y (Rect.bottom rect - h - 1) in
  let modal_r = Rect.make ~x ~y ~w ~h in
  if Rect.is_empty modal_r then ()
  else
    let title = inline_action_title ~lang ~modal kind in
    let hotkey =
      Say.resolve lang
        (Say.make ~ko:"[Tab] 필드 · [Enter] 제출 · [Esc] 취소"
           ~en:"[Tab] Field · [Enter] Submit · [Esc] Cancel")
    in
    let inner =
      Card.draw ~cache grid ~rect:modal_r ~theme
        {
          (Card.default_spec ~title) with
          hotkey = Some hotkey;
          focused = true;
          elevated = true;
        }
    in
    if not (Rect.is_empty inner) then begin
      let pad_x = if inner.w >= 48 then 2 else 1 in
      let bg = Color.of_rgb theme.surface_2 in
      let acc_st = Typography.accent ~bg ~bold:true theme in
      let ok_st = Typography.status ~bg ~bold:true theme Theme.Status_ok in
      let attn_st =
        Typography.status ~bg ~bold:true theme Theme.Status_attention
      in
      let crit_st =
        Typography.status ~bg ~bold:true theme Theme.Status_critical
      in
      let padded = Card.pad_inner ~pad_x inner in
      match kind with
      | Nav.Btw_query -> (
          match model.drafts.btw with
          | Drafts.Btw_idle ->
              let form_st = form_of_inline_modal modal in
              ignore
                (Form.draw grid ~rect:inner ~theme ~lang ~pad_x
                   ~show_row_badges:false form_st)
          | Drafts.Btw_sending { keeper; prompt; _ } ->
              ignore
                (Cell_grid.put_text ~clip:padded grid ~x:padded.x ~y:padded.y
                   ~style:acc_st
                   (Grapheme.truncate_to_width ~max_width:padded.w
                      ("Q: " ^ prompt)));
              if padded.h >= 2 then
                ignore
                  (Cell_grid.put_text ~clip:padded grid ~x:padded.x
                     ~y:(padded.y + 1) ~style:attn_st
                     (Say.resolve lang
                        (Say.make
                           ~ko:(Printf.sprintf "%s @%s 응답 요청 중..."
                                  (Glyph.to_utf8 Glyph.Transport_reconnecting)
                                  keeper)
                           ~en:(Printf.sprintf "%s Asking @%s..."
                                  (Glyph.to_utf8 Glyph.Transport_reconnecting)
                                  keeper))))
          | Drafts.Btw_streaming { keeper; prompt; buffer; _ } ->
              ignore
                (Cell_grid.put_text ~clip:padded grid ~x:padded.x ~y:padded.y
                   ~style:acc_st
                   (Grapheme.truncate_to_width ~max_width:padded.w
                      (Printf.sprintf "%s @%s · %s"
                         (Glyph.to_utf8 Glyph.Live_working) keeper prompt)));
              if padded.h >= 3 then begin
                Card.draw_hairline ~pad_x ~bg grid ~rect:inner ~y:(inner.y + 1)
                  ~theme;
                let md_r =
                  Rect.make ~x:padded.x ~y:(padded.y + 2) ~w:padded.w
                    ~h:(Int.max 0 (padded.h - 2))
                in
                ignore
                  (Markdown.draw grid ~rect:md_r ~theme
                     ~osc8:caps.osc8_hyperlinks buffer)
              end
          | Drafts.Btw_answered { keeper; prompt; reply } ->
              ignore
                (Cell_grid.put_text ~clip:padded grid ~x:padded.x ~y:padded.y
                   ~style:ok_st
                   (Grapheme.truncate_to_width ~max_width:padded.w
                      (Printf.sprintf "%s @%s · %s"
                         (Glyph.to_utf8 Glyph.Live_healthy) keeper prompt)));
              if padded.h >= 3 then begin
                Card.draw_hairline ~pad_x ~bg grid ~rect:inner ~y:(inner.y + 1)
                  ~theme;
                let md_r =
                  Rect.make ~x:padded.x ~y:(padded.y + 2) ~w:padded.w
                    ~h:(Int.max 0 (padded.h - 2))
                in
                ignore
                  (Markdown.draw grid ~rect:md_r ~theme
                     ~osc8:caps.osc8_hyperlinks reply)
              end
          | Drafts.Btw_failed { keeper; prompt; reason } ->
              ignore
                (Cell_grid.put_text ~clip:padded grid ~x:padded.x ~y:padded.y
                   ~style:acc_st
                   (Grapheme.truncate_to_width ~max_width:padded.w
                      ("Q: " ^ prompt)));
              if padded.h >= 2 then
                ignore
                  (Cell_grid.put_text ~clip:padded grid ~x:padded.x
                     ~y:(padded.y + 1) ~style:crit_st
                     (Grapheme.truncate_to_width ~max_width:padded.w
                        (Printf.sprintf "%s @%s: %s"
                           (Glyph.to_utf8 Glyph.Live_failing) keeper reason))))
      | Nav.Gate_reject _
      | Nav.Verification_reject _
      | Nav.Harness_overrule _
      | Nav.Task_cancel _
      | Nav.Schedule_form
      | Nav.Connector_form
      | Nav.Repo_add_form
      | Nav.Board_new_post ->
          let status_rows =
            if modal.submitting || Option.is_some modal.error then 1 else 0
          in
          let form_r =
            Rect.make ~x:inner.x ~y:inner.y ~w:inner.w
              ~h:(Int.max 0 (inner.h - status_rows))
          in
          let form_st = form_of_inline_modal modal in
          ignore
            (Form.draw grid ~rect:form_r ~theme ~lang ~pad_x
               ~show_row_badges:false form_st);
          if status_rows = 1 then begin
            let sy = Rect.bottom inner - 1 in
            let sr = Rect.make ~x:padded.x ~y:sy ~w:padded.w ~h:1 in
            match modal.error with
            | Some err ->
                ignore
                  (Cell_grid.put_text ~clip:sr grid ~x:padded.x ~y:sy
                     ~style:crit_st
                     (Grapheme.truncate_to_width ~max_width:padded.w
                        (Glyph.to_utf8 Glyph.Live_failing ^ " " ^ err)))
            | None ->
                if modal.submitting then
                  ignore
                    (Cell_grid.put_text ~clip:sr grid ~x:padded.x ~y:sy
                       ~style:attn_st
                       (Say.resolve lang
                          (Say.make
                             ~ko:(Glyph.to_utf8 Glyph.Live_working ^ " 서버에 전송 중...")
                             ~en:(Glyph.to_utf8 Glyph.Live_working ^ " Submitting..."))))
          end
    end

(* ---------- Overlay 6: ? Dynamic SSOT Help (2-Column with v-hairline & keycaps) ---------- *)

let render_help_column grid ~(rect : Rect.t) ~(theme : Theme.t)
    (groups : Keymap.help_group list) =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_2 in
    let keycap_bg = Color.of_rgb theme.surface_1 in
    let key_st = Typography.anchor ~bg:keycap_bg theme in
    let desc_st = Typography.primary ~bg theme in
    let whisper_st = Typography.whisper ~bg theme in
    let y = ref rect.y in
    let bottom = Rect.bottom rect in
    List.iter
      (fun (grp : Keymap.help_group) ->
        if !y < bottom then begin
          Card.draw_hairline ~pad_x:0 ~label:grp.title ~bg grid ~rect ~y:!y
            ~theme;
          incr y;
          List.iter
            (fun (e : Keymap.help_entry) ->
              if !y < bottom then begin
                let rr = Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:1 in
                let keys_s =
                  let shown_keys =
                    match e.keys with
                    | a :: b :: _ -> [ a; b ]
                    | xs -> xs
                  in
                  " " ^ String.concat "/" shown_keys ^ " "
                in
                let key_col_w = Int.min 18 (Int.max 9 (rect.w / 3)) in
                ignore
                  (Cell_grid.put_text ~clip:rr grid ~x:(rect.x + 1) ~y:!y
                     ~style:key_st
                     (Grapheme.truncate_to_width ~max_width:key_col_w keys_s));
                let dx = rect.x + 2 + key_col_w in
                let slash_s =
                  match e.slash_twin with Some s -> " " ^ s | None -> ""
                in
                let slash_w = Grapheme.display_width slash_s in
                let sx = Rect.right rect - slash_w in
                let dw =
                  Int.max 0
                    ((if slash_w > 0 && sx > dx + 8 then sx - 1
                      else Rect.right rect)
                     - dx)
                in
                if dw > 0 then
                  ignore
                    (Cell_grid.put_text ~clip:rr grid ~x:dx ~y:!y ~style:desc_st
                       (Grapheme.truncate_to_width ~max_width:dw e.desc));
                if slash_w > 0 && sx > dx + 8 then
                  ignore
                    (Cell_grid.put_text ~clip:rr grid ~x:sx ~y:!y
                       ~style:whisper_st slash_s);
                incr y
              end)
            grp.entries;
          if !y < bottom then incr y
        end)
      groups

let compact_help_group ~lang (grp : Keymap.help_group) : Keymap.help_group =
  let seen_ws = ref false in
  let seen_move = ref false in
  let seen_ask = ref false in
  let entries =
    List.filter_map
      (fun (e : Keymap.help_entry) ->
        match e.action with
        | Keymap.Switch_workspace _ ->
            if !seen_ws then None
            else begin
              seen_ws := true;
              Some
                {
                  e with
                  keys = [ "1..6"; "Alt+1..6" ];
                  desc =
                    Say.resolve lang
                      (Say.make ~ko:"워크스페이스 전환 (1..6)"
                         ~en:"Switch workspace (1..6)");
                  slash_twin = Some "/pulse../infra";
                }
            end
        | Keymap.Move _ ->
            if !seen_move then None
            else begin
              seen_move := true;
              Some
                {
                  e with
                  keys = [ "j/k"; "↑↓←→" ];
                  desc =
                    Say.resolve lang
                      (Say.make ~ko:"선택 이동 · 스크롤 (g/G)"
                         ~en:"Move / scroll (g/G top·bottom)");
                  slash_twin = None;
                }
            end
        | Keymap.Ask_select_choice _ ->
            if !seen_ask then None
            else begin
              seen_ask := true;
              Some
                {
                  e with
                  keys = [ "1..4" ];
                  desc =
                    Say.resolve lang
                      (Say.make ~ko:"Ask 다중 선택지 응답"
                         ~en:"Answer Ask choice (1..4)");
                  slash_twin = None;
                }
            end
        | Keymap.Submit_followup ->
            Some
              {
                e with
                keys = [ "S-Enter"; "Alt+↵" ];
                desc =
                  Say.resolve lang
                    (Say.make ~ko:"턴 종료 후 후속 메시지 예약"
                       ~en:"Queue end-of-turn follow-up");
              }
        | Keymap.Pop_back_or_close ->
            Some
              {
                e with
                desc =
                  Say.resolve lang
                    (Say.make ~ko:"닫기 / 상세 복귀 / 포커스 해제"
                       ~en:"Close overlay / pop dive / blur");
              }
        | Keymap.Open_palette ->
            Some
              {
                e with
                desc =
                  Say.resolve lang
                    (Say.make ~ko:"통합 명령·엔티티 팔레트"
                       ~en:"Command & Entity Palette");
              }
        | Keymap.Fast_deny_top ->
            Some
              {
                e with
                desc =
                  Say.resolve lang
                    (Say.make ~ko:"대기 승인 거절 (사유 입력)"
                       ~en:"Deny top approval (reason)");
              }
        | Keymap.Open_external ->
            Some
              {
                e with
                desc =
                  Say.resolve lang
                    (Say.make ~ko:"PR/문서/경로 외부 앱 열기"
                       ~en:"Open linked PR/doc externally");
              }
        | Keymap.Copy_selected ->
            Some
              {
                e with
                desc =
                  Say.resolve lang
                    (Say.make ~ko:"선택 항목 클립보드 복사"
                       ~en:"Copy selection (OSC 52)");
              }
        | Keymap.Teleport_blocked ->
            Some
              {
                e with
                desc =
                  Say.resolve lang
                    (Say.make ~ko:"대기·차단 키퍼로 즉시 이동"
                       ~en:"Jump to top blocked item");
              }
        | Keymap.Open_incidents ->
            Some
              {
                e with
                desc =
                  Say.resolve lang
                    (Say.make ~ko:"과거 장애·진단 이력 서랍"
                       ~en:"Historical Incidents drawer");
              }
        | Keymap.Open_keeper_switcher ->
            Some
              {
                e with
                desc =
                  Say.resolve lang
                    (Say.make ~ko:"키퍼·채팅 빠른 전환"
                       ~en:"Keeper/Chat switcher");
              }
        | Keymap.Open_queue_context ->
            Some
              {
                e with
                desc =
                  Say.resolve lang
                    (Say.make ~ko:"키퍼 큐·컨텍스트 서랍"
                       ~en:"Queue & Context drawer");
              }
        | Keymap.Cycle_origin_mode ->
            Some
              {
                e with
                desc =
                  Say.resolve lang
                    (Say.make ~ko:"채팅 발신 표시 모드 순환"
                       ~en:"Cycle chat origin mode");
              }
        | Keymap.Toggle_thinking ->
            Some
              {
                e with
                desc =
                  Say.resolve lang
                    (Say.make ~ko:"추론 블록 표시 순환"
                       ~en:"Cycle thinking display");
              }
        | Keymap.Sub_tab _
        | Keymap.Cycle_focus_pane _
        | Keymap.Focus_composer
        | Keymap.Focus_filter
        | Keymap.Dive_selected
        | Keymap.Confirm_selected
        | Keymap.Open_settings
        | Keymap.Voice_ptt_toggle
        | Keymap.Fast_approve_top
        | Keymap.Open_help
        | Keymap.Open_model_switcher
        | Keymap.Toggle_tool_details
        | Keymap.Composer_kill_word
        | Keymap.Composer_newline
        | Keymap.Submit_steer
        | Keymap.Toggle_expand
        | Keymap.Create_new
        | Keymap.Refresh
        | Keymap.Toggle_zoom
        | Keymap.Quit_app ->
            Some e)
      grp.entries
  in
  { grp with entries }

let render_help_overlay grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) =
  let w = Int.min (Int.max 0 (rect.w - 4)) 128 in
  let h = Int.min (Int.max 0 (rect.h - 2)) 28 in
  let modal_r = center_rect ~outer:rect ~w ~h in
  if Rect.is_empty modal_r then ()
  else
    let lang = model.lang in
    let title =
      Say.resolve lang
        (Say.make ~ko:"? · 동적 단축키 도움말 (SSOT)"
           ~en:"? · Dynamic SSOT Keymap Help")
    in
    let inner =
      Card.draw ~cache grid ~rect:modal_r ~theme
        {
          (Card.default_spec ~title) with
          hotkey =
            Some
              (Say.resolve lang
                 (Say.make ~ko:"[Esc / ?] 닫기" ~en:"[Esc / ?] Close"));
          focused = true;
          elevated = true;
        }
    in
    let pad_x = if inner.w >= 72 then 2 else 1 in
    let content = Card.pad_inner ~pad_x inner in
    if not (Rect.is_empty content) then begin
      let groups =
        Keymap.help_entries ~scope_chain:Keymap.all_scopes ~lang
        |> List.map (compact_help_group ~lang)
      in
      let is_left_cat = function
        | Keymap.Cat_navigation | Keymap.Cat_actions -> true
        | Keymap.Cat_overlays | Keymap.Cat_composer | Keymap.Cat_approval ->
            false
      in
      let left_groups =
        List.filter (fun (g : Keymap.help_group) -> is_left_cat g.category)
          groups
      in
      let right_groups =
        List.filter
          (fun (g : Keymap.help_group) -> not (is_left_cat g.category))
          groups
      in
      if content.w >= 72 then
        match Layout.split_h ~gap:3 content [ Layout.Flex 1; Layout.Flex 1 ] with
        | [ l_r; r_r ] ->
            render_help_column grid ~rect:l_r ~theme left_groups;
            Card.draw_v_hairline ~bg:(Color.of_rgb theme.surface_2) grid
              ~x:(Rect.right l_r + 1) ~y:content.y ~h:content.h ~theme;
            render_help_column grid ~rect:r_r ~theme right_groups
        | _ -> ()
      else
        let prioritized = right_groups @ left_groups in
        render_help_column grid ~rect:content ~theme prioritized
    end

(* ---------- Overlay 7: System / Auth / Media Gate Overlay ---------- *)

let render_system_gate grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~gate =
  let lang = model.lang in
  let w = Int.min (Int.max 0 (rect.w - 4)) 78 in
  let h = Int.min (Int.max 0 (rect.h - 2)) 15 in
  let modal_r = center_rect ~outer:rect ~w ~h in
  if Rect.is_empty modal_r then ()
  else
    let bg = Color.of_rgb theme.surface_2 in
    let anchor_st = Typography.anchor ~bg theme in
    let pri_st = Typography.primary ~bg theme in
    let struct_st = Typography.structure ~bg theme in
    let whisper_st = Typography.whisper ~bg theme in
    let acc_st = Typography.accent ~bg ~bold:true theme in
    let ok_st = Typography.status ~bg ~bold:true theme Theme.Status_ok in
    let attn_st =
      Typography.status ~bg ~bold:true theme Theme.Status_attention
    in
    let crit_st =
      Typography.status ~bg ~bold:true theme Theme.Status_critical
    in
    let draw_lines (inner : Rect.t) ~rail_tone lines =
      let pad_x = if inner.w >= 48 then 2 else 1 in
      let pad_y = if inner.h >= 7 then 1 else 0 in
      let content = Card.pad_inner ~pad_x ~pad_y inner in
      if not (Rect.is_empty content) then begin
        (match rail_tone with
         | Some tone ->
             Card.draw_left_rail ~bg ~tone grid ~x:content.x ~y:content.y
               ~h:(Int.min 2 content.h) ~theme
         | None -> ());
        let tx =
          match rail_tone with Some _ -> content.x + 2 | None -> content.x
        in
        let tw = Int.max 0 (Rect.right content - tx) in
        let y = ref content.y in
        List.iter
          (fun (st, txt) ->
            if !y < Rect.bottom content then begin
              let rr = Rect.make ~x:tx ~y:!y ~w:tw ~h:1 in
              ignore
                (Cell_grid.put_text ~clip:rr grid ~x:tx ~y:!y ~style:st
                   (Grapheme.truncate_to_width ~max_width:tw txt));
              incr y
            end)
          lines
      end
    in
    match gate with
    | Nav.Server_offline ->
        let is_mismatch =
          match (model.server_identity.mismatch_state, model.freshness.observer) with
          | (Model.Mismatch_recovering | Model.Mismatch_halted), _
          | _, Health.Workspace_mismatch _ ->
              true
          | Model.Mismatch_none,
            ( Health.Connecting
            | Health.Live _
            | Health.Reconnecting _
            | Health.Stale _
            | Health.Disconnected _ ) ->
              false
        in
        if is_mismatch then begin
          let title =
            Say.resolve lang
              (Say.make ~ko:"워크스페이스 불일치 복구 (409)"
                 ~en:"Workspace Mismatch Recovery (409)")
          in
          let inner =
            Card.draw ~cache grid ~rect:modal_r ~theme
              {
                (Card.default_spec ~title) with
                badge =
                  Some
                    {
                      glyph = Some Glyph.Warning_triangle;
                      text = "409";
                      tone = Some Theme.Status_critical;
                    };
                focused = true;
                elevated = true;
              }
          in
          let exp_obs =
            match model.freshness.observer with
            | Health.Workspace_mismatch { expected_instance; observed_instance } ->
                Printf.sprintf "Expected: %s · Observed: %s" expected_instance
                  observed_instance
            | Health.Connecting
            | Health.Live _
            | Health.Reconnecting _
            | Health.Stale _
            | Health.Disconnected _ ->
                Say.resolve lang
                  (Say.make ~ko:"서버 인스턴스가 재시작되었거나 다른 워크스페이스입니다."
                     ~en:"Server restarted or points to a different workspace instance.")
          in
          let state_line =
            match model.server_identity.mismatch_state with
            | Model.Mismatch_recovering ->
                ( attn_st,
                  Say.resolve lang
                    (Say.make ~ko:"◌ 자동 핸드셰이크 재동기화 중..."
                       ~en:"◌ Automatic handshake resync in progress...") )
            | Model.Mismatch_halted | Model.Mismatch_none ->
                ( crit_st,
                  Say.resolve lang
                    (Say.make ~ko:"✕ 자동 복구 한도 도달 — 수동 재연결 필요"
                       ~en:"✕ Auto-recovery halted — manual re-handshake required") )
          in
          draw_lines inner ~rail_tone:(Some Theme.Status_critical)
            [
              (anchor_st, exp_obs);
              state_line;
              (whisper_st, "");
              ( ok_st,
                Say.resolve lang
                  (Say.make ~ko:"[r] 워크스페이스 핸드셰이크 재시도  ·  [Ctrl+Q] 종료"
                     ~en:"[r] Retry workspace handshake  ·  [Ctrl+Q] Quit") );
            ]
        end
        else begin
          let title =
            Say.resolve lang (Say.make ~ko:"서버 오프라인" ~en:"Server Offline")
          in
          let inner =
            Card.draw ~cache grid ~rect:modal_r ~theme
              {
                (Card.default_spec ~title) with
                badge =
                  Some
                    {
                      glyph = Some Glyph.Live_idle;
                      text =
                        Say.resolve lang (Say.make ~ko:"연결 끊김" ~en:"OFFLINE");
                      tone = Some Theme.Status_critical;
                    };
                focused = true;
                elevated = true;
              }
          in
          let reason_line =
            match model.freshness.observer with
            | Health.Disconnected { reason; _ }
            | Health.Reconnecting { reason; _ } ->
                Render_util.string_of_transport_error ~lang reason
            | Health.Connecting
            | Health.Live _
            | Health.Stale _
            | Health.Workspace_mismatch _ ->
                Say.resolve lang
                  (Say.make ~ko:"MASC 서버에 연결할 수 없습니다."
                     ~en:"Unable to reach the MASC server.")
          in
          let autostart_line =
            if model.server_identity.autostart_attempted then
              Say.resolve lang
                (Say.make ~ko:"로컬 서버 자동 시작을 시도했습니다."
                   ~en:"Local server autostart was attempted.")
            else
              Say.resolve lang
                (Say.make ~ko:"로컬 MASC 서버를 시작하거나 재연결하세요."
                   ~en:"Start the local MASC server or retry connection.")
          in
          draw_lines inner ~rail_tone:(Some Theme.Status_critical)
            [
              (crit_st, Glyph.to_utf8 Glyph.Live_failing ^ " " ^ reason_line);
              (whisper_st, autostart_line);
              (whisper_st, "");
              ( ok_st,
                Say.resolve lang
                  (Say.make ~ko:"[s] 로컬 서버 시작  ·  [r] 재시도  ·  [Ctrl+Q] 종료"
                     ~en:"[s] Start local server  ·  [r] Retry  ·  [Ctrl+Q] Quit") );
            ]
        end
    | Nav.Auth_gate ->
        let title =
          Say.resolve lang (Say.make ~ko:"인증 필요" ~en:"Authentication Required")
        in
        let inner =
          Card.draw ~cache grid ~rect:modal_r ~theme
            {
              (Card.default_spec ~title) with
              badge =
                Some
                  {
                    glyph = Some Glyph.Action_required;
                    text = "AUTH";
                    tone = Some Theme.Status_attention;
                  };
              focused = true;
              elevated = true;
            }
        in
        let scope_info =
          match model.server_identity.health with
          | Some { scope = Wire_common.Public_health; version; _ } ->
              Printf.sprintf "Server %s (public health scope)" version
          | Some { scope = Wire_common.Full_health ws; version; _ } ->
              Printf.sprintf "Server %s · %s" version ws.base_path
          | None ->
              Say.resolve lang
                (Say.make ~ko:"서버 인증 자격 증명이 필요합니다."
                   ~en:"Server requires valid operator credentials.")
        in
        draw_lines inner ~rail_tone:(Some Theme.Status_attention)
          [
            (anchor_st, scope_info);
            ( whisper_st,
              Say.resolve lang
                (Say.make ~ko:"브라우저 OAuth 또는 PAT 설정 후 재시도하세요."
                   ~en:"Complete OAuth login or configure PAT, then retry.") );
            (whisper_st, "");
            ( acc_st,
              Say.resolve lang
                (Say.make ~ko:"[r] 인증 재확인  ·  [Ctrl+Q] 종료"
                   ~en:"[r] Retry authentication  ·  [Ctrl+Q] Quit") );
          ]
    | Nav.Media_viewer ->
        let title =
          Say.resolve lang
            (Say.make ~ko:"미디어 · 아티팩트 뷰어" ~en:"Media & Artifact Viewer")
        in
        let inner =
          Card.draw ~cache grid ~rect:modal_r ~theme
            {
              (Card.default_spec ~title) with
              hotkey =
                Some
                  (Say.resolve lang
                     (Say.make ~ko:"[y] 해시 복사 · [Esc] 닫기"
                        ~en:"[y] Copy SHA256 · [Esc] Close"));
              focused = true;
              elevated = true;
            }
        in
        let media_lines =
          match Knowledge_store.selected_artifact model.knowledge with
          | Some art ->
              [
                (anchor_st, art.name);
                ( struct_st,
                  Printf.sprintf "MIME: %s · Size: %s" art.mime_type
                    (Format_val.format_value Format_val.Bytes
                       (float_of_int art.bytes)) );
                ( whisper_st,
                  Printf.sprintf "SHA256: %s"
                    (Grapheme.truncate_to_width ~max_width:32 art.sha256) );
                ( pri_st,
                  Say.resolve lang
                    (Say.make ~ko:"프레임버퍼 안전 영역 내 미리보기 · [y] 해시 복사 · [Esc] 닫기"
                       ~en:"Fenced inside framebuffer lifecycle · [y] copy SHA256 · [Esc] close") );
              ]
          | None ->
              [
                ( whisper_st,
                  Say.resolve lang
                    (Say.make ~ko:"선택된 미디어 또는 아티팩트가 없습니다."
                       ~en:"No media or artifact selected.") );
                ( pri_st,
                  Say.resolve lang (Say.make ~ko:"[Esc] 돌아가기" ~en:"[Esc] Return") );
              ]
        in
        draw_lines inner ~rail_tone:(Some Theme.Status_active) media_lines
    | Nav.Micro_viewport ->
        let title =
          Say.resolve lang
            (Say.make ~ko:"마이크로 뷰포트 가드" ~en:"Micro Viewport Guard")
        in
        let inner =
          Card.draw ~cache grid ~rect:modal_r ~theme
            {
              (Card.default_spec ~title) with
              focused = true;
              elevated = true;
            }
        in
        let draft_n =
          (if Drafts.has_non_empty_draft model.drafts then 1 else 0)
          + Drafts.other_keepers_draft_count model.drafts
        in
        let gcols = Cell_grid.cols grid in
        let grows = Cell_grid.rows grid in
        draw_lines inner ~rail_tone:(Some Theme.Status_attention)
          [
            ( attn_st,
              Printf.sprintf "%s Viewport %dx%d (< 80x24)"
                (Glyph.to_utf8 Glyph.Warning_triangle) gcols grows );
            ( pri_st,
              Printf.sprintf "%s Action Queue: %d"
                (Glyph.to_utf8 Glyph.Action_required)
                (Attention.count model.attention) );
            ( whisper_st,
              Printf.sprintf "Protected drafts: %d · Resize >= 80x24" draft_n );
          ]

(* ---------- Public Overlay Dispatcher (Exhaustive on Nav.overlay) ---------- *)

let render ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  match model.nav.overlay with
  | None -> ()
  | Some overlay ->
      if Rect.is_empty rect then ()
      else
        let theme = Theme.of_preset model.theme_preset in
        Render_util.dim_backdrop grid ~rect ~theme;
        match overlay with
        | Nav.Palette -> render_palette grid ~cache ~rect ~theme ~model
        | Nav.Settings active_tab ->
            render_settings grid ~cache ~rect ~theme ~model ~active_tab
        | Nav.Incidents ->
            render_incidents_drawer grid ~cache ~rect ~theme ~model
        | Nav.Queue_context active_tab ->
            render_queue_context_drawer grid ~cache ~rect ~theme ~model
              ~active_tab
        | Nav.Inline_action kind ->
            render_inline_action_modal grid ~cache ~rect ~theme ~model ~kind
        | Nav.Help -> render_help_overlay grid ~cache ~rect ~theme ~model
        | Nav.System_gate gate ->
            render_system_gate grid ~cache ~rect ~theme ~model ~gate
