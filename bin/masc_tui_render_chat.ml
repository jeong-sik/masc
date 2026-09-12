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


let cached_chat_markdown ~theme ~(entry : Message_layout.entry) ~width =
  let context = Chat_theme.body_context theme entry.style in
  let palette_generation = context.palette_generation in
  match entry.markdown_source with
  | Message_layout.Markdown_stable
      { keeper_name; request_id; observed_at; entry_index } ->
      let source =
        Markdown_cache.Stable_source
          { identity =
              { cmi_style = entry.style;
                cmi_keeper_name = keeper_name;
                cmi_request_id = request_id;
                cmi_observed_at = Some observed_at;
                cmi_entry_index = entry_index;
              };
            text = entry.body;
          }
      in
      Markdown_cache.render chat_markdown_cache
        ~theme_revision:chat_markdown_theme_revision
        ~palette_generation ~width ~renderer:(chat_markdown ~context) ~source
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
        ~text:entry.body
  | Message_layout.Markdown_streaming ->
      chat_markdown ~context ~width entry.body


(* Conversation colour names the source, not the prose. A keeper can return a
   page of Markdown; painting every byte green turns syntax, emphasis, links,
   and ordinary text into one undifferentiated status light. The compact
   reverse-video badge gives the source a background that works with the
   terminal's own light or dark palette, while the body keeps its semantic
   Markdown colours. *)
(* How many reasoning lines a folded block stands for. The count is the
   non-blank lines, matching what the unfolded block draws. *)
let folded_thinking_summary body =
  let lines =
    String.split_on_char '\n' body
    |> List.filter (fun line -> String.trim line <> "")
  in
  match lines with
  (* A fold summary is itself one line, so folding one line hides nothing and
     saves nothing. It also promised an expansion: every committed reasoning
     block is the withheld-step count alone, and Ctrl-R on it redrew the same
     sentence. A block with nothing to fold draws as itself. *)
  | [] | [ _ ] -> body
  | lines ->
      Printf.sprintf
        "Reasoning · %d line(s) folded · Ctrl-R or /thinking to expand"
        (List.length lines)


let tool_projection_mode (state : state) =
  match state.msg_tool_visibility with
  | Tools_compact -> Keeper_chat_transcript.Compact
  | Tools_full -> Keeper_chat_transcript.Full


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
  let markers = [ "✓"; "✗"; "×"; "√"; "▶"; "◌"; "!"; "?" ] in
  List.find_opt (fun m -> String.starts_with ~prefix:m s) markers

;;

let tool_marker_color = function
  | "✓" | "√" -> Theme.ok ()
  | "✗" | "×" | "!" -> Ansi.bold ^ Theme.bad ()
  | "▶" | "?" -> Theme.warn ()
  | "◌" -> Theme.info ()
  | _ -> Ansi.reset

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
         Printf.sprintf "%s%s%s %s%s%s%s" col m Ansi.reset
           (Theme.tool_origin ()) name Ansi.reset args
       | None ->
         Printf.sprintf "%s%s%s %s%s%s" col m Ansi.reset
           (Theme.tool_origin ()) rest Ansi.reset)
  | None ->
    if contains_sub c "detail" && contains_sub c "folded" then
      Printf.sprintf "%s%s%s" (Theme.recede () ^ Ansi.dim) c Ansi.reset
    else if String.starts_with ~prefix:"Ctrl-" c || contains_sub c "carried by the transcript" then
      Printf.sprintf "%s%s%s" (Theme.recede () ^ Ansi.dim) c Ansi.reset
    else if (String.ends_with ~suffix:"ms" c || String.ends_with ~suffix:"s" c)
            && (match split_last_space c with None -> true | Some (_, _) -> false) then
      Printf.sprintf "%s%s%s" (Theme.recede () ^ Ansi.dim) c Ansi.reset
    else if contains_sub c "returned" || contains_sub c "failed" || contains_sub c "awaiting" || contains_sub c "running" then
      if contains_sub c ", " then
        let parts = String.split_on_char ',' c in
        let dressed =
          List.map
            (fun p ->
              let p = String.trim p in
              if String.ends_with ~suffix:"returned" p then
                Printf.sprintf "%s%s%s" (Theme.ok ()) p Ansi.reset
              else if contains_sub p "failed" || contains_sub p "never returned" then
                Printf.sprintf "%s%s%s" (Ansi.bold ^ Theme.bad ()) p Ansi.reset
              else if contains_sub p "awaiting" then
                Printf.sprintf "%s%s%s" (Theme.warn ()) p Ansi.reset
              else if contains_sub p "running" then
                Printf.sprintf "%s%s%s" (Theme.info ()) p Ansi.reset
              else p)
            parts
        in
        String.concat ", " dressed
      else if String.ends_with ~suffix:"returned" c then
        Printf.sprintf "%s%s%s" (Theme.ok ()) c Ansi.reset
      else if contains_sub c "failed" || contains_sub c "never returned" then
        Printf.sprintf "%s%s%s" (Ansi.bold ^ Theme.bad ()) c Ansi.reset
      else if contains_sub c "awaiting" then
        Printf.sprintf "%s%s%s" (Theme.warn ()) c Ansi.reset
      else if contains_sub c "running" then
        Printf.sprintf "%s%s%s" (Theme.info ()) c Ansi.reset
      else c
    else
      match split_last_space c with
      | Some (name, count) when is_all_digits count ->
        Printf.sprintf "%s%s%s %s%s%s"
          (Theme.tool_origin ()) name Ansi.reset
          (Theme.recede () ^ Ansi.dim) count Ansi.reset
      | _ -> c

;;

let dress_tool_summary (line : string) : string =
  let parts = split_on_middle_dot line in
  let dressed = List.map dress_tool_clause parts in
  let sep = Printf.sprintf " %s\xc2\xb7%s " (Theme.recede () ^ Ansi.dim) Ansi.reset in
  String.concat sep dressed

;;

