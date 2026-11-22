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

let preview_tool_output_rows ~(theme : Theme.t) ~(model : Model.t) ~width raw =
  let tools_mode = model.fleet.chat_tools_mode in
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

let build_history_rows ~(theme : Theme.t) ~(model : Model.t) ~keeper_name ~width
    (messages : Wire_fleet.chat_message list) =
  let base_bg = theme.surface_1 in
  let user_bg = theme.surface_2 in
  let runtimes = Runtime_store.runtime_options model.runtime in
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
    | (msg : Wire_fleet.chat_message) :: rest ->
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
              header_row
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
                match model.fleet.chat_tools_mode with
                | Slash.Tools_compact -> false
                | Slash.Tools_results | Slash.Tools_full -> true
              in
              let chevron =
                if expanded then Glyph.to_utf8 Glyph.Expand_open
                else Glyph.to_utf8 Glyph.Expand_closed
              in
              let preview =
                concise_tool_preview ~max_w:(Int.max 10 (width - 28)) msg.content
              in
              let bg = Color.of_rgb theme.surface_2 in
              let spans =
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
              let compact_line =
                make_row ~rail_rgb:theme.border_inactive
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
        in
        loop (Some hhmm) (List.rev_append (spacing @ msg_rows) acc) rest
  in
  loop None [] messages

