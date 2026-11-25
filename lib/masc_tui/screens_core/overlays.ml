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
  | Palette_overflow of string
  | Palette_item of {
      selectable_idx : int option;
      badge : string;
      title : string;
      meta : string;
      tone : Theme.status_token option;
    }

let palette_section_header ~lang = function
  | Update_nav.Pal_sec_commands ->
      Say.resolve lang (Say.make ~ko:"명령" ~en:"Commands")
  | Update_nav.Pal_sec_workspaces ->
      Say.resolve lang (Say.make ~ko:"화면 · 메뉴" ~en:"Screens & Menus")
  | Update_nav.Pal_sec_keepers ->
      Say.resolve lang (Say.make ~ko:"키퍼" ~en:"Keepers")
  | Update_nav.Pal_sec_companies ->
      Say.resolve lang (Say.make ~ko:"조직" ~en:"Companies")
  | Update_nav.Pal_sec_goals_tasks ->
      Say.resolve lang (Say.make ~ko:"목표 · 작업" ~en:"Goals & Tasks")
  | Update_nav.Pal_sec_board_wiki ->
      Say.resolve lang (Say.make ~ko:"보드 · 위키" ~en:"Board & Wiki")
  | Update_nav.Pal_sec_sandboxes ->
      Say.resolve lang (Say.make ~ko:"샌드박스" ~en:"Sandboxes")
  | Update_nav.Pal_sec_settings ->
      Say.resolve lang (Say.make ~ko:"설정 키" ~en:"Settings Keys")
  | Update_nav.Pal_sec_slash ->
      Say.resolve lang
        (Say.make
           ~ko:(Printf.sprintf "슬래시 명령 (%d)" (List.length Slash.all))
           ~en:(Printf.sprintf "Slash Commands (%d)" (List.length Slash.all)))

let equal_palette_section a b =
  match a, b with
  | Update_nav.Pal_sec_commands, Update_nav.Pal_sec_commands
  | Update_nav.Pal_sec_workspaces, Update_nav.Pal_sec_workspaces
  | Update_nav.Pal_sec_keepers, Update_nav.Pal_sec_keepers
  | Update_nav.Pal_sec_companies, Update_nav.Pal_sec_companies
  | Update_nav.Pal_sec_goals_tasks, Update_nav.Pal_sec_goals_tasks
  | Update_nav.Pal_sec_board_wiki, Update_nav.Pal_sec_board_wiki
  | Update_nav.Pal_sec_sandboxes, Update_nav.Pal_sec_sandboxes
  | Update_nav.Pal_sec_settings, Update_nav.Pal_sec_settings
  | Update_nav.Pal_sec_slash, Update_nav.Pal_sec_slash ->
      true
  | ( Update_nav.Pal_sec_commands
    | Update_nav.Pal_sec_workspaces
    | Update_nav.Pal_sec_keepers
    | Update_nav.Pal_sec_companies
    | Update_nav.Pal_sec_goals_tasks
    | Update_nav.Pal_sec_board_wiki
    | Update_nav.Pal_sec_sandboxes
    | Update_nav.Pal_sec_settings
    | Update_nav.Pal_sec_slash )
    , _ ->
      false

let build_universal_palette_rows (m : Model.t) =
  let lang = m.lang in
  let entries, overflow = Update_nav.palette_entries_with_overflow m in
  let overflow_for sec =
    List.find_map
      (fun (s, n) -> if equal_palette_section s sec then Some n else None)
      overflow
  in
  let rows = ref [] in
  let prev_sec = ref None in
  let flush_overflow () =
    match !prev_sec with
    | None -> ()
    | Some sec -> (
        match overflow_for sec with
        | Some n when n > 0 ->
            let msg =
              Say.resolve lang
                (Say.make
                   ~ko:(Printf.sprintf "  +%d개 더 있음 — 검색어를 입력해 좁히세요" n)
                   ~en:(Printf.sprintf "  +%d more — type to narrow" n))
            in
            rows := Palette_overflow msg :: !rows
        | Some _ | None -> ())
  in
  List.iteri
    (fun idx (e : Update_nav.palette_entry) ->
      let changed =
        match !prev_sec with
        | Some s -> not (equal_palette_section s e.section)
        | None -> true
      in
      if changed then begin
        flush_overflow ();
        rows := Palette_header (palette_section_header ~lang e.section) :: !rows;
        prev_sec := Some e.section
      end;
      rows :=
        Palette_item
          {
            selectable_idx = Some idx;
            badge = e.badge;
            title = e.title;
            meta = e.meta;
            tone = e.tone;
          }
        :: !rows)
    entries;
  flush_overflow ();
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
      let show_mode_bar = inner.h >= 4 in
      if show_mode_bar then begin
        let mode_y = inner.y + 1 in
        let mode_r = Rect.make ~x:q_left ~y:mode_y ~w:q_w ~h:1 in
        let modes =
          [
            ( Model.Palette_commands
            , Say.resolve lang (Say.make ~ko:"^K 명령·전체" ~en:"^K Commands") );
            ( Model.Palette_keepers
            , Say.resolve lang (Say.make ~ko:"^G 키퍼" ~en:"^G Keepers") );
            ( Model.Palette_models
            , Say.resolve lang (Say.make ~ko:"^L 모델" ~en:"^L Models") );
          ]
        in
        let mx = ref q_left in
        List.iteri
          (fun idx (md, lbl) ->
            if idx > 0 then begin
              let sep = "  " ^ Glyph.to_utf8 Glyph.Separator_dot ^ "  " in
              let adv =
                Cell_grid.put_text ~clip:mode_r grid ~x:!mx ~y:mode_y
                  ~style:whisper_st sep
              in
              mx := !mx + adv
            end;
            let active = Model.equal_palette_mode model.palette.mode md in
            let st =
              if active then Typography.anchor ~bg ~underline:true theme
              else Typography.structure ~bg theme
            in
            let prefix = if active then Glyph.to_utf8 Glyph.Left_rail ^ " " else "" in
            let adv =
              Cell_grid.put_text ~clip:mode_r grid ~x:!mx ~y:mode_y ~style:st
                (prefix ^ lbl)
            in
            mx := !mx + adv)
          modes;
        Card.draw_hairline ~pad_x ~bg grid ~rect:inner ~y:(inner.y + 2) ~theme
      end
      else if inner.h >= 2 then
        Card.draw_hairline ~pad_x ~bg grid ~rect:inner ~y:(inner.y + 1) ~theme;
      let list_y = inner.y + if show_mode_bar then 3 else 2 in
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
                | Palette_header _
                | Palette_overflow _
                | Palette_item { selectable_idx = None; _ } ->
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
                | Palette_header _ | Palette_overflow _ | Palette_item _ ->
                    find (i + 1)
            in
            find 0
          in
          let start, _ =
            Table.compute_viewport ~total_rows:total ~viewport_rows:list_h
              ~scroll:model.nav.palette_scroll_offset
              ~selected:(Some selected_row_pos)
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
              | Palette_overflow msg ->
                  ignore
                    (Cell_grid.put_text ~clip:row_r grid ~x:q_left ~y:py
                       ~style:whisper_st
                       (Grapheme.truncate_to_width ~max_width:q_w msg))
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
      | Wire_config.Field_structured ->
          Form.Text_val value
      | Wire_config.Field_secret ->
          Form.secret_val ~revealed:false value)

let form_field_of_schema_field ~(m : Model.t) (f : Wire_config.schema_field) :
    Form.field =
  let initial =
    if String.equal f.full_key "tui.theme" then
      let opts =
        List.map
          (fun p -> (Theme.preset_name p, Theme.preset_label p))
          Theme.all_presets
      in
      let idx =
        let rec find i = function
          | [] -> 0
          | p :: _ when Theme.equal_preset p m.theme_preset -> i
          | _ :: rest -> find (i + 1) rest
        in
        find 0 Theme.all_presets
      in
      Form.enum_val ~selected:idx opts
    else if String.equal f.full_key "tui.language" then
      let idx = match m.lang with Say.Lang_ko -> 0 | Say.Lang_en -> 1 in
      Form.enum_val ~selected:idx
        [
          ("ko", Say.make ~ko:"한국어" ~en:"Korean (KO)");
          ("en", Say.make ~ko:"English" ~en:"English (EN)");
        ]
    else form_value_of_wire_field f
  in
  let value =
    match m.config.editing_field_key with
    | Some ek when String.equal ek f.full_key -> (
        if f.secret then Form.secret_val ~revealed:false m.config.editing_buffer
        else
          match f.kind with
          | Wire_config.Field_int _ ->
              Form.int_val_of_raw m.config.editing_buffer
          | Wire_config.Field_float _ ->
              Form.float_val_of_raw m.config.editing_buffer
          | Wire_config.Field_secret ->
              Form.secret_val ~revealed:false m.config.editing_buffer
          | Wire_config.Field_bool
          | Wire_config.Field_string
          | Wire_config.Field_enum _
          | Wire_config.Field_string_list
          | Wire_config.Field_structured ->
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
  let provenance =
    if Config_store.is_tui_pref_key f.full_key then Form.Prov_tui_pref
    else form_provenance_of_wire ~target:m.config.target ~env:f.env f.provenance
  in
  let base =
    Form.make_field ~key:f.full_key ~label:leaf_label
      ?help:(Option.map Say.literal f.description)
      ~provenance
      ~reload_scope:(form_reload_of_wire f.reload_scope)
      ~validators ~read_only:(not f.writable || f.secret) initial
  in
  let updated = { base with value } in
  { updated with error = Form.validate_field updated }

let inspector_schema_fields (m : Model.t) =
  Config_store.inspector_fields m.config

let settings_form_of_model (m : Model.t) : Form.state =
  let schema_fields = inspector_schema_fields m in
  let fields = List.map (form_field_of_schema_field ~m) schema_fields in
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
              if is_focused then theme.selection_bg
              else if is_selected then theme.surface_2
              else theme.surface_1
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
            if val_w > 0 then begin
              let is_editing_this =
                is_focused && form_state.editing
                && Option.equal String.equal model.config.editing_field_key
                     (Some f.key)
              in
              if is_editing_this then begin
                let raw, cur =
                  match f.value with
                  | Form.Secret_val { revealed = false; _ } ->
                      (val_str, String.length val_str)
                  | Form.Text_val _
                  | Form.Multiline_val _
                  | Form.Int_val _
                  | Form.Float_val _
                  | Form.Bool_val _
                  | Form.Enum_val _
                  | Form.Secret_val { revealed = true; _ } ->
                      let buf = model.config.editing_buffer in
                      (buf, Config_store.clamp_edit_cursor buf model.config.editing_cursor)
                in
                let raw_len = String.length raw in
                let before = String.sub raw 0 cur in
                let after = String.sub raw cur (raw_len - cur) in
                let marked = before ^ "▏" ^ after in
                let rendered =
                  if Grapheme.display_width marked <= val_w then marked
                  else
                    let budget = Int.max 1 (val_w - 1) in
                    let keep_before = Int.max 1 ((budget * 2) / 3) in
                    let rec drop_prefix s =
                      if Grapheme.display_width s <= keep_before then s
                      else
                        let sl = String.length s in
                        if sl <= 0 then ""
                        else
                          let d = String.get_utf_8_uchar s 0 in
                          let step = Int.max 1 (Uchar.utf_decode_length d) in
                          drop_prefix (String.sub s step (sl - step))
                    in
                    let head_s =
                      if Grapheme.display_width before > keep_before then
                        "…" ^ drop_prefix before
                      else before
                    in
                    Grapheme.truncate_to_width ~max_width:val_w
                      (head_s ^ "▏" ^ after)
                in
                ignore
                  (Cell_grid.put_text ~clip:row_r grid ~x:val_x ~y:!y
                     ~style:val_st rendered)
              end
              else
                ignore
                  (Cell_grid.put_text ~clip:row_r grid ~x:val_x ~y:!y
                     ~style:val_st
                     (Grapheme.truncate_to_width ~max_width:val_w val_str))
            end;
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
                              ~ko:"[←→] 값 변경 · [Enter] 편집 · [d] Dry-run · [Ctrl+S] 저장 · [Tab] 트리"
                              ~en:"[←→] Cycle · [Enter] Edit · [d] Dry-run · [Ctrl+S] Save · [Tab] Tree"))))
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
                            ~ko:"[←→] 값 변경 · [Enter] 편집 · [d] Dry-run · [Tab] 트리"
                            ~en:"[←→] Cycle · [Enter] Edit · [d] Dry-run · [Tab] Tree"))))
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
                (if is_sel && tree_focused then theme.selection_bg
                 else if is_sel then theme.surface_2
                 else theme.surface_1)
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
                (if is_sel && tree_focused then theme.selection_bg
                 else if is_sel then theme.surface_2
                 else theme.surface_1)
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
                (if is_sel && tree_focused then theme.selection_bg
                 else if is_sel then theme.surface_2
                 else theme.surface_1)
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