let render_chat_row ~theme buf cols (row : Message_layout.row) =
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
        if is_tool then
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
          let marked = Message_layout.take_cells after_rail (at - rail_cells) in
          let label = Message_layout.drop_cells after_rail (at - rail_cells) in
          let rail =
            if String.equal rail "" then ""
            else Printf.sprintf "%s%s%s" (Theme.recede ()) rail Ansi.reset
          in
          if String.equal label "" then
            Printf.sprintf "%s%s%s%s%s" rail (Chat_theme.origin row.style)
              Ansi.bold marked restore
          else
            Printf.sprintf "%s%s%s%s%s%s%s%s" rail (Chat_theme.origin row.style)
              Ansi.bold marked Ansi.reset (Theme.recede ()) label restore
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
          | _, Message_layout.Shade_none -> "  "
          | _, Message_layout.Shade_quoted ->
              Printf.sprintf "%s\xe2\x94\x82%s " (Theme.recede ()) Ansi.reset
        in
        let body_style =
          if is_tool then Ansi.reset
          else Chat_theme.body row.style
        in
        if context.ambient_background && not is_tool then
          box_line_styled buf cols ~style:context.opening
            (Printf.sprintf "%s  %s" margin (dress rest))
        else
          box_line buf cols
            (Printf.sprintf "%s%s%s%s%s" margin rail
               body_style (dress rest) Ansi.reset))
      else
        box_line_styled buf cols
          ~style:(if is_tool then Ansi.reset else context.opening)
          (dress text)
  | Message_layout.Metadata (Message_layout.Timeline_break _) ->
      box_line_styled buf cols ~style:(Theme.info () ^ Ansi.bold) row.text
  | Message_layout.Metadata (Message_layout.Continued_at { timestamp }) ->
      box_line_styled buf cols ~style:(Theme.recede ())
        (Printf.sprintf "[%s]" timestamp)
  | Message_layout.Metadata
      (Message_layout.Origin { timestamp; role_label; request_label }) ->
      (match row.style with
       | Message_layout.Tool | Message_layout.Thinking ->
           box_line_styled buf cols ~style:(Theme.recede ())
             (Printf.sprintf "[%s]  %s  %s" timestamp
                (String.trim role_label) request_label)
       | Message_layout.User | Message_layout.Inbound | Message_layout.Keeper
       | Message_layout.Status | Message_layout.Local | Message_layout.Journal
       | Message_layout.Error | Message_layout.Skill _ ->
           (* [role_label] arrives in a fixed fourteen-to-eighteen cell column
              so the request column stays put down the pane. The label sits
              beside its mark and the remaining padding follows the badge;
              the reverse span covers only the name.

              "From" went with it. It was five cells that named no field and
              said nothing the badge does not: the row already reads
              [clock] [who] [request]. *)
           let mark, name, alignment =
             Message_layout.split_aligned_role_label ~style:row.style role_label
           in
           (* The mark keeps its colour and stays out of the badge, the way the
              inline gutter already draws it, so the two origin modes agree
              about what a speaker mark looks like. *)
           let badge =
             Printf.sprintf "%s%s%s%s%s %s %s" (Chat_theme.origin row.style)
               mark Ansi.reverse name Ansi.reset alignment Ansi.reset
           in
           box_line buf cols
             (Printf.sprintf "%s[%s]%s  %s %s%s%s" Ansi.dim timestamp Ansi.reset
                badge Ansi.dim request_label Ansi.reset))


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

let skill_tone_of_state :
    Keeper_chat_transcript.skill_state -> Message_layout.skill_tone = function
  | Keeper_chat_transcript.Skill_calling
  | Keeper_chat_transcript.Skill_served_pending
  | Keeper_chat_transcript.Skill_delivered -> Message_layout.Skill_live
  | Keeper_chat_transcript.Skill_used -> Message_layout.Skill_used
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
        Printf.sprintf " %s%s%s %s\xc2\xb7 gate:%s%s"
          (if yolo then (Theme.bad ()) else (Theme.info ()))
          chat_mode Ansi.reset Ansi.dim
          (Terminal_text.single_line gate_mode) Ansi.reset
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
             | Persisted_keeper -> status ^ " · —"
           in
           fit_identity (Ansi.dim ^ detail ^ Ansi.reset)
       | Some row ->
           let runtime_id =
             Keeper_chat_transcript.runtime_identity_text ~keeper_name
               ~configured_runtime:row.kr_runtime_id
               (Option.map (fun live -> live.tl_transcript) state.msg_live)
           in
           let prefix =
             Printf.sprintf "%s%s \xc2\xb7 %s " status Ansi.dim
               (Tui_decode.keeper_phase_to_string row.kr_phase)
           in
           let prefix_width = Message_layout.display_width prefix in
           if prefix_width >= max_cells then
             fit_width (prefix ^ runtime_id ^ Ansi.reset) max_cells
           else
             prefix
             ^ fit_runtime_id (max_cells - prefix_width) runtime_id
             ^ Ansi.reset)


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
      else if state.keeper_calls_loading then Call_log_loading
      else
      match state.keeper_calls_error, state.keeper_calls with
      | Some detail, _ -> Call_log_unavailable detail
      | None, None -> Call_log_not_loaded
      | None, Some snapshot
        when not (String.equal snapshot.Tui_decode.kcs_keeper keeper_name) ->
          Call_log_not_loaded
      | None, Some snapshot ->
          let matches =
            List.filter
              (fun (call : Tui_decode.keeper_call) ->
                Option.equal String.equal call.kc_execution_id
                  (Some execution_id))
              snapshot.kcs_entries
          in
          match matches with
          | [] -> Call_execution_missing
          | [ call ] -> Call_execution_exact call
          | rows -> Call_execution_ambiguous (List.length rows))


(* The tool tree's colours, out of the reader's own theme. Built per draw
   rather than held: the palette behind [Theme.*] is resolved against the
   terminal's answers and can change, and a cached record would keep drawing
   the colours the last answer produced. *)
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
  ; reset = Ansi.reset
  }


(* An outcome is a reading of state, so it draws through the status names
   rather than through the tree's own default. The two that are still moving
   read as attention; the two that stopped badly read as failure. *)
let tool_outcome_tone : Keeper_chat_transcript.tool_outcome -> string = function
  | Keeper_chat_transcript.Started | Keeper_chat_transcript.Awaiting_result ->
      Theme.info ()
  | Keeper_chat_transcript.Returned -> Theme.ok ()
  | Keeper_chat_transcript.Failed | Keeper_chat_transcript.Never_returned ->
      Theme.bad ()
  | Keeper_chat_transcript.Outcome_unrecorded -> Theme.warn ()


let tool_outcome_label : Keeper_chat_transcript.tool_outcome -> string = function
  | Keeper_chat_transcript.Started -> "PREPARING · ARGUMENTS STREAMING"
  | Keeper_chat_transcript.Awaiting_result -> "WAITING FOR RESULT"
  | Keeper_chat_transcript.Returned -> "RETURNED"
  | Keeper_chat_transcript.Failed -> "FAILED"
  | Keeper_chat_transcript.Never_returned -> "NEVER RETURNED"
  | Keeper_chat_transcript.Outcome_unrecorded -> "OUTCOME UNRECORDED"


let keeper_call_schedule_label (schedule : Tui_decode.keeper_call_schedule) =
  let execution =
    match schedule.kcs_execution_mode with
    | Tui_decode.Keeper_call_serial -> "serial"
    | Tui_decode.Keeper_call_concurrent -> "concurrent"
  in
  Printf.sprintf "%s · batch %d · width %d · plan step %d" execution
    (schedule.kcs_batch_index + 1) schedule.kcs_batch_size
    (schedule.kcs_planned_index + 1)


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
        let output =
          Option.map (fun value -> "output", value) call.kc_output
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
    | Call_execution_ambiguous _ ->
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
           (tool_outcome_label activity.outcome)
           (tool_outcome_tone activity.outcome))
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
    ; Option.map (fun (label, value) -> served label value) output_field
    ; Option.map (fun (label, value) -> said label value "") result_field
    ; Some (said "identity" identity "")
    ]
    |> List.filter_map Fun.id
  in
  Tool_detail.tree ~palette:(tool_detail_palette ()) fields


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
  let rows =
    Keeper_chat_diff.rows
    ~mode
    ~max_line_cells:(chat_body_line_cells ~chat_cols ~role_label_column)
    ~activity_details:(keeper_message_tool_activity_details state ~keeper_name)
    file_change_index projection
  in
  (* The fold says how many rows it is holding; the key that opens them is in
     the footer, on every frame, next to the other five. Repeating it on the
     row cost thirty-eight cells of the widest line in the pane, and a screen
     with four tool blocks carried the same sentence four times -- which is
     what pushed the tool names onto a second line and broke the read of the
     conversation they sit inside. *)
  match projection.Keeper_chat_transcript.header with
  | None -> rows
  | Some header ->
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
        |> Masc_tui_types.fold_memory_summary_runs
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

