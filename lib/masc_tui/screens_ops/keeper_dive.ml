open Masc_tui_core
open Masc_tui_term
open Masc_tui_keymap
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

(* --- Tab 1: Claude-Code-Grade Chat & Stream --- *)

type transcript_row = {
  rail_rgb : Theme.rgb option;
  prefix : string;
  prefix_fg : Theme.rgb;
  prefix_attrs : Attr.t;
  spans : Markdown.styled_span list;
  right_meta : string option;
  right_meta_fg : Theme.rgb option;
  right_meta_attrs : Attr.t;
  bg_rgb : Theme.rgb;
  full_bleed_bg : bool;
}

let make_row ?rail_rgb ?(prefix = "") ~prefix_fg ?(prefix_attrs = Attr.none)
    ?right_meta ?right_meta_fg ?(right_meta_attrs = Attr.italic) ~bg_rgb
    ?(full_bleed_bg = false) spans =
  {
    rail_rgb;
    prefix;
    prefix_fg;
    prefix_attrs;
    spans;
    right_meta;
    right_meta_fg;
    right_meta_attrs;
    bg_rgb;
    full_bleed_bg;
  }

let single_span_row ?rail_rgb ?(prefix = "") ~prefix_fg
    ?(prefix_attrs = Attr.none) ?right_meta ?right_meta_fg
    ?(right_meta_attrs = Attr.italic) ~text ~text_fg ~bg_rgb
    ?(attrs = Attr.none) ?(full_bleed_bg = false) () =
  let bg = Color.of_rgb bg_rgb in
  make_row ?rail_rgb ~prefix ~prefix_fg ~prefix_attrs ?right_meta ?right_meta_fg
    ~right_meta_attrs ~bg_rgb ~full_bleed_bg
    [
      {
        Markdown.text;
        style = Style.make ~fg:(Color.of_rgb text_fg) ~bg ~attrs ();
        hyperlink = None;
      };
    ]

let blank_row ~bg_rgb =
  make_row ~prefix_fg:bg_rgb ~bg_rgb []

let wrap_plain_lines = Chat_transcript.wrap_plain_lines

(* Summarize tool args/output cleanly so raw JSON walls and secrets never flood Chat. *)
let concise_tool_preview ~max_w raw =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then ""
  else
    let sanitize_one_line s =
      let scrubbed = Ops_common.scrub_secrets_in_text s in
      let clean =
        String.map (function '\n' | '\r' | '\t' -> ' ' | c -> c) scrubbed
      in
      if Json_tree.is_secret_value clean then "[redacted]" else clean
    in
    let one_line =
      match Yojson.Safe.from_string trimmed with
      | json -> (
          match Ops_common.scrub_json_secrets json with
          | `Assoc kvs ->
              kvs
              |> List.take 3
              |> List.map (fun (k, v) ->
                     let vs =
                       if Json_tree.is_secret_key k then "[redacted]"
                       else
                         match v with
                         | `String s -> sanitize_one_line s
                         | `Int n -> Int.to_string n
                         | `Float f -> Printf.sprintf "%.2g" f
                         | `Bool b -> if b then "true" else "false"
                         | `Null -> "null"
                         | `List xs -> Printf.sprintf "[%d]" (List.length xs)
                         | `Assoc xs -> Printf.sprintf "{%d}" (List.length xs)
                         | `Intlit s -> s
                     in
                     Printf.sprintf "%s=%s" k vs)
              |> String.concat "  "
          | `List xs -> Printf.sprintf "[%d items]" (List.length xs)
          | `String s -> sanitize_one_line s
          | `Int n -> Int.to_string n
          | `Float f -> Printf.sprintf "%.2g" f
          | `Bool b -> if b then "true" else "false"
          | `Null -> ""
          | `Intlit s -> s)
      | exception Yojson.Json_error _ -> sanitize_one_line trimmed
    in
    Grapheme.truncate_to_width ~max_width:(Int.max 8 max_w) one_line

let build_history_thinking_rows ~(theme : Theme.t) ~(model : Model.t) ~width
    (thinking : Wire_fleet.history_thinking option) =
  let base_bg = theme.surface_1 in
  let redacted_row () =
    [
      single_span_row ~rail_rgb:theme.status_ai
        ~prefix:(Glyph.to_utf8 Glyph.Ai_spark ^ " ")
        ~prefix_fg:theme.status_ai ~prefix_attrs:Attr.bold
        ~text:
          (Ops_common.say model ~ko:"추론 · 비공개 (redacted)"
             ~en:"Thinking · redacted")
        ~text_fg:theme.text_muted ~attrs:Attr.italic ~bg_rgb:base_bg ();
    ]
  in
  let render_visible ~is_partial ~mode text =
    if String.equal (String.trim text) "" then
      if is_partial then redacted_row () else []
    else
      let approx_toks = Int.max 1 (String.length text / 4) in
      let partial_suffix =
        if is_partial then
          Ops_common.say model ~ko:" · 일부 비공개" ~en:" · partially redacted"
        else ""
      in
      let lbl =
        Ops_common.say model
          ~ko:(Printf.sprintf "추론 · %d tok%s" approx_toks partial_suffix)
          ~en:(Printf.sprintf "Thinking · %d tok%s" approx_toks partial_suffix)
      in
      match mode with
      | Fleet_store.Thinking_hidden -> []
      | Fleet_store.Thinking_folded ->
          [
            single_span_row ~rail_rgb:theme.status_ai
              ~prefix:
                (Glyph.to_utf8 Glyph.Expand_closed ^ " "
                 ^ Glyph.to_utf8 Glyph.Ai_spark ^ " ")
              ~prefix_fg:theme.status_ai ~prefix_attrs:Attr.bold ~text:lbl
              ~text_fg:theme.text_muted ~attrs:Attr.italic
              ~right_meta:
                (Ops_common.say model ~ko:"[Alt+T] 펼치기" ~en:"[Alt+T] expand")
              ~right_meta_fg:theme.text_muted ~right_meta_attrs:Attr.italic
              ~bg_rgb:base_bg ();
          ]
      | Fleet_store.Thinking_full ->
          let hdr =
            single_span_row ~rail_rgb:theme.status_ai
              ~prefix:
                (Glyph.to_utf8 Glyph.Expand_open ^ " "
                 ^ Glyph.to_utf8 Glyph.Ai_spark ^ " ")
              ~prefix_fg:theme.status_ai ~prefix_attrs:Attr.bold ~text:lbl
              ~text_fg:theme.status_ai ~attrs:Attr.bold ~bg_rgb:base_bg ()
          in
          let think_lines =
            wrap_plain_lines ~width:(Int.max 12 (width - 6)) text
          in
          hdr
          :: List.map
               (fun ln ->
                 single_span_row ~rail_rgb:theme.status_ai ~prefix:"  "
                   ~prefix_fg:theme.status_ai ~text:ln ~text_fg:theme.text_muted
                   ~attrs:Attr.italic ~bg_rgb:base_bg ())
               think_lines
  in
  match thinking with
  | None -> []
  | Some th -> (
      match model.fleet.chat_thinking_mode with
      | Fleet_store.Thinking_hidden -> []
      | (Fleet_store.Thinking_folded | Fleet_store.Thinking_full) as mode -> (
          match th with
          | Wire_fleet.Thinking_redacted -> redacted_row ()
          | Wire_fleet.Thinking_visible text ->
              render_visible ~is_partial:false ~mode text
          | Wire_fleet.Thinking_partial text ->
              render_visible ~is_partial:true ~mode text))

let delegate_card_spans ~(theme : Theme.t) ~(model : Model.t) ~bg ~width
    (del : Chat_transcript.delegate_summary) =
  let action_lbl =
    match del.kind with
    | Chat_transcript.Delegate_invoke ->
        Ops_common.say model ~ko:"위임" ~en:"Delegate"
    | Chat_transcript.Delegate_status ->
        Ops_common.say model ~ko:"위임 조회" ~en:"Delegate status"
    | Chat_transcript.Delegate_cancel ->
        Ops_common.say model ~ko:"위임 취소" ~en:"Delegate cancel"
  in
  let target_suffix =
    match del.target_keepers with
    | [] -> ""
    | [ single ] -> " → @" ^ single
    | first :: rest ->
        let n_rest = List.length rest in
        Ops_common.say model
          ~ko:(Printf.sprintf " → @%s 외 %d명" first n_rest)
          ~en:(Printf.sprintf " → @%s +%d" first n_rest)
  in
  let title = action_lbl ^ target_suffix in
  let meta_parts =
    (if del.operation_count > 1 then
       [
         Ops_common.say model
           ~ko:(Printf.sprintf "%d건" del.operation_count)
           ~en:(Printf.sprintf "%d ops" del.operation_count);
       ]
     else [])
    @ (match del.operation_id with Some op -> [ "op:" ^ op ] | None -> [])
    @ (if del.artifact_count > 0 then
         [
           Ops_common.say model
             ~ko:(Printf.sprintf "아티팩트 %d" del.artifact_count)
             ~en:(Printf.sprintf "%d artifacts" del.artifact_count);
         ]
       else [])
    @ (match del.prompt_preview with Some p -> [ p ] | None -> [])
  in
  let detail =
    match meta_parts with
    | [] -> ""
    | xs ->
        let joined = String.concat Typography.sep_dot xs in
        Grapheme.truncate_to_width ~max_width:(Int.max 12 (width - 30)) joined
  in
  [
    {
      Markdown.text = title;
      style = Typography.accent ~bg ~bold:true theme;
      hyperlink = None;
    };
  ]
  @
  if String.length detail > 0 then
    [
      {
        Markdown.text = "  " ^ detail;
        style = Typography.structure ~bg theme;
        hyperlink = None;
      };
    ]
  else []

let tool_group_row ~(model : Model.t) ~(theme : Theme.t) ?right_meta ~count
    items =
  let label =
    Ops_common.say model ~ko:(Printf.sprintf "도구 호출 %d회" count)
      ~en:(Printf.sprintf "%d tool calls" count)
  in
  let histogram =
    Chat_transcript.summarize_tool_histogram ~lang:model.lang items
  in
  let text =
    if String.equal histogram "" then label
    else label ^ Typography.sep_dot ^ histogram
  in
  let right_meta =
    match right_meta with
    | Some m -> m
    | None -> "[Ctrl+O]"
  in
  single_span_row ~rail_rgb:theme.border_inactive
    ~prefix:
      (Glyph.to_utf8 Glyph.Expand_closed ^ " " ^ Glyph.to_utf8 Glyph.Tool_square
       ^ " ")
    ~prefix_fg:theme.text_secondary ~text ~text_fg:theme.text_secondary
    ~right_meta ~right_meta_fg:theme.text_muted ~right_meta_attrs:Attr.italic
    ~bg_rgb:theme.surface_2 ~full_bleed_bg:true ()

let preview_tool_output_rows ~(theme : Theme.t) ~(model : Model.t) ~width raw =
  let tools_mode = Chat_transcript.tools_mode model in
  let max_preview, show_expand_hint =
    match tools_mode with
    | Slash.Tools_compact -> (0, false)
    | Slash.Tools_results -> (8, true)
    | Slash.Tools_full -> (48, false)
  in
  let shown, hidden =
    Chat_transcript.tool_output_display_lines ~tools_mode ~width raw
  in
  if shown = [] && hidden = 0 then []
  else
    let inset_bg = theme.surface_0 in
    let body_rows =
      List.map
        (fun ln ->
          single_span_row ~rail_rgb:theme.border_subtle ~prefix:"  "
            ~prefix_fg:theme.text_muted ~text:ln ~text_fg:theme.text_secondary
            ~bg_rgb:inset_bg ~full_bleed_bg:true ())
        shown
    in
    if hidden > 0 then
      let overflow_txt =
        if show_expand_hint then
          Ops_common.say model
            ~ko:
              (Printf.sprintf "%s +%d줄 더 보기 [Ctrl+O]"
                 (Glyph.to_utf8 Glyph.Ellipsis) hidden)
            ~en:
              (Printf.sprintf "%s +%d more lines [Ctrl+O]"
                 (Glyph.to_utf8 Glyph.Ellipsis) hidden)
        else
          Ops_common.say model
            ~ko:
              (Printf.sprintf "%s 외 %d줄 생략 (최대 %d줄 표시)"
                 (Glyph.to_utf8 Glyph.Ellipsis) hidden max_preview)
            ~en:
              (Printf.sprintf "%s %d more lines truncated (%d-line cap)"
                 (Glyph.to_utf8 Glyph.Ellipsis) hidden max_preview)
      in
      body_rows
      @ [
          single_span_row ~rail_rgb:theme.border_subtle ~prefix:"  "
            ~prefix_fg:theme.text_muted ~text:overflow_txt
            ~text_fg:theme.text_muted ~bg_rgb:inset_bg ~attrs:Attr.italic
            ~full_bleed_bg:true ();
        ]
    else body_rows

let markdown_rows ?rail_rgb ~(theme : Theme.t) ~width ~prefix ~cont_prefix
    ~prefix_fg ~bg_rgb ?(full_bleed_bg = false) text =
  let lines =
    Chat_transcript.markdown_body_lines ~theme ~width
      ~rail_present:(Option.is_some rail_rgb) ~prefix text
  in
  match lines with
  | [] ->
      [
        single_span_row ?rail_rgb ~prefix ~prefix_fg ~text:""
          ~text_fg:theme.text_primary ~bg_rgb ~full_bleed_bg ();
      ]
  | first :: rest ->
      let head =
        make_row ?rail_rgb ~prefix ~prefix_fg ~bg_rgb ~full_bleed_bg first.spans
      in
      let tail =
        List.map
          (fun (l : Markdown.rendered_line) ->
            make_row ?rail_rgb ~prefix:cont_prefix ~prefix_fg ~bg_rgb
              ~full_bleed_bg l.spans)
          rest
      in
      head :: tail

(* The header of a [user] row the operator did not write: the author the server
   recorded, and the route when it is not a direct message. *)
let peer_label model (peer : Wire_fleet.chat_peer)
    (surface : Wire_fleet.chat_surface option) =
  let author =
    match peer with
    | Wire_fleet.Peer_keeper name | Wire_fleet.Peer_external name -> name
    | Wire_fleet.Peer_unresolved None ->
        Ops_common.say model ~ko:"보낸 사람 모름" ~en:"unknown sender"
    | Wire_fleet.Peer_unresolved (Some id) ->
        Printf.sprintf "%s (%s)" id
          (Ops_common.say model ~ko:"확인 안 됨" ~en:"unverified")
  in
  let route =
    match surface with
    | None | Some (Wire_fleet.Surface_dashboard | Wire_fleet.Surface_agent) -> None
    | Some Wire_fleet.Surface_broadcast ->
        Some (Ops_common.say model ~ko:"방송" ~en:"broadcast")
    | Some Wire_fleet.Surface_discord -> Some "Discord"
    | Some Wire_fleet.Surface_slack -> Some "Slack"
    | Some Wire_fleet.Surface_webhook -> Some "Webhook"
    | Some (Wire_fleet.Surface_gate label) -> Some label
  in
  match route with
  | None -> author
  | Some r -> Printf.sprintf "%s · %s" author r