let render_dry_run_pane ?(scroll = 0) grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~lang ~pad_x ~(dry_run_preview : Config_store.dry_run_state) =
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
               ~scroll diff_rows)

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
              (Say.make ~ko:"▸ 속성 검사기 · 활성  [←→] 값 변경 · [Enter] 편집 · [Del] 삭제"
                 ~en:"▸ INSPECTOR · FOCUS  [←→] Cycle · [Enter] Edit · [Del] Remove")
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
                     ~ko:(Printf.sprintf "✓ 새 키퍼: %s  ([n] 변경 · [d] 검증 · [Ctrl+S] 생성)"
                            model.config.new_keeper_name)
                     ~en:(Printf.sprintf "✓ New keeper: %s  ([n] Rename · [d] Diff · [Ctrl+S] Create)"
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
      render_dry_run_pane ~scroll:model.config.dry_run_scroll_offset grid
        ~rect:dry_r ~theme ~lang ~pad_x
        ~dry_run_preview:model.config.dry_run_preview

let format_build_summary (model : Model.t) =
  let tui_lbl = Model.tui_build_label model in
  let server_lbl = Model.server_build_label model in
  let sep = " " ^ Glyph.to_utf8 Glyph.Separator_dot ^ " " in
  match (String.equal tui_lbl "", server_lbl) with
  | true, None -> None
  | false, None -> Some ("TUI " ^ tui_lbl)
  | true, Some srv -> Some ("Server " ^ srv)
  | false, Some srv ->
      let mark =
        if Model.build_commit_mismatch model then
          " " ^ Glyph.to_utf8 Glyph.Warning_triangle
        else ""
      in
      Some (Printf.sprintf "TUI %s%sServer %s%s" tui_lbl sep srv mark)

let render_settings grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~active_tab:_ =
  (* Full overlay rect so underlying workspace chrome never bleeds at col 0 / right wall *)
  let modal_r = rect in
  if Rect.is_empty modal_r then ()
  else
    let lang = model.lang in
    let dirty_n = Config_store.dirty_count model.config in
    let tui_lbl = Model.tui_build_label model in
    let server_lbl = Model.server_build_label model in
    let show_server_in_subtitle = modal_r.w >= 132 && dirty_n = 0 in
    let subtitle =
      if show_server_in_subtitle then format_build_summary model
      else if not (String.equal tui_lbl "") then Some ("TUI " ^ tui_lbl)
      else
        match server_lbl with
        | Some srv -> Some ("Server " ^ srv)
        | None -> None
    in
    let title =
      if modal_r.w < 110 && Option.is_some subtitle then
        Say.resolve lang (Say.make ~ko:"설정" ~en:"Settings")
      else
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
          (Say.make ~ko:"[^S] 저장 · [d] 검증 · [Esc] 닫기"
             ~en:"[^S] Save · [d] Diff · [Esc] Close")
      else
        Say.resolve lang
          (Say.make ~ko:"[d] Dry-run · [Ctrl+S] 저장 · [Esc] 닫기"
             ~en:"[d] Dry-run · [Ctrl+S] Save · [Esc] Close")
    in
    let footer_hint =
      if modal_r.w >= 96 then
        Say.resolve lang
          (Say.make ~ko:"[Tab] 좌/우 · [Enter] 편집 · [Del] 삭제 · [^E] $EDITOR · [/] 검색 · [?]"
             ~en:"[Tab] Pane · [Enter] Edit · [Del] Remove · [^E] $EDITOR · [/] Search · [?]")
      else if modal_r.w >= 74 then
        Say.resolve lang
          (Say.make ~ko:"[Tab] 좌/우 · [Enter] 편집 · [^E] $EDITOR · [/] 검색"
             ~en:"[Tab] Pane · [Enter] Edit · [^E] $EDITOR · [/] Search")
      else
        Say.resolve lang
          (Say.make ~ko:"[Enter] 편집 · [^E] $EDITOR · [/] 검색"
             ~en:"[Enter] Edit · [^E] $EDITOR · [/] Search")
    in
    let inner =
      Card.draw ~cache grid ~rect:modal_r ~theme
        {
          (Card.default_spec ~title) with
          subtitle;
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
      let show_dirty = rd_w > 0 && right_edge - rd_w > !tx + 4 in
      let dirty_x = right_edge - rd_w in
      let server_row_txt, server_row_st =
        if not show_server_in_subtitle then
          match server_lbl with
          | Some srv ->
              let mismatch = Model.build_commit_mismatch model in
              let txt =
                if mismatch then
                  Printf.sprintf "Server %s %s" srv
                    (Glyph.to_utf8 Glyph.Warning_triangle)
                else "Server " ^ srv
              in
              (txt, if mismatch then attn_st else whisper_st)
          | None -> ("", whisper_st)
        else ("", whisper_st)
      in
      let srv_w = Grapheme.display_width server_row_txt in
      let server_right_edge = if show_dirty then dirty_x - 2 else right_edge in
      let server_x = server_right_edge - srv_w in
      let show_server_row = srv_w > 0 && server_x >= !tx + 14 in
      let reserved_left_edge =
        if show_server_row then server_x - 2
        else if show_dirty then dirty_x - 2
        else right_edge
      in
      let search_max_w = Int.max 0 (reserved_left_edge - !tx) in
      if search_max_w > 6 then
        ignore
          (Cell_grid.put_text ~clip:top_r grid ~x:!tx ~y:inner.y ~style:search_st
             (Grapheme.truncate_to_width ~max_width:search_max_w search_txt));
      if show_server_row then
        ignore
          (Cell_grid.put_text ~clip:top_r grid ~x:server_x ~y:inner.y
             ~style:server_row_st server_row_txt);
      if show_dirty then
        ignore
          (Cell_grid.put_text ~clip:top_r grid ~x:dirty_x ~y:inner.y
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
    let dismissed_tag =
      if model.incidents.show_dismissed then
        Say.resolve lang (Say.make ~ko:" · 숨김 포함" ~en:" · +dismissed")
      else ""
    in
    let badge : Card.badge =
      if model.incidents.clear_confirm_armed then
        {
          glyph = Some Glyph.Warning_triangle;
          text =
            Say.resolve lang
              (Say.make ~ko:"[c/D] 재입력 시 전체 삭제" ~en:"[c/D] again to clear");
          tone = Some Theme.Status_critical;
        }
      else
        {
          glyph = Some Glyph.Historical_incident;
          text =
            Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "활성 %d%s" active_n dismissed_tag)
                 ~en:(Printf.sprintf "%d active%s" active_n dismissed_tag));
          tone = Some Theme.Status_historical;
        }
    in
    let hotkey =
      Say.resolve lang
        (Say.make
           ~ko:"[d] 숨김 · [Space] 숨김표시 · [J/K] 상세 · [c] 비우기 · [o] 이동 · [Esc]"
           ~en:"[d] Dismiss · [Space] Show hidden · [J/K] Detail · [c] Clear · [o] Jump · [Esc]")
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
      let q_inc = String.trim model.incidents.filter_query in
      let tail_window ~max_w s =
        if Grapheme.display_width s <= max_w then s
        else
          let keep = Int.max 1 (max_w - 1) in
          let rec drop s =
            if Grapheme.display_width s <= keep then s
            else
              let sl = String.length s in
              if sl <= 0 then ""
              else
                let d = String.get_utf_8_uchar s 0 in
                let step = Int.max 1 (Uchar.utf_decode_length d) in
                drop (String.sub s step (sl - step))
          in
          "…" ^ drop s
      in
      let max_q_w = Int.max 8 (hdr_r.w / 2) in
      let filter_pill, filter_st =
        if model.nav.filter_focused then
          ( Printf.sprintf " / %s▏ "
              (tail_window ~max_w:max_q_w model.incidents.filter_query),
            Typography.anchor ~bg:(Color.of_rgb theme.selection_bg) theme )
        else if not (String.equal q_inc "") then
          ( Printf.sprintf " / %s (%d) "
              (tail_window ~max_w:max_q_w q_inc) (List.length entries),
            Typography.accent ~bg:(Color.of_rgb theme.surface_1) ~bold:true theme )
        else
          ( Say.resolve lang (Say.make ~ko:"[/] 필터" ~en:"[/] Filter"),
            whisper_st )
      in
      let fp_w = Grapheme.display_width filter_pill in
      let note =
        Say.resolve lang
          (Say.make
             ~ko:"과거/해결 이력은 실시간 상태 표시줄을 붉게 물들이지 않습니다."
             ~en:"Historical Channel-3 trail — never taints live SSOT health.")
      in
      let note_max = Int.max 0 (hdr_r.w - fp_w - 2) in
      if note_max > 8 then
        ignore
          (Cell_grid.put_text ~clip:hdr_r grid ~x:hdr_r.x ~y:inner.y
             ~style:whisper_st
             (Grapheme.truncate_to_width ~max_width:note_max note));
      let fpx = Int.max hdr_r.x (Rect.right hdr_r - fp_w) in
      ignore
        (Cell_grid.put_text ~clip:hdr_r grid ~x:fpx ~y:inner.y ~style:filter_st
           (Grapheme.truncate_to_width ~max_width:hdr_r.w filter_pill));
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
                    ignore
                      (Json_tree.draw grid ~rect:tree_r ~theme
                         ~scroll:model.incidents.detail_scroll_offset lines)
                | None ->
                    let safe_detail =
                      Render_util.redact_plain_text_secrets inc.detail
                    in
                    ignore
                      (Markdown.draw grid ~rect:payload_r ~theme
                         ~osc8:caps.osc8_hyperlinks
                         ~scroll:model.incidents.detail_scroll_offset
                         safe_detail)
        end
    end

(* ---------- Overlay 4: Ctrl+T Keeper Queue, Context & Schedules Drawer ---------- *)

(* ---------- Ctrl+T Context tab ---------- *)

(* The gauge reads the roster's context projection: a measured fill, the
   server's estimate (flagged so the title can say so), or no fill. The hint
   carries the measured tokens and window, or the server's reason when there
   is no measured fill. *)
let context_gauge_reading (k : Wire_fleet.keeper_summary) =
  match k.context with
  | Observed.Value { data; observed_at; stale } ->
      let used, estimated =
        match Fleet_store.context_display data with
        | Fleet_store.Context_fill { ratio; estimated } ->
            (Observed.value ~observed_at ~stale (ratio *. 100.0), estimated)
        | Fleet_store.Context_tokens_only _ | Fleet_store.Context_unavailable _
          ->
            (Observed.absent, false)
      in
      let hint =
        match data with
        | Wire_fleet.Context_measured { tokens; window; absolute_turn; _ } -> (
            let tok =
              Format_val.format_value Format_val.Count (Float.of_int tokens)
            in
            let turn =
              match absolute_turn with
              | Some n -> Printf.sprintf " · #%d" n
              | None -> ""
            in
            match window with
            | Some w ->
                Say.literal
                  (Printf.sprintf "%s / %s tok%s" tok
                     (Format_val.format_value Format_val.Count (Float.of_int w))
                     turn)
            | None ->
                Say.make
                  ~ko:(Printf.sprintf "%s tok · 창 크기 미보고%s" tok turn)
                  ~en:(Printf.sprintf "%s tok · window unreported%s" tok turn))
        | Wire_fleet.Context_not_measured { reason; _ } ->
            Fleet_store.context_unavailable_label reason
      in
      (used, Some hint, estimated)
  | Observed.Loading { since_ns } -> (Observed.loading ~since_ns, None, false)
  | Observed.Absent -> (Observed.absent, None, false)
  | Observed.Unreported -> (Observed.unreported, None, false)
  | Observed.Failed { reason; retryable; at } ->
      (Observed.failed ~reason ~retryable ~at, None, false)

(* One sample per turn record, oldest first. A turn the server would not
   count as a measured request stays blank instead of reading as zero. *)
let context_history_samples (fills : float option list) =
  Array.of_list
    (List.map
       (function
         | Some r when r > 0.0 -> Chart.Series.Value (r *. 100.0)
         | Some _ -> Chart.Series.Zero
         | None -> Chart.Series.Absent)
       fills)

let context_pct r = Printf.sprintf "%.0f%%" (r *. 100.0)

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
                 (match active_tab with
                  | Nav.Drawer_queue | Nav.Drawer_context | Nav.Drawer_schedules ->
                      Say.make ~ko:"[↑↓] 스크롤 · [[ ]/Tab] 탭 · [Esc] 닫기"
                        ~en:"[↑↓] Scroll · [[ ]/Tab] Tabs · [Esc] Close"));
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
            let rows_acc = ref [] in
            let push style txt = rows_acc := (style, txt) :: !rows_acc in
            let attn_count = Attention.count model.attention in
            if attn_count > 0 then begin
              push (Typography.anchor ~bg theme)
                (Say.resolve lang
                   (Say.make
                      ~ko:(Printf.sprintf "대기 중인 승인·확인 (%d건)" attn_count)
                      ~en:(Printf.sprintf "Pending Attention / Approvals (%d)"
                             attn_count)));
              List.iter
                (fun (entry : Attention.entry) ->
                  let kind_tag =
                    match entry.kind with
                    | Health.Held_tool_approval _ -> "[TOOL]"
                    | Health.Pending_ask _ -> "[ASK]"
                    | Health.Goal_confirmation _ -> "[GOAL]"
                  in
                  let in_flight =
                    Attention.is_in_flight ~id:entry.id model.attention
                  in
                  let keeper_s =
                    match entry.keeper with
                    | Some k -> " @" ^ k
                    | None -> ""
                  in
                  let status_s =
                    if in_flight then
                      Say.resolve lang (Say.make ~ko:" (전송 중)" ~en:" (in flight)")
                    else ""
                  in
                  let summary_one =
                    String.map (function '\n' | '\r' -> ' ' | c -> c)
                      (String.trim entry.summary)
                  in
                  let detail =
                    if String.equal summary_one "" then ""
                    else " · " ^ summary_one
                  in
                  let style = if in_flight then whisper_st else attn_st in
                  push style
                    (Printf.sprintf "  %s%s %s%s%s" kind_tag keeper_s entry.title
                       status_s detail))
                model.attention.items;
              push whisper_st
                (Say.resolve lang
                   (if Model.equal_breakpoint model.breakpoint Model.Micro then
                      Say.make
                        ~ko:"  [Esc] 닫기 · 승인·처리는 터미널을 80x24 이상으로 넓혀 진행하세요"
                        ~en:"  [Esc] close · enlarge terminal >= 80x24 to approve or resolve"
                    else
                      Say.make
                        ~ko:"  [Esc] 닫기 · 상단 바 [Y]/[N] 또는 [2 Work > Inbox]에서 처리"
                        ~en:"  [Esc] close · resolve via [Y]/[N] strip or [2 Work > Inbox]"));
              push pri_st ""
            end;
            let queue, txs = Model.drawer_queue ~keeper model in
            let draft = Drafts.draft_for ~keeper model.drafts in
            let one_line = String.map (function '\n' | '\r' -> ' ' | c -> c) in
            (match queue.read with
             | Observed.Value { stale; _ } ->
                 let label =
                   if stale then Say.make ~ko:"서버 대기열 · 마지막 조회" ~en:"Server queue · last read"
                   else Say.make ~ko:"서버 대기열" ~en:"Server queue"
                 in
                 push (Typography.anchor ~bg theme)
                   (Printf.sprintf "%s (%d)" (Say.resolve lang label) (List.length queue.operations))
             | Observed.Failed { reason; _ } ->
                 let label =
                   match queue.operations with
                   | [] -> Say.make ~ko:"서버 대기열 조회 실패" ~en:"Server queue read failed"
                   | _ :: _ -> Say.make ~ko:"서버 대기열 조회 실패 · 마지막 관측" ~en:"Server queue read failed · last observed rows"
                 in
                 push crit_st (Say.resolve lang label ^ " · " ^ reason)
             | Observed.Loading _ | Observed.Unreported | Observed.Absent ->
                 let label = if Option.is_none (Model.target_keeper model) then
                     Say.make ~ko:"키퍼를 선택하세요" ~en:"Select a Keeper"
                   else Say.make ~ko:"서버 대기열 조회 중…" ~en:"Reading server queue…" in
                 push whisper_st (Say.resolve lang label));
            List.iter (fun (op : Wire_fleet.chat_operation) ->
               let body = Option.value op.message ~default:"" |> one_line in
               push pri_st (Printf.sprintf "  %s  %s" (Keeper_chat_operation.Operation_id.to_string op.id) body))
              queue.operations;
            if txs <> [] then begin
              push (Typography.anchor ~bg theme)
                (Say.resolve lang (Say.make ~ko:"이 세션의 전송" ~en:"Session transmissions"));
              List.iter
                (fun (tx : Drafts.pending_message) ->
                  let mode_s =
                    match tx.mode with
                    | Drafts.Mode_direct -> "[Direct]"
                    | Drafts.Mode_steer -> "[Steer]"
                    | Drafts.Mode_follow_up -> "[FollowUp]"
                  in
                  let st_s, st_style =
                    match tx.state with
                    | Drafts.Delivered ->
                        ( Say.resolve lang
                            (Say.make ~ko:"전송 완료" ~en:"Delivered"),
                          ok_st )
                    | Drafts.No_operation_record ->
                        (Say.resolve lang (Drafts.absence_notice tx), attn_st)
                    | Drafts.Failed_retryable { reason } ->
                        ( Say.resolve lang
                            (Say.make ~ko:("전송 실패: " ^ reason)
                               ~en:("Send failed: " ^ reason)),
                          crit_st )
                    | Drafts.Queued
                    | Drafts.Sending
                    | Drafts.Pending_processing
                    | Drafts.Confirming_delivery
                    | Drafts.Interrupting ->
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
                  push st_style
                    (Printf.sprintf "  %s %s (%s) · %s" mode_s st_s tx.request_id
                       body_one))
                txs
            end;
            push pri_st "";
            push (Typography.anchor ~bg theme)
              (Say.resolve lang
                 (Say.make ~ko:"보존 초안 (Carry)" ~en:"Preserved Draft (Carry)"));
            let draft_empty = String.equal (String.trim draft.text) "" in
            if draft_empty then
              push whisper_st
                (Say.resolve lang (Say.make ~ko:"  비어 있음" ~en:"  Empty"))
            else
              push pri_st
                ("  "
                 ^ String.map (function '\n' | '\r' -> ' ' | c -> c) draft.text);
            let others = Drafts.other_keepers_draft_count model.drafts in
            if others > 0 then
              push whisper_st
                (Say.resolve lang
                   (Say.make
                      ~ko:(Printf.sprintf "  다른 키퍼 초안 %d건 보존 중" others)
                      ~en:(Printf.sprintf "  %d other keeper draft(s) preserved"
                             others)));
            let rows = List.rev !rows_acc in
            let max_skip = Int.max 0 (List.length rows - Int.max 1 body_r.h) in
            let skip =
              Int.min max_skip (Int.max 0 model.nav.queue_scroll_offset)
            in
            let y = ref body_r.y in
            let bottom = Rect.bottom body_r in
            List.iter
              (fun (style, txt) ->
                if !y < bottom then begin
                  if not (String.equal txt "") then begin
                    let r = Rect.make ~x:body_r.x ~y:!y ~w:body_r.w ~h:1 in
                    ignore
                      (Cell_grid.put_text ~clip:r grid ~x:body_r.x ~y:!y ~style
                         (Grapheme.truncate_to_width ~max_width:body_r.w txt))
                  end;
                  incr y
                end)
              (Store_scroll.drop skip rows)
        | Nav.Drawer_context ->
            let keeper_opt = Fleet_store.find_keeper ~name:keeper model.fleet in
            let ctx_st =
              Keeper_context_store.get_keeper ~keeper model.keeper_context
            in
            let eff_row =
              match Observed.to_option model.runtime.efficiency with
              | None -> None
              | Some eff ->
                  List.find_opt
                    (fun (r : Wire_runtime.keeper_efficiency_row) ->
                      String.equal r.keeper keeper)
                    eff.keepers
            in
            let skip = Int.max 0 model.nav.queue_scroll_offset in
            let vy = ref 0 in
            let bottom = Rect.bottom body_r in
            let screen_y_for v = body_r.y + (v - skip) in
            let put_body_line ~style txt =
              let sy = screen_y_for !vy in
              if !vy >= skip && sy < bottom then
                ignore
                  (Cell_grid.put_text ~clip:body_r grid ~x:body_r.x ~y:sy ~style
                     (Grapheme.truncate_to_width ~max_width:body_r.w txt));
              incr vy
            in
            let say ~ko ~en = Say.resolve lang (Say.make ~ko ~en) in
            let turn_entry = Keeper_context_store.selected_turn_entry ctx_st in
            (match (Observed.to_option ctx_st.turn_records, turn_entry) with
             | Some page, Some e ->
                 let sy = screen_y_for !vy in
                 if !vy >= skip && sy < bottom then begin
                   let r = e.record in
                   let step_s =
                     Printf.sprintf "Turn #%d (%d/%d) · %s · %s"
                       r.absolute_turn (ctx_st.selected_turn_idx + 1)
                       (List.length page.entries)
                       (Ids.Turn_ref.to_string r.turn_ref) r.runtime_profile
                   in
                   let hint_s =
                     Say.resolve lang
                       (Say.make ~ko:"[< >] 턴 · [Enter] 상세"
                          ~en:"[< >] Turn · [Enter] Dive")
                   in
                   let hw = Grapheme.display_width hint_s in
                   let lw = Int.max 8 (body_r.w - hw - 2) in
                   let row_r = Rect.make ~x:body_r.x ~y:sy ~w:body_r.w ~h:1 in
                   ignore
                     (Cell_grid.put_text ~clip:row_r grid ~x:body_r.x ~y:sy
                        ~style:(Typography.anchor ~bg theme)
                        (Grapheme.truncate_to_width ~max_width:lw step_s));
                   if body_r.w > hw + 10 then
                     ignore
                       (Cell_grid.put_text ~clip:row_r grid
                          ~x:(Rect.right row_r - hw) ~y:sy ~style:acc_st hint_s)
                 end;
                 incr vy
             | _ -> ());
            let ctx_used, ctx_hint, ctx_estimated =
              match keeper_opt with
              | Some k -> context_gauge_reading k
              | None -> (Observed.unreported, None, false)
            in
            let used_obs, lim_obs, unit_kind =
              match turn_entry with
              | Some e ->
                  let r = e.record in
                  let denom =
                    match r.provider_context_window with
                    | Some w when w > 0 -> Some w
                    | Some _ | None -> r.context_window
                  in
                  ( (match r.usage.input_tokens with
                     | Some n ->
                         Observed.value ~observed_at:Clock.Mono.zero
                           (float_of_int n)
                     | None -> Observed.unreported),
                    (match denom with
                     | Some n ->
                         Observed.value ~observed_at:Clock.Mono.zero
                           (float_of_int n)
                     | None -> Observed.unreported),
                    Format_val.Tokens )
              | None ->
                  ( ctx_used,
                    Observed.value ~observed_at:Clock.Mono.zero 100.0,
                    Format_val.Percent )
            in
            (let sy = screen_y_for !vy in
             if !vy >= skip && sy + 2 <= bottom then begin
               let gauge_r = Rect.make ~x:body_r.x ~y:sy ~w:body_r.w ~h:2 in
               let spec : Chart.Spec.t =
                 {
                   title =
                     (if ctx_estimated && Option.is_none turn_entry then
                        Say.make ~ko:"컨텍스트 윈도우 점유율 (추정)"
                          ~en:"Context Window Fill (estimate)"
                      else
                        Say.make ~ko:"컨텍스트 윈도우 점유율"
                          ~en:"Context Window Fill");
                   kind =
                     Chart.Spec.Ratio_gauge
                       {
                         used = used_obs;
                         limit = lim_obs;
                         unit = unit_kind;
                         gradient = Chart.Gradient.Thermal;
                         reset_hint = ctx_hint;
                       };
                   hotkey_hint = None;
                 }
               in
               ignore (Chart.draw grid ~rect:gauge_r ~theme ~caps ~lang spec)
             end;
             vy := !vy + 3);
            let draw_turn_composition () =
              match turn_entry with
              | Some e ->
                  let r = e.record in
                  let prompt_b, tools_b, msgs_b =
                    match r.input_components with
                    | Some comps ->
                        List.fold_left
                          (fun (pb, tb, mb) (c : Turn_record.input_component) ->
                            match c.component with
                            | Turn_record.Prompt_block _ -> (pb + c.bytes, tb, mb)
                            | Turn_record.Tool_schemas -> (pb, tb + c.bytes, mb)
                            | Turn_record.Message_user
                            | Turn_record.Message_system
                            | Turn_record.Message_assistant_text
                            | Turn_record.Message_thinking
                            | Turn_record.Message_redacted_thinking
                            | Turn_record.Message_tool_use
                            | Turn_record.Message_tool_result
                            | Turn_record.Message_image
                            | Turn_record.Message_document
                            | Turn_record.Message_audio ->
                                (pb, tb, mb + c.bytes))
                          (0, 0, 0) comps
                    | None ->
                        ( List.fold_left
                            (fun acc (b : Turn_record.prompt_block) ->
                              acc + b.bytes)
                            0 r.blocks,
                          0,
                          0 )
                  in
                  if prompt_b + tools_b + msgs_b > 0 then begin
                    let sy = screen_y_for !vy in
                    if !vy >= skip && sy + 3 <= bottom then begin
                      let bar_r = Rect.make ~x:body_r.x ~y:sy ~w:body_r.w ~h:3 in
                      let spec : Chart.Spec.t =
                        {
                          title =
                            Say.make ~ko:"턴 입력 구성 (바이트)"
                              ~en:"Turn Input Composition";
                          kind =
                            Chart.Spec.Stacked_bar
                              {
                                segments =
                                  [
                                    ( Say.make ~ko:"프롬프트" ~en:"Prompt",
                                      float_of_int prompt_b,
                                      Theme.Status_active );
                                    ( Say.make ~ko:"도구 스키마" ~en:"Tools",
                                      float_of_int tools_b,
                                      Theme.Status_ai );
                                    ( Say.make ~ko:"메시지" ~en:"Messages",
                                      float_of_int msgs_b,
                                      Theme.Status_ok );
                                  ];
                                total_label =
                                  Say.literal
                                    (Format_val.format_value Format_val.Bytes
                                       (float_of_int
                                          (prompt_b + tools_b + msgs_b)));
                                unit = Format_val.Bytes;
                              };
                          hotkey_hint = None;
                        }
                      in
                      ignore (Chart.draw grid ~rect:bar_r ~theme ~caps ~lang spec)
                    end;
                    vy := !vy + 3
                  end
              | None -> ()
            in
            (match eff_row with
             | Some r ->
                 let sy = screen_y_for !vy in
                 if !vy >= skip && sy + 3 <= bottom then begin
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
                   let bar_r = Rect.make ~x:body_r.x ~y:sy ~w:body_r.w ~h:3 in
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
                   ignore (Chart.draw grid ~rect:bar_r ~theme ~caps ~lang spec)
                 end;
                 vy := !vy + 4
             | None ->
                 if Option.is_some turn_entry then draw_turn_composition ()
                 else
                   put_body_line ~style:whisper_st
                     (say ~ko:"토큰·캐시 효율 스냅샷 대기 중"
                        ~en:"Awaiting token & cache breakdown snapshot"));
            (let ckpt_s =
                match Observed.to_option ctx_st.checkpoints with
                | Some inv ->
                    Printf.sprintf "ckpt:%s(%d hist)" inv.current_status
                      (List.length inv.history)
                | None -> ""
              in
              let note_s =
                match Observed.to_option ctx_st.operator_note with
                | Some n when n.pending -> "note:PENDING"
                | Some _ -> "note:consumed"
                | None -> ""
              in
              let mos_s =
                match Observed.to_option ctx_st.turn_records with
                | Some { memory_os = Some mo; _ } ->
                    Printf.sprintf "mem_os:r%d(%df)" mo.revision
                      mo.facts_current
                | Some { memory_os = None; _ } | None -> ""
              in
              let parts =
                List.filter
                  (fun s -> not (String.equal s ""))
                  [ ckpt_s; note_s; mos_s ]
              in
              if parts <> [] then
                put_body_line ~style:whisper_st (String.concat " · " parts));
            (match keeper_opt with
             | Some k ->
                 (* Cost comes from keeper-costs over its trailing window. *)
                 let cost_label =
                   match Runtime_store.keeper_costs_window_label model.runtime with
                   | Some w -> "Cost " ^ w
                   | None -> "Cost"
                 in
                 let cost = Runtime_store.keeper_cost_usd ~keeper model.runtime in
                 put_body_line ~style:struct_st
                   (Printf.sprintf "Runtime: %s · Turns: %s · %s: %s"
                      k.runtime_id
                      (Format_val.format_observed Format_val.Count
                         (Observed.map float_of_int k.total_turns)
                         ~lang)
                      cost_label
                      (Format_val.format_observed Format_val.Usd cost ~lang))
             | None -> ());
            if Option.is_some eff_row && Option.is_some turn_entry then
              draw_turn_composition ();
            (match Keeper_context_store.cache_outcome_for_selected_turn ctx_st with
             | Some reading ->
                 let diag =
                   match reading.outcome with
                   | Keeper_cache_outcome_reading.Turn_not_in_ledger ->
                       "Cache: turn not in ledger"
                   | Keeper_cache_outcome_reading.Ledger_row_unreadable e ->
                       "Cache: ledger err " ^ e
                   | Keeper_cache_outcome_reading.Not_per_request req ->
                       Printf.sprintf "Cache: session-scoped (%s)" req.runtime_id
                   | Keeper_cache_outcome_reading.First_request { earlier; _ } -> (
                       match earlier with
                       | Keeper_cache_outcome_reading.No_earlier_request
                           { horizon_s } ->
                           Printf.sprintf "Cache: cold (no prev in %.0fs)"
                             horizon_s
                       | Keeper_cache_outcome_reading.Earlier
                           { idle; prefix; _ } ->
                           let ttl_s =
                             match idle with
                             | Keeper_cache_outcome_reading.Idle
                                 {
                                   lifetime =
                                     Keeper_cache_outcome_reading.Lifetime_declared
                                       { check; _ };
                                   _;
                                 } -> (
                                 match check with
                                 | Keeper_cache_outcome_reading.Within ->
                                     "TTL Within"
                                 | Keeper_cache_outcome_reading.Outlived ->
                                     "TTL Outlived"
                                 | Keeper_cache_outcome_reading.Undecided ->
                                     "TTL Undecided")
                             | Keeper_cache_outcome_reading.Idle
                                 {
                                   lifetime =
                                     ( Keeper_cache_outcome_reading.Lifetime_unrecorded
                                     | Keeper_cache_outcome_reading.Provider_default_unknown _ );
                                   _;
                                 }
                             | Keeper_cache_outcome_reading.Start_unrecorded ->
                                 "TTL ?"
                           in
                           let pref_s =
                             match prefix with
                             | Keeper_cache_outcome_reading.Compared
                                 { system_changed; tools_changed; messages } ->
                                 let m_s =
                                   match messages with
                                   | Message_list_change.Appended { kept; added }
                                     ->
                                       Printf.sprintf "Appended(%d,+%d)" kept
                                         added
                                   | Message_list_change.Tail_removed _ ->
                                       "Tail_removed"
                                   | Message_list_change.Block_dropped _ ->
                                       "Block_dropped"
                                   | Message_list_change.Rewritten_in_place _ ->
                                       "Rewritten"
                                   | Message_list_change.Diverged_at { index; _ }
                                     ->
                                       Printf.sprintf "Diverged@%d" index
                                 in
                                 Printf.sprintf "sys=%s tools=%s %s"
                                   (if system_changed then "CHG" else "ok")
                                   (if tools_changed then "CHG" else "ok")
                                   m_s
                             | Keeper_cache_outcome_reading.Not_compared _ ->
                                 "uncompared"
                           in
                           Printf.sprintf "Cache: %s · %s" ttl_s pref_s)
                 in
                 put_body_line ~style:acc_st diag
             | None -> ());
            (match Observed.to_option ctx_st.next_request with
             | Some fc ->
                 let next_s =
                   match (fc.walk, fc.candidates) with
                   | Wire_keeper_context.Walk_order { lane_id; _ }, c :: _ ->
                       let carry =
                         match c.carried with
                         | Some cr ->
                             Printf.sprintf "carry %d/%d (%s)" cr.kept_atoms
                               c.history_atoms
                               (Format_val.format_value Format_val.Bytes
                                  (float_of_int cr.transmitted_bytes))
                         | None -> Printf.sprintf "%d atoms" c.history_atoms
                       in
                       Printf.sprintf "Next: %s -> %s · %s" lane_id c.runtime_id
                         carry
                   | Wire_keeper_context.Walk_order { lane_id; _ }, [] ->
                       Printf.sprintf "Next: %s (no candidates)" lane_id
                   | Wire_keeper_context.Walk_refused reason, _ ->
                       "Next refused: " ^ reason
                 in
                 put_body_line ~style:struct_st next_s
             | None -> ());
            incr vy;
            (* Per-turn fill from the keeper's recent turn records. *)
            (match Fleet_store.turn_records_for ~keeper model.fleet with
             | Observed.Value { data; _ } -> (
                 let fills =
                   List.map Wire_fleet.turn_record_context_fill data.rows
                 in
                 let measured = List.filter_map Fun.id fills in
                 put_body_line ~style:pri_st
                   (say
                      ~ko:
                        (Printf.sprintf "턴별 컨텍스트 · 최근 %d턴 중 측정 %d턴"
                           (List.length fills) (List.length measured))
                      ~en:
                        (Printf.sprintf
                           "Context per turn · %d of the last %d turns measured"
                           (List.length measured) (List.length fills)));
                 (match measured with
                  | [] ->
                      put_body_line ~style:whisper_st
                        (say ~ko:"측정된 턴이 없습니다"
                           ~en:"No measured turn in this window")
                  | first :: _ ->
                      let samples = context_history_samples fills in
                      let sy = screen_y_for !vy in
                      if !vy >= skip && sy < bottom then
                        ignore
                          (Chart.draw_sparkline_run ~clip:body_r grid
                             ~x:body_r.x ~y:sy
                             ~width:(Int.min body_r.w (Array.length samples))
                             ~theme ~bg ~unicode:true
                             ~gradient:Chart.Gradient.Thermal samples);
                      incr vy;
                      let latest = List.fold_left (fun _ r -> r) first measured in
                      let low = List.fold_left Float.min first measured in
                      let high = List.fold_left Float.max first measured in
                      put_body_line ~style:struct_st
                        (say
                           ~ko:
                             (Printf.sprintf "최근 %s · 최저 %s · 최고 %s"
                                (context_pct latest) (context_pct low)
                                (context_pct high))
                           ~en:
                             (Printf.sprintf "Latest %s · Low %s · High %s"
                                (context_pct latest) (context_pct low)
                                (context_pct high))));
                 if data.skipped_rows > 0 then
                   put_body_line ~style:attn_st
                     (say
                        ~ko:
                          (Printf.sprintf "읽지 못한 턴 기록 %d행"
                             data.skipped_rows)
                        ~en:
                          (Printf.sprintf "%d unreadable turn record rows"
                             data.skipped_rows)))
             | Observed.Loading _ ->
                 put_body_line ~style:whisper_st
                   (say ~ko:"턴 기록 불러오는 중…" ~en:"Loading turn records…")
             | Observed.Failed { reason; _ } ->
                 put_body_line ~style:crit_st
                   (say ~ko:("턴 기록 조회 실패: " ^ reason)
                      ~en:("Turn records fetch failed: " ^ reason))
             | Observed.Absent | Observed.Unreported ->
                 put_body_line ~style:whisper_st
                   (say ~ko:"턴 기록 대기 중" ~en:"Awaiting turn records"));
            incr vy;
            (* Latest compaction and history reset facts. *)
            (match
               Knowledge_store.memory_os_internals_for ~keeper model.knowledge
             with
             | Observed.Value { data; _ } ->
                 let compaction =
                   if data.compaction.present then
                     let covers =
                       match data.compaction.covers_through_turn with
                       | Some turn -> " → " ^ turn
                       | None -> ""
                     in
                     say
                       ~ko:
                         (Printf.sprintf "압축 %d회%s"
                            data.compaction.epoch_count covers)
                       ~en:
                         (Printf.sprintf "Compacted %d times%s"
                            data.compaction.epoch_count covers)
                   else say ~ko:"압축 없음" ~en:"Never compacted"
                 in
                 let reset_age =
                   match
                     Option.bind data.canonical_turns.latest_reset_at_unix
                       (fun at_unix ->
                         Render_util.format_relative_age
                           ~now_unix:model.freshness.last_wall_unix ~at_unix)
                   with
                   | Some age -> say ~ko:(" · 최근 " ^ age ^ " 전") ~en:(" · last " ^ age ^ " ago")
                   | None -> ""
                 in
                 put_body_line ~style:struct_st
                   (Printf.sprintf "%s%s%s" compaction Typography.sep_dot
                      (say
                         ~ko:
                           (Printf.sprintf "기록 리셋 %d회%s"
                              data.canonical_turns.history_resets_count reset_age)
                         ~en:
                           (Printf.sprintf "History resets %d%s"
                              data.canonical_turns.history_resets_count reset_age)))
             | Observed.Failed { reason; _ } ->
                 put_body_line ~style:crit_st
                   (say ~ko:("압축 기록 조회 실패: " ^ reason)
                      ~en:("Compaction facts fetch failed: " ^ reason))
             | Observed.Loading _ ->
                 put_body_line ~style:whisper_st
                   (say ~ko:"압축 기록 불러오는 중…" ~en:"Loading compaction facts…")
             | Observed.Absent | Observed.Unreported ->
                 put_body_line ~style:whisper_st
                   (say ~ko:"압축 기록 미보고" ~en:"Compaction facts unreported"))
        | Nav.Drawer_schedules ->
            let pad_right_width ~width s =
              let fitted = Grapheme.truncate_to_width ~max_width:width s in
              let dw = Grapheme.display_width fitted in
              if dw >= width then fitted
              else fitted ^ String.make (width - dw) ' '
            in
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
              let empty_st, empty_msg =
                match model.work.schedules with
                | Observed.Loading _ ->
                    ( whisper_st
                    , Say.resolve lang
                        (Say.make ~ko:"예약 일정 불러오는 중…"
                           ~en:"Loading schedules…") )
                | Observed.Failed { reason; _ } ->
                    ( crit_st
                    , Say.resolve lang
                        (Say.make
                           ~ko:("예약 일정 조회 실패: " ^ reason)
                           ~en:("Schedules fetch failed: " ^ reason)) )
                | Observed.Value _ | Observed.Absent | Observed.Unreported ->
                    ( whisper_st
                    , Say.resolve lang
                        (Say.make ~ko:"등록된 예약 일정이 없습니다."
                           ~en:"No schedules registered.") )
              in
              ignore
                (Cell_grid.put_text ~clip:body_r grid ~x:body_r.x ~y:body_r.y
                   ~style:empty_st
                   (Grapheme.truncate_to_width ~max_width:body_r.w empty_msg))
            else
              let arr = Array.of_list sorted in
              let total = Array.length arr in
              let max_skip = Int.max 0 (total - Int.max 1 body_r.h) in
              let skip =
                Int.min max_skip (Int.max 0 model.nav.queue_scroll_offset)
              in
              let max_show = Int.min body_r.h (Int.max 0 (total - skip)) in
              for i = 0 to max_show - 1 do
                let s = arr.(skip + i) in
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
                  | Wire_work.Wake_failed (Some r) ->
                      Glyph.to_utf8 Glyph.Live_failing ^ " fail: " ^ r
                  | Wire_work.Wake_failed None ->
                      Glyph.to_utf8 Glyph.Live_failing ^ " fail"
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
                  Printf.sprintf "%s %s %s %s · %s"
                    (Glyph.to_utf8 g)
                    (pad_right_width ~width:14 target)
                    (pad_right_width ~width:12 s.recurrence_summary)
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
    | Nav.Goal_drop _
    | Nav.Schedule_form
    | Nav.Connector_form
    | Nav.Repo_add_form
    | Nav.Board_comment _
    | Nav.Github_token_form _
    | Nav.Code_finder_form
    | Nav.Code_search_form
    | Nav.Keeper_control_confirm _
    | Nav.Keeper_clear_form _
    | Nav.Keeper_operator_note_form _
    | Nav.Runtime_lane_create
    | Nav.Runtime_lane_edit _
    | Nav.Runtime_lane_delete _
    | Nav.Task_create_form
    | Nav.Task_transition_form _
    | Nav.Task_link_goal _
    | Nav.Goal_upsert_form _
    | Nav.Board_delete_post _
    | Nav.Keeper_lifecycle_form _
    | Nav.Keeper_purge_confirm _
    | Nav.Addon_attach_form
    | Nav.Addon_detach_confirm _
    | Nav.Addon_invoke_action _
    | Nav.Setup_login_input_form _ ) as std ->
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
  | Form_standard (Nav.Goal_drop id) ->
      Say.resolve lang
        (Say.make ~ko:("목표 중단(Drop) · " ^ id) ~en:("Drop Goal · " ^ id))
  | Form_standard Nav.Schedule_form ->
      Say.resolve lang (Say.make ~ko:"새 일정 생성" ~en:"Create Schedule")
  | Form_standard Nav.Connector_form ->
      Say.resolve lang (Say.make ~ko:"새 커넥터 연결" ~en:"Add Connector")
  | Form_standard Nav.Repo_add_form ->
      Say.resolve lang (Say.make ~ko:"저장소 추가" ~en:"Add Repository")
  | Form_standard Nav.Board_new_post ->
      Say.resolve lang (Say.make ~ko:"보드 새 글 작성" ~en:"New Board Post")
  | Form_standard (Nav.Board_comment { post_id; parent_id }) -> (
      match parent_id with
      | Some pid ->
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "대댓글 작성 (%s)" pid)
               ~en:(Printf.sprintf "Reply to Comment (%s)" pid))
      | None ->
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "타래 댓글 작성 (%s)" post_id)
               ~en:(Printf.sprintf "Add Comment (%s)" post_id)))
  | Form_standard (Nav.Github_token_form keeper) ->
      Say.resolve lang
        (Say.make
           ~ko:("GitHub PAT 등록 (마스킹) · " ^ keeper)
           ~en:("GitHub PAT Token (Masked) · " ^ keeper))
  | Form_standard Nav.Code_finder_form ->
      Say.resolve lang (Say.make ~ko:"코드 파일 퍼지 검색" ~en:"Fuzzy File Finder")
  | Form_standard Nav.Code_search_form ->
      Say.resolve lang (Say.make ~ko:"워크스페이스 코드 검색 (rg)" ~en:"Workspace Code Search")
  | Form_standard Nav.Runtime_lane_create ->
      Say.resolve lang
        (Say.make ~ko:"새 런타임 레인 생성" ~en:"Create Runtime Lane")
  | Form_standard (Nav.Runtime_lane_edit { lane_id; exact_output; _ }) ->
      let prefix = if exact_output then "exact/" else "" in
      Say.resolve lang
        (Say.make
           ~ko:(Printf.sprintf "레인 후보 편집 · %s%s" prefix lane_id)
           ~en:(Printf.sprintf "Edit Lane Candidates · %s%s" prefix lane_id))
  | Form_standard (Nav.Runtime_lane_delete { lane_id; _ }) ->
      Say.resolve lang
        (Say.make
           ~ko:("레인 삭제 확인 · " ^ lane_id)
           ~en:("Delete Runtime Lane · " ^ lane_id))
  | Form_standard Nav.Task_create_form ->
      Say.resolve lang (Say.make ~ko:"새 작업 생성" ~en:"Create Task")
  | Form_standard (Nav.Task_transition_form { task_id }) ->
      Say.resolve lang
        (Say.make ~ko:("작업 상태 전환 · " ^ task_id)
           ~en:("Transition Task · " ^ task_id))
  | Form_standard (Nav.Task_link_goal { task_id }) ->
      Say.resolve lang
        (Say.make ~ko:("작업 → 목표 연결 · " ^ task_id)
           ~en:("Link Task to Goal · " ^ task_id))
  | Form_standard (Nav.Goal_upsert_form None) ->
      Say.resolve lang (Say.make ~ko:"새 목표 생성" ~en:"Create Goal")
  | Form_standard (Nav.Goal_upsert_form (Some goal_id)) ->
      Say.resolve lang
        (Say.make ~ko:("목표 편집 · " ^ goal_id) ~en:("Edit Goal · " ^ goal_id))
  | Form_standard (Nav.Board_delete_post { post_id; _ }) ->
      Say.resolve lang
        (Say.make ~ko:("게시글 삭제 확인 · " ^ post_id)
           ~en:("Delete Board Post · " ^ post_id))
  | Form_standard (Nav.Keeper_lifecycle_form { keeper }) ->
      Say.resolve lang
        (Say.make ~ko:("키퍼 라이프사이클 · @" ^ keeper)
           ~en:("Keeper Lifecycle · @" ^ keeper))
  | Form_standard (Nav.Keeper_purge_confirm { keeper }) ->
      Say.resolve lang
        (Say.make ~ko:("키퍼 영구 삭제 · @" ^ keeper)
           ~en:("Purge Keeper · @" ^ keeper))
  | Form_standard Nav.Addon_attach_form ->
      Say.resolve lang
        (Say.make ~ko:"레인 애드온 연결 (Attach)" ~en:"Attach Lane Addon")
  | Form_standard (Nav.Addon_detach_confirm { title; _ }) ->
      Say.resolve lang
        (Say.make ~ko:("애드온 분리 확인 · " ^ title)
           ~en:("Detach Lane Addon · " ^ title))
  | Form_standard (Nav.Addon_invoke_action { instance_id; _ }) ->
      Say.resolve lang
        (Say.make ~ko:("애드온 액션 호출 · " ^ instance_id)
           ~en:("Invoke Addon Action · " ^ instance_id))
  | Form_standard (Nav.Setup_login_input_form { login_id }) ->
      Say.resolve lang
        (Say.make ~ko:("OAuth 로그인 입력 · " ^ login_id)
           ~en:("OAuth Login Input · " ^ login_id))
  | Form_standard (Nav.Keeper_control_confirm { keeper; action }) -> (
      match action with
      | Nav.Keeper_act_shutdown ->
          Say.resolve lang
            (Say.make ~ko:("키퍼 종료 확인 · " ^ keeper)
               ~en:("Confirm Keeper Shutdown · " ^ keeper))
      | Nav.Keeper_act_reset ->
          Say.resolve lang
            (Say.make ~ko:("키퍼 리셋 확인 · " ^ keeper)
               ~en:("Confirm Keeper Reset · " ^ keeper))
      | Nav.Keeper_act_apply_purge ->
          Say.resolve lang
            (Say.make ~ko:("체크포인트 정리 적용 확인 · " ^ keeper)
               ~en:("Confirm Checkpoint Purge · " ^ keeper))
      | Nav.Keeper_act_delete_history ->
          Say.resolve lang
            (Say.make ~ko:("체크포인트 이력 삭제 확인 · " ^ keeper)
               ~en:("Confirm Checkpoint History Delete · " ^ keeper)))
  | Form_standard (Nav.Keeper_clear_form keeper) ->
      Say.resolve lang
        (Say.make ~ko:("키퍼 대화 이력 초기화 · " ^ keeper)
           ~en:("Clear Keeper History · " ^ keeper))
  | Form_standard (Nav.Keeper_operator_note_form keeper) ->
      Say.resolve lang
        (Say.make ~ko:("다음 턴 운영자 노트 · " ^ keeper)
           ~en:("Next-Turn Operator Note · " ^ keeper))

