module Layout = Masc_tui_message_layout
let sample style speaker request body : Layout.entry =
  {style; speaker; role_label = Layout.align_role_label ~column:22 ~style speaker;
   role_label_mark_cells = Layout.role_label_mark_cells ~column:22 ~style ();
   timestamp = "19:30:15"; timeline_bucket = None; span_clock = None;
   request_label = request; body; journal = []; markdown_source = Layout.Markdown_streaming;
   turn_rail = Layout.Rail_none; action = Layout.Action_none}
let entries =
  [sample Layout.User "YOU" "chat-1" "채팅 화면을 더 간결하게 정리해 줘. 필요한 내용만 읽고 싶어.";
   sample Layout.Tool "TOOLS" "chat-1" "✓ Read masc_tui_render_chat.ml · 16ms";
   sample Layout.Keeper "alpha" "chat-1"
     "대화 본문을 먼저 읽을 수 있도록 정리하겠습니다.\n\n저널과 요청 식별자는 상세 보기로 옮기고, 도구 호출은 이름과 결과만 남깁니다. 다른 Keeper의 실행 상태는 목록과 Activity에서 확인할 수 있습니다.";
   sample Layout.Journal "JOURNAL" "" "Librarian · revision 205 · +0 −0 · 52 retained";
   sample Layout.Inbound "reviewer · broadcast" "peer-1" "좁은 화면에서도 마지막 답변과 발신자 이름이 보이는지 확인했습니다.";
   sample Layout.User "YOU" "chat-2" "좋아. 오류나 전송 결과 미확인은 계속 보여 줘.";
   sample Layout.Keeper "alpha" "chat-2" "네. 중단 실패, 승인 요청, 전달 미확인은 기본 화면에서도 보이게 유지합니다."]
let kind (row : Layout.row) = match row.style with
  | Layout.User -> "user" | Inbound -> "inbound" | Keeper -> "keeper"
  | Tool -> "tool" | Journal -> "journal" | Error -> "error" | _ -> "meta"
let projection origin width entries =
  let column = Layout.chat_role_label_width ~pane_cells:width in
  let entries = List.map (fun (entry : Layout.entry) -> {entry with
    role_label = Layout.align_role_label ~column ~style:entry.style entry.speaker;
    role_label_mark_cells = Layout.role_label_mark_cells ~column ~style:entry.style ()}) entries in
  let rows = Layout.visible_rows ~origin ~inner_width:(Masc_tui_frame.inner_width ~cols:width) ~height:1000
    ~markdown:(fun ~entry ~width -> Masc_tui_markdown.render
      ~palette:Masc_tui_markdown.plain_palette ~width entry.Layout.body) entries in
  `List (List.map (fun row -> `Assoc ["kind", `String (kind row);
    "text", `String (row.Layout.gutter ^ row.text)]) rows)
let () =
  let plain = List.filter (fun (entry : Layout.entry) -> entry.style <> Layout.Journal) entries in
  let widths = [60; 96; 144] in
  let data = `List (List.map (fun width -> `Assoc ["width", `Int width;
    "before", projection Layout.Origin_inline width entries;
    "after", projection Layout.Origin_bare width plain]) widths) in
  print_endline (Yojson.Safe.pretty_to_string data)