let build_history_rows ~(theme : Theme.t) ~(model : Model.t) ~keeper_name ~width
    (messages : Wire_fleet.chat_message list) =
  let base_bg = theme.surface_1 in
  let user_bg = theme.surface_2 in
  let runtimes = Runtime_store.runtime_options model.runtime in
  let cut_replies =
    Fleet_store.cut_replies_by_row ~keeper:keeper_name model.fleet
  in
  let origin_mode =
    match model.fleet.chat_origin_mode with
    | Fleet_store.Display_origin_inline ->
        if width < 56 then Fleet_store.Display_origin_row
        else Fleet_store.Display_origin_inline
    | Fleet_store.Display_origin_bare -> Fleet_store.Display_origin_bare
    | Fleet_store.Display_origin_row -> Fleet_store.Display_origin_row
  in
  let rec loop prev_minute acc = function
    | [] -> List.rev acc
    | Chat_transcript.Grouped (first, related) :: rest ->
        let calls = first :: related in
        let items =
          List.map
            (fun (msg : Wire_fleet.chat_message) ->
              let tname =
                match msg.tool_call_name with
                | Some n -> n
                | None -> Ops_common.say model ~ko:"도구" ~en:"tool"
              in
              (tname, msg.content))
            calls
        in
        let hhmm =
          Ops_common.format_hhmm ~tz_offset_sec:model.tz_offset_sec
            (List.fold_left (fun _ (msg : Wire_fleet.chat_message) -> msg.ts_unix)
               first.ts_unix related)
        in
        let row =
          tool_group_row ~model ~theme
            ~right_meta:(Printf.sprintf "[Ctrl+O] · %s" hhmm)
            ~count:(List.length calls) items
        in
        let acc = if acc = [] then acc else blank_row ~bg_rgb:base_bg :: acc in
        loop (Some hhmm) (row :: acc) rest
    | Chat_transcript.Single (msg : Wire_fleet.chat_message) :: rest ->
        let hhmm =
          Ops_common.format_hhmm ~tz_offset_sec:model.tz_offset_sec msg.ts_unix
        in
        let same_min = Option.equal String.equal prev_minute (Some hhmm) in
        let spacing = if acc = [] then [] else [ blank_row ~bg_rgb:base_bg ] in
        let msg_rows =
          match msg.role with
          | Wire_fleet.Role_user ->
              (* Claude-Code User Turn: elevated surface_2 block + left ▎ (accent) + Bold Operator + italic timestamp *)
              let header_row =
                match origin_mode with
                | Fleet_store.Display_origin_inline -> []
                | Fleet_store.Display_origin_bare ->
                    [
                      single_span_row ~rail_rgb:theme.accent
                        ~prefix:(Glyph.to_utf8 Glyph.Prompt_caret ^ " ")
                        ~prefix_fg:theme.accent ~prefix_attrs:Attr.bold
                        ~text:(Ops_common.say model ~ko:"운영자" ~en:"Operator")
                        ~text_fg:theme.text_bright ~attrs:Attr.bold
                        ~right_meta:hhmm ~right_meta_fg:theme.text_muted
                        ~right_meta_attrs:Attr.italic ~bg_rgb:user_bg
                        ~full_bleed_bg:true ();
                    ]
                | Fleet_store.Display_origin_row ->
                    let origin_meta =
                      Printf.sprintf "%s · %s"
                        (Ops_common.say model ~ko:"직접 입력" ~en:"direct")
                        hhmm
                    in
                    [
                      single_span_row ~rail_rgb:theme.accent
                        ~prefix:(Glyph.to_utf8 Glyph.Prompt_caret ^ " ")
                        ~prefix_fg:theme.accent ~prefix_attrs:Attr.bold
                        ~text:(Ops_common.say model ~ko:"운영자" ~en:"Operator")
                        ~text_fg:theme.text_bright ~attrs:Attr.bold
                        ~right_meta:origin_meta ~right_meta_fg:theme.text_muted
                        ~right_meta_attrs:Attr.italic ~bg_rgb:user_bg
                        ~full_bleed_bg:true ();
                    ]
              in
              let prefix, cont =
                match origin_mode with
                | Fleet_store.Display_origin_inline ->
                    let ts_col = if same_min then "     " else hhmm in
                    ( Printf.sprintf "%s %s " ts_col
                        (Glyph.to_utf8 Glyph.Prompt_caret)
                    , "        " )
                | Fleet_store.Display_origin_bare
                | Fleet_store.Display_origin_row ->
                    ("  ", "  ")
              in
              header_row
              @ markdown_rows ~rail_rgb:theme.accent ~theme ~width ~prefix
                  ~cont_prefix:cont ~prefix_fg:theme.accent ~bg_rgb:user_bg
                  ~full_bleed_bg:true msg.content
          | Wire_fleet.Role_peer { peer; surface } ->
              (* Named on a header row in every origin mode: no prefix says who
                 wrote it, and the accent rail stays the operator's.
                 [Chat_transcript.count_history] counts the same rows. *)
              single_span_row ~rail_rgb:theme.border_subtle
                ~prefix:(Glyph.to_utf8 Glyph.Prompt_caret ^ " ")
                ~prefix_fg:theme.text_muted ~prefix_attrs:Attr.bold
                ~text:(peer_label model peer surface)
                ~text_fg:theme.text_primary ~attrs:Attr.bold ~right_meta:hhmm
                ~right_meta_fg:theme.text_muted ~right_meta_attrs:Attr.italic
                ~bg_rgb:base_bg ~full_bleed_bg:true ()
              :: markdown_rows ~rail_rgb:theme.border_subtle ~theme ~width
                   ~prefix:"  " ~cont_prefix:"  " ~prefix_fg:theme.text_muted
                   ~bg_rgb:base_bg ~full_bleed_bg:true msg.content
          | Wire_fleet.Role_assistant ->
              (* Claude-Code Assistant Reply: Bare keeps calm surface_1 + HH:MM; Row adds subtle rail + full model provenance *)
              let provenance_meta =
                match msg.model_used with
                | Some m ->
                    let human_m = Wire_runtime.human_runtime_slot_label ~runtimes m in
                    Printf.sprintf "%s · %s" human_m hhmm
                | None ->
                    Printf.sprintf "%s · %s"
                      (Ops_common.say model ~ko:"키퍼 응답" ~en:"keeper")
                      hhmm
              in
              let header_row =
                match origin_mode with
                | Fleet_store.Display_origin_inline -> []
                | Fleet_store.Display_origin_bare ->
                    [
                      single_span_row
                        ~prefix:(Glyph.to_utf8 Glyph.Live_healthy ^ " ")
                        ~prefix_fg:theme.status_ok ~prefix_attrs:Attr.bold
                        ~text:("@" ^ keeper_name) ~text_fg:theme.text_bright
                        ~attrs:Attr.bold ~right_meta:hhmm
                        ~right_meta_fg:theme.text_muted
                        ~right_meta_attrs:Attr.italic ~bg_rgb:base_bg ();
                    ]
                | Fleet_store.Display_origin_row ->
                    [
                      single_span_row ~rail_rgb:theme.border_subtle
                        ~prefix:(Glyph.to_utf8 Glyph.Live_healthy ^ " ")
                        ~prefix_fg:theme.status_ok ~prefix_attrs:Attr.bold
                        ~text:("@" ^ keeper_name) ~text_fg:theme.text_bright
                        ~attrs:Attr.bold ~right_meta:provenance_meta
                        ~right_meta_fg:theme.text_muted
                        ~right_meta_attrs:Attr.italic ~bg_rgb:base_bg ();
                    ]
              in
              let prefix, cont =
                match origin_mode with
                | Fleet_store.Display_origin_inline ->
                    let ts_col = if same_min then "     " else hhmm in
                    ( Printf.sprintf "%s %s " ts_col
                        (Glyph.to_utf8 Glyph.Live_healthy)
                    , "      " ^ Glyph.to_utf8 Glyph.Tree_pipe ^ " " )
                | Fleet_store.Display_origin_bare
                | Fleet_store.Display_origin_row ->
                    ("  ", "  ")
              in
              let body_rail =
                match origin_mode with
                | Fleet_store.Display_origin_row -> Some theme.border_subtle
                | Fleet_store.Display_origin_bare
                | Fleet_store.Display_origin_inline ->
                    None
              in
              let thinking_rows =
                build_history_thinking_rows ~theme ~model ~width msg.thinking
              in
              thinking_rows @ header_row
              @ markdown_rows ?rail_rgb:body_rail ~theme ~width ~prefix
                  ~cont_prefix:cont ~prefix_fg:theme.status_ok ~bg_rgb:base_bg
                  msg.content
          | Wire_fleet.Role_system ->
              let src_line =
                single_span_row ~rail_rgb:theme.status_active
                  ~prefix:(Glyph.to_utf8 Glyph.External_arrow ^ " ")
                  ~prefix_fg:theme.status_active ~prefix_attrs:Attr.bold
                  ~text:
                    (Ops_common.say model ~ko:"외부 · 브로드캐스트"
                       ~en:"external · broadcast")
                  ~text_fg:theme.text_secondary ~right_meta:hhmm
                  ~right_meta_fg:theme.text_muted ~right_meta_attrs:Attr.italic
                  ~bg_rgb:base_bg ()
              in
              src_line
              :: markdown_rows ~rail_rgb:theme.status_active ~theme ~width
                   ~prefix:"  " ~cont_prefix:"  "
                   ~prefix_fg:theme.text_secondary ~bg_rgb:base_bg msg.content
          | Wire_fleet.Role_tool ->
              (* Elevated surface_2 collapsible tool card — untyped history carries no ok:bool,
                 so NEVER fabricate ● (Live_healthy)! *)
              let tname =
                match msg.tool_call_name with
                | Some n -> n
                | None -> Ops_common.say model ~ko:"도구" ~en:"tool"
              in
              let expanded =
                match Chat_transcript.tools_mode model with
                | Slash.Tools_compact -> false
                | Slash.Tools_results | Slash.Tools_full -> true
              in
              let chevron =
                if expanded then Glyph.to_utf8 Glyph.Expand_open
                else Glyph.to_utf8 Glyph.Expand_closed
              in
              let bg = Color.of_rgb theme.surface_2 in
              let del_opt =
                Chat_transcript.extract_delegate_summary ~tool_name:tname
                  ~raw_json:msg.content
              in
              let rail_rgb, spans =
                match del_opt with
                | Some del ->
                    ( theme.accent
                    , delegate_card_spans ~theme ~model ~bg ~width del )
                | None ->
                    let preview =
                      concise_tool_preview ~max_w:(Int.max 10 (width - 28))
                        msg.content
                    in
                    let sp =
                      [
                        {
                          Markdown.text = tname;
                          style = Typography.accent ~bg ~bold:true theme;
                          hyperlink = None;
                        };
                      ]
                      @
                      if String.length preview > 0 then
                        [
                          {
                            Markdown.text = "  " ^ preview;
                            style = Typography.structure ~bg theme;
                            hyperlink = None;
                          };
                        ]
                      else []
                    in
                    (theme.border_inactive, sp)
              in
              let compact_line =
                make_row ~rail_rgb
                  ~prefix:(chevron ^ " " ^ Glyph.to_utf8 Glyph.Tool_square ^ " ")
                  ~prefix_fg:theme.text_secondary ~right_meta:hhmm
                  ~right_meta_fg:theme.text_muted ~right_meta_attrs:Attr.italic
                  ~bg_rgb:theme.surface_2 ~full_bleed_bg:true spans
              in
              let detail_rows =
                if expanded then
                  preview_tool_output_rows ~theme ~model ~width msg.content
                else []
              in
              compact_line :: detail_rows
          | Wire_fleet.Role_request_failure ->
              let meta =
                match msg.failure_kind with
                | Some fk -> Printf.sprintf "%s · %s" fk hhmm
                | None -> hhmm
              in
              let hdr =
                single_span_row ~rail_rgb:theme.status_critical
                  ~prefix:(Glyph.to_utf8 Glyph.Live_failing ^ " ")
                  ~prefix_fg:theme.status_critical ~prefix_attrs:Attr.bold
                  ~text:(Ops_common.say model ~ko:"요청 실패" ~en:"Request failed")
                  ~text_fg:theme.status_critical ~attrs:Attr.bold
                  ~right_meta:meta ~right_meta_fg:theme.text_muted
                  ~right_meta_attrs:Attr.italic ~bg_rgb:base_bg ()
              in
              (* What the Keeper had streamed before the cut, rebuilt from the
                 operation's journal. Chat_transcript.count_transcript_rows
                 counts the same rows. *)
              let cut_reply_rows =
                match Fleet_store.String_map.find_opt msg.id cut_replies with
                | None -> []
                | Some text ->
                    single_span_row ~rail_rgb:theme.border_inactive
                      ~prefix:(Glyph.to_utf8 Glyph.Tree_corner ^ " ")
                      ~prefix_fg:theme.text_muted
                      ~text:(Ops_common.say model ~ko:"끊긴 답장" ~en:"Cut reply")
                      ~text_fg:theme.text_secondary ~attrs:Attr.italic
                      ~bg_rgb:base_bg ()
                    :: markdown_rows ~rail_rgb:theme.border_inactive ~theme
                         ~width ~prefix:"  " ~cont_prefix:"  "
                         ~prefix_fg:theme.text_secondary ~bg_rgb:base_bg text
              in
              (hdr
              :: markdown_rows ~rail_rgb:theme.status_critical ~theme ~width
                   ~prefix:"  " ~cont_prefix:"  "
                   ~prefix_fg:theme.status_critical ~bg_rgb:base_bg msg.content)
              @ cut_reply_rows
        in
        loop (Some hhmm) (List.rev_append (spacing @ msg_rows) acc) rest
  in
  loop None []
    (Chat_transcript.history_tool_groups ~tools_mode:(Chat_transcript.tools_mode model)
       messages)

let build_stream_rows ~(theme : Theme.t) ~(model : Model.t) ~keeper_name ~width
    (sp : Chat_transcript.stream_projection) =
  let buf = sp.buf in
  let base_bg = theme.surface_1 in
  let rows = ref [] in
  let push r = rows := r :: !rows in
  let push_all rs = List.iter push rs in
  (* 0. Live Runtime Attempt / Provider Retry / Checkpoint / Protocol Banners *)
  (match sp.show_retry with
  | Some retry_s ->
      push
        (single_span_row ~rail_rgb:theme.status_attention
           ~prefix:(Glyph.to_utf8 Glyph.Action_required ^ " ")
           ~prefix_fg:theme.status_attention ~prefix_attrs:Attr.bold
           ~text:
             (Ops_common.say model ~ko:("프로바이더 재시도: " ^ retry_s)
                ~en:("Provider retry: " ^ retry_s))
           ~text_fg:theme.status_attention ~bg_rgb:base_bg ~attrs:Attr.bold ())
  | None -> ());
  (match sp.show_checkpoint with
  | Some ckpt_s ->
      push
        (single_span_row ~rail_rgb:theme.status_active
           ~prefix:(Glyph.to_utf8 Glyph.Ai_spark ^ " ")
           ~prefix_fg:theme.status_active ~prefix_attrs:Attr.bold
           ~text:
             (Ops_common.say model ~ko:("체크포인트: " ^ ckpt_s)
                ~en:("Checkpoint: " ^ ckpt_s))
           ~text_fg:theme.text_secondary ~bg_rgb:base_bg ~attrs:Attr.italic ())
  | None -> ());
  (match sp.show_protocol_warning with
  | Some warn_s ->
      push
        (single_span_row ~rail_rgb:theme.status_critical
           ~prefix:(Glyph.to_utf8 Glyph.Live_failing ^ " ")
           ~prefix_fg:theme.status_critical ~prefix_attrs:Attr.bold
           ~text:
             (Ops_common.say model ~ko:("스트림 경고: " ^ warn_s)
                ~en:("Stream protocol notice: " ^ warn_s))
           ~text_fg:theme.status_critical ~bg_rgb:base_bg ())
  | None -> ());
  (* 1. Keeper Thinking / Reasoning: Violet ▎ (status_ai) + ✦ (Ai_spark) + Tier-4 italic! *)
  if sp.show_thinking then begin
    let approx_toks = Int.max 1 (String.length buf.thinking / 4) in
    match model.fleet.chat_thinking_mode with
    | Fleet_store.Thinking_hidden -> ()
    | Fleet_store.Thinking_folded ->
        let lbl =
          Ops_common.say model
            ~ko:(Printf.sprintf "추론 · %d tok" approx_toks)
            ~en:(Printf.sprintf "Thinking · %d tok" approx_toks)
        in
        push
          (single_span_row ~rail_rgb:theme.status_ai
             ~prefix:
               (Glyph.to_utf8 Glyph.Expand_closed ^ " "
                ^ Glyph.to_utf8 Glyph.Ai_spark ^ " ")
             ~prefix_fg:theme.status_ai ~prefix_attrs:Attr.bold ~text:lbl
             ~text_fg:theme.text_muted ~attrs:Attr.italic
             ~right_meta:
               (Ops_common.say model ~ko:"[Alt+T] 펼치기" ~en:"[Alt+T] expand")
             ~right_meta_fg:theme.text_muted ~right_meta_attrs:Attr.italic
             ~bg_rgb:base_bg ())
    | Fleet_store.Thinking_full ->
        let hdr =
          Ops_common.say model
            ~ko:(Printf.sprintf "추론 · %d tok" approx_toks)
            ~en:(Printf.sprintf "Thinking · %d tok" approx_toks)
        in
        push
          (single_span_row ~rail_rgb:theme.status_ai
             ~prefix:
               (Glyph.to_utf8 Glyph.Expand_open ^ " "
                ^ Glyph.to_utf8 Glyph.Ai_spark ^ " ")
             ~prefix_fg:theme.status_ai ~prefix_attrs:Attr.bold ~text:hdr
             ~text_fg:theme.status_ai ~attrs:Attr.bold ~bg_rgb:base_bg ());
        let think_lines =
          wrap_plain_lines ~width:(Int.max 12 (width - 6)) buf.thinking
        in
        List.iter
          (fun ln ->
            push
              (single_span_row ~rail_rgb:theme.status_ai ~prefix:"  "
                 ~prefix_fg:theme.status_ai ~text:ln ~text_fg:theme.text_muted
                 ~attrs:Attr.italic ~bg_rgb:base_bg ()))
          think_lines
  end;
  (* 2. Collapsible Elevated Tool Cards (surface_2 header + recessed surface_0 preview) *)
  let tools_mode = Chat_transcript.tools_mode model in
  let expanded_tools =
    match tools_mode with
    | Slash.Tools_compact -> false
    | Slash.Tools_results | Slash.Tools_full -> true
  in
  if sp.show_tools then
    List.iter
      (function
        | Chat_transcript.Grouped (first, related) ->
            let calls = first :: related in
            let items =
              List.map
                (fun (call : Fleet_store.active_tool_call) ->
                  (call.tool_name, Option.value call.args_preview ~default:""))
                calls
            in
            push (tool_group_row ~model ~theme ~count:(List.length calls) items)
        | Chat_transcript.Single (tc : Fleet_store.active_tool_call) ->
        let rail_rgb, pill_txt, pill_fg =
          match tc.tool_state with
          | Fleet_store.Tool_pending ->
            ( theme.status_active
            , Glyph.to_utf8 Glyph.Live_working ^ " " ^ Option.value tc.progress_label ~default:"run"
            , theme.status_active )
          | Fleet_store.Tool_result_pending _ ->
              ( theme.status_active
              , (let waiting = Ops_common.say model ~ko:"결과 대기" ~en:"Awaiting result" in
                 Option.fold ~none:waiting ~some:(fun label -> waiting ^ " · " ^ label) tc.progress_label)
              , theme.status_active )
          | Fleet_store.Tool_unfinished ->
              ( theme.border_inactive
              , Ops_common.say model ~ko:"결과 미확인" ~en:"Result unconfirmed"
              , theme.text_secondary )
          | Fleet_store.Tool_settled -> (
              match tc.ok with
            | Some true ->
                ( theme.status_ok
                , Glyph.to_utf8 Glyph.Live_healthy ^ " ok"
                , theme.status_ok )
            | Some false ->
                ( theme.status_critical
                , Glyph.to_utf8 Glyph.Delta_up ^ " err"
                , theme.status_critical )
            | None ->
                ( theme.border_inactive
                , Glyph.to_utf8 Glyph.Live_idle
                , theme.text_secondary ))
        in
        let chevron =
          if expanded_tools && Option.is_some tc.output_preview then
            Glyph.to_utf8 Glyph.Expand_open
          else Glyph.to_utf8 Glyph.Expand_closed
        in
        let bg = Color.of_rgb theme.surface_2 in
        let del_opt =
          Chat_transcript.extract_delegate_summary ~tool_name:tc.tool_name
            ~raw_json:(Option.value tc.args_preview ~default:"")
        in
        let spans =
          match del_opt with
          | Some del -> delegate_card_spans ~theme ~model ~bg ~width del
          | None ->
              let args_part =
                match tc.args_preview with
                | Some a ->
                    concise_tool_preview ~max_w:(Int.max 10 (width - 30)) a
                | None -> ""
              in
              [
                {
                  Markdown.text = tc.tool_name;
                  style = Typography.accent ~bg ~bold:true theme;
                  hyperlink = None;
                };
              ]
              @
              if String.length args_part > 0 then
                [
                  {
                    Markdown.text = "  " ^ args_part;
                    style = Typography.structure ~bg theme;
                    hyperlink = None;
                  };
                ]
              else []
        in
        push
          (make_row ~rail_rgb
             ~prefix:(chevron ^ " " ^ Glyph.to_utf8 Glyph.Tool_square ^ " ")
             ~prefix_fg:rail_rgb ~right_meta:pill_txt ~right_meta_fg:pill_fg
             ~right_meta_attrs:Attr.bold ~bg_rgb:theme.surface_2
             ~full_bleed_bg:true spans);
        match expanded_tools, tc.output_preview with
        | true, Some out ->
            push_all (preview_tool_output_rows ~theme ~model ~width out)
        | false, _ | true, None -> ())
      (Chat_transcript.stream_tool_groups ~tools_mode buf.tools);
  (* 3. Live Assistant Text Delta *)
  if sp.show_text then begin
    let fg = theme.text_secondary in
    let label = match sp.show_runtime_meta with
      | Some runtime -> "@" ^ keeper_name ^ " · " ^ runtime
      | None -> "@" ^ keeper_name
    in
    push
      (single_span_row ~prefix:(Glyph.to_utf8 Glyph.Live_healthy ^ " ") ~prefix_fg:fg
         ~prefix_attrs:Attr.bold ~text:label
         ~text_fg:theme.text_bright ~attrs:Attr.bold
         ~bg_rgb:base_bg ());
    push_all
      (markdown_rows ~theme ~width ~prefix:"  " ~cont_prefix:"  " ~prefix_fg:fg
         ~bg_rgb:base_bg buf.text)
  end;
  (* 4. Explicit Stream Error (Coral left rail, non-italic Bold) *)
  (match sp.show_error with
  | Some err ->
      push
        (single_span_row ~rail_rgb:theme.status_critical
           ~prefix:(Glyph.to_utf8 Glyph.Live_failing ^ " ")
           ~prefix_fg:theme.status_critical ~prefix_attrs:Attr.bold
           ~text:
             (Ops_common.say model ~ko:("스트림 오류: " ^ err)
                ~en:("Stream error: " ^ err))
           ~text_fg:theme.status_critical ~bg_rgb:base_bg ~attrs:Attr.bold ())
  | None -> ());
  List.rev !rows

let build_pending_tx_rows ~(theme : Theme.t) ~(model : Model.t) ~width
    (items : Chat_transcript.pending_tx_projection list) =
  let base_bg = theme.surface_2 in
  List.map
    (fun (item : Chat_transcript.pending_tx_projection) ->
      let tx = item.tx in
      if item.notice_only then
        let notice, tone = match tx.state with
          | Drafts.No_operation_record -> Say.resolve model.lang (Drafts.absence_notice tx), theme.status_attention
          | Drafts.Failed_retryable { reason } ->
              Ops_common.say model ~ko:("전송 실패: " ^ reason) ~en:("Send failed: " ^ reason), theme.status_critical
          | Queued | Sending | Pending_processing | Confirming_delivery | Interrupting | Delivered ->
              "", theme.text_muted in
        single_span_row ~rail_rgb:tone
          ~prefix:(if tx.state = Drafts.No_operation_record then "· " else Glyph.to_utf8 Glyph.Live_failing ^ " ")
          ~prefix_fg:tone ~prefix_attrs:Attr.bold
          ~text:(Grapheme.truncate_to_width ~max_width:(Int.max 12 (width - 22)) notice)
          ~text_fg:tone ~attrs:Attr.bold
          ~right_meta:(Ops_common.say model ~ko:"[X] 닫기" ~en:"[X] dismiss")
          ~right_meta_fg:theme.text_muted ~right_meta_attrs:Attr.italic
          ~bg_rgb:theme.surface_1 ()
      else
        let state_str =
          if tx.state = Drafts.No_operation_record then Say.resolve model.lang (Drafts.absence_notice tx)
          else match Drafts.tx_state_label tx.state with
            | Some state_say -> Say.resolve model.lang state_say
            | None -> ""
        in
        let state_fg =
          match tx.state with
          | Drafts.No_operation_record -> theme.status_attention
          | Drafts.Failed_retryable _ -> theme.status_critical
          | Drafts.Queued | Drafts.Sending | Drafts.Interrupting ->
              theme.status_attention
          | Drafts.Pending_processing | Drafts.Confirming_delivery ->
              theme.status_active
          | Drafts.Delivered -> theme.status_ok
        in
        let mode_tag =
          match tx.mode with
          | Drafts.Mode_direct -> None
          | Drafts.Mode_steer ->
              Some (Ops_common.say model ~ko:"조향" ~en:"Steer")
          | Drafts.Mode_follow_up ->
              Some (Ops_common.say model ~ko:"후속" ~en:"Queue")
        in
        let body_preview =
          Grapheme.truncate_to_width
            ~max_width:(Int.max 12 (width - 30))
            (String.map (function '\n' | '\r' -> ' ' | c -> c) tx.body)
        in
        let detail =
          match tx.state with
          | Drafts.Failed_retryable { reason } ->
              Printf.sprintf "%s (%s)" body_preview reason
          | Drafts.No_operation_record
          | Drafts.Queued
          | Drafts.Sending
          | Drafts.Pending_processing
          | Drafts.Confirming_delivery
          | Drafts.Interrupting
          | Drafts.Delivered ->
              body_preview
        in
        let pill =
          match tx.state with
          | Drafts.No_operation_record | Drafts.Failed_retryable _ ->
              Printf.sprintf "%s · %s" state_str
                (Ops_common.say model ~ko:"[X] 닫기" ~en:"[X] dismiss")
          | Drafts.Queued
          | Drafts.Sending
          | Drafts.Pending_processing
          | Drafts.Confirming_delivery
          | Drafts.Interrupting
          | Drafts.Delivered -> (
              match mode_tag with
              | Some mt -> Printf.sprintf "%s · %s" state_str mt
              | None -> state_str)
        in
        single_span_row ~rail_rgb:state_fg
          ~prefix:(Glyph.to_utf8 Glyph.Prompt_caret ^ " ")
          ~prefix_fg:state_fg ~prefix_attrs:Attr.bold ~text:detail
          ~text_fg:theme.text_primary ~right_meta:pill ~right_meta_fg:state_fg
          ~right_meta_attrs:Attr.bold ~bg_rgb:base_bg ~full_bleed_bg:true ())
    items