let form_of_inline_modal (modal : Model.inline_modal_state) =
  let fields =
    List.map
      (fun (f : Model.modal_form_field) ->
        let validators = if f.required then [ Form.Required ] else [] in
        let value =
          if f.secret then Form.secret_val f.value else Form.Text_val f.value
        in
        let help = Model.modal_field_help ~key:f.key in
        Form.make_field ~key:f.key ~label:f.label ?help ~validators
          ~provenance:Form.Prov_tui_pref ~reload_scope:Form.Hot_reload value)
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
  let has_focused_help =
    match List.nth_opt modal.fields modal.active_field with
    | Some f -> Option.is_some (Model.modal_field_help ~key:f.key)
    | None -> false
  in
  let w = Int.min (Int.max 0 (rect.w - 4)) 84 in
  let desired_h =
    match kind with
    | Nav.Btw_query -> (
        match model.drafts.btw with
        | Drafts.Btw_idle | Drafts.Btw_sending _ ->
            7 + if Option.is_some modal.error then 1 else 0
        | Drafts.Btw_streaming _ | Drafts.Btw_answered _ | Drafts.Btw_failed _ ->
            Int.min (Int.max 13 (rect.h * 65 / 100)) (Int.max 7 (rect.h - 4)))
    | Nav.Code_finder_form -> 14 + if has_focused_help then 1 else 0
    | Nav.Gate_reject _
    | Nav.Verification_reject _
    | Nav.Harness_overrule _
    | Nav.Task_cancel _
    | Nav.Goal_drop _
    | Nav.Schedule_form
    | Nav.Connector_form
    | Nav.Repo_add_form
    | Nav.Board_new_post
    | Nav.Board_comment _
    | Nav.Github_token_form _
    | Nav.Code_search_form
    | Nav.Keeper_control_confirm _
    | Nav.Keeper_clear_form _
    | Nav.Keeper_operator_note_form _
    | Nav.Runtime_lane_create
    | Nav.Runtime_lane_edit _
    | Nav.Runtime_lane_delete _
    | Nav.Task_create_form
    | Nav.Task_transition_form _
    | Nav.Task_link_goal _
    | Nav.Goal_upsert_form _
    | Nav.Board_delete_post _
    | Nav.Keeper_lifecycle_form _
    | Nav.Keeper_purge_confirm _
    | Nav.Addon_attach_form
    | Nav.Addon_detach_confirm _
    | Nav.Addon_invoke_action _
    | Nav.Setup_login_input_form _ ->
        Int.max 7 (List.length modal.fields + 6 + if has_focused_help then 1 else 0)
  in
  let h = Int.min (Int.max 0 (rect.h - 2)) desired_h in
  let x = rect.x + ((rect.w - w) / 2) in
  let y = Int.max rect.y (Rect.bottom rect - h - 1) in
  let modal_r = Rect.make ~x ~y ~w ~h in
  if Rect.is_empty modal_r then ()
  else
    let title = inline_action_title ~lang ~modal kind in
    let hotkey =
      match kind with
      | Nav.Btw_query -> (
          match model.drafts.btw with
          | Drafts.Btw_idle ->
              Say.resolve lang
                (Say.make ~ko:"[Enter] 질문 · [Esc] 취소"
                   ~en:"[Enter] Submit · [Esc] Cancel")
          | Drafts.Btw_sending _ ->
              Say.resolve lang (Say.make ~ko:"[Esc] 취소" ~en:"[Esc] Cancel")
          | Drafts.Btw_streaming _ ->
              Say.resolve lang
                (Say.make ~ko:"[↑↓] 스크롤 · [y] 복사 · [Esc] 닫기"
                   ~en:"[↑↓] Scroll · [y] Copy · [Esc] Close")
          | Drafts.Btw_answered _ ->
              Say.resolve lang
                (Say.make ~ko:"[↑↓] 스크롤 · [y] 복사 · [Enter/Esc] 닫기"
                   ~en:"[↑↓] Scroll · [y] Copy · [Enter/Esc] Close")
          | Drafts.Btw_failed _ ->
              Say.resolve lang
                (Say.make ~ko:"[Enter/Esc] 닫기" ~en:"[Enter/Esc] Close"))
      | Nav.Gate_reject _
      | Nav.Verification_reject _
      | Nav.Harness_overrule _
      | Nav.Task_cancel _
      | Nav.Goal_drop _
      | Nav.Schedule_form
      | Nav.Connector_form
      | Nav.Repo_add_form
      | Nav.Board_new_post
      | Nav.Board_comment _
      | Nav.Github_token_form _
      | Nav.Code_finder_form
      | Nav.Code_search_form
      | Nav.Keeper_control_confirm _
      | Nav.Keeper_clear_form _
      | Nav.Keeper_operator_note_form _
      | Nav.Runtime_lane_create
      | Nav.Runtime_lane_edit _
      | Nav.Runtime_lane_delete _
      | Nav.Task_create_form
      | Nav.Task_transition_form _
      | Nav.Task_link_goal _
      | Nav.Goal_upsert_form _
      | Nav.Board_delete_post _
      | Nav.Keeper_lifecycle_form _
      | Nav.Keeper_purge_confirm _
      | Nav.Addon_attach_form
      | Nav.Addon_detach_confirm _
      | Nav.Addon_invoke_action _
      | Nav.Setup_login_input_form _ ->
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
      let draw_btw_header ~style ~max_s header_txt =
        let scroll_badge =
          if max_s > 0 then
            let cur = Int.min max_s (Int.max 0 model.nav.btw_scroll_offset) in
            Printf.sprintf " [%d/%d]" cur max_s
          else ""
        in
        let bw = Grapheme.display_width scroll_badge in
        let hdr_w = Int.max 0 (padded.w - bw) in
        ignore
          (Cell_grid.put_text ~clip:padded grid ~x:padded.x ~y:padded.y ~style
             (Grapheme.truncate_to_width ~max_width:hdr_w header_txt));
        if bw > 0 && padded.w > bw + 4 then
          ignore
            (Cell_grid.put_text ~clip:padded grid
               ~x:(Rect.right padded - bw) ~y:padded.y
               ~style:(Typography.whisper ~bg theme) scroll_badge)
      in
      match kind with
      | Nav.Btw_query -> (
          match model.drafts.btw with
          | Drafts.Btw_idle ->
              let err_rows = if Option.is_some modal.error then 1 else 0 in
              let form_r =
                Rect.make ~x:inner.x ~y:inner.y ~w:inner.w
                  ~h:(Int.max 0 (inner.h - err_rows))
              in
              let form_st = form_of_inline_modal modal in
              ignore
                (Form.draw grid ~rect:form_r ~theme ~lang ~pad_x
                   ~elevated:true ~edit_cursor:model.nav.modal_edit_cursor
                   ~show_row_badges:false form_st);
              (match modal.error with
              | Some err when err_rows = 1 ->
                  let sy = Rect.bottom inner - 1 in
                  let sr = Rect.make ~x:padded.x ~y:sy ~w:padded.w ~h:1 in
                  ignore
                    (Cell_grid.put_text ~clip:sr grid ~x:padded.x ~y:sy
                       ~style:crit_st
                       (Grapheme.truncate_to_width ~max_width:padded.w
                          (Glyph.to_utf8 Glyph.Live_failing ^ " " ^ err)))
              | Some _ | None -> ())
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
              let max_s = Update_nav.btw_max_scroll model in
              let scroll = Int.min max_s (Int.max 0 model.nav.btw_scroll_offset) in
              draw_btw_header ~style:acc_st ~max_s
                (Printf.sprintf "%s @%s · %s"
                   (Glyph.to_utf8 Glyph.Live_working) keeper prompt);
              if padded.h >= 3 then begin
                Card.draw_hairline ~pad_x ~bg grid ~rect:inner ~y:(inner.y + 1)
                  ~theme;
                let md_r =
                  Rect.make ~x:padded.x ~y:(padded.y + 2) ~w:padded.w
                    ~h:(Int.max 0 (padded.h - 2))
                in
                ignore
                  (Markdown.draw grid ~rect:md_r ~theme ~scroll
                     ~osc8:caps.osc8_hyperlinks buffer)
              end
          | Drafts.Btw_answered { keeper; prompt; reply } ->
              let max_s = Update_nav.btw_max_scroll model in
              let scroll = Int.min max_s (Int.max 0 model.nav.btw_scroll_offset) in
              draw_btw_header ~style:ok_st ~max_s
                (Printf.sprintf "%s @%s · %s"
                   (Glyph.to_utf8 Glyph.Live_healthy) keeper prompt);
              if padded.h >= 3 then begin
                Card.draw_hairline ~pad_x ~bg grid ~rect:inner ~y:(inner.y + 1)
                  ~theme;
                let md_r =
                  Rect.make ~x:padded.x ~y:(padded.y + 2) ~w:padded.w
                    ~h:(Int.max 0 (padded.h - 2))
                in
                ignore
                  (Markdown.draw grid ~rect:md_r ~theme ~scroll
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
      | Nav.Goal_drop _
      | Nav.Schedule_form
      | Nav.Connector_form
      | Nav.Repo_add_form
      | Nav.Board_new_post
      | Nav.Board_comment _
      | Nav.Github_token_form _
      | Nav.Code_finder_form
      | Nav.Code_search_form
      | Nav.Keeper_control_confirm _
      | Nav.Keeper_clear_form _
      | Nav.Keeper_operator_note_form _
      | Nav.Runtime_lane_create
      | Nav.Runtime_lane_edit _
      | Nav.Runtime_lane_delete _
      | Nav.Task_create_form
      | Nav.Task_transition_form _
      | Nav.Task_link_goal _
      | Nav.Goal_upsert_form _
      | Nav.Board_delete_post _
      | Nav.Keeper_lifecycle_form _
      | Nav.Keeper_purge_confirm _
      | Nav.Addon_attach_form
      | Nav.Addon_detach_confirm _
      | Nav.Addon_invoke_action _
      | Nav.Setup_login_input_form _ ->
          let status_rows =
            if modal.submitting || Option.is_some modal.error then 1 else 0
          in
          let extra_rows =
            match classify_inline_form modal with
            | Form_standard Nav.Code_finder_form ->
                Int.max 0 (Int.min 7 (inner.h - status_rows - 4))
            | Form_standard
                ( Nav.Connector_form
                | Nav.Runtime_lane_create
                | Nav.Runtime_lane_edit _
                | Nav.Task_create_form
                | Nav.Task_link_goal _
                | Nav.Addon_invoke_action _ )
            | Form_fusion_launch ->
                if inner.h - status_rows >= 6 then 1 else 0
            | Form_board_goal_proposal
            | Form_goal_confirmation_proof
            | Form_memory_act
            | Form_wiki_edit
            | Form_runtime_assign
            | Form_setup_account_key
            | Form_setup_login_start
            | Form_standard
                ( Nav.Btw_query
                | Nav.Gate_reject _
                | Nav.Verification_reject _
                | Nav.Harness_overrule _
                | Nav.Task_cancel _
                | Nav.Goal_drop _
                | Nav.Schedule_form
                | Nav.Repo_add_form
                | Nav.Board_new_post
                | Nav.Board_comment _
                | Nav.Github_token_form _
                | Nav.Code_search_form
                | Nav.Keeper_control_confirm _
                | Nav.Keeper_clear_form _
                | Nav.Keeper_operator_note_form _
                | Nav.Runtime_lane_delete _
                | Nav.Task_transition_form _
                | Nav.Goal_upsert_form _
                | Nav.Board_delete_post _
                | Nav.Keeper_lifecycle_form _
                | Nav.Keeper_purge_confirm _
                | Nav.Addon_attach_form
                | Nav.Addon_detach_confirm _
                | Nav.Setup_login_input_form _ ) ->
                0
          in
          let form_r =
            Rect.make ~x:inner.x ~y:inner.y ~w:inner.w
              ~h:(Int.max 0 (inner.h - status_rows - extra_rows))
          in
          let form_st = form_of_inline_modal modal in
          ignore
            (Form.draw grid ~rect:form_r ~theme ~lang ~pad_x ~elevated:true
               ~edit_cursor:model.nav.modal_edit_cursor
               ~show_row_badges:false form_st);
          if extra_rows > 0 then begin
            let ey = Rect.bottom form_r in
            let er =
              Rect.make ~x:padded.x ~y:ey ~w:padded.w ~h:extra_rows
            in
            let whisper_st = Typography.whisper ~bg theme in
            match classify_inline_form modal with
            | Form_standard Nav.Code_finder_form ->
                let q = Model.modal_field_value ~key:"query" modal in
                let matches = Update_nav.code_fuzzy_matches ~query:q model in
                if matches = [] then
                  ignore
                    (Cell_grid.put_text ~clip:er grid ~x:er.x ~y:er.y
                       ~style:whisper_st
                       (Grapheme.truncate_to_width ~max_width:er.w
                          (Say.resolve lang
                             (Say.make ~ko:"일치하는 파일 없음 (직접 경로 입력 후 Enter)"
                                ~en:"No matching files (type path + Enter)"))))
                else
                  List.iteri
                    (fun idx path ->
                      if idx < extra_rows then
                        let st = if idx = 0 then acc_st else Typography.primary ~bg theme in
                        let prefix = if idx = 0 then "▸ " else "  " in
                        ignore
                          (Cell_grid.put_text ~clip:er grid ~x:er.x
                             ~y:(er.y + idx) ~style:st
                             (Grapheme.truncate_to_width ~max_width:er.w
                                (prefix ^ path))))
                    matches
            | Form_standard Nav.Connector_form ->
                let cid = Model.modal_field_value ~key:"connector" modal in
                let names =
                  Runtime_store.connector_channel_names ~connector_id:cid
                    model.runtime
                in
                let hint =
                  if names = [] then
                    Say.resolve lang
                      (Say.make ~ko:"[←→] 커넥터/채널 순환"
                         ~en:"[←→] Cycle connector/channel")
                  else
                    let sample =
                      names
                      |> List.filteri (fun i _ -> i < 4)
                      |> List.map (fun (m : Wire_runtime.connector_name_mapping) ->
                             Printf.sprintf "%s(%s)" m.name m.id)
                      |> String.concat ", "
                    in
                    "[←→] Channels: " ^ sample
                in
                ignore
                  (Cell_grid.put_text ~clip:er grid ~x:er.x ~y:er.y
                     ~style:whisper_st
                     (Grapheme.truncate_to_width ~max_width:er.w hint))
            | Form_fusion_launch ->
                let hint =
                  if model.runtime.fusion_config_auth_denied then
                    Say.resolve lang
                      (Say.make ~ko:"프리셋 목록은 CanAdmin 권한 필요 (직접 입력 가능)"
                         ~en:"Presets require CanAdmin (manual preset entry supported)")
                  else
                    match Observed.to_option model.runtime.fusion_config with
                    | Some cfg when cfg.presets <> [] ->
                        let names =
                          cfg.presets
                          |> List.map (fun (p : Wire_runtime.fusion_preset_option) ->
                                 p.name)
                          |> String.concat ", "
                        in
                        "[←→] Presets: " ^ names
                    | Some _ | None -> "[←→] Presets (loading...)"
                in
                ignore
                  (Cell_grid.put_text ~clip:er grid ~x:er.x ~y:er.y
                     ~style:whisper_st
                     (Grapheme.truncate_to_width ~max_width:er.w hint))
            | Form_standard (Nav.Runtime_lane_create | Nav.Runtime_lane_edit _) ->
                let rts = Runtime_store.runtime_options model.runtime in
                let hint =
                  if rts = [] then
                    Say.resolve lang
                      (Say.make ~ko:"가용 런타임 목록 로딩 중..."
                         ~en:"Available runtimes loading...")
                  else
                    let sample =
                      rts
                      |> List.filteri (fun i _ -> i < 5)
                      |> List.map (fun (r : Wire_runtime.runtime_option) -> r.id)
                      |> String.concat ", "
                    in
                    "Runtimes: " ^ sample
                in
                ignore
                  (Cell_grid.put_text ~clip:er grid ~x:er.x ~y:er.y
                     ~style:whisper_st
                     (Grapheme.truncate_to_width ~max_width:er.w hint))
            | Form_standard (Nav.Task_create_form | Nav.Task_link_goal _) ->
                let goals = Work_store.goals model.work in
                let hint =
                  match goals with
                  | [] ->
                      Say.resolve lang
                        (Say.make ~ko:"로드된 목표 없음"
                           ~en:"No goals loaded")
                  | _ ->
                      let sample =
                        goals
                        |> List.filteri (fun i _ -> i < 4)
                        |> List.map (fun (g : Wire_work.goal) -> g.id)
                        |> String.concat ", "
                      in
                      "Goals: " ^ sample
                in
                ignore
                  (Cell_grid.put_text ~clip:er grid ~x:er.x ~y:er.y
                     ~style:whisper_st
                     (Grapheme.truncate_to_width ~max_width:er.w hint))
            | Form_standard (Nav.Addon_invoke_action { action_names; _ }) ->
                let hint =
                  match action_names with
                  | [] ->
                      Say.resolve lang
                        (Say.make ~ko:"선언된 액션 목록 없음 (직접 입력)"
                           ~en:"No declared action_names (enter action name manually)")
                  | xs -> "[←→] Actions: " ^ String.concat ", " xs
                in
                ignore
                  (Cell_grid.put_text ~clip:er grid ~x:er.x ~y:er.y
                     ~style:whisper_st
                     (Grapheme.truncate_to_width ~max_width:er.w hint))
            | Form_board_goal_proposal
            | Form_goal_confirmation_proof
            | Form_memory_act
            | Form_wiki_edit
            | Form_runtime_assign
            | Form_setup_account_key
            | Form_setup_login_start
            | Form_standard
                ( Nav.Btw_query
                | Nav.Gate_reject _
                | Nav.Verification_reject _
                | Nav.Harness_overrule _
                | Nav.Task_cancel _
                | Nav.Goal_drop _
                | Nav.Schedule_form
                | Nav.Repo_add_form
                | Nav.Board_new_post
                | Nav.Board_comment _
                | Nav.Github_token_form _
                | Nav.Code_search_form
                | Nav.Keeper_control_confirm _
                | Nav.Keeper_clear_form _
                | Nav.Keeper_operator_note_form _
                | Nav.Runtime_lane_delete _
                | Nav.Task_transition_form _
                | Nav.Goal_upsert_form _
                | Nav.Board_delete_post _
                | Nav.Keeper_lifecycle_form _
                | Nav.Keeper_purge_confirm _
                | Nav.Addon_attach_form
                | Nav.Addon_detach_confirm _
                | Nav.Setup_login_input_form _ ) ->
                ()
          end;
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

type help_line =
  | Help_header of string
  | Help_entry of Keymap.help_entry
  | Help_blank

let render_help_column grid ~(rect : Rect.t) ~(theme : Theme.t) ?(scroll = 0)
    (groups : Keymap.help_group list) =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_2 in
    let keycap_bg = Color.of_rgb theme.surface_1 in
    let key_st = Typography.anchor ~bg:keycap_bg theme in
    let desc_st = Typography.primary ~bg theme in
    let whisper_st = Typography.whisper ~bg theme in
    let lines =
      List.concat_map
        (fun (grp : Keymap.help_group) ->
          (Help_header grp.title
           :: List.map (fun e -> Help_entry e) grp.entries)
          @ [ Help_blank ])
        groups
    in
    let arr = Array.of_list lines in
    let total = Array.length arr in
    let max_scroll = Int.max 0 (total - rect.h) in
    let start = Int.max 0 (Int.min max_scroll scroll) in
    for i = 0 to rect.h - 1 do
      let idx = start + i in
      if idx < total then
        let py = rect.y + i in
        match arr.(idx) with
        | Help_blank -> ()
        | Help_header title ->
            Card.draw_hairline ~pad_x:0 ~label:title ~bg grid ~rect ~y:py ~theme
        | Help_entry e ->
            let rr = Rect.make ~x:rect.x ~y:py ~w:rect.w ~h:1 in
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
              (Cell_grid.put_text ~clip:rr grid ~x:(rect.x + 1) ~y:py
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
                (Cell_grid.put_text ~clip:rr grid ~x:dx ~y:py ~style:desc_st
                   (Grapheme.truncate_to_width ~max_width:dw e.desc));
            if slash_w > 0 && sx > dx + 8 then
              ignore
                (Cell_grid.put_text ~clip:rr grid ~x:sx ~y:py ~style:whisper_st
                   slash_s)
    done

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
                      (Say.make ~ko:"선택 이동 · 좌/우 패인 이동 (g/G)"
                         ~en:"Move / spatial pane switch (g/G)");
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
                  keys = [ "a..d" ];
                  desc =
                    Say.resolve lang
                      (Say.make ~ko:"Ask 선택지 빠른 응답 (단일 1문항)"
                         ~en:"Quick Ask choice (single-question)");
                  slash_twin = None;
                }
            end
        | Keymap.Submit_steer ->
            Some
              {
                e with
                keys = [ "Alt+↵"; "Ctrl+↵" ];
                desc =
                  Say.resolve lang
                    (Say.make ~ko:"내 요청을 끊고 Steer"
                       ~en:"Steer: cut your own running request");
              }
        | Keymap.Composer_newline ->
            Some
              {
                e with
                keys = [ "S-Enter"; "Ctrl+J" ];
                desc =
                  Say.resolve lang
                    (Say.make ~ko:"줄바꿈 삽입" ~en:"Insert newline");
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
                    (Say.make ~ko:"대기 승인 거절 / 질문 건너뛰기"
                       ~en:"Deny top approval / skip Ask");
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
        | Keymap.Toggle_sidebar
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
        | Keymap.Submit_followup
        | Keymap.Toggle_expand
        | Keymap.Create_new
        | Keymap.Refresh
        | Keymap.Toggle_zoom
        | Keymap.Cycle_memory_view
        | Keymap.Toggle_memory_sort
        | Keymap.Cycle_signal_or_source
        | Keymap.Cycle_sort_or_speak
        | Keymap.Cycle_hearth_or_overrule
        | Keymap.Cycle_time_window
        | Keymap.Cycle_view_mode
        | Keymap.Context_primary_action
        | Keymap.Toggle_artifact_share
        | Keymap.Step_revision _
        | Keymap.Step_context_item _
        | Keymap.Launch_fusion
        | Keymap.Toggle_unreported
        | Keymap.Unbind_connector
        | Keymap.Entity_approve_or_assign
        | Keymap.Entity_reject_or_cancel
        | Keymap.Edit_or_export
        | Keymap.Configure_provider_key
        | Keymap.Account_login
        | Keymap.Poll_account_login
        | Keymap.Copy_hash
        | Keymap.Dismiss_errors
        | Keymap.Board_vote _
        | Keymap.Toggle_memory_scope
        | Keymap.Copy_public_url
        | Keymap.Probe_sandbox
        | Keymap.Refresh_browser_tabs
        | Keymap.Open_memory_recovery
        | Keymap.Search_prev_match
        | Keymap.Toggle_memory_chart
        | Keymap.Open_external_editor
        | Keymap.Interrupt_turn
        | Keymap.Delete_selected
        | Keymap.Link_task_goal
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
                 (Say.make ~ko:"[↑↓] 스크롤 · [Esc / ?] 닫기"
                    ~en:"[↑↓] Scroll · [Esc / ?] Close"));
          focused = true;
          elevated = true;
        }
    in
    let pad_x = if inner.w >= 72 then 2 else 1 in
    let content0 = Card.pad_inner ~pad_x inner in
    if not (Rect.is_empty content0) then begin
      let tui_lbl = Model.tui_build_label model in
      let server_lbl = Model.server_build_label model in
      let has_build_bar =
        ((not (String.equal tui_lbl "")) || Option.is_some server_lbl)
        && content0.h >= 4
      in
      let content =
        if not has_build_bar then content0
        else begin
          let bg = Color.of_rgb theme.surface_2 in
          let bar_r =
            Rect.make ~x:content0.x ~y:content0.y ~w:content0.w ~h:1
          in
          let right_edge = Rect.right bar_r in
          let struct_st = Typography.structure ~bg theme in
          let primary_st = Typography.primary ~bg theme in
          let whisper_st = Typography.whisper ~bg theme in
          let mismatch = Model.build_commit_mismatch model in
          let attn_st =
            Typography.status ~bg ~bold:true theme Theme.Status_attention
          in
          let cx = ref bar_r.x in
          let put_seg st txt =
            let rem = right_edge - !cx in
            if rem > 0 then begin
              let fitted = Grapheme.truncate_to_width ~max_width:rem txt in
              let adv =
                Cell_grid.put_text ~clip:bar_r grid ~x:!cx ~y:bar_r.y ~style:st
                  fitted
              in
              cx := !cx + adv
            end
          in
          if not (String.equal tui_lbl "") then begin
            put_seg struct_st "TUI ";
            put_seg primary_st tui_lbl
          end;
          (match server_lbl with
           | None -> ()
           | Some srv ->
               if not (String.equal tui_lbl "") then
                 put_seg whisper_st
                   (" " ^ Glyph.to_utf8 Glyph.Separator_dot ^ " ");
               put_seg struct_st "Server ";
               put_seg (if mismatch then attn_st else primary_st) srv);
          if mismatch then begin
            let full_tag =
              Printf.sprintf "%s %s"
                (Glyph.to_utf8 Glyph.Warning_triangle)
                (Say.resolve lang
                   (Say.make ~ko:"커밋 불일치" ~en:"commit mismatch"))
            in
            let full_w = Grapheme.display_width full_tag in
            if !cx + 2 + full_w <= right_edge then
              ignore
                (Cell_grid.put_text ~clip:bar_r grid ~x:(right_edge - full_w)
                   ~y:bar_r.y ~style:attn_st full_tag)
            else if !cx + 2 <= right_edge then
              put_seg attn_st (" " ^ Glyph.to_utf8 Glyph.Warning_triangle)
          end;
          let header_h =
            if content0.h >= 6 then begin
              Card.draw_hairline ~pad_x ~bg grid ~rect:inner
                ~y:(content0.y + 1) ~theme;
              2
            end
            else 1
          in
          Rect.make ~x:content0.x ~y:(content0.y + header_h) ~w:content0.w
            ~h:(Int.max 0 (content0.h - header_h))
        end
      in
      let scroll = model.nav.help_scroll_offset in
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
            render_help_column grid ~rect:l_r ~theme ~scroll left_groups;
            Card.draw_v_hairline ~bg:(Color.of_rgb theme.surface_2) grid
              ~x:(Rect.right l_r + 1) ~y:content.y ~h:content.h ~theme;
            render_help_column grid ~rect:r_r ~theme ~scroll right_groups
        | _ -> ()
      else
        let prioritized = right_groups @ left_groups in
        render_help_column grid ~rect:content ~theme ~scroll prioritized
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
        let sel_art = Model.focused_artifact model in
        let fmt_tok, ext_tok =
          match sel_art with
          | Some a -> (
              match Wire_knowledge.artifact_format_of_entry a with
              | `Html -> ("HTML", ".html")
              | `Markdown -> ("MD", ".md"))
          | None -> ("MD", ".md")
        in
        let view_mode_lbl =
          match model.knowledge.artifact_view_mode with
          | `Document -> Say.resolve lang (Say.make ~ko:"문서" ~en:"Doc")
          | `Raw_source -> Say.resolve lang (Say.make ~ko:"원본" ~en:"Raw")
        in
        let inner =
          Card.draw ~cache grid ~rect:modal_r ~theme
            {
              (Card.default_spec ~title) with
              badge =
                Some
                  {
                    glyph = None;
                    text = Printf.sprintf "%s · %s" fmt_tok view_mode_lbl;
                    tone = Some Theme.Status_active;
                  };
              hotkey =
                Some
                  (Say.resolve lang
                     (Say.make
                        ~ko:
                          (Printf.sprintf
                             "[v] 문서/원본 · [r] 재조회 · [y] %s 복사 · [e] %s 저장 · [o] 열기 · [H] SHA · [Esc]"
                             fmt_tok ext_tok)
                        ~en:
                          (Printf.sprintf
                             "[v] Doc/Raw · [r] Retry · [y] Copy %s · [e] Export %s · [o] Open · [H] SHA · [Esc]"
                             fmt_tok ext_tok)));
              focused = true;
              elevated = true;
            }
        in
        let pad_x = if inner.w >= 48 then 2 else 1 in
        let content = Card.pad_inner ~pad_x inner in
        if not (Rect.is_empty content) then begin
          match sel_art with
          | None ->
              draw_lines inner ~rail_tone:(Some Theme.Status_active)
                [
                  ( whisper_st,
                    Say.resolve lang
                      (Say.make ~ko:"선택된 미디어 또는 아티팩트가 없습니다."
                         ~en:"No media or artifact selected.") );
                  ( pri_st,
                    Say.resolve lang
                      (Say.make ~ko:"[Esc] 돌아가기" ~en:"[Esc] Return") );
                ]
          | Some art ->
              let detail_opt =
                Knowledge_store.artifact_detail_for_entry art model.knowledge
              in
              let raw_body =
                match detail_opt with Some d -> d.content | None -> ""
              in
              let body_h_est = Int.max 0 (content.h - 3) in
              let total_lines_est =
                if String.equal (String.trim raw_body) "" then 0
                else
                  match
                    ( model.knowledge.artifact_view_mode
                    , Wire_knowledge.artifact_format_of_entry art )
                  with
                  | `Document, `Html ->
                      List.length
                        (Html_doc.render_lines ~theme ~width:content.w ~lang
                           raw_body)
                  | `Document, `Markdown ->
                      if Knowledge_store.is_json_artifact art then
                        let pretty =
                          match Yojson.Safe.from_string raw_body with
                          | j -> Yojson.Safe.pretty_to_string j
                          | exception Yojson.Json_error _ -> raw_body
                        in
                        List.length (String.split_on_char '\n' pretty)
                      else
                        List.length
                          (Markdown.render_lines ~theme ~width:content.w
                             raw_body)
                  | `Raw_source, (`Html | `Markdown) ->
                      List.length (String.split_on_char '\n' raw_body)
              in
              let scroll_suffix =
                if total_lines_est > body_h_est && body_h_est > 0 then
                  let max_s = Int.max 0 (total_lines_est - body_h_est) in
                  let cur_line =
                    1 + Int.min max_s (Int.max 0 model.knowledge.detail_scroll_offset)
                  in
                  Printf.sprintf " · [%d/%d]" cur_line total_lines_est
                else ""
              in
              let y = ref content.y and bot = Rect.bottom content in
              let put_hdr st txt =
                if !y < bot then begin
                  let rr = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:1 in
                  ignore
                    (Cell_grid.put_text ~clip:rr grid ~x:content.x ~y:!y
                       ~style:st
                       (Grapheme.truncate_to_width ~max_width:content.w txt));
                  incr y
                end
              in
              put_hdr anchor_st art.title;
              put_hdr struct_st
                (Printf.sprintf "ID: %s · r%d · %s · %s · SHA: %s%s" art.id
                   art.revision art.body.mime
                   (Format_val.format_value Format_val.Bytes
                      (float_of_int art.body.bytes))
                   (Grapheme.truncate_to_width ~max_width:14 art.body.sha256)
                   scroll_suffix);
              if !y < bot then begin
                Card.draw_hairline ~pad_x:0 ~bg grid ~rect:content ~y:!y ~theme;
                incr y
              end;
              let body_r =
                Rect.make ~x:content.x ~y:!y ~w:content.w
                  ~h:(Int.max 0 (bot - !y))
              in
              if not (Rect.is_empty body_r) then begin
                if String.equal (String.trim raw_body) "" then
                  match
                    Knowledge_store.artifact_detail_failure_for_entry art
                      model.knowledge
                  with
                  | Some reason ->
                      ignore
                        (Cell_grid.put_text ~clip:body_r grid ~x:body_r.x
                           ~y:body_r.y ~style:acc_st
                           (Say.resolve lang
                              (Say.make
                                 ~ko:
                                   (Printf.sprintf "본문 조회 실패: %s · [r] 재시도"
                                      reason)
                                 ~en:
                                   (Printf.sprintf
                                      "Body fetch failed: %s · [r] retry" reason))))
                  | None ->
                      ignore
                        (Cell_grid.put_text ~clip:body_r grid ~x:body_r.x
                           ~y:body_r.y ~style:whisper_st
                           (Say.resolve lang
                              (Say.make ~ko:"본문 불러오는 중 또는 미리보기 없음"
                                 ~en:"Loading body or no inline preview")))
                else
                  let scroll = Int.max 0 model.knowledge.detail_scroll_offset in
                  match
                    ( model.knowledge.artifact_view_mode
                    , Wire_knowledge.artifact_format_of_entry art )
                  with
                  | `Document, `Html ->
                      ignore
                        (Html_doc.draw grid ~rect:body_r ~theme ~lang ~scroll
                           raw_body)
                  | `Document, `Markdown ->
                      let is_json = Knowledge_store.is_json_artifact art in
                      if is_json then begin
                        let pretty =
                          match Yojson.Safe.from_string raw_body with
                          | j -> Yojson.Safe.pretty_to_string j
                          | exception Yojson.Json_error _ -> raw_body
                        in
                        let lines = String.split_on_char '\n' pretty in
                        let max_s =
                          Int.max 0 (List.length lines - Int.max 1 body_r.h)
                        in
                        let skip = Int.min max_s scroll in
                        let by = ref body_r.y in
                        List.iter
                          (fun ln ->
                            if !by < Rect.bottom body_r then begin
                              let rr =
                                Rect.make ~x:body_r.x ~y:!by ~w:body_r.w ~h:1
                              in
                              ignore
                                (Cell_grid.put_text ~clip:rr grid ~x:body_r.x
                                   ~y:!by ~style:pri_st
                                   (Grapheme.truncate_to_width
                                      ~max_width:body_r.w ln));
                              incr by
                            end)
                          (Store_scroll.drop skip lines)
                      end
                      else
                        ignore
                          (Markdown.draw grid ~rect:body_r ~theme
                             ~osc8:caps.osc8_hyperlinks ~scroll raw_body)
                  | `Raw_source, _ ->
                      let lines = String.split_on_char '\n' raw_body in
                      let max_s =
                        Int.max 0 (List.length lines - Int.max 1 body_r.h)
                      in
                      let skip = Int.min max_s scroll in
                      let by = ref body_r.y in
                      List.iter
                        (fun ln ->
                          if !by < Rect.bottom body_r then begin
                            let rr =
                              Rect.make ~x:body_r.x ~y:!by ~w:body_r.w ~h:1
                            in
                            ignore
                              (Cell_grid.put_text ~clip:rr grid ~x:body_r.x
                                 ~y:!by ~style:pri_st
                                 (Grapheme.truncate_to_width ~max_width:body_r.w
                                    ln));
                            incr by
                          end)
                        (Store_scroll.drop skip lines)
              end
        end
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

(* ---------- Dedicated Question/Ask Answer Modal ---------- *)

let ask_modal_rect ~(rect : Rect.t) =
  let max_w = Int.max 0 (rect.w - 2) in
  let max_h = Int.max 0 (rect.h - 2) in
  let desired_w = Int.max 66 (rect.w * 3 / 4) in
  let w = Int.min max_w (Int.min 96 desired_w) in
  let desired_h = Int.max 16 (rect.h - 4) in
  let h = Int.min max_h (Int.min 32 desired_h) in
  center_rect ~outer:rect ~w ~h

let split_graphemes_for_caret ~max_w ~cursor text =
  let norm_text, clusters = Grapheme.segment text in
  let len = String.length norm_text in
  let target = Int.max 0 (Int.min len cursor) in
  let snap =
    List.fold_left
      (fun best (c : Grapheme.cluster) ->
        if c.end_offset <= target then c.end_offset else best)
      0 clusters
  in
  let before_clusters =
    List.filter (fun (c : Grapheme.cluster) -> c.end_offset <= snap) clusters
  in
  let full_before = String.sub norm_text 0 snap in
  let full_after = String.sub norm_text snap (len - snap) in
  if max_w <= 1 then ("", "")
  else
    let caret_budget = Int.max 0 (max_w - 1) in
    let w_before = Grapheme.display_width full_before in
    let w_after = Grapheme.display_width full_after in
    if w_before + w_after <= caret_budget then (full_before, full_after)
    else
      (* Keep cursor visible inside viewport width *)
      let max_before =
        Int.min w_before (Int.max 0 (caret_budget - Int.min 6 w_after))
      in
      let before_arr = Array.of_list before_clusters in
      let start_off = ref snap in
      let bw = ref 0 in
      let i = ref (Array.length before_arr - 1) in
      while !i >= 0 do
        let c = before_arr.(!i) in
        if !bw + c.cell_width <= max_before then begin
          start_off := c.start_offset;
          bw := !bw + c.cell_width;
          decr i
        end
        else i := -1
      done;
      let vis_before = String.sub norm_text !start_off (snap - !start_off) in
      let rem_after = Int.max 0 (caret_budget - !bw) in
      let vis_after =
        Grapheme.truncate_to_width ~ellipsis:"" ~max_width:rem_after full_after
      in
      (vis_before, vis_after)

let render_ask_answer_modal grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) =
  match model.ask_modal with
  | None -> ()
  | Some modal ->
      let modal_r = ask_modal_rect ~rect in
      if Rect.is_empty modal_r then ()
      else
        let lang = model.lang in
        let q_count = List.length modal.ask.questions in
        let live_status = Model.ask_live_status model modal.ask.ask_id in
        let all_done = Model.ask_modal_all_answered modal in
        let title =
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "@%s · 질문 답변" modal.ask.keeper)
               ~en:(Printf.sprintf "@%s · Answer Ask" modal.ask.keeper))
        in
        let is_sending =
          modal.submitting
          || Model.equal_ask_live_status live_status Model.Ask_live_in_flight
        in
        let badge_tone =
          match live_status with
          | Model.Ask_live_closed -> Theme.Status_critical
          | Model.Ask_live_in_flight -> Theme.Status_attention
          | Model.Ask_live_open ->
              if modal.submitting then Theme.Status_attention
              else if Option.is_some modal.error then Theme.Status_critical
              else if all_done then Theme.Status_ok
              else Theme.Status_attention
        in
        let badge_text =
          Printf.sprintf "Q %d/%d"
            (Int.min (Int.max 1 q_count) (modal.question_idx + 1))
            (Int.max 1 q_count)
        in
        let hotkey =
          match live_status with
          | Model.Ask_live_closed ->
              Say.resolve lang
                (Say.make ~ko:"[C] 채팅 · [Esc] 닫기"
                   ~en:"[C] Chat · [Esc] Close")
          | Model.Ask_live_in_flight ->
              Say.resolve lang
                (Say.make ~ko:"전송 중 · [Esc] 닫기"
                   ~en:"Sending · [Esc] Close")
          | Model.Ask_live_open when modal.submitting ->
              Say.resolve lang
                (Say.make ~ko:"전송 중 · [Esc] 닫기"
                   ~en:"Sending · [Esc] Close")
          | Model.Ask_live_open when modal.editing_free_text ->
              Say.resolve lang
                (Say.make ~ko:"[Enter] 확정 · [Esc] 선택으로"
                   ~en:"[Enter] Confirm · [Esc] Back")
          | Model.Ask_live_open ->
              Say.resolve lang
                (Say.make ~ko:"[Enter] 확인/제출 · [C] 채팅 · [Esc] 닫기"
                   ~en:"[Enter] Confirm/Submit · [C] Chat · [Esc] Close")
        in
        let inner =
          Card.draw ~cache grid ~rect:modal_r ~theme
            {
              (Card.default_spec ~title) with
              badge =
                Some
                  {
                    Card.glyph = Some Glyph.Action_required;
                    text = badge_text;
                    tone = Some badge_tone;
                  };
              hotkey = Some hotkey;
              focused = true;
              elevated = true;
            }
        in
        if not (Rect.is_empty inner) then begin
          let pad_x = if inner.w >= 48 then 2 else 1 in
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
          let content_w = Int.max 0 (inner.w - (2 * pad_x)) in
          let x0 = inner.x + pad_x in
          let y = ref inner.y in
          let bot = Rect.bottom inner in
          (* 1. Honest Live Status / Submitting / Error Banner *)
          let draw_banner ~tone msg =
            if !y < bot then begin
              let br = Rect.make ~x:inner.x ~y:!y ~w:inner.w ~h:1 in
              let b_bg = Color.of_rgb theme.surface_1 in
              Cell_grid.fill_rect ~clip:br grid ~rect:br
                ~style:(Typography.primary ~bg:b_bg theme) ();
              ignore
                (Cell_grid.put_text ~clip:br grid ~x:x0 ~y:!y
                   ~style:(Typography.status ~bg:b_bg ~bold:true theme tone)
                   (Grapheme.truncate_to_width ~max_width:content_w msg));
              incr y
            end
          in
          (match live_status with
          | Model.Ask_live_closed ->
              draw_banner ~tone:Theme.Status_critical
                (Say.resolve lang
                   (Say.make
                      ~ko:"⊘ 이미 응답되었거나 철회된 질문입니다 — 제출 비활성화"
                      ~en:"⊘ This Ask was already answered or withdrawn — submission disabled"))
          | Model.Ask_live_in_flight ->
              draw_banner ~tone:Theme.Status_attention
                (Say.resolve lang
                   (Say.make ~ko:"… 응답 전송 중입니다..."
                      ~en:"… Submission in flight..."))
          | Model.Ask_live_open when modal.submitting ->
              draw_banner ~tone:Theme.Status_attention
                (Say.resolve lang
                   (Say.make ~ko:"… 응답 전송 중입니다..."
                      ~en:"… Submission in flight..."))
          | Model.Ask_live_open -> (
              match modal.error with
              | Some err ->
                  draw_banner ~tone:Theme.Status_critical
                    (Printf.sprintf "✕ %s" (Say.resolve lang err))
              | None -> ()));
          (* 2. Question Progress Chips Row *)
          if q_count > 0 && !y < bot then begin
            let chip_r = Rect.make ~x:x0 ~y:!y ~w:content_w ~h:1 in
            let cx = ref x0 in
            List.iteri
              (fun idx (qi : Wire_work.ask_question) ->
                if !cx < x0 + content_w then begin
                  let is_act = Int.equal idx modal.question_idx in
                  let mark, mark_st =
                    match Model.ask_question_response modal qi with
                    | Some Wire_work.Ask_skipped -> ("⊘", whisper_st)
                    | Some (Wire_work.Ask_chose _ | Wire_work.Ask_wrote _) ->
                        ("✓", ok_st)
                    | None -> ("○", attn_st)
                  in
                  let lbl = Printf.sprintf "Q%d %s" (idx + 1) mark in
                  if is_act then begin
                    let a0 =
                      Cell_grid.put_text ~clip:chip_r grid ~x:!cx ~y:!y
                        ~style:acc_st (Glyph.to_utf8 Glyph.Left_rail ^ " ")
                    in
                    cx := !cx + a0;
                    let a1 =
                      Cell_grid.put_text ~clip:chip_r grid ~x:!cx ~y:!y
                        ~style:(Typography.anchor ~bg ~underline:true theme) lbl
                    in
                    cx := !cx + a1 + 2
                  end
                  else begin
                    let a =
                      Cell_grid.put_text ~clip:chip_r grid ~x:!cx ~y:!y
                        ~style:mark_st lbl
                    in
                    cx := !cx + a + 2
                  end
                end)
              modal.ask.questions;
            if q_count > 1 then begin
              let nav_hint =
                Say.resolve lang
                  (Say.make ~ko:"[[ ]/Tab] 질문 전환" ~en:"[[ ]/Tab] Questions")
              in
              let hw = Grapheme.display_width nav_hint in
              let hx = x0 + content_w - hw in
              if hx > !cx then
                ignore
                  (Cell_grid.put_text ~clip:chip_r grid ~x:hx ~y:!y
                     ~style:whisper_st nav_hint)
            end;
            incr y;
            if !y < bot then begin
              Card.draw_hairline ~pad_x ~bg grid ~rect:inner ~y:!y ~theme;
              incr y
            end
          end;
          (* 3. Active Question Prompt + Interactive Rows + Footer *)
          match Model.ask_modal_current_question modal with
          | None ->
              if !y < bot then
                ignore
                  (Cell_grid.put_text ~clip:inner grid ~x:x0 ~y:!y
                     ~style:crit_st
                     (Grapheme.truncate_to_width ~max_width:content_w
                        (Say.resolve lang
                           (Say.make ~ko:"표시할 질문이 없습니다."
                              ~en:"No questions available in this Ask."))))
          | Some q ->
              let draft = Model.ask_question_draft_for modal q in
              let rows = Model.ask_modal_rows q in
              let total_rows = List.length rows in
              let footer_h = if bot - !y >= 5 then 1 else 0 in
              let body_bot = Int.max !y (bot - footer_h) in
              let body_h = Int.max 0 (body_bot - !y) in
              let sep_h = if body_h >= 6 then 1 else 0 in
              let avail_h = Int.max 0 (body_h - sep_h) in
              let min_rows_h =
                Int.min (Int.max 2 total_rows) (Int.max 2 ((avail_h + 1) / 2))
              in
              let md_h =
                if avail_h <= min_rows_h then 0
                else Int.min (avail_h - min_rows_h) (Int.max 2 (avail_h / 3))
              in
              let prompt_overflow = ref None in
              if md_h > 0 then begin
                let prompt_md =
                  Model.ask_modal_prompt_markdown ~compact:(md_h <= 4)
                    modal.ask q
                in
                let total_md_lines =
                  List.length
                    (Markdown.render_lines ~theme ~width:content_w
                       ~osc8:caps.osc8_hyperlinks prompt_md)
                in
                let md_max_scroll = Int.max 0 (total_md_lines - md_h) in
                let eff_scroll =
                  Int.max 0 (Int.min md_max_scroll modal.prompt_scroll)
                in
                if total_md_lines > md_h then
                  prompt_overflow := Some (eff_scroll + 1, md_max_scroll + 1);
                let md_r = Rect.make ~x:x0 ~y:!y ~w:content_w ~h:md_h in
                ignore
                  (Markdown.draw grid ~rect:md_r ~theme
                     ~osc8:caps.osc8_hyperlinks ~scroll:eff_scroll prompt_md);
                y := !y + md_h
              end;
              if sep_h > 0 && !y < body_bot then begin
                let base_lbl =
                  match q.mode with
                  | Wire_work.Ask_single ->
                      Say.resolve lang
                        (Say.make ~ko:"선택지 (단일 선택)"
                           ~en:"Choices (single-select)")
                  | Wire_work.Ask_multi ->
                      Say.resolve lang
                        (Say.make ~ko:"선택지 (다중 선택 · Space 토글)"
                           ~en:"Choices (multi-select · Space toggle)")
                in
                let mode_lbl =
                  match !prompt_overflow with
                  | Some (cur_p, tot_p) ->
                      Printf.sprintf "%s · %s %d/%d [J/K]" base_lbl
                        (Say.resolve lang (Say.make ~ko:"본문" ~en:"Prompt"))
                        cur_p tot_p
                  | None -> base_lbl
                in
                Card.draw_hairline ~pad_x ~bg ~label:mode_lbl grid ~rect:inner
                  ~y:!y ~theme;
                incr y
              end;
              let list_h = Int.max 0 (body_bot - !y) in
              let start_idx =
                if total_rows <= list_h || list_h <= 0 then 0
                else
                  let s = modal.cursor - (list_h / 2) in
                  Int.max 0 (Int.min (total_rows - list_h) s)
              in
              let rows_arr = Array.of_list rows in
              for offset = 0 to list_h - 1 do
                let row_idx = start_idx + offset in
                if row_idx < total_rows && !y + offset < body_bot then begin
                  let ry = !y + offset in
                  let row_r = Rect.make ~x:inner.x ~y:ry ~w:inner.w ~h:1 in
                  let is_cur = Int.equal row_idx modal.cursor in
                  let r_bg =
                    if is_cur then Color.of_rgb theme.selection_bg else bg
                  in
                  Cell_grid.fill_rect ~clip:row_r grid ~rect:row_r
                    ~style:(Typography.primary ~bg:r_bg theme) ();
                  if is_cur then
                    Card.draw_left_rail ~bg:r_bg
                      ~tone:
                        (if modal.editing_free_text then Theme.Status_ok
                         else Theme.Status_active)
                      grid ~x:(x0 - 1) ~y:ry ~theme ~h:1;
                  let text_r = Rect.make ~x:x0 ~y:ry ~w:content_w ~h:1 in
                  let row_pri =
                    if is_cur then Typography.primary ~bg:r_bg ~bold:true theme
                    else { pri_st with bg = r_bg }
                  in
                  let row_wh = { whisper_st with bg = r_bg } in
                  let row_ok = { ok_st with bg = r_bg } in
                  let row_acc = { acc_st with bg = r_bg } in
                  match rows_arr.(row_idx) with
                  | Model.Ask_row_choice (idx, ch) ->
                      let selected =
                        Model.equal_ask_answer_mode draft.mode
                          Model.Ask_mode_choices
                        && List.exists (String.equal ch.choice_id)
                             draft.choice_ids
                      in
                      let mark =
                        match q.mode with
                        | Wire_work.Ask_single -> if selected then "●" else "○"
                        | Wire_work.Ask_multi ->
                            if selected then "[x]" else "[ ]"
                      in
                      let key_s =
                        match Model.ask_choice_hotkey_char idx with
                        | Some kc -> Printf.sprintf "[%c] " kc
                        | None -> ""
                      in
                      let cx = ref x0 in
                      let a0 =
                        Cell_grid.put_text ~clip:text_r grid ~x:!cx ~y:ry
                          ~style:(if selected then row_ok else row_acc)
                          (mark ^ " ")
                      in
                      cx := !cx + a0;
                      let a1 =
                        Cell_grid.put_text ~clip:text_r grid ~x:!cx ~y:ry
                          ~style:row_acc key_s
                      in
                      cx := !cx + a1;
                      let rem_w = Int.max 0 (x0 + content_w - !cx) in
                      let a2 =
                        Cell_grid.put_text ~clip:text_r grid ~x:!cx ~y:ry
                          ~style:row_pri
                          (Grapheme.truncate_to_width ~max_width:rem_w ch.label)
                      in
                      cx := !cx + a2;
                      (match ch.description with
                      | Some desc
                        when not (String.equal (String.trim desc) "") ->
                          let rem2 = Int.max 0 (x0 + content_w - !cx) in
                          if rem2 > 4 then
                            ignore
                              (Cell_grid.put_text ~clip:text_r grid ~x:!cx ~y:ry
                                 ~style:row_wh
                                 (Grapheme.truncate_to_width ~max_width:rem2
                                    (" — " ^ desc)))
                      | Some _ | None -> ())
                  | Model.Ask_row_free_text ->
                      let is_active_ft =
                        Model.equal_ask_answer_mode draft.mode
                          Model.Ask_mode_free_text
                        && not (String.equal (String.trim draft.free_text) "")
                      in
                      let prefix =
                        if modal.editing_free_text then "✎ "
                        else if is_active_ft then "✓ ✎ "
                        else "✎ [i] "
                      in
                      let cx = ref x0 in
                      let a0 =
                        Cell_grid.put_text ~clip:text_r grid ~x:!cx ~y:ry
                          ~style:
                            (if modal.editing_free_text || is_active_ft then
                               row_ok
                             else row_acc)
                          prefix
                      in
                      cx := !cx + a0;
                      let rem_w = Int.max 0 (x0 + content_w - !cx) in
                      if modal.editing_free_text then begin
                        let vis_before, vis_after =
                          split_graphemes_for_caret ~max_w:rem_w
                            ~cursor:draft.free_text_cursor draft.free_text
                        in
                        let ab =
                          Cell_grid.put_text ~clip:text_r grid ~x:!cx ~y:ry
                            ~style:row_pri vis_before
                        in
                        cx := !cx + ab;
                        let ac =
                          Cell_grid.put_text ~clip:text_r grid ~x:!cx ~y:ry
                            ~style:row_ok "│"
                        in
                        cx := !cx + ac;
                        ignore
                          (Cell_grid.put_text ~clip:text_r grid ~x:!cx ~y:ry
                             ~style:row_pri vis_after)
                      end
                      else if not (String.equal (String.trim draft.free_text) "")
                      then
                        ignore
                          (Cell_grid.put_text ~clip:text_r grid ~x:!cx ~y:ry
                             ~style:row_pri
                             (Grapheme.truncate_to_width ~max_width:rem_w
                                draft.free_text))
                      else
                        let ph =
                          match q.free_text_hint with
                          | Some h when not (String.equal (String.trim h) "") ->
                              h
                          | Some _ | None ->
                              Say.resolve lang
                                (Say.make ~ko:"직접 입력 ([i] 또는 [Enter])"
                                   ~en:"Type custom answer ([i] or [Enter])")
                        in
                        ignore
                          (Cell_grid.put_text ~clip:text_r grid ~x:!cx ~y:ry
                             ~style:row_wh
                             (Grapheme.truncate_to_width ~max_width:rem_w ph))
                  | Model.Ask_row_skip ->
                      let is_skipped =
                        Model.equal_ask_answer_mode draft.mode
                          Model.Ask_mode_skipped
                      in
                      let lbl =
                        Say.resolve lang
                          (Say.make ~ko:"이 질문 건너뛰기"
                             ~en:"Skip this question")
                      in
                      let txt =
                        if is_skipped then "⊘ [✓] " ^ lbl else "⊘ " ^ lbl
                      in
                      ignore
                        (Cell_grid.put_text ~clip:text_r grid ~x:x0 ~y:ry
                           ~style:(if is_skipped then row_ok else row_wh)
                           (Grapheme.truncate_to_width ~max_width:content_w txt))
                end
              done;
              (* 4. Bottom Keycap Footer *)
              if footer_h > 0 && body_bot < bot then begin
                let fr = Rect.make ~x:x0 ~y:body_bot ~w:content_w ~h:1 in
                let hint =
                  match live_status with
                  | Model.Ask_live_closed ->
                      Say.resolve lang
                        (Say.make ~ko:"[C] 키퍼 채팅 · [Esc] 닫기"
                           ~en:"[C] Keeper Chat · [Esc] Close")
                  | Model.Ask_live_in_flight ->
                      Say.resolve lang
                        (Say.make ~ko:"응답 전송 중... · [Esc] 닫기"
                           ~en:"Submitting... · [Esc] Close")
                  | Model.Ask_live_open when is_sending ->
                      Say.resolve lang
                        (Say.make ~ko:"응답 전송 중... · [Esc] 닫기"
                           ~en:"Submitting... · [Esc] Close")
                  | Model.Ask_live_open ->
                      if modal.editing_free_text then
                        Say.resolve lang
                          (Say.make
                             ~ko:"[←→/Home/End] 커서 · [Enter] 확정 · [Ctrl+Enter] 제출 · [Esc] 선택으로"
                             ~en:"[←→/Home/End] Cursor · [Enter] Confirm · [Ctrl+Enter] Submit · [Esc] Back")
                      else
                        let parts =
                          [
                            Say.resolve lang
                              (Say.make ~ko:"[↑↓/jk] 이동" ~en:"[↑↓/jk] Move");
                            Say.resolve lang
                              (Say.make ~ko:"[Space] 선택" ~en:"[Space] Toggle");
                            Say.resolve lang
                              (Say.make ~ko:"[Enter] 확인" ~en:"[Enter] Confirm");
                          ]
                          @ (if Option.is_some !prompt_overflow then
                               [
                                 Say.resolve lang
                                   (Say.make ~ko:"[J/K] 본문" ~en:"[J/K] Prompt");
                               ]
                             else [])
                          @ (if q.allow_free_text then
                               [
                                 Say.resolve lang
                                   (Say.make ~ko:"[i] 입력" ~en:"[i] Type");
                               ]
                             else [])
                          @ (if q_count > 1 then
                               [
                                 Say.resolve lang
                                   (Say.make ~ko:"[[ ]/Tab] 질문"
                                      ~en:"[[ ]/Tab] Q");
                               ]
                             else [])
                          @ [
                              Say.resolve lang
                                (Say.make ~ko:"[^↵] 전체제출" ~en:"[^↵] Submit");
                              Say.resolve lang
                                (Say.make ~ko:"[C] 채팅" ~en:"[C] Chat");
                            ]
                        in
                        String.concat " · " parts
                in
                ignore
                  (Cell_grid.put_text ~clip:fr grid ~x:x0 ~y:body_bot
                     ~style:struct_st
                     (Grapheme.truncate_to_width ~max_width:content_w hint))
              end
        end

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
        | Nav.Ask_answer ->
            render_ask_answer_modal grid ~cache ~rect ~theme ~model
        | Nav.Help -> render_help_overlay grid ~cache ~rect ~theme ~model
        | Nav.System_gate gate ->
            render_system_gate grid ~cache ~rect ~theme ~model ~gate
