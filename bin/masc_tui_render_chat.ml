(** The Keeper chat surface.

    Lifted out of masc_tui_render.ml: the definitions only this surface
    reaches. The set was computed from the parsetree call graph and is
    closed -- it refers to the shared primitives and to nothing belonging to
    another screen, which is why it can be a library rather than a region of
    one. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi
open Masc_tui_render_prim


(* The chat history as the last frame drew it: which terminal row its first
   line landed on, and what a press on each line opens. Same reason as the
   Activity pane above -- a press between frames answers what was on screen.

   The row is absolute because the two-pane split places the chat buffer
   beside the roster rather than below it, so a line's vertical position is
   the buffer's own whether or not the roster is showing. Zero means no chat
   history was drawn, which is what keeps a stale row from answering. *)

module Context_state = Masc_tui_context_state
module Frame_presenter = Masc_tui_frame_presenter
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_diff = Masc_tui_keeper_chat_diff
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Keeper_control = Masc_tui_keeper_control
module Search = Masc_tui_chat_search
module Markdown = Masc_tui_markdown
module Markdown_cache = Masc_tui_markdown_render_cache
module Message_layout = Masc_tui_message_layout
module Observation_layout = Masc_tui_observation_layout
module Tool_detail = Masc_tui_tool_detail

let chat_history_first_row = ref 0

let chat_history_actions : Message_layout.row_action array ref = ref [||]


(* The input layer reads the last frame's pane through these, never the
   cells themselves: what it needs is the answer, and the cells stay this
   module's to set once per frame. *)
let chat_row_action_at ~row =
  let first = !chat_history_first_row in
  let actions = !chat_history_actions in
  let line = row - first in
  if first > 0 && line >= 0 && line < Array.length actions then actions.(line)
  else Message_layout.Action_none


let chat_markdown ~context ~width body =
  markdown_with_closing ~closing:context.Chat_theme.markdown_close ~width body


(* The semantic Markdown palette itself is compiled into this binary. The
   generation travels separately because only a user row's ambient terminal
   background changes its closing strings. *)
let chat_markdown_theme_revision = 1


(* Large enough to hold what a scrolled pane walks.

   A frame lays out the newest [scroll + height] rows, so reading back through
   a long turn walks hundreds of messages and asks this cache for each. At a
   hundred and twenty-eight the walk evicted its own earlier answers before
   the next frame asked for them again, and every notch of the wheel rendered
   the same messages over: the pane's worst frames were spent here. The store
   finds an entry by its identity rather than by walking, so a bound this size
   costs a hash per lookup and the memory of the rows themselves. *)
let chat_markdown_cache_capacity = 1024



(* What makes one rendered entry distinct from another, as the cache sees it.
   The cache is polymorphic in its identity, so it compares whole records --
   no field is ever named on the way out. The observed time and the entry
   index are here because two entries from the same keeper and the same
   request differ only in those. The comparison reads them; no projection
   does, which is the difference the unused-field warning cannot see. *)
type chat_markdown_identity = {
  cmi_style : Message_layout.style;
  cmi_keeper_name : string;
  cmi_request_id : string;
  cmi_observed_at : float option;
  cmi_entry_index : int;
}
[@@warning "-69"]

let chat_markdown_cache =
  Markdown_cache.create ~capacity:chat_markdown_cache_capacity


let chat_markdown_streaming ~context ~width body =
  Markdown.render_streaming
    ~palette:(chat_markdown_palette ~closing:context.Chat_theme.markdown_close)
    ~width body


(* Link cards must use the body budget supplied by Message_layout, after the
   clock, role and rail have been accounted for. Preview discovery and metadata
   fetching retain the existing link-preview cache policy. *)
module Entry_cache = Ephemeron.K1.Make (struct
  type t = Message_layout.entry
  let equal = ( == )
  let hash (entry : t) = Hashtbl.hash (entry.Message_layout.style,
    entry.markdown_source, entry.body_presentation)
end)

(* Immutable entry identity owns discovery. Ephemeron keys release both URLs
   and source indexes when the projection no longer retains that entry. *)
let entry_urls = Entry_cache.create 64
let source_url_discoveries = ref 0

let bare_urls_for_entry entry =
  match Entry_cache.find_opt entry_urls entry with
  | Some urls -> urls
  | None ->
      incr source_url_discoveries;
      let seen = Hashtbl.create 4 in
      let urls = Message_layout.bare_urls entry.Message_layout.body |> List.filter (fun url ->
        if Hashtbl.mem seen url then false else (Hashtbl.add seen url (); true)) in
      Entry_cache.replace entry_urls entry urls;
      urls

let chat_body_with_previews_internal ?on_field ~preview ~mode ~(entry : Message_layout.entry) ~width () =
  let body = entry.body in
  match entry.style, entry.markdown_source with
  | (Message_layout.Tool | Skill _), _
  | _, (Message_layout.Markdown_growing _ | Markdown_streaming) -> body
  | _, Message_layout.Markdown_stable _ ->
    let cards = match mode with
      | `Off -> []
      | (`Compact | `Rich) -> List.mapi (fun index url -> index,url) (bare_urls_for_entry entry)
          |> List.filter_map (fun (index,url) ->
            let p=preview url in
            let mapped = match mode,on_field with
              | `Compact,None -> Option.map (fun row -> [row],[]) (Masc_tui_link_preview.render_compact_badge p)
              | `Compact,Some _ -> Option.map (fun (mapped : Masc_tui_link_preview.card_render) -> mapped.rows,mapped.fields)
                  (Masc_tui_link_preview.render_compact_badge_with_spans p)
              | `Rich,_ when not (Masc_tui_link_preview.has_informative_preview p) -> None
              | `Rich,None -> Some (Masc_tui_link_preview.render_inline_card ~width p,[])
              | `Rich,Some _ -> let mapped=Masc_tui_link_preview.render_inline_card_with_spans ~width p in
                  Some(mapped.rows,mapped.fields)
              | `Off,_ -> None in
            Option.map (fun (rows,fields) -> index,url,rows,fields) mapped) in
    match cards with
    | [] -> body
    | _ ->
        let offset=ref (String.length body+1) in
        let texts=List.map (fun (index,url,rows,fields) ->
          Option.iter (fun emit ->
            let row_offsets=Array.of_list rows |> Array.map (fun row ->
              let start= !offset in offset:=start+String.length row+1; start) in
            List.iter (fun (field : Masc_tui_link_preview.card_source_span) ->
              emit ~index ~url ~start:(row_offsets.(field.row)+field.row_start_byte) field) fields) on_field;
          String.concat "\n" rows) cards in
        body ^ "\n" ^ String.concat "\n" texts

let chat_body_with_previews ~preview ~mode ~entry ~width =
  chat_body_with_previews_internal ~preview ~mode ~entry ~width ()

(* A journal revision's lines, in the columns [Message_layout.journal_rows]
   cut. Two questions, two channels: the sign keeps the diff colours, since
   arrived and left is what it has always said, and the category takes a
   colour grouped by what a reader does about it rather than one hue per word
   -- eight hues is a legend to memorise, and the theme has measured contrast
   for the ones already in it. A drop is dim: the reason a fact was let go is
   not the change itself. The claim keeps the body's own colour. *)
let chat_journal_rows ~(context : Chat_theme.body_context) ~width lines =
  let palette = chat_markdown_palette ~closing:context.Chat_theme.markdown_close in
  let span_of : Message_layout.journal_piece -> string * string = function
    | Journal_piece_sign Journal_added -> palette.code_diff_added
    | Journal_piece_sign Journal_removed -> palette.code_diff_removed
    | Journal_piece_category Tone_code_change -> palette.code_type
    | Journal_piece_category Tone_learning -> palette.code_keyword
    | Journal_piece_category Tone_intent -> palette.code_string
    | Journal_piece_category Tone_blocker -> palette.code_number
    (* The default kind and the most common: colouring the majority says
       nothing about it. *)
    | Journal_piece_category Tone_fact | Journal_piece_claim | Journal_piece_space ->
        ("", "")
    | Journal_piece_drop -> palette.code_comment
  in
  Message_layout.journal_rows ~width lines
  |> List.map (fun pieces ->
         String.concat ""
           (List.map
              (fun (text, piece) ->
                let opening, closing = span_of piece in
                if String.equal opening "" then text else opening ^ text ^ closing)
              pieces))

let preview_snapshot lookup =
  let previews=Hashtbl.create 4 in
  fun url -> match Hashtbl.find_opt previews url with
    | Some value -> value
    | None -> let value=lookup url in Hashtbl.add previews url value; value

let cached_chat_markdown_with_preview ~preview ~link_previews_mode ~theme =
  fun ~(entry : Message_layout.entry) ~width ->
  let body = chat_body_with_previews ~preview ~mode:link_previews_mode ~entry ~width in
  let context = Chat_theme.body_context theme entry.style in
  let palette_generation = context.palette_generation in
  let journal =
    match entry.journal with
    | [] -> []
    | lines -> "" :: chat_journal_rows ~context ~width lines
  in
  let body_rows =
  match entry.markdown_source with
  | Message_layout.Markdown_stable
      { keeper_name; request_id; observed_at; entry_index } ->
      Markdown_cache.render chat_markdown_cache
        ~theme_revision:chat_markdown_theme_revision
        ~palette_generation ~width ~renderer:(chat_markdown ~context)
        ~identity:
          { cmi_style = entry.style;
            cmi_keeper_name = keeper_name;
            cmi_request_id = request_id;
            cmi_observed_at = Some observed_at;
            cmi_entry_index = entry_index;
          }
        ~text:body
  | Message_layout.Markdown_growing
      { keeper_name; request_id; entry_index } ->
      Markdown_cache.render_growing chat_markdown_cache
        ~theme_revision:chat_markdown_theme_revision
        ~palette_generation ~width
        ~renderer:(chat_markdown_streaming ~context)
        ~identity:
          { cmi_style = entry.style;
            cmi_keeper_name = keeper_name;
            cmi_request_id = request_id;
            cmi_observed_at = None;
            cmi_entry_index = entry_index;
        }
        ~text:body
  | Message_layout.Markdown_streaming ->
      chat_markdown ~context ~width body
  in
  body_rows @ journal


let cached_chat_markdown ~link_previews_mode ~theme =
  (* One frozen preview provider serves measurement and drawing. Search passes
     this same provider to its mapping and suffix measurement closures. *)
  cached_chat_markdown_with_preview
    ~preview:(preview_snapshot Masc_tui_link_preview.get_preview) ~link_previews_mode ~theme

type mapped_chat_body = { mapped_rows : string list; runs : Search.run list; unavailable : bool }

let search_chat_markdown ~link_previews_mode ~theme ~preview ~(entry : Message_layout.entry) ~width =
  let fields=ref [] in
  let body=chat_body_with_previews_internal ~on_field:(fun ~index ~url ~start field ->
    fields:=(index,url,start,field):: !fields) ~preview ~mode:link_previews_mode ~entry ~width () in
  let origins=Array.init (String.length body) (fun offset ->
    if offset<String.length entry.body then Some(match entry.body_presentation with
      | Source_body -> Search.Body_byte {offset;expansion=0}
      | Thinking_summary -> Search.Thinking_summary_byte offset) else None) in
  List.iter (fun (index,url,start,(field : Masc_tui_link_preview.card_source_span)) ->
    for delta=0 to field.source_end_byte-field.source_start_byte-1 do
      origins.(start+delta)<-Some(Search.Preview_byte {url;index;field=field.field;order=field.order;
        byte=field.source_start_byte+delta;expansion=0})
    done) !fields;
  let context=Chat_theme.body_context theme entry.style in
  let palette=chat_markdown_palette ~closing:context.Chat_theme.markdown_close in
  let document=Markdown.render_document_with_spans ~palette ~width body in
  let runs,unavailable=Search.of_document ~presentation:entry.body_presentation ~body_length:(String.length entry.body) ~origins document in
  let journal_rows,journal_runs=match entry.journal with
    | [] -> [],[]
    | lines ->
        let mapped=Message_layout.journal_rows_with_spans ~width lines in
        let first=List.length document.document_rows+1 in
        let fields=Hashtbl.create 16 in
        List.iter (fun (span : Message_layout.journal_source_span) ->
          let key=span.line_index,span.field in
          let ranges=List.map (fun (start_byte,end_byte) -> {Markdown.start_byte;end_byte}) span.source_ranges in
          match Hashtbl.find_opt fields key with
          | None -> Hashtbl.add fields key {Search.text=span.value;
              positions=Array.init (String.length span.value) (fun byte -> Some(Search.Journal_byte {line=span.line_index;field=span.field;byte}));
              visible_rows=[first+span.row,ranges];joins_previous=false}
          | Some (run : Search.run) -> Hashtbl.replace fields key {run with visible_rows=(first+span.row,ranges)::run.visible_rows}) mapped.journal_fields;
        let runs=Hashtbl.to_seq fields |> List.of_seq |> List.sort (fun (a,_) (b,_) -> compare a b) |> List.map snd in
        "" :: chat_journal_rows ~context ~width lines,runs in
  {mapped_rows=document.document_rows @ journal_rows;runs=runs @ journal_runs;unavailable}


(* Conversation colour names the source, not the prose. A keeper can return a
   page of Markdown; painting every byte green turns syntax, emphasis, links,
   and ordinary text into one undifferentiated status light. The compact
   reverse-video badge gives the source a background that works with the
   terminal's own light or dark palette, while the body keeps its semantic
   Markdown colours. *)
(* How many reasoning lines a folded block stands for. The count is the
   non-blank lines, matching what the unfolded block draws. *)
let folded_thinking_body body =
  let lines =
    String.split_on_char '\n' body
    |> List.filter (fun line -> String.trim line <> "")
  in
  match lines with
  (* A fold summary is itself one line, so folding one line hides nothing and
     saves nothing. It also promised an expansion: every committed reasoning
     block is the withheld-step count alone, and Ctrl-R on it redrew the same
     sentence. A block with nothing to fold draws as itself. *)
  | [] | [ _ ] -> body, Message_layout.Source_body
  (* A turn that reasons between every call draws this once a round, eight
     rounds a turn. At 61 cells the sentence was the widest thing in the pane
     and said the same "or /thinking to expand" each time; the key stays, the
     footer and /help carry the rest. Two lines or more, so always plural. *)
  | lines ->
      Printf.sprintf "Reasoning · %d lines folded · Ctrl-R" (List.length lines),
      Message_layout.Thinking_summary


let folded_thinking_summary body = fst (folded_thinking_body body)

let tool_projection_mode (state : state) =
  match state.msg_tool_visibility with
  | Tools_compact -> Keeper_chat_transcript.Compact
  | Tools_results | Tools_full -> Keeper_chat_transcript.Full


let is_all_digits s =
  String.length s > 0
  &&
  let rec loop i =
    if i >= String.length s then true
    else if s.[i] >= '0' && s.[i] <= '9' then loop (i + 1)
    else false
  in
  loop 0

;;

let split_last_space s =
  match String.rindex_opt s ' ' with
  | None -> None
  | Some idx ->
    let first = String.sub s 0 idx in
    let second = String.sub s (idx + 1) (String.length s - idx - 1) in
    Some (first, second)

;;

let split_on_middle_dot (s : string) : string list =
  let len = String.length s in
  let rec scan last_pos pos acc =
    if pos + 4 > len then
      List.rev (String.sub s last_pos (len - last_pos) :: acc)
    else if Char.equal s.[pos] ' '
            && Char.equal s.[pos + 1] '\xc2'
            && Char.equal s.[pos + 2] '\xb7'
            && Char.equal s.[pos + 3] ' ' then
      let piece = String.sub s last_pos (pos - last_pos) in
      scan (pos + 4) (pos + 4) (piece :: acc)
    else
      scan last_pos (pos + 1) acc
  in
  scan 0 0 []

;;

let contains_sub s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  if len_sub = 0 then true
  else if len_s < len_sub then false
  else
    let rec check i j =
      if j >= len_sub then true
      else if Char.equal s.[i + j] sub.[j] then check i (j + 1)
      else false
    in
    let rec loop i =
      if i + len_sub > len_s then false
      else if check i 0 then true
      else loop (i + 1)
    in
    loop 0

;;

let extract_tool_marker s =
  let markers = [ "✓"; "✗"; "×"; "√"; Keeper_chat_transcript.received_marker; "▶"; "◌"; "○"; "!"; "?" ] in
  List.find_opt (fun m -> String.starts_with ~prefix:m s) markers

;;

(* The row this dressing sits in opens dim, and a coloured clause used to
   close with a bare [Ansi.reset], snapping the plain text after it -- args,
   counts, the dot between clauses -- back to full foreground. Every close
   reopens the rung the clause sits in, the way {!Chat_theme.body_context}
   closes markdown spans inside a dim body. *)
let tool_reopen = Ansi.reset ^ Ansi.dim

;;

(* SGR 1 does not clear SGR 2: inside the dim row, bold alone would leave a
   failure as faint as the work around it. The bad arms reset before they
   shout -- here and in the [failed] words of [dress_tool_clause] -- and the
   [tool_reopen] closing the clause re-contains the line to the dim rung. *)
let tool_marker_color = function
  | "✓" | "√" -> Theme.ok ()
  | "✗" | "×" | "!" -> Ansi.reset ^ Ansi.bold ^ Theme.bad ()
  | "▶" | "○" | "?" -> Theme.warn ()
  | "↩" | "◌" -> Theme.info ()
  | _ -> tool_reopen

;;

let dress_tool_clause (clause : string) : string =
  let c = String.trim clause in
  match extract_tool_marker c with
  | Some m ->
    let rest =
      String.trim (String.sub c (String.length m) (String.length c - String.length m))
    in
    let col = tool_marker_color m in
    (match String.index_opt rest ' ' with
       | Some idx ->
         let name = String.sub rest 0 idx in
         let args = String.sub rest idx (String.length rest - idx) in
         Printf.sprintf "%s%s%s %s%s%s%s" col m tool_reopen
           (Theme.tool_origin ()) name tool_reopen args
       | None ->
         Printf.sprintf "%s%s%s %s%s%s" col m tool_reopen
           (Theme.tool_origin ()) rest tool_reopen)
  | None ->
    if contains_sub c "detail" && contains_sub c "folded" then
      Printf.sprintf "%s%s%s" (Theme.recede () ^ Ansi.dim) c tool_reopen
    else if String.starts_with ~prefix:"Ctrl-" c || contains_sub c "carried by the transcript" then
      Printf.sprintf "%s%s%s" (Theme.recede () ^ Ansi.dim) c tool_reopen
    else if (String.ends_with ~suffix:"ms" c || String.ends_with ~suffix:"s" c)
            && (match split_last_space c with None -> true | Some (_, _) -> false) then
      Printf.sprintf "%s%s%s" (Theme.recede () ^ Ansi.dim) c tool_reopen
    else if contains_sub c "returned" || contains_sub c "failed"
            || contains_sub c "awaiting" || contains_sub c "running"
            || contains_sub c "result not seen" then
      if contains_sub c ", " then
        let parts = String.split_on_char ',' c in
        let dressed =
          List.map
            (fun p ->
              let p = String.trim p in
              if String.ends_with ~suffix:"returned" p then
                Printf.sprintf "%s%s%s" (Theme.ok ()) p tool_reopen
              else if contains_sub p "failed" then
                Printf.sprintf "%s%s%s" (Ansi.reset ^ Ansi.bold ^ Theme.bad ()) p tool_reopen
              else if contains_sub p "result not seen" then
                Printf.sprintf "%s%s%s" (Theme.warn ()) p tool_reopen
              else if contains_sub p "awaiting" then
                Printf.sprintf "%s%s%s" (Theme.warn ()) p tool_reopen
              else if contains_sub p "running" then
                Printf.sprintf "%s%s%s" (Theme.info ()) p tool_reopen
              else p)
            parts
        in
        String.concat ", " dressed
      else if String.ends_with ~suffix:"returned" c then
        Printf.sprintf "%s%s%s" (Theme.ok ()) c tool_reopen
      else if contains_sub c "failed" then
        Printf.sprintf "%s%s%s" (Ansi.reset ^ Ansi.bold ^ Theme.bad ()) c tool_reopen
      else if contains_sub c "result not seen" then
        Printf.sprintf "%s%s%s" (Theme.warn ()) c tool_reopen
      else if contains_sub c "awaiting" then
        Printf.sprintf "%s%s%s" (Theme.warn ()) c tool_reopen
      else if contains_sub c "running" then
        Printf.sprintf "%s%s%s" (Theme.info ()) c tool_reopen
      else c
    else
      match split_last_space c with
      | Some (name, count) when is_all_digits count ->
        Printf.sprintf "%s%s%s %s%s%s"
          (Theme.tool_origin ()) name tool_reopen
          (Theme.recede () ^ Ansi.dim) count tool_reopen
      | _ -> c

;;

let dress_tool_summary (line : string) : string =
  let parts = split_on_middle_dot line in
  let dressed = List.map dress_tool_clause parts in
  let sep = Printf.sprintf " %s\xc2\xb7%s " (Theme.recede () ^ Ansi.dim) tool_reopen in
  String.concat sep dressed

;;

(* The origin heading under [Origin_row]: who at the left, when at the
   right edge, a rule between. The name is spelt whole on a row that has the
   whole pane; the clock (metadata:full is the mode that shows seconds) sits
   at the right edge, where a chat client's timestamps sit, and the rule
   between them says where a turn's rows begin without spending a colour on
   the heading.

   [plain] is the lead measured, [styled] the same cells dressed; the two
   are kept together by the one caller so the rule is measured against what
   is drawn. A lead wider than the room left of the clock is cut, plain,
   rather than pushing the clock off the row. Cells add up to the frame's
   inner width exactly: the lead, one space and the rule fill the room the
   clock leaves, and the clock takes its cell count plus the space before
   it. *)
(* The bar down the left edge of a line someone else wrote, in the sender's
   colour: solid, where the journal's siding is dotted, so the texture says
   which kind of outside it came from (RFC chat-turn-rail-and-side-lanes
   §4.6). Plain and styled. The space goes before the bar, not after: in the
   inline gutter a name that fills its column would otherwise run into it,
   and the glyph fills only the left quarter of its cell, so the rest of the
   cell already keeps it off the text. *)
let arrival_bar (style : Message_layout.style) =
  match style with
  | Message_layout.Inbound ->
      ( " \xe2\x96\x8e",
        Printf.sprintf " %s\xe2\x96\x8e%s" (Chat_theme.origin style) Ansi.reset )
  | Message_layout.User | Message_layout.Keeper | Message_layout.Status
  | Message_layout.Local | Message_layout.Journal | Message_layout.Error
  | Message_layout.Tool | Message_layout.Skill _ | Message_layout.Thinking ->
      ("", "")

let origin_heading buf cols ~plain ~styled ~clock =
  let inner = framed_inner_width cols in
  let recede = Theme.recede () in
  let clock_cells =
    match clock with
    | None -> 0
    | Some clock -> Message_layout.display_width clock + 1
  in
  let room = max 0 (inner - clock_cells) in
  let lead_cells = Message_layout.display_width plain in
  let lead, lead_cells =
    if lead_cells <= room then styled, lead_cells else fit_width plain room, room
  in
  let rule_cells = room - lead_cells - 1 in
  (* A lead one cell short of the room leaves no cell for a rule but still
     owes the space: without it the row summed to one less than the frame
     and the clock sat a cell left of every other heading's. *)
  let rule =
    if rule_cells >= 1 then
      Printf.sprintf "%s%s%s%s"
        (if String.equal lead "" then "" else " ")
        recede
        (draw_hline (if String.equal lead "" then rule_cells + 1 else rule_cells))
        Ansi.reset
    else if rule_cells = 0 && not (String.equal lead "") then " "
    else ""
  in
  let tail =
    match clock with
    | None -> ""
    | Some clock -> Printf.sprintf " %s%s%s" recede clock Ansi.reset
  in
  box_line buf cols (lead ^ rule ^ tail)

let render_chat_row ~theme ~tool_visibility buf cols (row : Message_layout.row) =
  match row.kind with
  | Message_layout.Viewport_gap { hidden_rows = _ } ->
      (* The glyph survives NO_COLOR; the adaptive recede keeps the separator
         visible without competing with the message above and below it. *)
      box_line_styled buf cols ~style:(Theme.recede ()) row.text
  | Message_layout.Body ->
      (* The two cells reserved by the layout separate the activity column from
         its body. The semantic lead lives with the origin label, so wrapped
         prose starts at one stable column without drawing a rail on every row.
         That rail gave a continuation equal visual weight to a new event and
         made a busy turn look like a table. *)
      let text = row.text in
      let context = Chat_theme.body_context theme row.style in
      let is_tool = match row.style with Message_layout.Tool -> true | _ -> false in
      let dress rest =
        if is_tool && tool_visibility <> Tools_results then
          dress_tool_summary rest
        else
          Masc_tui_message_layout.dress_bare_links
            ~open_style:(Ansi.underline ^ Theme.Syntax.link)
            ~close_style:context.link_restore
            rest
      in
      (* Folded origins are the heading of each activity block. Keep them in
         the role colour and bold while the body stays neutral: after the old
         rail was removed, leaving this whole column dim made every speaker
         and tool block look like continuation metadata. An empty gutter adds
         no bytes at all, so a pane showing origins on their own rows draws
         exactly what it drew before this margin existed. *)
      (* Colour says status, and a row gets one of it. The whole gutter used to
         take the status colour and bold, so an errored turn painted its kind
         label red alongside its glyph and the row carried the same fact twice.
         The glyph keeps the colour -- it is the part that survives NO_COLOR as
         a shape -- and the label recedes into the dimmest step, saying only
         which kind of row this is.

         [gutter_label_at] is the layout's own count of the clock and mark it
         placed; measuring the glyph again here is how the two drift. *)
      let margin =
        if String.equal row.gutter "" then ""
        else
          let restore =
            if context.ambient_background then context.inline_restore
            else Ansi.reset
          in
          let width = Message_layout.display_width row.gutter in
          let at = max 0 (min row.gutter_label_at width) in
          let rail_cells = max 0 (min row.gutter_rail_cells at) in
          (* A plain prefix, not [fit_width]: that one marks an overrun with a
             trailing "…", which here would land in the middle of the gutter.
             Not [split_cells] either -- it wraps, so it hands back one piece
             even at zero cells, and a row that continues the speaker above it
             carries no mark and asks for exactly zero. That drew the clock's
             first digit twice: "222:32" for a row sent at 22:32. *)
          (* The turn rail is structure, not status, so it takes the quiet tone
             rather than the speaker's colour. An errored turn already says so
             on its own glyph; painting the bracket red as well would say it a
             second time, down the side of every row the turn touched. *)
          let rail = Message_layout.take_cells row.gutter rail_cells in
          let after_rail = Message_layout.drop_cells row.gutter rail_cells in
          (* The clock is time-chrome, not identity, so it leaves the mark's
             span and recedes with the rest of the gutter's chrome; the mark
             after it keeps the row's one colour. The layout holds the clock
             inside the span [gutter_label_at] measures, so this clamp only
             restates for the new field what the two above already say. *)
          let clock_cells =
            max 0 (min row.gutter_clock_cells (at - rail_cells))
          in
          let clock = Message_layout.take_cells after_rail clock_cells in
          let after_clock = Message_layout.drop_cells after_rail clock_cells in
          let marked =
            Message_layout.take_cells after_clock
              (at - rail_cells - clock_cells)
          in
          let label =
            Message_layout.drop_cells after_clock
              (at - rail_cells - clock_cells)
          in
          let rail =
            if String.equal rail "" then ""
            else Printf.sprintf "%s%s%s" (Theme.recede ()) rail Ansi.reset
          in
          (* Guarded the way [rail] is: a row with no clock column cuts an
             empty clock, and wrapping emptiness would still spend the escape
             pair on it. *)
          let clock =
            if String.equal clock "" then ""
            else Printf.sprintf "%s%s%s" (Theme.recede ()) clock Ansi.reset
          in
          if String.equal label "" then
            Printf.sprintf "%s%s%s%s%s%s" rail clock
              (Chat_theme.origin row.style) Ansi.bold marked restore
          else
            Printf.sprintf "%s%s%s%s%s%s%s%s%s" rail clock
              (Chat_theme.origin row.style) Ansi.bold marked Ansi.reset
              (Theme.recede ()) label restore
      in
      if
        String.length text >= 2 && Char.equal text.[0] ' '
        && Char.equal text.[1] ' '
      then (
        let rest = String.sub text 2 (String.length text - 2) in
        (* The rail is paid for out of the two spaces that were already there,
           so a quoted block costs no cells and nothing below it shifts. It
           runs the height of the block, which is how a reader sees where the
           quotation ends without reading it.

           [Shade_none] keeps the plain gap. An ambient background is only ever
           the operator's own message, which is prose and never quoted, so the
           rail cannot land inside a span this branch would have to restore. *)
        let rail =
          match row.style, row.shade with
          | Message_layout.Journal, _ ->
              Printf.sprintf "%s┊%s " (Chat_theme.origin row.style) Ansi.reset
          | Message_layout.Inbound, _ -> snd (arrival_bar row.style)
          | _, Message_layout.Shade_none -> "  "
          | _, Message_layout.Shade_quoted ->
              Printf.sprintf "%s\xe2\x94\x82%s " (Theme.recede ()) Ansi.reset
        in
        let body_style = context.opening in
        if context.ambient_background && not is_tool then
          box_line_styled buf cols ~style:context.opening
            (Printf.sprintf "%s  %s" margin (dress rest))
        else
          box_line buf cols
            (Printf.sprintf "%s%s%s%s%s" margin rail
               body_style (dress rest) Ansi.reset))
      else
        (* [rows_of_entry] prefixes every body chunk with the two spaces the guard matches, so this arm stays as a safety net. *)
        box_line_styled buf cols ~style:context.opening (dress text)
  | Message_layout.Metadata Message_layout.Diagnostic ->
      (* The layout puts a diagnostic in its entry's body column and carries
         the turn's rail past it; both are in the gutter. *)
      box_line_styled buf cols ~style:(Theme.recede ()) (row.gutter ^ row.text)
  | Message_layout.Metadata (Message_layout.Timeline_break _) ->
      (* The hour rail is a scrollbar landmark, not content: it stays, but
         recedes instead of holding the pane's brightest slot. *)
      box_line_styled buf cols ~style:(Theme.recede ()) row.text
  | Message_layout.Metadata (Message_layout.Continued_at { clock }) ->
      (* The same speaker, later. Nothing changed at the left, so the row is
         the heading's tail alone: the rule to the clock. *)
      let bar, styled_bar = arrival_bar row.style in
      origin_heading buf cols ~plain:(row.gutter ^ bar)
        ~styled:(row.gutter ^ styled_bar) ~clock:(Some clock)
  | Message_layout.Metadata
      (Message_layout.Origin { clock; speaker; role_label = _ })
    ->
      (* [speaker], not [role_label]: the label was aligned to the gutter's
         column for the inline modes, and this row has the pane. A name the
         gutter cut to "e-m…-leader" is spelled whole here.

         No request id. It groups the rows of a turn, and the rows already
         show that grouping; as text it was an identifier no reader acts on. *)
      let mark = Message_layout.speaker_mark row.style in
      let gap = if String.equal speaker "" then "" else " " in
      (* A heading in an arrival's column starts after the blank run the
         layout put in its gutter; everywhere else the gutter is empty. *)
      let bar, styled_bar = arrival_bar row.style in
      let plain = row.gutter ^ bar ^ mark ^ gap ^ speaker in
      let styled =
        match row.style with
        | Message_layout.Tool | Message_layout.Thinking ->
            Printf.sprintf "%s%s%s" (Theme.recede ()) plain Ansi.reset
        | Message_layout.User | Message_layout.Inbound | Message_layout.Keeper
        | Message_layout.Status | Message_layout.Local | Message_layout.Journal
        | Message_layout.Error | Message_layout.Skill _ ->
            (* The mark keeps its colour and stays out of the badge, the way
               the inline gutter already draws it, so the two origin modes
               agree about what a speaker mark looks like. The reverse span
               covers only the name, and an empty name gets no span. *)
            let badge =
              if String.equal speaker "" then ""
              else Printf.sprintf "%s%s%s" Ansi.reverse speaker Ansi.reset
            in
            (* The mark's colour and weight end at the mark, not at whatever
               follows it: a heading without a name has no badge to end
               them, and the rule after it would draw bold in the speaker's
               colour. *)
            Printf.sprintf "%s%s%s%s%s%s%s%s" row.gutter styled_bar
              (Chat_theme.origin row.style) Ansi.bold mark Ansi.reset gap badge
      in
      origin_heading buf cols ~plain ~styled ~clock


(* What a tool block's row says about state.

   A chat body is sanitized before it is drawn, so no marker inside the text
   can carry a colour; the row's own style is the only channel left. That only
   matters once a block folds: expanded, every call keeps a row and a glyph of
   its own, but folded, six calls sit behind one line where "1 failed" reads
   in the same colour as "5 returned". Live data says how much that hides --
   5,862 of 176,780 recorded calls failed, and three tools fail more often
   than they succeed.

   The projection decides which outcome the fold stands for, on the same
   precedence that picks its glyph, so the mark and the colour agree. A block
   holding a failure is a failure; one still waiting is attention; one that
   returned is the ordinary tool row it was before. *)
let tool_block_style (_projection : Keeper_chat_transcript.tool_projection) =
  Message_layout.Tool

;;

(* The mark says whether the row is still moving. Two states are:
   [Skill_calling] is the read or the run, [Skill_served_pending] is waiting
   on the delivery record. Every other state is a skill's life at rest.

   [Skill_delivered] -- "전달됨, 도구 안 씀" -- was drawn live, so a settled
   history line wore the hollow diamond and read as a turn still working. It
   weighed more after #36870 took the SKILL word off the row and left the
   mark as the only signal of that axis.

   The same line is already drawn elsewhere: [skill_block_state] ranks the
   states "what went wrong, then what is still moving, then how far a
   finished one got", and puts [Skill_delivered] in the finished group. Two
   places said which states are moving and only one of them was right. *)
let skill_tone_of_state :
    Keeper_chat_transcript.skill_state -> Message_layout.skill_tone = function
  | Keeper_chat_transcript.Skill_calling
  | Keeper_chat_transcript.Skill_served_pending -> Message_layout.Skill_live
  (* Delivered and used are the two ends of one life, and both are reached.
     Which one it is, the row spells in words; the mark says the life is
     over. [Skill_served_only] is finished too, but without the delivery
     record it should have, and that is what the attention mark is for. *)
  | Keeper_chat_transcript.Skill_delivered
  | Keeper_chat_transcript.Skill_used -> Message_layout.Skill_settled
  | Keeper_chat_transcript.Skill_served_only
  | Keeper_chat_transcript.Skill_evidence_missing -> Message_layout.Skill_attention
  | Keeper_chat_transcript.Skill_failed
  | Keeper_chat_transcript.Skill_evidence_unavailable -> Message_layout.Skill_failure


(* [None] is a roster that was not read, not a health the roster could not
   name: the word says so, and it is the word the header's tally uses for
   the same keepers, so a column of ten of them and "10 unread" above it
   are one fact drawn twice rather than two. *)
let keeper_health_word (health : Tui_decode.keeper_health option) =
  match health with
  | None -> "unread"
  | Some value -> Tui_decode.keeper_health_to_string value


let keeper_message_identity ~max_cells state keeper_name =
  let fit_identity text =
    if Message_layout.display_width text <= max_cells then text
    else fit_width text max_cells
  in
  match
    List.find_opt
      (fun (keeper : keeper) -> String.equal keeper.k_name keeper_name)
      state.keepers
  with
  | None ->
      fit_identity
        (Ansi.dim ^ "\xc3\x97 unavailable \xc2\xb7 \xe2\x80\x94" ^ Ansi.reset)
  | Some keeper ->
      let reading = keeper_reading state keeper in
      let health = Keeper_control.health reading in
      let runtime =
        match reading.Keeper_control.liveness with
        | Keeper_control.Present row -> Some row
        | Keeper_control.Absent | Keeper_control.Unobserved | Keeper_control.Invalid _ -> None
      in
      let status_color =
        keeper_action_color (Keeper_control.next_action reading)
      in
      (* Two stances that decide what this Keeper does with a tool call, on
         the row an operator reads before typing to it. Show defaults too:
         this is operational state, and an absent label made AUTO look like
         unknown while a visible YOLO label looked like the only real mode. *)
      let stance =
        let yolo = List.mem keeper.k_name state.keeper_yolo_names in
        let workspace_gate_mode =
          Option.map
            (fun modes -> modes.Tui_decode.glm_workspace)
            state.gate_modes
        in
        let chat_mode, gate_mode =
          keeper_chat_mode_labels ~yolo
            ~keeper_gate_mode:(List.assoc_opt keeper.k_name state.keeper_gate_modes)
            ~workspace_gate_mode
        in
        (* "gate: " with the space every other label on this header uses.
           Written tight, the stance ran into its value -- "gate:Auto Judge"
           -- beside "configured: <runtime>" on the same row. *)
        Printf.sprintf " %s%s%s %s\xc2\xb7 gate: %s%s"
          (if yolo then (Theme.bad ()) else (Theme.info ()))
          chat_mode Ansi.reset Ansi.dim
          (* Nothing observed is said in the words every other surface uses
             for it. "?" beside a stance that decides what a send can do left
             the reader to guess whether it meant manual or unread. *)
          (match gate_mode with
           | Some word -> Terminal_text.single_line word
           | None -> Masc_tui_types.field_unread)
          Ansi.reset
      in
      let status =
        String.concat ""
          [ status_color
          ; keeper_state_glyph ~paused:reading.Keeper_control.paused ~health
          ; " "
          ; keeper_health_word health
          ; Ansi.reset
          ; stance
          ]
      in
      (match runtime with
       | None ->
           let detail = match keeper.k_origin with
             | Tui_decode.Declared_keeper requirements ->
               "아직 시작하지 않음 · " ^ String.concat " · "
                 (List.map Masc.Keeper_declared_roster.requirement_label requirements)
             | Persisted_keeper | Remote_keeper -> status ^ " · —"
           in
           fit_identity (Ansi.dim ^ detail ^ Ansi.reset)
       | Some row ->
           let runtime_id =
             Keeper_chat_transcript.runtime_identity_text ~keeper_name
               ~configured_runtime:row.kr_runtime_id
               (Option.map (fun live -> live.tl_transcript) state.msg_live)
           in
           (* The phase and the runtime are two facts, and the runtime label
              starts with a word of its own ("configured:", "turn:"). Set side
              by side with only a space, they read as one phrase -- the header
              said "paused configured: anthropic.claude-sonnet-4", which names
              no state a person can act on. The separator the rest of the row
              uses keeps them apart. *)
           let prefix =
             Printf.sprintf "%s%s \xc2\xb7 %s \xc2\xb7 " status Ansi.dim
               (Tui_decode.keeper_phase_to_string row.kr_phase)
           in
           (* What the answer now streaming has spent and why the provider
              stopped writing, in the same clause shape as the rest of the
              row. It is an addition to this row, never a claim on it: it is
              drawn whole or not at all, so it can neither cut the runtime id
              nor arrive as a half-written number that reads as a smaller bill
              than the real one, nor as a stop reason cut down to another
              word. A row with room for the counters but not for both keeps
              the counters: the newer fact must not take away the one the
              screen was already showing. *)
           let transcript =
             Option.map (fun live -> live.tl_transcript) state.msg_live
           in
           let prefix_width = Message_layout.display_width prefix in
           if prefix_width >= max_cells then
             fit_width (prefix ^ runtime_id ^ Ansi.reset) max_cells
           else
             let room = max_cells - prefix_width in
             let id_width = Message_layout.display_width runtime_id in
             (match
                Keeper_chat_transcript.stream_details_within ~keeper_name
                  ~room:(room - id_width) transcript
              with
              | Some clause -> prefix ^ runtime_id ^ clause ^ Ansi.reset
              | None -> prefix ^ fit_runtime_id room runtime_id ^ Ansi.reset))


(** Render message input/conversation view *)
let keeper_message_clock at =
  let time = Unix.localtime at in
  Printf.sprintf "%02d:%02d:%02d" time.Unix.tm_hour time.Unix.tm_min
    time.Unix.tm_sec

;;

let keeper_message_timeline_bucket at =
  let time = Unix.localtime at in
  ({ tb_year = time.Unix.tm_year + 1900;
     tb_month = time.Unix.tm_mon + 1;
     tb_day = time.Unix.tm_mday;
     tb_hour = time.Unix.tm_hour;
     tb_is_dst = time.Unix.tm_isdst;
   }
    : Message_layout.timeline_bucket)

;;

type keeper_call_association =
  | Call_log_not_loaded
  | Call_log_loading
  | Call_log_unavailable of string
  | Call_execution_unrecorded
  | Call_execution_missing
  | Call_execution_coverage_gap of string
  | Call_execution_ambiguous of int
  | Call_execution_exact of Tui_decode.keeper_call

let keeper_call_association state ~keeper_name
    (activity : Keeper_chat_transcript.tool_activity) =
  match activity.execution_id with
  | None -> Call_execution_unrecorded
  | Some execution_id -> (
      if
        not
          (Option.equal String.equal state.keeper_calls_keeper
             (Some keeper_name))
      then Call_log_not_loaded
      (* Refresh keeps the last snapshot for this Keeper. Replacing it with
         a loading row drops every expanded output, changing the transcript's
         height twice per poll and moving the reader's viewport. Only the
         first read has no durable detail to draw yet. *)
      else if state.keeper_calls_loading && Option.is_none state.keeper_calls
      then Call_log_loading
      else
      match state.keeper_calls_error, state.keeper_calls with
      | Some detail, None -> Call_log_unavailable detail
      | None, None -> Call_log_not_loaded
      | _, Some snapshot
        when not (String.equal snapshot.Tui_decode.kcs_keeper keeper_name) ->
          Call_log_not_loaded
      | _, Some snapshot ->
          let matches =
            List.filter
              (fun (call : Tui_decode.keeper_call) ->
                Option.equal String.equal call.kc_execution_id
                  (Some execution_id))
              snapshot.kcs_entries
          in
          match matches with
          | [] ->
              (match state.keeper_calls_error with
               | Some detail -> Call_log_unavailable detail
               | None when snapshot.Tui_decode.kcs_mismatched > 0 ->
                   (* Filtered foreign rows never join. One of them may carry
                      the queried execution id, so a nonzero mismatch count
                      means this absence is unproven even when health says ok. *)
                   Call_execution_coverage_gap
                     (Printf.sprintf "%d row(s) named another keeper and were not drawn"
                        snapshot.Tui_decode.kcs_mismatched)
               | None -> (
                   (* No match is only proof of absence against a log known
                      complete: [ok], or [empty]/[missing] with nothing in it.
                      Any other verdict -- a coverage gap, a stale read, a word
                      this build does not know -- means the row may exist past
                      what the snapshot covers, so the association says the log
                      is incomplete instead of the row missing. *)
                   match snapshot.Tui_decode.kcs_health with
                   | Tui_decode.Call_log_ok -> Call_execution_missing
                   | (Tui_decode.Call_log_empty | Tui_decode.Call_log_missing)
                     when snapshot.Tui_decode.kcs_entries = [] ->
                       Call_execution_missing
                   | (Tui_decode.Call_log_empty | Tui_decode.Call_log_missing
                     | Tui_decode.Call_log_stale
                     | Tui_decode.Call_log_coverage_gap
                     | Tui_decode.Call_log_unknown _) as health ->
                       let reason =
                         match snapshot.Tui_decode.kcs_stale_reason with
                         | Some reason -> reason
                         | None ->
                             Tui_decode.keeper_call_log_health_to_string health
                       in
                       Call_execution_coverage_gap reason))
          | [ call ] -> Call_execution_exact call
          | rows -> Call_execution_ambiguous (List.length rows))


(* The tool tree's colours, out of the reader's own theme. Built per draw
   rather than held: the palette behind [Theme.*] is resolved against the
   terminal's answers and can change, and a cached record would keep drawing
   the colours the last answer produced. *)
(* How much of a served input or output the full calls draw before folding
   the rest. Enough to say what the payload is -- a member list, the head of
   a table -- on a pane that draws about twenty rows; a whole result runs to
   hundreds, and the Keeper Calls view is where it is read whole. *)
let tool_document_rows_shown = 8

let tool_detail_palette () : Tool_detail.palette =
  { Tool_detail.branch = Theme.recede ()
    (* A field's name and a document member's name are the same kind of
       thing, so they read in the same colour; the weight is what separates
       the tree's own labels from the names inside a payload. *)
  ; label = Ansi.bold ^ Masc_tui_theme.tone Masc_tui_theme.Accent
  ; separator = Theme.recede ()
  ; key = Masc_tui_theme.Syntax.json_key
  ; string_ = Masc_tui_theme.Syntax.string_
  ; number = Masc_tui_theme.Syntax.json_number
  ; literal = Masc_tui_theme.Syntax.json_literal
  ; punctuation = Masc_tui_theme.Syntax.json_punctuation
  ; note = Theme.recede ()
    (* The pane opens these rows dim; a bare reset after the first painted
       span would drop every following byte back to full weight. Close the
       way the markdown palette closes: reset, then reopen the rung the tree
       sits in. *)
  ; reset = Ansi.reset ^ Ansi.dim
  }


(* An outcome is a reading of state, so it draws through the status names
   rather than through the tree's own default. The two that are still moving
   read as attention; the two that stopped badly read as failure. *)
let tool_outcome_tone : Keeper_chat_transcript.tool_outcome -> string = function
  | Keeper_chat_transcript.Started | Keeper_chat_transcript.Native_running
  | Keeper_chat_transcript.Awaiting_result ->
      Theme.info ()
  | Keeper_chat_transcript.Returned -> Theme.ok ()
  | Keeper_chat_transcript.Native_ended -> Theme.recede ()
  | Keeper_chat_transcript.Failed -> Theme.bad ()
  | Keeper_chat_transcript.Never_returned
  | Keeper_chat_transcript.Outcome_unrecorded -> Theme.warn ()


let tool_outcome_label : Keeper_chat_transcript.tool_outcome -> string = function
  | Keeper_chat_transcript.Started -> "PREPARING · ARGUMENTS STREAMING"
  | Keeper_chat_transcript.Awaiting_result -> "WAITING FOR RESULT"
  | Keeper_chat_transcript.Returned -> "RETURNED"
  | Keeper_chat_transcript.Native_running -> "NATIVE STEP RUNNING"
  | Keeper_chat_transcript.Native_ended -> "NATIVE STEP ENDED · OUTCOME NOT REPORTED"
  | Keeper_chat_transcript.Failed -> "FAILED"
  | Keeper_chat_transcript.Never_returned -> "RESULT NOT SEEN HERE"
  | Keeper_chat_transcript.Outcome_unrecorded -> "OUTCOME UNRECORDED"


let durable_call_failed = function
  | Call_execution_exact call ->
      call.kc_outcome = Tool_result.Recorded_failed
      || call.kc_disposition = Some Tui_decode.Keeper_call_failed
  | Call_log_not_loaded | Call_log_loading | Call_log_unavailable _
  | Call_execution_unrecorded | Call_execution_missing
  | Call_execution_coverage_gap _ | Call_execution_ambiguous _ -> false


let tool_outcome_label_with_call outcome association =
  if durable_call_failed association then "FAILED · CALL LOG"
  else match outcome, association with
  | Keeper_chat_transcript.Never_returned, Call_execution_exact call
    when Option.is_some call.kc_output ->
      "RESULT IN CALL LOG · NOT SEEN IN TURN"
  | _ -> tool_outcome_label outcome


let tool_outcome_tone_with_call outcome association =
  if durable_call_failed association then Theme.bad ()
  else tool_outcome_tone outcome


let keeper_call_schedule_label (schedule : Tui_decode.keeper_call_schedule) =
  let execution =
    match schedule.kcs_execution_mode with
    | Tui_decode.Keeper_call_serial -> "serial"
    | Tui_decode.Keeper_call_concurrent -> "concurrent"
  in
  Printf.sprintf "%s · batch %d · width %d · plan step %d" execution
    (schedule.kcs_batch_index + 1) schedule.kcs_batch_size
    (schedule.kcs_planned_index + 1)


(* What the full calls draw for a recorded result: an Execute result read into
   its parts, or any result as it arrived. *)
type tool_output =
  | Execute_output of Masc_tui_execute_result.t
  | Served_output of string

let keeper_message_tool_activity_details state ~keeper_name
    (activity : Keeper_chat_transcript.tool_activity) =
  let association = keeper_call_association state ~keeper_name activity in
  let schedule_field, disposition_field, durable_input, output_field,
      result_field =
    match association with
    | Call_execution_exact call ->
        let schedule =
          match call.kc_schedule with
          | Some schedule -> keeper_call_schedule_label schedule
          | None -> "not recorded"
        in
        (* An Execute result read against the schema its descriptor
           declares, so the pane can lead with how the command ended and
           what it printed. Any other tool, or a result that does not read,
           is drawn as it arrived. *)
        let output =
          match call.kc_output with
          | None -> None
          | Some value -> (
              let execute =
                match Keeper_chat_transcript.descriptor_of_tool_name activity.tool_name with
                | Some descriptor
                  when descriptor.runtime_handler = Masc.Keeper_tool_descriptor.Tool_execute ->
                    Masc_tui_execute_result.of_result value
                | Some _ | None -> None
              in
              match execute with
              | Some result -> Some (Execute_output result)
              | None -> Some (Served_output value))
        in
        let disposition =
          match call.kc_disposition with
          | None -> None
          | Some Tui_decode.Keeper_call_completed ->
              Some ("dispatch", "COMPLETED · SYNCHRONOUS", Theme.ok ())
          | Some Tui_decode.Keeper_call_deferred ->
              Some ("dispatch", "DEFERRED · ASYNC CONTINUATION", Theme.info ())
          | Some Tui_decode.Keeper_call_failed ->
              Some ("dispatch", "FAILED", Theme.bad ())
        in
        let result =
          match call.kc_result_bytes, call.kc_truncated_to with
          | None, None -> None
          | result_bytes, truncated_to ->
              let parts =
                List.filter_map Fun.id
                  [ Option.map (Printf.sprintf "%d bytes") result_bytes
                  ; Option.map (Printf.sprintf "served through %d bytes")
                      truncated_to
                  ]
              in
              Some ("result", String.concat " · " parts)
        in
        (schedule, disposition, call.kc_input, output, result)
    | Call_log_not_loaded ->
        "open full calls to load durable schedule", None, activity.args, None,
        None
    | Call_log_loading ->
        "loading durable schedule…", None, activity.args, None, None
    | Call_log_unavailable detail ->
        "unavailable · " ^ detail, None, activity.args, None, None
    | Call_execution_unrecorded ->
        "execution id not recorded", None, activity.args, None, None
    | Call_execution_missing ->
        "no durable row for this execution id", None, activity.args, None, None
    | Call_execution_coverage_gap reason ->
        "call log incomplete · " ^ Terminal_text.single_line reason,
        None, activity.args, None, None
    | Call_execution_ambiguous count ->
        Printf.sprintf "%d durable rows share this execution id" count,
        None, activity.args, None, None
  in
  let provider_call_id =
    match association with
    | Call_execution_exact call ->
        (match call.kc_tool_use_id with
         | Some _ as recorded -> recorded
         | None -> activity.call_id)
    | Call_log_not_loaded | Call_log_loading | Call_log_unavailable _
    | Call_execution_unrecorded | Call_execution_missing
    | Call_execution_coverage_gap _ | Call_execution_ambiguous _ ->
        activity.call_id
  in
  let identity =
    List.filter_map Fun.id
      [ Option.map (fun value -> "execution=" ^ value) activity.execution_id
      ; Option.map (fun value -> "provider-call=" ^ value) provider_call_id
      ]
    |> function
    | [] -> "not recorded"
    | parts -> String.concat " · " parts
  in
  (* Which fields are readings of state and which are payloads, said once
     here. The tree draws a payload through the document roles and a reading
     through the tone this names; nothing downstream guesses from the label. *)
  let said label value tone =
    { Tool_detail.fd_label = label
    ; fd_value = Tool_detail.Text value
    ; fd_tone = tone
    }
  in
  let served label value =
    { Tool_detail.fd_label = label
    ; fd_value = Tool_detail.Document value
    ; fd_tone = ""
    }
  in
  let fields =
    [ Some
        (said "state"
           (tool_outcome_label_with_call activity.outcome association)
           (tool_outcome_tone_with_call activity.outcome association))
    ; Option.map
        (fun (label, value, tone) -> said label value tone)
        disposition_field
      (* The tool's own name, in the colour the pane already gives a tool
         row's origin. Not a status: naming Execute is not a verdict on it. *)
    ; Some (said "tool" activity.tool_name (Theme.tool_origin ()))
    ; Some (said "schedule" schedule_field "")
    ; Some
        (if String.equal durable_input "" then said "input" "(empty)" ""
         else served "input" durable_input)
    ]
    @ (match output_field with
       | None -> []
       | Some (Served_output value) -> [ Some (served "output" value) ]
       | Some (Execute_output result) ->
           [ Some
               (said "status"
                  (Masc_tui_execute_result.status_text result)
                  (if result.ok then Theme.ok () else Theme.bad ()))
           ; Option.map
               (function
                 | Masc_tui_execute_result.Printed "" -> said "output" "(empty)" ""
                 | Masc_tui_execute_result.Printed output -> served "output" output
                 | Masc_tui_execute_result.Stored reference ->
                     said "output" (Masc_tui_execute_result.stored_text reference) "")
               result.output
           ])
    @ [ Option.map (fun (label, value) -> said label value "") result_field
      ; Some (said "identity" identity "")
      ]
    |> List.filter_map Fun.id
  in
  Tool_detail.tree ~palette:(tool_detail_palette ())
    ~fold:
      { Tool_detail.fold_rows = tool_document_rows_shown
      ; fold_note =
          (fun hidden ->
            Printf.sprintf "\xe2\x80\xa6 +%d lines \xc2\xb7 Keeper Calls (%s)" hidden
              Masc_tui_keys.keeper_calls_key)
      }
    fields


(* How one finished turn's tool block becomes rows: the operator's
   compact/full choice, the width the aligned badge leaves, and this keeper's
   own file changes. The committed history and the turn still streaming both
   ask this, so a diff folded into the history and the same diff arriving live
   cannot be projected two ways. *)
(* One step. Deep enough that a call reads as belonging to the rollup above
   it, shallow enough that a block of eight calls does not walk off the pane
   on a narrow terminal. *)
let tool_detail_indent = "  "


(* How wide one body line runs. Floored so a narrow pane still shows
   something and capped so a wide one does not run a sentence past where the
   eye returns; the eight is the gutter and the space that follows it.

   Shared by everything that has to decide what fits on a line, because two
   readers with two budgets wrap the same pane at two places. *)
let chat_body_line_cells ~chat_cols ~role_label_column =
  max 24 (min 120 (chat_cols - role_label_column - 8))


let clip_tool_result ~max_cells text =
  let text = Masc_tui_keeper_chat_projection.terminal_safe_text text |> String.trim in
  if Message_layout.display_width text <= max_cells then text
  else
    match Message_layout.split_cells ~max_cells:(max 1 (max_cells - 1)) text with
    | [] -> "…"
    | prefix :: _ -> prefix ^ "…"


let tool_result_preview ~failed (activity : Keeper_chat_transcript.tool_activity) value =
  match Keeper_chat_transcript.descriptor_of_tool_name activity.Keeper_chat_transcript.tool_name with
  | Some descriptor
    when descriptor.runtime_handler = Masc.Keeper_tool_descriptor.Tool_execute ->
      (match Masc_tui_execute_result.of_result value with
       | Some result ->
           let output =
             match result.output with
             | Some (Masc_tui_execute_result.Printed text) -> text
             | Some (Masc_tui_execute_result.Stored reference) ->
                 Masc_tui_execute_result.stored_text reference
             | None -> ""
           in
           String.concat " · "
             (List.filter (fun text -> String.trim text <> "")
                [ Masc_tui_execute_result.status_text result; output ])
       | None -> value)
  | Some _ | None ->
      Masc_tui_browser_rejection.preview ~failed
        ~lacking:(fun transport capability ->
          Browser_lane_view.lacking_clause transport [capability])
        value


let tool_result_rows state ~keeper_name ~max_cells projection =
  let rows =
    List.concat_map
      (fun (activity : Keeper_chat_transcript.tool_activity) ->
        let association = keeper_call_association state ~keeper_name activity in
        (* Exact durable failure wins over a transcript that has not been
           enriched yet. Receipt otherwise makes no success claim. *)
        let durable_failure = durable_call_failed association in
        let marker, status =
          if durable_failure then
            Keeper_chat_transcript.marker_of_outcome Keeper_chat_transcript.Failed,
            "failed"
          else
            match activity.outcome, association with
            | ( Keeper_chat_transcript.Never_returned
              | Keeper_chat_transcript.Started
              | Keeper_chat_transcript.Awaiting_result )
              , Call_execution_exact call
              when Option.is_some call.kc_output ->
                (* A recorded output is already evidence, even when the
                   transcript has not folded its completion event yet. *)
                Keeper_chat_transcript.received_marker, "in call log"
            | Keeper_chat_transcript.Returned, _ ->
                Keeper_chat_transcript.received_marker, "received"
            | outcome, _ ->
                Keeper_chat_transcript.marker_of_outcome outcome,
                (match outcome with
                 | Keeper_chat_transcript.Started -> "starting"
                 | Keeper_chat_transcript.Awaiting_result -> "waiting"
                 | Keeper_chat_transcript.Failed -> "failed"
                 | Keeper_chat_transcript.Never_returned -> "not seen"
                 | Keeper_chat_transcript.Outcome_unrecorded -> "unknown"
                 | Keeper_chat_transcript.Native_running -> "native running"
                 | Keeper_chat_transcript.Native_ended -> "native ended"
                 | Keeper_chat_transcript.Returned -> "received")
        in
        let fixed_cells = Message_layout.display_width (marker ^ "  · " ^ status) in
        let detail_on_next_line = max_cells < 80 in
        let name_cells =
          max 4
            (min 48
               (max_cells - fixed_cells
                - (if detail_on_next_line then 0 else 12)))
        in
        let name = clip_tool_result ~max_cells:name_cells activity.tool_name in
        let prefix = Printf.sprintf "%s %s · %s" marker name status in
        let preview, unavailable =
          match association with
          | Call_execution_exact call ->
              let failed =
                durable_failure || activity.outcome = Keeper_chat_transcript.Failed in
              Option.map (tool_result_preview ~failed activity) call.kc_output,
              "result text not recorded"
          | Call_log_not_loaded -> None, "result preview not loaded"
          | Call_log_loading -> None, "loading result preview"
          | Call_log_unavailable _ -> None, "result preview unavailable"
          | Call_execution_unrecorded -> None, "no execution id"
          | Call_execution_missing -> None, "no call-log row"
          | Call_execution_coverage_gap _ -> None, "call log incomplete"
          | Call_execution_ambiguous _ -> None, "duplicate execution id"
        in
        let detail =
          match preview with
          | Some value when String.trim value <> "" -> Some value
          | Some _ -> Some "(empty result)"
          | None ->
              (match activity.outcome with
               | Keeper_chat_transcript.Native_ended -> Some "provider step ended; outcome not reported"
               | Keeper_chat_transcript.Native_running -> None
               | Keeper_chat_transcript.Started
               | Keeper_chat_transcript.Awaiting_result -> None
               | Keeper_chat_transcript.Returned
               | Keeper_chat_transcript.Failed
               | Keeper_chat_transcript.Never_returned
               | Keeper_chat_transcript.Outcome_unrecorded ->
                   Some unavailable)
        in
        (* Only generated status text is dressed. Payload stays terminal-safe
           plain text, including words or glyphs that resemble a failure. *)
        let prefix = clip_tool_result ~max_cells prefix in
        let styled_prefix = dress_tool_summary prefix in
        match detail with
        | None -> [styled_prefix]
        | Some detail when detail_on_next_line ->
            [ styled_prefix
            ; "  " ^ clip_tool_result ~max_cells:(max_cells - 2) detail
            ]
        | Some detail ->
            let room = max_cells - Message_layout.display_width prefix - 3 in
            [styled_prefix ^ " · " ^ clip_tool_result ~max_cells:room detail])
      projection.Keeper_chat_transcript.activities
  in
  if projection.omitted_steps = 0 then rows
  else rows @ [Printf.sprintf "(%d tool steps omitted from transcript)" projection.omitted_steps]


(* One reading of a Gate row's fold, for the two questions that need it: what
   the row draws, and whether pressing it opens anything. Folded twice, the
   text could say it is holding something on a frame where the press says it
   is not. *)
let gate_fold ~chat_cols ~role_label_column (message : Masc_tui_types.msg_entry)
    =
  Masc_tui_gate_text.fold_argument
    ~cap:(chat_body_line_cells ~chat_cols ~role_label_column)
    message.me_text


let keeper_message_tool_rows (state : state) ~keeper_name ~chat_cols projection =
  let role_label_column =
    Message_layout.chat_role_label_width ~pane_cells:chat_cols
  in
  let file_change_index =
    if Option.equal String.equal state.msg_file_changes_keeper (Some keeper_name)
    then state.msg_file_change_index
    else Keeper_chat_diff.empty
  in
  let mode = tool_projection_mode state in
  let max_line_cells = chat_body_line_cells ~chat_cols ~role_label_column in
  let rows =
    match state.msg_tool_visibility with
    | Tools_results ->
        tool_result_rows state ~keeper_name ~max_cells:max_line_cells projection
    | Tools_compact | Tools_full ->
        Keeper_chat_diff.rows ~mode ~max_line_cells
          ~activity_details:(keeper_message_tool_activity_details state ~keeper_name)
          file_change_index projection
  in
  (* The fold says how many rows it is holding; the key that opens them is in
     the footer, on every frame, next to the other five. Repeating it on the
     row cost thirty-eight cells of the widest line in the pane, and a screen
     with four tool blocks carried the same sentence four times -- which is
     what pushed the tool names onto a second line and broke the read of the
     conversation they sit inside. *)
  match state.msg_tool_visibility, projection.Keeper_chat_transcript.header with
  | Tools_results, _ | _, None -> rows
  | (Tools_compact | Tools_full), Some header ->
      (* The rollup is the block's first line and the calls hang under it,
         one step in. The projection knows which line is the header; how far
         the calls sit from it is this pane's decision, so the indent is
         applied here rather than baked into the strings upstream. *)
      header :: List.map (fun row -> tool_detail_indent ^ row) rows


(* Every committed row of one keeper's conversation, as the layout entries the
   pane draws -- the grouping, the aligned badges, the tool projections, and
   the link labels appended under each body.

   Lifted out of [render_keeper_message] so it has a second reader. A search
   over this conversation has to land the pane on a row, and a row position
   here is measured in the physical rows these entries render to; anything
   that computed it from the message list alone would be measuring a different
   document from the one on screen. The renderer never mutates state, so the
   search cannot live inside it either.

   Committed rows only. The turn still streaming is built where it is drawn:
   its row count changes on every frame, which is exactly what a stable
   position must not be measured against. *)
(* The timeline moments of one row list, computed once per list.

   [chat_projected_timeline_ats] walks the whole list with a floor per
   request id, and the chat frame asked for it twice per frame on the same
   rows: once to draw and once through [keeper_message_layout_entries]. The
   rows come from [chat_rows_for], which returns the same list until the
   conversation changes, so the list's physical identity is the key. A list
   built elsewhere (a search over a slice) replaces the slot and the next
   frame computes once more; nothing is kept stale. *)
let chat_timeline_ats_memo :
    (Masc_tui_types.msg_entry list
    * (Masc_tui_types.msg_entry * float option) list)
    option
    ref =
  ref None


let chat_rows_with_timeline_ats messages =
  match !chat_timeline_ats_memo with
  | Some (key, combined) when key == messages -> combined
  | Some _ | None ->
      let combined =
        List.combine messages (chat_projected_timeline_ats messages)
      in
      chat_timeline_ats_memo := Some (messages, combined);
      combined


(* The visibility-filtered timeline of one row list, computed once per list
   and visibility pair.

   The chat frame asks for this twice on the same inputs: once to place the
   live turn and once through [keeper_message_layout_entries]. The filter
   walks every committed row on every key, and its answer depends only on the
   row list -- replaced, not mutated, when the conversation changes -- and the
   memory, reasoning, and tool visibility readings. Full tool detail restores
   the raw Gate lifecycle, so its toggle also invalidates this reading. Same scoping as
   [chat_timeline_ats_memo] above: a frame with different rows or a toggled
   visibility replaces the slot, and nothing is kept stale. *)
type visible_timeline_memo = {
  vtm_messages : msg_entry list;
  vtm_memory : memory_visibility;
  vtm_reasoning : reasoning_visibility;
  vtm_tools : tool_visibility;
  vtm_timeline : (msg_entry * float option) list;
}

let visible_timeline_memo : visible_timeline_memo option ref = ref None


let keeper_message_visible_timeline ?messages (state : state) ~keeper_name =
  let messages =
    match messages with
    | Some messages -> messages
    | None -> chat_rows_for state keeper_name
  in
  match !visible_timeline_memo with
  | Some memo
    when memo.vtm_messages == messages
         && memo.vtm_memory = state.msg_memory_visibility
         && memo.vtm_reasoning = state.msg_reasoning_visibility
         && memo.vtm_tools = state.msg_tool_visibility ->
      memo.vtm_timeline
  | Some _ | None ->
      let timeline =
        chat_rows_with_timeline_ats messages
        |> List.filter (fun (message, _) ->
          state.msg_memory_visibility <> Memory_hidden
          || message.me_role <> Message_memory)
        |> List.filter (fun (message, _) ->
          message.me_role <> Message_thinking
          || Masc_tui_types.reasoning_drawn state.msg_reasoning_visibility)
        |> Masc_tui_types.project_memory_history
             ~visibility:state.msg_memory_visibility
        |> Masc_tui_types.project_gate_history ~visibility:state.msg_tool_visibility
      in
      visible_timeline_memo :=
        Some
          { vtm_messages = messages;
            vtm_memory = state.msg_memory_visibility;
            vtm_reasoning = state.msg_reasoning_visibility;
            vtm_tools = state.msg_tool_visibility;
            vtm_timeline = timeline;
          };
      timeline

;;

(* Which piece of its turn's bracket a row draws.

   A lone row of speech draws nothing. One thing said is not a hierarchy, and
   marking it would put a rail on nearly every row of ordinary chatter, which
   is where a reader stops seeing it at all.

   A lone row of work draws its own stub rather than the branch a running turn
   uses. Drawn as that branch, a run of them read as one turn's several
   branches: four consecutive autonomous wakes came out as four twigs off a
   trunk that was not there, and the boundary between the turns disappeared.

   The split between speech and work is the fact the pane was missing.
   Reasoning, tool calls and skills are what a turn did to arrive at what it
   said, and they were drawn at the same depth as the answer -- same column,
   same indent, same clock -- so a turn's work read as a sibling of its speech.
   They hang off the trunk instead. *)
(* Which siding a row came in on, or [None] when it is not an arrival.

   Exhaustive on purpose: a new row kind has to say whether it arrived from
   outside, and the compiler is the only thing that will ask.

   [Sent_by_operator] is not here. A prompt the operator sent from another
   surface did arrive from outside, but which surface is in the label's text
   and not in the constructor, and reading it back out of the string is the
   pane deciding something the type never recorded. *)
let siding_of_message (message : Masc_tui_types.msg_entry) =
  match message.me_role with
  | Masc_tui_types.Message_memory -> Some Message_layout.Siding_journal
  | Masc_tui_types.Message_user (Masc_tui_types.Sent_by_other _) ->
      Some Message_layout.Siding_arrival
  | Masc_tui_types.Message_user (Masc_tui_types.Sent_by_operator _)
  | Masc_tui_types.Message_keeper | Masc_tui_types.Message_autonomous
  | Masc_tui_types.Message_status | Masc_tui_types.Message_local
  | Masc_tui_types.Message_error | Masc_tui_types.Message_tool
  | Masc_tui_types.Message_skill _ | Masc_tui_types.Message_thinking ->
      None


(* [siding] only reaches the rail through [Turn_outside]: a row that owns a
   request is on the line whoever sent it, and a broadcast that opened a turn
   is that turn's first row rather than something beside it. *)
let turn_rail_of ~siding ~(edge : Masc_tui_types.turn_edge)
    ~(style : Message_layout.style) =
  match edge with
  | Turn_outside -> (
      match siding with
      | Some siding -> Message_layout.Rail_joins siding
      | None -> Message_layout.Rail_none)
  (* A turn of one row still divides into speech and work. It read as neither
     while an autonomous turn also wrote an empty reply -- two rows, so the
     turn drew a bracket -- and once that row stopped being drawn (#33692) the
     common autonomous turn became a single tool block with nothing marking it
     as work at all. *)
  | Turn_alone ->
      Message_layout.rail_for_style ~work:Message_layout.Rail_stands
        ~speech:Message_layout.Rail_none style
  | Turn_opens -> Message_layout.Rail_opens
  | Turn_closes -> Message_layout.Rail_closes
  | Turn_continues ->
      Message_layout.rail_for_style ~work:Message_layout.Rail_does
        ~speech:Message_layout.Rail_says style


module Request_owners = Map.Make (String)

let request_owner owners request_id =
  Option.value (Request_owners.find_opt request_id owners) ~default:request_id

let request_diagnostics ~tools ~request_id ~execution_id =
  match tools with
  | Tools_compact | Tools_results -> []
  | Tools_full when String.equal request_id "" -> []
  | Tools_full ->
      let safe = Keeper_chat.terminal_safe_text in
      ["request " ^ safe request_id]
      @ if String.equal request_id execution_id then []
        else ["execution " ^ safe execution_id]

let committed_request_diagnostics ~tools ~request_id ~execution_id ~edge =
  match edge with
  | Turn_opens | Turn_alone | Turn_outside ->
      request_diagnostics ~tools ~request_id ~execution_id
  | Turn_continues | Turn_closes -> []

let chat_request_owners (state : state) ~keeper_name =
  (* All watchers retain their validated request-to-execution binding, even
     when the selected journal has no visible output. Self identities add no
     alias and cannot overwrite a sibling's confirmed binding. *)
  state.msg_settled_logs
  @ List.map (fun (entry : Masc_tui_types.inflight) -> entry.log) state.msg_inflight
  @ Option.to_list state.msg_live
  |> List.filter_map (fun log ->
      let request_id = Masc_tui_types.turn_log_request_id log in
      let execution_id = Masc_tui_types.turn_log_execution_id log in
      if String.equal (Masc_tui_types.turn_log_keeper_name log) keeper_name
         && not (String.equal request_id execution_id)
      then Some (request_id, execution_id) else None)
  |> List.sort_uniq compare
  |> fun aliases ->
     (* Keep the existing first sorted binding if two watchers disagree. *)
     List.fold_right (fun (request_id, execution_id) owners ->
       Request_owners.add request_id execution_id owners) aliases Request_owners.empty

let compute_keeper_message_layout_entries (state : state) ~keeper_name ~request_owners
    ~chat_cols ~start_index visible_entries =
  (* Bound before the labels because one of them is fitted to it: a row from
     someone else names them, and adds the surface they came in by only when
     the column holds both. *)
  let role_label_column =
    Message_layout.chat_role_label_width ~pane_cells:chat_cols
  in
  (* Derived once for the width and again per row, so the badge the pane
     measures is the badge it draws. *)
  let base_role_label_of (message : Masc_tui_types.msg_entry) =
    match message.me_role with
    | Message_user (Sent_by_other { speaker; surface }) ->
        Message_layout.fit_speaker ~column:role_label_column ~speaker ~surface
          ()
    | Message_user (Sent_by_operator { surface }) ->
        (* Pending input is not a transcript row. Once it enters a turn this
           label can say YOU without a second queue lookup or a transient
           QUEUED identity that later changes underneath it.

           Fitted the same way as the arm above, because the pair is measured
           against the same column: the surface joins the badge when both fit
           and goes when they do not. It used to be joined before it got here
           and the badge asked whether the whole string was still "you", which
           only a row from the dashboard ever was -- so a line the operator
           wrote through a connector was cut as one string and drew
           "yo…dcast". *)
        Message_layout.fit_speaker ~column:role_label_column ~speaker:"YOU"
          ~surface ()
    | Message_keeper -> Keeper_chat.terminal_safe_text message.me_keeper_name
    | Message_autonomous -> Keeper_chat.terminal_safe_text message.me_keeper_name
    | Message_status -> "STATUS"
    | Message_local -> "LOCAL"
    | Message_error -> "ERROR"
    | Message_tool -> "TOOLS"
    | Message_skill _ -> "SKILL"
    | Message_thinking -> "THINKING"
    | Message_memory -> "JOURNAL"
  in
  (* Role labels identify speakers and activity lanes. Request identity stays
     in the grouping field; it is never inserted into speech. *)
  (* Who asked for a turn is one fact per turn, not one per row. It was the
     speaker label on every autonomous row, so the same keeper answered as
     itself when a person asked and as AUTO when nobody did -- two speakers for
     one keeper, interleaved with broadcasts and journal commits on one clock.
     The turn's opening row says it; the rows continuing that turn read as the
     keeper, like every other answer it gives. *)
  let role_label_of message edge =
    match message.Masc_tui_types.me_role with
    | Message_autonomous -> (
        match edge with
        | Masc_tui_types.Turn_opens | Masc_tui_types.Turn_alone -> "AUTO"
        | Masc_tui_types.Turn_continues | Masc_tui_types.Turn_closes
        | Masc_tui_types.Turn_outside ->
            base_role_label_of message)
    | _ -> base_role_label_of message
  in
  let projected_tool_rows =
    keeper_message_tool_rows state ~keeper_name ~chat_cols
  in
  let layout_entries =
    (* The position distinguishes rows whose durable timestamp and request
       fields tie. A history reorder can only cause a miss: the exact body is
       another cache-key field, so an index never authorizes stale rows. *)
    List.mapi
      (fun offset (message, timeline_at, edge) ->
        let entry_index = start_index + offset in
        let grouped_role_label = role_label_of message edge in
        (* Projected once: the style is read off it and the body is built
           from it, and projecting twice would let a fold decide the colour
           from one reading and the text from another. *)
        let tool_projection =
          match message.me_role with
          | Message_tool -> (
              match message.me_tool_block with
              | None -> None
              | Some block ->
                  Some
                    (Keeper_chat_transcript.project_tool_block
                       (tool_projection_mode state) block))
          | Message_user _ | Message_keeper | Message_autonomous
          | Message_status | Message_local | Message_memory | Message_error
          | Message_skill _ | Message_thinking ->
              None
        in
        let style =
          match message.me_role with
          | Message_user (Sent_by_operator _) -> Message_layout.User
          | Message_user (Sent_by_other _) -> Message_layout.Inbound
          | Message_keeper | Message_autonomous -> Message_layout.Keeper
          | Message_status -> Message_layout.Status
          | Message_local -> Message_layout.Local
          | Message_memory -> Message_layout.Journal
          | Message_error -> Message_layout.Error
          | Message_tool -> (
              match tool_projection with
              | None -> Message_layout.Tool
              | Some projection -> tool_block_style projection)
          | Message_skill state ->
              Message_layout.Skill (skill_tone_of_state state)
          | Message_thinking -> Message_layout.Thinking
        in
        (* The [Origin_row] heading names whoever the pane does not already.
           This pane is the keeper's own, so its replies carry no name there:
           the breadcrumb says whose chat it is, and a turn used to say it
           once per block. An autonomous turn still says who asked -- nobody
           -- where it opens. The inline gutter keeps the name. *)
        let speaker =
          match message.me_role with
          | Message_keeper -> ""
          | Message_autonomous -> (
              match edge with
              | Masc_tui_types.Turn_opens | Masc_tui_types.Turn_alone ->
                  grouped_role_label
              | Masc_tui_types.Turn_continues | Masc_tui_types.Turn_closes
              | Masc_tui_types.Turn_outside ->
                  "")
          | Message_user _ | Message_status | Message_local | Message_memory
          | Message_error | Message_tool | Message_skill _ | Message_thinking ->
              grouped_role_label
        in
        (* One column for every speaker so the [timestamp] speaker request
           rows line up down the pane, whatever name each row carries. *)
        let role_label =
          Message_layout.align_role_label ~column:role_label_column ~style
            grouped_role_label
        in
        let body =
          match message.me_role with
          | Message_thinking
            when state.msg_reasoning_visibility = Reasoning_folded ->
              folded_thinking_summary message.me_text
          | Message_skill _ -> (
              match message.me_skill_block with
              | [] -> message.me_text
              (* One row per skill the turn triggered, counted, is the fact
                 this row exists for. Each invocation's state, actions,
                 proof line and detail ride the tool cycle: full opens
                 them, the resting pane stays one line per skill. *)
              | activities ->
                  Keeper_chat_transcript.skill_rows
                    ~full:(state.msg_tool_visibility = Masc_tui_types.Tools_full)
                    activities
                  |> String.concat "\n")
          (* The Memory journal's change arrives inside a ["```diff"]
             fence, so a leading [+] is fence content rather than a list
             marker and needs no escaping. The escape that used to be here
             was never consumed by the renderer, so what reached the pane
             was a literal backslash in front of every changed fact. *)
          | Message_tool -> (
              match tool_projection with
              | None -> message.me_text
              | Some projection ->
                  String.concat "\n" (projected_tool_rows projection))
          | Message_memory -> (
              match state.msg_memory_visibility with
              (* Summary uses the producer's typed compact projection. Hidden
                 rows never reach this arm (the layout filter removed them),
                 and a neutral system row with no projection remains whole. *)
              | Memory_hidden -> message.me_text
              (* A revision with typed lines draws its header here and the
                 lines under it in columns ([journal] below); the plain text
                 would draw them twice. *)
              | Memory_full -> (
                  match message.me_journal, message.me_memory_summary with
                  | _ :: _, Some summary -> summary
                  | [], _ | _ :: _, None -> message.me_text)
              | Memory_summary -> (
                  (* The key that uncuts a summarised row is the footer's
                     Ctrl-N:journal, on screen whenever this row is. *)
                  match message.me_memory_summary with
                  | Some summary -> summary
                  | None -> message.me_text))
          (* Only a gated row: a Gate step's text ends in the argument the
             call asked for, while a status row without one is a sentence the
             server composed and has nothing to fold away. *)
          | Message_status when message.me_gate <> None -> (
              match state.msg_tool_visibility with
              | Tools_full -> message.me_text
              | Tools_compact | Tools_results ->
                  (gate_fold ~chat_cols ~role_label_column message)
                    .Masc_tui_gate_text.fa_text)
          | Message_thinking | Message_user _ | Message_keeper
          | Message_autonomous
          | Message_status | Message_local | Message_error ->
              message.me_text
        in
        let body_presentation = match message.me_role, state.msg_reasoning_visibility with
          | Message_thinking, Reasoning_folded -> snd (folded_thinking_body message.me_text)
          | _ -> Message_layout.Source_body in
        ({ style;
             body_presentation;
             timestamp =
               Option.fold ~none:message.me_timestamp
                 ~some:keeper_message_clock timeline_at;
             timeline_bucket =
               Option.map keeper_message_timeline_bucket
                 timeline_at;
             diagnostics = committed_request_diagnostics
               ~tools:state.msg_tool_visibility ~request_id:message.me_request_id
               ~execution_id:(request_owner request_owners message.me_request_id) ~edge;
             speaker;
             role_label;
             role_label_mark_cells =
               Message_layout.role_label_mark_cells
                 ~column:role_label_column ~style ();
             request_label = request_owner request_owners message.me_request_id;
             body;
             journal =
               (match message.me_role, state.msg_memory_visibility with
                | Message_memory, Memory_full -> message.me_journal
                | Message_memory, (Memory_summary | Memory_hidden)
                | ( ( Message_user _ | Message_keeper | Message_autonomous
                    | Message_status | Message_local | Message_error
                    | Message_tool | Message_skill _ | Message_thinking ),
                    _ ) ->
                    []);
             markdown_source =
               Message_layout.Markdown_stable
                 { keeper_name = message.me_keeper_name;
                   request_id = message.me_request_id;
                   observed_at = message.me_at;
                   entry_index;
                 };
             turn_rail =
               turn_rail_of ~siding:(siding_of_message message) ~edge ~style;
             (* Only a Gate row that actually folded: a row holding nothing
                would take a press and do nothing visible, which reads as the
                pane ignoring the click. *)
             action =
               (match message.me_role, state.msg_tool_visibility with
                | Masc_tui_types.Message_status, (Tools_compact | Tools_results)
                  when message.me_gate <> None
                       && (gate_fold ~chat_cols ~role_label_column message)
                            .Masc_tui_gate_text.fa_held_cells
                          > 0 ->
                    Message_layout.Action_unfold_argument
                | _ -> Message_layout.Action_none);
           }
            : Message_layout.entry))
      visible_entries
  in
  layout_entries