let format_active_turn_elapsed ~(model : Model.t) (turn : Wire_fleet.active_turn) =
  let secs_opt =
    if
      model.freshness.last_wall_unix > 0.0
      && model.freshness.last_wall_unix >= turn.started_at_unix
    then Some (model.freshness.last_wall_unix -. turn.started_at_unix)
    else Option.map (fun ms -> ms /. 1000.0) turn.elapsed_ms
  in
  match secs_opt with
  | None -> None
  | Some raw_s ->
      let s = Int.max 0 (Int.of_float raw_s) in
      if s < 60 then Some (Printf.sprintf "%ds" s)
      else if s < 3600 then Some (Printf.sprintf "%dm %02ds" (s / 60) (s mod 60))
      else Some (Printf.sprintf "%dh %02dm" (s / 3600) (s mod 3600 / 60))

let short_turn_ref_tag (turn : Wire_fleet.active_turn) =
  match turn.turn_ref with
  | None -> None
  | Some tr -> (
      match String.rindex_opt tr '#' with
      | Some idx when idx + 1 < String.length tr ->
          Some (String.sub tr idx (String.length tr - idx))
      | Some _ | None -> None)

let build_active_turn_rows ~(theme : Theme.t) ~(model : Model.t) ~keeper ~width
    (turn : Wire_fleet.active_turn) =
  let is_failed =
    match turn.preview with
    | Some { activity = Wire_fleet.Preview_failed; _ } -> true
    | Some
        {
          activity =
            ( Wire_fleet.Preview_preparing
            | Wire_fleet.Preview_waiting
            | Wire_fleet.Preview_streaming
            | Wire_fleet.Preview_tool_observed );
          _;
        }
    | None ->
        false
  in
  let rail_rgb =
    if is_failed then theme.status_attention else theme.status_active
  in
  let tail_rows =
    match Chat_transcript.active_turn_preview_tail turn with
    | None -> []
    | Some tail ->
        let snippet =
          "… "
          ^ Grapheme.truncate_to_width ~max_width:(Int.max 10 (width - 8)) tail
        in
        [
          single_span_row ~rail_rgb ~prefix:"  " ~prefix_fg:rail_rgb
            ~text:snippet ~text_fg:theme.text_secondary ~attrs:Attr.italic
            ~bg_rgb:theme.surface_2 ~full_bleed_bg:true ();
        ]
  in
  if not (Chat_transcript.show_active_turn_summary ~model ~keeper turn) then
    tail_rows
  else
    let summary =
      Printf.sprintf "%s · %s"
        (Ops_common.say model ~ko:"현재 작업" ~en:"Active turn")
        (Say.resolve model.lang (Chat_transcript.active_turn_detail_summary turn))
    in
    let hdr_text =
      Grapheme.truncate_to_width ~max_width:(Int.max 12 (width - 24)) summary
    in
    let right_meta =
      match model.fleet.chat_origin_mode with
      | Fleet_store.Display_origin_bare ->
          if is_failed then Ops_common.say model ~ko:"시도 실패" ~en:"failed"
          else Ops_common.say model ~ko:"진행 중" ~en:"running"
      | Fleet_store.Display_origin_inline | Fleet_store.Display_origin_row -> (
          let parts =
            List.filter_map Fun.id
              [
                short_turn_ref_tag turn;
                format_active_turn_elapsed ~model turn;
              ]
          in
          match parts with
          | [] ->
              if is_failed then Ops_common.say model ~ko:"시도 실패" ~en:"failed"
              else Ops_common.say model ~ko:"진행 중" ~en:"running"
          | _ :: _ -> String.concat " · " parts)
    in
    let hdr_row =
      single_span_row ~rail_rgb
        ~prefix:(Glyph.to_utf8 Glyph.Live_working ^ " ")
        ~prefix_fg:rail_rgb ~prefix_attrs:Attr.bold ~text:hdr_text
        ~text_fg:theme.text_bright ~attrs:Attr.bold ~right_meta
        ~right_meta_fg:rail_rgb ~right_meta_attrs:Attr.italic
        ~bg_rgb:theme.surface_2 ~full_bleed_bg:true ()
    in
    hdr_row :: tail_rows

let draw_transcript_rows grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~pad_x ~scroll rows =
  if Rect.is_empty rect then ()
  else
    let total = List.length rows in
    let arr = Array.of_list rows in
    let max_scroll = Int.max 0 (total - rect.h) in
    let clamped_scroll = Int.max 0 (Int.min max_scroll scroll) in
    let show_follow_cue = clamped_scroll > 0 && rect.h >= 2 in
    let view_h = if show_follow_cue then rect.h - 1 else rect.h in
    let start = Int.max 0 (total - view_h - clamped_scroll) in
    let visible = Int.min view_h (total - start) in
    let content = Card.pad_inner ~pad_x rect in
    (* Cap comfortable prose column at 96 cells for readability on ultra-wide screens *)
    let col_w = Int.min content.w 96 in
    let col_x = content.x in
    for i = 0 to visible - 1 do
      let r = arr.(start + i) in
      let py = rect.y + i in
      let full_row = Rect.make ~x:rect.x ~y:py ~w:rect.w ~h:1 in
      let col_rect = Rect.make ~x:col_x ~y:py ~w:col_w ~h:1 in
      let base_bg = Color.of_rgb theme.surface_1 in
      let body_bg = Color.of_rgb r.bg_rgb in
      Cell_grid.fill_rect ~clip:rect grid ~rect:full_row
        ~style:(Typography.primary ~bg:base_bg theme) ();
      if r.full_bleed_bg && r.bg_rgb <> theme.surface_1 then
        Cell_grid.fill_rect ~clip:col_rect grid ~rect:col_rect
          ~style:(Typography.primary ~bg:body_bg theme) ();
      let cx = ref col_x in
      let right_edge = Rect.right col_rect in
      (match r.rail_rgb with
      | Some c when !cx < right_edge ->
          let rail_bg = if r.full_bleed_bg then body_bg else base_bg in
          Card.draw_left_rail ~bg:rail_bg ~color:c grid ~x:!cx ~y:py ~h:1 ~theme;
          cx := !cx + 2
      | Some _ | None -> ());
      if String.length r.prefix > 0 && !cx < right_edge then begin
        let p_bg = if r.full_bleed_bg then body_bg else base_bg in
        let p_style =
          Style.make ~fg:(Color.of_rgb r.prefix_fg) ~bg:p_bg
            ~attrs:r.prefix_attrs ()
        in
        let adv =
          Cell_grid.put_text ~clip:col_rect grid ~x:!cx ~y:py ~style:p_style
            r.prefix
        in
        cx := !cx + adv
      end;
      if (not r.full_bleed_bg) && r.bg_rgb <> theme.surface_1 && !cx < right_edge
      then begin
        let b_rect = Rect.make ~x:!cx ~y:py ~w:(right_edge - !cx) ~h:1 in
        Cell_grid.fill_rect ~clip:col_rect grid ~rect:b_rect
          ~style:(Typography.primary ~bg:body_bg theme) ()
      end;
      let meta_reserved =
        match r.right_meta with
        | Some m when String.length m > 0 -> Grapheme.display_width m + 2
        | Some _ | None -> 0
      in
      let span_limit =
        if meta_reserved > 0 && right_edge - !cx > meta_reserved + 6 then
          right_edge - meta_reserved
        else right_edge
      in
      let span_clip =
        Rect.make ~x:!cx ~y:py ~w:(Int.max 0 (span_limit - !cx)) ~h:1
      in
      List.iter
        (fun (sp : Markdown.styled_span) ->
          if !cx < span_limit && String.length sp.text > 0 then begin
            (* Preserve Markdown's explicit fenced-code (surface_0) & inline-code (surface_2) bgs! *)
            let st =
              if Color.equal sp.style.bg (Color.of_rgb theme.surface_1) then
                Style.with_bg body_bg sp.style
              else sp.style
            in
            let st =
              match sp.hyperlink with
              | Some uri ->
                  let id = Cell_grid.intern_hyperlink grid uri in
                  Style.with_hyperlink id st
              | None -> st
            in
            let adv =
              Cell_grid.put_text ~clip:span_clip grid ~x:!cx ~y:py ~style:st
                sp.text
            in
            cx := !cx + adv
          end)
        r.spans;
      match r.right_meta with
      | Some m when String.length m > 0 && right_edge > !cx + 1 ->
          let mw = Int.min (Grapheme.display_width m) (right_edge - !cx - 1) in
          let mx = right_edge - mw in
          let m_fg =
            match r.right_meta_fg with Some c -> c | None -> theme.text_muted
          in
          let m_bg = if r.full_bleed_bg then body_bg else base_bg in
          let m_st =
            Style.make ~fg:(Color.of_rgb m_fg) ~bg:m_bg
              ~attrs:r.right_meta_attrs ()
          in
          ignore
            (Ops_common.put_line ~clip:col_rect grid ~x:mx ~y:py ~max_w:mw
               ~style:m_st m)
      | Some _ | None -> ()
    done

let render_empty_chat_context grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~name ~hist_obs
    (keeper_opt : Wire_fleet.keeper_summary option) =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = Ops_common.pad_x_for ~model rect in
    let inner_c = Card.pad_inner ~pad_x rect in
    let col_w = Int.min inner_c.w 96 in
    let panel = Rect.make ~x:inner_c.x ~y:inner_c.y ~w:col_w ~h:inner_c.h in
    if Rect.is_empty panel then ()
    else
      match hist_obs with
      | Observed.Loading _ ->
          (* Pillar 3: During initial history fetch, show a calm left-aligned
             1-line loading whisper on surface_1 — never flash a floating
             centered surface_2 rectangle. *)
          ignore
            (Ops_common.put_line ~clip:panel grid ~x:panel.x ~y:panel.y
               ~max_w:panel.w
               ~style:(Typography.status ~bg ~italic:true theme Theme.Status_active)
               (Glyph.to_utf8 Glyph.Transport_reconnecting ^ " "
                ^ Ops_common.say model ~ko:"대화 이력을 불러오는 중…"
                    ~en:"Loading chat history…"))
      | Observed.Value _ | Observed.Absent | Observed.Unreported
      | Observed.Failed _ ->
          let y = ref panel.y in
          let bot = Rect.bottom panel in
          let has_attn = Ops_common.keeper_has_attention model.attention name in
          let company_s, rt_s, status_s, task_s, turns_s =
            match keeper_opt with
            | Some k ->
                let g, _, slbl =
                  Ops_common.keeper_live_status ~has_attention:has_attn k
                in
                let rt = Ops_common.human_runtime_label ~model k in
                let tk =
                  match k.current_task_id with
                  | Some tid -> tid
                  | None -> Ops_common.keeper_turn_summary ~lang:model.lang k
                in
                let tr =
                  Format_val.format_observed Format_val.Count
                    (Observed.map Float.of_int k.total_turns)
                    ~lang:model.lang
                in
                ( k.company
                , rt
                , Glyph.to_utf8 g ^ " " ^ Say.resolve model.lang slbl
                , tk
                , tr )
            | None ->
                let dash = Glyph.to_utf8 Glyph.Missing_absent in
                ( dash
                , dash
                , Glyph.to_utf8 Glyph.Live_idle ^ " " ^ dash
                , dash
                , dash )
          in
          let sb_lbl, sb_tone = Ops_common.keeper_sandbox_label ~model name in
          let candle_s =
            match Ops_common.keeper_candle_milli ~model name with
            | Some (_, dec) ->
                Glyph.to_utf8 Glyph.Ai_spark ^ " "
                ^ Ops_common.format_milli_string dec
            | None -> Glyph.to_utf8 Glyph.Missing_absent
          in
          (* 1. Calm left-aligned surface_1 Identity Header (NO centered surface_2 rectangle) *)
          if !y < bot then begin
            let hdr_left = Printf.sprintf "@%s  %s" name status_s in
            let adv =
              Ops_common.put_line ~clip:panel grid ~x:panel.x ~y:!y
                ~max_w:panel.w ~style:(Typography.anchor ~bg theme) hdr_left
            in
            let sub = Printf.sprintf "  %s · %s" company_s sb_lbl in
            if panel.w - adv >= 8 then
              ignore
                (Ops_common.put_line ~clip:panel grid ~x:(panel.x + adv) ~y:!y
                   ~max_w:(panel.w - adv) ~style:(Typography.whisper ~bg theme)
                   sub);
            incr y
          end;
          if !y < bot then begin
            Card.draw_hairline ~pad_x:0 ~bg grid ~rect:panel ~y:!y ~theme;
            incr y
          end;
          let spec_r =
            Rect.make ~x:panel.x ~y:!y ~w:panel.w ~h:(Int.max 0 (bot - !y))
          in
          (* 2. Compact 3-line Spec Strip *)
          if !y < bot then begin
            Ops_common.draw_kv_row grid ~rect:spec_r ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"런타임" ~en:"Runtime")
              ~value:rt_s ();
            incr y
          end;
          if !y < bot then begin
            Ops_common.draw_kv_row grid ~rect:spec_r ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"격리 · 작업" ~en:"Sandbox / Task")
              ~value:(Printf.sprintf "%s · %s" sb_lbl task_s)
              ~val_fg:(Theme.status_color theme sb_tone) ();
            incr y
          end;
          if !y < bot then begin
            Ops_common.draw_kv_row grid ~rect:spec_r ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"누적 턴 · 캔들" ~en:"Total · Candle")
              ~value:
                (Printf.sprintf "%s %s  ·  %s" turns_s
                   (Ops_common.say model ~ko:"누적 턴" ~en:"total turns")
                   candle_s)
              ~val_fg:theme.status_ai ();
            incr y
          end;
          (* 3. Honest observation status *)
          if !y < bot then begin
            Card.draw_hairline ~pad_x:0 ~bg grid ~rect:spec_r ~y:!y ~theme;
            incr y
          end;
          if !y < bot then begin
            (match hist_obs with
            | Observed.Failed { reason; _ } ->
                Card.draw_left_rail ~bg ~tone:Theme.Status_critical grid
                  ~x:spec_r.x ~y:!y ~h:1 ~theme;
                ignore
                  (Ops_common.put_line ~clip:spec_r grid ~x:(spec_r.x + 2) ~y:!y
                     ~max_w:(Int.max 0 (spec_r.w - 2))
                     ~style:
                       (Typography.status ~bg ~bold:true theme
                          Theme.Status_critical)
                     (Glyph.to_utf8 Glyph.Live_failing ^ " "
                      ^ Ops_common.say model
                          ~ko:("대화 이력 조회 실패: " ^ reason)
                          ~en:("Chat history fetch failed: " ^ reason)))
            | Observed.Loading _ -> ()
            | Observed.Value _ | Observed.Absent | Observed.Unreported ->
                ignore
                  (Ops_common.put_line ~clip:spec_r grid ~x:spec_r.x ~y:!y
                     ~max_w:spec_r.w ~style:(Typography.whisper ~bg theme)
                     (Ops_common.say model
                        ~ko:"아직 대화 이력이 없습니다 · 아래 예시로 바로 대화를 시작하세요."
                        ~en:"No conversation history yet · try one of these starters:")));
            incr y
          end;
          (* 4. Three Violet-railed italic example prompt starters *)
          let starters =
            [
              Ops_common.say model
                ~ko:"\"현재 진행 중인 작업과 차단 요인을 요약해줘\""
                ~en:"\"Summarize your current task and any blockers\"";
              Ops_common.say model
                ~ko:"\"최근 24시간 기억 변경 사항과 핵심 결정을 알려줘\""
                ~en:"\"What changed in your memory over the last 24h?\"";
              Ops_common.say model
                ~ko:"\"/help  ·  [i] 메시지 입력  ·  [V] 음성 PTT\""
                ~en:"\"/help  ·  [i] Compose message  ·  [V] Voice PTT\"";
            ]
          in
          List.iter
            (fun prompt ->
              if !y < bot then begin
                Card.draw_left_rail ~bg ~tone:Theme.Status_ai grid ~x:spec_r.x
                  ~y:!y ~h:1 ~theme;
                let caret_adv =
                  Ops_common.put_line ~clip:spec_r grid ~x:(spec_r.x + 2) ~y:!y
                    ~max_w:2 ~style:(Typography.ai ~bg theme)
                    (Glyph.to_utf8 Glyph.Prompt_caret ^ " ")
                in
                ignore
                  (Ops_common.put_line ~clip:spec_r grid
                     ~x:(spec_r.x + 2 + caret_adv) ~y:!y
                     ~max_w:(Int.max 0 (spec_r.w - 2 - caret_adv))
                     ~style:(Typography.whisper ~bg theme)
                     prompt);
                incr y
              end)
            starters

let draw_keeper_status_strip grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~activity =
  if not (Rect.is_empty rect) then begin
    let bg = Color.of_rgb theme.surface_1 in
    let activity =
      Option.map
        (fun (glyph, tone, label) ->
          (Glyph.to_utf8 glyph ^ " ", tone, Say.resolve model.lang label))
        activity
    in
    let voice_error =
      match model.drafts.voice with
      | Drafts.Voice_error error ->
          let label = Ops_common.say model ~ko:"음성 오류" ~en:"Voice error" in
          Some (label, label ^ Typography.sep_dot ^ error)
      | Drafts.Voice_recording _ | Drafts.Voice_transcribing | Drafts.Voice_off ->
          None
    in
    let available = Int.max 0 (rect.w - 4) in
    let voice_w, voice_text =
      match voice_error with
      | None -> (0, "")
      | Some (label, detail) ->
          let label_w = Grapheme.display_width label in
          let budget =
            match activity with
            | None -> available
            | Some (mark, _, activity_text) ->
                let activity_w =
                  Grapheme.display_width mark + Grapheme.display_width activity_text
                in
                Int.min available (Int.max label_w (available - activity_w - 2))
          in
          if budget <= label_w then (budget, label)
          else (Int.min budget (Grapheme.display_width detail), detail)
    in
    Option.iter
      (fun (mark, tone, label) ->
        let x = rect.x + 2 in
        let voice_reserve = if voice_w > 0 then voice_w + 2 else 0 in
        let max_w = Int.max 0 (available - voice_reserve) in
        let glyph_w =
          Ops_common.put_line ~clip:rect grid ~x ~y:rect.y ~max_w
            ~style:(Typography.status ~bg ~bold:true theme tone) mark
        in
        ignore
          (Ops_common.put_line ~clip:rect grid ~x:(x + glyph_w) ~y:rect.y
             ~max_w:(Int.max 0 (max_w - glyph_w))
             ~style:(Typography.primary ~bg theme) label))
      activity;
    if voice_w > 0 then
      let x =
        if Option.is_some activity then Rect.right rect - voice_w - 2
        else rect.x + 2
      in
      ignore
        (Ops_common.put_line ~clip:rect grid ~x ~y:rect.y ~max_w:voice_w
           ~style:(Typography.status ~bg theme Theme.Status_attention) voice_text)
  end