let build_stream_rows ~(theme : Theme.t) ~(model : Model.t) ~keeper_name ~width
    (buf : Fleet_store.chat_stream_buffer) =
  let base_bg = theme.surface_1 in
  let rows = ref [] in
  let push r = rows := r :: !rows in
  let push_all rs = List.iter push rs in
  (* 1. Keeper Thinking / Reasoning: Violet ▎ (status_ai) + ✦ (Ai_spark) + Tier-4 italic! *)
  if not (String.equal (String.trim buf.thinking) "") then begin
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
  let expanded_tools =
    match model.fleet.chat_tools_mode with
    | Slash.Tools_compact -> false
    | Slash.Tools_results | Slash.Tools_full -> true
  in
  List.iter
    (fun (tc : Fleet_store.active_tool_call) ->
      let rail_rgb, pill_txt, pill_fg =
        if not tc.completed then
          ( theme.status_active
          , Glyph.to_utf8 Glyph.Live_working ^ " run"
          , theme.status_active )
        else
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
              , theme.text_secondary )
      in
      let chevron =
        if expanded_tools && Option.is_some tc.output_preview then
          Glyph.to_utf8 Glyph.Expand_open
        else Glyph.to_utf8 Glyph.Expand_closed
      in
      let args_part =
        match tc.args_preview with
        | Some a -> concise_tool_preview ~max_w:(Int.max 10 (width - 30)) a
        | None -> ""
      in
      let bg = Color.of_rgb theme.surface_2 in
      let spans =
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
    buf.tools;
  (* 3. Live Assistant Text Delta *)
  if not (String.equal (String.trim buf.text) "") then begin
    let glyph, fg, tag =
      if buf.active then
        ( Glyph.Live_working
        , theme.status_active
        , Ops_common.say model ~ko:"생성 중…" ~en:"streaming…" )
      else
        ( Glyph.Live_healthy
        , theme.status_ok
        , Ops_common.say model ~ko:"완료" ~en:"done" )
    in
    push
      (single_span_row ~prefix:(Glyph.to_utf8 glyph ^ " ") ~prefix_fg:fg
         ~prefix_attrs:Attr.bold ~text:("@" ^ keeper_name)
         ~text_fg:theme.text_bright ~attrs:Attr.bold ~right_meta:tag
         ~right_meta_fg:theme.text_muted ~right_meta_attrs:Attr.italic
         ~bg_rgb:base_bg ());
    push_all
      (markdown_rows ~theme ~width ~prefix:"  " ~cont_prefix:"  " ~prefix_fg:fg
         ~bg_rgb:base_bg buf.text)
  end;
  (* 4. Explicit Stream Error (Coral left rail, non-italic Bold) *)
  (match buf.last_error with
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

let build_pending_tx_rows ~(theme : Theme.t) ~(model : Model.t) ~keeper_name
    ~width =
  let pending = Drafts.pending_txs_for_keeper ~keeper:keeper_name model.drafts in
  let base_bg = theme.surface_2 in
  List.filter_map
    (fun (tx : Drafts.pending_message) ->
      match Drafts.tx_state_label tx.state with
      | None -> None
      | Some state_say ->
          let state_str = Say.resolve model.lang state_say in
          let state_fg =
            match tx.state with
            | Drafts.Failed_retryable _ -> theme.status_critical
            | Drafts.Queued | Drafts.Sending -> theme.status_attention
            | Drafts.Pending_processing | Drafts.Confirming_delivery ->
                theme.status_active
            | Drafts.Delivered -> theme.status_ok
          in
          let mode_tag =
            match tx.mode with
            | Drafts.Mode_steer -> Ops_common.say model ~ko:"조향" ~en:"Steer"
            | Drafts.Mode_follow_up -> Ops_common.say model ~ko:"후속" ~en:"Queue"
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
            | Drafts.Queued
            | Drafts.Sending
            | Drafts.Pending_processing
            | Drafts.Confirming_delivery
            | Drafts.Delivered ->
                body_preview
          in
          let pill = Printf.sprintf "%s · %s" state_str mode_tag in
          Some
            (single_span_row ~rail_rgb:state_fg
               ~prefix:(Glyph.to_utf8 Glyph.Prompt_caret ^ " ")
               ~prefix_fg:state_fg ~prefix_attrs:Attr.bold ~text:detail
               ~text_fg:theme.text_primary ~right_meta:pill
               ~right_meta_fg:state_fg ~right_meta_attrs:Attr.bold
               ~bg_rgb:base_bg ~full_bleed_bg:true ()))
    pending

let draw_transcript_rows grid ~(rect : Rect.t) ~(theme : Theme.t) ~pad_x ~scroll
    rows =
  if Rect.is_empty rect then ()
  else
    let total = List.length rows in
    let arr = Array.of_list rows in
    let max_scroll = Int.max 0 (total - rect.h) in
    let clamped_scroll = Int.max 0 (Int.min max_scroll scroll) in
    let start = Int.max 0 (total - rect.h - clamped_scroll) in
    let visible = Int.min rect.h (total - start) in
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
    let box_w = Int.min inner_c.w 76 in
    let box_x = inner_c.x + Int.max 0 ((inner_c.w - box_w) / 2) in
    let desired_h = 13 in
    let start_y =
      if inner_c.h >= desired_h + 2 then
        inner_c.y + ((inner_c.h - desired_h) / 3)
      else inner_c.y
    in
    let panel =
      Rect.make ~x:box_x ~y:start_y ~w:box_w
        ~h:(Int.max 0 (Rect.bottom inner_c - start_y))
    in
    if Rect.is_empty panel then ()
    else begin
      let y = ref panel.y in
      let bot = Rect.bottom panel in
      let has_attn = Ops_common.keeper_has_attention model.attention name in
      let company_s, rt_s, status_s, task_s, turns_s =
        match keeper_opt with
        | Some k ->
            let g, _, slbl = Ops_common.keeper_live_status ~has_attention:has_attn k in
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
            (dash, dash, Glyph.to_utf8 Glyph.Live_idle ^ " " ^ dash, dash, dash)
      in
      let sb_lbl, sb_tone = Ops_common.keeper_sandbox_label ~model name in
      let candle_s =
        match Ops_common.keeper_candle_milli ~model name with
        | Some (_, dec) ->
            Glyph.to_utf8 Glyph.Ai_spark ^ " "
            ^ Ops_common.format_milli_string dec
        | None -> Glyph.to_utf8 Glyph.Missing_absent
      in
      (* 1. Sleek elevated surface_2 Identity Band (NO nested Card!) *)
      if bot - !y >= 3 then begin
        Card.draw_section_band ~pad_x:2 grid
          ~rect:(Rect.make ~x:panel.x ~y:!y ~w:panel.w ~h:2)
          ~theme ~left_title:("@" ^ name) ~right_meta:status_s
          ~subtitle:(Printf.sprintf "%s · %s" company_s sb_lbl)
          ();
        y := !y + 3
      end;
      let spec_r =
        Rect.make ~x:(panel.x + 1) ~y:!y ~w:(Int.max 0 (panel.w - 2))
          ~h:(Int.max 0 (bot - !y))
      in
      (* 2. Compact 3-line Spec Strip *)
      if !y < bot then begin
        Ops_common.draw_kv_row grid ~rect:spec_r ~y:!y ~theme ~bg ~label_w:12
          ~key:(Ops_common.say model ~ko:"런타임" ~en:"Runtime")
          ~value:rt_s ();
        incr y
      end;
      if !y < bot then begin
        Ops_common.draw_kv_row grid ~rect:spec_r ~y:!y ~theme ~bg ~label_w:12
          ~key:(Ops_common.say model ~ko:"격리 · 작업" ~en:"Sandbox / Task")
          ~value:(Printf.sprintf "%s · %s" sb_lbl task_s)
          ~val_fg:(Theme.status_color theme sb_tone) ();
        incr y
      end;
      if !y < bot then begin
        Ops_common.draw_kv_row grid ~rect:spec_r ~y:!y ~theme ~bg ~label_w:12
          ~key:(Ops_common.say model ~ko:"누적 턴 · 캔들" ~en:"Total · Candle")
          ~value:
            (Printf.sprintf "%s %s  ·  %s" turns_s
               (Ops_common.say model ~ko:"누적 턴" ~en:"total turns")
               candle_s)
          ~val_fg:theme.status_ai ();
        incr y
      end;
      (* 3. Honest observation status or Hairline + Tier-4 italic guidance *)
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
                   (Typography.status ~bg ~bold:true theme Theme.Status_critical)
                 (Glyph.to_utf8 Glyph.Live_failing ^ " "
                  ^ Ops_common.say model
                      ~ko:("대화 이력 조회 실패: " ^ reason)
                      ~en:("Chat history fetch failed: " ^ reason)))
        | Observed.Loading _ ->
            ignore
              (Ops_common.put_line ~clip:spec_r grid ~x:spec_r.x ~y:!y
                 ~max_w:spec_r.w
                 ~style:(Typography.status ~bg ~italic:true theme Theme.Status_active)
                 (Glyph.to_utf8 Glyph.Transport_reconnecting ^ " "
                  ^ Ops_common.say model ~ko:"대화 이력을 불러오는 중…"
                      ~en:"Loading chat history…"))
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
            ~ko:"\"/status  ·  [i] 메시지 입력  ·  [V] 음성 PTT\""
            ~en:"\"/status  ·  [i] Compose message  ·  [V] Voice PTT\"";
        ]
      in
      List.iter
        (fun prompt ->
          if !y < bot then begin
            Card.draw_left_rail ~bg ~tone:Theme.Status_ai grid ~x:spec_r.x ~y:!y
              ~h:1 ~theme;
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
    end

let draw_keeper_status_strip grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~name (keeper_opt : Wire_fleet.keeper_summary option) =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_2 in
    let base_st = Typography.structure ~bg theme in
    Cell_grid.fill_rect ~clip:rect grid ~rect ~style:base_st ();
    let has_attn = Ops_common.keeper_has_attention model.attention name in
    let glyph, tone, act_str, rt_str, ctx_ratio_opt =
      match keeper_opt with
      | Some k ->
          let g, t, _ =
            Ops_common.keeper_live_status ~has_attention:has_attn k
          in
          let act =
            Say.resolve model.lang (Ops_common.activation_label k.activation_mode)
          in
          let rt = Ops_common.human_runtime_label ~model k in
          let ctx_opt = Observed.to_option k.context_ratio in
          (g, t, act, rt, ctx_opt)
      | None ->
          ( Glyph.Live_idle
          , Theme.Status_historical
          , Glyph.to_utf8 Glyph.Missing_absent
          , Glyph.to_utf8 Glyph.Missing_absent
          , None )
    in
    let infra_tag, _ = Ops_common.keeper_sandbox_tag ~model name in
    let trail_n = Ops_common.keeper_incident_count model.incidents name in
    let sep = Typography.sep_dot in
    let trail_part =
      if trail_n > 0 then
        Printf.sprintf "%s%s%d [I]" sep (Glyph.to_utf8 Glyph.Recovered) trail_n
      else ""
    in
    let voice_part =
      match model.drafts.voice with
      | Drafts.Voice_recording { elapsed_s; _ } ->
          Printf.sprintf "%sREC %.1fs" sep elapsed_s
      | Drafts.Voice_transcribing ->
          sep ^ Ops_common.say model ~ko:"음성 변환 중" ~en:"Transcribing"
      | Drafts.Voice_speaking ->
          sep ^ Ops_common.say model ~ko:"음성 출력" ~en:"Speaking"
      | Drafts.Voice_error e ->
          sep ^ "Voice " ^ Glyph.to_utf8 Glyph.Live_failing ^ " " ^ e
      | Drafts.Voice_off -> ""
    in
    let wave_w = 10 in
    let voice_levels_opt =
      match model.drafts.voice with
      | Drafts.Voice_recording { levels; _ } when rect.w >= 48 && levels <> [] ->
          Some levels
      | Drafts.Voice_recording _
      | Drafts.Voice_off
      | Drafts.Voice_transcribing
      | Drafts.Voice_speaking
      | Drafts.Voice_error _ ->
          None
    in
    let show_ctx_gauge =
      Option.is_none voice_levels_opt && rect.w >= 48
    in
    let ctx_block_w = if show_ctx_gauge then 18 else 0 in
    let right_reserve =
      match voice_levels_opt with
      | Some _ -> wave_w + 2
      | None -> if ctx_block_w > 0 then ctx_block_w + 2 else 1
    in
    let text_right_limit = Rect.right rect - right_reserve in
    let cx = ref (rect.x + 2) in
    Cell_grid.put_glyph ~clip:rect grid ~x:!cx ~y:rect.y
      ~style:(Typography.status ~bg ~bold:true theme tone)
      glyph;
    cx := !cx + 2;
    let adv_n =
      Ops_common.put_line ~clip:rect grid ~x:!cx ~y:rect.y
        ~max_w:(Int.max 0 (text_right_limit - !cx))
        ~style:(Typography.anchor ~bg theme)
        name
    in
    cx := !cx + adv_n;
    let rest_str =
      Printf.sprintf "%s%s%s%s%s%s%s%s" sep act_str sep rt_str sep infra_tag
        trail_part voice_part
    in
    ignore
      (Ops_common.put_line ~clip:rect grid ~x:!cx ~y:rect.y
         ~max_w:(Int.max 0 (text_right_limit - !cx))
         ~style:base_st rest_str);
    (* Right cluster: Voice waveform when recording, else smooth inline Ctx % Ratio_gauge *)
    match voice_levels_opt with
    | Some levels ->
        let wx = Rect.right rect - wave_w - 2 in
        let samples = Ops_common.samples_of_floats levels in
        ignore
          (Chart.draw_sparkline_run ~clip:rect grid ~x:wx ~y:rect.y
             ~width:wave_w ~theme ~bg ~unicode:true
             ~gradient:Chart.Gradient.Cool_flow samples)
    | None ->
        if show_ctx_gauge then begin
          let gx = Rect.right rect - ctx_block_w - 1 in
          match ctx_ratio_opt with
          | Some raw ->
              let ratio = Float.max 0.0 (Float.min 1.0 raw) in
              let lbl = Printf.sprintf "Ctx %2.0f%% " (ratio *. 100.0) in
              let adv_l =
                Ops_common.put_line ~clip:rect grid ~x:gx ~y:rect.y ~max_w:9
                  ~style:(Typography.whisper ~bg ~italic:false theme)
                  lbl
              in
              ignore
                (Chart.draw_ratio_bar_run ~clip:rect grid ~x:(gx + adv_l)
                   ~y:rect.y ~width:(Int.max 4 (ctx_block_w - adv_l)) ~theme ~bg
                   ~unicode:true
                   ~gradient:
                     (if ratio >= 0.80 then Chart.Gradient.Thermal
                      else Chart.Gradient.Cool_flow)
                   ~ratio)
          | None ->
              ignore
                (Ops_common.put_line ~clip:rect grid ~x:gx ~y:rect.y
                   ~max_w:ctx_block_w ~style:(Typography.whisper ~bg theme)
                   "Ctx —  [V] PTT")
        end

let stream_reply_already_persisted =
  Chat_transcript.stream_reply_already_persisted

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
    let hist_msgs =
      match Observed.to_option hist_obs with
      | Some page -> page.messages
      | None -> []
    in
    let stream_rows =
      match Fleet_store.String_map.find_opt name model.fleet.chat_streams with
      | Some buf ->
          if
            (not buf.active)
            && Option.is_none buf.last_error
            && stream_reply_already_persisted hist_msgs buf
          then []
          else build_stream_rows ~theme ~model ~keeper_name:name ~width:prose_w buf
      | None -> []
    in
    let pending_rows =
      build_pending_tx_rows ~theme ~model ~keeper_name:name ~width:prose_w
    in
    let hist_rows =
      build_history_rows ~theme ~model ~keeper_name:name ~width:prose_w hist_msgs
    in
    let all_rows =
      let with_stream =
        if stream_rows = [] then hist_rows
        else if hist_rows = [] then stream_rows
        else hist_rows @ [ blank_row ~bg_rgb:theme.surface_1 ] @ stream_rows
      in
      if pending_rows = [] then with_stream
      else if with_stream = [] then pending_rows
      else with_stream @ [ blank_row ~bg_rgb:theme.surface_1 ] @ pending_rows
    in
    if all_rows = [] then
      render_empty_chat_context grid ~rect:body_rect ~theme ~model ~name
        ~hist_obs keeper_opt
    else
      draw_transcript_rows grid ~rect:body_rect ~theme ~pad_x
        ~scroll:model.fleet.chat_scroll_offset all_rows;
    if status_h = 1 then
      draw_keeper_status_strip grid ~rect:status_rect ~theme ~model ~name
        keeper_opt

(* --- Tab 2: Memory (Scoped Temporal Diff Scrubber + Heat Stacked_bar + Librarian) --- *)

let heat_badge = function
  | Wire_knowledge.Heat_hot -> ("HOT", Theme.Status_critical)
  | Wire_knowledge.Heat_warm -> ("WARM", Theme.Status_attention)
  | Wire_knowledge.Heat_cold -> ("COLD", Theme.Status_active)
  | Wire_knowledge.Heat_never_retrieved -> ("0x", Theme.Status_historical)

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

let relation_label ~lang = function
  | Wire_knowledge.Revision -> Say.resolve lang (Say.make ~ko:"개정" ~en:"rev")
  | Wire_knowledge.Program_revision ->
      Say.resolve lang (Say.make ~ko:"규칙 개정" ~en:"prog-rev")
  | Wire_knowledge.Program_absorption ->
      Say.resolve lang (Say.make ~ko:"흡수" ~en:"absorb")

let render_memory_tab grid ~(rect : Rect.t) ~(theme : Theme.t) ~(model : Model.t)
    ~name =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = Ops_common.pad_x_for ~model rect in
    let bar_rect, rest_rect = Rect.split_v rect ~top_h:1 in
    let win = model.knowledge.memory_diff_window in
    let rev_pill_lbl =
      match win with
      | Knowledge_store.Window_revs { from_rev; to_rev } ->
          Printf.sprintf "rev %d..%d" from_rev to_rev
      | Knowledge_store.Window_24h
      | Knowledge_store.Window_7d
      | Knowledge_store.Window_30d ->
          "rev"
    in
    let pills =
      [
        ("24h", Knowledge_store.equal_memory_diff_window win Knowledge_store.Window_24h, None);
        ("7d", Knowledge_store.equal_memory_diff_window win Knowledge_store.Window_7d, None);
        ("30d", Knowledge_store.equal_memory_diff_window win Knowledge_store.Window_30d, None);
        ( rev_pill_lbl
        , (match win with
           | Knowledge_store.Window_revs _ -> true
           | Knowledge_store.Window_24h
           | Knowledge_store.Window_7d
           | Knowledge_store.Window_30d ->
               false)
        , None );
      ]
    in
    ignore (Ops_common.draw_pills grid ~rect:bar_rect ~theme ~bg pills);
    let footer_h = if rest_rect.h >= 6 then 2 else 0 in
    let body_rect, writer_rect =
      Rect.split_v rest_rect ~top_h:(Int.max 0 (rest_rect.h - footer_h))
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
    match model.knowledge.memory_diff with
    | Observed.Value { data = diff; _ } -> (
        match diff.body with
        | Wire_knowledge.Keeper_diff
            { counts; added; updated; retracted; invalidated; writer_status; _ } ->
            let scope_matches =
              match diff.scope with
              | Wire_knowledge.Scope_keeper k -> String.equal k name
              | Wire_knowledge.Scope_world -> false
            in
            if not scope_matches then begin
              if not (Rect.is_empty content) then begin
                let msg =
                  Ops_common.say model
                    ~ko:
                      (Printf.sprintf
                         "%s 기억 Diff 불러오기 대기 중 · [r] 키로 새로고침" name)
                    ~en:
                      (Printf.sprintf
                         "Awaiting scoped memory diff for %s · press [r] to refresh"
                         name)
                in
                ignore
                  (Ops_common.put_line ~clip:content grid ~x:content.x
                     ~y:(content.y + Int.min 1 (Int.max 0 (content.h - 1)))
                     ~max_w:content.w ~style:(Typography.whisper ~bg theme)
                     (Glyph.to_utf8 Glyph.Transport_reconnecting ^ " " ^ msg))
              end;
              draw_librarian_footer None
            end
            else begin
              let y = ref content.y in
              let bottom = Rect.bottom content in
              let heat = diff.retrieval_heat in
              let rev_span =
                match diff.range.from_rev, diff.range.to_rev with
                | Some a, Some b -> Printf.sprintf "rev %d -> %d" a b
                | Some a, None -> Printf.sprintf "rev %d.." a
                | None, Some b -> Printf.sprintf "..rev %d" b
                | None, None ->
                    (match diff.range.window with Some w -> w | None -> "24h")
              in
              let summary_line =
                Printf.sprintf "%s %s %d facts %s +%d ~%d -%d !%d %s HOT:%d WARM:%d COLD:%d"
                  rev_span
                  (Glyph.to_utf8 Glyph.Separator_dot)
                  counts.total_facts_now
                  (Glyph.to_utf8 Glyph.Separator_dot)
                  counts.added counts.updated counts.retracted counts.invalidated
                  (Glyph.to_utf8 Glyph.Separator_dot)
                  heat.hot heat.warm heat.cold
              in
              if !y < bottom then begin
                ignore
                  (Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                     ~max_w:content.w ~style:(Typography.structure ~bg ~bold:true theme)
                     summary_line);
                incr y
              end;
              (* Memory OS Internals strip (Compaction · Canonical Turns · Digest · Librarian Molt) *)
              (match Observed.to_option model.knowledge.memory_os_internals with
              | Some intr when String.equal intr.keeper name && !y < bottom ->
                  let comp_s =
                    if intr.compaction.present then
                      Printf.sprintf "compaction:%dep/%dt/%dB"
                        intr.compaction.epoch_count
                        intr.compaction.archived_turns_count
                        intr.compaction.anchor_bytes
                    else "compaction:none"
                  in
                  let ct_s =
                    if intr.canonical_turns.present then
                      let rk =
                        Option.value intr.canonical_turns.latest_runtime_kind
                          ~default:"?"
                      in
                      let wm =
                        match intr.canonical_turns.compaction_watermark_seq with
                        | Some s -> Printf.sprintf ",wm:%d" s
                        | None -> ""
                      in
                      Printf.sprintf "turns:%d(%s%s,rst:%d)"
                        intr.canonical_turns.turn_count rk wm
                        intr.canonical_turns.history_resets_count
                    else "turns:none"
                  in
                  let dig_s =
                    if intr.memory_digest.present then
                      let rev_s =
                        match intr.memory_digest.revision with
                        | Some r -> Printf.sprintf "r%d" r
                        | None -> "r?"
                      in
                      let sha_s =
                        match intr.memory_digest.digest_sha256 with
                        | Some s when String.length s > 8 ->
                            "#" ^ String.sub s 0 8
                        | Some s -> "#" ^ s
                        | None -> ""
                      in
                      Printf.sprintf "digest:%s%s/%df/%dB" rev_s sha_s
                        intr.memory_digest.fact_count intr.memory_digest.bytes
                    else "digest:none"
                  in
                  let molt_s =
                    match intr.librarian_molt.pending_molt_kind with
                    | Some mk ->
                        let cats =
                          if intr.librarian_molt.pending_molt_categories = []
                          then ""
                          else
                            "("
                            ^ String.concat ","
                                intr.librarian_molt.pending_molt_categories
                            ^ ")"
                        in
                        "molt:" ^ mk ^ cats
                    | None -> "molt:clear"
                  in
                  let os_line =
                    Printf.sprintf "OS %s %s %s %s %s %s %s"
                      comp_s (Glyph.to_utf8 Glyph.Separator_dot)
                      ct_s (Glyph.to_utf8 Glyph.Separator_dot)
                      dig_s (Glyph.to_utf8 Glyph.Separator_dot)
                      molt_s
                  in
                  ignore
                    (Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                       ~max_w:content.w ~style:(Typography.structure ~bg theme)
                       os_line);
                  incr y
              | _ -> ());
              (* Visual Tier Breakdown Bar (Chart.Stacked_bar, ~show_title:false) *)
              let heat_total = heat.hot + heat.warm + heat.cold + heat.never_retrieved in
              if heat_total > 0 && bottom - !y >= 4 then begin
                let bar_r = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:2 in
                let segments =
                  [
                    (Say.literal "HOT", Float.of_int heat.hot, Theme.Status_critical);
                    (Say.literal "WARM", Float.of_int heat.warm, Theme.Status_attention);
                    (Say.literal "COLD", Float.of_int heat.cold, Theme.Status_active);
                    (Say.literal "0x", Float.of_int heat.never_retrieved, Theme.Status_historical);
                  ]
                  |> List.filter (fun (_, v, _) -> v > 0.0)
                in
                ignore
                  (Chart.draw grid ~rect:bar_r ~theme
                     ~caps:Ops_common.default_caps ~lang:model.lang
                     ~show_title:false
                     {
                       Chart.Spec.title = Say.make ~ko:"기억 열도" ~en:"Heat";
                       kind =
                         Chart.Spec.Stacked_bar
                           {
                             segments;
                             total_label =
                               Say.literal
                                 (Printf.sprintf "%d hits" heat.total_events);
                             unit = Format_val.Count;
                           };
                       hotkey_hint = None;
                     });
                y := !y + 2;
                if !y < bottom then begin
                  Card.draw_hairline ~pad_x:0 ~bg grid ~rect:content ~y:!y ~theme;
                  incr y
                end
              end;
              let emit_railed ?rail_tone ~fg ~attrs line =
                if !y < bottom then begin
                  let x0 =
                    match rail_tone with
                    | Some tok ->
                        Card.draw_left_rail ~bg ~tone:tok grid ~x:content.x
                          ~y:!y ~h:1 ~theme;
                        content.x + 2
                    | None -> content.x + 2
                  in
                  let st = Style.make ~fg:(Color.of_rgb fg) ~bg ~attrs () in
                  ignore
                    (Ops_common.put_line ~clip:content grid ~x:x0 ~y:!y
                       ~max_w:(Int.max 0 (Rect.right content - x0))
                       ~style:st line);
                  incr y
                end
              in
              List.iter
                (fun (f : Wire_knowledge.memory_fact_entry) ->
                  let h_lbl, _ = heat_badge f.heat in
                  emit_railed ~rail_tone:Theme.Status_ok ~fg:theme.status_ok
                    ~attrs:Attr.bold
                    (Printf.sprintf "+ [%s] %s · %s %dx" f.category f.origin
                       h_lbl f.retrieval_count);
                  emit_railed ~rail_tone:Theme.Status_ok ~fg:theme.text_primary
                    ~attrs:Attr.none ("  " ^ f.text))
                added;
              List.iter
                (fun (u : Wire_knowledge.memory_updated_fact) ->
                  let h_lbl, _ = heat_badge u.after.heat in
                  emit_railed ~rail_tone:Theme.Status_active
                    ~fg:theme.status_active ~attrs:Attr.bold
                    (Printf.sprintf "~ [%s] %s rev %d · %s %dx" u.after.category
                       (relation_label ~lang:model.lang u.relation)
                       u.at_rev h_lbl u.after.retrieval_count);
                  emit_railed ~rail_tone:Theme.Status_active
                    ~fg:theme.status_critical ~attrs:Attr.none
                    ("  - " ^ u.before.text);
                  emit_railed ~rail_tone:Theme.Status_active ~fg:theme.status_ok
                    ~attrs:Attr.none ("  + " ^ u.after.text))
                updated;
              List.iter
                (fun (r : Wire_knowledge.memory_retracted_fact) ->
                  let reason_s =
                    match r.drop_reason with
                    | Some rs -> " (" ^ rs ^ ")"
                    | None -> ""
                  in
                  emit_railed ~rail_tone:Theme.Status_critical
                    ~fg:theme.status_critical ~attrs:Attr.bold
                    (Printf.sprintf "- [%s] rev %d · %s%s" r.category
                       r.removed_at_rev r.removed_by reason_s);
                  emit_railed ~rail_tone:Theme.Status_critical
                    ~fg:theme.text_muted ~attrs:Attr.italic ("  " ^ r.text))
                retracted;
              List.iter
                (fun (inv : Wire_knowledge.memory_invalidated_fact) ->
                  emit_railed ~rail_tone:Theme.Status_attention
                    ~fg:theme.status_attention ~attrs:Attr.bold
                    (Printf.sprintf "! rev %d · missing premises: %s" inv.at_rev
                       (String.concat ", " inv.missing_premise_ids));
                  emit_railed ~rail_tone:Theme.Status_attention
                    ~fg:theme.text_secondary ~attrs:Attr.none ("  " ^ inv.text))
                invalidated;
              if
                added = [] && updated = [] && retracted = [] && invalidated = []
              then
                emit_railed ~fg:theme.text_muted ~attrs:Attr.italic
                  (Ops_common.say model
                     ~ko:"선택한 기간 내 기억 변경 사항이 없습니다."
                     ~en:"No memory changes recorded in this window.");
              draw_librarian_footer writer_status
            end
        | Wire_knowledge.World_diff { counts; _ } ->
            if not (Rect.is_empty content) then begin
              let msg =
                Ops_common.say model
                  ~ko:
                    (Printf.sprintf
                       "현재 월드 기억 Diff 로드됨 (%d claims) · [r] 키로 %s 범위 조회"
                       counts.total_claims_now name)
                  ~en:
                    (Printf.sprintf
                       "World memory diff loaded (%d claims) · press [r] to load %s"
                       counts.total_claims_now name)
              in
              ignore
                (Ops_common.put_line ~clip:content grid ~x:content.x
                   ~y:(content.y + Int.min 1 (Int.max 0 (content.h - 1)))
                   ~max_w:content.w ~style:(Typography.whisper ~bg theme) msg)
            end;
            draw_librarian_footer None)
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        Ops_common.draw_observed_empty grid ~rect:body_rect ~theme
          ~lang:model.lang obs
          ~empty_msg:
            (Say.make ~ko:"기억 변경 이력이 없습니다" ~en:"No memory diff available");
        draw_librarian_footer None

(* --- Tab 3: Work & Candle (ZERO Nested Boxes — uses v_hairline / hairline!) --- *)

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
      List.filter
        (fun (sc : Wire_work.schedule_row) ->
          Option.equal String.equal sc.payload_keeper_name (Some name)
          || Option.equal String.equal sc.payload_target (Some name))
        (Work_store.schedules_list model.work)
    in
    let keeper_posts =
      List.filter
        (fun (p : Wire_knowledge.board_post) -> String.equal p.author name)
        (Knowledge_store.filtered_posts model.knowledge)
    in
    let y = ref l_content.y in
    let bottom = Rect.bottom l_content in
    let emit ~fg ~attrs line =
      if !y < bottom then begin
        let st = Style.make ~fg:(Color.of_rgb fg) ~bg ~attrs () in
        ignore
          (Ops_common.put_line ~clip:l_content grid ~x:l_content.x ~y:!y
             ~max_w:l_content.w ~style:st line);
        incr y
      end
    in
    let total_tasks = List.length keeper_tasks in
    let shown_tasks = List.take 5 keeper_tasks in
    let tasks_count_lbl =
      if total_tasks > List.length shown_tasks then
        Printf.sprintf "%d/%d" (List.length shown_tasks) total_tasks
      else Int.to_string total_tasks
    in
    if !y < bottom then begin
      Card.draw_hairline ~pad_x:0 ~bg
        ~label:
          (Printf.sprintf "%s (%s)"
             (Ops_common.say model ~ko:"할당 작업" ~en:"Assigned Tasks")
             tasks_count_lbl)
        grid ~rect:l_content ~y:!y ~theme;
      incr y
    end;
    if keeper_tasks = [] then
      emit ~fg:theme.text_muted ~attrs:Attr.italic
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
          emit ~fg:(Theme.status_color theme tok) ~attrs:Attr.none
            (Printf.sprintf "%s %s %s %s" (Glyph.to_utf8 g) tk.id tk.title gl))
        shown_tasks;
    let total_scheds = List.length keeper_scheds in
    let shown_scheds = List.take 4 keeper_scheds in
    let scheds_count_lbl =
      if total_scheds > List.length shown_scheds then
        Printf.sprintf "%d/%d" (List.length shown_scheds) total_scheds
      else Int.to_string total_scheds
    in
    if !y < bottom then begin
      Card.draw_hairline ~pad_x:0 ~bg
        ~label:
          (Printf.sprintf "%s (%s)"
             (Ops_common.say model ~ko:"예약 일정" ~en:"Schedules")
             scheds_count_lbl)
        grid ~rect:l_content ~y:!y ~theme;
      incr y
    end;
    if keeper_scheds = [] then
      emit ~fg:theme.text_muted ~attrs:Attr.italic
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
          emit ~fg:(Theme.status_color theme wake_tok) ~attrs:Attr.none
            (Printf.sprintf "%s · %s%s" sc.recurrence_summary wake_txt summary))
        shown_scheds;
    let total_posts = List.length keeper_posts in
    let avail_post_rows = Int.max 0 (bottom - (!y + 1)) in
    let posts_overflow = total_posts > avail_post_rows in
    let shown_post_limit =
      if posts_overflow then Int.max 0 (avail_post_rows - 1) else total_posts
    in
    let shown_posts = List.take shown_post_limit keeper_posts in
    let posts_count_lbl =
      if posts_overflow && shown_post_limit > 0 then
        Printf.sprintf "%d/%d" (List.length shown_posts) total_posts
      else Int.to_string total_posts
    in
    if !y < bottom then begin
      Card.draw_hairline ~pad_x:0 ~bg
        ~label:
          (Printf.sprintf "%s (%s)"
             (Ops_common.say model ~ko:"최근 보드 글" ~en:"Recent Board Posts")
             posts_count_lbl)
        grid ~rect:l_content ~y:!y ~theme;
      incr y
    end;
    if keeper_posts = [] then
      emit ~fg:theme.text_muted ~attrs:Attr.italic
        (Ops_common.say model ~ko:"최근 보드 작성 글 없음"
           ~en:"No recent board posts")
    else begin
      List.iter
        (fun (p : Wire_knowledge.board_post) ->
          let hearth =
            match p.hearth with Some h -> "#" ^ h | None -> "#all"
          in
          emit ~fg:theme.text_primary ~attrs:Attr.none
            (Printf.sprintf "%s %s (%s+%d · %dc)" hearth p.title
               (Glyph.to_utf8 Glyph.Delta_up)
               p.score p.comment_count))
        shown_posts;
      let hidden_posts = total_posts - List.length shown_posts in
      if hidden_posts > 0 then
        emit ~fg:theme.text_muted ~attrs:Attr.italic
          (Ops_common.say model
             ~ko:
               (Printf.sprintf "%s 외 %d건"
                  (Glyph.to_utf8 Glyph.Ellipsis)
                  hidden_posts)
             ~en:
               (Printf.sprintf "%s +%d more"
                  (Glyph.to_utf8 Glyph.Ellipsis)
                  hidden_posts))
    end;
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
  match Observed.to_option model.infra.keeper_sandbox with
  | Some resp when String.equal resp.keeper name ->
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
  | Some _ | None -> (
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
            (match Fleet_store.sandbox_profile_of ~keeper:name model.fleet with
            | Some _ ->
                let lbl, tone = Ops_common.keeper_sandbox_label ~model name in
                Ops_common.draw_kv_row grid ~rect:top_rect ~y:top_rect.y ~theme
                  ~bg ~label_w:14
                  ~key:(Ops_common.say model ~ko:"프로필" ~en:"Profile")
                  ~value:lbl ~val_fg:(Theme.status_color theme tone)
                  ~val_attrs:Attr.bold ();
                if top_rect.h >= 2 then
                  ignore
                    (Ops_common.put_line ~clip:top_rect grid ~x:top_rect.x
                       ~y:(top_rect.y + 1) ~max_w:top_rect.w
                       ~style:(Typography.whisper ~bg theme)
                       (Ops_common.say model
                          ~ko:"상세 샌드박스 프로브 데이터 대기 중"
                          ~en:"Detailed sandbox telemetry pending"))
            | None ->
                Ops_common.draw_observed_empty grid ~rect:top_rect ~theme
                  ~lang:model.lang model.infra.keeper_sandbox
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
            (List.take body_logs.h keeper_logs)
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
    | Wire_config.Remove_key _ -> Form.Text_val ""

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
  let schema_fields =
    match Observed.to_option cfg.schema with
    | Some schema
      when target_matches
           && Config_store.equal_config_target schema.target
                (Wire_config.Target_keeper name) ->
        List.concat_map
          (fun (sec : Wire_config.schema_section) -> sec.fields)
          schema.sections
    | Some _ | None -> []
  in
  let fields =
    if schema_fields <> [] then
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
                Form.Text_val cfg.editing_buffer
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
              ~reload_scope:Form.Hot_reload ~read_only:true
              (Form.Text_val k.company);
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
  let filter = if target_matches then cfg.search_query else "" in
  let st0 = { (Form.create fields) with filter } in
  let vis = Form.visible_indices st0 in
  let focused =
    if not target_matches then 0
    else
      let matched_by_store_sel =
        match Config_store.selected_field cfg with
        | None -> None
        | Some sf ->
            let n = Array.length st0.fields in
            let rec find i =
              if i >= n then None
              else if String.equal st0.fields.(i).key sf.full_key then Some i
              else find (i + 1)
            in
            find 0
      in
      match matched_by_store_sel with
      | Some idx -> idx
      | None -> (
          let vlen = List.length vis in
          if vlen = 0 then 0
          else
            let clamped =
              Int.max 0 (Int.min (vlen - 1) cfg.selected_field_index)
            in
            match List.nth_opt vis clamped with Some idx -> idx | None -> 0)
  in
  {
    st0 with
    focused;
    editing = target_matches && Option.is_some cfg.editing_field_key;
  }

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
    let hdr_str =
      Printf.sprintf "%s %s %s %s %d %s"
        (Ops_common.say model ~ko:"인라인 키퍼 설정" ~en:"Scoped Keeper Settings")
        (Glyph.to_utf8 Glyph.Separator_dot)
        name
        (Glyph.to_utf8 Glyph.Separator_dot)
        dirty_n
        (Ops_common.say model ~ko:"건 변경 대기 · [Ctrl+S] 저장 · [$EDITOR 불필요]"
           ~en:"staged · [Ctrl+S] Save · [Zero $EDITOR]")
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
    let form_st =
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
    if Array.length form_st.fields = 0 then
      Ops_common.draw_observed_empty grid ~rect:form_rect ~theme
        ~lang:model.lang model.config.schema
        ~empty_msg:
          (Say.make ~ko:"키퍼 설정 스키마를 불러오는 중"
             ~en:"Loading keeper configuration schema")
    else
      ignore
        (Form.draw grid ~rect:form_rect ~theme ~lang:model.lang ~pad_x
           ~section_header ~show_row_badges:false ~show_help_footer:true form_st);
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
          (Diff.draw grid ~rect:body ~theme ~language:Code_lexer.Toml numbered)
    | Some _ | None -> ()

(* --- Embedded Live Keeper Preview Header + 4-Metric Telemetry Strip --- *)

let keeper_turns_24h_opt (k : Wire_fleet.keeper_summary) =
  match k.activity_sparkline_24h with
  | [] -> None
  | slots ->
      let sum =
        List.fold_left
          (fun acc v -> if Float.is_finite v && v > 0.0 then acc +. v else acc)
          0.0 slots
      in
      Some (int_of_float (Float.round sum))

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
    let ctx_ratio_opt = Observed.to_option k.context_ratio in
    let turns_label, turns_short, turns_s =
      match keeper_turns_24h_opt k with
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
        (Ops_common.keeper_cost_24h ~model k)
        ~lang:model.lang
    in
    let candle_s =
      match Ops_common.keeper_candle_milli ~model name with
      | Some (_, dec_s) ->
          Glyph.to_utf8 Glyph.Ai_spark ^ " "
          ^ Ops_common.format_milli_string dec_s
      | None -> Glyph.to_utf8 Glyph.Ai_spark ^ " 0.000 C"
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
              (* Context % gauge *)
              let pct_s =
                match ctx_ratio_opt with
                | Some r ->
                    Printf.sprintf "%.0f%%"
                      (Float.max 0.0 (Float.min 1.0 r) *. 100.0)
                | None -> Glyph.to_utf8 Glyph.Missing_absent
              in
              Ops_common.draw_kpi_line grid ~rect:cr ~y:cr.y ~theme ~bg
                ~label:(Ops_common.say model ~ko:"컨텍스트" ~en:"Ctx")
                ~short_label:"Ctx" ~value:pct_s
                ~val_style:(Typography.anchor ~bg theme);
              if cr.h >= 2 then
                (match ctx_ratio_opt with
                | Some r ->
                    let ratio = Float.max 0.0 (Float.min 1.0 r) in
                    ignore
                      (Chart.draw_ratio_bar_run ~clip:cr grid ~x:cr.x
                         ~y:(cr.y + 1) ~width:(Int.min 12 cr.w) ~theme ~bg
                         ~unicode:true
                         ~gradient:
                           (if ratio >= 0.80 then Chart.Gradient.Thermal
                            else Chart.Gradient.Cool_flow)
                         ~ratio)
                | None ->
                    ignore
                      (Ops_common.put_line ~clip:cr grid ~x:cr.x ~y:(cr.y + 1)
                         ~max_w:cr.w ~style:(Typography.whisper ~bg theme)
                         (Ops_common.say model ~ko:"미보고" ~en:"unreported")))
          | 1 ->
              (* Honest 24h Turns (from 24h sparkline) or explicit Total turns *)
              Ops_common.draw_kpi_line grid ~rect:cr ~y:cr.y ~theme ~bg
                ~label:turns_label ~short_label:turns_short
                ~value:turns_s ~val_style:(Typography.anchor ~bg theme);
              if cr.h >= 2 then
                let samples = Ops_common.samples_of_floats k.activity_sparkline_24h in
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
              (* 24h Cost *)
              Ops_common.draw_kpi_line grid ~rect:cr ~y:cr.y ~theme ~bg
                ~label:(Ops_common.say model ~ko:"24h 비용" ~en:"Cost")
                ~short_label:(Ops_common.say model ~ko:"비용" ~en:"$")
                ~value:cost_s ~val_style:(Typography.anchor ~bg theme);
              if cr.h >= 2 then
                let tok_s =
                  Format_val.format_observed Format_val.Tokens
                    (Observed.map Float.of_int k.total_tokens)
                    ~lang:model.lang
                in
                ignore
                  (Ops_common.put_line ~clip:cr grid ~x:cr.x ~y:(cr.y + 1)
                     ~max_w:cr.w ~style:(Typography.whisper ~bg theme)
                     (tok_s ^ " tok"))
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

(* --- Unified 5-Tab Keeper Dive Entrypoint --- *)

let render_tabs_body ~embedded ~name ~tab ~(model : Model.t) ~cache
    ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Ops_common.theme_of_model model in
    let keeper_opt = Fleet_store.find_keeper ~name model.fleet in
    let has_attn = Ops_common.keeper_has_attention model.attention name in
    let badge_opt =
      match keeper_opt with
      | Some k ->
          let g, tok, lbl =
            Ops_common.keeper_live_status ~has_attention:has_attn k
          in
          Some
            {
              Card.glyph = Some g;
              text = Say.resolve model.lang lbl;
              tone = Some tok;
            }
      | None -> None
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
      Option.is_some (Fleet_store.active_turn_for ~keeper:name model.fleet)
      ||
      match Fleet_store.String_map.find_opt name model.fleet.chat_streams with
      | Some buf -> buf.active
      | None -> false
    in
    let hotkey =
      if embedded then
        Some
          (Ops_common.say model ~ko:"[Ctrl+T] 큐 · [z] 확대"
             ~en:"[Ctrl+T] Queue · [z] Zoom")
      else if Nav.equal_keeper_tab tab Nav.Keeper_chat && has_running_turn then
        Some
          (Ops_common.say model ~ko:"[Esc/Ctrl+X] 턴 중단 · [y] 복사 · [ ] 탭"
             ~en:"[Esc/Ctrl+X] Interrupt · [y] Copy · [ ] Tab")
      else
        Some
          (Ops_common.say model ~ko:"[ ] 탭 · [y] 응답 복사 · [Esc] 목록"
             ~en:"[ ] Tab · [y] Copy · [Esc] Fleet")
    in
    let footer_hint =
      if embedded then
        Some
          (Ops_common.say model
             ~ko:"[Enter] Dive · [c] 바로 채팅 · [V] 음성 PTT"
             ~en:"[Enter] Dive · [c] Quick Chat · [V] Voice PTT")
      else None
    in
    let card_spec : Card.spec =
      {
        (Card.default_spec ~title) with
        subtitle = company_sub;
        badge = badge_opt;
        hotkey;
        footer_hint;
        focused = (not embedded) || model.nav.pane_index = 1;
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
        | Nav.Keeper_memory ->
            render_memory_tab grid ~rect:content_rect ~theme ~model ~name
        | Nav.Keeper_work_candle ->
            render_work_candle_tab grid ~rect:content_rect ~theme ~model ~name
        | Nav.Keeper_sandbox ->
            render_sandbox_tab grid ~rect:content_rect ~theme ~model ~name
        | Nav.Keeper_config ->
            render_config_tab grid ~rect:content_rect ~theme ~model ~name
              keeper_opt