let keeper_message_visible_messages ?messages (state : state) ~keeper_name =
  keeper_message_visible_timeline ?messages state ~keeper_name
  |> List.map fst

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


let compute_keeper_message_layout_entries (state : state) ~keeper_name
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
  (* Turn identity stays in the typed request id. The speaker glyph already
     distinguishes USER, Keeper, Tool, Skill, and Journal, so prefixes such as
     [TURN ·] and [↳] repeated or obscured the same fact instead of clarifying
     it. Adjacent rows from the exact same request still fold as continuations
     in [Message_layout]; a row resuming after another lane names its source
     again. *)
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
        let role_label = grouped_role_label in
        (* One column for every speaker so the [timestamp] speaker request
           rows line up down the pane, whatever name each row carries. *)
        let role_label =
          Message_layout.align_role_label ~column:role_label_column ~style
            role_label
        in
        let body =
          match message.me_role with
          | Message_thinking
            when state.msg_reasoning_visibility = Reasoning_folded ->
              folded_thinking_summary message.me_text
          | Message_skill _ -> (
              match message.me_skill_activity with
              | None -> message.me_text
              (* Always full, not tied to [msg_tool_visibility]: a skill row is
                 one of ours, and whether a served skill was actually delivered
                 and used is the fact the row exists to carry. Folding it behind
                 the tool toggle made "SERVED ONLY vs DELIVERED · USED" the same
                 keystroke away as a docker exec's schedule, so the operator saw
                 only a name and a state and had to expand to learn if the skill
                 did anything. A skill has few rows (the action list and one
                 proof line), so showing them costs little and the toggle still
                 governs the tool projections beside it. *)
              | Some activity ->
                  Keeper_chat_transcript.skill_rows ~full:true activity
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
              | Memory_full | Memory_hidden -> message.me_text
              | Memory_summary -> (
                  (* A summarised row is a cut row, so it says which key
                     uncuts it. What that key does is the footer's line,
                     which is on screen whenever this row is: spelling
                     "journal detail" here again cost twenty-five cells on
                     every journal row of the pane. *)
                  match message.me_memory_summary with
                  | Some summary -> summary ^ " · Ctrl-N"
                  | None -> message.me_text))
          (* Only a gated row: a Gate step's text ends in the argument the
             call asked for, while a status row without one is a sentence the
             server composed and has nothing to fold away. *)
          | Message_status when message.me_gate <> None -> (
              match tool_projection_mode state with
              | Keeper_chat_transcript.Full -> message.me_text
              | Keeper_chat_transcript.Compact ->
                  (gate_fold ~chat_cols ~role_label_column message)
                    .Masc_tui_gate_text.fa_text)
          | Message_thinking | Message_user _ | Message_keeper
          | Message_autonomous
          | Message_status | Message_local | Message_error ->
              message.me_text
        in
        (* What the links in this message point at, on rows of their own
           under it. Added here because this is before the layout wraps:
           the pane's own link styling runs after wrapping and cannot add a
           cell without moving the row it sits on.

           Read out of the URL and never fetched. A keeper writes these
           links, and following one because it was mentioned would turn
           anything a keeper says into traffic this process sends.

           Not on a tool block. Tool output arrives already structured and
           already long, and a bare URL there sits in a row that says what
           it is; a URL in prose is the one standing on its own. *)
        let body =
          match message.me_role with
          | Message_tool | Message_skill _ -> body
          | Message_thinking | Message_user _ | Message_keeper
          | Message_autonomous | Message_status | Message_local
          | Message_error | Message_memory -> (
              let seen = Hashtbl.create 4 in
              let urls =
                Message_layout.bare_urls body
                |> List.filter (fun u ->
                       if Hashtbl.mem seen u then false
                       else begin
                         Hashtbl.add seen u ();
                         true
                       end)
              in
              match urls with
              | [] -> body
              | urls -> (
                  match state.link_previews_mode with
                  | `Off -> body
                  | `Compact ->
                      let badges =
                        List.filter_map
                          (fun u ->
                             let p = Masc_tui_link_preview.get_preview u in
                             Masc_tui_link_preview.render_compact_badge p)
                          urls
                      in
                      (match badges with
                       | [] -> body
                       | _ -> body ^ "\n" ^ String.concat "\n" badges)
                  | `Rich ->
                      let inner = max 20 (chat_cols - role_label_column - 6) in
                      let cards =
                        List.filter_map
                          (fun u ->
                             let p = Masc_tui_link_preview.get_preview u in
                             if Masc_tui_link_preview.has_informative_preview p then
                               Some (String.concat "\n" (Masc_tui_link_preview.render_inline_card ~width:inner p))
                             else None)
                          urls
                      in
                      (match cards with
                       | [] -> body
                       | _ -> body ^ "\n" ^ String.concat "\n" cards)))
        in
        ({ style;
             timestamp =
               Option.fold ~none:message.me_timestamp
                 ~some:keeper_message_clock timeline_at;
             timeline_bucket =
               Option.map keeper_message_timeline_bucket
                 timeline_at;
             role_label;
             role_label_mark_cells =
               Message_layout.role_label_mark_cells
                 ~column:role_label_column ~style ();
             request_label =
               Keeper_chat.compact_request_id message.me_request_id;
             body;
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
               (match message.me_role, tool_projection_mode state with
                | Masc_tui_types.Message_status, Keeper_chat_transcript.Compact
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


(* What a queued line is waiting on. "Pending" reads the same behind this
   Keeper's turn that is still out and behind another queued line, and the
   difference is whether the wait is ordinary. Computed here rather than in
   the queue module: the answer needs the in-flight list, and the queue
   cannot see it without a dependency cycle through [masc_tui_types]. *)
let chat_pending_behind (state : state)
  (item : Masc_tui_keeper_chat_queue.item) =
  let keeper_name =
  item.Masc_tui_keeper_chat_queue.request.Keeper_chat.keeper_name
  in
  let held =
  List.length
    (List.filter
       (fun (entry : Masc_tui_types.inflight) ->
          String.equal entry.Masc_tui_types.sent_request.keeper_name
            keeper_name)
       state.msg_inflight)
  in
  let ahead =
  List.filter
    (fun (waiting : Masc_tui_keeper_chat_queue.item) ->
       String.equal
         waiting.Masc_tui_keeper_chat_queue.request.Keeper_chat.keeper_name
         keeper_name
       && waiting.submission_seq > item.submission_seq
       &&
       (* A steer precedes ordinary input whatever its seq; a NEXT line
          ahead of a steer is not ahead at all. *)
       (match (waiting.intent, item.intent) with
        | Steer_after_interrupt, Next -> true
        | Next, Steer_after_interrupt -> false
        | _ -> waiting.submission_seq > item.submission_seq))
    (Masc_tui_keeper_chat_queue.waiting state.msg_queued)
  in
  match (item.intent, held, ahead) with
  | Masc_tui_keeper_chat_queue.Steer_after_interrupt, 0, [] ->
    Some "after the interrupted turn settles"
  | Masc_tui_keeper_chat_queue.Steer_after_interrupt, _, _ ->
    Some "behind this Keeper's turn still out"
  | Masc_tui_keeper_chat_queue.Next, 0, [] -> None
  | Masc_tui_keeper_chat_queue.Next, 0, waiting_ahead :: _ -> (
    match waiting_ahead.intent with
    | Steer_after_interrupt -> Some "behind a queued steer"
    | Next -> Some "behind an earlier queued message")
  | Masc_tui_keeper_chat_queue.Next, 1, _ ->
    Some "behind this Keeper's running turn"
  | Masc_tui_keeper_chat_queue.Next, held, _ ->
    Some
      (Printf.sprintf "behind this Keeper's %d running turns" held)

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
  (* The state goes in the body, not in [request_label]. That field rides the
     metadata row, which every origin mode but [Origin_row] folds away -- so a
     line saying where it stands would have said it only to a reader who had
     already pressed Ctrl-F. The body is drawn whatever the mode. *)
  let entry ~at ~label ~note ~body =
    let style = Message_layout.User in
    ({ style
     ; timestamp = keeper_message_clock at
     ; timeline_bucket = Some (keeper_message_timeline_bucket at)
     ; role_label =
         Message_layout.align_role_label ~column:role_label_column ~style label
     ; role_label_mark_cells =
         Message_layout.role_label_mark_cells ~column:role_label_column ~style ()
     ; request_label = ""
     ; body = note ^ "\n" ^ Terminal_text.single_line body
     ; markdown_source = Message_layout.Markdown_streaming
     ; turn_rail = Message_layout.Rail_none
     ; action = Message_layout.Action_none
     }
      : Message_layout.entry)
  in
  let promoted =
    match promoted_inflight_for_keeper state keeper_name with
    | None -> []
    | Some inflight ->
        (* The status says what the operator can act on: the line left and the
           running turn is answering it. The compact request id that stood
           here named a queue internal no reader could resolve. *)
        [ entry ~at:inflight.submitted_at ~label:"YOU"
            ~note:"sent · the running turn answers it"
            ~body:inflight.sent_request.message ]
  in
  let pending =
    Masc_tui_keeper_chat_queue.waiting_for_keeper state.msg_queued ~keeper_name
    |> keeper_message_pending_preview
    |> List.map (function
         | Pending_preview_item (position, item) ->
             let intent =
               match item.Masc_tui_keeper_chat_queue.intent with
               | Masc_tui_keeper_chat_queue.Next -> "NEXT"
               | Masc_tui_keeper_chat_queue.Steer_after_interrupt -> "STEER"
             in
             let note =
               match chat_pending_behind state item with
               | Some reason -> Printf.sprintf "%s %d · %s" intent position reason
               | None -> Printf.sprintf "%s %d" intent position
             in
             entry ~at:item.submitted_at ~label:"YOU" ~note
               ~body:item.Masc_tui_keeper_chat_queue.request.Keeper_chat.message
         | Pending_preview_omitted omitted ->
             entry ~at:(Unix.gettimeofday ()) ~label:""
               ~note:
                 (Printf.sprintf
                    "… %d pending row(s) hidden · Ctrl-K:cancel last · \
                     Ctrl-P:edit last" omitted)
               ~body:"")
  in
  promoted @ pending

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
  lem_chat_cols : int;
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
let rec shared_layout_entry_prefix reversed old_visible old_entries
    new_visible =
  match old_visible, old_entries, new_visible with
  | (old_message, old_at, old_edge) :: old_visible_rest,
    entry :: old_entries_rest,
    (message, timeline_at, edge) :: new_visible_rest
    when old_message == message
         && Option.equal Float.equal old_at timeline_at
         && old_edge = edge ->
      shared_layout_entry_prefix (entry :: reversed) old_visible_rest
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
  let same_inputs (memo : layout_entries_memo) =
    String.equal memo.lem_keeper_name keeper_name
    && memo.lem_chat_cols = chat_cols
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
    when same_inputs memo && memo.lem_visible_timeline == visible_timeline ->
      memo.lem_entries
  | Some memo when same_inputs memo ->
      let visible_entries = keeper_message_visible_entries visible_timeline in
      let prefix, suffix =
        shared_layout_entry_prefix [] memo.lem_visible_entries
          memo.lem_entries visible_entries
      in
      let entries =
        match suffix with
        | [] -> prefix
        | _ when suffix == visible_entries ->
            compute_keeper_message_layout_entries state ~keeper_name
              ~chat_cols ~start_index:0 visible_entries
        | _ ->
            prefix
            @ compute_keeper_message_layout_entries state ~keeper_name
                ~chat_cols ~start_index:(List.length prefix) suffix
      in
      layout_entries_memo :=
        Some
          { memo with
            lem_visible_timeline = visible_timeline;
            lem_visible_entries = visible_entries;
            lem_entries = entries;
          };
      entries
  | Some _ | None ->
      let visible_entries = keeper_message_visible_entries visible_timeline in
      let entries =
        compute_keeper_message_layout_entries state ~keeper_name ~chat_cols
          ~start_index:0 visible_entries
      in
      layout_entries_memo :=
        Some
          { lem_keeper_name = keeper_name;
            lem_chat_cols = chat_cols;
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


(* Where the pane has to scroll to put a message holding [query] on screen, and
   which message that is.

   Two values, because a caller needs both: the scroll to move to, and the
   structural anchor to start the next search strictly older than. The scroll is
   measured the only way it can be -- the physical rows the entries newer than
   the match render to, at this pane's width, through the same layout the
   frame draws. Counting messages instead would land somewhere else on every
   conversation that wraps.

   Newest first. A search over a conversation starts at what was just said and
   walks back, which is also the direction [msg_scroll] counts.

   [older_than] is a causal row identity, resolved again in the current
   timeline. A broadcast or Journal backfill may be inserted before it, so a
   stored numeric position would skip an older match after refresh. A match at
   or newer than the resolved anchor is skipped, which makes repeating a
   search walk instead of returning to the newest match every time.

   Measured over committed rows only. A producer backfill can move the physical
   row, so the repeat cursor and the scroll pin both retain its causal identity
   rather than its old index. With a live turn on screen the match lands that
   turn's height above the bottom edge rather than on it -- context below a
   result, and it settles when the turn ends.

   [needle] is trimmed by its caller and case-folded inside
   {!Masc_tui_types.palette_contains}, which keeps case folding out of a
   module whose one rule about [String.lowercase_ascii] is that it does not
   appear here.

   Pure. The renderer does not mutate state, and a search that scrolled the
   pane itself would be the exception that ends that. *)
let keeper_message_find_scroll (state : state) ~keeper_name ~needle ~older_than =
  if String.equal needle "" then None
  else
    let _, cols = get_terminal_size () in
    let chat_cols =
      Masc_tui_roster_pane.content_cols ~hidden:state.roster_pane_hidden ~cols
    in
    let messages = keeper_message_visible_messages state ~keeper_name in
    let entries =
      keeper_message_layout_entries state ~keeper_name ~chat_cols
    in
    let count = List.length entries in
    let ceiling =
      match older_than with
      | None -> count
      | Some anchor ->
          Option.value ~default:count
            (msg_index_of_anchor messages anchor)
    in
    let matched =
      List.filteri (fun index _ -> index < ceiling) entries
      |> List.mapi (fun index (entry : Message_layout.entry) -> (index, entry))
      |> List.rev
      |> List.find_opt (fun (_, (entry : Message_layout.entry)) ->
             Masc_tui_types.palette_contains ~needle entry.body)
    in
    match matched with
    | None -> None
    | Some (at, matched_entry) ->
        (* Everything newer than the match, which is exactly what a scroll
           position counts back over. *)
        let newer = List.filteri (fun index _ -> index > at) entries in
        let scroll =
          Message_layout.total_rows
            ~markdown:(cached_chat_markdown ~theme:(Chat_theme.snapshot ()))
            ~origin:state.msg_origin_display
            ~previous:matched_entry
            ~inner_width:(max 1 (framed_inner_width chat_cols))
            newer
        in
        Some (scroll, msg_anchor (List.nth messages at))


(* One turn's block as the chat pane draws it: the log it comes from, where
   it goes in the committed timeline, and its rows -- built as continuations,
   the corners set once the blocks are merged with the committed rows. *)
type log_block = {
  lb_log : Masc_tui_types.turn_log;
  lb_request_id : string;
  lb_insertion : int;
  lb_entries : Message_layout.entry list;
}

(* Whose a merged row is: a committed message's, or a block's log's. *)
type tagged_row =
  | Tagged_row of Masc_tui_types.msg_entry
  | Tagged_block of Masc_tui_types.turn_log

(* A settled block, per (keeper, request), until one of its inputs moves:
   the log's transcript (its revision: durable tool facts fold in after
   settle), the committed timeline it is placed in, the knobs its rows read,
   and the width. Module state like the renderer's other memos: derived, not
   authority. Never evicted within a session, like the logs themselves. *)
type settled_block_memo = {
  sbm_log : Masc_tui_types.turn_log;
  sbm_revision : int;
  sbm_timeline : (Masc_tui_types.msg_entry * float option) list;
  sbm_messages : Masc_tui_types.msg_entry list;
  sbm_reasoning : reasoning_visibility;
  sbm_tools : tool_visibility;
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
}

let merged_blocks_memo : merged_blocks_memo option ref = ref None


let render_keeper_message (state : state) =
  (* The chat surface draws its own composer, so it keeps the whole terminal
     rather than reserving the shared row for a second one. *)
  let rows, cols = get_terminal_size () in
  let buf = Buffer.create 4096 in

  match state.msg_target_keeper_name with
  | None ->
    Buffer.add_string buf "No keeper selected.\n";
    finish_frame_with_strip state ~surface_key:"keeper-message" ~cursor:Frame_presenter.Hidden
      ~rows ~cols buf
  | Some keeper_name ->
    let chat_theme = Chat_theme.snapshot () in
    let display_keeper_name = Keeper_chat.terminal_safe_text keeper_name in
    let target_registered =
      keeper_available_for_new_message state keeper_name
    in
    let status_rows = keeper_message_status_rows state in
    let support_status_rows =
      keeper_message_support_status_rows state ~status_rows
    in
    (* Wide terminals keep the roster beside the chat, exactly as the detail
       view does; the chat lays out against its own pane width. *)
    let split = keeper_roster_pane_shown state ~cols in
    let chat_cols =
      Masc_tui_roster_pane.content_cols ~hidden:state.roster_pane_hidden ~cols
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
        | Tools_compact -> ""
        | Tools_full ->
            if
              not
                (Option.equal String.equal state.msg_file_changes_keeper
                   (Some keeper_name))
            then "diffs pending"
            else if state.msg_file_changes_loading then "diffs loading"
            else
              match state.msg_file_changes_error, state.msg_file_changes with
              | Some _, Some snapshot -> snapshot_status ~stale:true snapshot
              | Some _, None -> "diffs unavailable"
              | None, Some snapshot -> snapshot_status ~stale:false snapshot
              | None, None -> "diffs pending"
      in
      let modes =
        [ modes; diff_status ]
        |> List.filter (fun item -> not (String.equal item ""))
        |> String.concat " · "
      in
      let title =
        screen_title
          (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 chat" display_keeper_name)
      in
      let mode_suffix =
        if String.equal modes "" then ""
        else Printf.sprintf "  %s%s%s" Ansi.dim modes Ansi.reset
      in
      title, mode_suffix
    in
    let inner_cells = framed_inner_width chat_cols in
    (* Title and projection are navigation facts. Runtime/gate/context are
       operational facts. Putting all of them on one row made an ordinary
       provider id consume the rest of the header and silently lose whatever
       followed it. Two fixed rows make the hierarchy visible and let the
       opaque runtime id be the only item that yields width. *)
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
              ~max_cells:(min 32 (max 0 (inner_cells / 3)))
              observation
        | Some _ | None -> None
    in
    let context_cells =
      match context_item with
      | None -> 0
      | Some item ->
          Message_layout.display_width context_separator
          + Message_layout.display_width item
    in
    let identity =
      keeper_message_identity
        ~max_cells:(max 0 (inner_cells - context_cells)) state keeper_name
    in
    let identity_row =
      match context_item with
      | None -> identity
      | Some item ->
          identity ^ context_separator ^ Ansi.dim ^ item ^ Ansi.reset
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
      finish_frame_with_strip state ~surface_key:"keeper-message"
        ~cursor:Frame_presenter.Hidden ~rows ~cols buf
    end else begin
    let chat_buf = if split then Buffer.create 4096 else buf in
    (* Header *)
    box_top chat_buf chat_cols;
    box_line chat_buf chat_cols title_row;
    box_line chat_buf chat_cols identity_row;
    box_divider chat_buf chat_cols;

    (* Message history. The fixed chrome is 8 rows — box top, two header rows,
       their divider, the input divider, the composer's first line, box bottom
       and the footer — and every variable row (status, sending, queue, errors,
       composer growth) is in [status_rows]. The old constant 10 reserved
       two rows nothing drew, so the pane stopped two short of the
       terminal's bottom edge. [message_viewport_supported] requires the same
       eight-row chrome plus three history rows, so a live-edge omission can
       still show its first row, typed gap, and latest row. *)
    let history_height =
      Message_layout.message_history_height ~terminal_rows:rows ~status_rows
    in
    (* The same pure derivation the committed rows used, asked again for the
       live ones: one call to one function with one argument, so the badge the
       streaming turn aligns to is the badge the history aligned to. *)
    let role_label_column =
      Message_layout.chat_role_label_width ~pane_cells:chat_cols
    in
    let projected_tool_rows =
      keeper_message_tool_rows state ~keeper_name ~chat_cols
    in
    let promoted = promoted_inflight_for_keeper state keeper_name in
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
    let log_projection ~committed (turn_log : Masc_tui_types.turn_log) =
      let transcript = turn_log.tl_transcript in
      let request_id = Masc_tui_types.turn_log_request_id turn_log in
      let request_label = Keeper_chat.compact_request_id request_id in
      let started_at = Keeper_chat_transcript.started_at transcript in
      let bounds_request (message : Masc_tui_types.msg_entry) =
        (not (String.equal message.me_request_id request_id))
        || committed = false
        || message.me_turn_phase <> Turn_output
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
        chat_live_timeline_at ~request_id ~started_at ~request_messages
          bounded_timeline
      in
      let insertion =
        if committed
        then
          chat_settled_insertion_index ~request_id ~timeline_at
            committed_visible_timeline
        else
          chat_live_insertion_index ~request_id ~timeline_at
            committed_visible_timeline
      in
      let timeline_bucket =
        Option.map keeper_message_timeline_bucket timeline_at
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
      (* The block's clock stays the dispatch moment. Drawing the span here
         ("16:38→" running, "16:38→16:41" settled) needs a pane-level clock
         column: the gutter's width is fixed at [chat_clock_column] cells and
         is what the body's wrap width is taken from, so a wider span clock
         wrapped this block's body narrower than the rows around it and, on
         a tight pane, truncated to an open arrow over a settled turn. The
         transcript already records the settle instant (settled_at); the
         span display returns with the clock-column work (task-1516). The
         2026-09-10 misread it answers: a 16:38 turn drawn under a 16:41
         reply read as out-of-order. *)
      let entries =
        List.filter_map Fun.id
        @@ List.mapi
             (fun entry_index (item : Keeper_chat_transcript.drawn_item) ->
                let label text =
                  match item.superseded with
                  | Some attempt ->
                      Printf.sprintf "%s \xe2\x86\xba%d" text (attempt + 1)
                  | None -> text
                in
                let annotate_body body =
                  match item.superseded_runtime_id with
                  | Some rid when String.trim rid <> "" ->
                      let attempt_num =
                        match item.superseded with
                        | Some a -> a + 1
                        | None -> 1
                      in
                      let prefix =
                        Printf.sprintf "*(attempt %d: `%s`)*" attempt_num (String.trim rid)
                      in
                      if body = "" then prefix else prefix ^ "\n" ^ body
                  | _ -> body
                in
                let markdown_source =
                  Message_layout.Markdown_growing
                    { keeper_name; request_id; entry_index }
                in
                let entry style role_label body =
                  (* One alignment, on the label the row actually carries.
                     Aligning the continuation mark and then aligning the
                     result again pays the badge's width twice, so the second
                     call trims what the first had already fitted. *)
                  Some
                    ({ style;
                       timestamp = keeper_message_clock started_at;
                       timeline_bucket;
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
                       markdown_source;
                       turn_rail =
                         turn_rail_of ~siding:None
                           ~edge:Masc_tui_types.Turn_continues ~style;
                       (* A live turn draws its Gate steps as status text the
                          transcript composed, not as the store's argument, so
                          there is no argument here to unfold. *)
                       action = Message_layout.Action_none;
                     }
                      : Message_layout.entry)
                in
                match item.drawn with
                | Keeper_chat_transcript.Drawn_thinking _
                  when not
                         (Masc_tui_types.reasoning_drawn
                            state.msg_reasoning_visibility) ->
                    None
                | Keeper_chat_transcript.Drawn_thinking lines ->
                    let body =
                      if state.msg_reasoning_visibility = Reasoning_folded
                      then folded_thinking_summary (String.concat "\n" lines)
                      else String.concat "\n" lines
                    in
                    entry Message_layout.Thinking (label "THINKING") (annotate_body body)
                | Keeper_chat_transcript.Drawn_tools block ->
                    let projection =
                      Keeper_chat_transcript.project_tool_block
                        (tool_projection_mode state) block
                    in
                    let body = String.concat "\n" (projected_tool_rows projection) in
                    entry (tool_block_style projection) (label "TOOLS") (annotate_body body)
                | Keeper_chat_transcript.Drawn_skill skill ->
                    entry
                      (Message_layout.Skill (skill_tone_of_state skill.state))
                      (label "SKILL")
                      (String.concat "\n"
                         (* Full on the block too: the same reason the
                            committed skill rows are always full — the skill's
                            delivery and observed actions are the feature this
                            row reports, not a detail behind the tool toggle. *)
                         (Keeper_chat_transcript.skill_rows ~full:true skill))
                | Keeper_chat_transcript.Drawn_text text
                | Keeper_chat_transcript.Drawn_reply text ->
                    entry Message_layout.Keeper (label keeper_label) (annotate_body text)
                | Keeper_chat_transcript.Drawn_status text ->
                    entry Message_layout.Status (label "STATUS") text)
             (Keeper_chat_transcript.drawn transcript)
      in
      { lb_log = turn_log; lb_request_id = request_id; lb_insertion = insertion;
        lb_entries = entries }
    in
    let settled_projection (turn_log : Masc_tui_types.turn_log) =
      let key =
        ( Masc_tui_types.turn_log_keeper_name turn_log
        , Masc_tui_types.turn_log_request_id turn_log )
      in
      let revision = Keeper_chat_transcript.revision turn_log.tl_transcript in
      match Hashtbl.find_opt settled_block_memo key with
      | Some memo
        when memo.sbm_log == turn_log
             && memo.sbm_revision = revision
             && memo.sbm_timeline == committed_visible_timeline
             && memo.sbm_messages == committed_timeline_messages
             && memo.sbm_reasoning = state.msg_reasoning_visibility
             && memo.sbm_tools = state.msg_tool_visibility
             && memo.sbm_chat_cols = chat_cols ->
          memo.sbm_block
      | Some _ | None ->
          let block = log_projection ~committed:true turn_log in
          Hashtbl.replace settled_block_memo key
            { sbm_log = turn_log;
              sbm_revision = revision;
              sbm_timeline = committed_visible_timeline;
              sbm_messages = committed_timeline_messages;
              sbm_reasoning = state.msg_reasoning_visibility;
              sbm_tools = state.msg_tool_visibility;
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
      |> List.map settled_projection
      |> List.filter (fun block -> block.lb_entries <> [])
    in
    let live_block =
      match state.msg_live with
      | Some live
        when String.equal (Masc_tui_types.turn_log_keeper_name live) keeper_name
             && Option.is_none promoted -> (
          match log_projection ~committed:false live with
          | { lb_entries = []; _ } -> None
          | block -> Some block)
      | Some _ | None -> None
    in
    let blocks = settled_blocks @ Option.to_list live_block in
    let committed_tagged =
      List.combine committed_messages committed_layout_entries
      |> List.map (fun (message, entry) -> Tagged_row message, entry)
    in
    (* Each block at its own place in the committed timeline. Blocks that
       land on the same index keep their order -- settled turns in the order
       they settled, the live one last -- and a block placed past the end
       follows everything. *)
    let merge_blocks () =
      let placed =
        List.map
          (fun block ->
            ( block.lb_insertion
            , List.map (fun entry -> Tagged_block block.lb_log, entry)
                block.lb_entries ))
          blocks
      in
      let rec merge index committed placed =
        match committed with
        | [] -> List.concat_map snd placed
        | item :: rest ->
            let due, later = List.partition (fun (at, _) -> at <= index) placed in
            List.concat_map snd due @ (item :: merge (index + 1) rest later)
      in
      let merged = merge 0 committed_tagged placed in
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
      let live_request_id =
        Option.map (fun block -> block.lb_request_id) live_block
      in
      let request_of = function
        | Tagged_row (message : Masc_tui_types.msg_entry) ->
            message.me_request_id
        | Tagged_block log -> Masc_tui_types.turn_log_request_id log
      in
      let first = Hashtbl.create 8 and last = Hashtbl.create 8 in
      List.iteri
        (fun index (tag, _) ->
          let request_id = request_of tag in
          if List.exists (String.equal request_id) block_requests then begin
            if not (Hashtbl.mem first request_id) then
              Hashtbl.replace first request_id index;
            Hashtbl.replace last request_id index
          end)
        merged;
      List.mapi
        (fun index ((tag, (entry : Message_layout.entry)) as item) ->
          let request_id = request_of tag in
          match Hashtbl.find_opt first request_id, Hashtbl.find_opt last request_id with
          | Some opens_at, Some closes_at ->
              let opens = opens_at = index in
              let closes =
                closes_at = index
                && not (Option.equal String.equal live_request_id (Some request_id))
              in
              let edge : Masc_tui_types.turn_edge =
                match opens, closes with
                | true, true -> Turn_alone
                | true, false -> Turn_opens
                | false, true -> Turn_closes
                | false, false -> Turn_continues
              in
              let siding =
                match tag with
                | Tagged_row message -> siding_of_message message
                | Tagged_block _ -> None
              in
              ( tag
              , { entry with
                  Message_layout.turn_rail =
                    turn_rail_of ~siding ~edge
                      ~style:entry.Message_layout.style
                } )
          | Some _, None | None, Some _ | None, None -> item)
        merged
    in
    let tagged_layout_entries =
      match blocks, live_block with
      | [], _ -> committed_tagged
      | _ :: _, Some _ -> merge_blocks ()
      | _ :: _, None -> (
          match !merged_blocks_memo with
          | Some memo
            when memo.mbm_committed == committed_layout_entries
                 && List.length memo.mbm_blocks = List.length settled_blocks
                 && List.for_all2 ( == ) memo.mbm_blocks settled_blocks ->
              memo.mbm_merged
          | Some _ | None ->
              let merged = merge_blocks () in
              merged_blocks_memo :=
                Some
                  { mbm_committed = committed_layout_entries;
                    mbm_blocks = settled_blocks;
                    mbm_merged = merged;
                  };
              merged)
    in
    (* With no block drawn, the entries the walk measures are the ones
       [layout_entries_memo] holds across frames, and passing that very list
       is what lets the walk keep its row counts: a fresh list of the same
       entries is a different question to it. With settled blocks only, the
       merged list above is that stable list. *)
    let layout_entries =
      match blocks with
      | [] -> committed_layout_entries
      | _ :: _ -> List.map snd tagged_layout_entries
    in
    (* The operator's unsettled lines sit at the end of the same stream, not
       in a slot below it. Appended after [tagged_layout_entries] on purpose:
       the scroll pin counts rows of committed messages that landed after its
       anchor, and these are not committed messages -- adding them there would
       move a pin the reader set. *)
    let layout_entries =
      layout_entries
      @ chat_tail_entries state ~keeper_name ~role_label_column
    in
    let inner_width = max 1 (framed_inner_width chat_cols) in
    (* Clamped here rather than where the key is handled: the limit depends on
       the terminal width and the pane's height, and a resize changes both
       under a scroll position that was legal before it. *)
    (* One capture, handed to both the measure and the draw, so the rows the
       pane counts are the rows it paints. *)
    let markdown = cached_chat_markdown ~theme:chat_theme in
    (* [msg_scroll] counts back from the row the operator was last looking at,
       not from whatever is newest now. Count the current structural suffix
       after that anchor: newly appended rows belong there, and a late input
       can move pre-existing output below an earlier phase inside its own turn.
       In both cases those rows sit between the anchor and bottom, so adding
       their height is what keeps the same anchored content still.

       A settled block's rows count only if its log was held after the pin was
       taken: the ones on screen when the operator anchored are what they
       anchored to, not rows that arrived since. *)
    let rows_since_pin =
      match state.msg_scroll_pin, live_block with
      | None, _ -> 0
      | Some _, Some _ ->
          (* A live trail has no durable row identity and may already have
             many wrapped rows when the operator first leaves the bottom.
             Treating that existing height as newly arrived double-counts it
             on the first key press. Structural compensation resumes when the
             trail settles into a block the pin can account for. *)
          0
      | Some pin, None ->
          let arrived_since_pin = function
            | Tagged_row _ -> true
            | Tagged_block log -> not (List.memq log state.msg_scroll_pin_settled)
          in
          let entries_after rest =
            List.filter_map
              (fun (tag, entry) -> if arrived_since_pin tag then Some entry else None)
              rest
          in
          let rendered_suffix =
            let rec find_visible = function
              | [] -> None
              | (Tagged_row message, entry) :: rest ->
                  if same_msg_anchor pin message
                  then Some (Some entry, entries_after rest)
                  else find_visible rest
              | (Tagged_block _, _) :: rest -> find_visible rest
            in
            match find_visible tagged_layout_entries with
            | Some _ as found -> found
            | None ->
                (* A hidden Memory/thinking row can own the logical pin but no
                   layout entry. Start at the first visible identity after it,
                   preserving the preceding entry from the full layout so an
                   hour rail is measured exactly as the frame measures it. *)
                let raw_after =
                  Option.value ~default:[]
                    (msg_entries_after_anchor (chat_rows_for state keeper_name) pin)
                in
                let after_anchors = List.map msg_anchor raw_after in
                let belongs message =
                  List.exists
                    (fun anchor -> same_msg_anchor anchor message)
                    after_anchors
                in
                let rec find_after previous = function
                  | [] -> None
                  | (Tagged_row message, entry) :: rest when belongs message ->
                      Some (previous, entry :: entries_after rest)
                  | (_, entry) :: rest -> find_after (Some entry) rest
                in
                find_after None tagged_layout_entries
          in
          (match rendered_suffix with
           | None | Some (_, []) -> 0
           | Some (previous, arrived) ->
               Message_layout.total_rows ~markdown
                 ~origin:state.msg_origin_display ?previous ~inner_width arrived)
    in
    let scroll, visible_rows =
      Message_layout.clamped_scrolled_rows ~markdown
        ~origin:state.msg_origin_display ~inner_width ~height:history_height
        ~requested:(state.msg_scroll + rows_since_pin) layout_entries
    in

    (* Recorded before the rows are written, so the count is the lines above
       the history rather than including them. One-based: terminal rows are. *)
    chat_history_first_row := count_frame_lines chat_buf + 1;
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
        (render_chat_row ~theme:chat_theme chat_buf chat_cols)
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
    (* This keeper's own turn first, then any other keeper's — talking here
       does not stop those, so the pane says they are going. *)
    (* One clock read for the whole group so two rows drawn in the same frame
       cannot report ages a tick apart. The age says how long the turn has
       been going, which is what separates slow from stuck: a keeper turn
       running minutes is ordinary here, and without it these rows look the
       same at three seconds and at thirteen minutes. It changes the text of
       a row, never how many there are, so the row budget is untouched. *)
    let now = Unix.gettimeofday () in
    let sending_age entry =
      match Message_layout.age_text ~now ~since:entry.sent_at with
      | None -> ""
      | Some age -> " · " ^ age
    in
    (* The request the live transcript is already drawing says everything this
       row would: its phase, its age, and the tools it is in. Drawing both put
       a second age and an opaque request id above the ACTIVE TURN line, and
       three ages in one frame read as a stuck screen. The row stays for every
       request the transcript is not covering — a second message sent to the
       same keeper still has to be visible. *)
    let live_request_id =
      match state.msg_live with
      | Some live
        when state.msg_target_keeper_name
             = Some (Masc_tui_types.turn_log_keeper_name live) ->
        Some (Masc_tui_types.turn_log_request_id live)
      | Some _ | None -> None
    in
    (match
       List.partition
         (fun entry -> String.equal entry.sent_request.keeper_name keeper_name)
         state.msg_inflight
     with
     | mine, others ->
         List.iter
           (fun entry ->
             if
               not
                 (Option.equal String.equal live_request_id
                    (Some entry.sent_request.request_id))
             then
             let activity =
               match entry.phase with
               | Turn_streaming -> "sending"
               | Turn_reconciling -> "reconciling"
             in
             box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
               (Printf.sprintf "  (%s %s%s…)" activity
                  (Keeper_chat.compact_request_id entry.sent_request.request_id)
                  (sending_age entry)))
           mine;
         List.iter
           (fun entry ->
             (* The row names the way to stop it. Esc and /interrupt both
                read [msg_live], which is this pane's turn and not this one,
                and the key that would put that keeper on screen is refused
                while any request is in flight -- so an operator reading
                this row had no key at all (#33852). *)
             box_line_styled chat_buf chat_cols ~style:(Theme.recede ())
               (Printf.sprintf "  (also sending to %s: %s%s -- /interrupt %s)"
                  (Keeper_chat.terminal_safe_text
                     entry.sent_request.keeper_name)
                  (Keeper_chat.compact_request_id entry.sent_request.request_id)
                  (sending_age entry)
                  (Keeper_chat.terminal_safe_text
                     entry.sent_request.keeper_name)))
           others);
    (match state.msg_loaded_error with
     | Some detail ->
         (* Cause first. The consequence -- this session only -- is the same
            sentence every time and cost 66 cells before the reader reached the
            part that differs, which the box then cut. *)
         box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
           ("  " ^ detail ^ " \xe2\x80\x94 showing this session only")
     | None -> ());
    (if state.msg_loaded_dropped > 0 then
       box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
         (Printf.sprintf
            "  %d saved row(s) could not be read and are not shown"
            state.msg_loaded_dropped));
    (match state.msg_memory_visibility, state.msg_memory_error with
     | Memory_hidden, _ -> ()
     | (Memory_summary | Memory_full), None -> ()
     | (Memory_summary | Memory_full), Some detail ->
         box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
           ("  memory journal unavailable: " ^ detail));
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
    (* Drawn on the stored position, which is what the budget above counted;
       worded from the clamped one, which is where the frame actually is. The
       two agree except on the single frame after a shrinking history forces a
       clamp, and there the row says so rather than reporting a distance the
       pane did not move. *)
    (if Masc_tui_types.keeper_message_reading_back state then
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
       | Some detail ->
           box_line_styled chat_buf chat_cols ~style:(Theme.warn ())
             ("  older messages could not be loaded: " ^ detail)
       | None -> ());
    (match state.msg_live with
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
                   "FAILOVER IN PROGRESS"
                 else
                   "IN PROGRESS"
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
           if Buffer.length state.msg_input > 0 then
             " · Enter queues your line; it sends when this turn ends"
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
                     | None -> "?"
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
              "  Keeper %s is no longer registered; draft retained; Esc to choose another"
              display_keeper_name
      in
      box_line_styled chat_buf chat_cols ~style:(Theme.bad ()) unavailable_message
    end;
    let input = Buffer.contents state.msg_input in
    let composer =
      Message_layout.composer_lines
        ~max_rows:Message_layout.composer_max_rows input
      |> List.map (Message_layout.input_viewport ~max_cells:(max 0 (chat_cols - 8)))
    in
    (* The cursor sits on the last composer line, which the row budget has
       already made room for. *)
    let visible_input =
      match List.rev composer with [] -> "" | last :: _ -> last
    in
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
        box_line chat_buf chat_cols ((Masc_tui_theme.tone Masc_tui_theme.Accent) ^ prefix ^ Ansi.reset ^ line))
      composer;

    let input_row =
      min (max 1 rows) (rows_above_composer + max 1 (List.length composer))
    in

    box_bottom chat_buf chat_cols;

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
            | 0 -> "Enter:queue for next turn"
            | waiting ->
                Printf.sprintf
                  "Enter:queue (%d waiting)  Ctrl-K:cancel last  Ctrl-P:edit last"
                  waiting)
      in
      match disposition with
      | Queues_behind _ -> queue_hint ()
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
    let return_hint () =
      match state.msg_return with
      | Keeper_chat_return_list -> "Esc:list"
      | Keeper_chat_return_detail -> "Esc:detail"
      | Keeper_chat_return_lanes -> "Esc:Lanes"
    in
    (* The hint is the dispatch's own table, not a retelling of it: both read
       Masc_tui_esc_interrupt.action, so the footer cannot advertise an
       interrupt Esc will not spend itself on, nor say "interrupt sent" after
       the grace window when Esc would leave. *)
    let escape_hint =
      match state.msg_live with
      | Some live ->
          (match
             Masc_tui_esc_interrupt.action ~now_ns:(Mtime_clock.elapsed_ns ())
               (Keeper_chat_transcript.interrupt live.tl_transcript)
           with
           | Masc_tui_esc_interrupt.Launch_interrupt -> "Esc:interrupt turn"
           | Masc_tui_esc_interrupt.Swallow -> "Esc:interrupt sent"
           | Masc_tui_esc_interrupt.Leave -> return_hint ())
      | None -> return_hint ()
    in
    (* Named beside the empty-draft Q arm in the dispatch, and reading the
       same condition it does, chat focus included: the hint exists exactly
       when the key would leave, and is absent exactly when Q is a letter
       someone is typing, the roster holds focus, or something is mid-flight
       for Esc to settle (a capture, a half-edited queued line). The compact
       footer omits it for width, not because the key went away -- the help
       sheet still names it. *)
    let leave_hint =
      if state.keeper_message_focus = Right_pane
         && Buffer.length state.msg_input = 0
         && Option.is_none state.msg_recall_replaces
         && Option.is_none state.voice_capture
      then "  Q:leave"
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
      let paint (span : Masc_tui_command.hint_span) =
        match span with
        | Masc_tui_command.Typed text -> (Masc_tui_theme.tone Masc_tui_theme.Accent) ^ text ^ Ansi.default_fg
        | Masc_tui_command.Wrong text -> (Theme.bad ()) ^ text ^ Ansi.default_fg
        | Masc_tui_command.Untyped text | Masc_tui_command.Detail text -> text
      in
      match
        Masc_tui_command.hint_spans
          (Masc_tui_command.hint (Buffer.contents state.msg_input))
      with
      | [] -> None
      | spans -> Some (String.concat "" (List.map paint spans))
    in
    let footer_hints =
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
           what the operator loses. ^Y keeps the sentence; Esc abandons it. *)
        Printf.sprintf
          "%s  %s^Y send · Esc discard%s"
          bar
          Ansi.dim
          Ansi.reset
      (* Between utterances in continuous mode: on, but nothing recording. A
         mode that is idle looks exactly like one that is off without this. *)
      | None when state.voice_continuous <> None ->
        Printf.sprintf
          "%s대기 중 — 말하면 잡습니다 · ^A to stop%s"
          Ansi.dim
          Ansi.reset
      | None ->
      if state.keeper_message_focus = Left_pane then
        "Up/Down:move  Enter:open  Right/Esc:chat"
      else if chat_cols < 120 then
        let compact_enter_hint =
          match disposition with
          | Queues_behind _ -> (
              match state.msg_recall_replaces with
              | Some _ -> "Enter:replace queued  Ctrl-U:leave it"
              | None ->
                  Printf.sprintf "Enter:queue(%d)  Ctrl-K:cancel  Ctrl-P:edit"
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
    Buffer.add_string chat_buf
      (footer_line state ~max_cells:chat_cols ~hints:footer_hints);

    let input_column =
      Message_layout.input_cursor_column ~terminal_cols:chat_cols
        ~input:visible_input
    in
    let cursor_column =
      input_column + if split then keeper_roster_pane_cols else 0
    in
    if split then begin
      let left_buf = Buffer.create 1024 in
      keeper_roster_pane
        ~focused:(state.keeper_message_focus = Left_pane)
        state ~rows ~cols:keeper_roster_pane_cols left_buf;
      write_two_panes buf ~left_cols:keeper_roster_pane_cols ~left:left_buf
        ~right:chat_buf
    end;
    finish_frame_with_strip state ~surface_key:"keeper-message"
      ~clamped:(Message_scroll scroll)
      ~cursor:
        (if state.keeper_message_focus = Left_pane then
           Frame_presenter.Hidden
         else
           Frame_presenter.Visible_at
             { row = input_row; column = cursor_column })
      ~rows ~cols buf
    end