let render_chat_tab grid ~(rect : Rect.t) ~(theme : Theme.t) ~(model : Model.t)
    ~name keeper_opt =
  if Rect.is_empty rect then ()
  else
    let status_h = if rect.h >= 2 then 1 else 0 in
    let body_rect, status_rect =
      Rect.split_v rect ~top_h:(Int.max 0 (rect.h - status_h))
    in
    let pad_x = Ops_common.pad_x_for ~model body_rect in
    let prose_w =
      Int.max 16 (Int.min (Int.max 16 (body_rect.w - (2 * pad_x))) 96)
    in
    let hist_obs =
      match Fleet_store.String_map.find_opt name model.fleet.chat_histories with
      | Some o -> o
      | None -> Observed.unreported
    in
    let sections = Chat_transcript.project_transcript ~model ~keeper:name in
    let all_rows =
      let _, rev_rows =
        List.fold_left
          (fun (first, acc) sec ->
            let sec_rows =
              match sec with
              | Chat_transcript.Section_history msgs ->
                  build_history_rows ~theme ~model ~keeper_name:name
                    ~width:prose_w msgs
              | Chat_transcript.Section_active_turn turn ->
                  build_active_turn_rows ~theme ~model ~keeper:name ~width:prose_w turn
              | Chat_transcript.Section_pending items ->
                  build_pending_tx_rows ~theme ~model ~width:prose_w items
              | Chat_transcript.Section_stream sp ->
                  build_stream_rows ~theme ~model ~keeper_name:name
                    ~width:prose_w sp
            in
            if sec_rows = [] then (first, acc)
            else
              let with_sep =
                if first then sec_rows
                else blank_row ~bg_rgb:theme.surface_1 :: sec_rows
              in
              (false, List.rev_append with_sep acc))
          (true, []) sections
      in
      List.rev rev_rows
    in
    if all_rows = [] then
      render_empty_chat_context grid ~rect:body_rect ~theme ~model ~name
        ~hist_obs keeper_opt
    else begin
      draw_transcript_rows grid ~rect:body_rect ~theme ~model ~pad_x
        ~scroll:model.fleet.chat_scroll_offset all_rows;
      let total_r = List.length all_rows in
      let max_s = Int.max 0 (total_r - body_rect.h) in
      let clamped_s = Int.max 0 (Int.min max_s model.fleet.chat_scroll_offset) in
      if clamped_s > 0 && body_rect.h >= 2 then begin
        let cue_y = Rect.bottom body_rect - 1 in
        let cue_r =
          Rect.make ~x:body_rect.x ~y:cue_y ~w:body_rect.w ~h:1
        in
        let cue_bg = Color.of_rgb theme.surface_2 in
        Cell_grid.fill_rect ~clip:body_rect grid ~rect:cue_r
          ~style:(Typography.accent ~bg:cue_bg ~bold:true theme) ();
        let cue_txt =
          Ops_common.say model
            ~ko:(Printf.sprintf "↓ 아래 %d줄 · [End] 최신 따라가기" clamped_s)
            ~en:(Printf.sprintf "↓ %d lines below · [End] Follow" clamped_s)
        in
        ignore
          (Ops_common.put_line ~clip:cue_r grid ~x:(body_rect.x + pad_x)
             ~y:cue_y ~max_w:(Int.max 0 (body_rect.w - (2 * pad_x)))
             ~style:(Typography.accent ~bg:cue_bg ~bold:true theme) cue_txt)
      end
    end;
    if status_h = 1 then
      let activity = Chat_transcript.live_chat_phase_badge ~model ~keeper:name in
      draw_keeper_status_strip grid ~rect:status_rect ~theme ~model ~activity

(* --- Tab 2: Memory (Rich Explorer + 24-bin Age Ladder + Braille Trend + Librarian) --- *)

let writer_state_badge = function
  | Wire_knowledge.Writer_open ->
      (Glyph.Live_healthy, Theme.Status_ok, Say.make ~ko:"기록 가능" ~en:"Open")
  | Wire_knowledge.Writer_idle ->
      (Glyph.Live_idle, Theme.Status_ok, Say.make ~ko:"유휴" ~en:"Idle")
  | Wire_knowledge.Writer_asking ->
      (Glyph.Action_required, Theme.Status_attention, Say.make ~ko:"질문 중" ~en:"Asking")
  | Wire_knowledge.Writer_resting ->
      (Glyph.Live_paused, Theme.Status_historical, Say.make ~ko:"휴식 중" ~en:"Resting")
  | Wire_knowledge.Writer_refused_at_bottom ->
      (Glyph.Warning_triangle, Theme.Status_attention, Say.make ~ko:"바닥 거절" ~en:"Refused")
  | Wire_knowledge.Writer_booting ->
      (Glyph.Live_working, Theme.Status_active, Say.make ~ko:"기동 중" ~en:"Booting")
  | Wire_knowledge.Writer_retired ->
      (Glyph.Live_paused, Theme.Status_historical, Say.make ~ko:"은퇴" ~en:"Retired")
  | Wire_knowledge.Writer_stopped reason ->
      ( Glyph.Live_failing
      , Theme.Status_critical
      , Say.make ~ko:("중지: " ^ reason) ~en:("Stopped: " ^ reason) )
  | Wire_knowledge.Writer_no_writer ->
      (Glyph.Missing_absent, Theme.Status_historical, Say.make ~ko:"라이터 없음" ~en:"No Writer")

let render_memory_tab grid ~(rect : Rect.t) ~(theme : Theme.t) ~(model : Model.t)
    ~name ~focused =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = Ops_common.pad_x_for ~model rect in
    let subbar_h = if rect.h >= 4 then 1 else 0 in
    let subbar_rect, rect =
      if subbar_h = 1 then Rect.split_v rect ~top_h:1
      else (Rect.empty, rect)
    in
    if subbar_h = 1 then begin
      let ksv = model.knowledge.keeper_memory_subview in
      let sub_pills =
        [
          ( Ops_common.say model ~ko:"[v] 탐색·Diff" ~en:"[v] Explorer & Diff"
          , Knowledge_store.equal_keeper_memory_subview ksv
              Knowledge_store.Kmem_diff_flow
          , Some Theme.Status_active );
          ( Ops_common.say model ~ko:"헬스" ~en:"Health"
          , Knowledge_store.equal_keeper_memory_subview ksv
              Knowledge_store.Kmem_health
          , Some Theme.Status_ok );
          ( Ops_common.say model ~ko:"팩트 트리" ~en:"Facts Tree"
          , Knowledge_store.equal_keeper_memory_subview ksv
              Knowledge_store.Kmem_facts_tree
          , Some Theme.Status_ai );
          ( Ops_common.say model ~ko:"저널" ~en:"Journal"
          , Knowledge_store.equal_keeper_memory_subview ksv
              Knowledge_store.Kmem_journal
          , Some Theme.Status_attention );
        ]
      in
      ignore (Ops_common.draw_pills grid ~rect:subbar_rect ~theme ~bg sub_pills)
    end;
    match model.knowledge.memory_diagram with
    | Some diagram
      when Knowledge_store.memory_diagram_matches_scope
             ~keeper_opt:(Some name) diagram ->
        let content = Card.pad_inner ~pad_x rect in
        Masc_tui_screens_core.Memory_explorer.render_memory_diagram ~grid
          ~rect:content ~theme ~lang:model.lang ~diagram
    | Some _ | None ->
    if
      not
        (Knowledge_store.equal_keeper_memory_subview
           model.knowledge.keeper_memory_subview Knowledge_store.Kmem_diff_flow)
    then begin
      let content = Card.pad_inner ~pad_x rect in
      if not (Rect.is_empty content) then begin
        let lines =
          Update_nav.keeper_memory_subview_lines ~width:content.w ~name
            model.knowledge
        in
        let line_count = List.length lines in
        let chart_rows =
          if
            Knowledge_store.equal_keeper_memory_subview
              model.knowledge.keeper_memory_subview Knowledge_store.Kmem_health
          then
            (* Charts use the rows left after the scrollable diagnostics. *)
            let chart_space, _ =
              Rect.split_v content ~top_h:(Int.max 0 (content.h - line_count))
            in
            Masc_tui_screens_core.Memory_explorer.render_keeper_health_charts
              ~grid ~rect:chart_space ~theme ~model ~keeper:name
          else 0
        in
        let _, content = Rect.split_v content ~top_h:chart_rows in
        let max_skip = Int.max 0 (line_count - content.h) in
        let skip =
          Int.min max_skip (Int.max 0 model.nav.dive_scroll_offset)
        in
        let y = ref content.y and bot = Rect.bottom content in
        List.iter
          (fun ln ->
            if !y < bot then begin
              let is_sel = String.starts_with ~prefix:">" ln in
              let row_rect =
                Rect.make ~x:content.x ~y:!y ~w:content.w ~h:1
              in
              let row_bg =
                if is_sel then Color.of_rgb theme.selection_bg else bg
              in
              if is_sel then
                Cell_grid.fill_rect ~clip:content grid ~rect:row_rect
                  ~style:(Style.make ~fg:(Color.of_rgb theme.text_primary) ~bg:row_bg ())
                  ();
              let st =
                if is_sel then Typography.anchor ~bg:row_bg theme
                else if String.starts_with ~prefix:"──" ln then
                  Typography.status ~bg ~bold:true theme Theme.Status_active
                else if String.starts_with ~prefix:"  [error" ln then
                  Typography.status ~bg theme Theme.Status_critical
                else if String.starts_with ~prefix:"  [warn" ln then
                  Typography.status ~bg theme Theme.Status_attention
                else Typography.structure ~bg theme
              in
              ignore
                (Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                   ~max_w:content.w ~style:st ln);
              incr y
            end)
          (Store_scroll.drop skip lines)
      end
    end
    else begin
    let footer_h = if rect.h >= 7 then 2 else 0 in
    let body_rect, writer_rect =
      Rect.split_v rect ~top_h:(Int.max 0 (rect.h - footer_h))
    in
    let content = Card.pad_inner ~pad_x body_rect in
    let writer_c = Card.pad_inner ~pad_x writer_rect in
    let draw_librarian_footer (ws_opt : Wire_knowledge.keeper_writer_status option) =
      if footer_h >= 2 && not (Rect.is_empty writer_c) then begin
        Card.draw_hairline ~pad_x:0 ~bg
          ~label:
            (Ops_common.say model ~ko:"사서 라이터 · 복구 액션"
               ~en:"Librarian Writer & Recovery")
          grid ~rect:writer_c ~y:writer_c.y ~theme;
        let py = writer_c.y + 1 in
        let format_snap = function
          | Some (Wire_knowledge.Snapshot_file_present { sha; _ }) ->
              let short =
                if String.length sha > 8 then String.sub sha 0 8 else sha
              in
              " · snap:" ^ short
          | Some (Wire_knowledge.Snapshot_file_fault f) -> " · snap:" ^ f
          | None -> ""
        in
        let status_line, tone =
          match ws_opt with
          | Some
              (Wire_knowledge.Keeper_writer_active
                 { state; available_act_tokens; snapshot_file }) ->
              let g, t, lbl = writer_state_badge state in
              let snap = format_snap snapshot_file in
              let acts =
                if available_act_tokens = [] then ""
                else
                  "  " ^ Glyph.to_utf8 Glyph.Separator_dot ^ " "
                  ^ Ops_common.say model ~ko:"복구: " ~en:"Acts: "
                  ^ String.concat " "
                      (List.map (fun tok -> "[" ^ tok ^ "]") available_act_tokens)
              in
              (Glyph.to_utf8 g ^ " " ^ Say.resolve model.lang lbl ^ snap ^ acts, t)
          | Some Wire_knowledge.Keeper_writer_none ->
              ( Glyph.to_utf8 Glyph.Missing_absent ^ " "
                ^ Ops_common.say model ~ko:"활성 라이터 없음" ~en:"No active writer"
              , Theme.Status_historical )
          | Some Wire_knowledge.Keeper_writer_none_in_process ->
              ( Glyph.to_utf8 Glyph.Live_paused ^ " "
                ^ Ops_common.say model ~ko:"프로세스 내 라이터 비활성"
                    ~en:"No in-process writer"
              , Theme.Status_historical )
          | None -> (
              match Observed.to_option model.knowledge.world_memory with
              | Some wm -> (
                  match wm.librarian_writers with
                  | Wire_knowledge.Writers_running { keepers; _ } -> (
                      match
                        List.find_opt
                          (fun (r : Wire_knowledge.librarian_writer_row) ->
                            String.equal r.keeper name)
                          keepers
                      with
                      | Some row ->
                          let g, t, lbl = writer_state_badge row.state in
                          let snap = format_snap row.snapshot_file in
                          let acts =
                            if row.available_act_tokens = [] then ""
                            else
                              " " ^ Glyph.to_utf8 Glyph.Separator_dot ^ " "
                              ^ String.concat " "
                                  (List.map (fun tk -> "[" ^ tk ^ "]")
                                     row.available_act_tokens)
                          in
                          ( Glyph.to_utf8 g ^ " " ^ Say.resolve model.lang lbl
                            ^ snap ^ acts
                          , t )
                      | None ->
                          ( Glyph.to_utf8 Glyph.Live_idle ^ " "
                            ^ Ops_common.say model ~ko:"대기 중" ~en:"Standing by"
                          , Theme.Status_historical ))
                  | Wire_knowledge.Writers_none_in_process ->
                      ( Glyph.to_utf8 Glyph.Missing_absent ^ " "
                        ^ Ops_common.say model ~ko:"라이터 없음" ~en:"No writer"
                      , Theme.Status_historical ))
              | None ->
                  ( Glyph.to_utf8 Glyph.Missing_unreported ^ " "
                    ^ Ops_common.say model ~ko:"라이터 상태 미보고"
                        ~en:"Writer unreported"
                  , Theme.Status_historical ))
        in
        let act_receipt =
          match model.knowledge.last_memory_act_answer with
          | Some (k, ans) when String.equal k name -> (
              match ans with
              | Wire_knowledge.Memory_act_done st ->
                  let _, _, lbl = writer_state_badge st in
                  " · " ^ Ops_common.say model ~ko:"최근 결과: " ~en:"Last: "
                  ^ Say.resolve model.lang lbl
              | Wire_knowledge.Memory_act_refused { code; _ } ->
                  " · " ^ Ops_common.say model ~ko:"거절: " ~en:"Refused: " ^ code
              | Wire_knowledge.Memory_act_invalid msg -> " · " ^ msg
              | Wire_knowledge.Memory_act_no_writer ->
                  " · " ^ Ops_common.say model ~ko:"라이터 없음" ~en:"No writer")
          | Some _ | None -> ""
        in
        ignore
          (Ops_common.put_line ~clip:writer_c grid ~x:writer_c.x ~y:py
             ~max_w:writer_c.w
             ~style:(Typography.status ~bg theme tone)
             (status_line ^ act_receipt))
      end
    in
    let writer_status_opt =
      match
        Observed.to_option
          (Knowledge_store.memory_diff_for ~keeper:(Some name)
             ~window:model.knowledge.memory_diff_window model.knowledge)
      with
      | Some
          {
            scope = Wire_knowledge.Scope_keeper kp;
            body = Wire_knowledge.Keeper_diff { writer_status; _ };
            _;
          }
        when String.equal kp name ->
          writer_status
      | Some
          {
            scope = Wire_knowledge.Scope_world | Wire_knowledge.Scope_keeper _;
            body = Wire_knowledge.Keeper_diff _ | Wire_knowledge.World_diff _;
            _;
          }
      | None ->
          None
    in
    Masc_tui_screens_core.Memory_explorer.render_keeper_memory ~grid
      ~rect:content ~theme ~bp:(Ops_common.layout_bp model) ~model ~keeper:name
      ~focused ~diff_scroll:model.nav.dive_scroll_offset;
    draw_librarian_footer writer_status_opt
    end

(* --- Tab 3: Work & Candle (ZERO Nested Boxes — uses v_hairline / hairline!) --- *)

let render_board_recovery grid ~(rect : Rect.t) ~theme ~(model : Model.t) ~name =
  let module Q = Board_quarantine in
  let say = Ops_common.say model in
  let e = Board_recovery.entry ~keeper:name model.knowledge.board_recovery in
  let area = Card.pad_inner ~pad_x:(Ops_common.pad_x_for ~model rect) rect in
  let y = ref area.y in
  let line style text =
    if !y < area.y + area.h then begin
      ignore (Cell_grid.put_text ~clip:area grid ~x:area.x ~y:!y ~style text);
      incr y
    end
  in
  let value = Typography.primary theme and detail = Typography.structure theme in
  let warn = Typography.status theme Theme.Status_attention in
  let error = Typography.status theme Theme.Status_critical in
  line (Typography.anchor theme) (say ~ko:"Board 격리 복구" ~en:"Board quarantine recovery" ^ " · @" ^ name);
  line detail (say ~ko:"↑↓ 후보 선택 · r 목록 새로고침 · v 작업·캔들"
                  ~en:"↑↓ select candidate · r refresh · v Work & Candle");
  let inventory = Observed.to_option e.inventory in
  (match e.command with
   | Board_recovery.Idle -> ()
   | Board_recovery.Submitting target ->
       line warn (say ~ko:"복구 요청 전송 중" ~en:"Submitting recovery" ^ " · " ^ target.candidate_id)
   | Board_recovery.Result (target, outcome) ->
       let label = match outcome with
         | Board_recovery.Accepted { wake; audit } ->
             let wake_label = match wake with
               | Q.Signaled -> say ~ko:"작업자에 알림" ~en:"Worker signaled"
               | Q.Coalesced -> say ~ko:"기존 작업자 알림에 병합" ~en:"Worker wake coalesced"
               | Q.Not_registered -> say ~ko:"등록된 작업자 없음" ~en:"No worker registered" in
             let audit_label = match audit with
               | Q.Recorded -> ""
               | Q.Recording_failed -> " · " ^ say ~ko:"감사 기록 실패" ~en:"Audit recording failed" in
             say ~ko:"서버 접수" ~en:"Server accepted" ^ " · " ^ wake_label ^ audit_label
         | Rejected reason -> say ~ko:"서버 거절" ~en:"Rejected" ^ " · " ^ reason
         | Unconfirmed reason -> say ~ko:"결과 미확인" ~en:"Outcome unconfirmed" ^ " · " ^ reason in
       line warn (label ^ " · " ^ target.candidate_id);
       Option.iter (fun (current : Q.inventory) ->
         let read_back = match List.find_opt (Q.same_candidate target) current.items with
           | Some item -> Q.inventory_phase_to_string item.phase
           | None when current.errors <> [] -> say ~ko:"원장 읽기 불완전" ~en:"Incomplete ledger read"
           | None -> say ~ko:"같은 격리 ID가 목록에 없음" ~en:"Quarantine generation absent" in
         line detail (say ~ko:"같은 후보 재조회" ~en:"Read-back" ^ " · " ^ read_back)) inventory);
  match e.inventory with
  | Observed.Unreported | Observed.Loading _ | Observed.Absent ->
      line detail (say ~ko:"격리 원장 조회 중…" ~en:"Reading quarantine ledger…")
  | Observed.Failed { reason; _ } ->
      line error (say ~ko:"격리 원장 조회 실패" ~en:"Quarantine read failed" ^ " · " ^ reason)
  | Observed.Value { data; stale; _ } ->
      List.iter (fun (failure : Q.inventory_error) ->
        line error (Q.inventory_error_kind_to_string failure.kind)) data.errors;
      if data.items = [] && data.errors = [] then line detail (say ~ko:"격리 기록 없음" ~en:"No quarantine records");
      let index = Board_recovery.selection_index e in
      (match Option.bind index (List.nth_opt data.items) with
       | None when data.items <> [] ->
           line warn (say ~ko:"선택한 격리가 바뀌었습니다. ↑↓로 후보를 선택하세요."
                          ~en:"The selected generation changed. Use ↑↓ to select a candidate.")
       | None -> ()
       | Some item ->
           if Option.is_some (Board_recovery.actionable e) then
             line (Typography.accent theme) (say ~ko:"c  확인 후 재큐잉" ~en:"c  Acknowledge and requeue");
           let identity key id =
             Memory_lineage.wrap_full_lines ~max_cells:(max 1 area.w) (key ^ " " ^ id)
             |> List.iter (line value) in
           identity "candidate" item.candidate_id;
           identity "partition" item.partition_id;
           identity "quarantine" item.quarantine_id;
           line detail (Q.quarantine_failure_category_to_string item.failure_category ^ " · " ^
                        Q.inventory_phase_to_string item.phase));
      if stale then line warn (say ~ko:"마지막 관측 · r 새로고침" ~en:"Last observation · r refresh");
      let space = max 0 (area.y + area.h - !y) in
      let at = Option.value index ~default:0 in
      let start = max 0 (min (List.length data.items - space) (at - space + 1)) in
      List.drop start data.items |> List.take space |> List.iteri (fun offset (item : Q.inventory_item) ->
        let selected = Option.equal Int.equal (Some (offset + start)) index in
        line (if selected then Typography.anchor theme else value)
          ((if selected then "› " else "  ") ^ Q.inventory_phase_to_string item.phase ^ " · " ^ item.candidate_id))

