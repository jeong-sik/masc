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
    (config_pane_title ~cols ~name:(screen_title " MASC System") state);
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
       "  overrides persist in .masc/runtime_params.json · E is advanced JSON"
   | Some (ok, detail) ->
     box_line_styled buf cols ~style:(if ok then Theme.ok () else Theme.bad ())
       ("  " ^ Terminal_text.single_line detail));
  let selected = List.nth_opt state.runtime_params state.runtime_params_cursor in
  let field label value =
    ("  " ^ Ansi.bold ^ label ^ Ansi.reset)
    :: (Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols - 4)) value
        |> List.map (fun line -> "    " ^ line))
  in
  (* Values are exact JSON. Word wrapping can discard a space at a chunk
     boundary, so split the sanitised value only between terminal cells. *)
  let value_field label value =
    ("  " ^ Ansi.bold ^ label ^ Ansi.reset)
    :: (Message_layout.split_cells
          ~max_cells:(max 1 (framed_inner_width cols - 4))
          (Masc.Tui_terminal_text.sanitize_terminal_text value)
        |> List.map (fun line -> "    " ^ line))
  in
  let selected_lines =
    (match state.runtime_params_notice with
     | None -> []
     | Some (ok, text) -> field (if ok then "Result" else "Refused") text)
    @
    match selected with
    | None -> ["  Select a row to see its contract"]
    | Some row ->
      let open Tui_decode in
      field "Key" row.rpr_key
      @ value_field "Current" row.rpr_current_json
      @ value_field "Default" row.rpr_default_json
      @ field "Type" (if String.trim row.rpr_value_type = "" then "typed value" else row.rpr_value_type)
      @ (match row.rpr_min_json with None -> [] | Some value -> value_field "Minimum" value)
      @ (match row.rpr_max_json with None -> [] | Some value -> value_field "Maximum" value)
      @ (row.rpr_choices
         |> List.mapi (fun index choice ->
              value_field (Printf.sprintf "Choice %d" (index + 1))
                (Yojson.Safe.to_string (`String choice)))
         |> List.concat)
      @ field "Contract" row.rpr_description
      @ field "Source" (if row.rpr_has_override then "override" else "default")
      @ (match row.rpr_surface with
         | None -> []
         | Some surface -> field "Group" (surface.rps_id ^ " · " ^ surface.rps_description))
  in
  box_line_styled buf cols ~style:(Theme.recede ())
    "  j/k selects · PgUp/PgDn reads the complete value and contract";
  box_divider buf cols;
  (* Editing adds a divider and two form rows.  Spend those rows out of the
     list budget so the footer remains visible instead of falling underneath
     the always-present composer. *)
  let list_height, detail_height =
    Masc_tui_types.runtime_params_viewport state ~terminal_rows in
  let count = List.length state.runtime_params in
  let cursor = max 0 (min state.runtime_params_cursor (count - 1)) in
  (match state.runtime_params_error with
   | Some detail ->
     box_line buf cols ((Theme.bad ()) ^ "설정을 읽지 못했습니다: " ^ Ansi.reset
                        ^ Terminal_text.single_line detail);
     for _ = 2 to list_height do box_empty buf cols done
   | None ->
     if state.runtime_params_loading && state.runtime_params = []
     then begin
       box_line buf cols (Ansi.dim ^ "  (loading runtime parameters…)" ^ Ansi.reset);
       for _ = 2 to list_height do box_empty buf cols done
     end
     else if state.runtime_params = []
     then begin
       box_line buf cols (Ansi.dim ^ "  등록된 설정 없음" ^ Ansi.reset);
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
         "그룹 없음 — 레지스트리가 이 param 을 어느 surface 에도 넣지 않았습니다"
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
         build None 0 [] state.runtime_params
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
           let label = if String.equal id "" then "(unfiled)" else id in
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
  let reading = Masc_tui_scroll.window_reading ~noun:"Detail" ~scroll
      ~height:detail_height (List.length selected_lines) in
  let detail_window = Rows.of_list ~first:scroll ~height:detail_height selected_lines in
  let visible_lines = List.init detail_height (fun index ->
      Option.value (Rows.at detail_window (scroll + index)) ~default:"") in
  let panel_title = Option.map (fun row ->
      "Selected setting · " ^ Terminal_text.single_line row.Tui_decode.rpr_key
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
       | Friendly_value when picking -> "choice>"
       | Friendly_value -> "value>"
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
       (Printf.sprintf "  editing %s · %s"
          (Terminal_text.single_line edit.rpe_key)
          (match edit.rpe_mode with
           | Advanced_json -> "advanced JSON · Enter apply · Esc cancel"
           | Friendly_value when friendly_bool ->
             "Left/Right/Space toggle · Enter apply · Esc cancel"
           | Friendly_value when friendly_choice ->
             (* The set is spelled out: a reader walking it one key at a time
                cannot otherwise see how many values there are, or that a form
                they can type by hand exists beside them. *)
             Printf.sprintf
               "Left/Right/Space cycle (%s) · Enter apply · Esc cancel"
               (String.concat " · " edit.rpe_choices)
           | Friendly_value ->
             "type to replace · Enter apply · Esc cancel")));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (match state.runtime_param_edit with
          | Some edit
            when edit.rpe_mode = Friendly_value
                 && List.mem (runtime_param_type_name edit.rpe_value_type)
                      [ "bool"; "boolean" ] ->
            "Left/Right/Space:toggle  Enter:apply  Esc:cancel"
          | Some edit
            when edit.rpe_mode = Friendly_value && edit.rpe_choices <> [] ->
            "Left/Right/Space:cycle  Enter:apply  Esc:cancel"
          | Some { rpe_mode = Friendly_value; _ } ->
            "type:value  Enter:apply  Ctrl-U:clear  Esc:cancel"
          | Some { rpe_mode = Advanced_json; _ } ->
            "type JSON  Enter:apply  Ctrl-U:clear  Esc:cancel"
          | None -> Masc_tui_keys.footer_hints_config ~pane:Config_params));
  finish_surface state ~clamped:(Runtime_params_scroll scroll)
    ~surface_key:"config-params" ~rows:terminal_rows ~cols buf
;;

(* Where the prompt catalog is, for the one row both prompt screens draw above
   their list. A failed refresh says so above the rows it kept, so they read as
   the last good catalog rather than a fresh one; a first read that failed has
   no rows under it. *)
let prompt_catalog_status_row prompts =
  match prompts with
  | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Absent -> None
  | Masc_tui_fetched.Loading -> Some (Theme.recede (), "프롬프트 목록을 읽는 중…")
  | Masc_tui_fetched.Stale (_, detail) ->
    Some
      ( Theme.bad ()
      , "새로고침 실패 · 마지막으로 읽은 목록입니다 — " ^ Terminal_text.single_line detail )
  | Masc_tui_fetched.Failed detail -> Some (Theme.bad (), Terminal_text.single_line detail)
;;

let prompts_detail_layout state ~rows ~error_rows =
  let fixed_rows = if state.prompts_show_runtime_assets then 9 else 8 in
  let combined = max 1 (rows - fixed_rows - error_rows) in
  let list_height = min 8 (combined / 3) in
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
  let status = match prompt_catalog_status_row prompts with
    | None -> [] | Some (_, text) -> wrap text
  in
  let document = match Masc_tui_fetched.value prompts with
    | None -> wrap "선택한 프롬프트가 없습니다"
    | Some snapshot when state.prompts_show_runtime_assets ->
        let assets = snapshot.Tui_decode.ps_runtime_assets in
        let selected = List.nth_opt assets
            (max 0 (min state.prompts_cursor (List.length assets - 1))) in
        (match selected with
         | None -> wrap "런타임 프롬프트 자산이 없습니다"
         | Some asset ->
             wrap "이 자산은 registry override·편집 대상이 아닙니다"
             @ body asset.pra_value
             @ List.concat_map wrap
                 [field "자산" asset.pra_path;
                  field "소스" (if asset.pra_file_exists then "런타임 파일" else "누락");
                  field "파일" asset.pra_file_path])
    | Some snapshot ->
        let rows = Tui_decode.prompt_rows_for_operator
            ~show_fragments:state.prompts_show_fragments snapshot in
        let selected = List.nth_opt rows
            (max 0 (min state.prompts_cursor (List.length rows - 1))) in
        (match selected with
         | None -> wrap "선택한 프롬프트가 없습니다"
         | Some row ->
             let notices =
               match List.find_opt
                       (fun (entry : Tui_decode.held_back_override) ->
                         String.equal entry.hbo_key row.pr_key)
                       snapshot.ps_held_back with
               | None -> []
               | Some entry ->
                   List.concat_map wrap
                     [Printf.sprintf "⊘ 적용 안 됨 · 저장된 오버라이드 %d바이트가 그대로 있습니다" entry.hbo_bytes;
                      entry.hbo_reason;
                      "그 변수를 빼고 같은 키를 다시 저장하면 적용됩니다"]
             in
             let moved = if row.pr_override_default_moved then
                 wrap "△ 기본 프롬프트가 이 오버라이드를 쓴 뒤에 바뀌었습니다 · 오버라이드는 그대로 적용 중이니 현재 기본값과 한 번 대조하세요"
               else []
             in
             let actual_input =
               if not (String.equal row.pr_category "librarian") then []
               else if state.prompts_librarian_input_loading
                       && not (Option.exists
                            (fun (key, _) -> String.equal key row.pr_key)
                            state.prompts_librarian_input) then
                 ["최근 실제 Librarian 입력"; "(Admin 실행 상세를 불러오는 중...)"]
               else match state.prompts_librarian_input_error with
                 | Some detail -> ["최근 실제 Librarian 입력"; "불러올 수 없음: " ^ Terminal_text.single_line detail]
                 | None ->
                     (match state.prompts_librarian_input with
                      | Some (key, lines) when String.equal key row.pr_key -> lines @ [""]
                      | Some _ | None -> [])
             in
             let source = match row.pr_source with
               | Tui_decode.Prompt_override -> "override 사용 · MD는 기본값"
               | Tui_decode.Prompt_file -> "MD 파일 사용"
               | Tui_decode.Prompt_missing -> "없음"
             in
             let contract =
               if String.equal row.pr_category "librarian" then
                 wrap "입력: Keeper 지침 | 현재 기억 | 제한된 대화 | 상대 관측 | 사실 최대 바이트"
               else []
             in
             notices @ moved @ List.concat_map wrap actual_input
             @ wrap "유효 템플릿 본문" @ body row.pr_effective
             @ List.concat_map wrap
                 [field "키" row.pr_key; field "소스" source;
                  field "파일" row.pr_file_path; field "분류" row.pr_category;
                  field "설명" row.pr_description;
                  field "템플릿 변수" (match row.pr_template_variables with
                    | [] -> "없음" | variables -> String.concat " | " variables);
                  field "읽기" (match row.pr_operator_surface with
                    | Tui_decode.Prompt_primary -> "주 프롬프트"
                    | Tui_decode.Prompt_fragment -> "내부 조각")]
             @ contract)
  in
  status @ document

let prompts_detail_viewport (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let prompts = Masc_tui_fetched.view_for ~equal:Unit.equal state.prompts ~key:() in
  let error_rows = if Option.is_some (prompt_catalog_status_row prompts) then 1 else 0 in
  let _, height = prompts_detail_layout state ~rows ~error_rows in
  (List.length (prompts_detail_lines state ~cols), height)

let render_prompts_detail state buf ~cols ~height =
  let rendered = prompts_detail_lines state ~cols in
  let total = List.length rendered in
  let scroll = Masc_tui_scroll.normalize ~count:total ~height state.config_scroll in
  box_line_styled buf cols ~style:(Theme.recede ())
    (Printf.sprintf "  Detail [%d-%d/%d]" (scroll + 1)
       (min total (scroll + height)) total);
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
        Printf.sprintf "%d/%d개" total all_prompt_count)
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
      Printf.sprintf " %s적용 안 된 오버라이드 %d개%s" (Theme.warn ())
        (List.length entries) Ansi.reset
  in
  let reading =
    Printf.sprintf "%s%s%s%s · %s%s"
      Ansi.dim count_text
      held_back_note
      Ansi.dim
      (if state.prompts_show_fragments then "내부 조각 포함" else "주 프롬프트")
      Ansi.reset
  in
  box_line buf cols
    (config_pane_title ~cols ~name:(screen_title " MASC 프롬프트") ~reading state);
  box_divider buf cols;
  (* One row that says where the catalog is. An empty list used to mean both
     "still reading" and "nothing here". *)
  let status_row = prompt_catalog_status_row prompts in
  let error_rows = if Option.is_some status_row then 1 else 0 in
  let list_height, detail_height = prompts_detail_layout state ~rows ~error_rows in
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
        let label = mark ^ " "
            ^ Message_layout.fit_middle (max 1 (framed_inner_width cols - 3))
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
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  " ^ Message_layout.truncate_middle (max 1 (framed_inner_width cols - 2))
       (match selected with
        | None -> "선택 없음"
        | Some row -> Terminal_text.single_line row.Tui_decode.pr_key));
  render_prompts_detail state buf ~cols ~height:detail_height;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_config ~pane:Config_prompts));
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
    title_count_of_view prompts ~count:(fun _ -> Printf.sprintf "%d개" total)
  in
  box_top buf cols;
  let reading =
    Printf.sprintf "%s%s · 읽기 전용%s" Ansi.dim count_text Ansi.reset
  in
  box_line buf cols
    (config_pane_title ~cols
       ~name:(screen_title " MASC 런타임 프롬프트 자산") ~reading state);
  box_line_styled buf cols ~style:(Theme.recede ())
    "  배포된 .txt 지시문 · registry override 대상이 아님";
  box_divider buf cols;
  (* One row that says where the catalog is. An empty list used to mean both
     "still reading" and "nothing here". *)
  let status_row = prompt_catalog_status_row prompts in
  let error_rows = if Option.is_some status_row then 1 else 0 in
  let list_height, detail_height = prompts_detail_layout state ~rows ~error_rows in
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
  box_line_styled buf cols ~style:(Theme.recede ())
    ("  " ^ Message_layout.truncate_middle (max 1 (framed_inner_width cols - 2))
       (match selected with
        | None -> "선택 없음"
        | Some asset -> Terminal_text.single_line asset.Tui_decode.pra_path));
  render_prompts_detail state buf ~cols ~height:detail_height;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:Masc_tui_keys.footer_hints_prompt_assets);
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
let preset_detail_lines (state : state) ~cols ~selected =
  let unreadable = match state.presets_snapshot with
    | None -> []
    | Some snapshot -> snapshot.Tui_decode.pss_unreadable
  in
  let detail = Masc_tui_preset_text.detail_lines ~selected
    ~detail:(match selected with
      | None -> Masc_tui_fetched.Absent
      | Some m -> Masc_tui_fetched.view_for ~equal:String.equal
          state.preset_detail ~key:m.Tui_decode.pm_name)
    ~report:state.preset_report
  in
  let errors = match state.presets_error with
    | None -> []
    | Some error -> ["Refresh failed: " ^ error; ""]
  in
  errors @ detail
  @ List.map (fun (name, reason) -> "! " ^ name ^ " — " ^ reason) unreadable
  |> List.concat_map (fun line ->
       if String.equal line "" then [""]
       else Masc_tui_text_block.rows ~max_cells:(max 1 (framed_inner_width cols - 2)) line)

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
    | Some _ -> Printf.sprintf "%d개" total
    | None -> title_missing_reading ~error:state.presets_error
  in
  box_top buf cols;
  let reading = Printf.sprintf "%s%s%s" Ansi.dim count_text Ansi.reset in
  box_line buf cols
    (config_pane_title ~cols ~name:(screen_title " MASC 프리셋") ~reading
       state);
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
       box_line_styled buf cols ~style:(Theme.recede ()) page_failed_note
   | None, None ->
       incr drawn;
       box_line_styled buf cols ~style:(Theme.recede ()) page_unread_note
   | Some snapshot, (Some _ | None) ->
       Option.iter
         (fun line ->
           incr drawn;
           box_line_styled buf cols ~style:(Theme.recede ()) ("  " ^ line))
         (Masc_tui_preset_text.pane_empty_line snapshot));
  List.iteri
    (fun index (manifest : Tui_decode.preset_manifest) ->
      if index >= first && index < first + preset_rows then begin
        incr drawn;
        let name = manifest.Tui_decode.pm_name in
        let mark =
          match state.preset_armed with
          | Some (Restore_armed armed) when String.equal armed name ->
              Theme.warn () ^ "r" ^ Ansi.reset
          | Some (Delete_armed armed) when String.equal armed name ->
              Theme.bad () ^ "D" ^ Ansi.reset
          | Some (Restore_armed _ | Delete_armed _) | None -> " "
        in
        let label =
          row_with_field ~cols ~lead:(" " ^ mark ^ " ")
            ~field:(Terminal_text.single_line (Masc_tui_preset_text.pane_row manifest))
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
  let detail_window = Rows.of_list ~first:scroll ~height:detail_height detail in
  for index = 0 to detail_height - 1 do
    match Rows.at detail_window (scroll + index) with
    | Some line -> box_line buf cols ("  " ^ line)
    | None -> box_empty buf cols
  done;
  Option.iter (box_line_styled buf cols ~style:(Theme.recede ()))
    (Masc_tui_scroll.position_row ~scroll ~height:detail_height count);
  (match state.preset_save_draft with
   | Some draft ->
     box_line buf cols
       (row_with_field ~cols
          ~lead:(Theme.info () ^ "  이름: " ^ Ansi.reset)
          ~field:(Terminal_text.single_line draft)
          ~tail:(Ansi.dim ^ "  Enter:저장  Esc:취소" ^ Ansi.reset))
   | None -> ());
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_config ~pane:Config_presets));
  finish_surface state ~clamped:(Preset_detail_scroll scroll)
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
    (config_pane_title ~cols ~name:(screen_title " MASC Themes")
       ~reading:
         (Printf.sprintf "%s%d themes · %d native-pass%s" Ansi.dim
            (List.length entries) native_count Ansi.reset)
       state);
  box_divider buf cols;
  box_line_styled buf cols ~style:Ansi.dim
    ("  " ^ fit_width "theme" (name_width + 2) ^ " "
     ^ fit_width "colours" 16 ^ "  " ^ fit_width "page" 9 ^ " "
     ^ fit_width "contrast" 12)
  ;
  (* The key the way the footer spells it, then the three filters as the
     product's tab strip draws a choice: the one in force marked. It read
     "Filter: [f] [All 53] · Dark 40 · Light 13", where the brackets meant a
     key once and the chosen filter once, on the same row. *)
  let explanation =
    if cols >= 92 then
      "  ·  "
      ^ (if lift_on then "native 7/7=no lift · lift N/7=N raised"
         else "native 7/7=all pass · N/7 low=below 4.5:1")
    else ""
  in
  let filter_tag =
    let chip label filter count =
      (label ^ " " ^ string_of_int count, state.theme_filter = filter, filter)
    in
    Ansi.dim ^ "f:filter  " ^ Ansi.reset
    ^ tab_strip
        ~width:
          (tab_strip_width ~cols ~before:"  f:filter  " ~after:explanation)
        ~press:(fun filter text -> pressable (Press_theme_filter filter) text)
        [ chip "All" `All (List.length all_entries)
        ; chip "Dark" `Dark dark_count
        ; chip "Light" `Light light_count
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
          ^ fit_width (if entry.light then "light" else "dark") 9
          ^ " "
          ^ fit_width (Theme_choice.contrast_status ~lift_on entry) 12
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
      (Printf.sprintf "  Sample: %s● Ok%s  %s▲ Warn%s  %s× Bad%s  %s◆ Info%s  %s@keeper%s  %s⚡ tool%s"
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
  box_line_styled buf cols ~style:Ansi.dim
    (* What is in force, then its keys in the footer's spelling. [f] is on
       the filter row above, so it is not said twice. *)
    (match chosen with
     | None ->
       "  terminal colours  \xc2\xb7  Enter:pick a theme"
     | Some name ->
       Printf.sprintf "  %s  \xc2\xb7  Enter:pick another  x:follow terminal"
         (Terminal_text.single_line name));
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_config ~pane:state.config_pane));
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
            path_from_root ~root:identity.Tui_decode.sid_masc_root path
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
               [{Masc_tui_detail_reading.heading="Source"; body=reading.rcv_path}])
        @ [{Masc_tui_detail_reading.heading="Account / model";
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
    (config_pane_title ~cols ~name:(screen_title " MASC Models") ~note:path_note
       state);
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
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:(Masc_tui_keys.footer_hints_config ~pane:Config_models));
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
      let base = Terminal_text.single_line identity.Tui_decode.sid_base_path in
      let masc = Terminal_text.single_line identity.Tui_decode.sid_masc_root in
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
      ("  " ^ notice) :: rows
  | Workspace_identity_unread | Workspace_identity_match
  | Workspace_identity_mismatch _ -> rows

(* What the runtime.toml body spends above the source: the server identity,
   one row per metadata line, and the rule under them. *)
let config_heading_rows ~cols (state : state) =
  List.length (config_identity_rows ~cols state)
  + List.length (config_metadata_summary state) + 1
  + List.length (runtime_config_edit_lines ~cols state)
  + (if Option.is_none state.runtime_account_form
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
    ~title:(screen_title " MASC System / runtime.toml status")
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
  box_bottom buf cols;
  Buffer.add_string buf (footer_line state ~max_cells:cols ~hints);
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
      (Printf.sprintf "  %s%-12s%s %s" Ansi.dim name Ansi.reset (Terminal_text.single_line value))
  in
  let draft = session.vws_draft in
  let side =
    match draft.Voice_wizard.section with
    | Voice_setup.Tts -> "speech out"
    | Voice_setup.Stt -> "speech in"
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
  box_top head cols;
  box_line head cols
    (config_pane_title ~cols ~name:(screen_title " MASC Voice · setup") state);
  voice_body_line buf cols "";
  voice_body_line buf cols
    (Printf.sprintf "  %sstep %s%s  %s" Ansi.dim position Ansi.reset
       (Voice_wizard.step_prompt session.vws_step));
  voice_body_line buf cols "";
  (* The answer being given. A closed set shows its current value and the keys
     that walk it; a text field shows what has been typed, with a cursor so an
     empty field is visibly a field. *)
  (match session.vws_step with
   | Voice_wizard.Section ->
     box_line head cols
       (Printf.sprintf "    %s%s%s   %s←/→ or space to switch%s" Ansi.bold side
          Ansi.reset Ansi.dim Ansi.reset)
   | Voice_wizard.Provider ->
     box_line head cols
       (Printf.sprintf "    %s%s%s   %s←/→ or space to switch%s" Ansi.bold
          (Voice_wizard.provider_label draft.Voice_wizard.provider)
          Ansi.reset Ansi.dim Ansi.reset)
   | Voice_wizard.Review ->
     (match Voice_wizard.gaps draft with
      | [] ->
        voice_body_line buf cols
          (Printf.sprintf "    %senter saves this%s" Ansi.bold Ansi.reset)
      | gaps ->
        List.iter
          (fun gap ->
            voice_body_line_styled buf cols ~style:(Theme.warn ())
              (Printf.sprintf "    %s" (Voice_wizard.gap_message gap)))
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
       field "typing" session.vws_input
   | Voice_wizard.Section | Voice_wizard.Provider | Voice_wizard.Review -> ());
  (* A local server that never asked for a key answers 200 only while nothing
     sends it one, so the blank is worth saying out loud rather than leaving as
     an empty line. *)
  (match session.vws_step with
   | Voice_wizard.Credential when String.trim session.vws_input = "" ->
     voice_body_line buf cols
       (Printf.sprintf "    %sblank sends no Authorization header%s" Ansi.dim Ansi.reset)
   | Voice_wizard.Address when String.trim session.vws_input = "" ->
     List.iter
       (fun (what, address) ->
         voice_body_line buf cols
           (Printf.sprintf "    %stry %s: %s%s" Ansi.dim what address Ansi.reset))
       (Voice_wizard.suggested_addresses draft.Voice_wizard.section)
   | Voice_wizard.Section | Voice_wizard.Provider | Voice_wizard.Name | Voice_wizard.Model
   | Voice_wizard.Voice | Voice_wizard.Review | (Address|Credential) -> ());
  voice_body_line buf cols "";
  voice_body_line buf cols (Printf.sprintf "  %sdraft%s" Ansi.bold Ansi.reset);
  field "side" side;
  field "provider" (Voice_wizard.provider_label draft.Voice_wizard.provider);
  field "name" (shown draft.Voice_wizard.endpoint_id);
  field "address" (shown draft.Voice_wizard.address);
  field "key var" (shown draft.Voice_wizard.credential_variable);
  field "model" (shown draft.Voice_wizard.model);
  (match draft.Voice_wizard.section with
   | Voice_setup.Tts -> field "voice" (shown draft.Voice_wizard.voice)
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
     voice_body_line buf cols (Printf.sprintf "  %swhat answered%s" Ansi.bold Ansi.reset);
     List.iter (fun line -> voice_body_line buf cols (Printf.sprintf "    %s" (Terminal_text.single_line line))) lines);
  finish_voice_surface state ~terminal_rows ~cols ~head ~body:buf
    ~hints:"Enter:next  Up:back  PgUp/PgDn:scroll  Esc:cancel"
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
    (config_pane_title ~cols ~name:(screen_title " MASC Voice · keeper voices") state);
  (* Both selected owners stay above the scrolling document. Enter therefore
     acts on the displayed pair even after paging through long metadata. *)
  selector "keeper" session.vas_agents session.vas_agent_cursor
    Terminal_text.single_line;
  selector "voice" session.vas_voices session.vas_voice_cursor
    (fun (_, label) -> Terminal_text.single_line label);
  voice_body_line buf cols "";
  (match List.nth_opt session.vas_agents session.vas_agent_cursor with
   | None -> ()
   | Some agent ->
       voice_body_line buf cols ("  Keeper: " ^ Terminal_text.single_line agent));
  (match List.nth_opt session.vas_voices session.vas_voice_cursor with
   | None -> ()
   | Some (voice_id, label) ->
       voice_body_line buf cols ("  Voice: " ^ Terminal_text.single_line label);
       voice_body_line buf cols ("  Voice ID: " ^ Terminal_text.single_line voice_id));
  (match session.vas_status with
   | None -> ()
   | Some status ->
     voice_body_line buf cols "";
     voice_body_line_styled buf cols ~style:(Theme.warn ())
       ("  " ^ Terminal_text.single_line status));
  finish_voice_surface state ~terminal_rows ~cols ~head ~body:buf
    ~hints:(Masc_tui_keys.footer_hints_voice_agent ~saving:session.vas_saving ())
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
      (Printf.sprintf "  %s%-18s%s %s" Ansi.dim name Ansi.reset (Terminal_text.single_line value))
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
    | Some (`Bool b) -> Some (if b then "yes" else "no")
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
                      | Some (`Bool false) -> "  (disabled)"
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
    (config_pane_title ~cols ~name:(screen_title " MASC Voice") state);
  voice_body_line buf cols "";
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
       voice_body_line_styled buf cols ~style:(Theme.warn ()) "  voice did not load";
       voice_body_line buf cols (Printf.sprintf "  %s%s%s" Ansi.dim (Terminal_text.single_line message) Ansi.reset)
   | None, None ->
       voice_body_line buf cols (Printf.sprintf "  %sreading…%s" Ansi.dim Ansi.reset)
   | Some json, None ->
       field "status"
         (Option.value (string_of [ "status" ] json)
            ~default:Masc_tui_theme.Glyph.no_value));
  voice_body_line buf cols "";
  voice_body_line buf cols (Printf.sprintf "  %sTTS%s" Ansi.bold Ansi.reset);
  from_config (fun json ->
    field "model"
      (Option.value (string_of [ "tts"; "default_model" ] json) ~default:Masc_tui_theme.Glyph.no_value);
    field "voice"
      (Option.value (string_of [ "tts"; "default_voice" ] json) ~default:Masc_tui_theme.Glyph.no_value));
  show_endpoints "tts";
  voice_body_line buf cols "";
  voice_body_line buf cols (Printf.sprintf "  %sSTT%s" Ansi.bold Ansi.reset);
  from_config (fun json ->
    field "model"
      (Option.value (string_of [ "stt"; "default_model" ] json) ~default:Masc_tui_theme.Glyph.no_value);
    field "endpoint"
      (Option.value
         (string_of [ "stt"; "active_endpoint"; "enabled" ] json)
         ~default:Masc_tui_theme.Glyph.no_value);
    field "fallback"
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
         "  the endpoint list could not be read";
       voice_body_line buf cols (Printf.sprintf "  %s%s%s" Ansi.dim (Terminal_text.single_line message) Ansi.reset));
  voice_body_line buf cols "";
  voice_body_line buf cols (Printf.sprintf "  %sInput%s" Ansi.bold Ansi.reset);
  field "device" (Option.value state.voice_input_device ~default:"unknown");
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
    (Printf.sprintf "  %s%s declares this; the server says what loaded%s"
       Ansi.dim declared_by Ansi.reset);
  (* The keys are the table's, as on every other Config pane. The row was
     written here and left out Esc and q, which the fitter keeps only when
     the hints name them, so the voice pane was the one Config pane that
     named no way out. *)
  finish_voice_surface state ~terminal_rows ~cols ~head ~body:buf
    ~hints:(Masc_tui_keys.footer_hints_config ~pane:Config_voice)
;;

let render_config (state : state) =
  if state.runtime_config_status_open then render_runtime_config_status state else
  let terminal_rows, cols = get_terminal_size () in
  let path_note = config_path_note state in
  let title =
    config_pane_title ~cols ~name:(screen_title " MASC System") ~note:path_note
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
       | None -> Masc_tui_keys.footer_hints_config ~pane:state.config_pane)
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