(* The operator's own lines that have left the composer and not settled yet:
   the one a running turn is answering, and the ones waiting behind it.

   They were drawn in fixed slots between the history and the composer, which
   put them outside the conversation's own time axis. A line typed at 14:06
   sat below a status row stamped 14:05:54 and above the composer, so the
   screen said the newest thing had happened first. As entries they join the
   tail of the stream every other line is in, and what state a line is in is
   said on the row rather than by where the row sits.

   [Markdown_streaming] because a queued line is still editable -- Ctrl-P
   takes the last one back into the composer -- so no render cache may hold
   it. [Rail_none] because the rail draws a turn's bracket and these belong
   to a turn that has not opened one yet; RFC chat-turn-rail-and-side-lanes
   decides later what a turn's own opening looks like. *)
let chat_tail_entries (state : state) ~keeper_name ~role_label_column =
  (* Delivery state belongs to the gutter/header. The pending text is exactly
     the submitted body; changing delivery state never rewrites its words. *)
  let delivery_label = function
    | Local_pending -> "전송 대기"
    | Awaiting_receipt -> "전송 중"
    | Keeper_queued -> "처리 대기"
    | Rechecking_delivery -> "전송 확인 중"
  in
  (* Pending and committed speech use the same column. A narrow gutter fits
     the state label; Origin_row keeps the complete label in its heading. *)
  let entry ~at ~request_id ~label ~body =
    (* Pending input has not entered the conversation. It uses the composer's
       local mark, not the arrow that means a submitted conversation row. *)
    let style = Message_layout.Local in
    ({ style
     ; body_presentation = Message_layout.Source_body
     ; timestamp = keeper_message_clock at
     ; timeline_bucket = Some (keeper_message_timeline_bucket at)
     (* A pending input has no execution yet, so its request is its only
        identity. The activity rows name requests by this id. *)
     ; diagnostics =
         request_diagnostics ~tools:state.msg_tool_visibility ~request_id
           ~execution_id:request_id
     ; speaker = label
     ; role_label =
         Message_layout.align_role_label ~column:role_label_column ~style label
     ; role_label_mark_cells =
         Message_layout.role_label_mark_cells ~column:role_label_column ~style ()
     ; request_label = request_id
     ; body = Keeper_chat.terminal_safe_text ~preserve_newlines:true body
     ; journal = []
     ; markdown_source = Message_layout.Markdown_streaming
     ; turn_rail = Message_layout.Rail_none
     ; action = Message_layout.Action_none
     }
      : Message_layout.entry)
  in
  let requests = Masc_tui_types.keeper_message_waiting_requests state ~keeper_name in
  let entries = List.map (fun (request, delivery) ->
      let at =
        match List.find_opt (fun (inflight : Masc_tui_types.inflight) ->
            Keeper_chat.same_request_identity inflight.sent_request request)
            state.msg_inflight with
        | Some inflight -> inflight.submitted_at
        | None ->
            match List.find_opt (fun (item : Masc_tui_keeper_chat_queue.item) ->
                Keeper_chat.same_request_identity item.request request)
                (Masc_tui_keeper_chat_queue.waiting_for_keeper state.msg_queued ~keeper_name) with
            | Some item -> item.submitted_at
            | None -> Unix.gettimeofday ()
      in
      let label = delivery_label delivery in
      entry ~at ~request_id:request.Keeper_chat.request_id ~label
        ~body:request.Keeper_chat.message) requests in
  match entries with
  | [] -> []
  | first :: _ ->
      let style = Message_layout.Status in
      (* The heading is not the input it was copied from. *)
      { first with style; timestamp = ""; timeline_bucket = None;
          diagnostics = [];
          speaker = "대기 입력";
          role_label = Message_layout.align_role_label
            ~column:role_label_column ~style "대기 입력";
          role_label_mark_cells = Message_layout.role_label_mark_cells
            ~column:role_label_column ~style ();
          request_label = "";
          body = Printf.sprintf "대기 입력 %d건" (List.length requests)
      } :: entries


(* The polled tail is an excerpt for a turn whose journal is unavailable.
   Once that exact turn's journal supplies text, the chronological transcript
   owns the output and the excerpt must disappear. *)
let preview_for_polled_anchor state keeper_name anchor =
  List.find_map (fun (row : Tui_decode.keeper_turn_row) ->
    if not (String.equal row.ktr_keeper_name keeper_name) then None else
    match anchor, row.ktr_state with
    | Scroll_polled (token, generation, Polled_speech),
      Tui_decode.Keeper_turn_running {interrupt_token;preview=Some preview;_}
      when String.equal token interrupt_token
        && generation = preview.ktp_text_position.kpp_generation -> Some preview
    | _ -> None) state.keeper_turns

let held_polled_for_keeper state keeper_name =
  match state.msg_scroll_pin with
  | Some pin when pin.pin_mode <> Follow_live
      && pin.pin_workspace = state.workspace_authority
      && String.equal pin.pin_keeper keeper_name -> pin.held_transients
  | Some _ | None -> []

let polled_turn_output_with_anchors (state : state) ~keeper_name ~role_label_column =
  let live_text_drawn =
    match state.msg_live with
    | Some live when String.equal (Masc_tui_types.turn_log_keeper_name live) keeper_name ->
        List.exists
          (fun (item : Masc_tui_keeper_chat_transcript.drawn_item) ->
            match item.drawn with
            | Masc_tui_keeper_chat_transcript.Drawn_text _
            | Masc_tui_keeper_chat_transcript.Drawn_reply _ -> true
            | Masc_tui_keeper_chat_transcript.Drawn_thinking _
            | Masc_tui_keeper_chat_transcript.Drawn_skill _
            | Masc_tui_keeper_chat_transcript.Drawn_tools _
            | Masc_tui_keeper_chat_transcript.Drawn_status _
            | Masc_tui_keeper_chat_transcript.Drawn_error _ -> false)
          (Masc_tui_keeper_chat_transcript.drawn live.tl_transcript)
    | Some _ | None -> false
  in
  match List.find_opt
      (fun (row : Tui_decode.keeper_turn_row) ->
         String.equal row.ktr_keeper_name keeper_name)
      state.keeper_turns with
    | Some { ktr_state = Tui_decode.Keeper_turn_running
        { lane; turn_ref; interrupt_token; preview = Some preview; _ }; _ }
      when String.trim preview.ktp_text_tail <> ""
           && (match lane with
               | Tui_decode.Turn_lane_chat_operation ->
                   not (Option.is_some (Masc_tui_types.working_chat_for_keeper state keeper_name)
                        || live_text_drawn
                        || Masc_tui_types.observed_turn_text_drawn state keeper_name)
               | Tui_decode.Turn_lane_autonomous | Tui_decode.Turn_lane_maintenance ->
                   not (Option.exists (fun turn_ref ->
                     let source = Masc_tui_keeper_chat_log.Autonomous_turn turn_ref in
                     Masc_tui_types.selected_source_logs_for_keeper state keeper_name
                     |> List.exists (fun log ->
                       Masc_tui_keeper_chat_log.source log.tl_log = source
                       && not (Masc_tui_types.observed_log_is_unavailable state log)
                       && List.exists (fun (item : Keeper_chat_transcript.drawn_item) ->
                         match item.drawn with
                         | Drawn_text _ | Drawn_reply _ -> true
                         | Drawn_thinking _ | Drawn_tools _ | Drawn_skill _ | Drawn_status _ | Drawn_error _ -> false)
                         (Keeper_chat_transcript.drawn log.tl_transcript))) turn_ref)) ->
        let style = Message_layout.Keeper in
        let label = keeper_name in
        let note =
          match state.keeper_turns_error with
          | None -> "진행 중"
          | Some _ -> "마지막 관측, 갱신 실패"
        in
        let speech = ({ style
           ; body_presentation = Message_layout.Source_body
           ; timestamp = keeper_message_clock preview.ktp_updated_at_unix
           ; timeline_bucket = Some (keeper_message_timeline_bucket preview.ktp_updated_at_unix)
           ; diagnostics = []
           ; speaker = label
           ; role_label =
               Message_layout.align_role_label ~column:role_label_column ~style label
           ; role_label_mark_cells =
               Message_layout.role_label_mark_cells ~column:role_label_column ~style ()
           ; request_label = ""
           ; body = Masc.Tui_terminal_text.sanitize_terminal_lines preview.ktp_text_tail
           ; journal = []
           ; markdown_source = Message_layout.Markdown_streaming
           ; turn_rail = Message_layout.Rail_none
           ; action = Message_layout.Action_none
           } : Message_layout.entry) in
        let status_style = Message_layout.Status in
        [ Scroll_polled (interrupt_token, preview.ktp_text_position.kpp_generation, Polled_speech), speech
        ; Scroll_polled (interrupt_token, preview.ktp_text_position.kpp_generation, Polled_status),
          { speech with style = status_style; speaker = "STATUS";
            role_label = Message_layout.align_role_label
              ~column:role_label_column ~style:status_style "STATUS";
            role_label_mark_cells = Message_layout.role_label_mark_cells
              ~column:role_label_column ~style:status_style ();
            body = Printf.sprintf "%s · %s · 최근 출력 발췌"
              note (Masc_tui_answering.lane_word lane) } ]
    | Some _ | None -> []

let polled_turn_output_entries state ~keeper_name ~role_label_column =
  polled_turn_output_with_anchors state ~keeper_name ~role_label_column |> List.map snd

(* One conversation's layout entries, reused per message across a change of
   the conversation.

   #32878 memoized this list whole: any landed message replaced the row
   list, and the next frame rebuilt an entry for every visible message --
   the safe text, the aligned badge, the link scan of the whole body, and a
   tool projection whose durable-call association filters the call snapshot
   per row. In an active chat, where a row lands every few seconds while
   the operator types, nearly every frame paid for the whole transcript.
   An entry is a pure function of one message and the readings below, so a
   frame whose conversation moved recomputes only the positions that
   actually moved; the rest are taken over unchanged.

   The full list of what one entry reads, and what busts its reuse:

   - the message record, compared by physical identity. Every field an
     entry is built from -- role, text, keeper name, tool block, skill
     activity, memory summary, request id, durable timestamp, observed-at --
     is a field of this record, and the row pipeline ([chat_timeline_slots],
     [chat_timeline_rows], the visibility filter) passes records through
     untouched: a conversation change replaces records rather than mutating
     them, the same contract [chat_rows_memo] and [chat_timeline_ats_memo]
     already rely on. A row rewritten in place (a queued line edited before
     sending) arrives as a fresh record and misses;
   - the entry's position in the visible timeline, baked into
     [markdown_source] as [entry_index]. The walk below compares
     positionally, so a reused entry's index is its position by
     construction; a removal or insertion above it ends the shared prefix
     and the tail is recomputed with its new indices;
   - the projected timeline moment for that position, from
     [chat_projected_timeline_ats]: a per-request floor over the whole row
     list in list order, so a row sorting in above (a late tool row joining
     its turn) can move the floor for later rows of that request. The walk
     compares the moment by value at every position, and a moved floor ends
     the sharing there;
   - the row's turn edge, from [mark_turn_edges]: whether the row opens,
     continues, closes, or is its whole turn, which the role label of an
     autonomous row reads ([AUTO] only where a turn opens). The edge of a
     position is a function of where its request's first and last rows sit
     in the visible list, so an append to an open turn flips the edge of
     the turn's previous last row; the walk compares the edge by value at
     every position, and a flipped edge ends the sharing there;
   - the keeper, the pane width, and the memory/reasoning/tool visibility
     readings, compared by value. The width decides the badge column and
     the tool-row wrap; the visibilities decide the folded thinking body,
     the journal summary body, and the compact/full tool projection (memory
     and reasoning also decide which rows the visible timeline holds at
     all, which the position comparison then sees);
   - validated request-to-execution aliases, indexed once by request. Alias
     changes update only the affected entry's grouping and diagnostics; they
     do not rebuild unrelated historical bodies;
   - this keeper's file-change index and durable-call snapshot readings,
     replaced wholesale when a load lands, so physical identity says whether
     they moved; the tool detail rows read both;
   - the terminal palette generation, because the tool detail rows bake the
     resolved colours into their text and a palette that arrived after
     start-up must not keep drawing the previous answer's escapes.

   Deliberately not inputs: the scroll position and the origin-display mode
   act after the entries exist ([rows_of_entry] takes them), the live turn
   is built where it is drawn, and [keeper_message_clock]'s timezone is the
   process's own for its whole life -- the assumption the whole-list memo
   already made.

   The reuse is a parallel walk over the previous and current visible
   timelines: while the record, the projected moment, and the turn edge at
   a position all agree, the entry computed for it is taken over; from the
   first position that differs, the tail is computed fresh. An append --
   the common case, every committed row landing at the newest end --
   therefore computes one entry, or two when it closes a turn's previous
   last row; a mid-list insertion recomputes the suffix below it, which
   during a live turn is the turn still settling. [Lazy.t] inside the entry
   was considered so a constructed-but-unviewed entry could skip its link
   scan and tool rows, but entries are constructed off the visible slice
   only when the readings above change wholesale -- first load, an older
   page prepending, a visibility toggle, a resize -- never on the
   per-message path this memo exists for, and a lazy [body] would change
   [Message_layout.entry] for every reader to serve a path that already
   runs once per change.

   One slot holding one conversation's entries, replaced wholesale when any
   reading changes: nothing accumulates across keepers, widths, or palette
   generations, and nothing is kept stale. Module state rather than a field
   on [state], like [chat_rows_memo]: a derived reading is not authority,
   and the input layer would otherwise have to invalidate it at every
   mutation site. *)
type layout_entries_memo = {
  lem_keeper_name : string;
  lem_request_owners : string Request_owners.t;
  lem_chat_cols : int;
  lem_preview_mode : [ `Rich | `Compact | `Off ];
  lem_preview_generation : int;
  lem_memory : memory_visibility;
  lem_reasoning : reasoning_visibility;
  lem_tools : tool_visibility;
  lem_file_changes_keeper : string option;
  lem_file_change_index : Keeper_chat_diff.index;
  lem_calls_keeper : string option;
  lem_calls_loading : bool;
  lem_calls_error : string option;
  lem_calls : keeper_calls_snapshot option;
  lem_palette_generation : int;
  lem_visible_timeline : (msg_entry * float option) list;
  lem_visible_entries : (msg_entry * float option * turn_edge) list;
  lem_entries : Message_layout.entry list;
}

let layout_entries_memo : layout_entries_memo option ref = ref None


(* The visible timeline with each row's turn edge beside it. Marking the
   edges walks the list once, so it runs only when the timeline actually
   changed; the identical-frame path below answers on the timeline's
   physical identity without paying it. *)
let keeper_message_visible_entries visible_timeline =
  let edges =
    List.map snd (Masc_tui_types.mark_turn_edges (List.map fst visible_timeline))
  in
  List.map2
    (fun (message, timeline_at) edge -> (message, timeline_at, edge))
    visible_timeline edges

;;

(* Positions whose message record, projected moment, and turn edge all
   survived a conversation change keep the entry already computed for them.
   The first position that differs ends the sharing, because the index
   baked into [markdown_source], the per-request floor walked in list
   order, and the first/last marking an edge reads are each only as good as
   every position above them. The suffix goes back as the tail cell it was
   found at, so a caller can tell "nothing shared" by physical identity
   rather than by measuring. *)
let rec shared_layout_entry_prefix ~refresh_owner reversed old_visible old_entries
    new_visible =
  match old_visible, old_entries, new_visible with
  | (old_message, old_at, old_edge) :: old_visible_rest,
    entry :: old_entries_rest,
    (message, timeline_at, edge) :: new_visible_rest
    when old_message == message
         && Option.equal Float.equal old_at timeline_at
         && old_edge = edge ->
      let entry = refresh_owner message edge entry in
      shared_layout_entry_prefix ~refresh_owner (entry :: reversed) old_visible_rest
        old_entries_rest new_visible_rest
  | _ -> List.rev reversed, new_visible

;;

let keeper_message_layout_entries ?messages (state : state) ~keeper_name
    ~chat_cols =
  let messages =
    match messages with
    | Some messages -> messages
    | None -> chat_rows_for state keeper_name
  in
  let visible_timeline =
    keeper_message_visible_timeline ~messages state ~keeper_name
  in
  let palette_generation =
    Masc_tui_terminal_palette.snapshot_generation
      (Masc_tui_terminal_palette.snapshot ())
  in
  let preview_generation = Masc_tui_link_preview.cache_generation () in
  let request_owners = chat_request_owners state ~keeper_name in
  let same_inputs (memo : layout_entries_memo) =
    String.equal memo.lem_keeper_name keeper_name
    && memo.lem_chat_cols = chat_cols
    && memo.lem_preview_mode = state.link_previews_mode
    && memo.lem_preview_generation = preview_generation
    && memo.lem_memory = state.msg_memory_visibility
    && memo.lem_reasoning = state.msg_reasoning_visibility
    && memo.lem_tools = state.msg_tool_visibility
    && Option.equal String.equal memo.lem_file_changes_keeper
         state.msg_file_changes_keeper
    && memo.lem_file_change_index == state.msg_file_change_index
    && Option.equal String.equal memo.lem_calls_keeper
         state.keeper_calls_keeper
    && Bool.equal memo.lem_calls_loading state.keeper_calls_loading
    && Option.equal String.equal memo.lem_calls_error
         state.keeper_calls_error
    && memo.lem_calls == state.keeper_calls
    && memo.lem_palette_generation = palette_generation
  in
  match !layout_entries_memo with
  | Some memo
    when same_inputs memo && memo.lem_visible_timeline == visible_timeline
         && Request_owners.equal String.equal memo.lem_request_owners request_owners ->
      memo.lem_entries
  | Some memo when same_inputs memo ->
      let visible_entries = keeper_message_visible_entries visible_timeline in
      let owner_changed = ref false in
      let refresh_owner message edge (entry : Message_layout.entry) =
        let execution_id = request_owner request_owners message.me_request_id in
        if String.equal entry.request_label execution_id then entry
        else (
          owner_changed := true;
          { entry with request_label = execution_id;
            diagnostics = committed_request_diagnostics
              ~tools:state.msg_tool_visibility ~request_id:message.me_request_id
              ~execution_id ~edge })
      in
      let prefix, suffix =
        shared_layout_entry_prefix ~refresh_owner [] memo.lem_visible_entries
          memo.lem_entries visible_entries
      in
      let entries =
        match suffix with
        | [] when not !owner_changed
                  && List.length prefix = List.length memo.lem_entries -> memo.lem_entries
        | [] -> prefix
        | _ when suffix == visible_entries ->
            compute_keeper_message_layout_entries state ~keeper_name ~request_owners
              ~chat_cols ~start_index:0 visible_entries
        | _ ->
            prefix
            @ compute_keeper_message_layout_entries state ~keeper_name ~request_owners
                ~chat_cols ~start_index:(List.length prefix) suffix
      in
      layout_entries_memo :=
        Some
          { memo with
            lem_request_owners = request_owners;
            lem_visible_timeline = visible_timeline;
            lem_visible_entries = visible_entries;
            lem_entries = entries;
          };
      entries
  | Some _ | None ->
      let visible_entries = keeper_message_visible_entries visible_timeline in
      let entries =
        compute_keeper_message_layout_entries state ~keeper_name ~request_owners ~chat_cols
          ~start_index:0 visible_entries
      in
      layout_entries_memo :=
        Some
          { lem_keeper_name = keeper_name;
            lem_request_owners = request_owners;
            lem_chat_cols = chat_cols;
            lem_preview_mode = state.link_previews_mode;
            lem_preview_generation = preview_generation;
            lem_memory = state.msg_memory_visibility;
            lem_reasoning = state.msg_reasoning_visibility;
            lem_tools = state.msg_tool_visibility;
            lem_file_changes_keeper = state.msg_file_changes_keeper;
            lem_file_change_index = state.msg_file_change_index;
            lem_calls_keeper = state.keeper_calls_keeper;
            lem_calls_loading = state.keeper_calls_loading;
            lem_calls_error = state.keeper_calls_error;
            lem_calls = state.keeper_calls;
            lem_palette_generation = palette_generation;
            lem_visible_timeline = visible_timeline;
            lem_visible_entries = visible_entries;
            lem_entries = entries;
          };
      entries


(* Whose a merged row is: a committed message's, or a block's log's. *)
type tagged_row =
  | Tagged_row of Masc_tui_types.msg_entry
  | Tagged_block of Masc_tui_types.turn_log * Keeper_chat_transcript.drawn_origin option * bool

(* One turn's block as the chat pane draws it: the log it comes from, where
   it goes in the committed timeline, and its rows -- built as continuations,
   the corners set once the blocks are merged with the committed rows. *)
type log_entry = {
  le_at : float option;
  le_origin : Keeper_chat_transcript.drawn_origin option;
  le_is_reply : bool;
  le_entry : Message_layout.entry;
}

type log_block = {
  lb_log : Masc_tui_types.turn_log;
  lb_request_id : string;
  lb_member_ids : string list;
  lb_insertion : int;
  lb_timeline_at : float option;
  lb_entries : log_entry list;
}

(* A settled block, per (keeper, request), until one of its inputs moves:
   the log's transcript (its revision: durable tool facts fold in after
   settle), the committed timeline it is placed in, the knobs its rows read,
   and the width. Module state like the renderer's other memos: derived, not
   authority. Never evicted within a session, like the logs themselves. *)
type settled_block_memo = {
  sbm_log : Masc_tui_types.turn_log;
  sbm_committed : bool;
      (** Which placement the block was projected with: a settled turn's,
          or the open placement an observed turn takes. *)
  sbm_failure_in_live_status : bool;
  sbm_revision : int;
  sbm_member_ids : string list;
  sbm_timeline : (Masc_tui_types.msg_entry * float option) list;
  sbm_messages : Masc_tui_types.msg_entry list;
  sbm_reasoning : reasoning_visibility;
  sbm_tools : tool_visibility;
  sbm_calls_keeper : string option;
  sbm_calls_loading : bool;
  sbm_calls_error : string option;
  sbm_calls : keeper_calls_snapshot option;
  sbm_file_changes_keeper : string option;
  sbm_file_change_index : Keeper_chat_diff.index;
  sbm_palette_generation : int;
  sbm_chat_cols : int;
  sbm_block : log_block;
}

let settled_block_memo : (string * string, settled_block_memo) Hashtbl.t =
  Hashtbl.create 16


(* The merged rows while no block is live: the same list across frames when
   the committed entries and every settled block are the same values, which
   is what lets the row walk keep its counts. *)
type merged_blocks_memo = {
  mbm_committed : Message_layout.entry list;
  mbm_blocks : log_block list;
  mbm_merged : (tagged_row * Message_layout.entry) list;
  mbm_entries : Message_layout.entry list;
}

let merged_blocks_memo : merged_blocks_memo option ref = ref None

(* [Message_layout] keeps its row counts for the list it measured and knows
   that list by identity. A settled conversation has no transient tail, and
   appending an empty one would still copy the list, so every repaint would
   measure the whole scroll depth again. *)
let with_transient_tail settled ~transient =
  match transient with
  | [] -> settled
  | _ :: _ -> settled @ transient

type chat_projection = {
  tagged_entries : (tagged_row * Message_layout.entry) list;
  transient_anchors : chat_scroll_anchor option list;
  layout_entries : Message_layout.entry list;
}

(* Drawing, search and row measurement consume this same chronological
   projection. History suppression and held journals must never be separate
   definitions of which messages the conversation contains. *)
let keeper_message_projection (state : state) ~keeper_name ~chat_cols =
  (* The same pure derivation the committed rows used, asked again for the
     live ones: one call to one function with one argument, so the badge the
     streaming turn aligns to is the badge the history aligned to. *)
  let role_label_column =
    Message_layout.chat_role_label_width ~pane_cells:chat_cols
  in
  let projected_tool_rows =
    keeper_message_tool_rows state ~keeper_name ~chat_cols
  in
  let committed_timeline_messages = chat_rows_for state keeper_name in
  let committed_visible_timeline =
    keeper_message_visible_timeline state ~keeper_name
  in
  let committed_messages = List.map fst committed_visible_timeline in
  let committed_layout_entries =
    keeper_message_layout_entries state ~keeper_name ~chat_cols
  in
  (* Rows for the turns this session holds as logs: every settled turn of
     this keeper that its log stands for, then the one still streaming. Each
     block follows the committed rows of its own request rather than
     escaping to a second bottom-only lane: a settled block sits after the
     request's last row of any phase before output (its failure row, if any,
     came after everything the block holds), the live block after every
     committed row of its request. A settled block is the same rows with a
     closing rail: settling changes the rail, not the words (RFC-0412 §3.3).

     A settled log is immutable but for the durable facts folded into its
     transcript, and its block depends on the committed rows only through
     the timeline it is placed in; so each block is memoized on the
     transcript's revision, the timeline's identity and the knobs the rows
     read, and the merged list is reused whole while no block is live. That
     is what keeps an idle pane holding settled turns at the same per-frame
     cost it had before they were logs. *)
  let failure_in_live_status turn_log =
    Option.exists (fun live -> live == turn_log)
      (Masc_tui_types.keeper_message_status_log state)
  in
  let log_projection ~committed:_ (turn_log : Masc_tui_types.turn_log) =
    let transcript = turn_log.tl_transcript in
    let request_id = Masc_tui_types.turn_log_execution_id turn_log in
    let member_ids = Masc_tui_types.chat_execution_member_ids state
        ~keeper_name ~execution_id:request_id in
    let committed_error =
      List.exists
        (fun (message : Masc_tui_types.msg_entry) ->
          message.me_role = Message_error
          && List.mem message.me_request_id member_ids)
        committed_timeline_messages
    in
    let request_label = request_id in
    let started_at = Keeper_chat_transcript.started_at transcript in
    let bounds_request (message : Masc_tui_types.msg_entry) =
      (not (List.mem message.me_request_id member_ids))
      || message.me_turn_phase = Turn_input
    in
    let request_messages =
      List.filter bounds_request committed_timeline_messages
    in
    let bounded_timeline =
      List.filter
        (fun ((message : Masc_tui_types.msg_entry), _) -> bounds_request message)
        committed_visible_timeline
    in
    let timeline_at =
      chat_live_timeline_at ~member_ids ~request_id ~started_at ~request_messages
        bounded_timeline
    in
    let insertion =
      chat_block_insertion_index ~member_ids
        ~bounds:(fun row -> row.me_turn_phase = Turn_input)
        ~request_id ~timeline_at committed_visible_timeline
    in
    let keeper_label =
      Keeper_chat.terminal_safe_text
        (Masc_tui_types.turn_log_keeper_name turn_log)
    in
    (* The turn in the order it happened, one row per stretch
       ([Keeper_chat_transcript.drawn]): a tool-call round interleaves
       reasoning, calls and reply text, and drawing them as three pooled
       blocks read as one wall of text with its calls listed elsewhere. The
       recorded reply is already reconciled in: by outcome, a differing
       terminal stretch is replaced by the recorded text and a control
       outcome ends the turn in one STATUS row.

       Indexed and filtered at once. The index is the growing-markdown cache
       key (#30290) and the filter is how hidden reasoning disappears; the
       index counts drawn positions, not surviving rows, so hiding reasoning
       does not renumber the text entries and invalidate every cached render
       below it. Every stretch rides the growing-markdown cache: a frame
       whose text did not move reuses the rows outright, and only the new
       suffix is parsed when it did.

       A superseded attempt's stretches are drawn in place with their own
       styles, each label ending in the retry mark and the number of the try
       it came from (" ↺1" = the first try, superseded). The mark goes at the
       tail because the role label keeps two thirds of its tail when it
       overruns the column. Not dimmed: the layout has no dim variant per style, and
       adding one is the 3b restyle.

       Every row is built as a continuation; the corners are set once the
       blocks are merged with the committed rows, where a turn's first and
       last row are known. *)
    (* The gutter follows the block's causal timeline position. Speech
       remains the recorded text without a turn clock prepended to it. *)
    let frontier = ref timeline_at in
    let request_shown = ref false in
    let shown_attempts = ref [] in
    let entries =
      List.filter_map Fun.id
      @@ List.mapi
           (fun entry_index (item : Keeper_chat_transcript.drawn_item) ->
              let timeline_at = match !frontier, item.at with
                | Some floor, Some at -> Some (Float.max floor at)
                | Some _ as at, None | None, (Some _ as at) -> at
                | None, None -> None in
              frontier := timeline_at;
              let timeline_bucket = Option.map keeper_message_timeline_bucket timeline_at in
              let label text =
                match item.superseded with
                | Some attempt ->
                    Printf.sprintf "%s \xe2\x86\xba%d" text (attempt + 1)
                | None -> text
              in
              let markdown_source =
                Message_layout.Markdown_growing
                  { keeper_name; request_id; entry_index }
              in
              let entry ?(speaker : string option) ?(body_presentation=Message_layout.Source_body) style role_label body =
                (* One alignment, on the label the row actually carries.
                   Aligning the continuation mark and then aligning the
                   result again pays the badge's width twice, so the second
                   call trims what the first had already fitted. *)
                let diagnostics =
                  let request =
                    if !request_shown then []
                    else request_diagnostics ~tools:state.msg_tool_visibility
                      ~request_id:(Masc_tui_types.turn_log_request_id turn_log)
                      ~execution_id:request_id in
                  request_shown := true;
                  let attempt = match state.msg_tool_visibility, item.superseded_runtime_id with
                    | Tools_full, Some runtime_id when String.trim runtime_id <> "" ->
                        let number = Option.value item.superseded ~default:0 + 1 in
                        let key = (number, runtime_id) in
                        if List.mem key !shown_attempts then []
                        else (
                          shown_attempts := key :: !shown_attempts;
                          [Printf.sprintf "attempt %d: %s" number
                             (Keeper_chat.terminal_safe_text runtime_id)])
                    | _ -> [] in
                  request @ attempt
                in
                Some
                  { le_at = timeline_at; le_origin = Some item.origin;
                    le_is_reply = (match item.drawn with
                      | Keeper_chat_transcript.Drawn_reply _ -> true
                      | Drawn_text _ | Drawn_thinking _ | Drawn_tools _
                      | Drawn_skill _ | Drawn_status _ | Drawn_error _ -> false);
                    le_entry = ({ style;
                     body_presentation;
                     timestamp = keeper_message_clock (Option.value timeline_at ~default:started_at);
                     timeline_bucket;
                     diagnostics;
                     speaker = Option.value speaker ~default:role_label;
                     role_label =
                       Message_layout.align_role_label
                         ~column:role_label_column
                         (* Same reasoning as the history rows above: the
                            column says who, not a mark inside the label. *)
                         ~style role_label;
                     role_label_mark_cells =
                       Message_layout.role_label_mark_cells
                         ~column:role_label_column ~style ();
                     request_label;
                     body;
                     journal = [];
                     markdown_source;
                     turn_rail =
                       turn_rail_of ~siding:None
                         ~edge:Masc_tui_types.Turn_continues ~style;
                     (* A live turn draws its Gate steps as status text the
                        transcript composed, not as the store's argument, so
                        there is no argument here to unfold. *)
                     action = Message_layout.Action_none;
                   }
                    : Message_layout.entry) }
              in
              match item.drawn with
              | Keeper_chat_transcript.Drawn_thinking _
                when not
                       (Masc_tui_types.reasoning_drawn
                          state.msg_reasoning_visibility) ->
                  None
              | Keeper_chat_transcript.Drawn_thinking lines ->
                  let body, body_presentation =
                    if state.msg_reasoning_visibility = Reasoning_folded
                    then folded_thinking_body (String.concat "\n" lines)
                    else String.concat "\n" lines, Message_layout.Source_body
                  in
                  entry ~body_presentation Message_layout.Thinking (label "THINKING") body
              | Keeper_chat_transcript.Drawn_tools block ->
                  let projection =
                    Keeper_chat_transcript.project_tool_block
                      (tool_projection_mode state) block
                  in
                  let body = String.concat "\n" (projected_tool_rows projection) in
                  entry (tool_block_style projection) (label "TOOLS") body
              | Keeper_chat_transcript.Drawn_skill skills ->
                  entry
                    (Message_layout.Skill
                       (skill_tone_of_state
                          (Keeper_chat_transcript.skill_block_state skills)))
                    (label "SKILL")
                    (String.concat "\n"
                       (* Same fold as the committed rows: one counted row
                          per skill; each invocation's state, actions,
                          proof line and detail ride the tool toggle. *)
                       (Keeper_chat_transcript.skill_rows
                          ~full:(state.msg_tool_visibility = Masc_tui_types.Tools_full)
                          skills))
              | Keeper_chat_transcript.Drawn_text text
              | Keeper_chat_transcript.Drawn_reply text ->
                  (* No name on the heading, as on the committed rows:
                     this is the keeper's own pane. *)
                  entry ~speaker:(label "") Message_layout.Keeper
                    (label keeper_label) text
              | Keeper_chat_transcript.Drawn_status text ->
                  entry Message_layout.Status (label "STATUS") text
              | Keeper_chat_transcript.Drawn_error _
                when failure_in_live_status turn_log || committed_error ->
                  (* Only the focused live log has the footer's status;
                     another source may have its session/history error. *)
                  None
              | Keeper_chat_transcript.Drawn_error text ->
                  entry Message_layout.Error (label "ERROR") text)
           (Keeper_chat_transcript.drawn transcript)
    in
    { lb_log = turn_log; lb_request_id = request_id; lb_member_ids = member_ids; lb_insertion = insertion; lb_timeline_at = timeline_at;
      lb_entries = entries }
  in
  (* One projection per held log per change of its inputs, settled or
     observed. The transcript's revision moves on every fold, so a journal
     read that grew an observed log reprojects it once, and the frames
     between reads -- every key, tick and async message -- reuse the
     block. *)
  let held_projection ~committed (turn_log : Masc_tui_types.turn_log) =
    let key =
      ( Masc_tui_types.turn_log_keeper_name turn_log
      , Masc_tui_types.turn_log_request_id turn_log )
    in
    let member_ids = Masc_tui_types.chat_execution_member_ids state
        ~keeper_name ~execution_id:(Masc_tui_types.turn_log_execution_id turn_log) in
    let revision = Keeper_chat_transcript.revision turn_log.tl_transcript in
    let palette_generation =
      Masc_tui_terminal_palette.snapshot_generation
        (Masc_tui_terminal_palette.snapshot ())
    in
    match Hashtbl.find_opt settled_block_memo key with
    | Some memo
      when memo.sbm_log == turn_log
           && memo.sbm_committed = committed
           && memo.sbm_failure_in_live_status = failure_in_live_status turn_log
           && memo.sbm_revision = revision
           && memo.sbm_member_ids = member_ids
           && memo.sbm_timeline == committed_visible_timeline
           && memo.sbm_messages == committed_timeline_messages
           && memo.sbm_reasoning = state.msg_reasoning_visibility
           && memo.sbm_tools = state.msg_tool_visibility
           && memo.sbm_calls_keeper = state.keeper_calls_keeper
           && memo.sbm_calls_loading = state.keeper_calls_loading
           && memo.sbm_calls_error = state.keeper_calls_error
           && memo.sbm_calls == state.keeper_calls
           && memo.sbm_file_changes_keeper = state.msg_file_changes_keeper
           && memo.sbm_file_change_index == state.msg_file_change_index
           && memo.sbm_palette_generation = palette_generation
           && memo.sbm_chat_cols = chat_cols ->
        memo.sbm_block
    | Some _ | None ->
        let block = log_projection ~committed turn_log in
        Hashtbl.replace settled_block_memo key
          { sbm_log = turn_log;
            sbm_committed = committed;
            sbm_failure_in_live_status = failure_in_live_status turn_log;
            sbm_revision = revision;
            sbm_member_ids = member_ids;
            sbm_timeline = committed_visible_timeline;
            sbm_messages = committed_timeline_messages;
            sbm_reasoning = state.msg_reasoning_visibility;
            sbm_tools = state.msg_tool_visibility;
            sbm_calls_keeper = state.keeper_calls_keeper;
            sbm_calls_loading = state.keeper_calls_loading;
            sbm_calls_error = state.keeper_calls_error;
            sbm_calls = state.keeper_calls;
            sbm_file_changes_keeper = state.msg_file_changes_keeper;
            sbm_file_change_index = state.msg_file_change_index;
            sbm_palette_generation = palette_generation;
            sbm_chat_cols = chat_cols;
            sbm_block = block;
          };
        block
  in
  (* A block with nothing to draw -- every row hidden reasoning, or a log
     of bookkeeping frames only -- is no block: it would move its request's
     corners onto rows that never close. *)
  let settled_blocks =
    Masc_tui_types.settled_logs_for_keeper state keeper_name
    |> List.filter Masc_tui_types.turn_log_holds_the_turn
    |> List.map (held_projection ~committed:true)
    |> List.filter (fun block -> block.lb_entries <> [])
  in
  (* Turns running that this pane did not open, drawn from the journal
     reads that feed their logs ([observed_logs_for_keeper]). Projected
     the way the live block is placed -- uncommitted, so the block sits
     where a running turn's rows go and its rail stays open -- and
     memoised the way a settled block is: the log changes only when a
     journal read lands, not on every frame. *)
  let observed_blocks =
    Masc_tui_types.observed_logs_for_keeper state keeper_name
    |> List.map (fun log ->
        let ended = Masc_tui_types.observed_log_has_ended state log in
        let unavailable = Masc_tui_types.observed_log_is_unavailable state log in
        let block = held_projection ~committed:(ended || unavailable) log in
        let entries = block.lb_entries in
        let entries =
          match unavailable, List.rev entries with
          | true, last :: _ ->
              let style = Message_layout.Status in
              entries @
              (* The status row is not the entry it was copied from, so it
                 names none of that entry's request or attempt. *)
              [{ last with le_origin = None; le_is_reply = false; le_entry = { last.le_entry with style; speaker = "STATUS";
                 body_presentation = Message_layout.Source_body;
                 diagnostics = [];
                 role_label = Message_layout.align_role_label
                   ~column:role_label_column ~style "STATUS";
                 role_label_mark_cells = Message_layout.role_label_mark_cells
                   ~column:role_label_column ~style ();
                 body = "저널 갱신 불가 · 받은 기록을 유지합니다";
                 markdown_source = Message_layout.Markdown_streaming } }]
          | false, _ | true, [] -> entries
        in
        { block with lb_entries = entries })
    |> List.filter (fun block -> block.lb_entries <> [])
  in
  (* Classify the same selected pool that history suppression reads. *)
  let other_live_blocks =
    Masc_tui_types.selected_source_logs_for_keeper state keeper_name
    |> List.filter (fun log ->
        not (Masc_tui_types.turn_log_holds_the_turn log)
        && (not (List.exists (( == ) log) state.msg_settled_logs)
            || List.exists (fun (entry : Masc_tui_types.inflight) -> entry.log == log)
                 state.msg_inflight))
    |> List.map (held_projection ~committed:false)
    |> List.filter (fun block -> block.lb_entries <> [])
  in
  let blocks =
    settled_blocks @ observed_blocks @ other_live_blocks
    |> List.stable_sort (fun left right ->
        let by_position = Int.compare left.lb_insertion right.lb_insertion in
        if by_position <> 0 then by_position
        else match left.lb_timeline_at, right.lb_timeline_at with
          | Some left_at, Some right_at -> Float.compare left_at right_at
          | Some _, None -> -1
          | None, Some _ -> 1
          | None, None -> 0)
  in
  let open_blocks =
    List.filter (fun block ->
      not (Masc_tui_types.observed_log_has_ended state block.lb_log)
      && not (Masc_tui_types.observed_log_is_unavailable state block.lb_log)) blocks
  in
  let committed_tagged =
    List.combine committed_messages committed_layout_entries
    |> List.map (fun (message, entry) -> Tagged_row message, entry)
  in
  (* Persisted inputs and their projected log share exact request metadata.
     Keep each identity once in drawn order without parsing speech or
     removing attempt diagnostics. Shared batch execution IDs follow the
     same rule even when more than one committed request names them. An
     entry that keeps all of its diagnostics is returned as it came. *)
  let once_per_identity tagged =
    let seen_diagnostics = Hashtbl.create 16 in
    let request_owners = chat_request_owners state ~keeper_name in
    List.map (fun (tag, (entry : Message_layout.entry)) ->
      let request_id, execution_id = match tag with
        | Tagged_row message -> message.me_request_id,
            request_owner request_owners message.me_request_id
        | Tagged_block (log, _, _) -> Masc_tui_types.turn_log_request_id log,
            Masc_tui_types.turn_log_execution_id log in
      let identities = request_diagnostics ~tools:state.msg_tool_visibility
          ~request_id ~execution_id in
      let diagnostics = List.filter (fun text ->
        if not (List.mem text identities) then true
        else if Hashtbl.mem seen_diagnostics text then false
        else (Hashtbl.add seen_diagnostics text (); true)) entry.diagnostics in
      if diagnostics = entry.diagnostics then tag, entry
      else tag, {entry with diagnostics}) tagged
  in
  (* Blocks sharing an insertion slot follow their causal timeline clocks.
     Equal clocks preserve source order; unknown clocks follow known ones. *)
  let merge_blocks () =
    let placed =
      List.concat_map (fun block ->
        List.map (fun item ->
          let by_time = chat_block_insertion_index ~member_ids:[]
              ~bounds:(fun _ -> false) ~request_id:block.lb_request_id
              ~timeline_at:item.le_at committed_visible_timeline in
          let insertion = max block.lb_insertion by_time in
          insertion, item.le_at, (Tagged_block (block.lb_log, item.le_origin, item.le_is_reply), item.le_entry))
          block.lb_entries) blocks
      |> List.stable_sort (fun (left, left_at, _) (right, right_at, _) ->
          let by_slot = Int.compare left right in
          if by_slot <> 0 then by_slot
          else match left_at, right_at with
            | Some left, Some right -> Float.compare left right
            | Some _, None -> -1 | None, Some _ -> 1 | None, None -> 0)
    in
    let rec merge index committed placed =
      match committed with
      | [] -> List.map (fun (_, _, item) -> item) placed
      | item :: rest ->
          let due, later = List.partition (fun (at, _, _) -> at <= index) placed in
          List.map (fun (_, _, item) -> item) due @ (item :: merge (index + 1) rest later)
    in
    let merged = once_per_identity (merge 0 committed_tagged placed) in
    (* A turn opens once and closes once, wherever its rows ended up: the
       corners of every request a block belongs to are set here, over the
       merged order, so a block placed before its request's failure row
       continues and the failure row closes, and a block placed last closes
       itself. A live block's turn has not closed: its last row continues
       until the stream ends. Rows of other requests keep the corners the
       entry memo gave them. *)
    let block_requests =
      List.map (fun block -> block.lb_request_id) blocks
    in
    (* Requests whose turn has not closed: the live block's and every
       observed block's. Their last row continues until the stream ends. *)
    let open_request_ids =
      List.map (fun block -> block.lb_request_id) open_blocks
    in
    let request_of = function
      | Tagged_row (message : Masc_tui_types.msg_entry) ->
          (match List.find_opt (fun block ->
              List.mem message.me_request_id block.lb_member_ids) blocks with
           | Some block -> block.lb_request_id
           | None -> message.me_request_id)
      | Tagged_block (log, _, _) -> Masc_tui_types.turn_log_execution_id log
    in
    let edges = Hashtbl.create 16 in
    let close_run ~at_tail request_id indices =
      let remains_open = at_tail && List.mem request_id open_request_ids in
      match List.rev indices with
      | [] -> ()
      | [only] -> Hashtbl.replace edges only (if remains_open then Turn_opens else Turn_alone)
      | first :: rest ->
          Hashtbl.replace edges first Turn_opens;
          List.iteri (fun i index ->
            Hashtbl.replace edges index
              (if i = List.length rest - 1 && not remains_open then Turn_closes else Turn_continues)) rest
    in
    let current = ref None and indices = ref [] in
    List.iteri (fun index (tag, _) ->
      let request_id = request_of tag in
      if request_id <> "" then begin
        if !current <> Some request_id then begin
          Option.iter (fun id -> close_run ~at_tail:false id !indices) !current;
          current := Some request_id;
          indices := []
        end;
        indices := index :: !indices
      end) merged;
    Option.iter (fun id -> close_run ~at_tail:true id !indices) !current;
    List.mapi
      (fun index ((tag, (entry : Message_layout.entry)) as item) ->
        let request_id = request_of tag in
        match Hashtbl.find_opt edges index with
        | Some edge when List.mem request_id block_requests ->
            let siding =
              match tag with
              | Tagged_row message -> siding_of_message message
              | Tagged_block _ -> None
            in
            ( tag
            , { entry with
                Message_layout.request_label = request_id;
                turn_rail =
                  turn_rail_of ~siding ~edge
                    ~style:entry.Message_layout.style
              } )
        | Some _ | None -> item)
      merged
  in
  let tagged_layout_entries, layout_entries =
    match blocks, open_blocks with
    | [], _ -> (
        (* No block to merge is not no identity to repeat: a batch's inputs
           share one execution before any of its output is drawable. Only
           expanded tools draw identities, and an untouched list keeps the
           committed entries' own layout memo. *)
        match state.msg_tool_visibility with
        | Tools_compact | Tools_results -> committed_tagged, committed_layout_entries
        | Tools_full ->
            let tagged = once_per_identity committed_tagged in
            if List.for_all2 (fun (_, kept) (_, came) -> kept == came) tagged committed_tagged
            then committed_tagged, committed_layout_entries
            else tagged, List.map snd tagged)
    | _ :: _, _ :: _ ->
        let merged = merge_blocks () in
        merged, List.map snd merged
    | _ :: _, [] -> (
        match !merged_blocks_memo with
        | Some memo
          when memo.mbm_committed == committed_layout_entries
               && List.length memo.mbm_blocks = List.length blocks
               && List.for_all2 ( == ) memo.mbm_blocks blocks ->
            memo.mbm_merged, memo.mbm_entries
        | Some _ | None ->
            let merged = merge_blocks () in
            let entries = List.map snd merged in
            merged_blocks_memo :=
              Some
                { mbm_committed = committed_layout_entries;
                  mbm_blocks = blocks;
                  mbm_merged = merged;
                  mbm_entries = entries;
                };
            merged, entries)
  in
  (* Unsettled input and polled excerpts occupy the same physical suffix as
     speech. They have no durable search origin, but their height participates
     in every search and scroll-pin measurement. *)
  let polled = polled_turn_output_with_anchors state ~keeper_name ~role_label_column in
  let held = held_polled_for_keeper state keeper_name in
  let polled = List.filter (fun (anchor, _) ->
      not (List.exists (fun excerpt -> excerpt.held_anchor = anchor) held)) polled
    @ List.map (fun excerpt -> excerpt.held_anchor, excerpt.held_entry) held in
  let pending = chat_tail_entries state ~keeper_name ~role_label_column in
  let transient_anchors = List.map (fun (anchor, _) -> Some anchor) polled
    @ List.map (fun (entry : Message_layout.entry) ->
        if entry.request_label = "" then None else Some (Scroll_pending entry.request_label)) pending in
  let layout_entries =
    with_transient_tail layout_entries ~transient:(List.map snd polled @ pending)
  in
  { tagged_entries = tagged_layout_entries; transient_anchors; layout_entries }

let search_reply_source (message : msg_entry) =
  match message.me_role, message.me_turn_phase with
  | (Message_keeper | Message_autonomous), Turn_output ->
      (match message.me_execution_source with
       | Some source -> Some source
       | None ->
           (match message.me_role with
            | Message_keeper -> Some (Masc_tui_keeper_chat_log.Operation message.me_request_id)
            | Message_autonomous ->
                Option.map (fun turn_ref -> Masc_tui_keeper_chat_log.Autonomous_turn turn_ref)
                  (Ids.Turn_ref.of_string message.me_request_id)
            | _ -> None))
  | (Message_user _ | Message_status | Message_local | Message_error
    | Message_tool | Message_skill _ | Message_thinking | Message_memory), _
  | (Message_keeper | Message_autonomous), (Turn_input | Turn_progress | Turn_tool) -> None

let search_anchor_of_tag = function
  | Tagged_row message -> Some (Search_history {
      row_anchor = msg_anchor message; reply_source = search_reply_source message })
  | Tagged_block (log, Some origin, canonical_reply) ->
      Some (Search_journal {
        source = Masc_tui_types.turn_log_execution_source log; origin; canonical_reply })
  | Tagged_block (_, None, _) -> None

type search_index_key =
  | History_identity of msg_identity
  | History_user_slot of string * chat_turn_phase * int
  | History_reply of Masc_tui_keeper_chat_log.journal_source
  | Journal_origin of Masc_tui_keeper_chat_log.journal_source * Masc_tui_keeper_chat_transcript.drawn_origin
  | Journal_reply of Masc_tui_keeper_chat_log.journal_source

let search_index_memo = ref None

let projection_index_of_anchor projection =
  let index = match !search_index_memo with
    | Some (tags, index) when tags == projection.tagged_entries -> index
    | _ ->
        let index = Hashtbl.create 64 in
        let add key at = if not (Hashtbl.mem index key) then Hashtbl.add index key at in
        List.iteri (fun at (tag, _) -> match tag with
          | Tagged_row row ->
              add (History_identity row.me_identity) at;
              (match row.me_role with
               | Message_user _ -> add (History_user_slot (row.me_request_id, row.me_turn_phase, row.me_operation_seq)) at
               | _ -> ());
              Option.iter (fun source -> add (History_reply source) at) (search_reply_source row)
          | Tagged_block (log, origin, canonical) ->
              let source = Masc_tui_types.turn_log_execution_source log in
              Option.iter (fun origin -> add (Journal_origin (source, origin)) at) origin;
              if canonical then add (Journal_reply source) at) projection.tagged_entries;
        search_index_memo := Some (projection.tagged_entries, index);
        index in
  fun anchor ->
    let keys = match anchor with
      | Search_history {row_anchor; reply_source} ->
          History_identity row_anchor.ma_identity
          :: (match row_anchor.ma_session_user_slot with None -> []
              | Some (id, phase, seq) -> [History_user_slot (id, phase, seq)])
          @ (match reply_source with None -> [] | Some source -> [Journal_reply source])
      | Search_journal {source; origin; canonical_reply} ->
          Journal_origin (source, origin)
          :: (if canonical_reply then [History_reply source] else []) in
    List.fold_left (fun earliest key ->
      match earliest, Hashtbl.find_opt index key with
      | None, found | found, None -> found
      | Some left, Some right -> Some (Int.min left right)) None keys

(* The layout reuses its entry list while a projection is unchanged. Keep the
   newest anchor alongside that identity instead of allocating every index on
   idle live-edge paints. Changed source/tail lists get a fresh observation. *)
type scroll_anchor_index = {
  indexed_entries : Message_layout.entry array;
  indexed_anchors : chat_scroll_anchor option array;
  transient_indices : (chat_scroll_anchor, int) Hashtbl.t;
}

let scroll_anchor_index_memo :
    (Message_layout.entry list * scroll_anchor_index) option ref = ref None

let scroll_anchor_index projection =
  match !scroll_anchor_index_memo with
  | Some (entries, anchors) when entries == projection.layout_entries -> anchors
  | Some _ | None ->
      let indexed_anchors = Array.of_list
        (List.map (fun (tag, _) ->
           Option.map (fun anchor -> Scroll_durable anchor) (search_anchor_of_tag tag))
           projection.tagged_entries @ projection.transient_anchors) in
      let transient_indices = Hashtbl.create 8 in
      let offset = List.length projection.tagged_entries in
      List.iteri (fun at -> function
        | Some anchor when not (Hashtbl.mem transient_indices anchor) ->
            Hashtbl.add transient_indices anchor (offset + at)
        | Some _ | None -> ()) projection.transient_anchors;
      (* A pending input is promoted into the durable user row by Run_started.
         The request identity continues to name that same speech position. *)
      List.iteri (fun at (tag, _) -> match tag with
        | Tagged_row row ->
            (match row.me_role, row.me_turn_phase with
             | Message_user _, Turn_input when row.me_request_id <> "" ->
                 let anchor = Scroll_pending row.me_request_id in
                 if not (Hashtbl.mem transient_indices anchor) then
                   Hashtbl.add transient_indices anchor at
             | _ -> ())
        | Tagged_block _ -> ()) projection.tagged_entries;
      let indexed_entries = Array.of_list projection.layout_entries in
      let anchors = {indexed_entries; indexed_anchors; transient_indices} in
      scroll_anchor_index_memo := Some (projection.layout_entries, anchors);
      anchors

let scroll_anchor_at projection index =
  let anchors = (scroll_anchor_index projection).indexed_anchors in
  if index < 0 || index >= Array.length anchors then None else anchors.(index)

let projection_index_of_scroll_anchor projection = function
  | Scroll_durable anchor -> projection_index_of_anchor projection anchor
  | (Scroll_pending _ | Scroll_polled _) as anchor ->
      Hashtbl.find_opt (scroll_anchor_index projection).transient_indices anchor

(* A frame owns one preview snapshot and one semantic map per projected entry.
   Physical row ordinals can change with terminal width or origin gutters;
   only a producer-owned source byte can recover that same reading position. *)
type source_body_index = {
  source_rows : (chat_source_position, int) Hashtbl.t;
  row_sources : (int, chat_source_position) Hashtbl.t;
  row_end_sources : (int, chat_source_position) Hashtbl.t;
}

type source_body_key = {
  source_width : int;
  source_palette_generation : int;
  source_origin : Message_layout.origin_display;
  source_preview_mode : [`Off | `Compact | `Rich];
  source_previews : Masc_tui_link_preview.og_preview list;
  source_polled_input : (int * int * string) option;
  source_polled_unavailable : bool;
}

(* Every field is compared, so a field added to the key and left out here is
   reported as never read. *)
let same_source_body_key (a : source_body_key) (b : source_body_key) =
  a.source_width = b.source_width
  && a.source_palette_generation = b.source_palette_generation
  && a.source_origin = b.source_origin
  && a.source_preview_mode = b.source_preview_mode
  && a.source_previews = b.source_previews
  && a.source_polled_input = b.source_polled_input
  && Bool.equal a.source_polled_unavailable b.source_polled_unavailable

type source_body_memo = { key : source_body_key; index : source_body_index option }

let source_body_indexes = Entry_cache.create 64
let source_index_builds = ref 0

type source_mapping_owner =
  | Durable_source
  | Polled_source of { start_byte : int; mapped : Masc.Tui_terminal_text.mapped_text Lazy.t }
  | Unknown_polled_source

let source_mapping_owner state ~keeper_name projection entry_index =
  match scroll_anchor_at projection entry_index with
  | Some (Scroll_polled (token, generation, Polled_speech)) ->
      (match (let held = held_polled_for_keeper state keeper_name in
        match List.find_opt (fun excerpt -> excerpt.held_anchor =
            Scroll_polled (token,generation,Polled_speech)) held with
        | Some excerpt -> Some excerpt.held_preview
        | None -> preview_for_polled_anchor state keeper_name
            (Scroll_polled (token,generation,Polled_speech))) with
       | None -> Unknown_polled_source, None
       | Some preview ->
           Polled_source {start_byte=preview.ktp_text_position.kpp_start_byte;
             mapped=lazy (Masc.Tui_terminal_text.sanitize_terminal_lines_with_source preview.ktp_text_tail)},
           Some (generation,preview.ktp_text_position.kpp_start_byte,preview.ktp_text_tail))
  | Some (Scroll_polled (_, _, Polled_status)) ->
      (* Activity labels can change within one speech generation. They have
         neither immutable held text nor a producer-owned source identity. *)
      Unknown_polled_source, None
  | Some (Scroll_durable _ | Scroll_pending _) | None ->
      Durable_source, None

let source_body_key state ~width ~theme ~preview ~polled_input ~unavailable
    (entry : Message_layout.entry) =
  let context = Chat_theme.body_context theme entry.Message_layout.style in
  let urls = match entry.style, entry.markdown_source, state.link_previews_mode with
    | (Message_layout.Tool | Skill _), _, _
    | _, (Message_layout.Markdown_growing _ | Markdown_streaming), _
    | _, _, `Off -> []
    | _, Message_layout.Markdown_stable _, (`Compact | `Rich) -> bare_urls_for_entry entry in
  {source_width=width;source_palette_generation=context.palette_generation;
   source_origin=state.msg_origin_display;source_preview_mode=state.link_previews_mode;
   source_previews=List.map preview urls;source_polled_input=polled_input;
   source_polled_unavailable=unavailable}

let source_body_lookup state ~keeper_name projection ~inner_width ~theme ~preview =
  let entries = (scroll_anchor_index projection).indexed_entries in
  let mapped = Hashtbl.create 8 in
  fun entry_index ->
    match Hashtbl.find_opt mapped entry_index with
    | Some value -> value
    | None ->
        let value = if entry_index < 0 || entry_index >= Array.length entries then None else
          let entry = entries.(entry_index) in
          let width = Message_layout.entry_body_cells ~origin:state.msg_origin_display
            ~inner_width entry in
          let owner, polled_input = source_mapping_owner state ~keeper_name projection entry_index in
          let key = source_body_key state ~width ~theme ~preview ~polled_input
            ~unavailable:(owner = Unknown_polled_source) entry in
          match Entry_cache.find_opt source_body_indexes entry with
          | Some memo when same_source_body_key memo.key key -> memo.index
          | Some _ | None ->
          incr source_index_builds;
          let body = search_chat_markdown ~link_previews_mode:state.link_previews_mode
            ~theme ~preview ~entry ~width in
          let index = if body.unavailable || owner = Unknown_polled_source then None else
          let convert = match owner with
            | Durable_source -> (fun position -> Some (Durable_position position))
            | Unknown_polled_source -> (fun _ -> None)
            | Polled_source {start_byte;mapped} ->
                let mapped = Lazy.force mapped in
                let output = Masc.Tui_terminal_text.mapped_text mapped in
                (* The exact shared sanitizer must own this same projection.
                   A stale or inconsistent producer map authorizes no pin. *)
                if not (String.equal output entry.body) then (fun _ -> None) else
                let expansions = Array.make (String.length output) 0 in
                let previous = ref None and expansion = ref 0 in
                for byte = 0 to String.length output - 1 do
                  let source = Masc.Tui_terminal_text.source_byte_at mapped byte in
                  if source = !previous then incr expansion else expansion := 0;
                  previous := source;
                  expansions.(byte) <- !expansion
                done;
                (function
                 | Search.Body_byte {offset;expansion=semantic_expansion} ->
                     Option.map (fun source -> Polled_body_byte {offset=start_byte+source;
                       sanitizer_expansion=expansions.(offset); semantic_expansion})
                       (Masc.Tui_terminal_text.source_byte_at mapped offset)
                 | Body_label _ | Thinking_summary_byte _ | Thinking_summary_label _
                 | Preview_byte _ | Journal_byte _ -> None) in
          let source_rows = Hashtbl.create 64 and row_sources = Hashtbl.create 16 in
          let row_end_sources = Hashtbl.create 16 in
          let body_rows = List.length body.mapped_rows in
          List.iter (fun (run : Search.run) ->
            let _, copied = Masc_tui_theme.strip_sgr_with_positions run.text in
            let visible_bytes = Array.make (String.length run.text) false in
            Array.iter (fun byte -> visible_bytes.(byte) <- true) copied;
            List.iter (fun (row, ranges) ->
              if row >= 0 && row < body_rows then
                List.iter (fun (range : Markdown.source_range) ->
                  for byte = range.start_byte to range.end_byte - 1 do
                    if visible_bytes.(byte) then Option.iter (fun position ->
                      (* A normalized origin can occur more than once. Keep the
                         first actually visible row, matching search's source
                         producer traversal, without electing by source words. *)
                      if not (Hashtbl.mem source_rows position) then Hashtbl.add source_rows position row;
                      if not (Hashtbl.mem row_sources row) then Hashtbl.add row_sources row position;
                      Hashtbl.replace row_end_sources row position)
                      (Option.bind run.positions.(byte) convert)
                  done) ranges) run.visible_rows) body.runs;
          Some {source_rows;row_sources;row_end_sources} in
          Entry_cache.replace source_body_indexes entry {key;index};
          index in
        Hashtbl.add mapped entry_index value;
        value

let body_row_of_point ~source_body entry_index (point : chat_scroll_point) =
  match point.source_position with
  | None -> None
  | Some position -> Option.bind (source_body entry_index) (fun body ->
      Hashtbl.find_opt body.source_rows position)

let source_point_on_row ~source_body entry_index body_row =
  Option.bind (source_body entry_index) (fun body -> Hashtbl.find_opt body.row_sources body_row)

let requested_scroll_from_pin state ~keeper_name projection ~markdown ~source_body ~inner_width =
  if state.msg_scroll = max_int then max_int
  else match state.msg_scroll_pin with
  | Some pin when pin.pin_workspace = state.workspace_authority
      && String.equal pin.pin_keeper keeper_name
      && pin.pin_mode <> Follow_live ->
      (* Every saved byte may have been removed. A stale numeric distance
         must not become a successful pin to newly arriving content. *)
      Option.value ~default:0
        (List.find_map (fun point ->
          Option.bind (projection_index_of_scroll_anchor projection point.scroll_anchor)
            (fun entry_index ->
              Option.bind (body_row_of_point ~source_body entry_index point) (fun body_row ->
                Option.map (fun suffix -> max 0
                  (suffix - point.rows_below + state.msg_scroll - pin.pin_scroll))
                  (Message_layout.scroll_for_body_row ~markdown
                    ~origin:state.msg_origin_display ~inner_width ~entry_index
                    ~body_row projection.layout_entries)))) pin.pin_points)
  | Some _ | None -> state.msg_scroll

let scroll_position_for_window state ~keeper_name projection ~markdown ~source_body ~inner_width
    (window : Message_layout.scroll_window) =
  let live_edge = window.scroll = 0 in
  let positions = if live_edge then List.rev window.body_positions else window.body_positions in
  let points = List.filter_map (fun (position : Message_layout.body_row_position) ->
    Option.bind (scroll_anchor_at projection position.entry_index) (fun anchor ->
      let source = if live_edge then
          Option.bind (source_body position.entry_index) (fun body ->
            Hashtbl.find_opt body.row_end_sources position.body_row)
        else source_point_on_row ~source_body position.entry_index position.body_row in
      Option.map (fun source_position ->
        {scroll_anchor=anchor; body_row=position.body_row; source_position=Some source_position;
         rows_below=position.rows_below}) source)) positions in
  (* Live-edge seeds use the last actually displayed mapped byte. Opening
     rows separated from the tail by a generated gap never elect an offset
     measured through an old, elided physical middle. *)
  let points = if live_edge then (match points with [] -> [] | point::_ -> [point]) else points in
  (* Frame feedback must retain a searched query endpoint, rather than replace
     it with the first byte of whichever physical row is now at the top. An
     explicit scroll gesture changes Hold_search to Hold_scroll at the edge. *)
  let searched_points = match state.msg_scroll_pin with
    | Some pin when pin.pin_mode=Hold_search && pin.pin_workspace=state.workspace_authority
        && String.equal pin.pin_keeper keeper_name ->
        Some (List.filter_map (fun point ->
          Option.bind (projection_index_of_scroll_anchor projection point.scroll_anchor) (fun entry_index ->
            Option.bind (body_row_of_point ~source_body entry_index point) (fun body_row ->
              Option.map (fun suffix -> {point with body_row;rows_below=suffix-window.scroll})
                (Message_layout.scroll_for_body_row ~markdown
                  ~origin:state.msg_origin_display ~inner_width ~entry_index
                  ~body_row projection.layout_entries)))) pin.pin_points)
    | Some _ | None -> None in
  let points,pin_mode = match searched_points with
    | Some (_ :: _ as retained) -> retained,Hold_search
    | Some [] | None -> points,(if window.scroll=0 then Follow_live else Hold_scroll) in
  let held_transients = if pin_mode = Follow_live then [] else
    let previous = held_polled_for_keeper state keeper_name in
    let entries = (scroll_anchor_index projection).indexed_entries in
    List.filter_map (fun point ->
      match point.scroll_anchor with
      | Scroll_polled (_, _, Polled_speech) as anchor ->
          (match List.find_opt (fun excerpt -> excerpt.held_anchor = anchor) previous with
           | Some excerpt -> Some excerpt
           | None -> Option.bind (preview_for_polled_anchor state keeper_name anchor)
               (fun held_preview -> Option.bind (projection_index_of_scroll_anchor projection anchor)
                 (fun index -> if index < 0 || index >= Array.length entries then None else
                   Some {held_anchor=anchor;held_preview;held_entry=entries.(index)})))
      | _ -> None) points
    |> List.sort_uniq (fun left right -> compare left.held_anchor right.held_anchor) in
  let empty_follow_live () = Some {pin_workspace=state.workspace_authority;
    pin_keeper=keeper_name;pin_scroll=0;pin_mode=Follow_live;held_transients=[];pin_points=[]} in
  let pin = match points with
    | _ :: _ -> Some { pin_workspace=state.workspace_authority;
        pin_keeper=keeper_name; pin_scroll=window.scroll; pin_mode; held_transients; pin_points=points }
    | [] ->
        (* Search pins hold even at zero. Follow_live snapshots only seed
           the next scroll key and do not compensate new arrivals. *)
        (match state.msg_scroll_pin with
         | Some pin when pin.pin_workspace=state.workspace_authority
             && String.equal pin.pin_keeper keeper_name ->
             let pin_points = List.filter_map (fun point ->
               Option.bind (projection_index_of_scroll_anchor projection point.scroll_anchor)
                 (fun entry_index ->
                   Option.bind (body_row_of_point ~source_body entry_index point) (fun body_row ->
                     Option.map (fun suffix -> {point with body_row;rows_below=suffix-window.scroll})
                       (Message_layout.scroll_for_body_row ~markdown
                         ~origin:state.msg_origin_display ~inner_width ~entry_index
                         ~body_row projection.layout_entries)))) pin.pin_points in
             (match pin_points with
              | [] -> empty_follow_live ()
              | _ :: _ -> Some {pin with pin_scroll=window.scroll; pin_mode; held_transients; pin_points})
         | Some _ | None -> empty_follow_live ())
  in
  { scroll=(match pin with Some {pin_points=[];pin_mode=Follow_live;_} -> 0
      | Some _ | None -> window.scroll); pin }

(* Search uses exactly the projected speech/activity rows and measures every
   displayed suffix row, including polled notices and pending input. Pending
   inputs and polled excerpts are not committed search candidates: they can
   be edited or replaced without acquiring a conversation identity.

   The repeat cursor uses source identity, never a timestamp, text match or
   viewport index. Reconciliation may remove a text stretch; in that case
   the saved older identities continue the walk without repeating new rows. *)
type chat_search_result = {
  match_result : (chat_scroll_position * chat_search_cursor) option;
  unavailable_entries : int;
}

let keeper_message_find_scroll ?(preview_lookup=Masc_tui_link_preview.get_preview) (state : state) ~keeper_name ~needle ~older_than =
  if String.equal needle "" then {match_result=None;unavailable_entries=0}
  else
    let _, cols = get_terminal_size () in
    let chat_cols =
      Masc_tui_roster_pane.content_cols ~hidden:(roster_pane_hidden state) ~cols
    in
    let projection = keeper_message_projection state ~keeper_name ~chat_cols in
    let tagged = projection.tagged_entries in
    let index_of = projection_index_of_anchor projection in
    let inner_width = max 1 (framed_inner_width chat_cols) in
    let theme=Chat_theme.snapshot () in
    let preview=preview_snapshot preview_lookup in
    let unavailable_entries=ref 0 in
    let markdown=cached_chat_markdown_with_preview ~preview ~link_previews_mode:state.link_previews_mode ~theme in
    let ceiling, repeat = match older_than with
      | None -> List.length tagged, None
      | Some cursor when cursor.search_workspace <> state.workspace_authority
          || not (String.equal cursor.search_keeper keeper_name) ->
          List.length tagged, None
      | Some cursor ->
          (match index_of cursor.matched_anchor with
           | Some index -> index + 1, Some (index, cursor.matched_position)
           | None ->
               Option.value ~default:0
                 (List.find_map (fun anchor ->
                    Option.map (fun index -> index + 1) (index_of anchor))
                    cursor.older_anchors), None)
    in
    (* Thread the chronological predecessor through one walk. Looking it up
       again from the list head per candidate made a missing query quadratic. *)
    let rec candidates index previous acc = function
      | [] -> acc
      | _ when index >= ceiling -> acc
      | (tag, entry) :: rest ->
          candidates (index + 1) (Some entry) ((index, tag, entry, previous) :: acc) rest
    in
    let matched =
      candidates 0 None [] tagged
      |> List.find_map (fun (index, tag, (entry : Message_layout.entry), previous) ->
           Option.bind (search_anchor_of_tag tag) (fun anchor ->
               let mapped=ref None in
               let observe ~entry ~width =
                 let body=search_chat_markdown ~link_previews_mode:state.link_previews_mode ~theme ~preview ~entry ~width in
                 mapped:=Some body;
                 body.mapped_rows in
               let rows=Message_layout.rows_of_entry ~markdown:observe
                 ~origin:state.msg_origin_display ~inner_width ~previous entry in
               match !mapped with
               | None -> incr unavailable_entries; None
               | Some body when body.unavailable -> incr unavailable_entries; None
               | Some body ->
                   let body_rows=List.fold_left (fun count (row : Message_layout.row) ->
                     match row.kind with Body -> count+1 | Metadata _ | Viewport_gap _ -> count) 0 rows in
                   let before=match repeat with
                     | Some (at,position) when at=index -> Some position | _ -> None in
                   Option.map (fun (found : Search.matched) -> index,anchor,found.body_row,found.position,found.ending_position)
                     (Search.find ~needle ~before ~body_rows body.runs)))
    in
    let match_result=match matched with
    | None -> None
    | Some (at, matched_anchor, body_row, matched_position, ending_position) ->
        let older_anchors = tagged |> List.take at
          |> List.filter_map (fun (tag, _) -> search_anchor_of_tag tag) |> List.rev in
        Option.map (fun scroll ->
          let pin = Some {pin_workspace=state.workspace_authority; pin_keeper=keeper_name;
            pin_scroll=scroll; pin_mode=Hold_search;
            held_transients=[]; pin_points=[{scroll_anchor=Scroll_durable matched_anchor; body_row;
              source_position=Some (Durable_position ending_position); rows_below=0}]} in
          {scroll; pin}, {search_workspace=state.workspace_authority;
            search_keeper=keeper_name; matched_anchor; matched_position; older_anchors})
          (Message_layout.scroll_for_body_row ~markdown ~origin:state.msg_origin_display
            ~inner_width ~entry_index:at ~body_row projection.layout_entries)

    in
    {match_result;unavailable_entries= !unavailable_entries}


let render_keeper_message (state : state) =
  (* The chat draws its own composer and footer instead of taking the shared
     composer row. Its columns are every surface's: the terminal less the
     Activity pane, which [finish_frame_beside_acting_pane] draws beside it. *)
  let rows, cols = get_terminal_size () in
  let buf = Buffer.create 4096 in

  match state.msg_target_keeper_name with
  | None ->
    Buffer.add_string buf "No keeper selected.\n";
    finish_frame_beside_acting_pane state ~surface_key:"keeper-message" ~cursor:Frame_presenter.Hidden
      ~rows ~cols buf
  | Some keeper_name ->
    let chat_theme = Chat_theme.snapshot () in
    let display_keeper_name = Keeper_chat.terminal_safe_text keeper_name in
    let target_registered =
      keeper_available_for_new_message state keeper_name
    in
    (* Wide terminals keep the roster beside the chat, exactly as the detail
       view does; the chat lays out against its own pane width. *)
    let split = keeper_roster_pane_shown state ~cols in
    let chat_cols =
      Masc_tui_roster_pane.content_cols ~hidden:(roster_pane_hidden state) ~cols
    in
    let projection = keeper_message_projection state ~keeper_name ~chat_cols in
    let inner_width = max 1 (framed_inner_width chat_cols) in
    let preview = preview_snapshot Masc_tui_link_preview.get_preview in
    let markdown = cached_chat_markdown_with_preview ~preview
      ~link_previews_mode:state.link_previews_mode ~theme:chat_theme in
    let source_body = source_body_lookup state ~keeper_name projection ~inner_width ~theme:chat_theme ~preview in
    let requested = requested_scroll_from_pin state ~keeper_name projection
      ~markdown ~source_body ~inner_width in
    (* A search can pin a short conversation at scroll zero. If an arrival
       precedes its first paint, the pin already restores a reading position
       although the stored scroll is still zero. Reserve and draw its chrome
       from that same requested position, before measuring the history. *)
    let command_window = keeper_message_command_window ~scroll:requested state
      ~terminal_rows:rows ~terminal_cols:cols in
    let command_rows = match command_window with None -> 0 | Some (_, entries) -> 2 + List.length entries in
    let status_rows = keeper_message_status_rows ~scroll:requested state
      ~terminal_cols:cols + command_rows in
    let support_status_rows =
      keeper_message_support_status_rows ~scroll:requested state ~status_rows
    in
    let title, mode_suffix =
      (* Both features put a mode indicator here: memory arrived on main
         (#30401) while this branch was open. Neither is dropped, but only a
         mode away from its default is spelled -- see
         [Tui_types.chat_visibility_summary] for why. *)
      let modes =
        chat_visibility_summary ~memory:state.msg_memory_visibility
          ~origin:state.msg_origin_display
          ~reasoning:state.msg_reasoning_visibility
          ~tools:state.msg_tool_visibility
      in
      let diff_status =
        let snapshot_status ~stale snapshot =
          let missing_ids =
            Keeper_chat_diff.missing_execution_ids
              state.msg_file_change_index
          in
          let ambiguous_ids =
            Keeper_chat_diff.ambiguous_execution_ids
              state.msg_file_change_index
          in
          let gaps =
            [ ( snapshot.Masc.Tui_decode.fcs_over_budget
              , "oversized" )
            ; (snapshot.Masc.Tui_decode.fcs_malformed, "malformed")
            ; (missing_ids, "no execution id")
            ; (ambiguous_ids, "duplicate execution ids")
            ]
            |> List.filter_map (fun (count, label) ->
              if count = 0 then None
              else Some (Printf.sprintf "%d %s" count label))
          in
          Printf.sprintf "diffs %.0fh%s%s"
            snapshot.Masc.Tui_decode.fcs_window_hours
            (if stale then " stale" else "")
            (match gaps with
             | [] -> ""
             | gaps -> " partial · " ^ String.concat " · " gaps)
        in
        match state.msg_tool_visibility with
        | Tools_compact | Tools_results -> ""
        | Tools_full ->
            if
              not
                (Option.equal String.equal state.msg_file_changes_keeper
                   (Some keeper_name))
            then "diffs pending"
            else if state.msg_file_changes_loading
                    && Option.is_none state.msg_file_changes
            then "diffs loading"
            else
              match state.msg_file_changes_error, state.msg_file_changes with
              | Some _, Some snapshot -> snapshot_status ~stale:true snapshot
              | Some _, None -> "diffs unavailable"
              | None, Some snapshot -> snapshot_status ~stale:false snapshot
              | None, None -> "diffs pending"
      in
      let call_status =
        match state.msg_tool_visibility, state.keeper_calls_error with
        | (Tools_results | Tools_full), Some _
          when state.keeper_calls_keeper = Some keeper_name ->
            (match state.keeper_calls with
             | Some snapshot when String.equal snapshot.kcs_keeper keeper_name ->
                 "results stale · refresh failed"
             | Some _ | None -> "results unavailable")
        | (Tools_compact | Tools_results | Tools_full), _ -> ""
      in
      let modes =
        [ modes; diff_status; call_status ]
        |> List.filter (fun item -> not (String.equal item ""))
        |> String.concat " · "
      in
      let title =
        Printf.sprintf "%s Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 chat%s"
          (Theme.recede ()) display_keeper_name Ansi.reset
      in
      let mode_suffix =
        if String.equal modes "" then ""
        else Printf.sprintf "  %s%s%s" Ansi.dim modes Ansi.reset
      in
      title, mode_suffix
    in
    let inner_cells = framed_inner_width chat_cols in
    (* Navigation stays above the conversation. The selected Keeper's status
       spans the full surface below both panes; the roster must not consume
       the width needed to identify the runtime the composer will address. *)
    let telemetry_cells = max 0 (cols - 1) in
    let telemetry_keeper =
      Masc_tui_theme.tone Masc_tui_theme.Accent
      ^ fit_runtime_id (telemetry_cells / 3) display_keeper_name ^ Ansi.reset ^ " · "
    in
    let telemetry_identity_cells =
      max 0 (telemetry_cells - Message_layout.display_width telemetry_keeper)
    in
    let title_row =
      Message_layout.chat_title_row ~inner_cells ~title ~mode_suffix
    in
    let context_separator = "  " in
    let context_item =
      if not target_registered then None
      else
        match
          Context_state.reading_for_keeper ~keeper_name state.live_context
        with
        | Some { observation = Some observation; error = None } ->
            Observation_layout.context_header_item
              ~max_cells:(min 48 (telemetry_identity_cells / 2))
              ~inspect_key:Masc_tui_keys.context_inspector_label observation
        | Some {error = Some _; _} -> Some "Context unavailable"
        | Some _ | None -> Some "Context —"
    in
    let context_cells =
      match context_item with
      | None -> 0
      | Some item ->
          Message_layout.display_width context_separator
          + Message_layout.display_width item
    in
    (* A Librarian that keeps failing is a state of this keeper's memory. It
       is said here, once, for as long as the run lasts, instead of as a row
       between every pair of turns ([project_memory_history]). It takes at
       most half of what the context item leaves; the runtime id in the
       identity yields first, as it does to the context item. *)
    let librarian_item =
      Option.map
        (fun (failing : Masc_tui_types.librarian_failing) ->
          fit_width
            (Masc_tui_types.librarian_failing_text
               ~since:(keeper_message_clock failing.lf_since) failing)
            (max 0 ((telemetry_identity_cells - context_cells) / 2)))
        (Masc_tui_types.librarian_failing (chat_rows_for state keeper_name))
    in
    let librarian_cells =
      match librarian_item with
      | None -> 0
      | Some item ->
          Message_layout.display_width context_separator
          + Message_layout.display_width item
    in
    let identity =
      keeper_message_identity
        ~max_cells:(max 0 (telemetry_identity_cells - context_cells - librarian_cells))
        state keeper_name
    in
    let identity_row =
      String.concat ""
        ((telemetry_keeper ^ identity)
         :: List.filter_map Fun.id
              [ Option.map
                  (fun item ->
                    context_separator ^ Theme.warn () ^ item ^ Ansi.reset)
                  librarian_item
              ; Option.map
                  (fun item -> context_separator ^ item ^ Ansi.reset)
                  context_item
              ])
    in
    if
      not
        (Message_layout.message_viewport_supported ~terminal_rows:rows
           ~terminal_cols:chat_cols ~status_rows:support_status_rows)
    then begin
      let notice =
        " Keeper chat needs a larger terminal; resize to type (Esc:back)"
      in
      Buffer.add_string buf
        (Message_layout.fit_width notice (max 1 (cols - 1)));
      finish_frame_beside_acting_pane state ~surface_key:"keeper-message"
        ~cursor:Frame_presenter.Hidden ~rows ~cols buf
    end else begin
    let chat_buf = if split then Buffer.create 4096 else buf in
    (* Header *)
    box_top chat_buf chat_cols;
    box_line chat_buf chat_cols title_row;
    box_divider chat_buf chat_cols;

    (* Message history. The fixed chrome is 8 rows — box top, navigation row,
       its divider, the input divider, composer's first line, box bottom,
       runtime/context row and key footer — and every variable row (status, sending, queue, errors,
       composer growth) is in [status_rows]. The old constant 10 reserved
       two rows nothing drew, so the pane stopped two short of the
       terminal's bottom edge. [message_viewport_supported] requires the same
       eight-row chrome plus three history rows, so a live-edge omission can
       still show its first row, typed gap, and latest row. *)
    let history_height =
      Message_layout.message_history_height ~terminal_rows:rows ~status_rows
    in
    let layout_entries = projection.layout_entries in
    (* Clamped here rather than where the key is handled: the limit depends on
       the terminal width and the pane's height, and a resize changes both
       under a scroll position that was legal before it. *)
    let window =
      Message_layout.clamped_scrolled_rows ~markdown
        ~origin:state.msg_origin_display ~inner_width ~height:history_height
        ~requested layout_entries
    in
    let scroll = window.scroll and visible_rows = window.rows in
    let scroll_feedback = scroll_position_for_window state ~keeper_name projection
      ~markdown ~source_body ~inner_width window in

    (* The chat buffer starts below the one-row tab strip, which is added by
       [finish_frame_beside_acting_pane]. Mouse reports count from the terminal's
       first row, so include that strip and the one-based row conversion. *)
    chat_history_first_row := count_frame_lines chat_buf + 2;
    chat_history_actions :=
      Array.of_list
        (List.map
           (fun (row : Message_layout.row) -> row.Message_layout.action)
           visible_rows);
    if visible_rows = [] then begin
      if history_height > 0 then
        box_line_styled chat_buf chat_cols ~style:(Theme.recede ())
          "  (no messages yet -- type below and press Enter)";
      for _ = 1 to history_height - 1 do
        box_empty chat_buf chat_cols
      done
    end else begin
      List.iter
        (render_chat_row ~theme:chat_theme ~tool_visibility:state.msg_tool_visibility
           chat_buf chat_cols)
        visible_rows;
      (* Fill remaining space *)
      for _ = List.length visible_rows to history_height - 1 do
        box_empty chat_buf chat_cols
      done
    end;

    (* The operator's unsettled lines used to be drawn here, between the
       history and the composer. They are entries in the history now -- see
       [chat_tail_entries] -- so the conversation holds one time axis and
       these rows scroll with the lines they follow. *)

    (* Input area divider *)
    box_divider chat_buf chat_cols;

    (* Input line *)
    List.iter
      (fun (mine, line) ->
        box_line_styled chat_buf chat_cols
          ~style:(if mine then Theme.warn () else Theme.recede ()) line)
      (Masc_tui_types.keeper_message_inflight_rows state ~chat_cols
         ~now:(Unix.gettimeofday ()));
    (* The lead -- the mark, the lane, the age -- in the status colour; the
       detail after it receded. Drawn whole in the status colour, five rows of
       band read as five warnings and none stood out. *)
    (* The keys are fitted first and the detail takes what is left, so a
       long preview status loses its tail rather than the keys after it. *)
    List.iter
      (fun (row : Masc_tui_answering.chat_activity_row) ->
        let keys = match state.msg_tool_visibility, Masc_tui_types.keeper_message_status_log state with
          | (Tools_compact | Tools_results), Some live
            when state.msg_target_keeper_name = Some (Masc_tui_types.turn_log_keeper_name live)
              && Masc_tui_types.keeper_message_folded_status_count state live.tl_transcript
                   ~now:(Unix.gettimeofday ()) > 0 ->
              row.keys ^ " · " ^ Masc_tui_keys.expand_turn_label
          | (Tools_full | Tools_compact | Tools_results), _ -> row.keys in
        let lead_room = max 0 (framed_inner_width chat_cols - 2
          - Message_layout.display_width keys) in
        let lead =
          if Message_layout.display_width row.lead <= lead_room then row.lead
          else fit_width row.lead lead_room in
        let room = lead_room - Message_layout.display_width lead in
        let rest =
          if Message_layout.display_width row.rest <= room then row.rest
          else fit_width row.rest (max 0 room)
        in
        box_line chat_buf chat_cols
          (Printf.sprintf "  %s%s%s%s%s%s%s"
             (match state.msg_tool_visibility with Tools_full -> Theme.warn ()
              | Tools_compact | Tools_results ->
                  if Masc_tui_types.keeper_message_activity_needs_attention state
                  then Theme.warn () else Theme.recede ()) lead Ansi.reset
             (Theme.recede ()) rest keys Ansi.reset))
      (Masc_tui_types.keeper_message_activity_rows state);
    List.iter (fun text -> box_line_styled chat_buf chat_cols ~style:(Theme.warn ()) ("  " ^ text))
      (Masc_tui_types.keeper_observed_interrupt_rows state);
    (match state.msg_loaded_error with
     | Some _ ->
         box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
           "  History load failed · /errors"
     | None -> ());
    (if state.msg_loaded_dropped > 0 then
       box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
         (Printf.sprintf
            "  %d saved row(s) could not be read and are not shown"
            state.msg_loaded_dropped));
    (match state.msg_memory_visibility, state.msg_memory_error with
     | Memory_hidden, _ -> ()
     | (Memory_summary | Memory_full), None -> ()
     | (Memory_summary | Memory_full), Some _ ->
         box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
           "  Memory load failed · /errors");
    (if state.msg_memory_visibility <> Memory_hidden
        && state.msg_memory_dropped > 0 then
       box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
         (Printf.sprintf
            "  %d memory journal row(s) could not be read and are not shown"
            state.msg_memory_dropped));
    (* Where the pane is, when it is not at the newest row. The distance and
       the key back are what the footer used to carry seventh of nine hints,
       and the footer drops hints from its tail: on a narrow pane the one
       fact that changes what the arrow keys do was among the first to go.
       The row is drawn from [scroll], which is the clamped position the
       frame actually used, so it cannot claim a distance the pane did not
       move. [keeper_message_status_rows] reserves it on the same condition.

       At the oldest row with nothing more to fetch the distance says less
       than "start" does, which is the same reading [scroll_hint] takes. *)
    (* Drawn on the restored position, which is what the budget above counted;
       worded from the clamped one, which is where the frame actually is. The
       two agree except on the single frame after a shrinking history forces a
       clamp, and there the row says so rather than reporting a distance the
       pane did not move. *)
    (if Masc_tui_types.keeper_message_reading_back ~scroll:requested state then
       box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
         (if scroll <= 0 then
            "  \xe2\x86\x93 back at the newest row"
          else if state.msg_older_exist then
            Printf.sprintf
              "  \xe2\x86\x91 reading back %d row(s) \xc2\xb7 Ctrl-E returns to the newest"
              scroll
          else
            "  \xe2\x86\x91 the start of this conversation \xc2\xb7 Ctrl-E returns to the newest"));
    (* The row [keeper_message_status_rows] reserves for the older-page
       fetch. Counting it without drawing it floated the footer a row up,
       and a failed page load was silent -- the one thing it must not be. *)
    (if state.msg_older_loading then
       box_line_styled chat_buf chat_cols ~style:(Theme.recede ())
         "  (loading older messages\xe2\x80\xa6)"
     else
       match state.msg_older_error with
       | Some _ ->
           box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
             "  Older load failed · /errors"
       | None -> ());
    (match Masc_tui_types.keeper_message_status_log state with
     | Some live
       when state.msg_target_keeper_name
            = Some (Masc_tui_types.turn_log_keeper_name live) ->
         let live = live.tl_transcript in
         (* The streaming turn is the row the eye waits on: drawn in the
            accent rather than dimmed, behind the mark a running turn wears
            everywhere else on the screen.

            It wore a second one -- four braille frames of its own, stepped
            from the wall clock by the whole second. The screen repaints every
            150ms while a turn runs, so six or seven consecutive frames drew
            the same glyph and then jumped, and the four frames chosen are not
            adjacent in the braille rotation, so the jump did not read as
            turning either. [activity_frame] is the counter that ticker
            advances, and stepping from it means one repaint, one frame. *)
         let running_mark, progress_heading =
           match Keeper_chat_transcript.phase live with
           | Keeper_chat_transcript.Waiting -> "○", "WAITING TO START"
           | Working ->
               let heading =
                 if Keeper_chat_transcript.attempt live > 0 then
                   "TURN · IN PROGRESS ON NEXT CANDIDATE"
                 else
                   "TURN · IN PROGRESS"
               in
               Masc_tui_answering.running_glyph ~frame:state.activity_frame,
               heading
           | Stream_ended -> "○", "FINALIZING"
           | Stream_failed _ -> "!", "REQUEST ERROR"
         in
         (* The age belongs to the progress row, which already ends with it
            (masc #29229 pins that a turn which never started still reports
            one). Printing it here too put the same number twice in one line,
            and a number that repeats reads as a frozen screen rather than a
            clock. *)
         (* An operator who has typed while a turn runs is about to press
            Enter and does not know what it will do. The footer says it, forty
            columns away from the caret; said here it is beside the line that
            is holding them up. Only while there is something to queue. *)
         let queue_hint =
           if Masc_tui_message_input.length state.msg_input > 0 then
             (match send_disposition state ~keeper_name with
              | Updates _ -> " · Enter:send update; Ctrl-T:queue"
              | Sends -> " · Enter:send")
           else ""
         in
         (* The gate and the prompt describe the same held call. Drawn apart,
            one row asked the operator to answer while another said a judge
            was deciding, and neither said how they related — so the screen
            read as two authorities waiting on each other. The prompt says
            which one holds the call and that the operator's key still ends
            it. *)
         let gate_note =
           match
             Masc_tui_types.keeper_effects_at_the_gate state
               ~keeper_name:(Keeper_chat_transcript.keeper_name live)
           with
           | [] -> ""
           | pending -> (
             let judging =
               List.find_opt
                 (fun (row : Tui_decode.gate_pending) ->
                   row.gp_phase = Tui_decode.Gate_judging)
                 pending
             in
             match judging with
             | None -> ""
             | Some row ->
               let age =
                 match row.gp_waiting_s with
                 | Some seconds -> " " ^ Masc_tui_answering.duration_text seconds
                 | None -> ""
               in
               Printf.sprintf " · the judge is deciding%s; your answer ends it now" age)
         in
         (* What the fold took, said on the line that stays. A count the
            reader can see is a thing they can ask for; rows that simply were
            not drawn are a screen that looks complete and is not. *)
         let now = Unix.gettimeofday () in
         let folded_away =
           Masc_tui_types.keeper_message_folded_status_count state live ~now
         in
         let gate_waiting =
           match state.msg_target_keeper_name with
           | Some keeper_name when state.msg_turn_folded ->
               List.length
                 (Masc_tui_types.keeper_effects_at_the_gate state ~keeper_name)
           | Some _ | None -> 0
         in
         let fold_suffix =
           let parts =
             (if gate_waiting > 0 then [ Printf.sprintf "gate %d" gate_waiting ]
              else [])
             @ (if folded_away > 0 then [ Printf.sprintf "+%d" folded_away ]
                else [])
           in
           match parts with
           | [] -> ""
           | parts ->
               " · " ^ String.concat " · " parts ^ " · "
               ^ Masc_tui_keys.expand_turn_label
         in
         List.iter
           (fun (kind, text) ->
             (match kind with
              | Keeper_chat_transcript.Progress ->
                  box_line_styled chat_buf chat_cols ~style:(Masc_tui_theme.tone Masc_tui_theme.Accent)
                    ("  " ^ running_mark ^ " " ^ Ansi.bold ^ progress_heading
                     ^ Ansi.reset ^ (Masc_tui_theme.tone Masc_tui_theme.Accent)
                     ^ " · " ^ text ^ queue_hint ^ fold_suffix)
              (* The gate and this row describe the same held call, so the
                 note rides the row that asks -- which is this one by its
                 kind now, rather than by being first among the Attention
                 rows and hoping the order holds. *)
              | Keeper_chat_transcript.Answer_needed ->
                  box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
                    ("  " ^ text ^ gate_note)
              | Keeper_chat_transcript.Attention ->
                  box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
                    ("  " ^ text)
              | Keeper_chat_transcript.Approval outcome ->
                  let style =
                    match outcome with
                    | Keeper_chat_transcript.Approved -> Theme.ok ()
                    | Keeper_chat_transcript.Denied
                    | Keeper_chat_transcript.Timed_out
                    | Keeper_chat_transcript.Displaced
                    | Keeper_chat_transcript.Approval_other _ -> Theme.warn ()
                  in
                  box_line_styled chat_buf chat_cols ~style ("  " ^ text)))
           (Masc_tui_types.keeper_message_visible_status_rows state live ~now)
     | Some _ | None -> ());
    (* Effects this Keeper is not waiting on. A deferral returns successfully
       and the Keeper carries on, so the tool row reads as a plain return and
       nothing else on this pane said the effect was still out. The phase
       vocabulary and the age are the Approvals screen's own, so the two
       surfaces cannot disagree about a row they both hold. *)
    (match state.msg_target_keeper_name with
     | None -> ()
     | Some keeper_name -> (
         match keeper_effects_at_the_gate state ~keeper_name with
         | [] -> ()
         | pending ->
             let severity (row : Tui_decode.gate_pending) =
               match row.gp_phase with
               | Tui_decode.Gate_blocked -> 3
               | Tui_decode.Gate_human_required -> 2
               | Tui_decode.Gate_queued -> 1
               | Tui_decode.Gate_judging -> 0
             in
             let worst =
               List.fold_left
                 (fun worst row ->
                   if severity row > severity worst then row else worst)
                 (List.hd pending) (List.tl pending)
             in
             let style =
               match worst.gp_phase with
               | Tui_decode.Gate_blocked -> Theme.bad ()
               | Tui_decode.Gate_queued | Tui_decode.Gate_human_required ->
                   Theme.warn ()
               | Tui_decode.Gate_judging -> Theme.info ()
             in
             let named =
               List.map
                 (fun (row : Tui_decode.gate_pending) ->
                   let phase =
                     match row.gp_phase with
                     | Tui_decode.Gate_queued -> "queued"
                     | Tui_decode.Gate_judging -> "judging"
                     | Tui_decode.Gate_human_required -> "human"
                     | Tui_decode.Gate_blocked -> "blocked"
                   in
                   let age =
                     match row.gp_waiting_s with
                     | Some seconds -> Masc_tui_answering.duration_text seconds
                     | None -> Masc_tui_theme.Glyph.no_value
                   in
                   Printf.sprintf "%s %s %s"
                     (Keeper_chat.terminal_safe_text row.gp_display_tool)
                     age phase)
                 pending
             in
             let count = List.length pending in
             box_line_styled chat_buf chat_cols ~style
               (Printf.sprintf "  AT THE GATE · %d external effect%s out · %s"
                  count
                  (if count = 1 then "" else "s")
                  (String.concat " · " named))));
    if not target_registered then begin
      let unavailable_message =
        match state.keepers_error with
        | Some _ ->
            "  Keeper roster is unavailable; draft retained; Esc to choose another"
        | None ->
            Printf.sprintf
              (if state.keeper_creation_awaiting_roster = Some keeper_name then
                 "  Keeper %s: creation accepted; roster confirmation pending; draft retained; Esc then r to refresh"
               else "  Keeper %s is no longer registered; draft retained; Esc to choose another")
              display_keeper_name
      in
      box_line_styled chat_buf chat_cols ~style:(Theme.bad ()) unavailable_message
    end;
    (match command_window with
     | None -> ()
     | Some (menu, entries) ->
       box_line_styled chat_buf chat_cols ~style:(Theme.recede ())
         (Printf.sprintf "  Commands  %d/%d" (menu.selected + 1) (List.length menu.items));
       let label_cells = min 26 (max 8 ((framed_inner_width chat_cols - 5) / 3)) in
       List.iter (fun (selected, (item : Masc_tui_command.menu_item)) ->
         let label = fit_width (Terminal_text.single_line item.label) label_cells in
         let marker = if selected then "› " else "  " in
         let content = "  " ^ marker ^ label ^ "  "
           ^ Terminal_text.single_line item.description in
         if selected then box_line_selected chat_buf chat_cols content
         else box_line_styled chat_buf chat_cols ~style:(Theme.recede ()) content) entries;
       box_divider chat_buf chat_cols);
    let input = Masc_tui_message_input.contents state.msg_input in
    let composer = Message_layout.composer_window
      ~max_rows:Message_layout.composer_max_rows ~max_cells:(max 0 (chat_cols - 8))
      ~cursor:(Masc_tui_message_input.cursor state.msg_input) input in
    (* Where the composer landed, not where a second copy of the pane's
       arithmetic predicted it would. The prediction only held while every row
       the pane drew was also counted in [keeper_message_status_rows]; a
       queued line was drawn and not counted, so the prompt moved down and the
       caret did not. Reading the rows already in the frame, with the same
       [frame_lines] that builds it, cannot disagree with it. *)
    let rows_above_composer = count_frame_lines chat_buf in
    List.iteri
      (fun index line ->
        (* Only the first line carries the prompt; the rest line up under it so
           a wrapped thought reads as one message rather than several. The
           prefix here is the one [Message_layout.input_cursor_column] measures
           the caret from, so both say the same constant. *)
        let prefix =
          if index = 0 then Message_layout.chat_input_prompt_prefix else "    "
        in
        (* Recede may use SGR dim when the terminal palette is unknown. Reset
           that weight before the draft and reopen its background, so only
           the prompt recedes and typed text retains the terminal foreground. *)
        box_line_styled chat_buf chat_cols ~style:chat_theme.Chat_theme.user_background
          (Theme.recede () ^ prefix ^ Ansi.reset
           ^ chat_theme.Chat_theme.user_background ^ line))
      composer.lines;

    let input_row =
      min (max 1 rows) (rows_above_composer + composer.cursor_row + 1)
    in

    (* Reuse the existing bottom spacer as input padding: the input has a
       clear surface without taking another row from conversation history. *)
    box_line_styled chat_buf chat_cols ~style:chat_theme.Chat_theme.user_background "";
    (* Footer *)
    let disposition = send_disposition state ~keeper_name in
    let pending_count =
      Masc_tui_keeper_chat_queue.length_for_keeper state.msg_queued
        ~keeper_name
    in
    let enter_hint =
      (* What the key does is read once, by [send_disposition]; the in-flight
         kind only names what is happening while it does it. Answering both
         here from a subset of the state is what let the footer say
         [Enter:blocked] on a screen that also showed "queued 1". *)
      let queue_hint () =
        (* Walking back onto a waiting line makes the next Enter a replacement
           rather than a second copy. The operator has to be told which of the
           two this Enter is: the composer looks identical either way. *)
        match state.msg_recall_replaces with
        | Some _ -> "Enter:replace the queued line  Ctrl-U:leave it queued"
        | None -> (
            match pending_count with
            | 0 -> "Enter:send update"
            | waiting ->
                if state.msg_tool_visibility = Tools_full then
                  Printf.sprintf
                    "Enter:send update (%d local)  Ctrl-T:queue  Ctrl-K:cancel  Ctrl-P:edit"
                    waiting
                else "Enter:send update  Ctrl-T:queue  Ctrl-K:cancel  Ctrl-P:edit")
      in
      match disposition with
      | Updates _ -> queue_hint ()
      | Sends ->
          if target_registered then "Enter:send"
          else if Option.is_some state.keepers_error then
            "Enter:disabled (roster unavailable)"
          else "Enter:disabled (Keeper unavailable)"
    in
    let scroll_hint =
      Message_layout.scroll_hint ~scrolled_back:scroll
        ~older_exist:state.msg_older_exist
    in
    (* Beside the keys, not among them. The fitter gives up key items from the
       back, and this is the one item on the row that [?] cannot recover. *)
    let scroll_position =
      Message_layout.scroll_position ~scrolled_back:scroll
        ~older_exist:state.msg_older_exist
    in
    let return_hint () =
      match state.msg_return with
      | Keeper_chat_return_home -> "Esc:Dashboard"
      | Keeper_chat_return_list -> "Esc:list"
      | Keeper_chat_return_detail -> "Esc:detail"
    in
    (* The hint is the dispatch's own table, not a retelling of it: both read
       Masc_tui_esc_interrupt.action, so the footer cannot advertise an
       interrupt Esc will not spend itself on, nor say "interrupt sent" after
       the grace window when Esc would leave. *)
    let escape_hint =
      let action = Option.bind state.msg_target_keeper_name (fun keeper_name ->
        match Masc_tui_types.working_chat_for_keeper state keeper_name with
        | Some entry -> Some (Masc_tui_types.working_chat_interrupt_action
            ~now_ns:(Mtime_clock.elapsed_ns ()) state keeper_name entry)
        | None -> Masc_tui_types.keeper_observed_interrupt_action state keeper_name) in
      match action with
      | Some Masc_tui_esc_interrupt.Launch_interrupt -> "Esc:stop current turn"
      | Some Swallow -> "Esc:interrupt requested"
      | Some Leave -> return_hint ()
      | None ->
        match state.msg_live with
        | Some live ->
          (match Masc_tui_esc_interrupt.action ~now_ns:(Mtime_clock.elapsed_ns ())
            (Keeper_chat_transcript.interrupt live.tl_transcript) with
           | Launch_interrupt -> "Esc:interrupt turn"
           | Swallow -> "Esc:interrupt sent"
           | Leave -> return_hint ())
        | None -> return_hint ()
    in
    (* Match the visible composer's key predicate, including staged media
       and whether a turn is active. Ctrl-Q remains available while typing. The compact footer omits this hint for width, but the
       help sheet names both keys. *)
    let leave_hint =
      if state.keeper_message_focus = Right_pane
         && Option.is_none state.msg_recall_replaces
         && Option.is_none state.voice_capture
      then
        if Masc_tui_keys.chat_quiet_leave ~input_supported:true
             ~turn_active:(keeper_message_turn_active state)
             ~draft_empty:(keeper_message_draft_empty state) "Q"
        then "  Q / Ctrl-Q:leave"
        else "  Ctrl-Q:leave"
      else ""
    in
    let switch_hint =
      match next_keeper_message_target state with
      | Masc_tui_keeper_selection.No_alternative -> ""
      | Masc_tui_keeper_selection.Switch_to _ -> "  Ctrl-G:next Keeper"
    in
    (* A composer holding a slash word gets a footer about that word instead
       of the key list. The keys have not changed and one backspace brings
       them back; what the operator is looking at is the command they are
       part way through typing, and until now the only way to find out
       whether it existed was to send it. *)
    (* The footer is drawn dim, so a span that changes colour restores the
       foreground rather than resetting: a reset would drop the dim from
       everything after it. What is highlighted is the run the operator has
       actually pressed, which is what tells them how far along the word they
       are. *)
    let slash_hint =
      match command_window with
      | Some _ -> Some "↑/↓:select  Tab/Enter:insert  Esc:close"
      | None -> slash_hint_text ~restore:Ansi.default_fg (Masc_tui_message_input.contents state.msg_input)
    in
    let footer_hints =
      if state.keeper_navigation_open then Masc_tui_keys.keeper_navigation_hints
      else
      match slash_hint with
      | Some line -> line
      (* A capture takes the hint line for as long as it runs. The chat surface
         draws its own input row rather than the composer, so the meter that
         row carries never reaches here — and this is the one screen an
         operator speaks from. Nothing else distinguishes a microphone that is
         hearing them from one that is not: both end as an empty draft.

         It replaces the hints rather than crowding in beside them because the
         keys they name are the ones a capture is not waiting for. *)
      | None when state.voice_capture <> None ->
        let bar =
          match state.voice_level_db with
          | None -> Printf.sprintf "%s듣는 중…%s" Ansi.dim Ansi.reset
          | Some db ->
            Printf.sprintf
              "%s%s%s  %s%.0f dB%s"
              (Masc_tui_theme.tone Masc_tui_theme.Accent)
              (Masc_tui_footer.voice_bar
                 ~width:Masc_tui_footer.voice_bar_width
                 ~db:(Some db))
              Ansi.reset
              Ansi.dim
              db
              Ansi.reset
        in
        (* Both endings, because they are not the same and the difference is
           what the operator loses. Ctrl-Y keeps the sentence; Esc abandons it. *)
        Printf.sprintf
          "%s  %s%s send · Esc discard%s"
          bar
          Ansi.dim
          Masc_tui_keys.voice_speak_key
          Ansi.reset
      (* Between utterances in continuous mode: on, but nothing recording. A
         mode that is idle looks exactly like one that is off without this. *)
      | None when state.voice_continuous <> None ->
        Printf.sprintf
          "%s대기 중 — 말하면 잡습니다 · %s to stop%s"
          Ansi.dim
          Masc_tui_keys.voice_listen_key
          Ansi.reset
      | None ->
      if state.keeper_message_focus = Left_pane then
        "Up/Down:move  Enter:open  Right/Esc:chat"
      else if chat_cols < 120 then
        let compact_enter_hint =
          match disposition with
          | Updates _ -> (
              match state.msg_recall_replaces with
              | Some _ -> "Enter:replace queued  Ctrl-U:leave it"
              | None ->
                  Printf.sprintf "Enter:send (%d local)  Ctrl-T:queue  Ctrl-K:cancel"
                    pending_count)
          | Sends -> enter_hint
        in
        let compact_scroll_hint =
          if scroll = 0 then "PgUp:history" else "PgDn:newest"
        in
        Masc_tui_footer.compact_chat_hints ~enter_hint:compact_enter_hint
          ~scroll_hint:compact_scroll_hint ~escape_hint
      else
        Masc_tui_footer.chat_hints ~enter_hint ~scroll_hint ~switch_hint
          ~escape_hint ~leave_hint
    in
    let input_column =
      Message_layout.input_cursor_column ~terminal_cols:chat_cols
        ~input_cells:composer.cursor_cells
    in
    let cursor_column =
      input_column + if split then keeper_roster_pane_cols else 0
    in
    if split then begin
      let left_buf = Buffer.create 1024 in
      let pane_rows = count_frame_lines chat_buf in
      let portrait =
        match List.find_opt
          (fun (keeper : keeper) -> String.equal keeper.k_name keeper_name)
          state.keepers with
        | None -> None
        | Some keeper ->
          (match (keeper_reading state keeper).Keeper_control.liveness with
           | Keeper_control.Present runtime ->
             (match runtime.kr_portrait with
              | Tui_decode.Ready equipment ->
                Masc_tui_chat_portrait.shown ~name:keeper_name
                  ~portrait:(Keeper_portrait_equipment.Ready equipment)
                  ~rows:pane_rows ~cols:keeper_roster_pane_cols
              | Tui_decode.Unavailable _ -> None)
           | Keeper_control.Unobserved | Keeper_control.Absent
           | Keeper_control.Invalid _ -> None)
      in
      let roster_rows = match portrait with
        | None -> pane_rows
        | Some portrait -> portrait.Masc_tui_chat_portrait.roster_rows in
      Option.iter (fun portrait ->
        box_line left_buf keeper_roster_pane_cols
          (Theme.recede () ^ " 현재 대화 · " ^ display_keeper_name ^ Ansi.reset);
        (* Anchor pixels to the caption actually drawn above the selectable roster. *)
        let picture_row = count_frame_lines left_buf in
        List.iter (box_line left_buf keeper_roster_pane_cols)
          portrait.Masc_tui_chat_portrait.picture_lines;
        (* A present left-pane row must retain its width: [box_bottom] is
           a bare newline for full-screen surfaces and would pull the
           right-pane composer into the portrait column. *)
        box_line left_buf keeper_roster_pane_cols "";
        Option.iter (fun (placement : Masc_tui_portrait_view.placement) ->
          Masc_tui_portrait_view.request
            {placement with row = picture_row + strip_rows}) portrait.placement)
        portrait;
      keeper_roster_pane
        ~focused:(state.keeper_message_focus = Left_pane)
        state ~rows:roster_rows ~cols:keeper_roster_pane_cols left_buf;
      write_two_panes buf ~left_cols:keeper_roster_pane_cols ~left:left_buf
        ~right:chat_buf
    end;
    (* History already reserves these two fixed rows. Append them once after
       composing the panes, with the same full width in split and plain chat. *)
    Buffer.add_string buf (" " ^ fit_width identity_row telemetry_cells ^ "\n");
    Buffer.add_string buf
      (footer_line state ~max_cells:cols ?position:scroll_position ~hints:footer_hints);
    finish_frame_beside_acting_pane state ~surface_key:"keeper-message"
      ~clamped:(Message_scroll scroll_feedback)
      ~cursor:
        (if state.keeper_message_focus = Left_pane then
           Frame_presenter.Hidden
         else
           Frame_presenter.Visible_at
             { row = input_row; column = cursor_column })
      ~rows ~cols buf
    end

module For_testing = struct
  let source_index_build_count () = !source_index_builds
  let source_url_discovery_count () = !source_url_discoveries
end
