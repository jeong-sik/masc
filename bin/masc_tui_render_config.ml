(** System Config screens (Prompts, Presets, Themes, Runtime TOML, Models,
    Runtime Parameters, and Voice) and their viewport/scroll calculators. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim
open Masc_tui_press

module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Keeper_chat = Masc_tui_keeper_chat_projection
module Theme_choice = Masc_tui_theme_choice

(* How long ago the running binary's commit landed. Coarse on purpose: the
   question is "is this the build I think it is", and minutes answer it while
   seconds only look precise. *)
let binary_age_text = function
  | None -> "age unknown"
  | Some seconds when seconds < 60. -> "built just now"
  | Some seconds when seconds < 3600. ->
      Printf.sprintf "built %.0fm ago" (seconds /. 60.)
  | Some seconds when seconds < 86400. ->
      Printf.sprintf "built %.0fh ago" (seconds /. 3600.)
  | Some seconds -> Printf.sprintf "built %.0fd ago" (seconds /. 86400.)

(* The Runtime_params registry. A view, not a second place values live:
   overrides are written by the server to .masc/runtime_params.json, and this
   shows what is there beside what it would be without them.

   runtime.toml sits in the pane next door and answers a different question --
   which runtimes and lanes exist. One value claimed by two files is how "I set
   it and it did not take" happens, so these stay two panes over one store. *)
let render_runtime_params (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  box_line buf cols
    (config_pane_title ~cols
       ~name:(screen_title (ui_text state ~ko:" MASC 시스템·파라미터" ~en:" MASC Params"))
       state);
  (* Where the overrides live leads, because it is the only thing on this row
     the reader cannot get anywhere else, and it was what the row cut first:
     at eighty columns it read "overrides persist in .masc/run\xe2\x80\xa6" and at
     sixty-four "overrides pers\xe2\x80\xa6", while the two key phrases in front of it
     survived whole.

     [Enter] is gone from the row. The footer is pinned to keep it at every
     width ([Masc_tui_footer.never_dropped_keys]), so "Enter edits by type"
     was the footer's own hint said a second time on a row that had no space
     for it -- and [e] opens the same editor, which the row never said.

     [E] stays. The footer drops it at eighty columns, so below that this row
     is the only place the advanced editor is named. *)
  (match state.runtime_params_notice with
   | None ->
     box_line_styled buf cols ~style:(Theme.recede ())
       (ui_text state
          ~ko:"  저장 위치: .masc/runtime_params.json · E:JSON 편집"
          ~en:"  Saved in .masc/runtime_params.json · E:edit JSON")
   | Some (ok, detail) ->
     box_line_styled buf cols ~style:(if ok then Theme.ok () else Theme.bad ())
       ("  " ^ Terminal_text.single_line detail));
  let rows = Option.value state.runtime_params ~default:[] in
  let selected = List.nth_opt rows state.runtime_params_cursor in
  let field label value =
    Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols - 2))
      (label ^ " · " ^ value)
    |> List.map (fun line -> "  " ^ line)
  in
  (* Values are exact JSON. Word wrapping can discard a space at a chunk
     boundary, so split the sanitised value only between terminal cells. *)
  let value_field label value =
    let inner = max 1 (framed_inner_width cols) in
    let prefix = "  " ^ label ^ " · " in
    let prefix_width = Message_layout.display_width prefix in
    let value = Masc.Tui_terminal_text.sanitize_terminal_text value in
    if prefix_width >= inner then
      let indent = if inner > 2 then "  " else "" in
      let width = max 1 (inner - Message_layout.display_width indent) in
      let rows text = Message_layout.split_cells ~max_cells:width text
          |> List.map (fun line -> indent ^ line) in
      rows label @ rows value
    else
      let width = inner - prefix_width in
      match Message_layout.split_cells ~max_cells:width value with
      | [] -> [prefix]
      | first :: rest -> (prefix ^ first) :: List.map (fun line -> "    " ^ line) rest
  in
  let selected_lines =
    (match state.runtime_params_notice with
     | None -> []
     | Some (ok, text) -> field (if ok then ui_text state ~ko:"결과" ~en:"Result"
                                else ui_text state ~ko:"거절" ~en:"Refused") text)
    @
    match selected with
    | None ->
      [ ui_text state ~ko:"  행을 선택하면 파라미터 명세와 허용 범위를 표시합니다"
          ~en:"  Select a row to see its contract" ]
    | Some row ->
      let open Tui_decode in
      detail_section_lines ~first:true
        (ui_text state ~ko:"현재 값" ~en:"Current value")
      @ field (ui_text state ~ko:"키" ~en:"Key") row.rpr_key
      @ field (ui_text state ~ko:"설명" ~en:"Contract") row.rpr_description
      @ value_field (ui_text state ~ko:"현재 값" ~en:"Current") row.rpr_current_json
      @ value_field (ui_text state ~ko:"기본값" ~en:"Default") row.rpr_default_json
      @ detail_section_lines
          (ui_text state ~ko:"타입과 허용 범위" ~en:"Type and constraints")
      @ field (ui_text state ~ko:"타입" ~en:"Type")
          (if String.trim row.rpr_value_type = "" then "typed value" else row.rpr_value_type)
      @ (match row.rpr_min_json with None -> [] | Some value -> value_field (ui_text state ~ko:"최소값" ~en:"Minimum") value)
      @ (match row.rpr_max_json with None -> [] | Some value -> value_field (ui_text state ~ko:"최대값" ~en:"Maximum") value)
      @ (row.rpr_choices
         |> List.mapi (fun index choice ->
              value_field (Printf.sprintf (if state.ui_language = Lang_ko then "선택지 %d" else "Choice %d") (index + 1))
                (Yojson.Safe.to_string (`String choice)))
         |> List.concat)
      @ detail_section_lines
          (ui_text state ~ko:"적용 상태" ~en:"Source")
      @ field (ui_text state ~ko:"적용 상태" ~en:"Source")
          (if row.rpr_has_override
           then ui_text state ~ko:"사용자 오버라이드" ~en:"override"
           else ui_text state ~ko:"기본값" ~en:"default")
      @ (match row.rpr_surface with
         | None -> []
         | Some surface ->
           field (ui_text state ~ko:"소속 그룹" ~en:"Group")
             (surface.rps_id ^ " · " ^ surface.rps_description))
  in
  box_line_styled buf cols ~style:(Theme.recede ())
    (system_subnav_row state);
  box_divider buf cols;
  (* Editing adds a divider and two form rows.  Spend those rows out of the
     list budget so the footer remains visible instead of falling underneath
     the always-present composer. *)
  let list_height, detail_height =
    Masc_tui_types.runtime_params_viewport state ~terminal_rows in
  let count = List.length rows in
  let cursor = max 0 (min state.runtime_params_cursor (count - 1)) in
  (match state.runtime_params_error with
   | Some detail ->
     box_line buf cols ((Theme.bad ()) ^ ui_text state ~ko:"설정을 읽지 못했습니다: " ~en:"Could not read settings: " ^ Ansi.reset
                        ^ Terminal_text.single_line detail);
     for _ = 2 to list_height do box_empty buf cols done
   | None ->
     if state.runtime_params_loading && rows = []
     then begin
       box_line buf cols (Ansi.dim ^ ui_text state ~ko:"  파라미터를 읽는 중…" ~en:"  Loading parameters…" ^ Ansi.reset);
       for _ = 2 to list_height do box_empty buf cols done
     end
     else if Option.is_none state.runtime_params
     then begin
       box_line buf cols (Ansi.dim ^ ui_text state ~ko:"  파라미터 미확인 · 작업공간 접근을 확인하고 새로고침하세요"
         ~en:"  Parameters unread · confirm workspace access and refresh" ^ Ansi.reset);
       for _ = 2 to list_height do box_empty buf cols done
     end
     else if rows = []
     then begin
       box_line buf cols (Ansi.dim ^ ui_text state ~ko:"  등록된 설정 없음" ~en:"  No settings registered" ^ Ansi.reset);
       for _ = 2 to list_height do box_empty buf cols done
     end else begin
       (* Rows arrive in registry-group order (Tui_decode sorts them by
          surface). Headers are lines on this screen, not decoration outside it:
          they are built into the same list the window scrolls over, so a group
          heading costs a row from [list_height] instead of pushing the last
          param off the bottom.

          The cursor stays an index into [state.runtime_params] — key handling
          and the edit target read it — so the window is positioned by where
          that row lands in the display list. *)
       let unfiled_description =
         ui_text state ~ko:"그룹 없음 — 등록부에 소속 그룹이 없습니다"
           ~en:"Unfiled — no group assigned in the registry"
       in
       let surface_of (row : Tui_decode.runtime_param_row) =
         match row.Tui_decode.rpr_surface with
         | Some s -> (s.Tui_decode.rps_id, s.Tui_decode.rps_description)
         | None -> ("", unfiled_description)
       in
       let display =
         let rec build previous index acc = function
           | [] -> List.rev acc
           | row :: rest ->
             let id, description = surface_of row in
             let acc =
               match previous with
               | Some prev when String.equal prev id -> acc
               | Some _ | None -> `Header (id, description) :: acc
             in
             build (Some id) (index + 1) (`Row (index, row) :: acc) rest
         in
         build None 0 [] rows
       in
       let cursor_display =
         let rec find index = function
           | [] -> 0
           | `Row (row_index, _) :: _ when row_index = cursor -> index
           | _ :: rest -> find (index + 1) rest
         in
         find 0 display
       in
       let total = List.length display in
       let first =
         if total <= list_height then 0
         else if cursor_display < list_height then 0
         else min (total - list_height) (cursor_display - list_height + 1)
       in
       let display_window = Rows.of_list ~first:first ~height:list_height display in
       for index = 0 to list_height - 1 do
         match Rows.at display_window (first + index) with
         | None -> box_empty buf cols
         | Some (`Header (id, description)) ->
           let label = if String.equal id "" then ui_text state ~ko:"(그룹 없음)" ~en:"(unfiled)" else id in
           box_line_styled buf cols
             ~style:(Masc_tui_theme.tone Masc_tui_theme.Accent)
             (Printf.sprintf "  %s %s"
                (Terminal_text.single_line label)
                (Ansi.dim ^ Terminal_text.single_line description ^ Ansi.reset))
         | Some (`Row (row_index, row)) ->
           let open Tui_decode in
           let value_width = max 4 (min 16 ((framed_inner_width cols - 7) / 3)) in
           let key_width = max 1 (framed_inner_width cols - 7 - value_width) in
           let line =
             Printf.sprintf "    %s %s %s"
               (Masc_tui_config_mark.param_glyph
                  ~has_override:row.rpr_has_override)
               (Message_layout.fit_middle key_width (Terminal_text.single_line row.rpr_key)
                |> fun key -> fit_width key key_width)
               (fit_width (Terminal_text.single_line
                  (runtime_param_value_text ~value_type:row.rpr_value_type
                     row.rpr_current_json)) value_width)
           in
           if row_index = cursor then box_line_selected buf cols line
           else
             box_line_styled buf cols
               ~style:(if row.rpr_has_override then (Masc_tui_theme.tone Masc_tui_theme.Accent) else Ansi.dim) line
       done
     end);
  let scroll = Masc_tui_scroll.normalize ~count:(List.length selected_lines)
      ~height:(max 1 detail_height) state.config_scroll in
  let reading = Masc_tui_scroll.window_reading ~noun:(ui_text state ~ko:"상세" ~en:"Detail") ~scroll
      ~height:detail_height (List.length selected_lines) in
  let detail_window = Rows.of_list ~first:scroll ~height:detail_height selected_lines in
  let visible_lines = List.init detail_height (fun index ->
      Option.value (Rows.at detail_window (scroll + index)) ~default:"") in
  let panel_title = Option.map (fun row ->
      ui_text state ~ko:"선택한 설정 · " ~en:"Selected setting · " ^ Terminal_text.single_line row.Tui_decode.rpr_key
      ^ " · " ^ reading) selected in
  (* The panel replaces the divider and position row, so the document keeps
     the shared paging height. Use plain rows when panel borders would trim
     any exact JSON row or hide the document position. *)
  (match panel_title with
   | Some title
     when Message_layout.display_width title <= framed_inner_width cols - 4
       && List.for_all
            (fun line -> Message_layout.display_width line <= framed_inner_width cols - 4)
            selected_lines ->
       studio_panel ~width:(framed_inner_width cols) ~title ~lines:visible_lines
       |> List.iter (box_line buf cols)
   | Some _ | None ->
       box_divider buf cols;
       List.iter (box_line buf cols) visible_lines;
       box_line_styled buf cols ~style:(Theme.recede ()) ("  " ^ reading));
  (match state.runtime_param_edit with
   | None -> ()
   | Some edit ->
     let friendly_bool =
       edit.rpe_mode = Friendly_value
       && List.mem (runtime_param_type_name edit.rpe_value_type)
            [ "bool"; "boolean" ]
     in
     (* A param with a closed set is walked the way a bool is toggled — the
        reader is choosing, not typing — so both draw as a choice. *)
     let friendly_choice =
       edit.rpe_mode = Friendly_value && edit.rpe_choices <> []
     in
     let picking = friendly_bool || friendly_choice in
     let field_label =
       match edit.rpe_mode with
       | Advanced_json -> "JSON>"
       | Friendly_value when picking -> ui_text state ~ko:"선택>" ~en:"choice>"
       | Friendly_value -> ui_text state ~ko:"값>" ~en:"value>"
     in
     let draft = Terminal_text.single_line edit.rpe_draft in
     let draft =
       if edit.rpe_replace_on_type && not picking
       then Theme.selection ^ draft ^ Ansi.reset
       else draft
     in
     box_divider buf cols;
     let runtime_param_edit_row =
       row_with_field ~cols
         ~lead:(Printf.sprintf "  %s%s%s " Ansi.bold field_label Ansi.reset)
         ~field:draft ~tail:""
     in
     box_line buf cols runtime_param_edit_row;
     box_line_styled buf cols ~style:(Theme.recede ())
       (Printf.sprintf (if state.ui_language = Lang_ko then "  %s 편집 · %s" else "  editing %s · %s")
          (Terminal_text.single_line edit.rpe_key)
          (match edit.rpe_mode with
           | Advanced_json -> ui_text state ~ko:"고급 JSON · Enter 적용 · Esc 취소" ~en:"advanced JSON · Enter apply · Esc cancel"
           | Friendly_value when friendly_bool ->
             ui_text state ~ko:"←/→/Space 전환 · Enter 적용 · Esc 취소" ~en:"Left/Right/Space toggle · Enter apply · Esc cancel"
           | Friendly_value when friendly_choice ->
             (* The set is spelled out: a reader walking it one key at a time
                cannot otherwise see how many values there are, or that a form
                they can type by hand exists beside them. *)
             Printf.sprintf
               (if state.ui_language = Lang_ko then "←/→/Space 선택 (%s) · Enter 적용 · Esc 취소"
                else "Left/Right/Space cycle (%s) · Enter apply · Esc cancel")
               (String.concat " · " edit.rpe_choices)
           | Friendly_value ->
             ui_text state ~ko:"입력하여 교체 · Enter 적용 · Esc 취소" ~en:"type to replace · Enter apply · Esc cancel")));
  let recovery_in_slot = recovery_box_bottom state buf ~cols in
  Buffer.add_string buf
    (footer_line ~recovery_in_slot state ~max_cells:cols
       ~hints:
         (match state.runtime_param_edit with
          | Some edit
            when edit.rpe_mode = Friendly_value
                 && List.mem (runtime_param_type_name edit.rpe_value_type)
                      [ "bool"; "boolean" ] ->
            ui_text state ~ko:"Left/Right/Space:전환  Enter:적용  Esc:취소" ~en:"Left/Right/Space:toggle  Enter:apply  Esc:cancel"
          | Some edit
            when edit.rpe_mode = Friendly_value && edit.rpe_choices <> [] ->
            ui_text state ~ko:"Left/Right/Space:선택  Enter:적용  Esc:취소" ~en:"Left/Right/Space:cycle  Enter:apply  Esc:cancel"
          | Some { rpe_mode = Friendly_value; _ } ->
            ui_text state ~ko:"입력:값  Enter:적용  Ctrl-U:지우기  Esc:취소" ~en:"type:value  Enter:apply  Ctrl-U:clear  Esc:cancel"
          | Some { rpe_mode = Advanced_json; _ } ->
            ui_text state ~ko:"JSON 입력  Enter:적용  Ctrl-U:지우기  Esc:취소" ~en:"type JSON  Enter:apply  Ctrl-U:clear  Esc:cancel"
          | None -> Masc_tui_keys.footer_hints_config ~lang:state.ui_language ~pane:Config_params));
  finish_surface state ~clamped:(Runtime_params_scroll scroll)
    ~surface_key:"config-params" ~rows:terminal_rows ~cols buf
;;

(* Where the prompt catalog is, for the one row both prompt screens draw above
   their list. A failed refresh says so above the rows it kept, so they read as
   the last good catalog rather than a fresh one; a first read that failed has
   no rows under it. *)
let prompt_catalog_status_row state prompts =
  match prompts with
  | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Absent -> None
  | Masc_tui_fetched.Loading -> Some (Theme.recede (), ui_text state ~ko:"프롬프트 목록을 읽는 중…" ~en:"Loading prompt catalog…")
  | Masc_tui_fetched.Stale (_, detail) ->
    Some
      ( Theme.bad ()
      , ui_text state ~ko:"새로고침 실패 · 마지막으로 읽은 목록 — " ~en:"Refresh failed · last read catalog — " ^ Terminal_text.single_line detail )
  | Masc_tui_fetched.Failed detail -> Some (Theme.bad (), Terminal_text.single_line detail)
;;

let prompts_detail_layout state ~rows ~error_rows ~list_count =
  let fixed_rows = if state.prompts_show_runtime_assets then 8 else 7 in
  let combined = max 1 (rows - fixed_rows - error_rows) in
  let list_height = min (max 1 list_count)
      (min (combined - 1) (min 8 (max 1 (combined / 3)))) in
  (list_height, max 1 (combined - list_height))

let prompts_detail_lines (state : state) ~cols =
  let prompts = Masc_tui_fetched.view_for ~equal:Unit.equal state.prompts ~key:() in
  let wrap text =
    Message_layout.wrap_body ~max_cells:(max 1 (framed_inner_width cols - 2))
      ~sanitize:Terminal_text.single_line text
  in
  let body text =
    Message_layout.wrap_body ~markdown:document_markdown
      ~max_cells:(max 1 (framed_inner_width cols - 2)) ~sanitize:Terminal_text.single_line text
  in
  let field name text = name ^ ": " ^ Terminal_text.single_line text in
  let status = match prompt_catalog_status_row state prompts with
    | None -> [] | Some (_, text) -> wrap text
  in
  let section ?(first = false) title =
    let heading = [ Theme.info () ^ Ansi.bold ^ "[ " ^ title ^ " ]" ^ Ansi.reset ] in
    if first then heading else "" :: heading
  in
  let document = match Masc_tui_fetched.value prompts with
    | None -> wrap (ui_text state ~ko:"선택한 프롬프트가 없습니다" ~en:"No prompt selected")
    | Some snapshot when state.prompts_show_runtime_assets ->
        let assets = snapshot.Tui_decode.ps_runtime_assets in
        let selected = List.nth_opt assets
            (max 0 (min state.prompts_cursor (List.length assets - 1))) in
        (match selected with
         | None -> wrap (ui_text state ~ko:"런타임 프롬프트 자산이 없습니다" ~en:"No runtime prompt assets")
         | Some asset ->
             section ~first:true (ui_text state ~ko:"런타임 자산" ~en:"Runtime asset")
             @ wrap (ui_text state ~ko:"읽기 전용 자산 · 프롬프트 재정의 대상 아님" ~en:"Read-only asset · not a registry override")
             @ List.concat_map wrap
                 [field (ui_text state ~ko:"자산" ~en:"Asset") asset.pra_path;
                  field (ui_text state ~ko:"소스" ~en:"Source")
                    (if asset.pra_file_exists then ui_text state ~ko:"런타임 파일" ~en:"Runtime file"
                     else ui_text state ~ko:"누락" ~en:"Missing");
                  field (ui_text state ~ko:"파일" ~en:"File") asset.pra_file_path]
             @ section (ui_text state ~ko:"본문" ~en:"Body")
             @ body asset.pra_value)
    | Some snapshot ->
        let rows = Tui_decode.prompt_rows_for_operator
            ~show_fragments:state.prompts_show_fragments snapshot in
        let selected = List.nth_opt rows
            (max 0 (min state.prompts_cursor (List.length rows - 1))) in
        (match selected with
         | None -> wrap (ui_text state ~ko:"선택한 프롬프트가 없습니다" ~en:"No prompt selected")
         | Some row ->
             let notices =
               match List.find_opt
                       (fun (entry : Tui_decode.held_back_override) ->
                         String.equal entry.hbo_key row.pr_key)
                       snapshot.ps_held_back with
               | None -> []
               | Some entry ->
                   List.concat_map wrap
                     [Printf.sprintf
                        (if state.ui_language = Lang_ko then "⊘ 적용 안 됨 · 저장된 재정의 %d바이트 보존"
                         else "⊘ Not applied · saved override of %d bytes retained") entry.hbo_bytes;
                      entry.hbo_reason;
                      ui_text state ~ko:"해당 변수를 빼고 같은 키를 다시 저장하세요"
                        ~en:"Remove that variable and save the same key again"]
             in
             let moved = if row.pr_override_default_moved then
                 wrap (ui_text state
                   ~ko:"△ 기본 프롬프트가 바뀌었지만 재정의는 계속 적용 중입니다 · 현재 기본값과 대조하세요"
                   ~en:"△ The default changed; the override remains active · compare it with the current default")
               else []
             in
             let authoring =
               List.concat_map
                 (function
                   | Tui_decode.Invalid_operator_surface {value; source_file} ->
                       List.concat_map wrap
                         ["△ invalid_operator_surface";
                          field (ui_text state ~ko:"원문 값" ~en:"Value") (Printf.sprintf "operator_surface = %S" value);
                          field (ui_text state ~ko:"원본 파일" ~en:"Source file") source_file;
                          ui_text state ~ko:"원본 마크다운의 operator_surface를 primary 또는 fragment로 고친 뒤 다시 등록하고 r로 새로 읽으세요"
                            ~en:"Fix operator_surface to primary or fragment in the source Markdown, register it again, then reload with r";
                          ui_text state ~ko:"본문 재정의 저장·해제는 이 작성 오류를 고치지 않습니다"
                            ~en:"Saving or clearing a body override does not fix this authoring error"])
                 row.pr_authoring_issues
             in
             let actual_input =
               if not (String.equal row.pr_category "librarian") then []
               else if state.prompts_librarian_input_loading
                       && not (Option.exists
                            (fun (key, _) -> String.equal key row.pr_key)
                            state.prompts_librarian_input) then
                 [ui_text state ~ko:"관리자 실행 상세를 읽는 중…" ~en:"Loading admin execution details…"]
               else match state.prompts_librarian_input_error with
                 | Some detail -> [ui_text state ~ko:"읽기 실패: " ~en:"Read failed: " ^ Terminal_text.single_line detail]
                 | None ->
                     (match state.prompts_librarian_input with
                      | Some (key, lines) when String.equal key row.pr_key -> lines
                      | Some _ | None -> [])
             in
             let source = match row.pr_source with
               | Tui_decode.Prompt_override -> ui_text state ~ko:"재정의 적용 · MD는 기본값" ~en:"Override active · MD is default"
               | Tui_decode.Prompt_file -> ui_text state ~ko:"MD 파일" ~en:"MD file"
               | Tui_decode.Prompt_missing -> ui_text state ~ko:"없음" ~en:"Missing"
             in
             let contract =
               if String.equal row.pr_category "librarian" then
                 wrap (ui_text state ~ko:"입력: 키퍼 지침 | 현재 기억 | 제한된 대화 | 상대 관측 | 사실 최대 바이트"
                   ~en:"Input: Keeper instructions | current memory | bounded conversation | counterpart observations | fact byte limit")
               else []
             in
             let has_notices = notices <> [] || moved <> [] || authoring <> [] in
             notices @ moved @ authoring
             @ section ~first:(not has_notices) (ui_text state ~ko:"프롬프트 정보" ~en:"Prompt information")
             @ List.concat_map wrap
                 [field (ui_text state ~ko:"키" ~en:"Key") row.pr_key;
                  field (ui_text state ~ko:"소스" ~en:"Source") source;
                  field (ui_text state ~ko:"파일" ~en:"File") row.pr_file_path;
                  field (ui_text state ~ko:"분류" ~en:"Category") row.pr_category;
                  field (ui_text state ~ko:"설명" ~en:"Description") row.pr_description;
                  field (ui_text state ~ko:"변수" ~en:"Variables") (match row.pr_template_variables with
                    | [] -> ui_text state ~ko:"없음" ~en:"None" | variables -> String.concat " | " variables);
                  field (ui_text state ~ko:"유형" ~en:"Kind") (match row.pr_operator_surface with
                    | Tui_decode.Prompt_primary -> ui_text state ~ko:"주 프롬프트" ~en:"Primary"
                    | Tui_decode.Prompt_fragment -> ui_text state ~ko:"내부 조각" ~en:"Fragment")]
             @ contract
             @ section (ui_text state ~ko:"적용 중인 템플릿" ~en:"Effective template")
             @ body row.pr_effective
             @ (match actual_input with
                | [] -> []
                | lines ->
                    section (ui_text state ~ko:"최근 Librarian 입력" ~en:"Recent Librarian input")
                    @ List.concat_map wrap lines))
  in
  status @ document

let prompts_detail_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let prompts = Masc_tui_fetched.view_for ~equal:Unit.equal state.prompts ~key:() in
  let error_rows = if Option.is_some (prompt_catalog_status_row state prompts) then 1 else 0 in
  let list_count = match Masc_tui_fetched.value prompts with
    | None -> 0
    | Some snapshot when state.prompts_show_runtime_assets -> List.length snapshot.Tui_decode.ps_runtime_assets
    | Some snapshot -> List.length (Tui_decode.prompt_rows_for_operator
        ~show_fragments:state.prompts_show_fragments snapshot)
  in
  let _, height = prompts_detail_layout state ~rows ~error_rows ~list_count in
  (List.length (prompts_detail_lines state ~cols), height)

let render_prompts_detail state buf ~cols ~height ~selected =
  let rendered = prompts_detail_lines state ~cols in
  let total = List.length rendered in
  let scroll = Masc_tui_scroll.normalize ~count:total ~height state.config_scroll in
  box_line_styled buf cols ~style:(Theme.recede ())
    (row_with_field ~cols ~lead:"  " ~field:(Terminal_text.single_line selected)
       ~tail:(Printf.sprintf " · %s [%d-%d/%d]"
         (ui_text state ~ko:"상세" ~en:"Detail")
         (if total = 0 then 0 else scroll + 1) (min total (scroll + height)) total));
  let window = Rows.of_list ~first:scroll ~height rendered in
  for index = 0 to height - 1 do
    match Rows.at window (scroll + index) with
    | Some line -> box_line buf cols ("  " ^ line)
    | None -> box_empty buf cols
  done

let render_prompt_registry (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let prompts = Masc_tui_fetched.view_for ~equal:Unit.equal state.prompts ~key:() in
  (* A failed refresh keeps the catalog it read last: its rows, its count and
     its held-back overrides stay drawn, and the status row below says the
     refresh failed. Only a first read with no answer has none of them. *)
  let snapshot = Masc_tui_fetched.value prompts in
  let prompt_rows =
    match snapshot with
    | Some snapshot ->
        Tui_decode.prompt_rows_for_operator
          ~show_fragments:state.prompts_show_fragments snapshot
    | None -> []
  in
  let all_prompt_count =
    match snapshot with
    | Some snapshot -> List.length snapshot.Tui_decode.ps_rows
    | None -> 0
  in
  (* Overrides the registry declined to restore. A held-back key still draws
     from its file, so without this it renders exactly like a prompt nobody
     ever customized -- which is how an operator loses an override without
     learning they lost it. *)
  let held_back =
    match snapshot with
    | Some snapshot -> snapshot.Tui_decode.ps_held_back
    | None -> []
  in
  let held_back_for key =
    List.find_opt
      (fun (entry : Tui_decode.held_back_override) ->
        String.equal entry.Tui_decode.hbo_key key)
      held_back
  in
  let total = List.length prompt_rows in
  let cursor = max 0 (min state.prompts_cursor (total - 1)) in
  let selected = List.nth_opt prompt_rows cursor in
  (* A count only once the registry has answered. "0/0개" stood for a
     registry not asked yet and for one whose read failed, the same as for a
     registry with no prompts. *)
  let count_text =
    title_count_of_view prompts ~count:(fun _ ->
        Printf.sprintf (if state.ui_language = Lang_ko then "%d/%d개" else "%d/%d prompts") total all_prompt_count)
  in
  box_top buf cols;
  (* The count the registry answered, and -- before any decoration that can
     be cut -- how many overrides it held back. The row keeps a fixed floor
     for the tab strip, so at a hundred and twenty columns the reading can
     run a cell short and [config_pane_title_head] shortens the tail first.
     An override the registry declined is exactly the warning an operator
     must not lose to an ellipsis, so it sits beside the count the row
     protects rather than after the part that gives way. *)
  let held_back_note =
    match held_back with
    | [] -> ""
    | entries ->
      Printf.sprintf (if state.ui_language = Lang_ko then " %s적용 안 된 재정의 %d개%s" else " %s%d overrides not applied%s") (Theme.warn ())
        (List.length entries) Ansi.reset
  in
  let reading =
    Printf.sprintf "%s%s%s%s · %s%s"
      Ansi.dim count_text
      held_back_note
      Ansi.dim
      (if state.prompts_show_fragments then ui_text state ~ko:"내부 조각 포함" ~en:"including fragments"
       else ui_text state ~ko:"주 프롬프트" ~en:"primary prompts")
      Ansi.reset
  in
  box_line buf cols
    (config_pane_title ~cols
       ~name:(screen_title (ui_text state ~ko:" MASC 시스템·프롬프트" ~en:" MASC Prompts"))
       ~reading state);
  box_divider buf cols;
  (* One row that says where the catalog is. An empty list used to mean both
     "still reading" and "nothing here". *)
  let status_row = prompt_catalog_status_row state prompts in
  let error_rows = if Option.is_some status_row then 1 else 0 in
  let list_height, detail_height = prompts_detail_layout state ~rows ~error_rows ~list_count:total in
  let first = if cursor < list_height then 0 else cursor - list_height + 1 in
  (match status_row with
   | Some (style, text) ->
     box_line buf cols (style ^ "  " ^ fit_width text (framed_inner_width cols - 2) ^ Ansi.reset)
   | None -> ());
  let drawn = ref 0 in
  List.iteri
    (fun index (row : Tui_decode.prompt_row) ->
      if index >= first && index < first + list_height then begin
        incr drawn;
        let mark =
          let held_back = Option.is_some (held_back_for row.Tui_decode.pr_key) in
          let glyph =
            Masc_tui_config_mark.prompt_glyph ~held_back row.Tui_decode.pr_source
          in
          (* Colour is this pane's, the glyph the mark module's, because the
             help sheet draws the same glyph with no colour at all. *)
          match held_back, row.Tui_decode.pr_source with
          | true, _ -> (Theme.bad ()) ^ glyph ^ Ansi.reset
          | false, Tui_decode.Prompt_override -> (Theme.warn ()) ^ glyph ^ Ansi.reset
          | false, Tui_decode.Prompt_file -> glyph
          | false, Tui_decode.Prompt_missing -> (Theme.bad ()) ^ glyph ^ Ansi.reset
        in
        let authoring_mark, authoring_cells = match row.pr_authoring_issues with
          | [] -> "", 0
          | _ :: _ ->
              let mark = "△ " in
              Theme.warn () ^ mark ^ Ansi.reset, Message_layout.display_width mark
        in
        let label = mark ^ " "
            ^ authoring_mark
            ^ Message_layout.fit_middle
                (max 1 (framed_inner_width cols - 3 - authoring_cells))
                (Terminal_text.single_line row.Tui_decode.pr_key) in
        if index = cursor then
          box_line buf cols (Theme.selection ^ " " ^ label ^ Ansi.reset)
        else box_line buf cols (" " ^ label)
      end)
    prompt_rows;
  for _ = 1 to list_height - !drawn do
    box_empty buf cols
  done;
  box_divider buf cols;
  render_prompts_detail state buf ~cols ~height:detail_height
    ~selected:(match selected with
      | None -> ui_text state ~ko:"선택 없음" ~en:"No selection"
      | Some row -> row.Tui_decode.pr_key);
  let recovery_in_slot = recovery_box_bottom state buf ~cols in
  Buffer.add_string buf
    (footer_line ~recovery_in_slot state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_config ~lang:state.ui_language ~pane:Config_prompts));
  finish_surface state ~surface_key:"prompts" ~rows:terminal_rows ~cols buf

(* The raw text assets are distributed with the binary and deliberately have
   no override contract.  They use the same Config page as the editable
   Markdown registry, but a distinct mode makes the missing edit controls an
   explicit capability boundary rather than an accidental omission. *)
let render_runtime_prompt_assets (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 8192 in
  let prompts = Masc_tui_fetched.view_for ~equal:Unit.equal state.prompts ~key:() in
  let assets =
    match Masc_tui_fetched.value prompts with
    | Some snapshot -> snapshot.Tui_decode.ps_runtime_assets
    | None -> []
  in
  let total = List.length assets in
  let cursor = max 0 (min state.prompts_cursor (total - 1)) in
  let selected = List.nth_opt assets cursor in
  let count_text =
    title_count_of_view prompts ~count:(fun _ -> Printf.sprintf (if state.ui_language = Lang_ko then "%d개" else "%d assets") total)
  in
  box_top buf cols;
  let reading =
    Printf.sprintf "%s%s · %s%s" Ansi.dim count_text
      (ui_text state ~ko:"읽기 전용" ~en:"read only") Ansi.reset
  in
  box_line buf cols
    (config_pane_title ~cols
       ~name:(screen_title (ui_text state ~ko:" MASC 런타임 프롬프트 자산" ~en:" MASC Runtime Prompt Assets")) ~reading state);
  box_line_styled buf cols ~style:(Theme.recede ())
    (ui_text state ~ko:"  배포된 .txt 지시문 · 프롬프트 재정의 대상 아님"
       ~en:"  Distributed .txt instructions · not registry overrides");
  box_divider buf cols;
  (* One row that says where the catalog is. An empty list used to mean both
     "still reading" and "nothing here". *)
  let status_row = prompt_catalog_status_row state prompts in
  let error_rows = if Option.is_some status_row then 1 else 0 in
  let list_height, detail_height = prompts_detail_layout state ~rows ~error_rows ~list_count:total in
  let first = if cursor < list_height then 0 else cursor - list_height + 1 in
  (match status_row with
   | Some (style, text) ->
     box_line buf cols (style ^ "  " ^ fit_width text (framed_inner_width cols - 2) ^ Ansi.reset)
   | None -> ());
  let drawn = ref 0 in
  List.iteri
    (fun index (asset : Tui_decode.runtime_prompt_asset) ->
       if index >= first && index < first + list_height then begin
         incr drawn;
         let mark = if asset.pra_file_exists then " " else (Theme.bad ()) ^ "!" ^ Ansi.reset in
         let line = mark ^ " "
             ^ Message_layout.fit_middle (max 1 (framed_inner_width cols - 3))
                 (Terminal_text.single_line asset.pra_path) in
         if index = cursor then box_line buf cols (Theme.selection ^ " " ^ line ^ Ansi.reset)
         else box_line buf cols (" " ^ line)
       end)
    assets;
  for _ = 1 to list_height - !drawn do
    box_empty buf cols
  done;
  box_divider buf cols;
  render_prompts_detail state buf ~cols ~height:detail_height
    ~selected:(match selected with
      | None -> ui_text state ~ko:"선택 없음" ~en:"No selection"
      | Some asset -> asset.Tui_decode.pra_path);
  let recovery_in_slot = recovery_box_bottom state buf ~cols in
  Buffer.add_string buf
    (footer_line ~recovery_in_slot state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_prompt_assets ~lang:state.ui_language));
  finish_surface state ~surface_key:"prompt-runtime-assets" ~rows:terminal_rows ~cols buf
;;

let render_prompts (state : state) =
  if state.prompts_show_runtime_assets
  then render_runtime_prompt_assets state
  else render_prompt_registry state
;;

(* The row the reader is on. A check rather than a colour, because the point
   of this screen is that colours are about to change. *)
let chosen_mark = "\xe2\x9c\x93"

(* Everything right of the theme name has a fixed cell budget: the palette
   blocks, page kind, and contrast result. Give the name what remains, up to
   the longest bundled name. Unlike a printf width this counts terminal cells
   and truncates, so gruvbox-material-light-medium cannot push the next three
   columns sideways. *)
let theme_name_width ~cols =
  let fixed_cells = 45 in
  max 8 (min 29 (framed_inner_width cols - fixed_cells))
;;

(* Prompt presets (#32777). A preset is one named snapshot of three
   surfaces the operator changes together: the prompt override table, each
   keeper's instructions, and runtime.toml's assignments and exact-output
   lanes. The pane lists them, saves the live state under a typed name, and
   restores one behind a two-press arm — a restore rewrites all three, and
   the report below the list is the only place it says what it skipped and
   whether runtime.toml committed. *)
let preset_save_receipt_lines ~ko (receipt : preset_save_receipt) =
  let text korean english = if ko then korean else english in
  let name = Terminal_text.single_line receipt.psr_request.psp_name in
  let reason detail =
    text "  원인 · " "  Reason · " ^ Terminal_text.single_line detail in
  let outcome = match receipt.psr_result with
  | Ok _ ->
    [text "✓ 프리셋 저장 확인 · " "✓ Preset save confirmed · " ^ name]
  | Error (Preset_save_not_sent detail) ->
    [text "! 프리셋 저장 미전송 · " "! Preset save not sent · " ^ name;
     reason detail]
  | Error (Preset_save_refused detail) ->
    [text "! 프리셋 저장 거절 · " "! Preset save refused · " ^ name;
     reason detail]
  | Error (Preset_save_auth_retry_not_sent detail) ->
    [text "! 인증 거절 · 재시도 미전송 · " "! Authentication refused · retry not sent · " ^ name;
     reason detail]
  | Error (Preset_save_unconfirmed detail) ->
    [text "! 프리셋 저장 결과 미확인 · " "! Preset save unconfirmed · " ^ name;
     text "  다시 저장하기 전 내용을 확인하세요 · 같은 이름은 덮어씁니다"
       "  Check contents before saving again · the same name is overwritten";
     text "  목록에 이름이 있어도 이번 저장의 성공을 뜻하지 않습니다"
       "  A listed name alone does not confirm this save";
     text "  알림을 숨겨도 같은 이름의 재저장 경고는 유지됩니다"
       "  Hiding this notice keeps the same-name retry warning";
     reason detail] in
  match receipt.psr_result, receipt.psr_request.psp_chat_input with
  | Error (Preset_save_not_sent _ | Preset_save_auth_retry_not_sent _), Some input ->
    outcome @ [text "  미전송 채팅 명령 원문" "  Unsent chat command"]
    @ Masc_tui_text_block.lines input
  | (Ok _ | Error (Preset_save_refused _ | Preset_save_unconfirmed _)), _
  | Error (Preset_save_not_sent _ | Preset_save_auth_retry_not_sent _), None -> outcome

let preset_confirmation_rows (state : state) ~cols =
  let description = match state.preset_save_draft_source with
    | Preset_form_local -> []
    | Preset_form_chat _ when String.equal state.preset_save_draft_description "" ->
      [ui_text state ~ko:"▸ 채팅 설명 · 없음" ~en:"▸ Chat description · empty"]
    | Preset_form_chat _ ->
      [ui_text state ~ko:"▸ 채팅 설명" ~en:"▸ Chat description";
       state.preset_save_draft_description] in
  let lines = match state.preset_armed with
    | Some (Save_workspace_armed (name, workspace)) ->
      [ui_text state ~ko:"▸ 저장 이름 · " ~en:"▸ Save name · " ^ Terminal_text.single_line name;
       ui_text state ~ko:"▸ 저장할 작업 공간" ~en:"▸ Save workspace";
       ui_text state ~ko:"  기준 경로 · " ~en:"  Base · " ^ Terminal_text.single_line workspace.wi_base_path;
       ui_text state ~ko:"  MASC 경로 · " ~en:"  MASC root · " ^ Terminal_text.single_line workspace.wi_masc_root]
      @ description
      @ [ui_text state ~ko:"  전체 확인 후 Enter: 진행 · Esc: 취소"
           ~en:"  After reviewing all rows, Enter: continue · Esc: cancel"]
    | Some (Save_armed name) ->
      [ui_text state ~ko:"! 이전 저장 결과 미확인 · " ~en:"! Earlier save unconfirmed · "
         ^ Terminal_text.single_line name;
       ui_text state ~ko:"  이전 저장은 성공했을 수 있습니다" ~en:"  The earlier save may have succeeded";
       ui_text state ~ko:"  재저장하면 현재 설정으로 같은 이름을 덮어씁니다"
         ~en:"  Saving again overwrites the same name with current settings";
       ui_text state ~ko:"  목록에 이름이 있어도 이전 저장의 성공은 확인되지 않습니다"
         ~en:"  A listed name alone does not confirm the earlier save"]
      @ description
      @ [ui_text state ~ko:"  전체 확인 후 Enter: 덮어쓰기 · Esc: 취소"
           ~en:"  After reviewing all rows, Enter: overwrite · Esc: cancel"]
    | Some (Restore_armed _ | Delete_armed _) | None -> [] in
  List.concat_map (fun text ->
    Masc_tui_text_block.lines text
    |> List.concat_map (fun line ->
      if String.equal line "" then [""]
      else Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols - 2)) line)) lines

let preset_confirmation_ready (state : state) =
  let _, cols = get_terminal_size () in
  match state.preset_armed, state.preset_confirmation_token, state.preset_confirmation_presented with
  | Some arm, Some token, Some progress ->
    let frame = progress.pcp_frame in
    frame.pcf_token == token && frame.pcf_arm = arm
    && frame.pcf_cols = cols && frame.pcf_language = state.ui_language
    && String.equal frame.pcf_description state.preset_save_draft_description
    && frame.pcf_source = state.preset_save_draft_source
    && frame.pcf_authority = state.workspace_authority
    && frame.pcf_reading == state.workspace_read_authority
    && frame.pcf_workspace = workspace_input_identity_of_server state.server_identity
    && frame.pcf_count = List.length (preset_confirmation_rows state ~cols)
    && progress.pcp_seen_through >= frame.pcf_count
  | (None, _, _) | (_, None, _) | (_, _, None) -> false

let preset_detail_lines (state : state) ~cols ~selected =
  let draft_workspace = match state.preset_armed with
    | Some (Save_workspace_armed _ | Save_armed _) -> []
    | Some (Restore_armed _ | Delete_armed _) | None ->
      if Option.is_some state.preset_save_draft && state.preset_save_draft_workspace = None then
        [ui_text state ~ko:"▸ 이름 초안 · 작업 공간 미지정"
           ~en:"▸ Name draft · workspace not selected";
         ui_text state ~ko:"  Enter로 저장할 작업 공간을 확인하세요"
           ~en:"  Press Enter to check the save workspace"; ""]
      else [] in
  let pending_saves = List.map (fun pending ->
    let label = match Atomic.get pending.psp_phase with
      | Preset_save_preparing -> ui_text state ~ko:"저장 준비 중" ~en:"Preparing save"
      | Preset_save_dispatching -> ui_text state ~ko:"저장 결과 대기" ~en:"Waiting for save result"
      | Preset_save_auth_refused ->
        ui_text state ~ko:"인증 거절 · 재확인 중" ~en:"Authentication refused · checking retry" in
    "▸ " ^ label ^ " · " ^ Terminal_text.single_line pending.psp_name)
      (workspace_preset_save_pending state) in
  let recovery = match recoverable_preset_save_commands state with
    | [] -> []
    | commands ->
      let index = state.preset_save_copy_cursor mod List.length commands in
      let name, _ = List.nth commands index in
      [Printf.sprintf
         (if state.ui_language = Lang_ko then "▸ 미전송 채팅 명령 %d개 · %s%s 복사"
          else "▸ Unsent chat commands: %d · %scopy %s")
         (List.length commands)
         (if state.ui_language = Lang_ko then
            (if Option.is_some state.preset_save_draft then "Esc 후 c: " else "c: ")
          else if Option.is_some state.preset_save_draft then "Esc then c: " else "c: ")
         (Terminal_text.single_line name);
       (if Option.is_some state.preset_save_draft then
          ui_text state ~ko:"  Esc 후 v: 미전송 원문 다시 보기"
            ~en:"  Esc then v: show unsent originals again"
        else ui_text state ~ko:"  v: 미전송 원문 다시 보기"
            ~en:"  v: show unsent originals again"); ""] in
  let save_issues = match visible_preset_save_receipts state with
    | [] -> []
    | issues ->
      [Printf.sprintf
         (if state.ui_language = Lang_ko then "▸ 저장 알림 %d개 · %s"
          else "▸ Save notices: %d · %s") (List.length issues)
         (if Option.is_some state.preset_save_draft then
            ui_text state ~ko:"Esc 후 x:최근 알림 숨기기" ~en:"Esc then x:hide latest"
          else ui_text state ~ko:"x:최근 알림 숨기기" ~en:"x:hide latest")]
      @ List.concat_map (fun receipt ->
          let lines = preset_save_receipt_lines ~ko:(state.ui_language = Lang_ko) receipt in
          match receipt.psr_request.psp_pane_observer, lines with
          | Some (_, Preset_save_shared), first :: rest ->
            first :: ui_text state ~ko:"  먼저 시작한 저장 결과 · 새 저장은 보내지 않았습니다"
              ~en:"  Earlier save result · no new save was sent" :: rest
          | (Some (_, Preset_save_original) | None), _ | _, [] -> lines) issues
      @ [""]
  in
  let save_issues = if pending_saves = [] then save_issues else pending_saves @ [""] @ save_issues in
  let unreadable = match state.presets_snapshot with
    | None -> []
    | Some snapshot -> snapshot.Tui_decode.pss_unreadable
  in
  let detail = Masc_tui_preset_text.detail_lines ~ko:(state.ui_language = Lang_ko) ~selected
    ~detail:(match selected with
      | None -> Masc_tui_fetched.Absent
      | Some m -> Masc_tui_fetched.view_for ~equal:String.equal
          state.preset_detail ~key:m.Tui_decode.pm_name)
    ~report:state.preset_report
  in
  let warning = match unreadable with
    | [] -> []
    | rows ->
      [Printf.sprintf
         (if state.ui_language = Lang_ko then "! 읽을 수 없는 프리셋 %d개 · 상세는 아래에"
          else "! Unreadable presets: %d · details below") (List.length rows)]
  in
  let failures = match unreadable, state.presets_error with
    | [], None -> []
    | rows, error ->
      [""; ui_text state ~ko:"▸ 읽기 오류" ~en:"▸ Read errors"]
      @ (match error with None -> [] | Some reason ->
          [ui_text state ~ko:"새로고침 실패 · " ~en:"Refresh failed · " ^ reason])
      @ List.map (fun (name, reason) -> "! " ^ name ^ " — " ^ reason) rows
  in
  let remaining = draft_workspace @ recovery @ save_issues @ warning @ detail @ failures
  |> List.concat_map (fun line ->
       if String.equal line "" then [""]
       else Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols - 2)) line)
  in
  match preset_confirmation_rows state ~cols with
  | [] -> remaining
  | rows -> rows @ [""] @ remaining

let preset_pane_heights (state : state) ~rows ~count ~presets_count =
  let error_rows = if Option.is_some state.presets_error then 1 else 0 in
  let entry_rows = if Option.is_some state.preset_save_draft then 1 else 0 in
  (* Top, title, divider, list/detail divider, bottom, and footer. The error
     is outside the selection list, so a retained list keeps its full slot. *)
  let combined_height = max 2 (rows - 6 - error_rows - entry_rows) in
  let list_height = min (max 1 presets_count) (min 8 (max 1 (combined_height / 3))) in
  let detail_rows = max 1 (combined_height - list_height) in
  let detail_height = Masc_tui_scroll.content_height ~rows:detail_rows ~chrome:0
      ~count ~preview_keep:None ~overflow_takes_row:true
  in
  list_height, detail_height

let presets_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let presets = match state.presets_snapshot with
    | None -> [] | Some snapshot -> snapshot.Tui_decode.pss_presets in
  let cursor = max 0 (min state.presets_cursor (List.length presets - 1)) in
  let selected = List.nth_opt presets cursor in
  let count = List.length (preset_detail_lines state ~cols ~selected) in
  let _, height = preset_pane_heights state
      ~rows:(Masc_tui_types.surface_body_rows state ~terminal_rows) ~count
      ~presets_count:(List.length presets) in
  count, height

let render_presets (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let presets =
    match state.presets_snapshot with
    | None -> []
    | Some snapshot -> snapshot.Tui_decode.pss_presets
  in
  let total = List.length presets in
  let cursor = max 0 (min state.presets_cursor (total - 1)) in
  let selected = List.nth_opt presets cursor in
  (* The same rule as the prompt registry's title: no count before a
     snapshot has arrived, and none after a first read that failed. *)
  let count_text =
    match state.presets_snapshot with
    | Some _ -> Printf.sprintf
        (if state.ui_language = Lang_ko then "%d개"
         else if total = 1 then "%d preset" else "%d presets") total
    | None -> (match state.presets_error with
        | None -> ui_text state ~ko:"읽는 중" ~en:"reading"
        | Some _ -> ui_text state ~ko:"읽기 실패" ~en:"read failed")
  in
  box_top buf cols;
  let reading = Printf.sprintf "%s%s%s" Ansi.dim count_text Ansi.reset in
  box_line buf cols
    (config_pane_title ~cols
       ~name:(screen_title (ui_text state ~ko:" MASC 시스템·프리셋" ~en:" MASC Presets"))
       ~reading state);
  box_divider buf cols;
  let detail = preset_detail_lines state ~cols ~selected in
  let count = List.length detail in
  let list_height, detail_height = preset_pane_heights state ~rows ~count ~presets_count:total in
  let preset_rows = list_height in
  let first = if cursor < preset_rows then 0 else cursor - preset_rows + 1 in
  (match state.presets_error with
   | Some detail ->
     box_line buf cols
       (Theme.bad () ^ "  " ^ fit_width (Terminal_text.single_line detail) (framed_inner_width cols - 2)
        ^ Ansi.reset)
   | None -> ());
  let drawn = ref 0 in
  (* A read that failed said "불러오는 중..." under its own failure row: the
     empty row asked only whether a snapshot had arrived. *)
  (match state.presets_snapshot, state.presets_error with
   | None, Some _ ->
       incr drawn;
       box_line_styled buf cols ~style:(Theme.recede ())
         (ui_text state ~ko:"  프리셋을 읽지 못했습니다" ~en:"  Could not read presets")
   | None, None ->
       incr drawn;
       box_line_styled buf cols ~style:(Theme.recede ())
         (ui_text state ~ko:"  프리셋을 읽는 중…" ~en:"  Loading presets…")
   | Some snapshot, (Some _ | None) ->
       Option.iter
         (fun line ->
           incr drawn;
           box_line_styled buf cols ~style:(Theme.recede ()) ("  " ^ line))
         (Masc_tui_preset_text.pane_empty_line ~ko:(state.ui_language = Lang_ko) snapshot));
  List.iteri
    (fun index (manifest : Tui_decode.preset_manifest) ->
      if index >= first && index < first + preset_rows then begin
        incr drawn;
        let name = manifest.Tui_decode.pm_name in
        let mark =
          match state.preset_armed with
          | Some (Restore_armed armed) when String.equal armed name ->
              Theme.warn () ^ "u" ^ Ansi.reset
          | Some (Delete_armed armed) when String.equal armed name ->
              Theme.bad () ^ "D" ^ Ansi.reset
          | Some (Restore_armed _ | Delete_armed _ | Save_armed _ | Save_workspace_armed _) | None -> " "
        in
        let label =
          row_with_field ~cols ~lead:(" " ^ mark ^ " ")
            ~field:(Masc_tui_preset_text.pane_row ~ko:(state.ui_language = Lang_ko)
                      ~max_cells:(max 1 (framed_inner_width cols - 3)) manifest)
            ~tail:""
        in
        if index = cursor then box_line buf cols (Theme.selection ^ label ^ Ansi.reset)
        else box_line buf cols label
      end)
    presets;
  for _ = 1 to list_height - !drawn do
    box_empty buf cols
  done;
  box_divider buf cols;
  let scroll = Masc_tui_scroll.normalize ~count ~height:detail_height state.config_scroll in
  let confirmation = match state.preset_armed, state.preset_confirmation_token with
    | Some (Save_armed _ | Save_workspace_armed _ as arm), Some token ->
      let count = List.length (preset_confirmation_rows state ~cols) in
      Some { pcf_token = token; pcf_arm = arm; pcf_cols = cols
           ; pcf_language = state.ui_language; pcf_authority = state.workspace_authority
           ; pcf_description = state.preset_save_draft_description
           ; pcf_source = state.preset_save_draft_source
           ; pcf_reading = state.workspace_read_authority
           ; pcf_workspace = workspace_input_identity_of_server state.server_identity; pcf_count = count
           ; pcf_first = scroll; pcf_last = min count (scroll + detail_height) }
    | Some (Restore_armed _ | Delete_armed _), _ | None, _ | _, None -> None in
  let detail_window = Rows.of_list ~first:scroll ~height:detail_height detail in
  for index = 0 to detail_height - 1 do
    match Rows.at detail_window (scroll + index) with
    | Some line -> box_line buf cols ("  " ^ line)
    | None -> box_empty buf cols
  done;
  if count > detail_height then
    box_line_styled buf cols ~style:(Theme.recede ())
      (Printf.sprintf "  [%s %s]" (ui_text state ~ko:"행" ~en:"lines")
         (Masc_tui_scroll.window_text ~scroll ~height:detail_height count));
  (match state.preset_save_draft with
   | Some draft ->
     box_line buf cols
       (row_with_field ~cols
          ~lead:(Theme.info () ^ ui_text state ~ko:"  이름: " ~en:"  Name: " ^ Ansi.reset)
          ~field:(Terminal_text.single_line draft)
          ~tail:(Ansi.dim ^ (match state.preset_armed with
            | Some (Save_armed _) ->
              if preset_confirmation_ready state then
                ui_text state ~ko:"  Enter:덮어쓰기  Esc:취소"
                  ~en:"  Enter:overwrite  Esc:cancel"
              else ui_text state ~ko:"  Home 후 PgDn:경고 확인  Esc:취소"
                  ~en:"  Home then PgDn:read warning  Esc:cancel"
            | Some (Save_workspace_armed _) ->
              if preset_confirmation_ready state then
                ui_text state ~ko:"  Enter:여기로 진행  Esc:취소"
                  ~en:"  Enter:continue here  Esc:cancel"
              else ui_text state ~ko:"  Home 후 PgDn:경로 확인  Esc:취소"
                  ~en:"  Home then PgDn:read paths  Esc:cancel"
            | Some (Restore_armed _ | Delete_armed _) | None ->
              ui_text state ~ko:"  Enter:저장  Esc:취소" ~en:"  Enter:save  Esc:cancel") ^ Ansi.reset))
   | None -> ());
  let recovery_in_slot = recovery_box_bottom state buf ~cols in
  Buffer.add_string buf
    (footer_line ~recovery_in_slot state ~max_cells:cols
       ~hints:(match state.preset_save_draft with
         | Some _ ->
           ui_text state
             ~ko:"Enter:진행  Esc:닫기  Home/End:처음/끝  PgUp/PgDn:상세"
             ~en:"Enter:continue  Esc:close  Home/End:edges  PgUp/PgDn:details"
         | None ->
           Masc_tui_keys.footer_hints_config ~lang:state.ui_language
             ~pane:Config_presets));
  finish_surface state ~clamped:(Preset_detail_scroll (scroll, confirmation))
    ~surface_key:"presets" ~rows:terminal_rows ~cols buf

let render_themes (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let all_entries = Theme_choice.entries () in
  let dark_count =
    List.fold_left
      (fun count (entry : Theme_choice.entry) ->
        if not entry.light then count + 1 else count)
      0 all_entries
  in
  let light_count = List.length all_entries - dark_count in
  let entries =
    match state.theme_filter with
    | `All -> all_entries
    | `Dark ->
        List.filter
          (fun (entry : Theme_choice.entry) -> not entry.light)
          all_entries
    | `Light ->
        List.filter
          (fun (entry : Theme_choice.entry) -> entry.light)
          all_entries
  in
  let native_count =
    List.fold_left
      (fun count (entry : Theme_choice.entry) ->
        if entry.lifted = 0 then count + 1 else count)
      0 entries
  in
  let show_sample = rows >= 20 in
  let chrome_rows = if show_sample then 11 else 8 in
  let content_height = max 1 (rows - chrome_rows) in
  let cursor =
    max 0 (min state.theme_cursor (max 0 (List.length entries - 1)))
  in
  let scroll = max 0 (cursor - content_height + 1) in
  let lift_on = Masc_tui_theme.lift_is_enabled () in
  let name_width = theme_name_width ~cols in
  box_top buf cols;
  box_line buf cols
    (config_pane_title ~cols
       ~name:(screen_title (ui_text state ~ko:" MASC 시스템·테마" ~en:" MASC Themes"))
       ~reading:
         (Printf.sprintf (if state.ui_language = Lang_ko then "%s테마 %d개 · 원래 대비 통과 %d개%s" else "%s%d themes · %d native-pass%s") Ansi.dim
            (List.length entries) native_count Ansi.reset)
       state);
  box_divider buf cols;
  box_line_styled buf cols ~style:Ansi.dim
    ("  " ^ fit_width (ui_text state ~ko:"테마" ~en:"theme") (name_width + 2) ^ " "
     ^ fit_width (ui_text state ~ko:"색상" ~en:"colours") 16 ^ "  "
     ^ fit_width (ui_text state ~ko:"배경" ~en:"page") 9 ^ " "
     ^ fit_width (ui_text state ~ko:"대비" ~en:"contrast") 12)
  ;
  (* The key the way the footer spells it, then the three filters as the
     product's tab strip draws a choice: the one in force marked. It read
     "Filter: [f] [All 53] · Dark 40 · Light 13", where the brackets meant a
     key once and the chosen filter once, on the same row. *)
  let explanation =
    if cols >= 92 then
      "  ·  "
      ^ (if lift_on then ui_text state ~ko:"원래 7/7=보정 없음 · 보정 N/7=N개 밝힘" ~en:"native 7/7=no lift · lift N/7=N raised"
         else ui_text state ~ko:"원래 7/7=모두 통과 · 부족 N/7=4.5:1 미달" ~en:"native 7/7=all pass · N/7 low=below 4.5:1")
    else ""
  in
  let filter_tag =
    let chip label filter count =
      (label ^ " " ^ string_of_int count, state.theme_filter = filter, filter)
    in
    Ansi.dim ^ ui_text state ~ko:"f:필터  " ~en:"f:filter  " ^ Ansi.reset
    ^ tab_strip
        ~width:
          (tab_strip_width ~cols ~before:(ui_text state ~ko:"  f:필터  " ~en:"  f:filter  ") ~after:explanation)
        ~press:(fun filter text -> pressable (Press_theme_filter filter) text)
        [ chip (ui_text state ~ko:"전체" ~en:"All") `All (List.length all_entries)
        ; chip (ui_text state ~ko:"어둡게" ~en:"Dark") `Dark dark_count
        ; chip (ui_text state ~ko:"밝게" ~en:"Light") `Light light_count
        ]
  in
  box_line buf cols ("  " ^ filter_tag ^ Ansi.dim ^ explanation ^ Ansi.reset);
  let chosen = state.theme_choice in
  List.iteri
    (fun index (entry : Theme_choice.entry) ->
      if index >= scroll && index < scroll + content_height then begin
        let picked =
          match chosen with
          | Some name -> String.equal name entry.name
          | None -> false
        in
        let swatch = Theme_choice.swatch_cells entry in
        let row =
          Printf.sprintf "  %s %s " (if picked then chosen_mark else " ")
            (fit_width (Terminal_text.single_line entry.name) name_width)
          ^ swatch
          ^ "  "
          ^ fit_width (if entry.light then ui_text state ~ko:"밝음" ~en:"light"
                       else ui_text state ~ko:"어두움" ~en:"dark") 9
          ^ " "
          ^ fit_width
              (if state.ui_language = Lang_en then Theme_choice.contrast_status ~lift_on entry
               else if entry.lifted = 0 then Printf.sprintf "원래 %d/%d" entry.measured entry.measured
               else if lift_on then Printf.sprintf "보정 %d/%d" entry.lifted entry.measured
               else Printf.sprintf "부족 %d/%d" entry.lifted entry.measured) 12
        in
        if index = cursor then box_line_selected buf cols (Masc_tui_theme.strip_sgr row)
        else box_line buf cols row
      end)
    entries;
  let drawn = min content_height (List.length entries) in
  for _ = drawn to content_height - 1 do
    box_empty buf cols
  done;
  if show_sample then begin
    box_divider buf cols;
    box_line buf cols
      (Printf.sprintf (if state.ui_language = Lang_ko then "  예시: %s● 정상%s  %s▲ 주의%s  %s× 오류%s  %s◆ 정보%s  %s@keeper%s  %s⚡ 도구%s"
                       else "  Sample: %s● Ok%s  %s▲ Warn%s  %s× Bad%s  %s◆ Info%s  %s@keeper%s  %s⚡ tool%s")
         (Theme.ok ()) Ansi.reset
         (Theme.warn ()) Ansi.reset
         (Theme.bad ()) Ansi.reset
         (Theme.info ()) Ansi.reset
         (Theme.keeper_origin ()) Ansi.reset
         (Theme.tool_origin ()) Ansi.reset);
    box_line buf cols
      (Printf.sprintf "  Syntax: %slet%s x = %s\"val\"%s in %s123%s  %s(+gain)%s  %s(-loss)%s"
         Theme.Syntax.keyword Ansi.reset
         Theme.Syntax.string Ansi.reset
         Theme.Syntax.code_number Ansi.reset
         Theme.Syntax.diff_added Ansi.reset
         Theme.Syntax.diff_removed Ansi.reset);
  end;
  let lang_toggle =
    pressable Press_ui_language
      (ui_text state
         ~ko:("[UI 언어: " ^ ui_language_label state.ui_language ^ " · 클릭 또는 :language 전환]")
         ~en:("[UI Language: " ^ ui_language_label state.ui_language ^ " · click or :language]"))
  in
  box_line_styled buf cols ~style:Ansi.dim
    (* What is in force, then its keys in the footer's spelling. [f] is on
       the filter row above, so it is not said twice. *)
    (match chosen with
     | None ->
       ui_text state ~ko:"  터미널 색상 · Enter:테마 선택 · " ~en:"  terminal colours · Enter:pick a theme · " ^ lang_toggle
     | Some name ->
       Printf.sprintf (if state.ui_language = Lang_ko then "  %s · Enter:다른 테마 선택  x:터미널 색상 · %s"
                       else "  %s · Enter:pick another  x:follow terminal · %s")
         (Terminal_text.single_line name) lang_toggle);
  let recovery_in_slot = recovery_box_bottom state buf ~cols in
  Buffer.add_string buf
    (footer_line ~recovery_in_slot state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_config ~lang:state.ui_language ~pane:state.config_pane));
  finish_surface state ~surface_key:"themes" ~rows:terminal_rows ~cols buf

(* Where the config file being read lives, for the title row beside the strip
   that already names the file. Said from the server's masc root, which is the
   same for every screen in the session and named on the Config pane's identity
   row. Until the server has said where its root is, the whole path is the only
   honest reading. *)
let config_path_note (state : state) =
  match state.runtime_config_view, state.runtime_config_view_error with
  | Some reading, _ ->
      let path = Terminal_text.single_line reading.rcv_path in
      let shown =
        match state.server_identity with
        | Some identity ->
            path_from_root ~root:(Canonical_path.to_string identity.Tui_decode.sid_masc_root) path
        | None -> path
      in
      Ansi.dim ^ shown ^ Ansi.reset
  | None, Some _ -> ""
  | None, None ->
      Ansi.dim ^ title_missing_reading ~error:None ^ Ansi.reset

(* A provider id such as [codex_727e6d05] does not say which account it is,
   and one account can sit under several ids. The Models pane names the
   account from the account-email reading: a short label beside every
   provider id, and the whole email on the selected binding. Drawing and
   scroll arithmetic below use these same rows and these same detail lines. *)
let config_models_drawn_rows (state : state) =
  List.map
    (fun (row : Masc_tui_model_runtime_table.row) ->
      match fst (models_source_account_reading ~provider:row.provider state.runtime_config_view) with
      | Some email ->
          { row with
            account_label =
              Some
                (Masc_tui_model_runtime_table.account_label_of_email
                   (Terminal_text.single_line email))
          }
      | None -> row)
    state.config_models_rows

(* How many Keepers already sit on the selected login is the reading that was
   missing on 2026-10-08, when fourteen were moved onto one account. Only a
   complete roster is counted: a partial one would read as fewer Keepers. *)
let config_models_detail (state : state) (row : Masc_tui_model_runtime_table.row) =
  let account_email, account_notes =
    models_source_account_reading ~provider:row.provider state.runtime_config_view in
  let keepers =
    match state.keeper_roster with
    | Masc_tui_keeper_control.Roster_complete rows ->
        Some
          (Masc_tui_model_runtime_table.keepers_on_login
             ~rows:state.config_models_rows
             ~assignments:
               (List.map
                  (fun (keeper : Masc.Tui_decode.keeper_runtime) ->
                    keeper.kr_name, keeper.kr_runtime_id)
                  rows)
             row)
    | Masc_tui_keeper_control.Roster_unobserved
    | Masc_tui_keeper_control.Roster_partial _
    | Masc_tui_keeper_control.Roster_invalid _ -> None
  in
  account_notes @ Masc_tui_model_runtime_table.detail_lines ?account_email ?keepers row

let selected_model_reading (state : state) =
  Option.bind (List.nth_opt state.config_models_rows state.config_models_cursor)
    (fun (row : Masc_tui_model_runtime_table.row) ->
      let sections =
        (match state.runtime_config_view_error with
         | None -> [] | Some reason ->
             [{Masc_tui_detail_reading.heading="Refresh failed · retained reading";body=reason}])
        @ (match state.runtime_config_view with
           | None -> [] | Some reading ->
               [{Masc_tui_detail_reading.heading=
                   ui_text state ~ko:"1. 설정 출처 · 파일 경로" ~en:"1. Source";
                 body=reading.rcv_path}])
        @ [{Masc_tui_detail_reading.heading=
              ui_text state ~ko:"2. 계정 · 모델 바인딩 및 배정 키퍼"
                ~en:"2. Account / Model & Keepers";
            body=String.concat "\n" (config_models_detail state row)}] in
      Some (Masc_tui_detail_reading.create
        ~title:("System / Models / " ^ row.provider ^ " / " ^ row.model) sections))

(* The model knobs sit in different tables -- [reasoning-effort] and
   [temperature] under [models.NAME], [max-tokens] under
   [PROVIDER.NAME] -- and runtime.toml is 2,300 lines, so reading it top to
   bottom never puts them side by side. On 2026-08-29 nine of ten
   ollama_cloud bindings carried neither; a request with no reasoning_effort
   has Ollama turn thinking on by itself, and one keeper spent a turn
   producing 2,000 characters of reasoning and no answer. This pane is the
   same source the runtime.toml pane shows, arranged so a missing knob is a
   column and not an absence.

   Structured edits and copies use the runtime.toml preview-checked writer. *)
let render_config_models (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows_avail = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  let path_note = config_path_note state in
  box_line buf cols
    (config_pane_title ~cols
       ~name:(screen_title (ui_text state ~ko:" MASC 시스템·모델" ~en:" MASC Models"))
       ~note:path_note state);
  box_divider buf cols;
  let content_height = max 1 (rows_avail - 5) in
  (match state.runtime_model_form with
   | Some form ->
       let lines = Masc_tui_model_form.rows ~input_locked:(runtime_form_input_locked state)
           ~width:(max 1 (framed_inner_width cols - 2)) ~height:content_height form in
       List.iter (fun line -> box_line buf cols ("  " ^ Terminal_text.single_line line)) lines;
       for _ = List.length lines + 1 to content_height do box_empty buf cols done
   | None when Option.is_some state.runtime_model_jump ->
       box_line buf cols (Ansi.dim ^ "  Loading selected account/model settings… Esc cancels" ^ Ansi.reset);
       for _ = 2 to content_height do box_empty buf cols done
   | None -> match config_models_read_error state, state.runtime_config_view with
   | Some detail, _ ->
       box_line buf cols
         (Theme.bad () ^ "  " ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset);
       for _ = 2 to content_height do
         box_empty buf cols
       done
   | None, None ->
       box_line buf cols (Ansi.dim ^ "  (loading\xe2\x80\xa6)" ^ Ansi.reset);
       for _ = 2 to content_height do
         box_empty buf cols
       done
   | None, Some _ ->
       let drawn_rows = config_models_drawn_rows state in
       let detail =
         List.nth_opt state.config_models_rows state.config_models_cursor
         |> Option.map (config_models_detail state)
         |> Option.value ~default:[]
       in
       (* Keep the explanation attached to the selected row. Five rows are
          enough to name both owning sections without adding another modal or
          another editor path. On a very short terminal the table still keeps
          one visible row. *)
       let detail_height = min (List.length detail) (max 0 (content_height - 2)) in
       let table_height =
         max 1 (content_height - detail_height - if detail_height > 0 then 1 else 0)
       in
       (* [box_line] spends the frame's margin either side, which
          [framed_inner_width] already leaves out, and this pane adds two
          more for its own indent. A
          width that ignores them wraps the last column onto its own row,
          which reads as a blank value. The pane is the truth the table is
          fitted against: handing the table a floor of 40 on a terminal
          narrower than that drew mandatory readings into cells the frame
          then cut (#28905 review). [render] uses the pane to choose the
          stacked layout before that cut can eat a value. *)
       let table =
         Masc_tui_model_runtime_table.render
           ~width:(max 40 (framed_inner_width cols - 2 - 2))
           ~pane:(max 1 (framed_inner_width cols - 2 - 2))
           drawn_rows
       in
       let total = List.length table in
       (* The cursor walks bindings, not lines. In table mode line 0 is the
          header, so binding [i] is line [i+1] and that is what the window
          follows. In stacked mode the item's first line is the binding's
          line: the cursor still selects the same record it did before the
          resize, which is the whole point of the transition. *)
       let pane_width = max 1 (framed_inner_width cols - 2 - 2) in
       let table_mode =
         Masc_tui_model_runtime_table.fits ~width:pane_width drawn_rows
       in
       let starts =
         if table_mode then []
         else
           Masc_tui_model_runtime_table.stacked_item_starts ~pane:pane_width
             drawn_rows
       in
       let cursor_line =
         if table_mode then state.config_models_cursor + 1
         else
           List.nth_opt starts state.config_models_cursor
           |> Option.value ~default:0
       in
       (* The last line of the selected item: items are separated by one
          blank line and the trailing separator is dropped. In table mode
          the binding is the single line itself. *)
       let cursor_stop =
         if table_mode then cursor_line
         else
           match List.nth_opt starts (state.config_models_cursor + 1) with
           | Some next -> next - 2
           | None -> total - 1
       in
       let max_scroll = max 0 (total - table_height) in
       (* The window follows the selected item rather than the other way
          round: an item the frame does not draw at all is a selection the
          reader cannot see, and [e] would act on it blind. While some line
          of it is shown the reader's scroll stands, so a stacked item's
          body -- the fields below its first line -- stays reachable on a
          short pane (#41026 review). *)
       let scroll = max 0 (min state.config_scroll max_scroll) in
       let scroll =
         min max_scroll
           (Masc_tui_scroll.ensure_span_visible ~start:cursor_line
              ~stop:cursor_stop ~height:table_height scroll)
       in
       (* The mark rides the first line of the item that is on screen. *)
       let marked_line = max cursor_line scroll in
       (* The window is cut at the scroll the cursor settled, not the stored
          one. Cut before, a cursor that moved further than a row -- a page
          key, a list that shrank -- drew its rows outside the window, and
          they came out blank. *)
       let table_window = Rows.of_list ~first:scroll ~height:table_height table in
       (* Row 0 of [table] is the header in table mode, so a cursor over the
          data rows is one lower than the line it marks. Stacked mode has no
          header: line 0 is the first binding's item. *)
       for i = 0 to table_height - 1 do
         let index = scroll + i in
         match Rows.at table_window index with
         | Some line ->
             let marked =
               if table_mode && index = 0 then "  " ^ Ansi.bold ^ line ^ Ansi.reset
               else if index = marked_line then Ansi.bold ^ Theme.info () ^ "> " ^ line ^ Ansi.reset
               else "  " ^ line
             in
             box_line buf cols marked
         | None -> box_empty buf cols
       done;
       if detail_height > 0
       then (
         box_divider buf cols;
         List.iteri
           (fun i line ->
             if i < detail_height
             then (
               let line =
                 "  " ^ fit_width (Terminal_text.single_line line) (max 1 (framed_inner_width cols - 3))
               in
               if i = 0
               then box_line_styled buf cols ~style:(Ansi.bold ^ Theme.info ()) line
               else box_line_styled buf cols ~style:(Theme.recede ()) line))
           detail));
  let recovery_in_slot = recovery_box_bottom state buf ~cols in
  Buffer.add_string buf
    (footer_line ~recovery_in_slot state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_config ~lang:state.ui_language ~pane:Config_models));
  finish_surface state ~surface_key:"config_models" ~rows:terminal_rows ~cols buf

(* The models pane's scroll bound. The document is the table when it fits and
   the stacked items when it does not, which only the pane width decides, so
   the pane owns the count the keys move through (as Tools and Memory do).
   Counting the table rows let the keys stop short of the stacked fields
   (#41026 review). The chrome mirrors [render_config_models]: its own five
   rows plus the detail block and its rule. *)
let config_models_scrolled (state : state) : scrolled =
  let chrome_error = listing_chrome ~error:state.runtime_config_view_error in
  match state.runtime_config_view_error, state.runtime_config_view with
  | Some _, _ | None, None ->
      { sc_count = 0
      ; sc_chrome = chrome_error
      ; sc_overflow_takes_row = false
      ; sc_preview_keep = None
      }
  | None, Some _ ->
      let terminal_rows, cols = get_terminal_size () in
      let pane = max 1 (framed_inner_width cols - 2 - 2) in
      let rows = config_models_drawn_rows state in
      let document =
        Masc_tui_model_runtime_table.render ~width:(max 40 pane) ~pane rows
      in
      let content_height =
        max 1 (Masc_tui_types.surface_body_rows state ~terminal_rows - 5)
      in
      let detail_len =
        List.nth_opt rows state.config_models_cursor
        |> Option.map (fun r -> List.length (config_models_detail state r))
        |> Option.value ~default:0
      in
      let detail_height = min detail_len (max 0 (content_height - 2)) in
      { sc_count = List.length document
      ; sc_chrome = 5 + detail_height + if detail_height > 0 then 1 else 0
      ; sc_overflow_takes_row = false
      ; sc_preview_keep = None
      }

(* Whether the pane draws stacked items at the current width. *)
let config_models_stacked (state : state) =
  let _, cols = get_terminal_size () in
  not
    (Masc_tui_model_runtime_table.fits ~width:(max 1 (framed_inner_width cols - 2 - 2))
       (config_models_drawn_rows state))

let config_metadata_style = function
  | Masc_tui_runtime_config_view.Neutral -> Theme.recede ()
  | Good -> Theme.ok () | Warning -> Theme.warn () | Bad -> Theme.bad ()

(* Paths and build facts have separate rows so the server identity cannot
   spend every path cell on a narrow terminal. Use these same rows when
   budgeting the source viewport and keeping the cursor visible. *)
let config_identity_rows ~cols (state : state) =
  let width = framed_inner_width cols in
  let rows = match state.server_identity with
  | None -> [Printf.sprintf "  port :%d · server identity unread" state.port]
  | Some identity ->
      let base =
        Terminal_text.single_line (Canonical_path.to_string identity.Tui_decode.sid_base_path) in
      let masc =
        Terminal_text.single_line (Canonical_path.to_string identity.Tui_decode.sid_masc_root) in
      let masc =
        let prefix = base ^ "/" in
        let prefix_len = String.length prefix in
        if String.length masc > prefix_len && String.starts_with ~prefix masc then
          "<base>/" ^ String.sub masc prefix_len (String.length masc - prefix_len)
        else masc
      in
      let room = max 0 (width - Message_layout.display_width "  base    masc ") in
      let base_cells = Message_layout.display_width base in
      let masc_cells = Message_layout.display_width masc in
      let base, masc =
        if base_cells + masc_cells <= room then base, masc
        else
          (* Keep a shorter path whole and give the other the remaining
             cells. When both are long, preserve both deciding tails. *)
          let half = room / 2 in
          let base_room, masc_room =
            if base_cells <= half then base_cells, room - base_cells
            else if masc_cells <= half then room - masc_cells, masc_cells
            else half, room - half
          in
          Message_layout.fit_middle base_room base,
          Message_layout.fit_middle masc_room masc
      in
      let server =
        "server " ^ String.concat " · "
          [ Terminal_text.single_line
              ("v" ^ identity.sid_version ^ " "
               ^ Masc_tui_footer.short_commit identity.sid_binary_commit);
            Printf.sprintf ":%d" state.port;
            binary_age_text identity.sid_binary_commit_age_s ]
      in
      Printf.sprintf "  base %s   masc %s" base masc
      :: (Masc_tui_text_block.rows ~max_cells:(max 1 (width - 2)) server
          |> List.map (fun line -> "  " ^ line)) in
  match state.workspace_identity with
  | Masc_tui_types.Workspace_identity_match_unconfirmed reason ->
      (* One row. A failed /health can carry a long transport body, such as a
         proxy's HTML page; wrapped whole, it filled the [Fits] body and hid
         the last confirmed identity and the configuration below it. The
         reason is cut in the middle so its start and its end stay readable. *)
      let max_cells = max 1 (width - 2) in
      let lead = "(server identity unconfirmed: " in
      let trail = "; last confirmed below)" in
      let reason = Terminal_text.single_line reason in
      let room =
        max_cells - Message_layout.display_width lead - Message_layout.display_width trail
      in
      let notice =
        if room > 0 then lead ^ Message_layout.truncate_middle room reason ^ trail
        else Message_layout.truncate_middle max_cells (lead ^ reason ^ trail)
      in
      system_subnav_row state :: ("  " ^ notice) :: rows
  | Workspace_identity_unread | Workspace_identity_match
  | Workspace_identity_mismatch _ ->
      system_subnav_row state :: rows

(* What the runtime.toml body spends above the source: the server identity,
   one row per metadata line, and the rule under them. *)
let config_heading_rows ~cols (state : state) =
  List.length (config_identity_rows ~cols state)
  + List.length (config_metadata_summary state) + 1
  + List.length (runtime_config_edit_lines ~cols state)
  + (if Option.is_none state.runtime_account_form
        && Option.is_none state.memory_recall_form
        && Option.is_some state.runtime_config_view_error then 1 else 0)

(* The source rows the frame shows, and the height the cursor keeps itself
   inside. One number for both: the frame is [surface_chrome]'s, so what it
   spends is [surface_chrome_rows] and the heading above, not a literal. *)
let config_content_height (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  max 1
    (Masc_tui_types.surface_body_rows state ~terminal_rows
     - surface_chrome_rows - config_heading_rows ~cols state)

let runtime_config_status_scroll_limit state ~terminal_rows ~cols =
  let room = max 1 (Masc_tui_types.surface_body_rows state ~terminal_rows - 5) in
  max 0 (List.length (runtime_config_status_lines state ~cols) - room)

let render_runtime_config_status state =
  let terminal_rows, cols = get_terminal_size () in
  surface_chrome ~overflow:Paged_by_cursor state ~terminal_rows ~cols
    ~surface_key:"config-status"
    ~title:
      (screen_title
         (ui_text state
            ~ko:" MASC 시스템 / 설정 검증 및 적용 상태"
            ~en:" MASC System / runtime.toml status"))
    ~hints:"j/k:scroll  PgUp/PgDn:page  v/Esc:source  r:reload"
    ~body:(fun ~budget c ->
      let lines = runtime_config_status_lines state ~cols in
      let scroll = min state.runtime_config_status_scroll (max 0 (List.length lines - budget)) in
      lines |> List.filteri (fun i _ -> i >= scroll && i < scroll + budget)
      |> List.iter (fun (tone, text) -> c.push_styled ~style:(config_metadata_style tone) ("  " ^ text)))

(* What voice resolved to, and on which microphone.

   Three facts an operator cannot get from runtime.toml. Whether the config
   loaded at all: a section that does not parse reads the same as one that was
   never written, and telling those apart took six days once. Which STT
   endpoint answers first, since a local server that is down falls back to a
   paid one silently. And the input device, because a capture that comes back
   empty is more often the wrong microphone than a threshold. *)
(* The wizard screen. The questions, their order and the completeness rule are
   Voice_wizard's; what is drawn here is only how a terminal shows them. *)
(* The voice pane and its wizard: a fixed head and footer around lines read
   through [state.config_scroll]. Both drew every line into the surface budget,
   and [finish_surface] keeps the leading rows of a frame that runs over, so a
   long endpoint list or probe report lost its tail and then its footer with no
   key that could bring them back. The offset is clamped here, against the
   lines actually laid out, and reported back as [Voice_scroll]. *)
let finish_voice_surface (state : state) ~terminal_rows ~cols ~head ~body ~hints =
  let lines = frame_lines body in
  let height =
    (* The rows under the head, less the box bottom and the footer. *)
    max 1
      (Masc_tui_types.surface_body_rows state ~terminal_rows
       - List.length (frame_lines head) - 2)
  in
  let scroll =
    Masc_tui_scroll.normalize ~count:(List.length lines) ~height state.config_scroll
  in
  let buf = Buffer.create (Buffer.length head + Buffer.length body + 256) in
  Buffer.add_buffer buf head;
  List.iteri
    (fun index line ->
      if index >= scroll && index < scroll + height then begin
        Buffer.add_string buf line;
        Buffer.add_char buf '\n'
      end)
    lines;
  (* The rows the reading does not fill. Without them the box bottom and the
     footer sit under the last line drawn, wherever that lands, and the pane
     ends in the middle of the frame with blank rows under it. It is the same
     hand-drawn frame the cheat sheet and the answering overlay were moved off
     for the same reason.

     How many were drawn is the window, not a tally of it: [normalize] holds
     [scroll] at or under [count - height], so the loop above draws exactly
     this many. *)
  let drawn = min height (max 0 (List.length lines - scroll)) in
  for _ = drawn + 1 to height do
    box_empty buf cols
  done;
  let recovery_in_slot = recovery_box_bottom state buf ~cols in
  Buffer.add_string buf (footer_line ~recovery_in_slot state ~max_cells:cols ~hints);
  finish_surface state ~clamped:(Voice_scroll scroll) ~surface_key:"voice"
    ~rows:terminal_rows ~cols buf
;;

(* Voice metadata is a literal document. Wrap before boxing, so the boxed
   rows counted by [finish_voice_surface] include every endpoint and draft
   value rather than the clipped prefix of each logical line. *)
let voice_body_rows cols content =
  let width = framed_inner_width cols in
  if Message_layout.display_width content <= width then [ content ]
  else Message_layout.wrap_words ~max_cells:width content
;;

let voice_body_line buf cols content =
  List.iter (fun row -> box_line buf cols (row ^ Ansi.reset))
    (voice_body_rows cols content)
;;

let voice_body_line_styled buf cols ~style content =
  List.iter (box_line_styled buf cols ~style) (voice_body_rows cols content)
;;

let render_voice_wizard (state : state) (session : Masc_tui_voice_wizard_session.voice_wizard_session) =
  let terminal_rows, cols = get_terminal_size () in
  let head = Buffer.create 256 in
  let buf = Buffer.create 2048 in
  let field name value =
    voice_body_line buf cols
      (Printf.sprintf "  %s%s%s %s" Ansi.dim (fit_width name 12) Ansi.reset (Terminal_text.single_line value))
  in
  let draft = session.vws_draft in
  let side =
    match draft.Voice_wizard.section with
    | Voice_setup.Tts -> ui_text state ~ko:"음성 출력" ~en:"speech out"
    | Voice_setup.Stt -> ui_text state ~ko:"음성 입력" ~en:"speech in"
  in
  let shown value = if String.trim value = "" then Masc_tui_theme.Glyph.no_value else value in
  let steps = Voice_wizard.steps draft in
  let position =
    let rec index n = function
      | [] -> None
      | step :: rest -> if step = session.vws_step then Some n else index (n + 1) rest
    in
    match index 1 steps with
    | Some n -> Printf.sprintf "%d/%d" n (List.length steps)
    | None -> Masc_tui_theme.Glyph.no_value
  in
  let step_prompt = match state.ui_language with
    | Lang_en -> Voice_wizard.step_prompt session.vws_step
    | Lang_ko -> (match session.vws_step with
      | Voice_wizard.Section -> "음성 출력과 입력 중 어느 쪽인가요?"
      | Voice_wizard.Provider -> "어떤 공급자를 사용하나요?"
      | Voice_wizard.Name -> "엔드포인트 이름은 무엇인가요? 나중에 이 이름으로 선택합니다."
      | Voice_wizard.Address -> "엔드포인트 주소는 무엇인가요?"
      | Voice_wizard.Credential -> "키가 든 환경 변수 이름은 무엇인가요? 키가 필요 없는 로컬 서버라면 비워 두세요."
      | Voice_wizard.Model -> "어떤 모델을 사용하나요? whisper-cli는 읽을 ggml 파일 경로를 입력합니다."
      | Voice_wizard.Voice -> "음성 출력의 기본 목소리는 무엇인가요?"
      | Voice_wizard.Review -> "변경할 내용을 확인하세요.")
  in
  let gap_message gap = match state.ui_language with
    | Lang_en -> Voice_wizard.gap_message gap
    | Lang_ko -> (match gap with
      | Voice_wizard.Endpoint_id_is_blank -> "나중에 선택할 엔드포인트 이름이 필요합니다"
      | Voice_wizard.Address_is_blank -> "연결할 엔드포인트 주소가 필요합니다"
      | Voice_wizard.Credential_variable_is_blank -> "키가 든 환경 변수 이름이 필요합니다"
      | Voice_wizard.Model_is_blank -> "이 엔드포인트의 모델이 필요합니다 · 다른 엔드포인트의 모델은 유지됩니다"
      | Voice_wizard.Voice_is_blank -> "음성 출력의 기본 목소리가 필요합니다")
  in
  box_top head cols;
  box_line head cols
    (config_pane_title ~cols ~name:(screen_title (ui_text state ~ko:" MASC 음성 · 설정" ~en:" MASC Voice · setup")) state);
  voice_body_line buf cols "";
  voice_body_line buf cols
    (Printf.sprintf "  %s%s %s%s  %s" Ansi.dim (ui_text state ~ko:"단계" ~en:"step") position Ansi.reset step_prompt);
  voice_body_line buf cols "";
  (* The answer being given. A closed set shows its current value and the keys
     that walk it; a text field shows what has been typed, with a cursor so an
     empty field is visibly a field. *)
  (match session.vws_step with
   | Voice_wizard.Section ->
     box_line head cols
       (Printf.sprintf "    %s%s%s   %s%s%s" Ansi.bold side
          Ansi.reset Ansi.dim (ui_text state ~ko:"←/→ 또는 Space로 전환" ~en:"←/→ or space to switch") Ansi.reset)
   | Voice_wizard.Provider ->
     box_line head cols
       (Printf.sprintf "    %s%s%s   %s%s%s" Ansi.bold
          (Voice_wizard.provider_label draft.Voice_wizard.provider)
          Ansi.reset Ansi.dim (ui_text state ~ko:"←/→ 또는 Space로 전환" ~en:"←/→ or space to switch") Ansi.reset)
   | Voice_wizard.Review ->
     (match Voice_wizard.gaps draft with
      | [] ->
        let notice = match session.vws_save with
          | Masc_tui_voice_wizard_session.Save_sending _ ->
            ui_text state ~ko:"저장 요청 중 · 화면을 닫아도 요청은 계속됩니다"
              ~en:"Save in progress · closing this screen does not cancel it"
          | Save_unanswered _ ->
            ui_text state ~ko:"이전 저장 결과 확인 중" ~en:"Checking the previous save result"
          | Save_needs_reopen _ ->
            ui_text state ~ko:"저장 결과를 확인할 수 없음 · 닫고 설정을 다시 여세요"
              ~en:"Save result unconfirmed · close and reopen settings"
          | Save_not_sent | Save_probing _ | Save_settled ->
            ui_text state ~ko:"Enter로 저장" ~en:"Enter saves this"
        in
        voice_body_line buf cols (Printf.sprintf "    %s%s%s" Ansi.bold notice Ansi.reset)
      | gaps ->
        List.iter
          (fun gap ->
            voice_body_line_styled buf cols ~style:(Theme.warn ())
              (Printf.sprintf "    %s" (gap_message gap)))
          gaps)
   | Voice_wizard.Name
   | Voice_wizard.Address
   | Voice_wizard.Credential
   | Voice_wizard.Model
   | Voice_wizard.Voice ->
     let caret = if Masc_tui_voice_wizard_session.voice_wizard_is_sending session then "" else "▏" in
     let input =
       Message_layout.input_viewport
         ~max_cells:(max 0 (framed_inner_width cols - 4 - Message_layout.display_width caret))
         (Terminal_text.single_line session.vws_input)
     in
     box_line head cols
       (Printf.sprintf "    %s%s%s%s" Ansi.bold input Ansi.reset caret));
  (match session.vws_step with
   | Voice_wizard.Name | Voice_wizard.Address | Voice_wizard.Credential
   | Voice_wizard.Model | Voice_wizard.Voice ->
       field (ui_text state ~ko:"입력" ~en:"typing") session.vws_input
   | Voice_wizard.Section | Voice_wizard.Provider | Voice_wizard.Review -> ());
  (* A local server that never asked for a key answers 200 only while nothing
     sends it one, so the blank is worth saying out loud rather than leaving as
     an empty line. *)
  (match session.vws_step with
   | Voice_wizard.Credential when String.trim session.vws_input = "" ->
     voice_body_line buf cols
       (Printf.sprintf "    %s%s%s" Ansi.dim
          (ui_text state ~ko:"비워 두면 Authorization 헤더를 보내지 않습니다" ~en:"blank sends no Authorization header") Ansi.reset)
   | Voice_wizard.Address when String.trim session.vws_input = "" ->
     List.iter
       (fun (what, address) ->
         voice_body_line buf cols
           (Printf.sprintf "    %s%s %s: %s%s" Ansi.dim (ui_text state ~ko:"예시" ~en:"try") what address Ansi.reset))
       (Voice_wizard.suggested_addresses draft.Voice_wizard.section)
   | Voice_wizard.Section | Voice_wizard.Provider | Voice_wizard.Name | Voice_wizard.Model
   | Voice_wizard.Voice | Voice_wizard.Review | (Address|Credential) -> ());
  voice_body_line buf cols "";
  voice_body_line buf cols (Printf.sprintf "  %s%s%s" Ansi.bold (ui_text state ~ko:"초안" ~en:"draft") Ansi.reset);
  field (ui_text state ~ko:"방향" ~en:"side") side;
  field (ui_text state ~ko:"공급자" ~en:"provider") (Voice_wizard.provider_label draft.Voice_wizard.provider);
  field (ui_text state ~ko:"이름" ~en:"name") (shown draft.Voice_wizard.endpoint_id);
  field (ui_text state ~ko:"주소" ~en:"address") (shown draft.Voice_wizard.address);
  field (ui_text state ~ko:"키 변수" ~en:"key var") (shown draft.Voice_wizard.credential_variable);
  field (ui_text state ~ko:"모델" ~en:"model") (shown draft.Voice_wizard.model);
  (match draft.Voice_wizard.section with
   | Voice_setup.Tts -> field (ui_text state ~ko:"목소리" ~en:"voice") (shown draft.Voice_wizard.voice)
   | Voice_setup.Stt -> ());
  (match session.vws_status with
   | None -> ()
   | Some status ->
     voice_body_line buf cols "";
     voice_body_line_styled buf cols ~style:(Theme.warn ()) (Printf.sprintf "  %s" (Terminal_text.single_line status)));
  (* Every endpoint, not just the first that answered. A chain stops at the
     first, which is why a dead fallback reads as healthy until the endpoint in
     front of it goes away. *)
  (match session.vws_probe with
   | [] -> ()
   | lines ->
     voice_body_line buf cols "";
     voice_body_line buf cols (Printf.sprintf "  %s%s%s" Ansi.bold (ui_text state ~ko:"응답한 엔드포인트" ~en:"what answered") Ansi.reset);
     List.iter (fun line -> voice_body_line buf cols (Printf.sprintf "    %s" (Terminal_text.single_line line))) lines);
  finish_voice_surface state ~terminal_rows ~cols ~head ~body:buf
    ~hints:(match session.vws_save, session.vws_step with
      | Masc_tui_voice_wizard_session.Save_sending _, _ ->
        ui_text state ~ko:"Esc:닫기 · 저장 요청은 계속됨" ~en:"Esc:close · save continues"
      | (Save_unanswered _ | Save_needs_reopen _), Voice_wizard.Review ->
        ui_text state ~ko:"Up:이전  PgUp/PgDn:스크롤  Esc:닫기" ~en:"Up:back  PgUp/PgDn:scroll  Esc:close"
      | (Save_not_sent | Save_probing _ | Save_settled), Voice_wizard.Review ->
        ui_text state ~ko:"Enter:저장  Up:이전  PgUp/PgDn:스크롤  Esc:닫기"
          ~en:"Enter:save  Up:back  PgUp/PgDn:scroll  Esc:close"
      | (Save_not_sent | Save_probing _ | Save_settled | Save_unanswered _ | Save_needs_reopen _),
        (Voice_wizard.Section | Provider | Name | Address | Credential | Model | Voice) ->
        ui_text state ~ko:"Enter:다음  Up:이전  PgUp/PgDn:스크롤  Esc:닫기"
          ~en:"Enter:next  Up:back  PgUp/PgDn:scroll  Esc:close")
;;

(* Assigning a voice to a keeper: two lists, the keeper walking under up and
   down and the voice under the arrows. Drawn instead of the pane rather than
   over it, because both are lists and a list over a list is two cursors a
   reader has to keep apart. *)
let render_voice_agent (state : state) (session : voice_agent_session) =
  let terminal_rows, cols = get_terminal_size () in
  let buf = Buffer.create 2048 in
  let head = Buffer.create 256 in
  let selector label items cursor draw =
    let position =
      if items = [] then "0/0"
      else Printf.sprintf "%d/%d" (cursor + 1) (List.length items)
    in
    let prefix = Printf.sprintf "  %s %s: " label position in
    let value =
      match List.nth_opt items cursor with
      | None -> Masc_tui_theme.Glyph.no_value
      | Some item -> draw item
    in
    let room = max 1 (framed_inner_width cols - Message_layout.display_width prefix) in
    box_line head cols
      (prefix ^ Ansi.bold ^ Message_layout.fit_middle room value ^ Ansi.reset)
  in
  box_top head cols;
  box_line head cols
    (config_pane_title ~cols ~name:(screen_title (ui_text state ~ko:" MASC 음성 · 키퍼 목소리" ~en:" MASC Voice · keeper voices")) state);
  (* Both selected owners stay above the scrolling document. Enter therefore
     acts on the displayed pair even after paging through long metadata. *)
  selector (ui_text state ~ko:"키퍼" ~en:"keeper") session.vas_agents session.vas_agent_cursor
    Terminal_text.single_line;
  selector (ui_text state ~ko:"목소리" ~en:"voice") session.vas_voices session.vas_voice_cursor
    (fun (_, label) -> Terminal_text.single_line label);
  voice_body_line buf cols "";
  (match List.nth_opt session.vas_agents session.vas_agent_cursor with
   | None -> ()
   | Some agent ->
       voice_body_line buf cols (ui_text state ~ko:"  키퍼: " ~en:"  Keeper: " ^ Terminal_text.single_line agent));
  (match List.nth_opt session.vas_voices session.vas_voice_cursor with
   | None -> ()
   | Some (voice_id, label) ->
       voice_body_line buf cols (ui_text state ~ko:"  목소리: " ~en:"  Voice: " ^ Terminal_text.single_line label);
       voice_body_line buf cols (ui_text state ~ko:"  목소리 ID: " ~en:"  Voice ID: " ^ Terminal_text.single_line voice_id));
  (match session.vas_status with
   | None -> ()
   | Some status ->
     voice_body_line buf cols "";
     voice_body_line_styled buf cols ~style:(Theme.warn ())
       ("  " ^ Terminal_text.single_line status));
  finish_voice_surface state ~terminal_rows ~cols ~head ~body:buf
    ~hints:(Masc_tui_keys.footer_hints_voice_agent ~lang:state.ui_language ~saving:session.vas_saving ())
;;

let render_voice (state : state) =
  match state.voice_agent_voices, state.voice_wizard with
  | Some session, _ -> render_voice_agent state session
  | None, Some session -> render_voice_wizard state session
  | None, None ->
  let terminal_rows, cols = get_terminal_size () in
  let head = Buffer.create 256 in
  let buf = Buffer.create 2048 in
  let field name value =
    voice_body_line buf cols
      (Printf.sprintf "  %s%s%s %s" Ansi.dim (fit_width name 18) Ansi.reset (Terminal_text.single_line value))
  in
  let member path json =
    List.fold_left
      (fun acc key ->
        match acc with
        | Some (`Assoc fields) -> List.assoc_opt key fields
        | Some _ | None -> None)
      (Some json) path
  in
  let string_of path json =
    match member path json with
    | Some (`String v) -> Some v
    | Some (`Bool b) -> Some (if b then ui_text state ~ko:"예" ~en:"yes" else ui_text state ~ko:"아니요" ~en:"no")
    | Some (`Int i) -> Some (string_of_int i)
    | Some _ | None -> None
  in
  (* One line per endpoint, from the admin setup read. The public config route
     answers whether a fallback is configured and not which one, so a chain that
     has quietly gone dead reads there exactly like a healthy one. *)
  let endpoints section =
    match state.voice_setup with
    | None -> []
    | Some json -> (
        match member [ section; "endpoints" ] json with
        | Some (`List items) ->
            List.filter_map
              (fun item ->
                match string_of [ "id" ] item with
                | None -> None
                | Some id ->
                    let kind = Option.value (string_of [ "kind" ] item) ~default:"?" in
                    (* The server resolves it the way the transport does.
                       Choosing between base_url and mcp_url here showed
                       base_url for a voice_mcp endpoint that is called at
                       its mcp_url. A command kind has no address. *)
                    let address =
                      Option.value (string_of [ "address" ] item) ~default:Masc_tui_theme.Glyph.no_value
                    in
                    let off =
                      match member [ "enabled" ] item with
                      | Some (`Bool false) -> ui_text state ~ko:"  (사용 안 함)" ~en:"  (disabled)"
                      | Some _ | None -> ""
                    in
                    (* runtime.toml is an operator's file, not this pane's
                       output. box_line's fit_width keeps ANSI, so an id, kind
                       or address carrying control bytes rewrote the screen the
                       moment the voice pane opened. The probe rows below
                       already pass through the same filter. *)
                    Some
                      (Printf.sprintf "    %-20s %s%-18s%s %s%s"
                         (Terminal_text.single_line id) Ansi.dim
                         (Terminal_text.single_line kind)
                         Ansi.reset (Terminal_text.single_line address) off))
              items
        | Some _ | None -> [])
  in
  let show_endpoints section =
    match endpoints section with
    | [] -> ()
    | lines -> List.iter (fun line -> voice_body_line buf cols line) lines
  in
  box_top head cols;
  box_line head cols
    (config_pane_title ~cols
       ~name:(screen_title (ui_text state ~ko:" MASC 시스템·음성" ~en:" MASC Voice"))
       state);
  let voice_section ?(first = false) title =
    List.iter (fun row -> voice_body_line buf cols row)
      (detail_section_lines ~first title)
  in
  voice_section ~first:true
    (ui_text state ~ko:"음성 엔진" ~en:"Voice engine");
  (* Two independent reads feed this pane: the public config says what loaded,
     and the setup read says which endpoints are declared. They used to share
     one match, so a failed config read also erased the endpoint identities the
     other read had returned. Each section now draws whatever it has. *)
  let loaded_config =
    match (state.voice_config, state.voice_config_error) with
    | Some json, None -> Some json
    | Some _, Some _ | None, Some _ | None, None -> None
  in
  let from_config render =
    match loaded_config with Some json -> render json | None -> ()
  in
  (match (state.voice_config, state.voice_config_error) with
   | _, Some message ->
       (* The distinction the pane exists for, said in words rather than drawn
          as an empty section. *)
       voice_body_line_styled buf cols ~style:(Theme.warn ()) (ui_text state ~ko:"  음성 설정을 읽지 못했습니다" ~en:"  Voice settings did not load");
       voice_body_line buf cols (Printf.sprintf "  %s%s%s" Ansi.dim (Terminal_text.single_line message) Ansi.reset)
   | None, None ->
       voice_body_line buf cols (Printf.sprintf "  %s%s%s" Ansi.dim (ui_text state ~ko:"읽는 중…" ~en:"Reading…") Ansi.reset)
   | Some json, None ->
       field (ui_text state ~ko:"상태" ~en:"status")
         (Option.value (string_of [ "status" ] json)
            ~default:Masc_tui_theme.Glyph.no_value));
  voice_section
    (ui_text state ~ko:"음성 출력 · TTS" ~en:"Voice output · TTS");
  from_config (fun json ->
    field (ui_text state ~ko:"모델" ~en:"model")
      (Option.value (string_of [ "tts"; "default_model" ] json) ~default:Masc_tui_theme.Glyph.no_value);
    field (ui_text state ~ko:"목소리" ~en:"voice")
      (Option.value (string_of [ "tts"; "default_voice" ] json) ~default:Masc_tui_theme.Glyph.no_value));
  show_endpoints "tts";
  voice_section
    (ui_text state ~ko:"음성 입력 · STT" ~en:"Voice input · STT");
  from_config (fun json ->
    field (ui_text state ~ko:"모델" ~en:"model")
      (Option.value (string_of [ "stt"; "default_model" ] json) ~default:Masc_tui_theme.Glyph.no_value);
    field (ui_text state ~ko:"엔드포인트" ~en:"endpoint")
      (Option.value
         (string_of [ "stt"; "active_endpoint"; "enabled" ] json)
         ~default:Masc_tui_theme.Glyph.no_value);
    field (ui_text state ~ko:"대체 경로" ~en:"fallback")
      (Option.value
         (string_of [ "stt"; "active_endpoint"; "fallback_configured" ] json)
         ~default:Masc_tui_theme.Glyph.no_value));
  show_endpoints "stt";
  (* Said once, not per section: the endpoints are missing from both when this
     read fails, and repeating it twice would read as two faults. *)
  (match state.voice_setup_error with
   | None -> ()
   | Some message ->
       voice_body_line buf cols "";
       voice_body_line_styled buf cols ~style:(Theme.warn ())
         (ui_text state ~ko:"  엔드포인트 목록을 읽지 못했습니다" ~en:"  The endpoint list could not be read");
       voice_body_line buf cols (Printf.sprintf "  %s%s%s" Ansi.dim (Terminal_text.single_line message) Ansi.reset));
  voice_section
    (ui_text state ~ko:"입력 장치와 설정 출처" ~en:"Input device and config source");
  field (ui_text state ~ko:"장치" ~en:"device")
    (Option.value state.voice_input_device ~default:(ui_text state ~ko:"미확인" ~en:"unknown"));
  voice_body_line buf cols "";
  (* Where the endpoints above come from. With no [voice] section the loader
     reads the standalone JSON, and naming runtime.toml there sent a reader to a
     file that declares nothing. *)
  let declared_by =
    match Option.map (member [ "source" ]) state.voice_setup with
    | Some (Some (`Assoc source)) -> (
        match List.assoc_opt "path" source with
        | Some (`String path) -> Terminal_text.single_line path
        | Some _ | None -> "runtime.toml [voice]")
    | Some (Some _ | None) | None -> "runtime.toml [voice]"
  in
  voice_body_line buf cols
    (Printf.sprintf (if state.ui_language = Lang_ko then "  %s선언: %s · 위 상태는 서버가 읽은 값%s"
                     else "  %sDeclared in %s · status above is what the server loaded%s")
       Ansi.dim declared_by Ansi.reset);
  (* The keys are the table's, as on every other Config pane. The row was
     written here and left out Esc and q, which the fitter keeps only when
     the hints name them, so the voice pane was the one Config pane that
     named no way out. *)
  finish_voice_surface state ~terminal_rows ~cols ~head ~body:buf
    ~hints:(Masc_tui_keys.footer_hints_config ~lang:state.ui_language ~pane:Config_voice)
;;

let render_config (state : state) =
  if state.runtime_config_status_open then render_runtime_config_status state else
  let terminal_rows, cols = get_terminal_size () in
  let path_note = config_path_note state in
  let title =
    config_pane_title ~cols
      ~name:(screen_title (ui_text state ~ko:" MASC 시스템·설정" ~en:" MASC System"))
      ~note:path_note
      ~clock:
        (Printf.sprintf "%s%s%s" Ansi.dim
           (let now = Unix.localtime (Unix.gettimeofday ()) in
            Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
              now.Unix.tm_sec)
           Ansi.reset)
      state
  in
  (* The frame, its fill and the footer are the contract's. The surface
     subtracted a literal 7 and drew six fixed rows, so the footer stood one
     row above the composer; the key handler read the same short number. *)
  surface_chrome ~overflow:Fits state ~terminal_rows ~cols ~surface_key:"config" ~title
    ~hints:
      (* Projected from the key table rather than spelled here. The literal
         named five keys and no way out -- not because the row ran out of
         cells (78 of 150 at the time) but because nobody wrote Esc or q
         into it. It also named PgUp/PgDn, which the table did not have, so
         the two had drifted in both directions. *)
      (match state.runtime_account_form with
       | Some _ when runtime_form_input_locked state ->
         "Esc back · input retained · Ctrl-X closes recovery after receipt"
       | Some form when Masc_tui_runtime_account_form.is_saved form ->
         Masc_tui_keys.footer_hints_runtime_account_saved ()
       | Some _ -> Masc_tui_keys.footer_hints_runtime_account_form ()
       | None when Option.is_some state.memory_recall_form ->
         Masc_tui_keys.footer_hints_memory_recall_form ()
       | None -> Masc_tui_keys.footer_hints_config ~lang:state.ui_language ~pane:state.config_pane)
    ~body:(fun ~budget:_ c ->
      List.iter (c.push_styled ~style:(Theme.recede ()))
        (config_identity_rows ~cols state);
      List.iter (fun (tone, text) ->
        c.push_styled ~style:(config_metadata_style tone)
          ("  " ^ Terminal_text.single_line text)) (config_metadata_summary state);
      List.iter (fun line -> c.push_styled ~style:(Theme.warn ()) ("  " ^ line))
        (runtime_config_edit_lines ~cols state);
      c.push_divider ();
      let content_height = config_content_height state in
      (* The account form stands where the file is drawn: it is opened on that
         file, and what it saves is that file with one provider added. *)
      match state.runtime_account_form with
      | Some form ->
          List.iter c.push
            (Masc_tui_runtime_account_form.rows ~width:(framed_inner_width cols) form);
          (* The saved form stays open for its copy key, and the footer can
             lose it: the save notice leads that row and the fitter keeps only
             the way out, so CI run 36397938379 drew "Enter / Esc:close"
             without [y]. The card names its keys itself, as the link card
             does. *)
          if Masc_tui_runtime_account_form.is_saved form then
            c.push ("  " ^ Masc_tui_keys.footer_hints_runtime_account_saved ())
      | None ->
      match state.memory_recall_form with
      | Some form ->
          (* Same place and same reason as the account form: the form is
             opened on the file, and what it saves is that file with three
             keys of [typesafeai] set. *)
          List.iter c.push
            (Masc_tui_memory_recall_form.rows ~width:(framed_inner_width cols)
               ~height:content_height form)
      | None ->
      (match state.runtime_config_view_error with
       | Some detail ->
         c.push ((Theme.bad ()) ^ "  " ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset)
       | None -> ());
      match state.runtime_config_view with
      | None ->
          if Option.is_none state.runtime_config_view_error then
            c.push (Ansi.dim ^ "  (loading\xe2\x80\xa6)" ^ Ansi.reset)
      | Some _ ->
          let rows = runtime_config_active_rows state in
          let total = List.length rows in
          let max_scroll = max 0 (total - content_height) in
          let scroll = max 0 (min state.config_scroll max_scroll) in
          let rows_window = Rows.of_list ~first:scroll ~height:content_height rows in
          for i = 0 to content_height - 1 do
            match Rows.at rows_window (scroll + i) with
            | Some segments ->
                (* Painted through [lexed_span], the table the Code surface
                   reads. The runtime config is TOML and the lexer already
                   answers for it; what was missing was anyone asking. *)
                let line = String.concat "" (List.map lexed_span segments) in
                let line =
                  Printf.sprintf "%s%4d%s  %s" Ansi.dim (scroll + i + 1)
                    Ansi.reset line
                in
                if scroll + i = state.runtime_config_cursor then
                  c.push_selected (Masc_tui_theme.strip_sgr line)
                else c.push line
            | None -> ()
          done)