let render_work_candle_tab grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~name =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = Ops_common.pad_x_for ~model rect in
    let is_hsplit = rect.w >= 76 in
    let left_rect, right_rect =
      if is_hsplit then
        match Layout.split_h ~gap:3 rect [ Layout.Ratio 0.54; Layout.Flex 1 ] with
        | [ l; r ] -> (l, r)
        | _ -> (rect, Rect.empty)
      else
        match Layout.split_v ~gap:1 rect [ Layout.Ratio 0.56; Layout.Flex 1 ] with
        | [ t; b ] -> (t, b)
        | _ -> (rect, Rect.empty)
    in
    if is_hsplit && not (Rect.is_empty right_rect) && right_rect.x >= 2 then
      Card.draw_v_hairline ~bg grid ~x:(right_rect.x - 2) ~y:rect.y ~h:rect.h
        ~theme;
    (* Left/Top: Assigned Tasks + Schedules + Board posts *)
    let l_content = Card.pad_inner ~pad_x left_rect in
    let keeper_tasks =
      List.filter
        (fun (tk : Wire_work.task) ->
          match Ops_common.task_assignee_opt tk.status with
          | Some a -> String.equal a name
          | None -> false)
        (Work_store.tasks model.work)
    in
    let keeper_scheds =
      Keeper_cadence.keeper_schedules ~name (Work_store.schedules_list model.work)
    in
    let keeper_posts =
      List.filter
        (fun (p : Wire_knowledge.board_post) -> String.equal p.author name)
        (Knowledge_store.filtered_posts model.knowledge)
    in
    let rows_acc = ref [] in
    let push_hairline label = rows_acc := `Hairline label :: !rows_acc in
    let push_line ~fg ~attrs line =
      rows_acc := `Line (fg, attrs, line) :: !rows_acc
    in
    push_line ~fg:theme.text_secondary ~attrs:Attr.none
      (Ops_common.say model ~ko:"[v] Board 격리 복구" ~en:"[v] Board quarantine recovery");
    let now_unix = model.freshness.last_wall_unix in
    let say = Ops_common.say model in
    push_hairline (say ~ko:"주기" ~en:"Cadence");
    (match Fleet_store.turn_pulse model.fleet name with
     | None ->
         push_line ~fg:theme.text_muted ~attrs:Attr.italic
           (say ~ko:"서버가 보낸 턴 기록이 없습니다" ~en:"The server sent no turn pulse")
     | Some pulse ->
         List.iter
           (fun hours ->
             let w = Keeper_cadence.window ~now_unix ~hours pulse in
             let rate =
               match w.known_from with
               | None ->
                   Printf.sprintf " · %s %.1f" (say ~ko:"시간당" ~en:"per hour")
                     (Float.of_int w.turns /. Float.of_int hours)
               | Some since ->
                   Printf.sprintf " · %s %s"
                     (say ~ko:"기록 시작" ~en:"counted since")
                     (Ops_common.format_age ~now_unix since ~lang:model.lang)
             in
             push_line ~fg:theme.text_primary ~attrs:Attr.none
               (Printf.sprintf "%s · %d%s%s"
                  (say
                     ~ko:(Printf.sprintf "최근 %d시간" hours)
                     ~en:(Printf.sprintf "Last %dh" hours))
                  w.turns (say ~ko:"턴" ~en:" turns") rate);
             push_line ~fg:theme.text_secondary ~attrs:Attr.none
               (Printf.sprintf "  %s %d · %s %d · %s %d · %s %d · %s %d"
                  (say ~ko:"예약" ~en:"scheduled") w.scheduled
                  (say ~ko:"반응" ~en:"reacted") w.reacted
                  (say ~ko:"채팅" ~en:"chat") w.chat
                  (say ~ko:"스스로" ~en:"own") w.own
                  (say ~ko:"모름" ~en:"unknown") w.unknown))
           Keeper_cadence.window_hours);
    let next_due_text =
      match Observed.to_option model.work.schedules with
      | None -> say ~ko:"예약 목록을 아직 못 읽음" ~en:"schedules not read yet"
      | Some (_rows, next_cursor) -> (
          match
            Keeper_cadence.next_due ~now_unix
              ~more_pages:(Option.is_some next_cursor) keeper_scheds
          with
          | Keeper_cadence.No_schedule -> say ~ko:"없음" ~en:"none"
          | Keeper_cadence.Past_page_read ->
              say ~ko:"읽은 쪽에 없음" ~en:"not on the page read"
          | Keeper_cadence.Due_unknown -> say ~ko:"시각 모름" ~en:"time unknown"
          | Keeper_cadence.Due_in sec ->
              say ~ko:(Format_val.format_duration_s sec ^ " 뒤")
                ~en:("in " ^ Format_val.format_duration_s sec)
          | Keeper_cadence.Late_by sec ->
              say ~ko:(Format_val.format_duration_s sec ^ " 늦음")
                ~en:(Format_val.format_duration_s sec ^ " late"))
    in
    push_line ~fg:theme.text_primary ~attrs:Attr.none
      (Printf.sprintf "%s · %s" (say ~ko:"다음 예약" ~en:"Next due") next_due_text);
    let total_tasks = List.length keeper_tasks in
    push_hairline
      (Printf.sprintf "%s (%d)"
         (Ops_common.say model ~ko:"할당 작업" ~en:"Assigned Tasks")
         total_tasks);
    if keeper_tasks = [] then
      push_line ~fg:theme.text_muted ~attrs:Attr.italic
        (Ops_common.say model ~ko:"할당된 작업이 없습니다" ~en:"No assigned tasks")
    else
      List.iter
        (fun (tk : Wire_work.task) ->
          let g, tok, _ = Ops_common.task_status_badge tk.status in
          let gl =
            match tk.goal_link with
            | Wire_work.Linked gid -> "[" ^ gid ^ "]"
            | Wire_work.Unlinked ->
                Glyph.to_utf8 Glyph.Warning_triangle ^ " "
                ^ Ops_common.say model ~ko:"미연결" ~en:"unlinked"
          in
          push_line ~fg:(Theme.status_color theme tok) ~attrs:Attr.none
            (Printf.sprintf "%s %s %s %s" (Glyph.to_utf8 g) tk.id tk.title gl))
        keeper_tasks;
    let total_scheds = List.length keeper_scheds in
    push_hairline
      (Printf.sprintf "%s (%d)"
         (Ops_common.say model ~ko:"예약 일정" ~en:"Schedules")
         total_scheds);
    if keeper_scheds = [] then
      push_line ~fg:theme.text_muted ~attrs:Attr.italic
        (Ops_common.say model ~ko:"등록된 일정이 없습니다" ~en:"No scheduled jobs")
    else
      List.iter
        (fun (sc : Wire_work.schedule_row) ->
          let wake_txt, wake_tok =
            Ops_common.wake_disposition_text ~lang:model.lang
              sc.last_disposition
          in
          let summary =
            match sc.payload_summary with Some s -> " · " ^ s | None -> ""
          in
          let due =
            match sc.next_due_at_unix with
            | Some at when at >= now_unix ->
                " · " ^ say ~ko:"다음 " ~en:"next " ^ Format_val.format_duration_s (at -. now_unix)
            | Some at ->
                " · " ^ say ~ko:"늦음 " ~en:"late " ^ Format_val.format_duration_s (now_unix -. at)
            | None -> ""
          in
          push_line ~fg:(Theme.status_color theme wake_tok) ~attrs:Attr.none
            (Printf.sprintf "%s%s · %s%s" sc.recurrence_summary due wake_txt summary))
        keeper_scheds;
    let total_posts = List.length keeper_posts in
    push_hairline
      (Printf.sprintf "%s (%d)"
         (Ops_common.say model ~ko:"최근 보드 글" ~en:"Recent Board Posts")
         total_posts);
    if keeper_posts = [] then
      push_line ~fg:theme.text_muted ~attrs:Attr.italic
        (Ops_common.say model ~ko:"최근 보드 작성 글 없음"
           ~en:"No recent board posts")
    else
      List.iter
        (fun (p : Wire_knowledge.board_post) ->
          let hearth =
            match p.hearth with Some h -> "#" ^ h | None -> "#all"
          in
          push_line ~fg:theme.text_primary ~attrs:Attr.none
            (Printf.sprintf "%s %s (%s+%d · %dc)" hearth p.title
               (Glyph.to_utf8 Glyph.Delta_up)
               p.score p.comment_count))
        keeper_posts;
    let rows = List.rev !rows_acc in
    let vis_h = Int.max 1 l_content.h in
    let max_skip = Int.max 0 (List.length rows - vis_h) in
    let skip = Int.min max_skip (Int.max 0 model.nav.dive_scroll_offset) in
    let y = ref l_content.y in
    let bottom = Rect.bottom l_content in
    List.iter
      (function
        | `Hairline label ->
            if !y < bottom then begin
              Card.draw_hairline ~pad_x:0 ~bg ~label grid ~rect:l_content ~y:!y
                ~theme;
              incr y
            end
        | `Line (fg, attrs, line) ->
            if !y < bottom then begin
              let st = Style.make ~fg:(Color.of_rgb fg) ~bg ~attrs () in
              ignore
                (Ops_common.put_line ~clip:l_content grid ~x:l_content.x ~y:!y
                   ~max_w:l_content.w ~style:st line);
              incr y
            end)
      (Store_scroll.drop skip rows);
    (* Right/Bottom: Candle Balance + Violet Half-Life Decay Gauge + Portrait Ornaments (NO nested Card!) *)
    if not (Rect.is_empty right_rect) then begin
      let r_content = Card.pad_inner ~pad_x right_rect in
      if not (Rect.is_empty r_content) then begin
        let cy = ref r_content.y in
        let cbot = Rect.bottom r_content in
        Card.draw_hairline ~pad_x:0 ~bg
          ~label:
            (Glyph.to_utf8 Glyph.Ai_spark ^ " "
             ^ Ops_common.say model ~ko:"캔들 · 초상화 장신구"
                 ~en:"Candle & Ornaments")
          grid ~rect:r_content ~y:!cy ~theme;
        incr cy;
        match model.work.candle_ledger with
        | Observed.Value { data = ledger; _ } ->
            let bal_opt =
              List.find_opt
                (fun (b : Wire_work.candle_balance_row) ->
                  String.equal b.keeper name)
                ledger.balances
            in
            let nominal_milli, decayed_str, owned_items =
              match bal_opt with
              | Some b -> (b.balance_milli, b.decayed_milli, b.owned_items)
              | None -> (0, "0", [])
            in
            let decayed_f =
              match float_of_string_opt (String.trim decayed_str) with
              | Some f when Float.is_finite f -> f /. 1000.0
              | Some _ | None -> Float.of_int nominal_milli /. 1000.0
            in
            let nominal_f = Float.of_int nominal_milli /. 1000.0 in
            if !cy < cbot then begin
              Ops_common.draw_kv_row grid ~rect:r_content ~y:!cy ~theme ~bg
                ~label_w:12
                ~key:(Ops_common.say model ~ko:"현재 잔액" ~en:"Balance")
                ~value:
                  (Glyph.to_utf8 Glyph.Ai_spark ^ " "
                   ^ Ops_common.format_milli_string decayed_str)
                ~val_fg:theme.status_ai ~val_attrs:Attr.bold ();
              incr cy
            end;
            let hl_str =
              match ledger.half_life_sec with
              | Some s -> Format_val.format_duration_s s
              | None -> Glyph.to_utf8 Glyph.Missing_absent
            in
            if !cy < cbot then begin
              Ops_common.draw_kv_row grid ~rect:r_content ~y:!cy ~theme ~bg
                ~label_w:12
                ~key:(Ops_common.say model ~ko:"반감기" ~en:"Half-life")
                ~value:hl_str ~val_fg:theme.text_secondary ();
              incr cy
            end;
            if !cy + 2 <= cbot then begin
              let gauge_rect =
                Rect.make ~x:r_content.x ~y:!cy ~w:r_content.w
                  ~h:(Int.min 2 (cbot - !cy))
              in
              let gauge_used, gauge_limit =
                if nominal_f > 0.0 then
                  ( Observed.value ~observed_at:Clock.Mono.zero decayed_f
                  , Observed.value ~observed_at:Clock.Mono.zero
                      (Float.max nominal_f decayed_f) )
                else (Observed.absent, Observed.absent)
              in
              let ratio_spec : Chart.Spec.t =
                {
                  title = Say.make ~ko:"감쇠 유지율" ~en:"Decay Retention";
                  kind =
                    Chart.Spec.Ratio_gauge
                      {
                        used = gauge_used;
                        limit = gauge_limit;
                        unit = Format_val.Candles;
                        gradient = Chart.Gradient.Ai_flow;
                        reset_hint = None;
                      };
                  hotkey_hint = None;
                }
              in
              ignore
                (Chart.draw grid ~rect:gauge_rect ~theme
                   ~caps:Ops_common.default_caps ~lang:model.lang
                   ~show_title:false ratio_spec);
              cy := !cy + gauge_rect.h
            end;
            if !cy < cbot then begin
              ignore
                (Ops_common.put_line ~clip:r_content grid ~x:r_content.x ~y:!cy
                   ~max_w:r_content.w ~style:(Typography.whisper ~bg theme)
                   (Ops_common.say model
                      ~ko:"계약: 초상화 장신구 전용 (도구·모델 구매 불가)"
                      ~en:"Contract: portrait accessories only (no tools/models)"));
              incr cy
            end;
            if !cy < cbot then begin
              Card.draw_hairline ~pad_x:0 ~bg
                ~label:
                  (Printf.sprintf "%s (%d)"
                     (Ops_common.say model ~ko:"초상화 장신구"
                        ~en:"Portrait Ornaments")
                     (List.length owned_items))
                grid ~rect:r_content ~y:!cy ~theme;
              incr cy
            end;
            let equipped =
              List.filter_map
                (fun (ev : Wire_work.candle_event) ->
                  match ev.kind with
                  | Wire_work.Candle_equipped { keeper; slot; choice }
                    when String.equal keeper name ->
                      Some (Printf.sprintf "%s: %s" slot choice)
                  | Wire_work.Candle_equipped _
                  | Wire_work.Candle_paid _
                  | Wire_work.Candle_purchased _
                  | Wire_work.Candle_granted _
                  | Wire_work.Candle_gifted _
                  | Wire_work.Candle_gifted_item _
                  | Wire_work.Candle_half_life_set _
                  | Wire_work.Candle_snapshot _
                  | Wire_work.Candle_payout_owed _
                  | Wire_work.Candle_candidates _
                  | Wire_work.Candle_candidates_fenced _
                  | Wire_work.Candle_window_held _
                  | Wire_work.Candle_window_released _
                  | Wire_work.Candle_unattributed _
                  | Wire_work.Candle_payout_failed _ ->
                      None)
                ledger.recent_events
            in
            if owned_items = [] && equipped = [] then begin
              if !cy < cbot then
                ignore
                  (Ops_common.put_line ~clip:r_content grid ~x:r_content.x
                     ~y:!cy ~max_w:r_content.w
                     ~style:(Typography.whisper ~bg theme)
                     (Ops_common.say model ~ko:"보유 장신구 없음"
                        ~en:"No ornaments owned"))
            end
            else begin
              List.iter
                (fun eq ->
                  if !cy < cbot then begin
                    ignore
                      (Ops_common.put_line ~clip:r_content grid ~x:r_content.x
                         ~y:!cy ~max_w:r_content.w
                         ~style:(Typography.status ~bg theme Theme.Status_ok)
                         (Glyph.to_utf8 Glyph.Check_mark ^ " " ^ eq));
                    incr cy
                  end)
                (List.take 3 equipped);
              List.iter
                (fun item ->
                  if !cy < cbot then begin
                    ignore
                      (Ops_common.put_line ~clip:r_content grid ~x:r_content.x
                         ~y:!cy ~max_w:r_content.w
                         ~style:(Typography.primary ~bg theme)
                         (Glyph.to_utf8 Glyph.Separator_dot ^ " " ^ item));
                    incr cy
                  end)
                (List.take 5 owned_items)
            end
        | ( Observed.Loading _
          | Observed.Absent
          | Observed.Unreported
          | Observed.Failed _ ) as obs ->
            Ops_common.draw_observed_empty grid
              ~rect:
                (Rect.make ~x:r_content.x ~y:!cy ~w:r_content.w
                   ~h:(Int.max 0 (cbot - !cy)))
              ~theme ~lang:model.lang obs
              ~empty_msg:
                (Say.make ~ko:"캔들 원장 데이터 없음" ~en:"No candle ledger data")
      end
    end

(* --- Tab 4: Sandbox (microVM / remote_ssh + 24h failure classes + logs) --- *)

let find_ssh_pool_for_keeper (model : Model.t) ~name =
  match Observed.to_option model.infra.sandboxes with
  | None -> None
  | Some snap ->
      List.find_opt
        (fun (p : Wire_infra.ssh_pool) ->
          List.exists
            (fun (s : Wire_infra.ssh_keeper_session) ->
              String.equal s.keeper name)
            p.keeper_sessions)
        snap.ssh_pools

let resolve_keeper_sandbox (model : Model.t) ~name =
  match
    Observed.to_option (Infra_store.keeper_sandbox_for ~keeper:name model.infra)
  with
  | Some resp ->
      let pool_opt =
        match resp.sandbox with
        | Wire_infra.Sandbox_ssh_keeper { pool = Some p; _ } -> Some p
        | Wire_infra.Sandbox_ssh_keeper { pool = None; _ } ->
            find_ssh_pool_for_keeper model ~name
        | Wire_infra.Sandbox_microvm _
        | Wire_infra.Sandbox_ssh_unbound _
        | Wire_infra.Sandbox_docker _ ->
            None
      in
      Some (resp.sandbox, pool_opt)
  | None -> (
      match Observed.to_option model.infra.sandboxes with
      | None -> None
      | Some snap -> (
          match
            List.find_opt
              (fun (g : Wire_infra.microvm_guest) -> String.equal g.keeper name)
              snap.microvm_guests
          with
          | Some g -> Some (Wire_infra.Sandbox_microvm g, None)
          | None -> (
              let ssh_hit =
                List.find_map
                  (fun (p : Wire_infra.ssh_pool) ->
                    match
                      List.find_opt
                        (fun (s : Wire_infra.ssh_keeper_session) ->
                          String.equal s.keeper name)
                        p.keeper_sessions
                    with
                    | Some sess -> Some (sess, p)
                    | None -> None)
                  snap.ssh_pools
              in
              match ssh_hit with
              | Some (sess, pool) ->
                  Some
                    ( Wire_infra.Sandbox_ssh_keeper
                        { session = sess; pool = Some pool }
                    , Some pool )
              | None -> (
                  match
                    List.find_opt
                      (fun (u : Wire_infra.ssh_unbound_keeper) ->
                        String.equal u.keeper name)
                      snap.ssh_unbound_keepers
                  with
                  | Some u -> Some (Wire_infra.Sandbox_ssh_unbound u, None)
                  | None -> (
                      match
                        List.find_opt
                          (fun (d : Wire_infra.docker_keeper) ->
                            String.equal d.keeper name)
                          snap.docker_keepers
                      with
                      | Some d -> Some (Wire_infra.Sandbox_docker d, None)
                      | None -> None)))))

let network_mode_text ~lang = function
  | Wire_infra.Net_inherit -> Say.resolve lang (Say.make ~ko:"상속 (inherit)" ~en:"inherit")
  | Wire_infra.Net_none -> Say.resolve lang (Say.make ~ko:"차단 (none)" ~en:"none (isolated)")
  | Wire_infra.Net_policy -> Say.resolve lang (Say.make ~ko:"정책 (policy)" ~en:"policy")

let render_failure_classes grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) (m24 : Wire_infra.tool_metrics_24h) =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let fc = m24.failure_classes in
    let p95 =
      Format_val.format_observed Format_val.Milliseconds m24.p95_ms
        ~lang:model.lang
    in
    let p50 =
      Format_val.format_observed Format_val.Milliseconds m24.p50_ms
        ~lang:model.lang
    in
    let y = ref rect.y in
    let bot = Rect.bottom rect in
    Card.draw_hairline ~pad_x:0 ~bg
      ~label:
        (Ops_common.say model ~ko:"24h 도구 실행 · 오류 분류"
           ~en:"24h Tool Telemetry & Failures")
      grid ~rect ~y:!y ~theme;
    incr y;
    if !y < bot then begin
      let hdr =
        Printf.sprintf "%d calls · %d fail · p50 %s · p95 %s" m24.calls
          m24.failures p50 p95
      in
      ignore
        (Ops_common.put_line ~clip:rect grid ~x:rect.x ~y:!y ~max_w:rect.w
           ~style:(Typography.primary ~bg ~bold:true theme)
           hdr);
      incr y
    end;
    if !y < bot then begin
      let classes_line =
        Printf.sprintf "dep:%d  runtime:%d  policy:%d  workflow:%d  cancel:%d"
          fc.dependency_unavailable fc.runtime_failure fc.policy_rejection
          fc.workflow_rejection fc.operator_cancelled
      in
      let st =
        if fc.dependency_unavailable + fc.runtime_failure > 0 then
          Typography.status ~bg theme Theme.Status_attention
        else Typography.whisper ~bg theme
      in
      ignore
        (Ops_common.put_line ~clip:rect grid ~x:rect.x ~y:!y ~max_w:rect.w
           ~style:st classes_line);
      incr y
    end;
    if !y < bot && m24.failures > 0 then begin
      let bar_rect =
        Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:(Int.min 2 (bot - !y))
      in
      let segments =
        [
          (Say.literal "dep", Float.of_int fc.dependency_unavailable, Theme.Status_critical);
          (Say.literal "run", Float.of_int fc.runtime_failure, Theme.Status_attention);
          (Say.literal "pol", Float.of_int fc.policy_rejection, Theme.Status_active);
          (Say.literal "wf", Float.of_int fc.workflow_rejection, Theme.Status_historical);
        ]
        |> List.filter (fun (_, v, _) -> v > 0.0)
      in
      if segments <> [] then
        ignore
          (Chart.draw grid ~rect:bar_rect ~theme ~caps:Ops_common.default_caps
             ~lang:model.lang ~show_title:false
             {
               Chart.Spec.title = Say.make ~ko:"실패 분류" ~en:"Failures";
               kind =
                 Chart.Spec.Stacked_bar
                   {
                     segments;
                     total_label = Say.literal (Int.to_string m24.failures);
                     unit = Format_val.Count;
                   };
               hotkey_hint = None;
             })
    end

let render_sandbox_tab grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~name =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = Ops_common.pad_x_for ~model rect in
    let content = Card.pad_inner ~pad_x rect in
    if Rect.is_empty content then ()
    else
      let top_h = Int.min 10 (Int.max 4 (content.h / 2)) in
      let top_rect, rest_rect = Rect.split_v content ~top_h in
      let metrics_h = if rest_rect.h >= 8 then 5 else if rest_rect.h >= 5 then 3 else 0 in
      let metrics_rect, logs_rect = Rect.split_v rest_rect ~top_h:metrics_h in
      let m24_opt =
        match resolve_keeper_sandbox model ~name with
        | None ->
            let sandbox_obs =
              Infra_store.keeper_sandbox_for ~keeper:name model.infra
            in
            (match Fleet_store.sandbox_profile_of ~keeper:name model.fleet with
            | Some _ ->
                let lbl, tone = Ops_common.keeper_sandbox_label ~model name in
                Ops_common.draw_kv_row grid ~rect:top_rect ~y:top_rect.y ~theme
                  ~bg ~label_w:14
                  ~key:(Ops_common.say model ~ko:"프로필" ~en:"Profile")
                  ~value:lbl ~val_fg:(Theme.status_color theme tone)
                  ~val_attrs:Attr.bold ();
                if top_rect.h >= 2 then begin
                  let style, line =
                    match sandbox_obs with
                    | Observed.Failed { reason; _ } ->
                        ( Typography.status ~bg theme Theme.Status_critical
                        , Ops_common.say model ~ko:("조회 실패: " ^ reason)
                            ~en:("Fetch failed: " ^ reason) )
                    | Observed.Loading _ | Observed.Unreported
                    | Observed.Absent | Observed.Value _ ->
                        ( Typography.whisper ~bg theme
                        , Ops_common.say model
                            ~ko:"상세 샌드박스 프로브 데이터 대기 중"
                            ~en:"Detailed sandbox telemetry pending" )
                  in
                  ignore
                    (Ops_common.put_line ~clip:top_rect grid ~x:top_rect.x
                       ~y:(top_rect.y + 1) ~max_w:top_rect.w ~style line)
                end
            | None ->
                Ops_common.draw_observed_empty grid ~rect:top_rect ~theme
                  ~lang:model.lang sandbox_obs
                  ~empty_msg:
                    (Say.make ~ko:"이 키퍼의 샌드박스 정보 없음"
                       ~en:"No sandbox telemetry for this keeper"));
            None
        | Some (Wire_infra.Sandbox_microvm g, _) ->
            let y = ref top_rect.y in
            Ops_common.draw_kv_row grid ~rect:top_rect ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"백엔드" ~en:"Backend")
              ~value:(Printf.sprintf "%s · %s (%s)" g.backend g.guest_name g.presence)
              ~val_fg:theme.accent ~val_attrs:Attr.bold ();
            incr y;
            let sock_str, sock_fg =
              match g.agent_socket with
              | Wire_infra.Socket_present { path_basename } ->
                  ( Glyph.to_utf8 Glyph.Live_healthy ^ " present"
                    ^ (match path_basename with Some b -> " (" ^ b ^ ")" | None -> "")
                  , theme.status_ok )
              | Wire_infra.Socket_absent { path_basename } ->
                  ( Glyph.to_utf8 Glyph.Live_failing ^ " absent"
                    ^ (match path_basename with Some b -> " (" ^ b ^ ")" | None -> "")
                  , theme.status_critical )
              | Wire_infra.Socket_non_socket { file_kind } ->
                  ( Glyph.to_utf8 Glyph.Warning_triangle ^ " non-socket"
                    ^ (match file_kind with Some k -> " (" ^ k ^ ")" | None -> "")
                  , theme.status_attention )
              | Wire_infra.Socket_unreadable { detail } ->
                  ( Glyph.to_utf8 Glyph.Live_failing ^ " unreadable"
                    ^ (match detail with Some d -> ": " ^ d | None -> "")
                  , theme.status_critical )
            in
            Ops_common.draw_kv_row grid ~rect:top_rect ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"소켓" ~en:"Agent Socket")
              ~value:sock_str ~val_fg:sock_fg ();
            incr y;
            let shim_str, shim_fg =
              match g.shim_parity with
              | Wire_infra.Shim_matched id ->
                  (Glyph.to_utf8 Glyph.Check_mark ^ " matched (" ^ id ^ ")", theme.status_ok)
              | Wire_infra.Shim_mismatch { shim_identity; server_identity } ->
                  ( Printf.sprintf "%s mismatch (shim=%s vs srv=%s)"
                      (Glyph.to_utf8 Glyph.Warning_triangle)
                      shim_identity
                      (match server_identity with Some s -> s | None -> "?")
                  , theme.status_attention )
              | Wire_infra.Shim_undeclared -> ("undeclared", theme.text_muted)
              | Wire_infra.Shim_unavailable r ->
                  ("unavailable: " ^ r, theme.status_critical)
            in
            Ops_common.draw_kv_row grid ~rect:top_rect ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"심 버전" ~en:"Shim Parity")
              ~value:shim_str ~val_fg:shim_fg ();
            incr y;
            Ops_common.draw_kv_row grid ~rect:top_rect ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"네트워크" ~en:"Network")
              ~value:(network_mode_text ~lang:model.lang g.network_mode) ();
            incr y;
            let vol_str, vol_fg =
              match g.volume with
              | Wire_infra.Volume_declared v ->
                  (Glyph.to_utf8 Glyph.Live_healthy ^ " " ^ v, theme.status_ok)
              | Wire_infra.Volume_invalid err ->
                  (Glyph.to_utf8 Glyph.Live_failing ^ " " ^ err, theme.status_critical)
            in
            Ops_common.draw_kv_row grid ~rect:top_rect ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"볼륨 상태" ~en:"Volume")
              ~value:vol_str ~val_fg:vol_fg ();
            incr y;
            let res_str =
              let cpu_s =
                match g.cpus with
                | Observed.Value { data; _ } -> Printf.sprintf "%d vCPU" data
                | Observed.Loading _ | Observed.Absent | Observed.Unreported
                | Observed.Failed _ ->
                    "?"
              in
              let mem_s =
                match g.memory_mib with
                | Observed.Value { data; _ } -> Printf.sprintf "%d MiB" data
                | Observed.Loading _ | Observed.Absent | Observed.Unreported
                | Observed.Failed _ ->
                    "?"
              in
              cpu_s ^ " · " ^ mem_s
            in
            Ops_common.draw_kv_row grid ~rect:top_rect ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"자원" ~en:"Resources")
              ~value:res_str ();
            Some g.metrics_24h
        | Some
            ( Wire_infra.Sandbox_ssh_keeper
                { session = sess; pool = embedded_pool }
            , pool_opt ) ->
            let pool_opt =
              match pool_opt with Some _ as p -> p | None -> embedded_pool
            in
            let y = ref top_rect.y in
            let pool_desc, reach_str, reach_fg, sess_str, sess_ratio_opt =
              match pool_opt with
              | Some p ->
                  let r_s, r_fg =
                    match p.reachability with
                    | Wire_infra.Ssh_reachable { rtt_ms; _ } ->
                        ( Printf.sprintf "%s reachable · RTT %.1fms"
                            (Glyph.to_utf8 Glyph.Live_healthy)
                            rtt_ms
                        , theme.status_ok )
                    | Wire_infra.Ssh_probe_pending ->
                        ( Glyph.to_utf8 Glyph.Transport_reconnecting ^ " probing…"
                        , theme.status_active )
                    | Wire_infra.Ssh_unreachable { detail; _ } ->
                        ( Glyph.to_utf8 Glyph.Live_failing ^ " " ^ detail
                        , theme.status_critical )
                  in
                  let active_s, ratio_opt =
                    match p.active_sessions with
                    | Observed.Value { data; _ } ->
                        let r =
                          if p.max_sessions > 0 then
                            Some
                              (Float.min 1.0
                                 (Float.of_int data /. Float.of_int p.max_sessions))
                          else None
                        in
                        (Int.to_string data, r)
                    | Observed.Loading _ | Observed.Absent | Observed.Unreported
                    | Observed.Failed _ ->
                        ("?", None)
                  in
                  ( Printf.sprintf "%s (%s@%s:%d)" p.pool_name p.unix_user
                      p.host p.port
                  , r_s
                  , r_fg
                  , Printf.sprintf "%s / %d sessions · root %s" active_s
                      p.max_sessions p.remote_root
                  , ratio_opt )
              | None ->
                  ( "remote_ssh"
                  , Glyph.to_utf8 Glyph.Missing_unreported
                    ^ " pool metadata pending"
                  , theme.text_muted
                  , Glyph.to_utf8 Glyph.Missing_absent
                  , None )
            in
            Ops_common.draw_kv_row grid ~rect:top_rect ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"SSH 풀" ~en:"SSH Pool")
              ~value:pool_desc ~val_fg:theme.accent ~val_attrs:Attr.bold ();
            incr y;
            let rtt_samples =
              let opt_v = function
                | Observed.Value { data; _ } when Float.is_finite data -> [ data ]
                | Observed.Value _ | Observed.Loading _ | Observed.Absent
                | Observed.Unreported | Observed.Failed _ ->
                    []
              in
              let base_rtt =
                match pool_opt with
                | Some { reachability = Wire_infra.Ssh_reachable { rtt_ms; _ }; _ } ->
                    [ rtt_ms ]
                | Some
                    {
                      reachability =
                        Wire_infra.Ssh_probe_pending
                        | Wire_infra.Ssh_unreachable _;
                      _;
                    }
                | None ->
                    []
              in
              Ops_common.samples_of_floats
                (base_rtt
                 @ opt_v sess.metrics_24h.p50_ms
                 @ opt_v sess.metrics_24h.p95_ms
                 @ opt_v sess.metrics_24h.max_ms)
            in
            let sw = 8 in
            let show_rtt_spark = Array.length rtt_samples > 0 && top_rect.w >= 54 in
            let kv_rtt_rect =
              if show_rtt_spark then
                { top_rect with w = Int.max 0 (top_rect.w - sw - 2) }
              else top_rect
            in
            Ops_common.draw_kv_row grid ~rect:kv_rtt_rect ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"연결 · RTT" ~en:"Liveness · RTT")
              ~value:reach_str ~val_fg:reach_fg ();
            if show_rtt_spark then begin
              let sx = Rect.right top_rect - sw - 1 in
              ignore
                (Chart.draw_sparkline_run ~clip:top_rect grid ~x:sx ~y:!y
                   ~width:sw ~theme ~bg ~unicode:true
                   ~gradient:Chart.Gradient.Cool_flow rtt_samples)
            end;
            incr y;
            let sess_kv_r =
              match sess_ratio_opt with
              | Some _ when top_rect.w >= 56 ->
                  { top_rect with w = Int.max 0 (top_rect.w - 12) }
              | _ -> top_rect
            in
            Ops_common.draw_kv_row grid ~rect:sess_kv_r ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"세션" ~en:"Sessions")
              ~value:sess_str ();
            (match sess_ratio_opt with
            | Some ratio when top_rect.w >= 56 ->
                let bx = Rect.right top_rect - 10 in
                ignore
                  (Chart.draw_ratio_bar_run ~clip:top_rect grid ~x:bx ~y:!y
                     ~width:10 ~theme ~bg ~unicode:true
                     ~gradient:Chart.Gradient.Thermal ~ratio)
            | Some _ | None -> ());
            incr y;
            (match sess.last_dispatch with
            | `Null -> ()
            | ( `Assoc _ | `List _ | `Bool _ | `Int _ | `Intlit _ | `Float _
              | `String _ ) as dispatch_json ->
                let jt_rect =
                  Rect.make ~x:top_rect.x ~y:!y ~w:top_rect.w
                    ~h:(Int.max 0 (Rect.bottom top_rect - !y))
                in
                if not (Rect.is_empty jt_rect) then begin
                  let lines =
                    Json_tree.flatten ~max_depth:2 ~redact_secrets:true
                      (Ops_common.scrub_json_secrets dispatch_json)
                  in
                  ignore (Json_tree.draw grid ~rect:jt_rect ~theme lines)
                end);
            Some sess.metrics_24h
        | Some (Wire_infra.Sandbox_ssh_unbound u, _) ->
            let y = ref top_rect.y in
            Ops_common.draw_kv_row grid ~rect:top_rect ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"백엔드" ~en:"Backend")
              ~value:u.backend ~val_fg:theme.status_attention ~val_attrs:Attr.bold
              ();
            incr y;
            Ops_common.draw_kv_row grid ~rect:top_rect ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"바인딩" ~en:"Binding")
              ~value:(Glyph.to_utf8 Glyph.Warning_triangle ^ " " ^ u.binding_state)
              ~val_fg:theme.status_attention ();
            incr y;
            Ops_common.draw_kv_row grid ~rect:top_rect ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"원격 엔드포인트" ~en:"Endpoint")
              ~value:
                (match u.remote_endpoint with
                | Some e -> e
                | None -> Glyph.to_utf8 Glyph.Missing_absent)
              ();
            Some u.metrics_24h
        | Some (Wire_infra.Sandbox_docker d, _) ->
            let y = ref top_rect.y in
            Ops_common.draw_kv_row grid ~rect:top_rect ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"백엔드" ~en:"Backend")
              ~value:d.backend ~val_fg:theme.status_active ~val_attrs:Attr.bold
              ();
            incr y;
            Ops_common.draw_kv_row grid ~rect:top_rect ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"네트워크" ~en:"Network")
              ~value:(network_mode_text ~lang:model.lang d.network_mode) ();
            Some d.metrics_24h
      in
      (match m24_opt with
      | Some m24 when metrics_h > 0 ->
          render_failure_classes grid ~rect:metrics_rect ~theme ~model m24
      | Some _ | None -> ());
      (* Bottom: Live Sandbox Tail Logs *)
      if not (Rect.is_empty logs_rect) then begin
        Card.draw_hairline ~pad_x:0 ~bg
          ~label:
            (Ops_common.say model ~ko:"샌드박스 실시간 로그"
               ~en:"Live Sandbox Tail Logs")
          grid ~rect:logs_rect ~y:logs_rect.y ~theme;
        let keeper_logs =
          List.filter
            (fun (l : Wire_infra.system_log_entry) ->
              Option.equal String.equal l.keeper (Some name))
            model.infra.logs
        in
        let body_logs =
          Rect.make ~x:logs_rect.x ~y:(logs_rect.y + 1) ~w:logs_rect.w
            ~h:(Int.max 0 (logs_rect.h - 1))
        in
        if keeper_logs = [] && not (Rect.is_empty body_logs) then
          ignore
            (Ops_common.put_line ~clip:body_logs grid ~x:body_logs.x
               ~y:body_logs.y ~max_w:body_logs.w
               ~style:(Typography.whisper ~bg theme)
               (Ops_common.say model ~ko:"수신된 샌드박스 로그가 없습니다"
                  ~en:"No sandbox logs captured for this keeper"))
        else
          let max_skip =
            Int.max 0 (List.length keeper_logs - Int.max 1 body_logs.h)
          in
          let skip =
            Int.min max_skip (Int.max 0 model.nav.dive_scroll_offset)
          in
          List.iteri
            (fun idx (l : Wire_infra.system_log_entry) ->
              let py = body_logs.y + idx in
              if py < Rect.bottom body_logs then begin
                let lvl_str, tok =
                  match l.level with
                  | Wire_infra.Log_error -> ("ERR", Theme.Status_critical)
                  | Wire_infra.Log_warn -> ("WRN", Theme.Status_attention)
                  | Wire_infra.Log_info -> ("INF", Theme.Status_active)
                  | Wire_infra.Log_debug -> ("DBG", Theme.Status_historical)
                in
                let adv_t =
                  Ops_common.put_line ~clip:body_logs grid ~x:body_logs.x ~y:py
                    ~max_w:10 ~style:(Typography.whisper ~bg theme)
                    (l.ts ^ " ")
                in
                let adv_l =
                  Ops_common.put_line ~clip:body_logs grid
                    ~x:(body_logs.x + adv_t) ~y:py ~max_w:6
                    ~style:(Typography.status ~bg ~bold:true theme tok)
                    (lvl_str ^ " ")
                in
                let msg = Printf.sprintf "%s: %s" l.module_name l.message in
                ignore
                  (Ops_common.put_line ~clip:body_logs grid
                     ~x:(body_logs.x + adv_t + adv_l) ~y:py
                     ~max_w:(Int.max 0 (body_logs.w - adv_t - adv_l))
                     ~style:(Typography.primary ~bg theme)
                     msg)
              end)
            (List.take body_logs.h (Store_scroll.drop skip keeper_logs))
      end

(* --- Tab 5: Config (Scoped In-TUI Settings via v2.5 Form.draw, ZERO $EDITOR) --- *)

let map_provenance ~keeper = function
  | Wire_config.Prov_default -> Form.Prov_default
  | Wire_config.Prov_global | Wire_config.Prov_project -> Form.Prov_global_toml
  | Wire_config.Prov_keeper -> Form.Prov_keeper_toml keeper
  | Wire_config.Prov_env_override -> Form.Prov_env "ENV"

let map_reload_scope = function
  | Wire_config.Hot_reload -> Form.Hot_reload
  | Wire_config.Next_turn -> Form.Next_turn
  | Wire_config.Restart_required -> Form.Restart_required

let is_secret_schema_field (f : Wire_config.schema_field) =
  f.secret
  ||
  match f.kind with
  | Wire_config.Field_secret -> true
  | Wire_config.Field_bool
  | Wire_config.Field_int _
  | Wire_config.Field_float _
  | Wire_config.Field_string
  | Wire_config.Field_enum _
  | Wire_config.Field_string_list
  | Wire_config.Field_structured ->
      false

let form_value_of_schema_field (f : Wire_config.schema_field) =
  if is_secret_schema_field f then
    match f.value with
    | Wire_config.Val_secret { configured = true; _ } ->
        Form.secret_val ~revealed:false "configured"
    | Wire_config.Val_string s when not (String.equal (String.trim s) "") ->
        Form.secret_val ~revealed:false "configured"
    | Wire_config.Val_secret { configured = false; _ }
    | Wire_config.Val_string _
    | Wire_config.Val_bool _
    | Wire_config.Val_int _
    | Wire_config.Val_float _
    | Wire_config.Val_string_list _
    | Wire_config.Val_structured _
    | Wire_config.Val_null ->
        Form.secret_val ~revealed:false ""
  else
    match f.kind, f.value with
    | Wire_config.Field_bool, Wire_config.Val_bool b -> Form.Bool_val b
    | ( Wire_config.Field_bool
      , ( Wire_config.Val_int _
        | Wire_config.Val_float _
        | Wire_config.Val_string _
        | Wire_config.Val_string_list _
        | Wire_config.Val_structured _
        | Wire_config.Val_secret _
        | Wire_config.Val_null ) ) ->
        Form.Bool_val false
    | Wire_config.Field_int _, Wire_config.Val_int n -> Form.int_val n
    | ( Wire_config.Field_int _
      , ( Wire_config.Val_bool _
        | Wire_config.Val_float _
        | Wire_config.Val_string _
        | Wire_config.Val_string_list _
        | Wire_config.Val_structured _
        | Wire_config.Val_secret _
        | Wire_config.Val_null ) ) ->
        Form.int_val_of_raw ""
    | Wire_config.Field_float _, Wire_config.Val_float v -> Form.float_val v
    | ( Wire_config.Field_float _
      , ( Wire_config.Val_bool _
        | Wire_config.Val_int _
        | Wire_config.Val_string _
        | Wire_config.Val_string_list _
        | Wire_config.Val_structured _
        | Wire_config.Val_secret _
        | Wire_config.Val_null ) ) ->
        Form.float_val_of_raw ""
    | Wire_config.Field_enum opts, Wire_config.Val_string s ->
        let sel =
          let rec find i = function
            | [] -> 0
            | x :: xs -> if String.equal x s then i else find (i + 1) xs
          in
          find 0 opts
        in
        Form.enum_val ~selected:sel (List.map (fun o -> (o, Say.literal o)) opts)
    | ( Wire_config.Field_enum opts
      , ( Wire_config.Val_bool _
        | Wire_config.Val_int _
        | Wire_config.Val_float _
        | Wire_config.Val_string_list _
        | Wire_config.Val_structured _
        | Wire_config.Val_secret _
        | Wire_config.Val_null ) ) ->
        Form.enum_val ~selected:0 (List.map (fun o -> (o, Say.literal o)) opts)
    | ( Wire_config.Field_secret
      , ( Wire_config.Val_bool _
        | Wire_config.Val_int _
        | Wire_config.Val_float _
        | Wire_config.Val_string _
        | Wire_config.Val_string_list _
        | Wire_config.Val_structured _
        | Wire_config.Val_secret _
        | Wire_config.Val_null ) ) ->
        Form.secret_val ~revealed:false ""
    | Wire_config.Field_string_list, Wire_config.Val_string_list xs ->
        Form.Text_val (String.concat ", " xs)
    | Wire_config.Field_structured, Wire_config.Val_structured j ->
        let summary =
          match j with
          | `Assoc kvs -> Printf.sprintf "{%d keys}" (List.length kvs)
          | `List xs -> Printf.sprintf "[%d items]" (List.length xs)
          | `String s -> s
          | `Int n -> Int.to_string n
          | `Float v -> Printf.sprintf "%g" v
          | `Bool b -> if b then "true" else "false"
          | `Null -> "(null)"
          | `Intlit s -> s
        in
        Form.Text_val summary
    | ( Wire_config.Field_string
      | Wire_config.Field_string_list
      | Wire_config.Field_structured ),
      Wire_config.Val_string s ->
        Form.Text_val s
    | ( Wire_config.Field_string
      | Wire_config.Field_string_list
      | Wire_config.Field_structured ),
      ( Wire_config.Val_bool _
      | Wire_config.Val_int _
      | Wire_config.Val_float _
      | Wire_config.Val_string_list _
      | Wire_config.Val_structured _
      | Wire_config.Val_secret _
      | Wire_config.Val_null ) ->
        Form.Text_val ""

let form_value_of_patch_op (f : Wire_config.schema_field) op =
  if is_secret_schema_field f then
    match op with
    | Wire_config.Set_scalar { value; _ } ->
        Form.secret_val ~revealed:false value
    | Wire_config.Set_bool _
    | Wire_config.Set_int _
    | Wire_config.Set_float _
    | Wire_config.Set_string_array _
    | Wire_config.Remove_key _ ->
        Form.secret_val ~revealed:false ""
  else
    match op with
    | Wire_config.Set_bool { value; _ } -> Form.Bool_val value
    | Wire_config.Set_int { value; _ } -> Form.int_val value
    | Wire_config.Set_float { value; _ } -> Form.float_val value
    | Wire_config.Set_scalar { value; _ } -> (
        match f.kind with
        | Wire_config.Field_enum opts ->
            let sel =
              let rec find i = function
                | [] -> 0
                | x :: xs -> if String.equal x value then i else find (i + 1) xs
              in
              find 0 opts
            in
            Form.enum_val ~selected:sel
              (List.map (fun o -> (o, Say.literal o)) opts)
        | Wire_config.Field_secret -> Form.secret_val ~revealed:false value
        | Wire_config.Field_bool
        | Wire_config.Field_int _
        | Wire_config.Field_float _
        | Wire_config.Field_string
        | Wire_config.Field_string_list
        | Wire_config.Field_structured ->
            Form.Text_val value)
    | Wire_config.Set_string_array { values; _ } ->
        Form.Text_val (String.concat ", " values)
    | Wire_config.Remove_key _ -> Form.Text_val "(removed)"

let parse_hunk_header line =
  let len = String.length line in
  if len < 4 || not (String.equal (String.sub line 0 3) "@@ ") then None
  else
    let parse_num_after ch =
      match String.index_opt line ch with
      | None -> None
      | Some idx ->
          let rec scan j =
            if j < len && line.[j] >= '0' && line.[j] <= '9' then scan (j + 1)
            else j
          in
          let stop = scan (idx + 1) in
          if stop > idx + 1 then
            int_of_string_opt (String.sub line (idx + 1) (stop - idx - 1))
          else None
    in
    match parse_num_after '-', parse_num_after '+' with
    | Some o, Some n -> Some (o, n)
    | _ -> None

let numbered_rows_of_hunk_lines ~old_start ~new_start lines =
  let rec loop o n acc = function
    | [] -> List.rev acc
    | ln :: rest ->
        let len = String.length ln in
        if
          (len >= 4 && String.equal (String.sub ln 0 4) "--- ")
          || (len >= 4 && String.equal (String.sub ln 0 4) "+++ ")
        then loop o n acc rest
        else if len >= 3 && String.equal (String.sub ln 0 3) "@@ " then
          match parse_hunk_header ln with
          | Some (o', n') -> loop o' n' acc rest
          | None -> loop o n acc rest
        else if len > 0 && Char.equal ln.[0] '+' then
          let body = String.sub ln 1 (len - 1) in
          let row =
            { Diff.nrow = Diff.Added body; old_line = None; new_line = Some n }
          in
          loop o (n + 1) (row :: acc) rest
        else if len > 0 && Char.equal ln.[0] '-' then
          let body = String.sub ln 1 (len - 1) in
          let row =
            {
              Diff.nrow = Diff.Removed body;
              old_line = Some o;
              new_line = None;
            }
          in
          loop (o + 1) n (row :: acc) rest
        else
          let body =
            if len > 0 && Char.equal ln.[0] ' ' then String.sub ln 1 (len - 1)
            else ln
          in
          let row =
            {
              Diff.nrow = Diff.Context body;
              old_line = Some o;
              new_line = Some n;
            }
          in
          loop (o + 1) (n + 1) (row :: acc) rest
  in
  loop old_start new_start [] lines

let numbered_of_patch_response (resp : Wire_config.patch_response) =
  if resp.diff_hunks <> [] then
    List.concat_map
      (fun (h : Wire_config.diff_hunk) ->
        numbered_rows_of_hunk_lines ~old_start:h.old_start
          ~new_start:h.new_start h.lines)
      resp.diff_hunks
  else
    let raw_lines =
      String.split_on_char '\n' resp.unified_diff
      |> List.filter (fun ln -> not (String.equal ln ""))
    in
    numbered_rows_of_hunk_lines ~old_start:1 ~new_start:1 raw_lines

let build_keeper_form_state ~(model : Model.t) ~name ~target_matches
    ~suppress_local_diff (keeper_opt : Wire_fleet.keeper_summary option) =
  let cfg = model.config in
  let schema_loaded_for_target =
    match Observed.to_option cfg.schema with
    | Some schema ->
        target_matches
        && Config_store.equal_config_target schema.target
             (Wire_config.Target_keeper name)
    | None -> false
  in
  let schema_fields =
    if schema_loaded_for_target then
      Config_store.keeper_visible_fields ~lang:model.lang cfg
    else []
  in
  let fields =
    if schema_loaded_for_target then
      List.map
        (fun (f : Wire_config.schema_field) ->
          let is_sec = is_secret_schema_field f in
          let initial = form_value_of_schema_field f in
          let staged_val =
            match Config_store.String_map.find_opt f.full_key cfg.dirty_fields with
            | Some op -> form_value_of_patch_op f op
            | None -> initial
          in
          let current_val =
            match cfg.editing_field_key with
            | Some ek when (not is_sec) && String.equal ek f.full_key ->
                Form.Text_val (cfg.editing_buffer ^ "_")
            | Some _ | None -> staged_val
          in
          let help =
            let env_help =
              if is_sec then
                match f.value with
                | Wire_config.Val_secret
                    { source = Wire_config.Secret_env env_k; _ } ->
                    Some
                      (Say.make
                         ~ko:("환경변수에서 주입됨: " ^ env_k)
                         ~en:("Injected from env: " ^ env_k))
                | Wire_config.Val_secret
                    {
                      source =
                        Wire_config.Secret_inline_redacted
                        | Wire_config.Secret_unset;
                      _;
                    }
                | Wire_config.Val_bool _
                | Wire_config.Val_int _
                | Wire_config.Val_float _
                | Wire_config.Val_string _
                | Wire_config.Val_string_list _
                | Wire_config.Val_structured _
                | Wire_config.Val_null ->
                    None
              else None
            in
            match env_help with
            | Some _ as h -> h
            | None -> Option.map Say.literal f.description
          in
          let effective_initial =
            if suppress_local_diff then current_val else initial
          in
          let leaf_lbl = Config_store.field_label ~lang:model.lang f in
          let base =
            Form.make_field ~key:f.full_key ~label:(Say.literal leaf_lbl) ?help
              ~provenance:(map_provenance ~keeper:name f.provenance)
              ~reload_scope:(map_reload_scope f.reload_scope)
              ~read_only:((not f.writable) || is_sec)
              effective_initial
          in
          { base with value = current_val })
        schema_fields
    else
      match keeper_opt with
      | Some k ->
          [
            Form.make_field ~key:"keeper.group"
              ~label:(Say.make ~ko:"소속 회사 / 그룹" ~en:"Company / Group")
              ~provenance:(Form.Prov_keeper_toml name)
              ~reload_scope:Form.Next_turn ~read_only:true
              (Form.Text_val
                 (match k.group with
                  | Some group -> group
                  | None -> "ungrouped"));
            Form.make_field ~key:"keeper.runtime_id"
              ~label:(Say.make ~ko:"런타임 캐스케이드" ~en:"Runtime Cascade")
              ~provenance:(Form.Prov_keeper_toml name)
              ~reload_scope:Form.Next_turn ~read_only:true
              (Form.Text_val (Ops_common.human_runtime_label ~model k));
            Form.make_field ~key:"keeper.activation"
              ~label:(Say.make ~ko:"활성화 모드" ~en:"Activation Mode")
              ~provenance:(Form.Prov_keeper_toml name)
              ~reload_scope:Form.Hot_reload ~read_only:true
              (Form.Text_val
                 (Say.resolve model.lang
                    (Ops_common.activation_label k.activation_mode)));
            Form.make_field ~key:"keeper.paused"
              ~label:(Say.make ~ko:"일시 정지" ~en:"Paused")
              ~provenance:(Form.Prov_keeper_toml name)
              ~reload_scope:Form.Hot_reload ~read_only:true
              (Form.Bool_val k.paused);
            Form.make_field ~key:"keeper.secrets"
              ~label:(Say.make ~ko:"시크릿 (마스킹)" ~en:"Secrets (masked)")
              ~provenance:(Form.Prov_env "ENV")
              ~reload_scope:Form.Restart_required ~read_only:true
              (Form.secret_val ~revealed:false "configured");
          ]
      | None -> []
  in
  (* Single-SSOT filtering already applied by Config_store.keeper_visible_fields:
     pass filter = "" to Form.create so no duplicate Form.filter pass occurs. *)
  let st0 = { (Form.create fields) with filter = "" } in
  let len = Array.length st0.fields in
  let focused =
    if len = 0 then 0
    else if target_matches then
      Store_scroll.clamp_index len cfg.selected_field_index
    else 0
  in
  ( {
      st0 with
      focused;
      editing = target_matches && Option.is_some cfg.editing_field_key;
    }
  , schema_loaded_for_target )

let render_config_tab grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~name keeper_opt =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = Ops_common.pad_x_for ~model rect in
    let hdr_rect, rest = Rect.split_v rect ~top_h:1 in
    let target_matches =
      Config_store.equal_config_target model.config.target
        (Wire_config.Target_keeper name)
    in
    let dirty_n =
      if target_matches then Config_store.dirty_count model.config else 0
    in
    let diff_hint =
      if dirty_n > 0 then
        Ops_common.say model ~ko:" · [d] Diff" ~en:" · [d] Diff"
      else ""
    in
    let config_focused = Model.is_keeper_config_active model in
    let hdr_str =
      if config_focused then
        Printf.sprintf "%s %s %s %s %d %s%s"
          (Ops_common.say model ~ko:"키퍼 설정" ~en:"Keeper Settings")
          (Glyph.to_utf8 Glyph.Separator_dot)
          name
          (Glyph.to_utf8 Glyph.Separator_dot)
          dirty_n
          (Ops_common.say model
             ~ko:"건 변경 대기 · [↑↓] 필드 · [←→] 값 변경 · [Enter] 편집 · [Ctrl+S] 저장 · [[ ]] 탭"
             ~en:"staged · [↑↓] Field · [←→] Cycle · [Enter] Edit · [Ctrl+S] Save · [[ ]] Tabs")
          diff_hint
      else
        Printf.sprintf "%s %s %s %s %d %s"
          (Ops_common.say model ~ko:"키퍼 설정" ~en:"Keeper Settings")
          (Glyph.to_utf8 Glyph.Separator_dot)
          name
          (Glyph.to_utf8 Glyph.Separator_dot)
          dirty_n
          (Ops_common.say model
             ~ko:"건 변경 대기 · [Tab] 설정 편집 포커스"
             ~en:"staged · [Tab] Focus settings editor")
    in
    let hdr_st =
      if dirty_n > 0 then Typography.status ~bg ~bold:true theme Theme.Status_attention
      else Typography.structure ~bg ~bold:true theme
    in
    ignore
      (Ops_common.put_line ~clip:hdr_rect grid ~x:(hdr_rect.x + pad_x)
         ~y:hdr_rect.y
         ~max_w:(Int.max 0 (hdr_rect.w - (2 * pad_x)))
         ~style:hdr_st hdr_str);
    let server_diff_opt =
      if not target_matches then None
      else
        match model.config.dry_run_preview with
        | Config_store.Dry_run_ready resp
          when (String.equal resp.target ("keeper:" ^ name)
                || String.equal resp.target name)
               && (resp.diff_hunks <> []
                   || not (String.equal (String.trim resp.unified_diff) "")) ->
            Some resp
        | Config_store.Dry_run_ready _
        | Config_store.Dry_run_idle
        | Config_store.Dry_run_loading
        | Config_store.Dry_run_failed _ ->
            None
    in
    let diff_h =
      match server_diff_opt with
      | Some _ when rest.h >= 10 -> Int.min 7 (rest.h / 3)
      | Some _ | None -> 0
    in
    let form_rect, diff_rect =
      Rect.split_v rest ~top_h:(Int.max 0 (rest.h - diff_h))
    in
    let form_st, schema_loaded_for_target =
      build_keeper_form_state ~model ~name ~target_matches
        ~suppress_local_diff:(diff_h >= 2) keeper_opt
    in
    let section_header : Form.section_header =
      {
        title =
          Say.make
            ~ko:(Printf.sprintf "%s 키퍼 프로필" name)
            ~en:(Printf.sprintf "%s Keeper Profile" name);
        canonical_prefix = Some (Printf.sprintf "keepers/%s.toml" name);
        provenance = Form.Prov_keeper_toml name;
        reload_scope = Form.Hot_reload;
      }
    in
    if Array.length form_st.fields = 0 then begin
      if
        schema_loaded_for_target
        && not (String.equal (String.trim model.config.search_query) "")
      then begin
        let content = Card.pad_inner ~pad_x form_rect in
        if not (Rect.is_empty content) then
          ignore
            (Ops_common.put_line ~clip:content grid ~x:content.x ~y:content.y
               ~max_w:content.w ~style:(Typography.whisper ~bg theme)
               (Ops_common.say model
                  ~ko:
                    (Printf.sprintf "검색어 \"%s\"에 일치하는 설정이 없습니다 ([Esc] 초기화)"
                       model.config.search_query)
                  ~en:
                    (Printf.sprintf "No settings match \"%s\" ([Esc] Clear)"
                       model.config.search_query)))
      end
      else
        Ops_common.draw_observed_empty grid ~rect:form_rect ~theme
          ~lang:model.lang model.config.schema
          ~empty_msg:
            (Say.make ~ko:"키퍼 설정 스키마를 불러오는 중"
               ~en:"Loading keeper configuration schema")
    end
    else
      ignore
        (Form.draw grid ~rect:form_rect ~theme ~lang:model.lang ~pad_x
           ~section_header ~show_row_badges:false ~show_help_footer:false
           ~focused:
             (Model.is_keeper_config_active model && Model.body_has_focus model)
           form_st);
    match server_diff_opt with
    | Some resp when diff_h >= 2 ->
        let diff_c = Card.pad_inner ~pad_x diff_rect in
        Card.draw_hairline ~pad_x:0 ~bg
          ~label:
            (Ops_common.say model ~ko:"드라이런 TOML Diff 미리보기"
               ~en:"Dry-Run TOML Diff Preview")
          grid ~rect:diff_c ~y:diff_c.y ~theme;
        let numbered = numbered_of_patch_response resp in
        let body =
          Rect.make ~x:diff_c.x ~y:(diff_c.y + 1) ~w:diff_c.w
            ~h:(Int.max 0 (diff_c.h - 1))
        in
        ignore
          (Diff.draw grid ~rect:body ~theme ~language:Code_lexer.Toml
             ~scroll:model.config.dry_run_scroll_offset numbered)
    | Some _ | None -> ()

(* --- Embedded Live Keeper Preview Header + 4-Metric Telemetry Strip --- *)

let keeper_turns_24h_opt ~(model : Model.t) ~name =
  Fleet_store.keeper_turns_24h ~now_unix:model.freshness.last_wall_unix
    ~keeper:name model.fleet

let draw_embedded_preview_header grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~name (k : Wire_fleet.keeper_summary) =
  let bg = Color.of_rgb theme.surface_1 in
  let pad_x = Ops_common.pad_x_for ~model rect in
  let sb_lbl, _ = Ops_common.keeper_sandbox_label ~model name in
  let rt_lbl = Ops_common.human_runtime_label ~model k in
  let turn_lbl = Ops_common.keeper_turn_summary ~lang:model.lang k in
  let age_s =
    match k.last_turn_at_unix with
    | Some ts ->
        Typography.sep_dot
        ^ Ops_common.format_age ~now_unix:model.freshness.last_wall_unix ts
            ~lang:model.lang
    | None -> ""
  in
  (* 1. 2-row surface_2 Hero Band *)
  Card.draw_section_band ~pad_x grid
    ~rect:(Rect.make ~x:rect.x ~y:rect.y ~w:rect.w ~h:2)
    ~theme ~left_title:name
    ~right_meta:(Printf.sprintf "%s · %s" k.company sb_lbl)
    ~subtitle:(Printf.sprintf "%s · %s%s" rt_lbl turn_lbl age_s)
    ();
  (* 2. 4 Compact Live Gauges / Metrics separated by Card.draw_v_hairline *)
  let kpi_rect =
    Card.pad_inner ~pad_x
      (Rect.make ~x:rect.x ~y:(rect.y + 2) ~w:rect.w ~h:2)
  in
  if not (Rect.is_empty kpi_rect) then begin
    let kpi_gap = if kpi_rect.w >= 72 then 3 else 2 in
    let cols =
      Layout.split_h ~gap:kpi_gap kpi_rect
        [ Layout.Flex 1; Layout.Flex 1; Layout.Flex 1; Layout.Flex 1 ]
    in
    let ctx_display = Observed.map Fleet_store.context_display k.context in
    let turns_label, turns_short, turns_s =
      match keeper_turns_24h_opt ~model ~name with
      | Some n24 ->
          ( Ops_common.say model ~ko:"24h 턴" ~en:"24h Turns"
          , Ops_common.say model ~ko:"24h" ~en:"24h"
          , Format_val.format_value Format_val.Count (Float.of_int n24) )
      | None ->
          ( Ops_common.say model ~ko:"누적 턴" ~en:"Total turns"
          , Ops_common.say model ~ko:"누적" ~en:"Tot"
          , Format_val.format_observed Format_val.Count
              (Observed.map Float.of_int k.total_turns)
              ~lang:model.lang )
    in
    let cost_s =
      Format_val.format_observed Format_val.Usd
        (Runtime_store.keeper_cost_usd ~keeper:name model.runtime)
        ~lang:model.lang
    in
    let cost_label =
      match Runtime_store.keeper_costs_window_label model.runtime with
      | Some w -> Ops_common.say model ~ko:(w ^ " 비용") ~en:(w ^ " Cost")
      | None -> Ops_common.say model ~ko:"비용" ~en:"Cost"
    in
    let candle_s =
      match Ops_common.keeper_candle_milli ~model name with
      | Some (_, dec_s) ->
          Glyph.to_utf8 Glyph.Ai_spark ^ " "
          ^ Ops_common.format_milli_string dec_s
      | None ->
          Glyph.to_utf8 Glyph.Ai_spark ^ " " ^ Glyph.to_utf8 Glyph.Missing_absent
    in
    List.iteri
      (fun idx (cr : Rect.t) ->
        if
          idx > 0 && not (Rect.is_empty cr) && cr.x - 2 >= kpi_rect.x
          && cr.x - 2 < Rect.right kpi_rect
        then
          Card.draw_v_hairline ~bg grid ~x:(cr.x - 2) ~y:cr.y ~h:cr.h ~theme;
        if not (Rect.is_empty cr) then
          match idx with
          | 0 ->
              (* Context % gauge: a measured fill, the server's estimate
                 marked with "~", or the reason the server has no fill. *)
              let pct_s =
                match ctx_display with
                | Observed.Value
                    { data = Fleet_store.Context_fill { ratio; estimated }; _ }
                  ->
                    Fleet_store.context_fill_label ~estimated ratio
                | Observed.Value
                    { data = Fleet_store.Context_tokens_only tokens; _ } ->
                    Format_val.format_value Format_val.Tokens
                      (Float.of_int tokens)
                | Observed.Value
                    { data = Fleet_store.Context_unavailable _; _ }
                | Observed.Loading _ | Observed.Absent | Observed.Unreported
                | Observed.Failed _ ->
                    Glyph.to_utf8 Glyph.Missing_absent
              in
              Ops_common.draw_kpi_line grid ~rect:cr ~y:cr.y ~theme ~bg
                ~label:(Ops_common.say model ~ko:"컨텍스트" ~en:"Ctx")
                ~short_label:"Ctx" ~value:pct_s
                ~val_style:(Typography.anchor ~bg theme);
              if cr.h >= 2 then begin
                let whisper line =
                  ignore
                    (Ops_common.put_line ~clip:cr grid ~x:cr.x ~y:(cr.y + 1)
                       ~max_w:cr.w ~style:(Typography.whisper ~bg theme) line)
                in
                match ctx_display with
                | Observed.Value
                    { data = Fleet_store.Context_fill { ratio; estimated = _ }; _ }
                  ->
                    ignore
                      (Chart.draw_ratio_bar_run ~clip:cr grid ~x:cr.x
                         ~y:(cr.y + 1) ~width:(Int.min 12 cr.w) ~theme ~bg
                         ~unicode:true
                         ~gradient:
                           (if ratio >= 0.80 then Chart.Gradient.Thermal
                            else Chart.Gradient.Cool_flow)
                         ~ratio)
                | Observed.Value
                    { data = Fleet_store.Context_tokens_only _; _ } ->
                    whisper
                      (Ops_common.say model ~ko:"창 크기 미보고"
                         ~en:"window unreported")
                | Observed.Value
                    { data = Fleet_store.Context_unavailable reason; _ } ->
                    whisper
                      (Say.resolve model.lang
                         (Fleet_store.context_unavailable_label reason))
                | Observed.Loading _ -> whisper (Glyph.to_utf8 Glyph.Ellipsis)
                | Observed.Absent -> whisper (Glyph.to_utf8 Glyph.Missing_absent)
                | Observed.Unreported ->
                    whisper (Ops_common.say model ~ko:"미보고" ~en:"unreported")
                | Observed.Failed _ ->
                    whisper (Ops_common.say model ~ko:"조회 실패" ~en:"fetch failed")
              end
          | 1 ->
              (* Honest 24h Turns (from 24h sparkline) or explicit Total turns *)
              Ops_common.draw_kpi_line grid ~rect:cr ~y:cr.y ~theme ~bg
                ~label:turns_label ~short_label:turns_short
                ~value:turns_s ~val_style:(Typography.anchor ~bg theme);
              if cr.h >= 2 then
                let samples =
                  Ops_common.samples_of_floats
                    (Fleet_store.sparkline_24h
                       ~now_unix:model.freshness.last_wall_unix ~keeper:name
                       model.fleet)
                in
                if Array.length samples > 0 then
                  ignore
                    (Chart.draw_sparkline_run ~clip:cr grid ~x:cr.x ~y:(cr.y + 1)
                       ~width:(Int.min 12 cr.w) ~theme ~bg ~unicode:true
                       ~gradient:Chart.Gradient.Cool_flow samples)
                else
                  ignore
                    (Ops_common.put_line ~clip:cr grid ~x:cr.x ~y:(cr.y + 1)
                       ~max_w:cr.w ~style:(Typography.whisper ~bg theme)
                       (Ops_common.say model ~ko:"누적 합계" ~en:"lifetime total"))
          | 2 ->
              (* Cost and tokens over the keeper-costs window *)
              Ops_common.draw_kpi_line grid ~rect:cr ~y:cr.y ~theme ~bg
                ~label:cost_label ~short_label:(Ops_common.say model ~ko:"비용" ~en:"$")
                ~value:cost_s ~val_style:(Typography.anchor ~bg theme);
              if cr.h >= 2 then
                let tok_s =
                  Format_val.format_observed Format_val.Tokens
                    (Observed.map Float.of_int
                       (Runtime_store.keeper_tokens ~keeper:name model.runtime))
                    ~lang:model.lang
                in
                ignore
                  (Ops_common.put_line ~clip:cr grid ~x:cr.x ~y:(cr.y + 1)
                     ~max_w:cr.w ~style:(Typography.whisper ~bg theme)
                     tok_s)
          | _ ->
              (* Candle balance in Violet *)
              Ops_common.draw_kpi_line grid ~rect:cr ~y:cr.y ~theme ~bg
                ~label:(Ops_common.say model ~ko:"캔들" ~en:"Candle")
                ~short_label:"" ~value:candle_s
                ~val_style:(Typography.ai ~bg ~bold:true theme);
              if cr.h >= 2 then
                ignore
                  (Ops_common.put_line ~clip:cr grid ~x:cr.x ~y:(cr.y + 1)
                     ~max_w:cr.w ~style:(Typography.whisper ~bg theme)
                     (Say.resolve model.lang
                        (Ops_common.activation_label k.activation_mode))))
      cols
  end;
  Card.draw_hairline ~pad_x ~bg grid ~rect ~y:(rect.y + 4) ~theme

let render_logs_tab grid ~(rect : Rect.t) ~(theme : Theme.t) ~(model : Model.t)
    ~name =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = Ops_common.pad_x_for ~model rect in
    let content = Card.pad_inner ~pad_x rect in
    if not (Rect.is_empty content) then begin
      let ks = Keeper_context_store.get_keeper ~keeper:name model.keeper_context in
      let lines = Update_nav.keeper_logs_lines ~width:content.w ~name ks in
      let max_skip = Int.max 0 (List.length lines - content.h) in
      let skip = Int.min max_skip (Int.max 0 ks.logs_scroll_offset) in
      let y = ref content.y and bot = Rect.bottom content in
      List.iter
        (fun ln ->
          if !y < bot then begin
            let st =
              if String.starts_with ~prefix:"──" ln then
                Typography.status ~bg ~bold:true theme Theme.Status_active
              else if String.starts_with ~prefix:"  stderr:" ln then
                Typography.status ~bg theme Theme.Status_attention
              else if String.starts_with ~prefix:"  stdout:" ln then
                Typography.status ~bg theme Theme.Status_ok
              else Typography.structure ~bg theme
            in
            ignore
              (Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                 ~max_w:content.w ~style:st ln);
            incr y
          end)
        (Store_scroll.drop skip lines)
    end

let render_identity_tab grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~name =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = Ops_common.pad_x_for ~model rect in
    let content = Card.pad_inner ~pad_x rect in
    if not (Rect.is_empty content) then begin
      let ks = Keeper_context_store.get_keeper ~keeper:name model.keeper_context in
      let lines =
        Update_nav.keeper_identity_lines ~width:content.w ~name model
      in
      let max_skip = Int.max 0 (List.length lines - content.h) in
      let skip = Int.min max_skip (Int.max 0 ks.identity_scroll_offset) in
      let y = ref content.y and bot = Rect.bottom content in
      List.iter
        (fun ln ->
          if !y < bot then begin
            let is_sel = String.starts_with ~prefix:">" ln in
            let row_rect = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:1 in
            let row_bg =
              if is_sel then Color.of_rgb theme.selection_bg else bg
            in
            if is_sel then
              Cell_grid.fill_rect ~clip:content grid ~rect:row_rect
                ~style:
                  (Style.make ~fg:(Color.of_rgb theme.text_primary) ~bg:row_bg ())
                ();
            let st =
              if is_sel then Typography.anchor ~bg:row_bg theme
              else if String.starts_with ~prefix:"──" ln then
                Typography.status ~bg ~bold:true theme Theme.Status_active
              else if
                String.starts_with ~prefix:"  [CanAdmin" ln
                || String.starts_with ~prefix:"  Error:" ln
                || String.starts_with ~prefix:"  Effective error:" ln
              then Typography.status ~bg theme Theme.Status_attention
              else if String.starts_with ~prefix:"  One-time code:" ln then
                Typography.status ~bg ~bold:true theme Theme.Status_ok
              else Typography.structure ~bg theme
            in
            ignore
              (Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                 ~max_w:content.w ~style:st ln);
            incr y
          end)
        (Store_scroll.drop skip lines)
    end

(* --- Unified 9-Tab Keeper Dive Entrypoint --- *)

let render_tabs_body ~embedded ~name ~tab ~(model : Model.t) ~cache
    ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Ops_common.theme_of_model model in
    let keeper_opt = Fleet_store.find_keeper ~name model.fleet in
    let has_attn = Ops_common.keeper_has_attention model.attention name in
    let badge_opt =
      Option.map
        (fun k ->
          let g, tok, lbl = Ops_common.keeper_live_status ~has_attention:has_attn k in
          { Card.glyph = Some g; text = Say.resolve model.lang lbl; tone = Some tok })
        keeper_opt
    in
    let company_sub =
      match keeper_opt with Some k -> Some k.company | None -> None
    in
    let title =
      if embedded then
        Printf.sprintf "%s %s %s"
          (Ops_common.say model ~ko:"키퍼 프리뷰" ~en:"Keeper Preview")
          (Glyph.to_utf8 Glyph.Separator_dot)
          name
      else
        Printf.sprintf "%s %s %s"
          (Say.resolve model.lang (Nav.workspace_label Nav.Keepers))
          (Glyph.to_utf8 Glyph.Prompt_caret)
          name
    in
    let has_running_turn =
      Option.is_some (Chat_transcript.escape_interrupt_target ~model ~keeper:name)
    in
    let can_explicit_interrupt =
      let turn = Fleet_store.active_turn_for ~keeper:name model.fleet in
      match Chat_transcript.explicit_interrupt_target ~model ~keeper:name turn with
      | Some target ->
          not (Chat_transcript.interrupt_target_pending ~model ~keeper:name target)
      | None -> false
    in
    let board_recovery_open =
      Nav.equal_keeper_tab tab Nav.Keeper_work_candle
      && ((not embedded) || Model.pane_focused model 1
          || (model.nav.zoomed && Model.can_zoom_current_view model))
      && Board_recovery.shown ~keeper:name model.knowledge.board_recovery
    in
    let hotkey =
      if Nav.equal_keeper_tab tab Nav.Keeper_memory then None
      else if embedded then
        if board_recovery_open then
          Some
            (Ops_common.say model
               ~ko:"[↑↓] 항목 · [Enter/c] 복구 · [v/Esc] 닫기"
               ~en:"[↑↓] Item · [Enter/c] Recover · [v/Esc] Close")
        else if Nav.equal_keeper_tab tab Nav.Keeper_config then
          if Model.is_keeper_config_active model then
            Some
              (Ops_common.say model
                 ~ko:"[←→] 값 · [Enter] 편집 · [d] Diff · [Ctrl+S] 저장 · [[ ]] 탭"
                 ~en:"[←→] Cycle · [Enter] Edit · [d] Diff · [Ctrl+S] Save · [[ ]] Tabs")
          else
            Some
              (Ops_common.say model
                 ~ko:"[Tab] 설정 편집 · [Enter] 상세 · [z] 확대"
                 ~en:"[Tab] Edit Config · [Enter] Dive · [z] Zoom")
        else if Nav.equal_keeper_tab tab Nav.Keeper_logs then
          Some
            (Ops_common.say model
               ~ko:"[v] 메트릭/샌드박스 · [r] 새로고침 · [z] 확대"
               ~en:"[v] Metrics/Sandbox · [r] Refresh · [z] Zoom")
        else if Nav.equal_keeper_tab tab Nav.Keeper_identity then
          Some
            (Ops_common.say model
               ~ko:"[l] 로그인 · [a/Enter] 전환 · [K] PAT · [y] 복사"
               ~en:"[l] Login · [a/Enter] Switch · [K] PAT · [y] Copy")
        else
          Some
            (Ops_common.say model ~ko:"[Ctrl+T] 큐 · [z] 확대"
               ~en:"[Ctrl+T] Queue · [z] Zoom")
      else if board_recovery_open then
        Some
          (Ops_common.say model
             ~ko:"[↑↓] 항목 · [Enter/c] 복구 · [v/Esc] 닫기"
             ~en:"[↑↓] Item · [Enter/c] Recover · [v/Esc] Close")
      else if Nav.equal_keeper_tab tab Nav.Keeper_config then
        Some
          (Ops_common.say model
             ~ko:"[←→] 값 변경 · [Enter] 편집 · [d] Diff · [Ctrl+S] 저장 · [[ ]] 탭 · [Esc] 목록"
             ~en:"[←→] Cycle · [Enter] Edit · [d] Diff · [Ctrl+S] Save · [[ ]] Tabs · [Esc] Fleet")
      else if Nav.equal_keeper_tab tab Nav.Keeper_logs then
        Some
          (Ops_common.say model
             ~ko:"[v] 메트릭/샌드박스 · [r] 새로고침 · [[ ]] 탭 · [Esc] 목록"
             ~en:"[v] Metrics/Sandbox · [r] Refresh · [[ ]] Tabs · [Esc] Fleet")
      else if Nav.equal_keeper_tab tab Nav.Keeper_identity then
        Some
          (Ops_common.say model
             ~ko:"[l] 로그인 · [L] 폴 · [a/Enter] 전환 · [U] 해제 · [K] PAT · [y] 복사"
             ~en:"[l] Login · [L] Poll · [a/Enter] Switch · [U] Disconnect · [K] PAT · [y] Copy")
      else if Nav.equal_keeper_tab tab Nav.Keeper_chat && has_running_turn then
        Some
          (Ops_common.say model ~ko:"[Ctrl+T] 작업·큐 · [Esc/Ctrl+X] 턴 중단"
             ~en:"[Ctrl+T] Work & Queue · [Esc/Ctrl+X] Interrupt")
      else if
        Nav.equal_keeper_tab tab Nav.Keeper_chat && can_explicit_interrupt
      then
        Some
          (Ops_common.say model ~ko:"[Ctrl+T] 작업·큐 · [Ctrl+X] 턴 중단"
             ~en:"[Ctrl+T] Work & Queue · [Ctrl+X] Interrupt")
      else if Nav.equal_keeper_tab tab Nav.Keeper_chat then
        Some
          (Ops_common.say model ~ko:"[Ctrl+T] 작업·큐 · [Ctrl+O] 도구 상세"
             ~en:"[Ctrl+T] Work & Queue · [Ctrl+O] Tool details")
      else
        Some
          (Ops_common.say model ~ko:"[[ ]] 탭 · [y] 응답 복사 · [Esc] 목록"
             ~en:"[[ ]] Tabs · [y] Copy · [Esc] Fleet")
    in
    let footer_hint =
      let stop_armed_for_here =
        match model.keeper_stop_armed with
        | Some (armed_name, _) -> String.equal armed_name name
        | None -> false
      in
      if stop_armed_for_here then
        Some
          (Ops_common.say model
             ~ko:"[D] 한 번 더 눌러 중지 확정 · [Esc] 취소"
             ~en:"Press [D] again to confirm stop · [Esc] Cancel")
      else if embedded then
        if
          Nav.equal_keeper_tab tab Nav.Keeper_config
          && Model.is_keeper_config_active model
        then
          Some
            (Ops_common.say model
               ~ko:"[Enter] 편집 · [d] Diff · [Ctrl+S] 저장 · [Tab] 목록"
               ~en:"[Enter] Edit · [d] Diff · [Ctrl+S] Save · [Tab] Fleet")
        else if
          Nav.equal_keeper_tab tab Nav.Keeper_memory
          && model.nav.pane_index = 1
        then
          Some
            (Ops_common.say model
               ~ko:"[Enter] 전문 읽기 · [z] 확대 · [Tab] 목록"
               ~en:"[Enter] Read · [z] Zoom · [Tab] Fleet")
        else if rect.w >= 73 then
          Some
            (Ops_common.say model
               ~ko:"[W] 깨우기 · [D] 중지(2회) · [Enter] Dive · [c] 채팅 · [V] 음성 PTT"
               ~en:"[W] Wake/Online · [D] Stop(2x) · [Enter] Dive · [c] Chat · [V] PTT")
        else
          Some
            (Ops_common.say model
               ~ko:"[W] 깨우기 · [D] 중지 · [Enter] Dive · [c] 채팅 · [V] PTT"
               ~en:"[W] Wake · [D] Stop · [Enter] Dive · [c] Chat · [V] PTT")
      else if rect.w >= 54 then
        Some
          (Ops_common.say model
             ~ko:"[W] 깨우기/온라인 · [D] 중지(2회)"
             ~en:"[W] Wake/Online · [D] Stop(2x)")
      else
        Some
          (Ops_common.say model
             ~ko:"[W] 깨우기 · [D] 중지"
             ~en:"[W] Wake · [D] Stop")
    in
    let card_spec : Card.spec =
      {
        (Card.default_spec ~title) with
        subtitle = company_sub;
        badge = badge_opt;
        hotkey;
        footer_hint;
        focused =
          Model.body_has_focus model && ((not embedded) || model.nav.pane_index >= 1);
      }
    in
    let inner = Card.draw ~cache grid ~rect ~theme card_spec in
    if Rect.is_empty inner then ()
    else
      let after_hero =
        match embedded, keeper_opt with
        | true, Some k when inner.h >= 16 ->
            let hero_r, rest = Rect.split_v inner ~top_h:5 in
            draw_embedded_preview_header grid ~rect:hero_r ~theme ~model ~name k;
            rest
        | _ -> inner
      in
      let content_rect =
        if embedded && after_hero.h >= 3 then begin
          let tab_bar_rect, body_rect = Rect.split_v after_hero ~top_h:1 in
          let bg = Color.of_rgb theme.surface_1 in
          let tab_pills =
            List.map
              (fun t ->
                ( Say.resolve model.lang (Nav.keeper_tab_label t)
                , Nav.equal_keeper_tab t tab
                , None ))
              Nav.all_keeper_tabs
          in
          ignore (Ops_common.draw_pills grid ~rect:tab_bar_rect ~theme ~bg tab_pills);
          let body_after_rule =
            if body_rect.h >= 6 then begin
              let pad_x = Ops_common.pad_x_for ~model body_rect in
              Card.draw_hairline ~pad_x ~bg grid ~rect:body_rect ~y:body_rect.y
                ~theme;
              Rect.make ~x:body_rect.x ~y:(body_rect.y + 1) ~w:body_rect.w
                ~h:(body_rect.h - 1)
            end
            else body_rect
          in
          body_after_rule
        end
        else after_hero
      in
      if not (Rect.is_empty content_rect) then
        match tab with
        | Nav.Keeper_chat ->
            render_chat_tab grid ~rect:content_rect ~theme ~model ~name
              keeper_opt
        | Nav.Keeper_context ->
            Keeper_context_view.draw_context_tab grid ~rect:content_rect ~theme
              ~model ~name
        | Nav.Keeper_tool_calls ->
            Keeper_context_view.draw_tool_calls_tab grid ~rect:content_rect
              ~theme ~model ~name
        | Nav.Keeper_memory ->
            render_memory_tab grid ~rect:content_rect ~theme ~model ~name
              ~focused:card_spec.focused
        | Nav.Keeper_work_candle when Board_recovery.shown ~keeper:name model.knowledge.board_recovery ->
            render_board_recovery grid ~rect:content_rect ~theme ~model ~name
        | Nav.Keeper_work_candle ->
            render_work_candle_tab grid ~rect:content_rect ~theme ~model ~name
        | Nav.Keeper_sandbox ->
            render_sandbox_tab grid ~rect:content_rect ~theme ~model ~name
        | Nav.Keeper_config ->
            render_config_tab grid ~rect:content_rect ~theme ~model ~name
              keeper_opt
        | Nav.Keeper_logs ->
            render_logs_tab grid ~rect:content_rect ~theme ~model ~name
        | Nav.Keeper_identity ->
            render_identity_tab grid ~rect:content_rect ~theme ~model ~name
