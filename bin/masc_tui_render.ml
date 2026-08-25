(** TUI rendering functions — split from masc_tui.ml (#3808) *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi

module Frame_presenter = Masc_tui_frame_presenter
module Board_detail = Masc_tui_board_detail
module Message_layout = Masc_tui_message_layout
module Metrics_tail = Masc_tui_metrics_tail
module Observation_layout = Masc_tui_observation_layout
module Keeper_activity = Masc_tui_keeper_activity
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript
module Render_schedule = Masc_tui_render_schedule
module Markdown = Masc_tui_markdown
module Markdown_cache = Masc_tui_markdown_render_cache
module Composer = Masc_tui_composer
module Keeper_control = Masc_tui_keeper_control
module Task_selection = Masc_tui_task_selection
module Tool_tree = Masc_tui_tool_tree
module Planning_detail = Masc_tui_planning_detail
module Status = Masc.Keeper_status_runtime

(* Every surface lays out against a viewport one row shorter than the
   terminal: the top row belongs to the surface strip, prepended when a frame
   is finished. Shadowing the probe here (and, via open order, in masc_tui.ml)
   keeps all sixteen surfaces' row budgets and the input layer's paging math
   in step without touching each formula. *)
let get_terminal_size () =
  let rows, cols = Masc_tui_ansi.get_terminal_size () in
  (max 1 (rows - 1), cols)

let frame_lines buf =
  match List.rev (String.split_on_char '\n' (Buffer.contents buf)) with
  | "" :: reversed -> List.rev reversed
  | reversed -> List.rev reversed

(* A frame, and what it had to clamp to build itself. The clamp travels beside
   the frame rather than being written into the state mid-draw; see
   [clamped_scroll]. Surfaces that clamp nothing pass nothing. *)
let finish_frame ?clamped ~surface_key ~cursor ~rows ~cols buf :
    Frame_presenter.frame * clamped_scroll option =
  ( { surface_key;
      terminal_rows = rows;
      terminal_cols = cols;
      cursor;
      lines = frame_lines buf;
    }
  , clamped )

(* Terminal dress for the markdown a keeper writes. The marker is the noise:
   a backticked identifier should read as the identifier, and a fenced diff
   should keep the alignment that made it worth fencing. Colours stay inside
   the palette the renderer already uses, so a chat row is still recognisably
   one of this TUI's rows. *)
let chat_markdown_palette : Markdown.palette =
  { strong = (Ansi.bold, Ansi.reset)
  ; emphasis = (Ansi.dim, Ansi.reset)
  ; code = (Ansi.cyan, Ansi.reset)
  (* Bold alone. [white] is a colour like any other -- on a light background
     it is the background -- so painting a heading with it hid the heading on
     exactly the terminals that read it as text. Bold already says heading. *)
  (* Which heading is inside which, said the way a terminal can: the top
     level is underlined as well as bold, the next is bold, and the rest are
     bold and dim so they still read as headings without competing with the
     two above. One span for every level drew a document with no shape. *)
  ; heading =
      (fun level ->
        if level <= 1 then (Ansi.bold ^ Ansi.underline, Ansi.reset)
        else if level = 2 then (Ansi.bold, Ansi.reset)
        else (Ansi.bold ^ Ansi.dim, Ansi.reset))
  ; quote = (Ansi.dim, Ansi.reset)
  ; link_text = (Ansi.blue, Ansi.reset)
  ; link_target = (Ansi.dim, Ansi.reset)
  ; rule = (Ansi.gray, Ansi.reset)
  ; bullet = "\xe2\x80\xa2"
  ; code_gutter = "\xe2\x94\x82 "
  (* Reverse video uses the terminal's own foreground and background, so the
     language banner stays legible on both light and dark themes. *)
  ; code_header = (Ansi.reverse, Ansi.reset)
  ; code_border = (Ansi.gray, Ansi.reset)
  ; quote_gutter = "\xe2\x96\x8f "
  ; table_header = (Ansi.bold, Ansi.reset)
  ; table_gutter = " \xe2\x94\x82 "
  (* Fenced-code tokens, inside the cyan the plain code span already uses:
     one hue per role a keeper's eye scans for -- what binds, what is data,
     what the reader can skip. *)
  ; code_keyword = (Theme.Syntax.keyword, Ansi.reset)
  ; code_string = (Theme.Syntax.string, Ansi.reset)
  ; code_comment = (Ansi.gray, Ansi.reset)
  ; code_number = (Ansi.magenta, Ansi.reset)
  ; code_type = (Ansi.bold ^ Ansi.blue, Ansi.reset)
  }

let chat_markdown ~width body =
  Markdown.render ~palette:chat_markdown_palette ~width body

(* The palette above is compiled into this binary today. The revisions remain
   explicit inputs because #30196 can make the terminal palette runtime state;
   that owner will advance [chat_markdown_palette_generation] instead of
   teaching the cache which colour fields matter. *)
let chat_markdown_theme_revision = 1
let chat_markdown_palette_generation = 0
let chat_markdown_cache_capacity = 128

type chat_markdown_identity = {
  cmi_style : Message_layout.style;
  cmi_keeper_name : string;
  cmi_request_id : string;
  cmi_observed_at : float;
  cmi_entry_index : int;
}

let equal_chat_markdown_identity left right =
  left.cmi_style = right.cmi_style
  && String.equal left.cmi_keeper_name right.cmi_keeper_name
  && String.equal left.cmi_request_id right.cmi_request_id
  && Float.equal left.cmi_observed_at right.cmi_observed_at
  && left.cmi_entry_index = right.cmi_entry_index

let chat_markdown_cache =
  Markdown_cache.create ~capacity:chat_markdown_cache_capacity
    ~equal:equal_chat_markdown_identity

let cached_chat_markdown ~(entry : Message_layout.entry) ~width =
  let source =
    match entry.markdown_source with
    | Message_layout.Markdown_stable
        { keeper_name; request_id; observed_at; entry_index } ->
        Markdown_cache.Stable_source
          { identity =
              { cmi_style = entry.style;
                cmi_keeper_name = keeper_name;
                cmi_request_id = request_id;
                cmi_observed_at = observed_at;
                cmi_entry_index = entry_index;
              };
            text = entry.body;
          }
    | Message_layout.Markdown_streaming ->
        Markdown_cache.Streaming_source entry.body
  in
  Markdown_cache.render chat_markdown_cache
    ~theme_revision:chat_markdown_theme_revision
    ~palette_generation:chat_markdown_palette_generation ~width
    ~renderer:chat_markdown ~source

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
  Printf.sprintf "(%d reasoning line(s) folded - /thinking to unfold)"
    (List.length lines)

let render_chat_row buf cols (row : Message_layout.row) =
  match row.kind with
  | Message_layout.Body ->
      (* The two indent cells the layout reserves become a gutter in the
         block's own colour, so where one block ends and the next begins
         reads at a glance instead of from the headings alone. *)
      let text = row.text in
      let dress rest =
        (* A pasted URL reads as a link, not prose. Closed by restoring the
           row's own style — a bare reset would strip it from everything
           after the link. *)
        Masc_tui_message_layout.dress_bare_links
          ~open_style:(Ansi.underline ^ Ansi.blue)
          ~close_style:(Ansi.reset ^ Chat_theme.body row.style)
          rest
      in
      if
        String.length text >= 2 && Char.equal text.[0] ' '
        && Char.equal text.[1] ' '
      then (
        let rest = String.sub text 2 (String.length text - 2) in
        box_line buf cols
          (Printf.sprintf "%s\xe2\x94\x82%s %s%s%s"
             (Chat_theme.origin row.style) Ansi.reset
             (Chat_theme.body row.style) (dress rest) Ansi.reset))
      else
        box_line_styled buf cols ~style:(Chat_theme.body row.style)
          (dress text)
  | Message_layout.Metadata (Message_layout.Continued_at { timestamp }) ->
      box_line_styled buf cols ~style:Ansi.dim
        (Printf.sprintf "[%s]" timestamp)
  | Message_layout.Metadata
      (Message_layout.Origin { timestamp; role_label; request_label }) ->
      let badge =
        Printf.sprintf "%s%s %s %s" (Chat_theme.origin row.style) Ansi.reverse
          role_label Ansi.reset
      in
      box_line buf cols
        (Printf.sprintf "%s[%s]%s %sFrom%s %s %s%s%s" Ansi.dim timestamp
           Ansi.reset Ansi.dim Ansi.reset badge Ansi.dim request_label
           Ansi.reset)

(* The composer row every surface carries on its last terminal line.

   The recipient is whichever keeper the roster cursor points at. That cursor
   keeps its place while the operator works on another surface, so the row goes
   on naming the last keeper they pointed at rather than emptying out. Because
   the cursor can also move on its own -- a refresh drops a row and the one
   below slides up -- the name is drawn every frame instead of being captured
   when the draft was started. *)
let composer_of_state (state : state) : Composer.t =
  let target =
    match selected_keeper state with
    | None -> Composer.No_target
    | Some keeper ->
        if keeper_available_for_new_message state keeper.k_name then
          Composer.Ready keeper.k_name
        else
          Composer.Unreachable
            { keeper = keeper.k_name
            ; reason =
                (match state.keepers_error with
                 | Some _ -> "keeper list unread"
                 | None -> "no longer in the roster")
            }
  in
  { Composer.target
  ; focus = (if state.composer_focused then Composer.Focused else Composer.Unfocused)
  ; draft = Buffer.contents state.msg_input
  }

let composer_prompt_text composer =
  Printf.sprintf " %s %s " "\xe2\x80\xba" (Composer.prompt composer)

(* Unfocused the row is dim and says which key opens it; focused it is drawn in
   full and carries the cursor. Either way it occupies the same single row, so
   taking focus does not move the frame above it. *)
(* The one line that tells an operator on any surface that a keeper is holding
   a tool call. Returns None when nothing is held, which is the common case. *)
let awaiting_approval_notice (state : state) =
  match state.msg_live with
  | None -> None
  | Some live -> (
      match Keeper_chat_transcript.awaiting_approval live with
      | None -> None
      | Some awaiting ->
          let where =
            match state.view with
            | Keepers Keeper_message -> ""
            | Overview | Acting | Keepers _ | Lanes | Board | Approvals | Planning
            | Schedules | Verification | Harness | Fusion | Repositories | Changes
            | Connectors | Runtime | Config | Resources | Tools | System_logs ->
                "  (2 then m to answer)"
          in
          Some
            (Printf.sprintf "  %s is holding %s%s"
               (Terminal_text.single_line
                  (Keeper_chat_transcript.keeper_name live))
               (Terminal_text.single_line awaiting.Keeper_chat_transcript.tool_name)
               where))

(* The server names itself in every footer, because "which masc is this"
   is a question every surface can raise and none of them answered: the tail
   said [Port: 8935] and two checkouts on that port read identically. *)
let footer_line ?(status = []) (state : state) ~hints =
  let build =
    match state.server_identity with
    | None -> []
    | Some identity ->
        [ Masc_tui_footer.Server_build
            { version = identity.Tui_decode.sid_version
            ; commit = identity.Tui_decode.sid_binary_commit
            }
        ]
  in
  Masc_tui_footer.line ~status:(status @ build) ~dim:Ansi.dim ~reset:Ansi.reset
    ~port:state.port ~hints ()

let composer_line state ~cols =
  let composer = composer_of_state state in
  let prompt = composer_prompt_text composer in
  let tone =
    match (composer.Composer.focus, composer.Composer.target) with
    | Composer.Focused, _ -> Ansi.cyan
    | Composer.Unfocused, Composer.Ready _ -> Ansi.dim
    | Composer.Unfocused, (Composer.No_target | Composer.Unreachable _) ->
        Ansi.dim
  in
  let draft = Terminal_text.single_line composer.Composer.draft in
  let hint =
    match (composer.Composer.focus, composer.Composer.target) with
    | Composer.Focused, _ -> ""
    | Composer.Unfocused, Composer.Ready _ ->
        Printf.sprintf "  (%s to write)" Composer.focus_key
    | Composer.Unfocused, (Composer.No_target | Composer.Unreachable _) -> ""
  in
  let body =
    if String.equal draft "" then prompt ^ hint else prompt ^ draft
  in
  (* A held tool call is drawn on whatever surface the operator is looking at.
     Its prompt lives in the chat pane, and a turn holding a call is denied
     when the wait runs out -- so an operator reading the Board would lose the
     call without ever seeing that it was waiting. This line says a keeper is
     waiting and where to answer; the answer itself stays in the chat pane,
     where it is unambiguous which keeper and which call it is for. *)
  match awaiting_approval_notice state with
  | Some notice -> Theme.warn ^ fit_width notice cols ^ Ansi.reset
  | None -> tone ^ fit_width body cols ^ Ansi.reset

let composer_cursor state ~rows ~cols =
  let composer = composer_of_state state in
  match composer.Composer.focus with
  | Composer.Unfocused -> Frame_presenter.Hidden
  | Composer.Focused ->
      let prompt_cells =
        Message_layout.display_width (composer_prompt_text composer)
      in
      let draft_cells =
        Message_layout.display_width
          (Terminal_text.single_line composer.Composer.draft)
      in
      Frame_presenter.Visible_at
        { row = rows
        ; column = Composer.cursor_column ~prompt_cells ~draft_cells ~terminal_cols:cols
        }

(* The strip above every surface: the Tab ring with the active family
   highlighted. Wider terminals see the whole ring; narrower ones see a
   window around the active entry with how many entries hide past each edge,
   so position in the cycle stays readable at any width. *)
let surface_strip (state : state) ~cols =
  let ring = Masc_tui_types.surface_ring in
  let n = List.length ring in
  let active = Masc_tui_types.surface_ring_index state.view in
  (* A count rides the entry it belongs to, so pending work is visible from
     every surface without a spare row. Zero draws nothing -- an always-on
     badge would be texture, not information. *)
  let badge surface =
    match (surface : surface) with
    | Approvals ->
        (match List.length (Masc_tui_types.approval_items state) with
         | 0 -> ""
         | pending -> Printf.sprintf "\xc2\xb7%d" pending)
    | _ -> ""
  in
  let label i =
    let surface, name = List.nth ring i in
    name ^ badge surface
  in
  (* Plain-cell width of entry [i] inside a window starting at [lo]. *)
  let entry_width ~lo i =
    (* Cells, not bytes: the Approvals badge's middle dot is two bytes and
       one cell, and a byte count windows the strip one entry early. *)
    Message_layout.display_width (label i)
    + (if i = active then 1 else 0)
    + (if i > lo then 2 else 0)
  in
  let window_width lo hi =
    let rec sum i acc =
      if i > hi then acc else sum (i + 1) (acc + entry_width ~lo i)
    in
    sum lo 0
  in
  let budget = max 8 (cols - 1) in
  let lo, hi =
    if window_width 0 (n - 1) <= budget then (0, n - 1)
    else begin
      (* Markers for hidden entries cost room; reserve it up front. *)
      let budget = max 8 (budget - 10) in
      let lo = ref active and hi = ref active in
      let grew = ref true in
      while !grew do
        grew := false;
        if !hi + 1 < n && window_width !lo (!hi + 1) <= budget then begin
          incr hi;
          grew := true
        end;
        if !lo > 0 && window_width (!lo - 1) !hi <= budget then begin
          decr lo;
          grew := true
        end
      done;
      (!lo, !hi)
    end
  in
  let parts = Buffer.create 128 in
  Buffer.add_char parts ' ';
  if lo > 0 then
    Buffer.add_string parts
      (Printf.sprintf "%s\xe2\x80\xb9%d%s " Ansi.dim lo Ansi.reset);
  for i = lo to hi do
    if i > lo then Buffer.add_string parts "  ";
    if i = active then
      Buffer.add_string parts
        (Ansi.bold ^ Theme.info ^ "\xe2\x96\xb8" ^ label i ^ Ansi.reset)
    else Buffer.add_string parts (Ansi.dim ^ label i ^ Ansi.reset)
  done;
  if hi < n - 1 then
    Buffer.add_string parts
      (Printf.sprintf " %s%d\xe2\x80\xba%s" Ansi.dim (n - 1 - hi) Ansi.reset);
  Buffer.contents parts

(* Side-by-side panes share one threshold and one context-pane width, so
   every split surface folds at the same terminal size. *)
let keeper_split_threshold_cols = Masc_tui_roster_pane.threshold_cols
let keeper_roster_pane_cols = Masc_tui_roster_pane.pane_cols

(* The roster shows when the terminal can spare its columns and the reader
   has not put it away. Width is the terminal's answer, [roster_pane_hidden]
   is theirs, and hiding survives a resize because it is a decision rather
   than a measurement. *)
let keeper_roster_pane_shown (state : state) ~cols =
  Masc_tui_roster_pane.shown ~hidden:state.roster_pane_hidden ~cols


(* Finish a frame with the strip on top. Surfaces measured cursor rows inside
   their own frame, so a visible cursor shifts down with the prepend, and the
   declared height grows back to the terminal's real row count. *)
let finish_frame_with_strip (state : state) ?clamped ~surface_key ~cursor ~rows
    ~cols buf =
  let cursor =
    match cursor with
    | Frame_presenter.Hidden -> Frame_presenter.Hidden
    | Frame_presenter.Visible_at { row; column } ->
      Frame_presenter.Visible_at { row = row + 1; column }
  in
  let framed = Buffer.create (Buffer.length buf + 160) in
  Buffer.add_string framed (surface_strip state ~cols);
  Buffer.add_char framed '\n';
  Buffer.add_buffer framed buf;
  finish_frame ?clamped ~surface_key ~cursor ~rows:(rows + 1) ~cols framed

(* Close a surface: pad its frame to the row above the composer, then draw the
   composer on the terminal's last row.

   The padding is what keeps the two in step. Each surface computes its own
   height, and one that came out short used to leave its footer stranded
   partway up the screen; now it would push the composer up with it, and the
   row an operator reaches for would move per surface. *)
let finish_surface (state : state) ?clamped ~surface_key ~rows ~cols buf =
  let body_rows = max 0 (rows - Composer.rows_for ~terminal_rows:rows) in
  let drawn = frame_lines buf in
  let body =
    if List.length drawn <= body_rows then
      drawn @ List.init (body_rows - List.length drawn) (fun _ -> "")
    else
      (* A surface that came out taller than its budget loses its last rows
         rather than the composer. The body is already scrollable and the
         composer is a fixed contract -- the row an operator reaches for cannot
         be the one that disappears when a surface miscounts. *)
      List.filteri (fun index _ -> index < body_rows) drawn
  in
  let framed = Buffer.create (String.length (Buffer.contents buf) + 256) in
  List.iter
    (fun line ->
       Buffer.add_string framed line;
       Buffer.add_char framed '\n')
    body;
  Buffer.add_string framed (composer_line state ~cols ^ "\n");
  finish_frame_with_strip state ?clamped ~surface_key
    ~cursor:(composer_cursor state ~rows ~cols) ~rows ~cols framed

(* Exhaustive over [connection_status]: a new state is a compile error
   here rather than an unexplained [disconnected] on screen. *)
let connection_badge : Masc_tui_types.connection_status -> string = function
  | Connected as status ->
      Theme.ok ^ "[" ^ connection_status_label status ^ "]" ^ Ansi.reset
  | (Degraded | Connecting | Reconnecting) as status ->
      Theme.warn ^ "[" ^ connection_status_label status ^ "]" ^ Ansi.reset
  | Disconnected as status ->
      Theme.bad ^ "[" ^ connection_status_label status ^ "]" ^ Ansi.reset
;;

let workspace_health_label = function
  | Workspace_health_critical -> "critical"
  | Workspace_health_bad -> "bad"
  | Workspace_health_risk -> "risk"
  | Workspace_health_warning -> "warning"
  | Workspace_health_degraded -> "degraded"
  | Workspace_health_initializing -> "initializing"
  | Workspace_health_ok -> "ok"
  | Workspace_health_unknown -> "unknown"

let workspace_health_color = function
  | Workspace_health_critical
  | Workspace_health_bad
  | Workspace_health_risk -> Theme.bad
  | Workspace_health_warning
  | Workspace_health_degraded
  | Workspace_health_initializing
  | Workspace_health_unknown -> Theme.warn
  | Workspace_health_ok -> Theme.ok

let attention_severity_label = function
  | Attention_critical -> "critical"
  | Attention_bad -> "bad"
  | Attention_warning -> "warn"
  | Attention_info -> "info"

let attention_severity_color = function
  | Attention_critical | Attention_bad -> Theme.bad
  | Attention_warning -> Theme.warn
  | Attention_info -> Ansi.cyan

let task_line (task : task) =
  let status = Masc_domain.task_status_to_string task.status in
  let assignee =
    match Masc_domain.task_assignee_of_status task.status with
    | Some name -> Printf.sprintf " @%s" (Terminal_text.single_line name)
    | None -> ""
  in
  Printf.sprintf "%s [%s] %s (%s%s) %s"
    (task_status_icon task.status)
    (Terminal_text.single_line task.id)
    (Terminal_text.single_line task.title)
    status
    assignee
    (priority_indicator task.priority)

(** Project the shared Overview row budget and its sanitized variable inputs. *)
let overview_layout (state : state) ~terminal_rows =
  let attention_items =
    match state.overview with
    | None -> []
    | Some overview -> overview.ov_attention_items
  in
  let tasks_error = Terminal_text.optional_single_line state.tasks_error in
  let row_budget =
    Render_schedule.allocate_overview ~terminal_rows
      ~has_cluster:(Option.is_some state.overview)
      ~attention_count:(List.length attention_items)
      ~event_count:(List.length state.events)
      ~task_count:(List.length state.tasks)
      ~has_task_error:(Option.is_some tasks_error)
  in
  attention_items, tasks_error, row_budget

(** Render the Overview surface (Dashboard V2 shell/briefing summary). *)
let render_overview (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf "%s  %s[%s]%s  %s  %s"
    (screen_title " MASC Overview")
    Ansi.cyan (Terminal_text.single_line state.workspace) Ansi.reset timestamp
    (connection_badge state.connection_status) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let ov = state.overview in
  let overview_error =
    Terminal_text.optional_single_line state.overview_error
  in

  (* Summary line *)
  let summary_line =
    match (ov, overview_error) with
    | _, Some err ->
        Printf.sprintf "  %s(data unreliable: %s)%s" Theme.bad
          (fit_width err (cols - 24))
          Ansi.reset
    | None, None ->
        Printf.sprintf "  %s(no overview data — press 'r' to refresh)%s"
          Ansi.dim Ansi.reset
    | Some o, None ->
        let health_color = workspace_health_color o.ov_workspace_health in
        let health_label = workspace_health_label o.ov_workspace_health in
        let approval_count =
          match state.approval_snapshot, state.approvals_error with
          | Some snapshot, None -> string_of_int snapshot.aps_visible_count
          | None, _ | Some _, Some _ -> "?"
        in
        (* Keepers and MCP clients are counted apart: a row reading
           "Agents: 2" over a runtime with ten keepers named the wrong
           population. *)
        Printf.sprintf
          "  Health: %s%s%s  Keepers: %d  MCP agents: %d  Approvals: %s  \
           Incidents: %d"
          health_color health_label Ansi.reset o.ov_keepers o.ov_mcp_agents
          approval_count o.ov_incident_count
  in
  box_line buf cols summary_line;

  (* Cluster/project line *)
  (match ov with
   | None -> ()
   | Some o ->
         (* The transport summary rides this row rather than taking one of its
            own: a narrow viewport must not trade an event line for it. A path
            that is not listening reads "off" instead of zero sessions, and
            dropped events are called out because a steady queue that drops is
            not a healthy transport. *)
         let transport_summary =
           match state.transport with
           | None -> ""
           | Some t ->
             let websocket =
               match t.th_websocket_sessions with
               | Some sessions -> Printf.sprintf "ws %d" sessions
               | None -> "ws off"
             in
             let grpc =
               match t.th_grpc_port with
               | Some port -> Printf.sprintf "grpc :%d" port
               | None -> "grpc off"
             in
             let dropped =
               if t.th_events_dropped = 0 then ""
               else Printf.sprintf "  dropped %d" t.th_events_dropped
             in
             (* No padding here: this rides the tail of the row, so a long
                value trims itself against the border instead of pushing the
                cluster and project columns around. *)
             Printf.sprintf "  %s/%s  sse %d  %s  %s%s"
               (* Both come off a closed type now, so there is no arbitrary
                  text to sanitize here. *)
               (Masc.Transport_metrics.primary_path_kind_to_string t.th_primary_path)
               (Masc.Transport_metrics.queue_pressure_kind_to_string
                  t.th_queue_pressure)
               t.th_sse_sessions websocket grpc dropped
         in
         (* The runtime event feed rides the same tail. "live N" counts the
            frames this stream has delivered; a closed feed keeps its count
            and says why it closed, so a stream that dropped after a thousand
            events and one that never opened do not read alike. *)
         let observer_summary =
           match state.observer with
           | Observer_off -> ""
           | Observer_opening -> "  feed: opening"
           | Observer_live { events; _ } -> Printf.sprintf "  feed: live %d" events
           | Observer_closed { events; _ } ->
               (* The reason is in Recent Events and on the Acting status
                  row; here it would push the count off a narrow row. *)
               Printf.sprintf "  feed: closed after %d" events
         in
         let cluster_line =
           Printf.sprintf "  Cluster: %s%s%s  Project: %s%s%s"
             Ansi.dim
             (fit_width (Terminal_text.single_line o.ov_cluster) 24)
             Ansi.reset
             (fit_width (Terminal_text.single_line o.ov_project) 20)
             transport_summary observer_summary
       in
       box_line buf cols cluster_line);

  box_divider buf cols;

  (* Attention panel *)
  let attention_items, tasks_error, row_budget =
    overview_layout state ~terminal_rows:rows
  in
  (* Three verticals plus two panels have to add up to the box the rest of the
     screen draws. An odd remainder used to be dropped by the division, so on
     any odd width the Attention/Events band ended one column short of every
     other row and the right edge stepped in and back out. The odd column goes
     to the right panel. *)
  let panel_width = (cols - 3) / 2 in
  let right_panel_width = cols - 3 - panel_width in
  let attention_title = " Attention " in
  let event_count = List.length state.events in
  let event_window =
    Render_schedule.project_overview_event_window ~event_count
      ~visible_rows:row_budget.attention_rows state.overview_event_scroll
  in
  let events_title =
    let title =
      if event_window.oew_first_position = 0 then " Recent Events "
      else
        Printf.sprintf " Recent Events %d-%d/%d "
          event_window.oew_first_position event_window.oew_last_position
          event_count
    in
    fit_width title (max 0 panel_width)
  in
  Buffer.add_string buf (Printf.sprintf " %s%s%s%s%s%s\n"
    Ansi.bold attention_title Ansi.reset
    (String.make (max 0 (panel_width - String.length attention_title)) ' ')
    (Ansi.gray ^ Ansi.box_v ^ Ansi.reset)
    events_title);

  for i = 0 to row_budget.attention_rows - 1 do
    let attention_str =
      if i < List.length attention_items then
        let a = List.nth attention_items i in
        let sev_color = attention_severity_color a.ai_severity in
        let severity_label = attention_severity_label a.ai_severity in
          (* Fitted once, by the fit that draws the row. Fitting the summary
             here as well meant guessing how many cells the label ahead of it
             spends, and the events column beside this one guessed one too
             many: every event row came out a cell over its budget and was
             marked truncated whether or not anything was cut. The severity
             label keeps its own fit -- that one is a fixed column, not a
             guess at the rest of the row. *)
          Printf.sprintf "%s[%s]%s %s"
            sev_color (fit_width severity_label 5) Ansi.reset
            (Terminal_text.single_line a.ai_summary)
      else ""
    in
    let event_str =
      let event_index = i + event_window.oew_offset in
      if event_index < event_count then
        let e = List.nth state.events event_index in
        Printf.sprintf "%s[%s]%s %s"
          Ansi.dim e.timestamp Ansi.reset
          (Terminal_text.single_line e.content)
      else ""
    in
    Buffer.add_string buf (Printf.sprintf "  %s %s%s%s %s\n"
      (fit_width attention_str (panel_width - 2))
      Ansi.gray Ansi.box_v Ansi.reset
      (fit_width event_str (right_panel_width - 2)))
  done;

  box_divider buf cols;

  (* Tasks section *)
  Buffer.add_string buf
    (Printf.sprintf " %sTasks%s\n" Ansi.bold Ansi.reset);

  (match tasks_error with
   | Some err when row_budget.task_error_rows > 0 ->
        box_line buf cols
          (Theme.bad ^ "  "
          ^ fit_width err (cols - 8)
          ^ Ansi.reset)
   | None | Some _ -> ());
  if row_budget.task_rows > 0 && List.is_empty state.tasks
     && Option.is_none tasks_error then
    box_line buf cols (Ansi.dim ^ "  (no tasks)" ^ Ansi.reset)
  else begin
    (* The panel is shorter than the list can get, so the cursor can sit below
       the last visible row; the window follows it the way Board's does. *)
    let task_scroll_offset =
      max 0 (state.task_cursor - row_budget.task_rows + 1)
    in
    for i = 0 to row_budget.task_rows - 1 do
      let idx = i + task_scroll_offset in
      if idx < List.length state.tasks then begin
        let t = List.nth state.tasks idx in
        let is_selected = state.task_focus && idx = state.task_cursor in
        let content =
          if is_selected then
            Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ task_line t
          else "  " ^ task_line t
        in
        box_line buf cols content
      end
    done
  end;

  (* Carry the frame to the bottom of the terminal. Without this the surface
     stops where its content does and the footer under it lands wherever that
     happens to be -- halfway up a tall window. *)
  for _ = 1 to row_budget.filler_rows do
    box_empty buf cols
  done;

  box_bottom buf cols;

  let overview_hint =
    if state.task_focus then "j/k:tasks  Enter:detail  esc:events"
    else "j/k:events  t:tasks"
  in
  Buffer.add_string buf
    (footer_line state
       ~status:[ Masc_tui_footer.Refresh_interval state.refresh_interval ]
       ~hints:
         (Printf.sprintf "%s  q:quit  r:refresh  Tab:next  2:keepers"
            overview_hint));

  finish_surface state ~clamped:(Overview_events event_window.oew_offset) ~surface_key:"overview" ~rows:terminal_rows
      ~cols buf

(** Render one backlog task in full, from the same load the Overview list was
    projected from. The dispatch falls back to the Overview when the row is no
    longer in the backlog, so the task argument always exists here. *)
let render_task_detail (state : state) (task : Masc_domain.task) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf "%s  %s[%s]%s  %s  %s"
    (screen_title " MASC Task")
    Ansi.cyan (fit_width task.id 20) Ansi.reset timestamp
    (connection_badge state.connection_status) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  box_line buf cols
    (Ansi.bold ^ "  "
    ^ fit_width (Terminal_text.single_line task.title) (cols - 6)
    ^ Ansi.reset);
  (* Each status carries its own timestamps and actors; one exhaustive match
     keeps the row and the status from disagreeing about who did what. The
     note lines stay counted so the body budget below shrinks with them --
     a verification id must not push the helper row off the screen. *)
  let status_line, note_lines =
    match task.task_status with
    | Masc_domain.Todo -> ("todo — unclaimed", [])
    | Masc_domain.Claimed { assignee; claimed_at } ->
        ( Printf.sprintf "claimed by %s at %s"
            (Terminal_text.single_line assignee)
            (Terminal_text.single_line claimed_at)
        , [] )
    | Masc_domain.InProgress { assignee; started_at } ->
        ( Printf.sprintf "in progress by %s since %s"
            (Terminal_text.single_line assignee)
            (Terminal_text.single_line started_at)
        , [] )
    | Masc_domain.AwaitingVerification
        { assignee; submitted_at; verification_id; _ } ->
        ( Printf.sprintf "awaiting verification by %s, submitted %s"
            (Terminal_text.single_line assignee)
            (Terminal_text.single_line submitted_at)
        , [Printf.sprintf "verification %s"
             (Terminal_text.single_line verification_id)] )
    | Masc_domain.Done { assignee; completed_at; notes } ->
        ( Printf.sprintf "done by %s at %s"
            (Terminal_text.single_line assignee)
            (Terminal_text.single_line completed_at)
        , match notes with None -> [] | Some note -> [note] )
    | Masc_domain.Cancelled { cancelled_by; cancelled_at; reason } ->
        ( Printf.sprintf "cancelled by %s at %s"
            (Terminal_text.single_line cancelled_by)
            (Terminal_text.single_line cancelled_at)
        , match reason with None -> [] | Some r -> [r] )
  in
  box_line buf cols
    (Ansi.dim ^ "  status   " ^ Ansi.reset
    ^ fit_width status_line (cols - 16));
  List.iter
    (fun note ->
       box_line buf cols
         (Ansi.dim ^ "           " ^ fit_width
            (Terminal_text.single_line note) (cols - 16)
         ^ Ansi.reset))
    note_lines;
  box_line buf cols
    (Ansi.dim ^ Printf.sprintf "  created  %s by %s  priority %d  cycles %d"
       (Terminal_text.single_line task.created_at)
       (match task.created_by with
        | Some by -> Terminal_text.single_line by
        | None -> "-")
       task.priority task.cycle_count
    ^ Ansi.reset);
  box_divider buf cols;

  (* Labeled block: the label rides the first wrapped line and continuation
     lines keep the text column, so long handoff summaries stay readable. *)
  let labeled_lines label text =
    let width = max 10 (cols - 16) in
    Message_layout.wrap_words ~max_cells:width
      (Terminal_text.single_line text)
    |> List.mapi
         (fun index line ->
            if index = 0 then Printf.sprintf "  %-8s %s" label line
            else Printf.sprintf "           %s" line)
  in
  let some_lines label = function
    | None -> []
    | Some text -> labeled_lines label text
  in
  let list_lines label items =
    List.concat_map (fun item -> labeled_lines label item) items
  in
  let body_lines =
    (if String.equal task.description "" then [] else labeled_lines "what" task.description)
    @ (match task.handoff_context with
       | None -> []
       | Some handoff ->
           some_lines "why" handoff.Masc_domain.reason
           @ (if String.equal handoff.Masc_domain.summary "" then []
              else labeled_lines "handoff" handoff.Masc_domain.summary)
           @ some_lines "next" handoff.Masc_domain.next_step
           @ some_lines "failure" handoff.Masc_domain.failure_mode
           @ list_lines "evidence" handoff.Masc_domain.evidence_refs)
    @ (match task.contract with
       | None -> []
       | Some contract ->
           (if contract.Masc_domain.strict then
              ["  contract strict"]
            else [])
           @ list_lines "done-when" contract.Masc_domain.completion_contract
           @ list_lines "evidence" contract.Masc_domain.required_evidence)
    @ list_lines "file" task.files
  in
  let total_lines = List.length body_lines in
  (* Chrome above and below the scrolling body: top border, header, divider,
     the title block, the bottom border, the helper row and the composer row.
     Clamped through the same helper the keeper log pane uses. Ten, not nine:
     at nine the frame came out one row taller than its budget, which cost the
     surface the composer row rather than a body row. On top of the ten, the
     status note lines vary by state -- a verification id or cancellation
     reason must shrink the body, not push rows off the bottom. *)
  let content_height = max 1 (rows - 10 - List.length note_lines) in
  let offset =
    min state.task_detail_scroll
      (Metrics_tail.maximum_scroll ~entry_count:total_lines ~content_height)
  in
  for i = 0 to content_height - 1 do
    let line_index = i + offset in
    let text =
      if line_index < total_lines then
        List.nth body_lines line_index
      else ""
    in
    box_line buf cols
      (Ansi.dim ^ fit_width (Terminal_text.single_line text) (cols - 8)
      ^ Ansi.reset)
  done;

  box_bottom buf cols;
  Buffer.add_string buf
    (Printf.sprintf "%s  j/k:scroll  esc:back  r:refresh  | Task %s | Refresh: %.0fs%s\n"
       Ansi.dim (Terminal_text.single_line task.id)
       state.refresh_interval Ansi.reset);

  finish_surface state ~clamped:(Task_detail offset) ~surface_key:"task-detail" ~rows:terminal_rows ~cols buf

(** Render the Approvals surface (pending confirmations). *)
let render_approvals (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let approvals = approval_items state in
  let scope, visible_count, total_count, hidden_count =
    match state.approval_snapshot with
    | None -> "-", "?", "?", "?"
     | Some snapshot ->
        ( (if snapshot.aps_filter_active then
             Terminal_text.single_line_or ~default:"?"
               snapshot.aps_actor_filter
           else "all")
        , string_of_int snapshot.aps_visible_count
        , string_of_int snapshot.aps_total_count
        , string_of_int snapshot.aps_hidden_count )
  in
  let count = List.length approvals in
  let action_inflight =
    Masc_tui_operator_projection.Flow.action_inflight state.approval_flow
  in
  let action_badge = if action_inflight then "  [submitting]" else "" in
  let header =
    Printf.sprintf
      "%s (%s/%s, hidden %s, actor %s)  %s  %s%s"
      (screen_title " MASC Approvals")
      visible_count total_count hidden_count scope timestamp
      (connection_badge state.connection_status) action_badge
  in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let approvals_error =
    Terminal_text.optional_single_line state.approvals_error
  in
  if count = 0 then begin
    (match state.approval_snapshot, approvals_error with
     | _, Some err ->
         box_line buf cols
           (Theme.bad ^ "  (data unreliable: "
           ^ fit_width err (cols - 24)
           ^ ")" ^ Ansi.reset)
     | None, None ->
         box_line buf cols
           (Ansi.dim ^ "  (no approval data — press 'r' to refresh)"
           ^ Ansi.reset)
     | Some _, None ->
         box_line buf cols
           (Ansi.dim ^ "  (no pending approvals)" ^ Ansi.reset));
    for _ = 1 to rows - 10 do
      box_empty buf cols
    done
  end else begin
    let content_height = max 0 (rows - 10) in
    let scroll_offset =
      if content_height > 0 && state.approval_cursor >= content_height then
        state.approval_cursor - content_height + 1
      else 0
    in
    let now_unix = Unix.gettimeofday () in
    for i = 0 to content_height - 1 do
      let idx = i + scroll_offset in
      if idx < count then begin
        let line =
          match List.nth approvals idx with
          | Operator_row a ->
              let target_id =
                Terminal_text.single_line_or ~default:"-" a.ap_target_id
              in
              Printf.sprintf "  %s  %s  %s  %s"
                (fit_width (Terminal_text.single_line a.ap_actor) 16)
                (fit_width (Terminal_text.single_line a.ap_action_type) 20)
                (fit_width (Terminal_text.single_line a.ap_target_type) 16)
                target_id
          | Keeper_tool_row held ->
              (* The remaining wait, not the age: this row disappears on its
                 own when it runs out, and what an operator weighs is how
                 long they still have. *)
              let remaining =
                max 0.
                  (held.kta_asked_at +. held.kta_timeout_sec -. now_unix)
              in
              Printf.sprintf "  %s  %s  %s  %s"
                (fit_width (Terminal_text.single_line held.kta_keeper) 16)
                (fit_width
                   ("tool: " ^ Terminal_text.single_line held.kta_tool)
                   20)
                (fit_width (Printf.sprintf "%.0fs left" remaining) 16)
                (Terminal_text.single_line held.kta_question)
        in
        let is_selected = idx = state.approval_cursor in
        let content =
          if is_selected then
            Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line
          else
            "  " ^ line
        in
        box_line buf cols content
      end else
        box_empty buf cols
    done
  end;

  box_bottom buf cols;

  let detail_line =
    match List.nth_opt approvals state.approval_cursor with
    | Some (Operator_row a) -> (
        if action_inflight then
          Printf.sprintf "  %sApproval request in progress…%s" Theme.warn
            Ansi.reset
        else
          match state.pending_approval_action with
          | Some { paa_token; paa_decision }
            when String.equal paa_token a.ap_token ->
              let key =
                match paa_decision with
                | Confirm -> "y"
                | Deny -> "n"
              in
              Printf.sprintf "  %sPress %s again: %s%s" Theme.warn key
                (fit_width (Terminal_text.single_line a.ap_summary) (cols - 22))
                Ansi.reset
          | _ ->
              Printf.sprintf "  %s%s%s"
                Ansi.dim
                (fit_width (Terminal_text.single_line a.ap_summary) (cols - 6))
                Ansi.reset)
    | Some (Keeper_tool_row held) ->
        (* One press answers a held call, matching the chat pane's [y]. The
           question is the whole ask, so it is the row the eye lands on. *)
        Printf.sprintf "  %s%s  [y] allow  [n] deny%s"
          Theme.warn
          (fit_width
             (Terminal_text.single_line held.kta_question)
             (max 8 (cols - 26)))
          Ansi.reset
    | None -> ""
  in
  Buffer.add_string buf (Printf.sprintf "%s\n" detail_line);

  let metadata_line, payload_line =
    match List.nth_opt approvals state.approval_cursor with
    | None -> "", ""
    | Some (Operator_row approval) ->
        let expires =
          Terminal_text.single_line_or ~default:"-" approval.ap_expires_at
        in
        let payload =
          Masc_tui_operator_projection.approval_payload_for_terminal
            approval.ap_payload
        in
        ( Printf.sprintf "  %strace=%s  created=%s  expires=%s%s" Ansi.dim
            (fit_width (Terminal_text.single_line approval.ap_trace_id) 18)
            (Terminal_text.single_line approval.ap_created_at)
            expires Ansi.reset
        , Printf.sprintf "  %spayload=%s%s" Ansi.dim
            (fit_width payload (max 8 (cols - 12)))
            Ansi.reset )
    | Some (Keeper_tool_row held) ->
        ( Printf.sprintf "  %skeeper=%s  call=%s%s" Ansi.dim
            (fit_width (Terminal_text.single_line held.kta_keeper) 20)
            (fit_width (Terminal_text.single_line held.kta_tool_call_id) 28)
            Ansi.reset
        , Printf.sprintf "  %sargs=%s%s" Ansi.dim
            (fit_width
               (Terminal_text.single_line held.kta_args)
               (max 8 (cols - 9)))
            Ansi.reset )
  in
  Buffer.add_string buf (Printf.sprintf "%s\n%s\n" metadata_line payload_line);

  Buffer.add_string buf
    (footer_line state ~hints:"j/k:move  y/y:confirm  n/n:deny  r:refresh  Tab:next");

  finish_surface state ~surface_key:"approvals" ~rows:terminal_rows
      ~cols buf

(* Who wrote it, in one column. 1561 of this workspace's 2171 posts are system
   posts and 588 are automation; the 22 a person wrote are what an operator is
   scanning for, so those are the ones that get a mark. *)
let board_kind_mark = function
  | Some Post_by_person -> Ansi.bold ^ "@" ^ Ansi.reset
  | Some Post_by_automation -> Ansi.dim ^ "\xc2\xb7" ^ Ansi.reset
  | Some Post_by_system -> " "
  | Some (Post_kind_unknown _) -> Theme.warn ^ "?" ^ Ansi.reset
  | None -> " "
;;

(** The draft pane. For a new post the commit-message convention is stated
    on screen rather than assumed: first line is the title, the rest is the
    body. A reply sends the whole draft as one comment, so its hint drops
    the title convention. A draft taller than the viewport shows its tail,
    where the caret is -- the operator is always writing at the bottom. *)
let render_board_compose (state : state) =
  let (rows, cols) = get_terminal_size () in
  let buf = Buffer.create 4096 in
  let kind_line =
    match state.board_compose_reply_to with
    | Some post_id ->
        Printf.sprintf "  comment on %s  Enter: new line"
          (fit_width (Terminal_text.single_line post_id) 16)
    | None -> "  first line: title   rest: body   Enter: new line"
  in
  let header = Printf.sprintf "%s  %s[%s]%s  %s"
    (screen_title " MASC Board")
    Ansi.cyan
    (match state.board_compose_reply_to with
     | Some _ -> "reply" | None -> "new post")
    Ansi.reset
    (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  box_line buf cols (Ansi.dim ^ kind_line ^ Ansi.reset);
  (match state.board_post_error with
   | Some err ->
       box_line buf cols
         (Theme.bad ^ "  "
         ^ fit_width (Terminal_text.single_line err) (cols - 8)
         ^ Ansi.reset)
   | None -> ());
  box_divider buf cols;
  let text_width = max 10 (cols - 8) in
  let draft_lines =
    String.split_on_char '\n' (Buffer.contents state.board_draft)
    |> List.concat_map (fun line ->
           Message_layout.wrap_words ~max_cells:text_width
             (Terminal_text.single_line line))
  in
  let error_rows = if Option.is_some state.board_post_error then 1 else 0 in
  let content_height = max 1 (rows - 8 - error_rows) in
  let visible_lines =
    let total = List.length draft_lines in
    if total > content_height then
      List.filteri
        (fun index _ -> index >= total - content_height)
        draft_lines
    else draft_lines
  in
  List.iter
    (fun line ->
       box_line buf cols
         ("  " ^ fit_width line (cols - 8)))
    visible_lines;
  box_bottom buf cols;
  let prompt =
    if state.board_compose_armed then
      "s:send  d:discard  esc:keep writing"
    else
      "type to write  esc:send or discard  Tab:surfaces  q:quit"
  in
  Buffer.add_string buf
    (Printf.sprintf "%s  %s%s\n" Ansi.dim prompt Ansi.reset);
  finish_frame_with_strip state ~surface_key:"board-compose" ~cursor:Frame_presenter.Hidden ~rows
    ~cols buf

let render_board_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let count = List.length state.board_posts in
  let header = Printf.sprintf "%s (%d)  %s  %s"
    (screen_title " MASC Board")
    count timestamp
    (connection_badge state.connection_status) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let board_list_error =
    Terminal_text.optional_single_line state.board_list_error
  in
  let render_list_error err =
    box_line buf cols
      (Theme.bad ^ "  (data unreliable: "
      ^ fit_width err (max 1 (cols - 24))
      ^ ")" ^ Ansi.reset)
  in
  if count = 0 then begin
    (match board_list_error with
     | Some err -> render_list_error err
     | None ->
         box_line buf cols (Ansi.dim ^ "  (no board posts)" ^ Ansi.reset));
    for _ = 1 to rows - 7 do
      box_empty buf cols
    done
  end else begin
    Option.iter render_list_error board_list_error;
    let error_rows = if Option.is_some board_list_error then 1 else 0 in
    let content_height = max 0 (rows - 7 - error_rows) in
    let scroll_offset =
      if state.board_cursor >= content_height then
        state.board_cursor - content_height + 1
      else 0
    in
    for i = 0 to content_height - 1 do
      let idx = i + scroll_offset in
      if idx < count then begin
        let p = List.nth state.board_posts idx in
        let is_selected = idx = state.board_cursor in
        let line =
          Printf.sprintf "  %s %s  %s  %s  %s  +%d  c%d"
            (board_kind_mark p.bp_kind)
            (fit_width (Terminal_text.single_line p.bp_id) 12)
            (Ansi.dim
             ^ fit_width
                 (match Terminal_text.optional_single_line p.bp_hearth with
                  | Some hearth -> hearth
                  | None -> "")
                 12
             ^ Ansi.reset)
            (fit_width (Terminal_text.single_line p.bp_author) 16)
            (fit_width (Terminal_text.single_line p.bp_title) (cols - 68))
            p.bp_votes
            p.bp_comment_count
        in
        let content =
          if is_selected then
            Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line
          else
            "  " ^ line
        in
        box_line buf cols content
      end else
        box_empty buf cols
    done
  end;

  box_bottom buf cols;

  Buffer.add_string buf (footer_line state ~hints:"j/k:move  Enter:read  v:vote-up  V:vote-down  w:write  r:refresh  Tab:next");

  finish_surface state ~surface_key:"board-list" ~rows:terminal_rows
      ~cols buf

(** Render the Board surface (read view). *)
(* The read post alone -- borders, header, body, comments -- at [cols]
   wide, footer excluded, so a caller can lay it beside the post list.
   Returns the scroll the frame used. *)
let board_read_pane (state : state) (list_post : board_post) ~rows ~cols buf =
  let detail =
    Board_detail.view_for state.board_detail ~post_id:list_post.bp_id
  in
  let post =
    match detail with
    | Board_detail.Ready (detail_post, _) -> detail_post
    | Board_detail.Absent | Board_detail.Loading | Board_detail.Failed _ ->
        list_post
  in

  let header = Printf.sprintf "%s  %s[%s]%s  by %s  +%d  c%d"
    (screen_title " MASC Board")
    Ansi.cyan
    (fit_width (Terminal_text.single_line post.bp_id) 12)
    Ansi.reset
    (Terminal_text.single_line post.bp_author)
    post.bp_votes post.bp_comment_count
  in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let title_line = Printf.sprintf "  %s%s%s"
    Ansi.bold
    (fit_width (Terminal_text.single_line post.bp_title) (cols - 6))
    Ansi.reset
  in
  box_line buf cols title_line;
  box_line buf cols
    (Ansi.dim ^ "  "
    ^ fit_width (Terminal_text.single_line post.bp_created_at) 40
    ^ Ansi.reset);
  box_divider buf cols;

  (* Body lines *)
  let text_width = cols - 8 in
  (* Sanitised a line at a time. A newline is a control byte, so sanitising the
     body whole escaped every break and the post arrived as one unbroken run
     with "\x0A" printed through it. *)
  (* Board posts are written in markdown -- headings, fences, rules -- and were
     drawn as the source they were typed as. The chat pane has rendered them
     for a while; this surface reads the same kind of document. *)
  let body_lines =
    Message_layout.wrap_body
      ~markdown:chat_markdown
      ~max_cells:text_width
      ~sanitize:Terminal_text.single_line
      post.bp_body
  in
  let total_lines = List.length body_lines in
  let detail_lines =
    match detail with
    | Board_detail.Absent ->
        [Ansi.dim ^ "  Board detail unavailable" ^ Ansi.reset]
    | Board_detail.Loading ->
        [Ansi.dim ^ "  Loading Board detail..." ^ Ansi.reset]
    | Board_detail.Failed error ->
        [ Theme.bad ^ "  Board detail unavailable: "
          ^ fit_width (Terminal_text.single_line error) (max 1 (cols - 32))
          ^ Ansi.reset
        ]
    | Board_detail.Ready (_, comments) ->
        List.map
          (fun c ->
             Printf.sprintf "  %s: %s"
               (fit_width (Terminal_text.single_line c.bc_author) 16)
               (fit_width (Terminal_text.single_line c.bc_content) (cols - 24)))
          comments
  in
  let detail_line_count = List.length detail_lines in
  let row_budget =
    Render_schedule.allocate_board_read ~terminal_rows:rows
      ~body_line_count:total_lines
      ~comment_count:detail_line_count
  in
  let content_height = row_budget.body_rows in
  let comment_height = row_budget.comment_rows in
  let scroll =
    Render_schedule.project_board_read_scroll ~body_line_count:total_lines
      ~body_rows:content_height
      ~comment_count:detail_line_count
      ~comment_rows:comment_height state.board_scroll
  in
  for i = 0 to content_height - 1 do
    let idx = i + scroll.body_offset in
    if idx < total_lines then
      box_line buf cols ("  " ^ List.nth body_lines idx)
    else
      box_empty buf cols
  done;

  if comment_height > 0 then begin
    box_divider buf cols;
    box_line buf cols (Ansi.bold ^ "  Comments" ^ Ansi.reset);
    for i = 0 to comment_height - 1 do
      box_line buf cols (List.nth detail_lines (i + scroll.comment_offset))
    done
  end;

  box_bottom buf cols;
  scroll.normalized_scroll

(* The post list beside the read: position context with the open post
   marked, exactly the roster-beside-detail shape. *)
let board_list_pane (state : state) ~(open_post : board_post) ~rows ~cols buf =
  framed_top buf cols;
  framed_line buf cols
    (Ansi.dim
     ^ Printf.sprintf " Board (%d)" (List.length state.board_posts)
     ^ Ansi.reset);
  framed_divider buf cols;
  let content_height = max 0 (rows - 5) in
  let selected_index =
    let rec find i = function
      | [] -> 0
      | (post : board_post) :: rest ->
          if String.equal post.bp_id open_post.bp_id then i
          else find (i + 1) rest
    in
    find 0 state.board_posts
  in
  let first =
    if selected_index < content_height then 0
    else selected_index - content_height + 1
  in
  for i = 0 to content_height - 1 do
    match List.nth_opt state.board_posts (first + i) with
    | Some (post : board_post) ->
        let title = Terminal_text.single_line post.bp_title in
        let line =
          if first + i = selected_index then
            Theme.selection ^ " " ^ title
            ^ String.make
                (max 0 (cols - 5 - Message_layout.display_width title))
                ' '
            ^ Ansi.reset
          else " " ^ title
        in
        framed_line buf cols line
    | None -> framed_empty buf cols
  done;
  framed_bottom buf cols

let render_board_read (state : state) (list_post : board_post) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let footer =
    footer_line state ~hints:"j/k:scroll  Esc:back  c:reply  r:refresh  Tab:next"
  in
  if cols < keeper_split_threshold_cols then begin
    let scroll = board_read_pane state list_post ~rows ~cols buf in
    Buffer.add_string buf footer;
    finish_surface state ~clamped:(Board_read scroll)
      ~surface_key:"board-read" ~rows:terminal_rows ~cols buf
  end
  else begin
    let left_cols = keeper_roster_pane_cols in
    let right_cols = cols - left_cols in
    let left_buf = Buffer.create 1024 in
    let right_buf = Buffer.create 4096 in
    board_list_pane state ~open_post:list_post ~rows ~cols:left_cols left_buf;
    let scroll =
      board_read_pane state list_post ~rows ~cols:right_cols right_buf
    in
    let blank_left = String.make left_cols ' ' in
    let rec zip left right =
      match left, right with
      | [], [] -> []
      | l :: lt, r :: rt -> (l ^ r) :: zip lt rt
      | [], r :: rt -> (blank_left ^ r) :: zip [] rt
      | l :: lt, [] -> l :: zip lt []
    in
    List.iter
      (fun line ->
        Buffer.add_string buf line;
        Buffer.add_char buf '\n')
      (zip (frame_lines left_buf) (frame_lines right_buf));
    Buffer.add_string buf footer;
    finish_surface state ~clamped:(Board_read scroll)
      ~surface_key:"board-read" ~rows:terminal_rows ~cols buf
  end

let planning_phase_label phase = Goal_phase.to_string phase

(* As wide as the widest phase rather than a literal. Three of the four labels
   are nine cells and the column was eight, so nearly every planning row read
   [complet~] with sixty columns of space to its right -- the mark that says
   "there was more" on a value nothing was cut from. Taken from the phase list
   so a new phase widens the column instead of losing its last letter. *)
let planning_phase_column =
  List.fold_left
    (fun widest phase ->
      max widest (Message_layout.display_width (planning_phase_label phase)))
    0
    Goal_phase.all

let planning_phase_color = function
  | Goal_phase.Executing -> Ansi.cyan
  | Goal_phase.Verifying -> Ansi.magenta
  | Goal_phase.Completed -> Theme.ok
  | Goal_phase.Dropped -> Ansi.gray

(* Where the goal stands with the completion judge, in one column. The phase
   reads [executing] both for a goal nobody asked about and for one the judge
   refused; without this the two are the same row. Idle is a blank rather than
   a glyph — most goals have never been asked, and a mark on all of them would
   carry no information. *)
let planning_proof_mark = function
  | Tui_decode.Proof_idle -> " "
  | Tui_decode.Proof_pending -> Theme.warn ^ "\xe2\x80\xa6" ^ Ansi.reset
  | Tui_decode.Proof_proven _ -> Theme.ok ^ "\xe2\x9c\x93" ^ Ansi.reset
  | Tui_decode.Proof_refuted _ -> Theme.bad ^ "\xe2\x9c\x97" ^ Ansi.reset
  | Tui_decode.Proof_unreadable _ -> Theme.warn ^ "!" ^ Ansi.reset
;;

(* The line under the list, for the goal the cursor is on. A verdict without its
   reason is a colour and nothing else; the reason is what the judge produced
   and the only thing that says what to do next. *)
let planning_proof_detail (goal : planning_goal) =
  match goal.pg_proof with
  | Tui_decode.Proof_proven None -> Some (Theme.ok, "proven")
  | Tui_decode.Proof_proven (Some evidence) -> Some (Theme.ok, "proven: " ^ evidence)
  | Tui_decode.Proof_refuted None -> Some (Theme.bad, "refused")
  | Tui_decode.Proof_refuted (Some reason) -> Some (Theme.bad, "refused: " ^ reason)
  | Tui_decode.Proof_pending -> Some (Theme.warn, "waiting for the completion judge")
  | Tui_decode.Proof_unreadable None ->
      Some (Theme.warn, "verification ledger unreadable")
  | Tui_decode.Proof_unreadable (Some detail) ->
      Some (Theme.warn, "verification ledger unreadable: " ^ detail)
  | Tui_decode.Proof_idle ->
      (* Nothing from the judge. A keeper's own note is the next best thing the
         row has to say, and it is what the operator wrote there to be read. *)
      Option.map
        (fun note -> (Ansi.dim, "note: " ^ note))
        (Terminal_text.optional_single_line goal.pg_last_review_note)
;;

(** Render the Planning surface (list view). *)
let render_planning_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf "%s  %s  %s"
    (screen_title " MASC Planning")
    timestamp
    (connection_badge state.connection_status) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  let goals =
    match state.planning with
    | None -> []
    | Some p -> planning_visible_goals p.pl_goals
  in
  let count = List.length goals in
  let planning_error =
    Terminal_text.optional_single_line state.planning_error
  in

  (match state.planning with
   | None ->
       (match planning_error with
        | Some err ->
            box_line buf cols
              (Theme.bad ^ "  (data unreliable: "
              ^ fit_width err (cols - 24)
              ^ ")" ^ Ansi.reset)
        | None ->
            box_line buf cols (Ansi.dim ^ "  (not loaded yet)" ^ Ansi.reset));
       for _ = 1 to rows - 10 do
         box_empty buf cols
       done
   | Some p ->
       let rollup =
         Printf.sprintf
           "  Executing: %d  Verifying: %d  Done: %d  Dropped: %d"
           p.pl_rollup.pr_active
           p.pl_rollup.pr_verifying p.pl_rollup.pr_done
           p.pl_rollup.pr_dropped
       in
       let backlog =
         Printf.sprintf "  Backlog: todo=%d  claimed=%d  running=%d  done=%d  cancelled=%d"
           p.pl_backlog.pb_todo p.pl_backlog.pb_claimed p.pl_backlog.pb_running
           p.pl_backlog.pb_done p.pl_backlog.pb_cancelled
       in
       box_line buf cols (Ansi.bold ^ rollup ^ Ansi.reset);
       box_line buf cols (Ansi.dim ^ backlog ^ Ansi.reset);
       box_divider buf cols;

       if count = 0 then begin
         box_line buf cols (Ansi.dim ^ "  (no goals)" ^ Ansi.reset);
         for _ = 1 to rows - 11 do
           box_empty buf cols
         done
       end else begin
         (* One row is reserved below the list for the selected goal's verdict. *)
         let content_height = rows - 13 in
         let scroll_offset =
           if state.planning_cursor >= content_height then
             state.planning_cursor - content_height + 1
           else 0
         in
         for i = 0 to content_height - 1 do
           let idx = i + scroll_offset in
           if idx < count then begin
             let g = List.nth goals idx in
             let is_selected = idx = state.planning_cursor in
             let depth = planning_goal_depth p.pl_goals g in
             let indent = String.make (depth * 2) ' ' in
             let branch = if depth > 0 then "└─ " else "  " in
             let status_color = planning_phase_color g.pg_phase in
             let status_label = planning_phase_label g.pg_phase in
            let due =
              match Terminal_text.optional_single_line g.pg_due_date with
              | Some d -> "  " ^ d
              | None -> ""
            in
             let line =
               Printf.sprintf "%s%s%s[%s]%s %s P%d  %s%s"
                 indent branch status_color
                 (fit_width status_label planning_phase_column)
                 Ansi.reset
                 (planning_proof_mark g.pg_proof)
                 g.pg_priority
                 (fit_width
                    (Terminal_text.single_line g.pg_title)
                    (cols - 30 - (depth * 2)
                   - Message_layout.display_width due))
                 (Ansi.dim ^ due ^ Ansi.reset)
             in
             let content =
               if is_selected then
                 Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line
               else
                 "  " ^ line
             in
             box_line buf cols content
           end else
             box_empty buf cols
         done;
         match List.nth_opt goals state.planning_cursor with
         | None -> box_empty buf cols
         | Some selected ->
             (match planning_proof_detail selected with
              | None -> box_empty buf cols
              | Some (colour, text) ->
                  box_line buf cols
                    (colour ^ "  " ^ Terminal_text.single_line text ^ Ansi.reset))
       end);

  box_bottom buf cols;

  Buffer.add_string buf (footer_line state ~hints:"j/k:move  Enter:detail  r:refresh  Tab:next");

  finish_surface state ~surface_key:"planning-list" ~rows:terminal_rows
      ~cols buf

(** Render the Planning surface (detail view). *)
(* Border, header, divider, title, phase, due, metric, blank, divider,
   border, footer: the eleven rows the detail draws whatever the goal says.
   A lifecycle arm and a refused request each add one more when they are
   there, so the block is measured against them rather than against a
   constant that would push the footer off a full screen. *)
let planning_detail_fixed_rows = 11

let planning_detail_tone (tone : Planning_detail.tone) =
  match tone with
  | Planning_detail.Proven -> Theme.ok
  | Planning_detail.Refused -> Theme.bad
  | Planning_detail.Waiting | Planning_detail.Unreadable -> Theme.warn
  | Planning_detail.Note | Planning_detail.Quiet -> Ansi.dim

let render_planning_detail (state : state)
    ~(armed : Goal_phase.Public_action.t option) (goal : planning_goal) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in

  let status_color = planning_phase_color goal.pg_phase in
  let status_label = planning_phase_label goal.pg_phase in
  let header = Printf.sprintf "%s  %s[%s]%s  %s"
    (screen_title " MASC Planning")
    status_color (fit_width status_label planning_phase_column) Ansi.reset
    (fit_width (Terminal_text.single_line goal.pg_id) 20)
  in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  box_line buf cols (Printf.sprintf "  %s%s%s"
    Ansi.bold
    (fit_width (Terminal_text.single_line goal.pg_title) (cols - 6))
    Ansi.reset);
  box_line buf cols (Printf.sprintf "  Phase: %s  Priority: P%d"
    (fit_width (planning_phase_label goal.pg_phase) 14) goal.pg_priority);
  (match Terminal_text.optional_single_line goal.pg_due_date with
   | Some d ->
       box_line buf cols
         (Printf.sprintf "  Due: %s" d)
   | None -> box_empty buf cols);
  (match Terminal_text.optional_single_line goal.pg_metric with
   | Some m ->
       let target =
         match Terminal_text.optional_single_line goal.pg_target_value with
         | Some t -> " = " ^ t
         | None -> ""
       in
       box_line buf cols
         (Printf.sprintf "  Metric: %s%s" m target)
   | None -> box_empty buf cols);
  box_empty buf cols;
  (* A lifecycle request is the one state the detail carries between frames,
     so it gets a row rather than an event log: the arm says what the next
     press of the same key would do, and the error says what the server said
     when the last one was refused. *)
  (match armed with
   | Some armed_action ->
       box_line buf cols
         (Theme.warn ^ Printf.sprintf "  armed: %s -- same key again to send"
            (match armed_action with
             | Goal_phase.Public_action.Request_complete -> "request completion"
             | Goal_phase.Public_action.Drop -> "drop"
             | Goal_phase.Public_action.Reopen -> "reopen")
         ^ Ansi.reset)
   | None -> ());
  (match state.goal_action_error with
   | Some err ->
       box_line buf cols
         (Theme.bad ^ "  "
         ^ fit_width (Terminal_text.single_line err) (cols - 8)
         ^ Ansi.reset)
   | None -> ());
  box_divider buf cols;

  (* The verdict and the keeper's note: the two things the list draws under
     the cursor and the detail used to leave out, so opening a goal showed
     less than the row it was opened from. They wrap, so this is what the
     surface's scroll moves through. *)
  let body =
    Planning_detail.body ~width:(cols - 6) goal.pg_proof goal.pg_last_review_note
  in
  let chrome_rows =
    planning_detail_fixed_rows
    + (match armed with Some _ -> 1 | None -> 0)
    + (match state.goal_action_error with Some _ -> 1 | None -> 0)
  in
  let content_height = max 1 (rows - chrome_rows) in
  let scroll =
    Masc_tui_scroll.normalize ~count:(List.length body) ~height:content_height
      state.planning_scroll
  in
  let drawn =
    body
    |> List.filteri (fun i _ -> i >= scroll && i < scroll + content_height)
  in
  List.iter
    (fun (line : Planning_detail.line) ->
      box_line buf cols
        (Printf.sprintf "  %s%s%s"
           (planning_detail_tone line.Planning_detail.tone)
           (fit_width line.Planning_detail.text (cols - 6))
           Ansi.reset))
    drawn;
  for _ = 1 to content_height - List.length drawn do
    box_empty buf cols
  done;

  box_bottom buf cols;

  Buffer.add_string buf (footer_line state ~hints:"j/k:scroll  Esc:back  r:refresh  c:complete  x:drop  o:reopen  Tab:next");

  finish_surface state ~clamped:(Planning_detail_scroll scroll)
      ~surface_key:"planning-detail" ~rows:terminal_rows ~cols buf

(* The store's status vocabulary, as colours. An unknown word keeps its own
   text and no colour: the row is still a fact about the store, just one this
   build does not rank. *)
let schedule_status_color status =
  match status with
  | "scheduled" | "due" -> Theme.warn
  | "running" -> Ansi.cyan
  | "failed" -> Theme.bad
  | "succeeded" | "cancelled" | "expired" -> Ansi.dim
  | _ -> Ansi.reset

(** Render the Schedules surface: the scheduled-automation list, with an
    armed cancel. The server sorts active rows first by due time and caps the
    list at its own limit; [scs_truncated] and [scs_request_count] say what
    of the whole store this page is. *)
let render_schedules (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface lays
     out fits above it. *)
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp = Printf.sprintf "%02d:%02d:%02d"
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec in
  let header = Printf.sprintf " MASC Schedules  %s  %s"
    timestamp
    (connection_badge state.connection_status) in

  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;

  (match state.schedules with
   | None ->
       (match Terminal_text.optional_single_line state.schedules_error with
        | Some err ->
            box_line buf cols
              (Theme.bad ^ "  (data unreliable: "
              ^ fit_width err (cols - 24)
              ^ ")" ^ Ansi.reset)
        | None ->
            box_line buf cols (Ansi.dim ^ "  (not loaded yet)" ^ Ansi.reset));
       for _ = 1 to rows - 10 do
         box_empty buf cols
       done
   | Some snapshot ->
       if not (String.equal snapshot.scs_status "ok") then begin
         (* The server's "unknown" is a failed store read, not an empty list;
            the row says which, so a dead ledger cannot read as "nothing is
            scheduled". *)
         (match snapshot.scs_read_error with
          | Some err ->
              box_line buf cols
                (Theme.bad ^ "  (data unreliable: "
                ^ fit_width err (cols - 24)
                ^ ")" ^ Ansi.reset)
          | None ->
              box_line buf cols
                (Theme.bad ^ "  (schedule store unreadable)" ^ Ansi.reset));
         for _ = 1 to rows - 10 do
           box_empty buf cols
         done
       end else begin
         let count_text =
           match snapshot.scs_request_count with
           | Some total when snapshot.scs_truncated ->
               Printf.sprintf "  Requests: %d  (page shows first %d)" total
                 (List.length snapshot.scs_rows)
           | Some total ->
               Printf.sprintf "  Requests: %d" total
           | None -> "  Requests: ?"
         in
         let next_due_text =
           match snapshot.scs_next_due_iso with
           | Some iso ->
               Printf.sprintf "  Next due: %s"
                 (Tui_decode.short_timestamp_for_terminal iso)
           | None -> ""
         in
         box_line buf cols (Ansi.bold ^ count_text ^ Ansi.reset);
         box_line buf cols (Ansi.dim ^ next_due_text ^ Ansi.reset);
         box_divider buf cols;

         let count = List.length snapshot.scs_rows in
         if count = 0 then begin
           box_line buf cols (Ansi.dim ^ "  (no scheduled automation)" ^ Ansi.reset);
           for _ = 1 to rows - 12 do
             box_empty buf cols
           done
         end else begin
           let content_height = rows - 12 in
           let scroll_offset =
             if state.schedule_cursor >= content_height then
               state.schedule_cursor - content_height + 1
             else 0
           in
           for i = 0 to content_height - 1 do
             let idx = i + scroll_offset in
             if idx < count then begin
               let row = List.nth snapshot.scs_rows idx in
               let is_selected = idx = state.schedule_cursor in
               let due =
                 match row.sch_due_at_iso with
                 | Some iso -> Tui_decode.short_timestamp_for_terminal iso
                 | None -> "-"
               in
               (* The payload target names who the wake reaches (a keeper for
                  keeper wakes); rows without one fall back to the summary,
                  then the source, so every row names something. *)
               let subject =
                 match row.sch_payload_target with
                 | Some target -> target
                 | None ->
                     (match row.sch_payload_summary with
                      | Some summary -> summary
                      | None -> row.sch_source)
               in
               let status_color = schedule_status_color row.sch_status in
               let line =
                 Printf.sprintf "%s[%s]%s %s  %s  %s"
                   status_color
                   (fit_width row.sch_status 10)
                   Ansi.reset
                   due
                   (fit_width (Terminal_text.single_line subject)
                      (max 8 (cols - 60)))
                   (Ansi.dim ^ row.sch_recurrence_summary ^ Ansi.reset)
               in
               let content =
                 if is_selected then
                   Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line
                 else
                   "  " ^ line
               in
               box_line buf cols content
             end
             else box_empty buf cols
           done
         end;
         (* The arm and the server's last refusal sit under the list, the
            same rows the goal detail carries them on. *)
         (match state.schedule_cancel_armed with
          | Some schedule_id ->
              box_line buf cols
                (Theme.warn
                ^ Printf.sprintf
                    "  armed: cancel %s -- same key again to send"
                    (fit_width schedule_id (cols - 44))
                ^ Ansi.reset)
          | None -> ());
         (match state.schedule_cancel_error with
          | Some err ->
              box_line buf cols
                (Theme.bad ^ "  "
                ^ fit_width (Terminal_text.single_line err) (cols - 8)
                ^ Ansi.reset)
          | None -> ())
       end);

  box_bottom buf cols;

  Buffer.add_string buf (footer_line state ~hints:"j/k:move  x:cancel  r:refresh  Tab:next");

  finish_surface state ~surface_key:"schedules" ~rows:terminal_rows
      ~cols buf

(** Render the keeper list view *)
(* Status is shown as a glyph and a word. The glyph is the coarse reading an
   operator scans a column for -- a fiber running, a fiber sleeping, no fiber,
   nothing observed -- and the word next to it is the exact published status,
   so the column stays legible at four shapes instead of needing a distinct
   glyph per label. *)
(* One keeper is described by four separate readings, and the status cell draws
   three of them in three separate channels rather than folding them into one
   word:

     colour  what to do about it   from next_action, which the runtime derives
     glyph   whether it is paused  a person's decision, not a health reading
     word    how it is reporting   from health

   The lifecycle cell is the fourth and has its own column. The cell used to
   show a single word from [surface_status], which restates health with stale,
   degraded and zombie folded together and hides health entirely while a keeper
   is paused. *)
let keeper_action_color
    (action : Status.keeper_next_action_path option) =
  match action with
  | None -> Ansi.dim
  | Some Status.Auto_restart -> Theme.bad
  | Some Status.Recover -> Theme.warn
  | Some Status.Probe -> Ansi.cyan
  | Some Status.Direct_message -> Theme.ok

let keeper_state_glyph ~paused ~(health : Tui_decode.keeper_health option) =
  Masc_tui_keeper_mark.glyph ~paused
    (Option.map Tui_decode.keeper_health_reading health)

(* [None] is a roster that was not read, not a health the roster could not
   name: the word says so, and it is the word the header's tally uses for
   the same keepers, so a column of ten of them and "10 unread" above it
   are one fact drawn twice rather than two. *)
let keeper_health_word (health : Tui_decode.keeper_health option) =
  match health with
  | None -> "unread"
  | Some value -> Tui_decode.keeper_health_to_string value

(* The runtime id is [provider.model], and the provider half repeats inside the
   model half often enough that printing both costs the column its width. The
   phase is the fine-grained state-machine reading from GET /api/v1/gate/keepers,
   shown ahead of the model so an operator scanning the column sees lifecycle
   state first. *)
let keeper_runtime_label (runtime : keeper_runtime option) =
  match runtime with
  | None -> "\xe2\x80\x94"
  | Some row -> (
      let raw = Terminal_text.single_line row.kr_runtime_id in
      let model =
        match String.index_opt raw '.' with
        | Some idx when idx + 1 < String.length raw ->
            String.sub raw (idx + 1) (String.length raw - idx - 1)
        | Some _ | None -> raw
      in
      Printf.sprintf "%s %s"
        (Tui_decode.keeper_phase_to_string row.kr_phase)
        model)

let keeper_message_identity state keeper_name =
  match
    List.find_opt
      (fun (keeper : keeper) -> String.equal keeper.k_name keeper_name)
      state.keepers
  with
  | None ->
      Ansi.dim ^ "\xc3\x97 unavailable \xc2\xb7 \xe2\x80\x94" ^ Ansi.reset
  | Some keeper ->
      let reading = keeper_reading state keeper in
      let health = Keeper_control.health reading in
      let runtime =
        match reading.Keeper_control.liveness with
        | Keeper_control.Present row -> Some row
        | Keeper_control.Absent | Keeper_control.Unobserved -> None
      in
      let status_color =
        keeper_action_color (Keeper_control.next_action reading)
      in
      String.concat ""
        [ status_color
        ; keeper_state_glyph ~paused:reading.Keeper_control.paused ~health
        ; " "
        ; keeper_health_word health
        ; Ansi.reset
        ; Ansi.dim
        ; " \xc2\xb7 "
        ; keeper_runtime_label runtime
        ; Ansi.reset
        ]

(* Two dispositions an operator needs before stopping anything: whether the
   keeper comes back by itself, and whether it takes turns without being
   asked. Both are on the roster row. *)
let keeper_flag_cell (runtime : keeper_runtime option) =
  match runtime with
  | None -> Ansi.dim ^ "- -" ^ Ansi.reset
  | Some row ->
      let flag enabled letter =
        if enabled then Ansi.cyan ^ letter ^ Ansi.reset
        else Ansi.dim ^ "-" ^ Ansi.reset
      in
      flag row.kr_autoboot_enabled "A" ^ " " ^ flag row.kr_proactive_enabled "P"

(* Column header labels line up with the cell budgets
   [Render_schedule.allocate_keeper_columns] hands out, so the arithmetic lives
   in one tested place instead of once here and once in the row. *)
let keeper_column_header (columns : Render_schedule.keeper_columns) =
  String.concat ""
    [ String.make Render_schedule.keeper_marker_width ' '
    ; Printf.sprintf "%-*s" Render_schedule.keeper_status_width "STATUS"
    ; " "
    ; Printf.sprintf "%-*s" columns.kcol_name "KEEPER"
    ; (if columns.kcol_show_flags then
         " " ^ Printf.sprintf "%-*s" Render_schedule.keeper_flags_width "A P"
       else "")
    ; Printf.sprintf " %*s" Render_schedule.keeper_turns_width "TURNS"
    ; (if columns.kcol_show_runtime then
         " " ^ fit_width "PHASE / MODEL" columns.kcol_runtime
       else "")
    ; " "
    ; "TASK"
    ]

(* Each cell is fitted as plain text and styled afterwards, so a long keeper
   name cannot push the columns to its right out of the frame and the style
   bytes never count toward the width. *)
let keeper_row_content ~(columns : Render_schedule.keeper_columns) ~selected
    ~yolo ~paused ~health ~next_action ~keeper ~runtime =
  let status_color = keeper_action_color next_action in
  let glyph = keeper_state_glyph ~paused ~health in
  (* Same gutter marker the Approvals, Board and Planning lists draw. A
     selection cursor that changes shape when the operator switches surface
     reads as a different control, not the same one. *)
  let marker = if selected then Ansi.reverse ^ ">" ^ Ansi.reset else " " in
  let name =
    fit_width (Terminal_text.single_line keeper.k_name) columns.kcol_name
  in
  let task =
    fit_width
      (Terminal_text.single_line_or ~default:"\xe2\x80\x93"
         keeper.k_current_task_id)
      columns.kcol_task
  in
  String.concat ""
    [ " "
    ; marker
    ; " "
    ; status_color ^ glyph ^ " "
      ^ fit_width (keeper_health_word health)
          (Render_schedule.keeper_status_width - 2)
      ^ Ansi.reset
    ; " "
    ; (let dressed =
         (* A keeper whose gate runs every call unasked wears its name in
            red: the stance has no column of its own, and the name is what
            the eye finds first. *)
         if yolo then Theme.bad ^ name ^ Ansi.reset else name
       in
       if selected then Ansi.bold ^ dressed ^ Ansi.reset else dressed)
    ; (if columns.kcol_show_flags then " " ^ keeper_flag_cell runtime else "")
    ; Printf.sprintf " %s%*d%s" Ansi.dim Render_schedule.keeper_turns_width
        keeper.k_total_turns Ansi.reset
    ; (if columns.kcol_show_runtime then
         " " ^ Ansi.gray
         ^ fit_width (keeper_runtime_label runtime) columns.kcol_runtime
         ^ Ansi.reset
       else "")
    ; " "
    ; Ansi.dim ^ task ^ Ansi.reset
    ]

(* The footer names the action behind each key for the keeper under the cursor,
   because which action the toggle sends depends on that keeper's state. A key
   with nothing behind it is dimmed rather than dropped, so the row of keys
   does not shift as the cursor travels. *)
let keeper_action_hints ?(offers_chat = true) ?(offers_back = true) state reading =
  let available =
    match reading with None -> [] | Some r -> Keeper_control.available r
  in
  (* An action that ends a fiber is toned apart from the reversible ones, so the
     key that needs two presses does not read like the keys that need one. *)
  let hint action label =
    let key_color =
      if Keeper_control.requires_confirmation action then Theme.bad else Ansi.cyan
    in
    if List.mem action available then
      Printf.sprintf "%s%s%s %s" key_color (Keeper_control.action_key action)
        Ansi.reset label
    else
      Printf.sprintf "%s%s %s%s" Ansi.dim (Keeper_control.action_key action)
        label Ansi.reset
  in
  let toggle =
    match Option.bind reading Keeper_control.primary with
    | Some action -> hint action (Keeper_control.action_label action)
    | None -> Printf.sprintf "%sp pause%s" Ansi.dim Ansi.reset
  in
  match (state.keeper_action_inflight, state.keeper_action_pending) with
  | Some (keeper_name, action), _ ->
      Printf.sprintf "  %s%s %s\xe2\x80\xa6%s" Ansi.cyan
        (Keeper_control.action_gerund action)
        (Terminal_text.single_line keeper_name)
        Ansi.reset
  | None, Some pending ->
      Printf.sprintf "  %s%spress %s again to %s %s%s" Ansi.bold Theme.warn
        (Keeper_control.action_key pending.Keeper_control.pending_action)
        (Keeper_control.action_label pending.Keeper_control.pending_action)
        (Terminal_text.single_line pending.Keeper_control.pending_keeper)
        Ansi.reset
  | None, None ->
      "  "
      ^ String.concat
          (Ansi.dim ^ " \xc2\xb7 " ^ Ansi.reset)
          [ Ansi.dim ^ "j/k move" ^ Ansi.reset
          ; toggle
          ; hint Keeper_control.Wakeup "wake"
          ; hint Keeper_control.Shutdown "shutdown"
          ; Ansi.cyan ^ "e" ^ Ansi.reset ^ " settings"
          ; Ansi.cyan ^ "a" ^ Ansi.reset ^ " new"
          ; Ansi.cyan ^ "l" ^ Ansi.reset ^ " logs"
          ; Ansi.cyan ^ "t" ^ Ansi.reset ^ " calls"
          ; Theme.bad ^ "g" ^ Ansi.reset ^ " yolo"
          ; Ansi.cyan ^ "u" ^ Ansi.reset ^ " runtime"
            (* Dimmed rather than dropped, the same way an unavailable
               lifecycle key is: chat lives in detail, and a key that vanishes
               between surfaces reads as a key that does not exist. *)
          ; (if offers_chat then Ansi.cyan ^ "c" ^ Ansi.reset ^ " chat"
             else Ansi.dim ^ "c chat" ^ Ansi.reset)
          ; (if offers_back then Ansi.dim ^ "esc back" ^ Ansi.reset
             else Ansi.cyan ^ "enter" ^ Ansi.reset ^ " detail")
          ; Ansi.dim ^ "r refresh" ^ Ansi.reset
          ; Ansi.dim ^ "q quit" ^ Ansi.reset
          ]

(* Counted from the same readings the rows are drawn from, so the heading
   cannot disagree with the list under it. *)
(* Tally words come from [Keeper_control.health_label], so this paints the
   health vocabulary. [unread] is the roster not answering, which is dim rather
   than any health colour. *)
let keeper_roster_status_color = function
  | "healthy" -> Theme.ok
  | "stale" | "degraded" -> Theme.warn
  | "zombie" -> Theme.bad
  | "offline" | "idle" -> Ansi.gray
  | _ -> Ansi.dim

(* The tally is [Keeper_control.status_tally], so every word here is a word the
   status column shows for the same keeper. This function only paints it. *)
let keeper_roster_summary readings =
  Keeper_control.health_tally readings
  |> List.map (fun (label, count) ->
         Printf.sprintf "%s%d %s%s" (keeper_roster_status_color label) count
           label Ansi.reset)

(* The two subtractions over the fleet's name lists. They answer different
   questions and only one of them is about being stopped: a keeper the fleet
   wanted and never started is bootable minus running, while a keeper whose
   fiber is alive but whose durable demand is not admissible is running minus
   executable. Reporting the second as "not running" sent an operator to boot
   ten keepers that were already up. *)
let keeper_fleet_gap_lines (fleet : fleet_safety) =
  let subtract from_names remove_names =
    List.filter (fun name -> not (List.mem name remove_names)) from_names
  in
  let never_started = subtract fleet.fs_bootable_names fleet.fs_running_names in
  let running_without_turn =
    subtract fleet.fs_running_names fleet.fs_executable_names
  in
  List.filter_map
    (fun (names, label, color) ->
       match names with
       | [] -> None
       | _ -> Some (color, label, String.concat ", " names))
    [ (never_started, "not running", Theme.bad)
    ; (running_without_turn, "running, cannot take a turn", Theme.warn)
    ]

let render_keeper_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let inner = max 1 (cols - 4) in
  let readings = List.map (keeper_reading state) state.keepers in
  let selected_reading =
    Option.map (keeper_reading state) (selected_keeper state)
  in

  Buffer.add_char buf '\n';

  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let heading =
    Printf.sprintf " %sMASC Keepers (%d)%s" Ansi.bold (List.length state.keepers)
      Ansi.reset
    ^ (match state.roster_search with
       | Some query ->
           Printf.sprintf "  %s/%s%s\xe2\x96\x8c%s" Ansi.cyan
             (Terminal_text.single_line query) Ansi.reset Ansi.reset
       | None ->
           if state.roster_search_last = "" then ""
           else
             Printf.sprintf "  %s/%s (n/N)%s" Ansi.dim
               (Terminal_text.single_line state.roster_search_last)
               Ansi.reset)
    ^ (match keeper_roster_summary readings with
       | [] -> ""
       | parts ->
           Ansi.dim ^ "   " ^ Ansi.reset
           ^ String.concat (Ansi.dim ^ " \xc2\xb7 " ^ Ansi.reset) parts)
  in
  (* Style bytes are zero-width to [display_width], so the gap is measured on
     the styled string rather than on a plain copy that could drift from it. *)
  let gap =
    max 1
      (inner - Message_layout.display_width heading - String.length timestamp)
  in
  box_line buf cols
    (heading ^ String.make gap ' ' ^ Ansi.dim ^ timestamp ^ Ansi.reset);

  Buffer.add_string buf
    (Printf.sprintf " %s%s%s\n" Ansi.gray (draw_hline (cols - 2)) Ansi.reset);

  (match (state.fleet_safety, state.fleet_safety_error) with
   | _, Some err ->
       box_line buf cols
         (Theme.bad ^ "  fleet: " ^ Terminal_text.single_line err ^ Ansi.reset)
   | None, None -> ()
   | Some fleet, None ->
       let tone =
         if fleet.fs_operator_action_required then Theme.bad
         else if String.equal fleet.fs_status "ok" then Theme.ok
         else Theme.warn
       in
       let blocker =
         match fleet.fs_blocker with None -> "" | Some b -> "   blocker: " ^ b
       in
       box_line buf cols
         (Printf.sprintf
            "%s  fleet %s%s   running %d/%d   turn capacity %d/%d%s%s%s" tone
            fleet.fs_status Ansi.reset fleet.fs_running_count
            fleet.fs_bootable_count
            (fleet.fs_target_reaction_capacity
            - fleet.fs_reaction_capacity_shortfall)
            fleet.fs_target_reaction_capacity Ansi.dim blocker Ansi.reset);
       let counts =
         [ ("paused", fleet.fs_paused_count)
         ; ("failing", fleet.fs_failing_count)
         ; ("recovering", fleet.fs_recovering_count)
         ; ( "task owner without fiber"
           , fleet.fs_active_task_owner_without_fiber_count )
         ; ("awaiting verdict", fleet.fs_completion_authority_pending_count)
         ]
         |> List.filter (fun (_, n) -> n > 0)
         |> List.map (fun (label, n) -> Printf.sprintf "%s %d" label n)
       in
       if counts <> [] then
         box_line buf cols
           (Ansi.dim ^ "  " ^ String.concat "   " counts ^ Ansi.reset);
       List.iter
         (fun (color, label, names) ->
            box_line buf cols
              (Printf.sprintf "%s  %s: %s%s" color label
                 (Terminal_text.single_line names) Ansi.reset))
         (keeper_fleet_gap_lines fleet));

  (* The roster's own failure. The rows below still come from disk so they stay
     on screen; this says the live half of every one of them is missing, which
     is why the lifecycle keys stop offering anything. *)
  (match state.keeper_roster_error with
   | Some err ->
       box_line buf cols
         (Theme.warn ^ "  " ^ Terminal_text.single_line err ^ Ansi.reset)
   | None -> ());
  (match state.keeper_roster with
   | Keeper_control.Roster_partial { observed; total } ->
       box_line buf cols
         (Printf.sprintf
            "%s  live status covers %d of %d keepers; the rest read as unknown%s"
            Theme.warn (List.length observed) total Ansi.reset)
   | Keeper_control.Roster_unobserved | Keeper_control.Roster_complete _ -> ());

  let columns = Render_schedule.allocate_keeper_columns ~inner_width:inner in
  box_line_styled buf cols ~style:Ansi.dim (keeper_column_header columns);
  Buffer.add_string buf
    (Printf.sprintf " %s%s%s\n" Ansi.gray (draw_hline (cols - 2)) Ansi.reset);

  let keepers_error = Terminal_text.optional_single_line state.keepers_error in
  (match keepers_error with
   | Some err -> box_line buf cols (Theme.bad ^ "  " ^ err ^ Ansi.reset)
   | None -> ());

  (* Counted rather than recomputed: the chrome above varies with the fleet
     reading, the roster's health and the metadata error, so a second
     arithmetic copy of its height would drift from what was just emitted and
     scroll the frame. *)
  let chrome_rows = List.length (frame_lines buf) in
  let footer_rows = 2 in
  let keeper_rows = max 0 (rows - chrome_rows - footer_rows) in
  let keeper_count = List.length state.keepers in
  let scroll_offset =
    if keeper_rows > 0 && state.keeper_cursor >= keeper_rows then
      state.keeper_cursor - keeper_rows + 1
    else 0
  in
  if keeper_count = 0 then begin
    if keeper_rows > 0 && Option.is_none keepers_error then
      box_line buf cols
        (Ansi.dim ^ "   no keeper metadata under .masc/keepers/" ^ Ansi.reset);
    let filled = if Option.is_none keepers_error then 1 else 0 in
    for _ = 1 to max 0 (keeper_rows - filled) do
      box_empty buf cols
    done
  end
  else
    for index = 0 to keeper_rows - 1 do
      let position = index + scroll_offset in
      match
        (List.nth_opt state.keepers position, List.nth_opt readings position)
      with
      | Some keeper, Some reading ->
          let runtime =
            match reading.Keeper_control.liveness with
            | Keeper_control.Present row -> Some row
            | Keeper_control.Absent | Keeper_control.Unobserved -> None
          in
          box_line buf cols
            (keeper_row_content ~columns
               ~selected:(position = state.keeper_cursor)
               ~yolo:(List.mem keeper.k_name state.keeper_yolo_names)
               ~paused:reading.Keeper_control.paused
               ~health:(Keeper_control.health reading)
               ~next_action:(Keeper_control.next_action reading)
               ~keeper ~runtime)
      | Some _, None | None, Some _ | None, None -> box_empty buf cols
    done;

  Buffer.add_string buf
    (Printf.sprintf "%s%s%s%s%s\n" Ansi.gray Ansi.box_bl (draw_hline (cols - 2))
       Ansi.box_br Ansi.reset);
  Buffer.add_string buf
    (keeper_action_hints ~offers_back:false state selected_reading ^ "\n");

  finish_surface state ~surface_key:"keeper-list" ~rows:terminal_rows
      ~cols buf

let keeper_lane_phase_style (phase : Tui_decode.keeper_lane_phase) =
  match phase with
  | Lane_phase_running -> (Theme.ok, "\xe2\x97\x8f")
  | Lane_phase_failing | Lane_phase_crashed -> (Theme.bad, "\xc3\x97")
  | Lane_phase_compacting | Lane_phase_handing_off | Lane_phase_draining
  | Lane_phase_restarting ->
      (Theme.warn, "\xe2\x97\x90")
  | Lane_phase_paused -> (Theme.warn, "\xe2\x97\x8b")
  | Lane_phase_offline | Lane_phase_stopped -> (Ansi.gray, "\xc3\x97")
  | Lane_phase_unknown _ -> (Theme.warn, "?")

let keeper_lane_turn_style (phase : Tui_decode.keeper_lane_turn_phase) =
  match phase with
  | Lane_turn_executing | Lane_turn_prompting | Lane_turn_routing -> Ansi.cyan
  | Lane_turn_compacting | Lane_turn_finalizing -> Theme.warn
  | Lane_turn_exhausted -> Theme.bad
  | Lane_turn_idle -> Ansi.gray
  | Lane_turn_unknown _ -> Theme.warn

let keeper_lane_idle_text seconds =
  let seconds = max 0 seconds in
  if seconds < 60 then Printf.sprintf "%ds" seconds
  else if seconds < 3600 then Printf.sprintf "%dm" (seconds / 60)
  else if seconds < 86400 then Printf.sprintf "%dh" (seconds / 3600)
  else Printf.sprintf "%dd" (seconds / 86400)

let keeper_lane_outcome_text = function
  | None -> "\xe2\x80\x94"
  | Some (outcome : Tui_decode.keeper_lane_last_outcome) ->
      let state = Terminal_text.single_line outcome.klo_runtime_state in
      (match outcome.klo_selected_model with
       | Some model when String.trim model <> "" ->
           state ^ " \xc2\xb7 " ^ Terminal_text.single_line model
       | Some _ | None -> state)

type keeper_lane_columns = {
  lane_keeper_width : int;
  lane_phase_width : int;
  lane_turn_width : int;
  lane_idle_width : int;
  lane_outcome_width : int;
  lane_diagnosis_width : int;
  lane_show_outcome : bool;
  lane_show_diagnosis : bool;
}

(* The four left columns are always present. Outcome appears next; diagnosis
   is the first column a narrow terminal drops. At 100 columns -- the PTY
   contract -- all six still have enough room to carry a useful value. *)
let keeper_lane_columns inner =
  let lane_phase_width = 11 in
  let lane_turn_width = 11 in
  let lane_idle_width = 6 in
  let lane_show_outcome = inner >= 68 in
  let lane_show_diagnosis = inner >= 84 in
  let lane_outcome_width = if lane_show_outcome then 20 else 0 in
  let fixed_without_keeper =
    2 + lane_phase_width + lane_turn_width + lane_idle_width + 3
    + (if lane_show_outcome then 1 + lane_outcome_width else 0)
    + (if lane_show_diagnosis then 1 else 0)
  in
  let available = max 1 (inner - fixed_without_keeper) in
  let lane_keeper_width =
    if lane_show_diagnosis then min 18 (max 10 (available / 2))
    else min 22 available
  in
  let lane_diagnosis_width =
    if lane_show_diagnosis then max 1 (available - lane_keeper_width) else 0
  in
  { lane_keeper_width
  ; lane_phase_width
  ; lane_turn_width
  ; lane_idle_width
  ; lane_outcome_width
  ; lane_diagnosis_width
  ; lane_show_outcome
  ; lane_show_diagnosis
  }

let keeper_lane_header (columns : keeper_lane_columns) =
  String.concat ""
    [ "  "
    ; fit_width "KEEPER" columns.lane_keeper_width
    ; " "
    ; fit_width "PHASE" columns.lane_phase_width
    ; " "
    ; fit_width "TURN" columns.lane_turn_width
    ; " "
    ; fit_width "IDLE" columns.lane_idle_width
    ; (if columns.lane_show_outcome then
         " " ^ fit_width "LAST OUTCOME" columns.lane_outcome_width
       else "")
    ; (if columns.lane_show_diagnosis then
         " " ^ fit_width "DIAGNOSIS" columns.lane_diagnosis_width
       else "")
    ]

let keeper_lane_row (columns : keeper_lane_columns)
    (lane : Tui_decode.keeper_lane) =
  let phase_color, phase_glyph = keeper_lane_phase_style lane.kl_phase in
  let phase =
    phase_color ^ phase_glyph ^ " "
    ^ fit_width
        (Terminal_text.single_line
           (Tui_decode.keeper_lane_phase_to_string lane.kl_phase))
        (max 1 (columns.lane_phase_width - 2))
    ^ Ansi.reset
  in
  let turn =
    keeper_lane_turn_style lane.kl_turn_phase
    ^ fit_width
        (Terminal_text.single_line
           (Tui_decode.keeper_lane_turn_phase_to_string lane.kl_turn_phase))
        columns.lane_turn_width
    ^ Ansi.reset
  in
  String.concat ""
    [ "  "
    ; fit_width (Terminal_text.single_line lane.kl_keeper)
        columns.lane_keeper_width
    ; " "
    ; phase
    ; " "
    ; turn
    ; " "
    ; Ansi.dim
    ; fit_width (keeper_lane_idle_text lane.kl_idle_seconds)
        columns.lane_idle_width
    ; Ansi.reset
    ; (if columns.lane_show_outcome then
         " " ^ Ansi.gray
         ^ fit_width (keeper_lane_outcome_text lane.kl_last_outcome)
             columns.lane_outcome_width
         ^ Ansi.reset
       else "")
    ; (if columns.lane_show_diagnosis then
         " " ^ Ansi.dim
         ^ fit_width
             (Terminal_text.single_line_or ~default:"\xe2\x80\x94"
                lane.kl_diagnosis)
             columns.lane_diagnosis_width
         ^ Ansi.reset
       else "")
    ]

(** Render one current composite row per Keeper. This is a read-only operator
    view: the endpoint owns the phase diagnosis and this surface only makes
    the six facts scannable together. *)
let render_lanes (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let inner = max 1 (cols - 4) in
  let buf = Buffer.create 4096 in
  let lanes =
    match state.lanes with
    | None -> []
    | Some snapshot -> snapshot.Tui_decode.kls_lanes
  in
  let shown = List.length lanes in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.lanes with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Lanes") timestamp
          (connection_badge state.connection_status)
    | Some snapshot ->
        Printf.sprintf "%s (%d keepers)  %s  %s"
          (screen_title " MASC Lanes") snapshot.kls_count timestamp
          (connection_badge state.connection_status)
  in
  let columns = keeper_lane_columns inner in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  box_line_styled buf cols ~style:Ansi.dim (keeper_lane_header columns);
  box_divider buf cols;
  (match state.lanes_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:Theme.bad
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = listing_chrome ~error:state.lanes_error in
  (* The overflow indicator spends a content row rather than growing the
     frame past its budget, where the truncation's casualty was the footer. *)
  let base_height = max 1 (rows - chrome_rows) in
  let content_height =
    if shown > base_height then max 1 (base_height - 1) else base_height
  in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.lanes_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      match empty_page_of ~snapshot:state.lanes ~error:state.lanes_error with
      | Page_failed -> "  (load failed; nothing here is a reading)"
      | Page_unread -> "  (not loaded yet)"
      | Page_empty -> "  (no keeper lane snapshots)"
    in
    box_line_styled buf cols ~style:Ansi.dim empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for index = 0 to content_height - 1 do
      match List.nth_opt lanes (index + scroll) with
      | None -> box_empty buf cols
      | Some lane -> box_line buf cols (keeper_lane_row columns lane)
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:Ansi.dim
      (Printf.sprintf "[%d keepers, scroll %d]" shown scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"lanes" ~rows:terminal_rows ~cols buf

(** Render keeper detail view with live context and scrolling *)
(* The detail box alone -- borders, title, scrolled content -- written into
   [buf] at [cols] wide, footer excluded so a caller can lay it beside the
   roster pane. Returns the scroll the frame actually used. *)
let keeper_detail_pane (state : state) (k : keeper) ~framed ~rows ~cols buf =
    (* Beside the roster pane the box is the pane separator; alone on the
       surface it is the redundant outer frame, dropped. *)
    let box_top = if framed then framed_top else box_top in
    let box_divider = if framed then framed_divider else box_divider in
    let box_line = if framed then framed_line else box_line in
    let box_empty = if framed then framed_empty else box_empty in
    let box_bottom = if framed then framed_bottom else box_bottom in
    let inner = cols - 4 in  (* width inside borders *)

    (* Build all detail lines first, then apply scroll *)
    let lines = ref [] in
    let add_line s = lines := s :: !lines in

    (* Helper to add a labeled row *)
    let add_row label value =
      add_line (Printf.sprintf "  %s%-22s%s %s" Ansi.cyan label Ansi.reset value)
    in
    let add_empty () = add_line "" in
    let add_section title =
      add_line (Printf.sprintf "  %s%s%s" Ansi.bold title Ansi.reset)
    in

    (* Identity section *)
    add_section "Identity";
    add_row "Name:" (Terminal_text.single_line k.k_name);
    add_row "Paused:"
      (if k.k_paused then Theme.warn ^ "yes" ^ Ansi.reset
       else Ansi.dim ^ "no" ^ Ansi.reset);
    add_empty ();

    (* Current work section *)
    add_section "Current Work";
    add_row "Task:"
      (Terminal_text.single_line_or ~default:"-" k.k_current_task_id);
    add_empty ();

    (* Live Context section (Phase 2) *)
    add_section "Live Context";
    (match
       Terminal_text.optional_single_line state.live_context_error,
       state.live_context
     with
     | Some error, _ ->
         add_row "Context:" (Theme.bad ^ error ^ Ansi.reset)
     | None, Some observation ->
         (match Observation_layout.context_summary observation with
          | Observation_layout.Context_measured observation ->
              let ratio = observation.ratio in
              let pct = ratio *. 100.0 in
              let bar_width =
                Masc_tui_render_schedule.keeper_context_bar_width
                  ~inner_width:inner
              in
              add_row "Context:"
                (Printf.sprintf "%s%.1f%%%s  %s  %d / %d tokens"
                   (ctx_color ratio) pct Ansi.reset
                   (ctx_bar ratio bar_width) observation.tokens
                   observation.maximum);
              add_row "Observed:"
                (Terminal_text.short_timestamp observation.observed_at);
              add_row "Turn Ref:"
                (Terminal_text.single_line observation.turn_ref)
          | Observation_layout.Context_partial observation ->
              add_row "Context:"
                (Printf.sprintf "%d tokens; context window not observed"
                   observation.tokens);
              add_row "Observed:"
                (Terminal_text.short_timestamp observation.observed_at);
              add_row "Turn Ref:"
                (Terminal_text.single_line observation.turn_ref)
          | Observation_layout.Context_unavailable reason ->
              add_row "Context:" (Ansi.dim ^ reason ^ Ansi.reset))
     | None, None ->
         add_row "Context:" (Ansi.dim ^ "not loaded" ^ Ansi.reset));
    add_empty ();

    (* Runtime section *)
    add_section "Runtime Stats";
    add_row "Total Turns:" (string_of_int k.k_total_turns);
    add_row "Total Tokens:" (string_of_int k.k_total_tokens);
    add_row "Total Cost:" (Printf.sprintf "$%.4f" k.k_total_cost_usd);
    add_row "Last Turn:" (Terminal_text.short_timestamp k.k_last_turn_ts);
    add_row "Compactions:" (string_of_int k.k_compaction_count);
    add_empty ();

    (* Recent activity, folded from the metrics rows already read for this
       Keeper. The window is bounded by row count, so it can fall short of the
       span; when it does, say what it reached instead of implying a full day. *)
    let activity =
      Keeper_activity.summarize
        ~since:
          (Keeper_activity.cutoff_of ~now:(Unix.gettimeofday ()) ~hours:24)
        state.log_entries
    in
    add_section "Last 24h";
    if not activity.Keeper_activity.aw_covered then
      add_row "Window:"
        (match activity.Keeper_activity.aw_oldest_ts with
         | Some oldest ->
           Printf.sprintf "partial, reaches %s"
             (Terminal_text.short_timestamp oldest)
         | None -> "no metrics rows read");
    add_row "Turns / Heartbeats:"
      (Printf.sprintf "%d / %d" activity.Keeper_activity.aw_turns
         activity.Keeper_activity.aw_heartbeats);
    add_row "Tokens In / Out:"
      (Printf.sprintf "%d / %d" activity.Keeper_activity.aw_input_tokens
         activity.Keeper_activity.aw_output_tokens);
    add_row "Cost:"
      (Printf.sprintf "$%.4f" activity.Keeper_activity.aw_cost_usd);
    add_row "Tool Calls:"
      (string_of_int activity.Keeper_activity.aw_tool_calls);
    add_row "Top Tools:"
      (match activity.Keeper_activity.aw_top_tools with
       | [] -> "-"
       | tools ->
         tools
         |> List.map (fun (tool : Keeper_activity.tool_use) ->
                Printf.sprintf "%s x%d"
                  (Terminal_text.single_line tool.Keeper_activity.tu_name)
                  tool.Keeper_activity.tu_calls)
         |> String.concat "  ");
    add_empty ();

    add_section "Autonomy";
    add_row "Last Outcome:" k.k_last_proactive_outcome;
    add_empty ();

    (* Timestamps section *)
    add_section "Timestamps";
    add_row "Created:" (Terminal_text.short_timestamp k.k_created_at);
    add_row "Updated:" (Terminal_text.short_timestamp k.k_updated_at);

    (* Reverse to get correct order *)
    let info_lines = List.rev !lines in
    (* The non-Info tabs draw a fetched read; the stamp has to name the
       keeper on screen or the pane shows loading, never another keeper's
       answer. *)
    let stamped_or view error =
      match error with
      | Some detail -> [ Theme.bad ^ "  " ^ detail ^ Ansi.reset ]
      | None -> (
          match view with
          | Some (stamp, lines) when String.equal stamp k.k_name ->
              List.map (fun line -> "  " ^ line) lines
          | Some _ | None -> [ Ansi.dim ^ "  (loading\xe2\x80\xa6)" ^ Ansi.reset ])
    in
    let all_lines =
      match state.detail_tab with
      | Detail_info -> info_lines
      | Detail_instructions ->
          stamped_or state.keeper_config_view state.keeper_config_view_error
      | Detail_github ->
          stamped_or state.github_identity_view
            state.github_identity_view_error
    in
    let total_lines = List.length all_lines in

    (* Top border *)
    box_top buf cols;

    (* Title, with the tab walk on the same row so the chrome height the
       scroll math counts does not move. *)
    let tabs =
      Masc_tui_types.keeper_detail_tabs
      |> List.map (fun tab ->
             let label = Masc_tui_types.keeper_detail_tab_label tab in
             if tab = state.detail_tab then
               Ansi.bold ^ Ansi.underline ^ label ^ Ansi.reset
             else Ansi.dim ^ label ^ Ansi.reset)
      |> String.concat "  "
    in
    let tab_hint =
      match state.detail_tab with
      | Detail_github -> "[ ]:tab  L:login"
      | Detail_info | Detail_instructions -> "[ ]:tab"
    in
    let title =
      Printf.sprintf " Keepers \xe2\x96\xb8 %s%s%s   %s   %s%s%s" Ansi.bold
        (Terminal_text.single_line k.k_name)
        Ansi.reset tabs Ansi.dim tab_hint Ansi.reset
    in
    box_line buf cols title;

    (* Divider *)
    box_divider buf cols;

    (* Content area with scrolling. Chrome is 4 rows (top, title, divider,
       bottom); the indicator, when the content overflows, spends one
       content row rather than growing the pane, so the pane's height is
       rows - 1 in both cases and the split's two bottoms stay level. *)
    let base_height = max 0 (rows - 5) in
    let content_height =
      if total_lines > base_height then max 0 (base_height - 1)
      else base_height
    in
    let visible_lines = min content_height total_lines in
    let scroll =
      Render_schedule.normalize_keeper_detail_scroll ~line_count:total_lines
        ~content_height state.detail_scroll
    in

    for i = 0 to visible_lines - 1 do
      let idx = i + scroll in
      if idx < total_lines then
        box_line buf cols (List.nth all_lines idx)
      else
        box_empty buf cols
    done;

    (* Fill remaining space *)
    for _ = visible_lines to content_height - 1 do
      box_empty buf cols
    done;

    (* Scroll indicator *)
    if total_lines > content_height then begin
      let indicator = Printf.sprintf "%s[%d/%d]%s" Ansi.dim (scroll + 1) (total_lines - content_height + 1) Ansi.reset in
      box_line buf cols indicator
    end;

    (* Bottom border *)
    box_bottom buf cols;
    scroll

(* A narrow roster beside the detail: position context, not a second input
   surface -- the keys keep their detail meaning. The window follows the
   cursor the way the detail follows the selection. *)
let keeper_roster_pane (state : state) ~rows ~cols buf =
  framed_top buf cols;
  framed_line buf cols (Ansi.dim ^ " Keepers  ^B:hide" ^ Ansi.reset);
  framed_divider buf cols;
  let content_height = max 0 (rows - 5) in
  let first =
    if state.keeper_cursor < content_height then 0
    else state.keeper_cursor - content_height + 1
  in
  for i = 0 to content_height - 1 do
    match List.nth_opt state.keepers (first + i) with
    | Some (k : keeper) ->
        let selected = first + i = state.keeper_cursor in
        let name = Terminal_text.single_line k.k_name in
        (* The same glyph the Keepers surface draws, for the same reading.
           Without it the pane says a keeper exists and nothing else, so a
           roster of ten looks identical whether one of them is offline. *)
        let reading = keeper_reading state k in
        let glyph =
          keeper_state_glyph
            ~paused:reading.Keeper_control.paused
            ~health:(Keeper_control.health reading)
        in
        (* Reverse video is the one selection signal every terminal
           renders, colour or not, and it owns the whole row: a glyph
           tinted inside it reads as a second highlight. *)
        let line =
          if selected then
            Theme.selection ^ " " ^ glyph ^ " " ^ name
            ^ String.make
                (max 0 (cols - 7 - Message_layout.display_width name)) ' '
            ^ Ansi.reset
          else
            " "
            ^ keeper_action_color (Keeper_control.next_action reading)
            ^ glyph ^ Ansi.reset ^ " " ^ name
        in
        framed_line buf cols line
    | None -> framed_empty buf cols
  done;
  framed_bottom buf cols


let render_keeper_detail (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  if state.keeper_cursor >= List.length state.keepers then begin
    Buffer.add_string buf "No keeper selected.\n";
    finish_surface state ~surface_key:"keeper-detail" ~rows:terminal_rows
      ~cols buf
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let footer =
      keeper_action_hints state (Some (keeper_reading state k))
    in
    if not (keeper_roster_pane_shown state ~cols) then begin
      let scroll = keeper_detail_pane state k ~framed:false ~rows ~cols buf in
      Buffer.add_string buf (footer ^ "\n");
      finish_surface state ~clamped:(Keeper_detail scroll)
        ~surface_key:"keeper-detail" ~rows:terminal_rows ~cols buf
    end
    else begin
      (* Wide terminals keep the roster in sight beside the detail. Both
         panes draw the same number of rows, so the zip below is a plain
         row-by-row join. *)
      let left_cols = keeper_roster_pane_cols in
      let right_cols = cols - left_cols in
      let left_buf = Buffer.create 1024 in
      let right_buf = Buffer.create 4096 in
      keeper_roster_pane state ~rows ~cols:left_cols left_buf;
      let scroll =
        keeper_detail_pane state k ~framed:true ~rows ~cols:right_cols right_buf
      in
      let blank_left = String.make left_cols ' ' in
      let rec zip left right =
        match left, right with
        | [], [] -> []
        | l :: lt, r :: rt -> (l ^ r) :: zip lt rt
        | [], r :: rt -> (blank_left ^ r) :: zip [] rt
        | l :: lt, [] -> l :: zip lt []
      in
      List.iter
        (fun line ->
          Buffer.add_string buf line;
          Buffer.add_char buf '\n')
        (zip (frame_lines left_buf) (frame_lines right_buf));
      Buffer.add_string buf (footer ^ "\n");
      finish_surface state ~clamped:(Keeper_detail scroll)
        ~surface_key:"keeper-detail" ~rows:terminal_rows ~cols buf
    end
  end

(** Render keeper log view *)
let render_keeper_logs (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in

  if state.keeper_cursor >= List.length state.keepers then begin
    Buffer.add_string buf "No keeper selected.\n";
    finish_surface state ~surface_key:"keeper-logs" ~rows:terminal_rows
      ~cols buf
  end else begin
    let k = List.nth state.keepers state.keeper_cursor in
    let total_entries = List.length state.log_entries in

    (* Header *)
    let header =
      Printf.sprintf "%s  (%d entries)"
        (screen_title
           (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 logs"
              (Terminal_text.single_line k.k_name)))
        total_entries
    in

    box_top buf cols;
    box_line buf cols header;
    box_divider buf cols;

    (* Column header *)
    let col_hdr =
      Printf.sprintf "  %-8s %-4s %-8s %5s %13s %9s %9s  %-10s" "Time"
        "Kind" "Channel" "Msgs" "In/Out" "Lat" "Cost" "Work"
    in
    box_line_styled buf cols ~style:Ansi.dim col_hdr;
    box_divider buf cols;

    (match state.log_error with
      | None -> ()
      | Some error ->
          let style =
            match error with
            | Metrics_tail.Storage_error _ -> Theme.bad
            | Metrics_tail.Row_errors _ -> Theme.warn
          in
          let diagnostic =
            Keeper_chat.terminal_safe_text
              (Metrics_tail.error_to_string error)
          in
          box_line_styled buf cols ~style
            ("  " ^ diagnostic);
          box_divider buf cols);

    (* Content area *)
    let content_height =
      Metrics_tail.content_height ~terminal_rows:rows ~error:state.log_error
    in
    let scroll =
      Metrics_tail.normalize_scroll ~entry_count:total_entries ~content_height
        state.log_scroll
    in

    if total_entries = 0 then begin
      box_line_styled buf cols ~style:Ansi.dim
        ("  " ^ Metrics_tail.empty_message state.log_error);
      for _ = 1 to content_height - 1 do
        box_empty buf cols
      done
    end else begin
      for i = 0 to content_height - 1 do
        let idx = i + scroll in
        if idx < total_entries then begin
          let e = List.nth state.log_entries idx in
          (* Extract just the time portion from ts *)
          let time_str = Terminal_text.clock_timestamp e.le_ts in
          let tool_names = Terminal_text.single_lines e.le_tools_used in
          let tools_str =
            if List.length tool_names > 0 then
              " "
              ^ String.concat ","
                  (List.filteri (fun i _ -> i < 2) tool_names)
            else ""
          in
          let terminal_entry =
            { e with
              le_work_kind =
                Terminal_text.optional_single_line e.le_work_kind
            }
          in
          let line =
            Observation_layout.plain_log_row ~time:time_str terminal_entry
            ^ tools_str
          in
          box_line buf cols line
        end else
          box_empty buf cols
      done
    end;

    (* Scroll indicator *)
    if total_entries > content_height then begin
      let indicator =
        Printf.sprintf "[%d/%d entries, scroll %d]" total_entries total_entries
          scroll
      in
      box_line_styled buf cols ~style:Ansi.dim indicator
    end;

    box_bottom buf cols;

    (* Footer *)
    Buffer.add_string buf (Printf.sprintf "%s  j/k:scroll  Esc:back  q:quit  r:refresh%s\n"
      Ansi.dim Ansi.reset);

    finish_surface state ~surface_key:"keeper-logs" ~rows:terminal_rows
      ~cols buf
  end

(** Render message input/conversation view *)
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
    let display_keeper_name = Keeper_chat.terminal_safe_text keeper_name in
    let header =
      Printf.sprintf "%s  %s  %s(port %d)%s"
        (screen_title
         (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 chat" display_keeper_name))
        (keeper_message_identity state keeper_name)
        Ansi.dim state.port Ansi.reset
    in
    let target_registered =
      keeper_available_for_new_message state keeper_name
    in
    let status_rows = keeper_message_status_rows state in
    (* Wide terminals keep the roster beside the chat, exactly as the detail
       view does; the chat lays out against its own pane width. *)
    let split = keeper_roster_pane_shown state ~cols in
    let chat_cols =
      Masc_tui_roster_pane.content_cols ~hidden:state.roster_pane_hidden ~cols
    in
    if
      not
        (Message_layout.message_viewport_supported ~terminal_rows:rows
           ~terminal_cols:chat_cols ~status_rows)
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
    box_line chat_buf chat_cols header;
    box_divider chat_buf chat_cols;

    (* Message history. The fixed chrome is 7 rows — box top, header, its
       divider, the input divider, the composer's first line, box bottom and
       the footer — and every variable row (status, sending, queue, errors,
       composer growth) is in [status_rows]. The old constant 10 reserved
       three rows nothing drew, so the pane stopped three short of the
       terminal's bottom edge. [message_viewport_supported] already states
       the same chrome as [8 + status_rows]: 7 plus one history row. *)
    let history_height = max 0 (rows - 7 - status_rows) in
    let messages = chat_rows_for state keeper_name in
    let layout_entries =
      (* The position distinguishes rows whose durable timestamp and request
         fields tie. A history reorder can only cause a miss: the exact body is
         another cache-key field, so an index never authorizes stale rows. *)
      List.mapi
        (fun entry_index message ->
          let style, role_label =
            match message.me_role with
            | Message_user speaker -> Message_layout.User, speaker
            | Message_keeper ->
                ( Message_layout.Keeper
                , Keeper_chat.terminal_safe_text message.me_keeper_name )
            | Message_status -> Message_layout.Status, "status"
            | Message_error -> Message_layout.Error, "error"
            | Message_tool -> Message_layout.Tool, "tools"
            | Message_thinking -> Message_layout.Thinking, "thinking"
          in
          (* One column for every speaker so the [timestamp] speaker request
             rows line up down the pane, whatever name each row carries. *)
          let role_label = Message_layout.align_role_label role_label in
          let body =
            match message.me_role with
            | Message_thinking when state.msg_thinking_collapsed ->
                folded_thinking_summary message.me_text
            | Message_thinking | Message_user _ | Message_keeper
            | Message_status | Message_error | Message_tool -> message.me_text
          in
          ({ style;
             timestamp = message.me_timestamp;
             role_label;
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
           }
            : Message_layout.entry))
        messages
    in
    (* Rows for the turn still streaming, drawn under the committed history so
       the streaming reply sits at the bottom edge, where the eye rests while
       waiting for it. Reasoning is kept to its last line: it arrives faster
       than anything else and a full transcript of it would push the reply and
       the tool rows off the pane. *)
    let live_entries =
      match state.msg_live with
      | Some live
        when String.equal (Keeper_chat_transcript.keeper_name live) keeper_name
        ->
          let request_label =
            Keeper_chat.compact_request_id
              (Keeper_chat_transcript.request_id live)
          in
          let entry style role_label body =
            ({ style;
               timestamp = "live";
               role_label;
               request_label;
               body;
               markdown_source = Message_layout.Markdown_streaming;
             }
              : Message_layout.entry)
          in
          (* The turn in the order it happened, one entry per stretch. A
             tool-call round interleaves reasoning, calls and reply text, and
             drawing them as three pooled blocks read as one wall of text with
             its calls listed elsewhere. Reasoning is the only part of a live
             turn the durable transcript does not keep, so the pane is the one
             place it can be read — the whole trail, not its last line. *)
          let keeper_label =
            Keeper_chat.terminal_safe_text
              (Keeper_chat_transcript.keeper_name live)
          in
          List.map
            (fun (item : Keeper_chat_transcript.trail_item) ->
              match item with
              | Keeper_chat_transcript.Trail_thinking lines ->
                  entry Message_layout.Thinking "thinking"
                    (if state.msg_thinking_collapsed
                     then folded_thinking_summary (String.concat "\n" lines)
                     else String.concat "\n" lines)
              | Keeper_chat_transcript.Trail_tools block ->
                  let projection =
                    Keeper_chat_transcript.project_tool_block
                      Keeper_chat_transcript.Full block
                  in
                  entry Message_layout.Tool "tools"
                    (String.concat "\n" projection.rows)
              | Keeper_chat_transcript.Trail_text text ->
                  entry Message_layout.Keeper keeper_label text)
            (Keeper_chat_transcript.trail live)
      | Some _ | None -> []
    in
    let layout_entries = layout_entries @ live_entries in
    let inner_width = max 1 (chat_cols - 4) in
    (* Clamped here rather than where the key is handled: the limit depends on
       the terminal width and the pane's height, and a resize changes both
       under a scroll position that was legal before it. *)
    let scroll, visible_rows =
      Message_layout.clamped_scrolled_rows ~markdown:cached_chat_markdown
        ~inner_width ~height:history_height ~requested:state.msg_scroll
        layout_entries
    in

    if visible_rows = [] then begin
      if history_height > 0 then
        box_line_styled chat_buf chat_cols ~style:Ansi.dim
          "  (no messages yet -- type below and press Enter)";
      for _ = 1 to history_height - 1 do
        box_empty chat_buf chat_cols
      done
    end else begin
      List.iter
        (render_chat_row chat_buf chat_cols)
        visible_rows;
      (* Fill remaining space *)
      for _ = List.length visible_rows to history_height - 1 do
        box_empty chat_buf chat_cols
      done
    end;

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
    (match
       List.partition
         (fun entry -> String.equal entry.sent_request.keeper_name keeper_name)
         state.msg_inflight
     with
     | mine, others ->
         List.iter
           (fun entry ->
             box_line_styled chat_buf chat_cols ~style:Theme.warn
               (Printf.sprintf "  (sending %s%s…)"
                  (Keeper_chat.compact_request_id entry.sent_request.request_id)
                  (sending_age entry)))
           mine;
         List.iter
           (fun entry ->
             box_line_styled chat_buf chat_cols ~style:Ansi.dim
               (Printf.sprintf "  (also sending to %s: %s%s)"
                  (Keeper_chat.terminal_safe_text
                     entry.sent_request.keeper_name)
                  (Keeper_chat.compact_request_id entry.sent_request.request_id)
                  (sending_age entry)))
           others);
    (match state.msg_loaded_error with
     | Some detail ->
         (* Cause first. The consequence -- this session only -- is the same
            sentence every time and cost 66 cells before the reader reached the
            part that differs, which the box then cut. *)
         box_line_styled chat_buf chat_cols ~style:Theme.warn
           ("  " ^ detail ^ " \xe2\x80\x94 showing this session only")
     | None -> ());
    (if state.msg_loaded_dropped > 0 then
       box_line_styled chat_buf chat_cols ~style:Theme.warn
         (Printf.sprintf
            "  %d saved row(s) could not be read and are not shown"
            state.msg_loaded_dropped));
    (* The row [keeper_message_status_rows] reserves for the older-page
       fetch. Counting it without drawing it floated the footer a row up,
       and a failed page load was silent -- the one thing it must not be. *)
    (if state.msg_older_loading then
       box_line_styled chat_buf chat_cols ~style:Ansi.dim
         "  (loading older messages\xe2\x80\xa6)"
     else
       match state.msg_older_error with
       | Some detail ->
           box_line_styled chat_buf chat_cols ~style:Theme.warn
             ("  older messages could not be loaded: " ^ detail)
       | None -> ());
    (match state.msg_live with
     | Some live
       when state.msg_target_keeper_name
            = Some (Keeper_chat_transcript.keeper_name live) ->
         List.iter
           (fun (kind, text) ->
             (* The streaming turn is the row the eye waits on: drawn in the
                accent rather than dimmed, behind a spinner stepped from the
                clock so consecutive frames visibly move. *)
             let spinner =
               let glyphs = [| "\xe2\xa0\x8b"; "\xe2\xa0\x99"; "\xe2\xa0\xb8"; "\xe2\xa0\xb4" |] in
               glyphs.(int_of_float (Unix.gettimeofday ()) mod 4)
             in
             (match kind with
              | Keeper_chat_transcript.Progress ->
                  box_line_styled chat_buf chat_cols ~style:Ansi.cyan
                    ("  " ^ spinner ^ " " ^ text)
              | Keeper_chat_transcript.Attention ->
                  box_line_styled chat_buf chat_cols ~style:Theme.warn ("  " ^ text)))
           (Keeper_chat_transcript.status_rows ~now:(Unix.gettimeofday ()) live)
     | Some _ | None -> ());
    (* What is waiting, in the order it will go. Drawn in full rather than as
       a count: an operator who typed three lines during a turn needs to see
       which three, and a queue that only says "3 waiting" is the same silence
       that made a refused send look like a sent one.

       [keeper_message_status_rows] has always reserved one row per waiting
       line. #29818 rewrote the in-flight block above and took these rows out
       with it, leaving the reservation behind: the history was sized as if
       the queue were drawn, so each line typed during a turn took a row off
       the conversation and put nothing in its place. *)
    List.iteri
      (fun index (queued_keeper, text) ->
        (* First line only. A queued line can be a pasted paragraph, and the
           budget counts one row for it, so this row has one row to fit in. *)
        let body =
          match String.index_opt text '\n' with
          | None -> text
          | Some cut -> String.sub text 0 cut ^ " …"
        in
        (* The operator can switch keepers while a turn runs, and a queued
           line travels with the keeper it was written to. Naming the ones
           that are not this pane's keeps a line from looking like it will go
           to whoever is on screen. *)
        let addressed =
          if String.equal queued_keeper keeper_name then ""
          else " -> " ^ Keeper_chat.terminal_safe_text queued_keeper
        in
        box_line_styled chat_buf chat_cols ~style:Ansi.dim
          (Printf.sprintf "  queued %d%s: %s" (index + 1) addressed
             (Keeper_chat.terminal_safe_text body)))
      (Masc_tui_keeper_chat_queue.waiting state.msg_queued);
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
      box_line_styled chat_buf chat_cols ~style:Theme.bad unavailable_message
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
    let rows_above_composer = List.length (frame_lines chat_buf) in
    List.iteri
      (fun index line ->
        (* Only the first line carries the prompt; the rest line up under it so
           a wrapped thought reads as one message rather than several. The
           prefix here is the one [Message_layout.input_cursor_column] measures
           the caret from, so both say the same constant. *)
        let prefix =
          if index = 0 then Message_layout.chat_input_prompt_prefix else "    "
        in
        box_line chat_buf chat_cols (Ansi.cyan ^ prefix ^ Ansi.reset ^ line))
      composer;

    let input_row =
      min (max 1 rows) (rows_above_composer + max 1 (List.length composer))
    in

    box_bottom chat_buf chat_cols;

    (* Footer *)
    let enter_hint =
      (* What the key does is read once, by [send_disposition]; the in-flight
         kind only names what is happening while it does it. Answering both
         here from a subset of the state is what let the footer say
         [Enter:blocked] on a screen that also showed "queued 1". *)
      let queue_hint () =
        match Masc_tui_keeper_chat_queue.length state.msg_queued with
        | 0 -> "Enter:queue for next turn"
        | waiting ->
            Printf.sprintf
              "Enter:queue (%d waiting)  Ctrl-K:cancel last  Ctrl-P:edit last"
              waiting
      in
      match send_disposition state ~keeper_name with
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
    let escape_hint =
      match state.msg_live with
      | Some live
        when Keeper_chat_transcript.interrupt live
             = Keeper_chat_transcript.Not_requested ->
          "Esc:interrupt turn"
      | Some _ -> "Esc:interrupt sent"
      | None ->
          (match state.msg_return with
           | Keeper_chat_return_list -> "Esc:list"
           | Keeper_chat_return_detail -> "Esc:detail")
    in
    let switch_hint =
      match next_keeper_message_target state with
      | Masc_tui_keeper_selection.No_alternative -> ""
      | Masc_tui_keeper_selection.Switch_to _ -> "  Ctrl-G:next Keeper"
    in
    let footer =
      Printf.sprintf "%s  %s  Ctrl-J:newline  %s%s  %s  Ctrl-U:clear%s"
        Ansi.dim enter_hint scroll_hint switch_hint escape_hint Ansi.reset
    in
    Buffer.add_string chat_buf
      (Message_layout.fit_width footer (max 1 (chat_cols - 1)));
    Buffer.add_char chat_buf '\n';

    let input_column =
      Message_layout.input_cursor_column ~terminal_cols:chat_cols
        ~input:visible_input
    in
    let cursor_column =
      input_column + if split then keeper_roster_pane_cols else 0
    in
    if split then begin
      let left_buf = Buffer.create 1024 in
      keeper_roster_pane state ~rows ~cols:keeper_roster_pane_cols left_buf;
      let blank_left = String.make keeper_roster_pane_cols ' ' in
      let rec zip left right =
        match left, right with
        | [], [] -> []
        | l :: lt, r :: rt -> (l ^ r) :: zip lt rt
        | [], r :: rt -> (blank_left ^ r) :: zip [] rt
        | l :: lt, [] -> l :: zip lt []
      in
      List.iter
        (fun line ->
          Buffer.add_string buf line;
          Buffer.add_char buf '\n')
        (zip (frame_lines left_buf) (frame_lines chat_buf))
    end;
    finish_frame_with_strip state ~surface_key:"keeper-message"
      ~cursor:
        (Frame_presenter.Visible_at
           { row = input_row; column = cursor_column })
      ~rows ~cols buf
    end

(* One colour per level so an operator scanning the column sees severity before
   reading the text. A level this build does not name keeps its own text and
   renders unstyled rather than borrowing another level's colour. *)
let system_log_level_style : Masc.Tui_decode.system_log_level -> string = function
  | System_debug -> Ansi.dim
  | System_info -> Ansi.reset
  | System_warn -> Theme.warn
  | System_error -> Theme.bad
  | System_level_unknown _ -> Ansi.reset

let render_system_logs (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let entries =
    match state.system_logs with None -> [] | Some s -> s.sys_entries
  in
  let total_entries = List.length entries in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.system_logs with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC System Logs") timestamp
          (connection_badge state.connection_status)
    | Some snapshot ->
        (* [total] counts what the ring has seen, not what this page holds.
           Showing both keeps "300 of 774273" from reading as "300 exist". *)
        Printf.sprintf "%s (%d of %d, seq %d)  %s  %s"
          (screen_title " MASC System Logs")
          total_entries snapshot.sys_total snapshot.sys_latest_seq timestamp
          (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let col_hdr =
    Printf.sprintf "  %-8s %-5s %-16s %-12s %s" "Time" "Level" "Module" "Keeper"
      "Message"
  in
  box_line_styled buf cols ~style:Ansi.dim col_hdr;
  box_divider buf cols;
  (match state.system_logs_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:Theme.bad
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = if Option.is_some state.system_logs_error then 9 else 7 in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (total_entries - content_height) in
  let scroll = max 0 (min state.system_logs_scroll max_scroll) in
  if total_entries = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.system_logs ~error:state.system_logs_error
      with
      | Page_failed -> "  (load failed; the count above is not a reading)"
      | Page_unread -> "  (not loaded yet)"
      | Page_empty -> "  (no entries)"
    in
    box_line_styled buf cols ~style:Ansi.dim empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match List.nth_opt entries idx with
      | None -> box_empty buf cols
      | Some e ->
          let keeper =
            match e.sl_keeper with None -> "-" | Some name -> name
          in
          let line =
            Printf.sprintf "  %-8s %-5s %-16s %-12s %s"
              (Terminal_text.clock_timestamp e.sl_ts)
              (Masc.Tui_decode.system_log_level_label e.sl_level)
              (Terminal_text.single_line e.sl_module)
              (Terminal_text.single_line keeper)
              (Terminal_text.single_line e.sl_message)
          in
          box_line_styled buf cols ~style:(system_log_level_style e.sl_level) line
    done;
  if total_entries > content_height then
    box_line_styled buf cols ~style:Ansi.dim
      (Printf.sprintf "[%d entries, scroll %d]" total_entries scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"system-logs" ~rows:terminal_rows
      ~cols buf

(* What is waiting on a verdict.

   The columns answer the questions an operator opens this for: which task,
   who submitted it, and what would move it forward. Evidence counts rather
   than paths -- a row is a queue entry, and the paths belong to whoever opens
   the task. *)
let render_verification (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let requests =
    match state.verification with None -> [] | Some s -> s.Masc.Tui_decode.vs_requests
  in
  let shown = List.length requests in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.verification with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Verification") timestamp
          (connection_badge state.connection_status)
    | Some snapshot ->
        (* Both numbers, for the same reason the log surface shows both: "12"
           beside a list of 12 would read as "that is all of them". *)
        Printf.sprintf "%s (%d of %d)  %s  %s"
          (screen_title " MASC Verification") shown
          snapshot.Masc.Tui_decode.vs_total timestamp
          (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let col_hdr =
    Printf.sprintf "  %-14s %-16s %-9s %s" "Task" "Submitted by" "Evidence"
      "What it asks for"
  in
  box_line_styled buf cols ~style:Ansi.dim col_hdr;
  box_divider buf cols;
  (match state.verification_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:Theme.bad
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = if Option.is_some state.verification_error then 9 else 7 in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.verification_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.verification
          ~error:state.verification_error
      with
      | Page_failed -> "  (load failed; nothing here is a reading)"
      | Page_unread -> "  (not loaded yet)"
      | Page_empty -> "  (nothing waiting on a verdict)"
    in
    box_line_styled buf cols ~style:Ansi.dim empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match List.nth_opt requests idx with
      | None -> box_empty buf cols
      | Some r ->
          let open Masc.Tui_decode in
          (* Submitted against required. A request that owes three artifacts
             and has one is the row an operator acts on first, and the pair
             says that where a single count would not. *)
          let evidence =
            match r.vr_evidence_error with
            | Some _ -> "unreadable"
            | None ->
                Printf.sprintf "%d/%d"
                  (List.length r.vr_submitted_evidence)
                  (List.length r.vr_required_artifacts)
          in
          let asks =
            match r.vr_next_action with
            | Some action -> action
            | None -> r.vr_summary
          in
          let line =
            Printf.sprintf "  %-14s %-16s %-9s %s"
              (Terminal_text.single_line r.vr_task_id)
              (Terminal_text.single_line r.vr_submitted_by)
              evidence
              (Terminal_text.single_line asks)
          in
          let style =
            (* Evidence that cannot be read is the one row that cannot be
               judged as it stands, so it reads as a problem rather than as a
               queue entry. *)
            match r.vr_evidence_error with
            | Some _ -> Theme.bad
            | None -> Ansi.reset
          in
          box_line_styled buf cols ~style line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:Ansi.dim
      (Printf.sprintf "[%d requests, scroll %d]" shown scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"verification" ~rows:terminal_rows ~cols buf

(* What the harness decided, most recent first.

   A verdict reached by a fallback evaluator is not the verdict that was asked
   for, so the row says which evaluator answered and marks the ones that were
   not the intended one. Reading a column of "approve" without that would say
   the gate is working when it may only be degrading quietly. *)
let render_harness (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let verdicts =
    match state.harness with
    | None -> []
    | Some s -> s.Masc.Tui_decode.hs_verdicts
  in
  let shown = List.length verdicts in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let fallbacks =
    List.length
      (List.filter
         (fun (v : Masc.Tui_decode.harness_verdict) ->
           Option.is_some v.Masc.Tui_decode.hv_fallback_reason)
         verdicts)
  in
  let header =
    match state.harness with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Harness") timestamp
          (connection_badge state.connection_status)
    | Some _ when fallbacks > 0 ->
        (* The count is the reading an operator opens this for: verdicts that
           came from something other than the evaluator the gate names. *)
        Printf.sprintf "%s (%d verdicts, %d by fallback)  %s  %s"
          (screen_title " MASC Harness")
          shown fallbacks timestamp (connection_badge state.connection_status)
    | Some _ ->
        Printf.sprintf "%s (%d verdicts)  %s  %s"
          (screen_title " MASC Harness") shown timestamp
          (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let col_hdr =
    Printf.sprintf "  %-8s %-14s %-9s %-9s %s" "Time" "Task" "Gate" "Verdict"
      "Evaluator"
  in
  box_line_styled buf cols ~style:Ansi.dim col_hdr;
  box_divider buf cols;
  (match state.harness_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:Theme.bad
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = if Option.is_some state.harness_error then 9 else 7 in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.harness_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      match empty_page_of ~snapshot:state.harness ~error:state.harness_error with
      | Page_failed -> "  (load failed; nothing here is a reading)"
      | Page_unread -> "  (not loaded yet)"
      | Page_empty -> "  (no verdicts recorded)"
    in
    box_line_styled buf cols ~style:Ansi.dim empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match List.nth_opt verdicts idx with
      | None -> box_empty buf cols
      | Some v ->
          let open Masc.Tui_decode in
          let evaluator =
            match v.hv_fallback_reason with
            | None -> v.hv_evaluator
            | Some reason ->
                Printf.sprintf "%s (fallback: %s)" v.hv_evaluator reason
          in
          let line =
            Printf.sprintf "  %-8s %-14s %-9s %-9s %s"
              (Terminal_text.clock_timestamp
                 (Masc_domain.iso8601_of_unix_seconds v.hv_at))
              (Terminal_text.single_line v.hv_task_id)
              (Terminal_text.single_line v.hv_gate)
              (Terminal_text.single_line v.hv_verdict)
              (Terminal_text.single_line evaluator)
          in
          let style =
            match v.hv_fallback_reason with
            | Some _ -> Theme.warn
            | None -> Ansi.reset
          in
          box_line_styled buf cols ~style line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:Ansi.dim
      (Printf.sprintf "[%d verdicts, scroll %d]" shown scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"harness" ~rows:terminal_rows ~cols buf

let fusion_run_status_color = function
  | Fusion_running -> Ansi.cyan
  | Fusion_completed -> Theme.ok
  | Fusion_failed _ -> Theme.bad

let fusion_run_clock run =
  Terminal_text.clock_timestamp
    (Masc_domain.iso8601_of_unix_seconds run.fur_started_at)

let render_fusion_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let runs =
    match state.fusion_runs with
    | None -> []
    | Some snapshot -> snapshot.fus_runs
  in
  let shown = List.length runs in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.fusion_runs with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Fusion") timestamp
          (connection_badge state.connection_status)
    | Some _ ->
        Printf.sprintf "%s (%d runs)  %s  %s"
          (screen_title " MASC Fusion") shown timestamp
          (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  box_line_styled buf cols ~style:Ansi.dim
    (Printf.sprintf "  %-8s %-9s %-16s %-10s %-10s %s" "TIME" "STATUS"
       "KEEPER" "PRESET" "TOPOLOGY" "RUN");
  box_divider buf cols;
  (match state.fusion_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:Theme.bad
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = listing_chrome ~error:state.fusion_error in
  let content_height = max 1 (rows - chrome_rows) in
  let scroll =
    if state.fusion_cursor >= content_height then
      state.fusion_cursor - content_height + 1
    else 0
  in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.fusion_runs ~error:state.fusion_error
      with
      | Page_failed -> "  (load failed; nothing here is a reading)"
      | Page_unread -> "  (not loaded yet)"
      | Page_empty -> "  (no retained Fusion runs)"
    in
    box_line_styled buf cols ~style:Ansi.dim empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for index = 0 to content_height - 1 do
      let row_index = index + scroll in
      match List.nth_opt runs row_index with
      | None -> box_empty buf cols
      | Some run ->
          let status = fusion_run_status_to_string run.fur_status in
          let line =
            Printf.sprintf "%-8s %s%-9s%s %-16s %-10s %-10s %s"
              (fusion_run_clock run)
              (fusion_run_status_color run.fur_status)
              status Ansi.reset
              (fit_width (Terminal_text.single_line run.fur_keeper) 16)
              (fit_width (Terminal_text.single_line run.fur_preset) 10)
              (fit_width
                 (Fusion_types.fusion_topology_to_string run.fur_topology)
                 10)
              (Terminal_text.single_line run.fur_run_id)
          in
          if row_index = state.fusion_cursor then
            box_line buf cols (Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line)
          else box_line buf cols ("  " ^ line)
    done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~hints:"j/k:move  Enter:detail  r:refresh  Tab:next  q:quit");
  finish_surface state ~surface_key:"fusion-list" ~rows:terminal_rows ~cols buf

let fusion_wrapped_block ~width ~indent text =
  let body_width = max 1 (width - Message_layout.display_width indent) in
  String.split_on_char '\n' text
  |> List.concat_map (fun raw ->
         let safe = Terminal_text.single_line raw in
         if String.equal safe "" then [ indent ^ "(empty)" ]
         else
           Message_layout.wrap_words ~max_cells:body_width safe
           |> List.map (fun line -> indent ^ line))
  |> List.map (fun line -> Ansi.reset, line)

let fusion_labeled_block ~width ~label text =
  (Ansi.bold, "  " ^ label)
  :: fusion_wrapped_block ~width ~indent:"    " text

let fusion_detail_lines ~width (detail : fusion_detail) =
  let run = detail.fud_run in
  let status = fusion_run_status_to_string run.fur_status in
  let run_lines =
    [ fusion_run_status_color run.fur_status, "  Status: " ^ status
    ; Ansi.reset, "  Keeper: " ^ Terminal_text.single_line run.fur_keeper
    ; Ansi.reset, "  Preset: " ^ Terminal_text.single_line run.fur_preset
    ; ( Ansi.reset
    , "  Topology: "
      ^ Fusion_types.fusion_topology_to_string run.fur_topology )
    ; Ansi.dim, "  Started: " ^ fusion_run_clock run
    ]
    @
    match run.fur_status with
    | Fusion_running | Fusion_completed -> []
    | Fusion_failed failure ->
        [ Theme.bad
        , Printf.sprintf "  Registry failure [%s]: %s"
            (Terminal_text.single_line failure.frs_failure_code)
            (Terminal_text.single_line failure.frs_error)
        ]
  in
  let evidence_lines =
    match detail.fud_evidence_status, detail.fud_evidence with
    | Fusion_evidence_pending, None ->
        [ Theme.warn, "  Evidence: pending (run is still running)" ]
    | Fusion_evidence_absent, None ->
        [ Theme.warn
        , "  Evidence: absent (no current Board projection for this retained run)"
        ]
    | Fusion_evidence_recorded, Some evidence ->
        let panel_lines =
          evidence.fe_panel
          |> List.mapi (fun index result ->
                 match result with
                 | Fusion_panel_answered answer ->
                     [ ( Theme.ok
                       , Printf.sprintf
                           "  Panel %d [answered] %s  (%d in / %d out)"
                           (index + 1)
                           (Terminal_text.single_line answer.fpa_model)
                           answer.fpa_input_tokens answer.fpa_output_tokens )
                     ]
                     @ fusion_wrapped_block ~width ~indent:"    "
                         answer.fpa_answer
                 | Fusion_panel_failed failure ->
                     [ ( Theme.bad
                       , Printf.sprintf "  Panel %d [failed] %s  [%s]"
                           (index + 1)
                           (Terminal_text.single_line failure.fpf_model)
                           (Terminal_text.single_line failure.fpf_reason_code) )
                     ]
                     @ fusion_wrapped_block ~width ~indent:"    "
                         failure.fpf_reason_detail)
          |> List.concat
        in
        let judge_lines =
          match evidence.fe_judge with
          | Fusion_judge_synthesized judge ->
              [ ( Ansi.magenta
                , "  Judge [synthesized] "
                  ^ Terminal_text.single_line judge.fj_decision )
              ]
              @ fusion_labeled_block ~width ~label:"Resolved"
                  judge.fj_resolved_answer
              @ fusion_labeled_block ~width ~label:"Reason" judge.fj_reason
          | Fusion_judge_failed failure ->
              [ ( Theme.bad
                , "  Judge [failed] ["
                  ^ Terminal_text.single_line failure.fj_failure_code
                  ^ "]" )
              ]
              @ fusion_wrapped_block ~width ~indent:"    " failure.fj_error
        in
        [ Theme.ok, "  Evidence: recorded"
        ; Ansi.bold, "  Title: " ^ Terminal_text.single_line evidence.fe_title
        ]
        @ fusion_labeled_block ~width ~label:"Question" evidence.fe_question
        @ [ Ansi.dim, "" ]
        @ panel_lines @ [ Ansi.dim, "" ] @ judge_lines
    | Fusion_evidence_recorded, None
    | Fusion_evidence_pending, Some _
    | Fusion_evidence_absent, Some _ ->
        (* The strict decoder makes these states unreachable. Keeping the row
           explicit protects locally-constructed test state from looking like
           a legitimate empty reading. *)
        [ Theme.bad, "  Fusion evidence invariant violated" ]
  in
  run_lines @ [ Ansi.dim, "" ] @ evidence_lines

let render_fusion_detail (state : state) run_id =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 8192 in
  let detail =
    match state.fusion_detail with
    | Some detail when String.equal detail.fud_run.fur_run_id run_id ->
        Some detail
    | Some _ | None -> None
  in
  let header =
    Printf.sprintf "%s  %s  %s" (screen_title " MASC Fusion")
      (fit_width (Terminal_text.single_line run_id) 38)
      (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (match state.fusion_detail_error with
   | None -> ()
   | Some error ->
       box_line_styled buf cols ~style:Theme.bad
         ("  " ^ Keeper_chat.terminal_safe_text error);
       box_divider buf cols);
  let chrome_rows =
    if Option.is_some state.fusion_detail_error then 7 else 5
  in
  let content_height = max 1 (rows - chrome_rows) in
  let lines =
    match detail, state.fusion_detail_error with
    | None, None -> [ Ansi.dim, "  (loading exact Fusion detail)" ]
    | None, Some _ ->
        [ Ansi.dim, "  (load failed; nothing here is a reading)" ]
    | Some detail, (Some _ | None) ->
        fusion_detail_lines ~width:(max 1 (cols - 8)) detail
  in
  let total = List.length lines in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.fusion_scroll max_scroll) in
  for index = 0 to content_height - 1 do
    match List.nth_opt lines (index + scroll) with
    | None -> box_empty buf cols
    | Some (style, line) -> box_line_styled buf cols ~style line
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state
       ~hints:
         (Printf.sprintf "j/k:scroll (%d/%d)  Esc:back  r:refresh  Tab:next"
            scroll max_scroll));
  finish_surface state ~clamped:(Fusion_detail_scroll scroll)
    ~surface_key:"fusion-detail" ~rows:terminal_rows ~cols buf

(* The repositories a keeper can work in.

   Auto-sync and the assigned keepers are the two columns that change what an
   operator does next: a repository nobody is assigned to will not move on its
   own, and one that is not syncing is working from whatever was last pulled. *)
let render_repositories (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let repos =
    match state.repositories with
    | None -> []
    | Some s -> s.Masc.Tui_decode.rs_repositories
  in
  let shown = List.length repos in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.repositories with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Repositories") timestamp
          (connection_badge state.connection_status)
    | Some _ ->
        Printf.sprintf "%s (%d)  %s  %s"
          (screen_title " MASC Repositories") shown timestamp
          (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let col_hdr =
    Printf.sprintf "  %-18s %-12s %-9s %-6s %s" "Name" "Branch" "Status" "Sync"
      "Keepers"
  in
  box_line_styled buf cols ~style:Ansi.dim col_hdr;
  box_divider buf cols;
  (match state.repositories_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:Theme.bad
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = if Option.is_some state.repositories_error then 9 else 7 in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.repositories_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.repositories
          ~error:state.repositories_error
      with
      | Page_failed -> "  (load failed; nothing here is a reading)"
      | Page_unread -> "  (not loaded yet)"
      | Page_empty -> "  (no repositories registered)"
    in
    box_line_styled buf cols ~style:Ansi.dim empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match List.nth_opt repos idx with
      | None -> box_empty buf cols
      | Some r ->
          let open Masc.Tui_decode in
          let keepers =
            match r.rp_keepers with
            | [] -> "-"
            | names -> String.concat ", " names
          in
          let line =
            Printf.sprintf "  %-18s %-12s %-9s %-6s %s"
              (Terminal_text.single_line r.rp_name)
              (Terminal_text.single_line r.rp_default_branch)
              (Terminal_text.single_line r.rp_status)
              (if r.rp_auto_sync then "auto" else "manual")
              (Terminal_text.single_line keepers)
          in
          (* A repository nobody works in is dim rather than absent: it is
             registered, and that it has no keeper is the thing to notice. *)
          let style = match r.rp_keepers with [] -> Ansi.dim | _ -> Ansi.reset in
          box_line_styled buf cols ~style line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:Ansi.dim
      (Printf.sprintf "[%d repositories, scroll %d]" shown scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"repositories" ~rows:terminal_rows ~cols buf

(* The files a keeper wrote, read back out of the tool-call log.

   The durable chat transcript keeps a rendered line per tool call and drops
   the arguments, so once a turn ends there is nowhere on this surface to see
   what an Edit replaced. This row is where that is: the address the file has
   in any checkout, the turn and task it belonged to, and enough of the new
   text to recognise it by. Pressing the open key hands the selected row to
   the operator's editor. *)
let change_row_address (change : Masc.Tui_decode.file_change) =
  match change.Masc.Tui_decode.fc_location with
  | Masc.Tui_decode.Fc_in_repo { repo_id; relative_path } ->
      Printf.sprintf "%s:%s" repo_id relative_path
  | Masc.Tui_decode.Fc_in_bundle { bundle_path } -> bundle_path
  | Masc.Tui_decode.Fc_at_absolute_path { path } -> path

(* One line of what the change put there. An edit shows the text it wrote
   rather than the text it removed: the question a reader has is what the file
   says now. A write shows its size, because the whole body is never one row
   and a truncated first line of a new file says less than its length. *)
let change_row_summary (change : Masc.Tui_decode.file_change) =
  match change.Masc.Tui_decode.fc_kind with
  | Masc.Tui_decode.Fc_edited { after; _ } ->
      Terminal_text.single_line after
  | Masc.Tui_decode.Fc_written { content } ->
      Printf.sprintf "(wrote %d bytes)" (String.length content)

module Span = Masc_tui_span
module Diff = Masc_tui_diff

(* A row of the diff, drawn as layers rather than as one styled string.

   Three styles overlap on every line: the row's background, the gutter's
   weight, and the text's own colour. Concatenating them would let the
   gutter's reset close the background, and the line would lose its colour
   from the marker onward -- the fault [Masc_tui_span] exists for. *)
let diff_row_span ~width (row : Diff.row) =
  let background, marker, text =
    match row with
    | Diff.Removed line -> (Span.bg Ansi.bg_removed, "-", line)
    | Diff.Added line -> (Span.bg Ansi.bg_added, "+", line)
    | Diff.Context line -> (Span.plain, " ", line)
  in
  (* Context is dim so the changed lines are what an eye lands on. The marker
     is bold against the same background, which is what tells the two apart
     where the terminal has no colour. *)
  let text_style =
    match row with
    | Diff.Context _ -> Span.combine background (Span.weight Ansi.dim)
    | Diff.Removed _ | Diff.Added _ -> background
  in
  let composed =
    Span.concat
      [ Span.text (Span.combine background (Span.weight Ansi.bold)) (marker ^ " ")
      ; Span.text text_style (Terminal_text.single_line text)
      ]
  in
  (* Padded to the full width with the row's own background: colour that stops
     at the last character makes lines of different lengths look like
     different kinds of line. Truncated first, because padding does not
     shorten. *)
  Span.pad_to width background (Span.truncate width composed)

let box_line_span buf cols span =
  let inner = cols - 4 in
  Buffer.add_string buf
    (Printf.sprintf "  %s  \n" (Span.render (Span.pad_to inner Span.plain (Span.truncate inner span))))

(* The two halves of one change. A write has no removed half: its before is
   empty, so every line arrives as an addition, which is what a new file is. *)
let change_diff_halves (change : Masc.Tui_decode.file_change) =
  match change.Masc.Tui_decode.fc_kind with
  | Masc.Tui_decode.Fc_edited { before; after; _ } -> (before, after)
  | Masc.Tui_decode.Fc_written { content } -> ("", content)

let render_changes_diff (state : state) (change : Masc.Tui_decode.file_change) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let before, after = change_diff_halves change in
  let diff_rows = Diff.rows ~before ~after in
  let removed, added = Diff.counts diff_rows in
  let total = List.length diff_rows in
  let header =
    Printf.sprintf "%s %s  -%d +%d  %s"
      (screen_title " MASC Change")
      (Terminal_text.single_line (change_row_address change))
      removed added
      (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  (* Facts about the change the rows themselves cannot carry. *)
  let notes =
    let turn =
      Printf.sprintf "  turn %s  task %s  %s"
        (Option.fold ~none:"-" ~some:string_of_int change.Masc.Tui_decode.fc_turn)
        (Terminal_text.single_line
           (Option.value ~default:"-" change.Masc.Tui_decode.fc_task_id))
        (if change.Masc.Tui_decode.fc_succeeded then "applied"
         else "the call failed; this is what it tried to write")
    in
    match change.Masc.Tui_decode.fc_kind with
    | Masc.Tui_decode.Fc_edited { replace_all = true; _ } ->
        (* Every occurrence changed, and the log records the text once. Showing
           one pair without saying so would undercount the change. *)
        [ turn; "  replace_all: every occurrence changed; the log holds the text once" ]
    | Masc.Tui_decode.Fc_edited { replace_all = false; _ }
    | Masc.Tui_decode.Fc_written _ -> [ turn ]
  in
  List.iter (fun note -> box_line_styled buf cols ~style:Ansi.dim note) notes;
  box_divider buf cols;
  let chrome_rows = 7 + List.length notes - 1 in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.changes_diff_scroll max_scroll) in
  if total = 0 then begin
    box_line_styled buf cols ~style:Ansi.dim
      "  (the call recorded no text; there is nothing to compare)";
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      match List.nth_opt diff_rows (i + scroll) with
      | None -> box_empty buf cols
      | Some row -> box_line_span buf cols (diff_row_span ~width:(cols - 4) row)
    done;
  if total > content_height then
    box_line_styled buf cols ~style:Ansi.dim
      (Printf.sprintf "[%d lines, scroll %d]  esc closes" total scroll)
  else box_line_styled buf cols ~style:Ansi.dim "  esc closes";
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~hints:"j/k:scroll  esc:back  o:open in editor  q:quit");
  finish_surface state ~surface_key:"changes" ~rows:terminal_rows ~cols buf

let render_changes_list (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let changes =
    match state.changes with
    | None -> []
    | Some s -> s.Masc.Tui_decode.fcs_changes
  in
  let shown = List.length changes in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let whose =
    match state.changes_keeper with
    | None -> "(no keeper selected)"
    | Some name -> Terminal_text.single_line name
  in
  let header =
    match state.changes with
    | None ->
        Printf.sprintf "%s %s  (not loaded)  %s  %s"
          (screen_title " MASC Changes") whose timestamp
          (connection_badge state.connection_status)
    | Some s ->
        (* The window and the call count are stated because the list alone
           does not say what was looked at: no changes in a window and no
           calls in a window are different facts. *)
        Printf.sprintf "%s %s (%d in %.0fh of %d calls)  %s  %s"
          (screen_title " MASC Changes") whose shown
          s.Masc.Tui_decode.fcs_window_hours s.Masc.Tui_decode.fcs_calls_in_window
          timestamp
          (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let col_hdr = Printf.sprintf "  %-6s %-10s %-44s %s" "Turn" "Task" "File" "What" in
  box_line_styled buf cols ~style:Ansi.dim col_hdr;
  box_divider buf cols;
  (match state.changes_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:Theme.bad
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (* Changes the log could not carry are said out loud. A list that showed
     only what it had would tell an operator the turn wrote less than it did. *)
  let budget_note =
    match state.changes with
    | Some s when s.Masc.Tui_decode.fcs_over_budget > 0 ->
        Some
          (Printf.sprintf
             "  %d change(s) outgrew the tool-call log's inline budget; their text is not on disk"
             s.Masc.Tui_decode.fcs_over_budget)
    | Some _ | None -> None
  in
  (match budget_note with
   | None -> ()
   | Some note ->
       box_line_styled buf cols ~style:Ansi.dim note;
       box_divider buf cols);
  let chrome_rows =
    7
    + (if Option.is_some state.changes_error then 2 else 0)
    + (if Option.is_some budget_note then 2 else 0)
  in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.changes_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      match empty_page_of ~snapshot:state.changes ~error:state.changes_error with
      | Page_failed -> "  (load failed; nothing here is a reading)"
      | Page_unread -> "  (pick a keeper on the Keepers surface, then press r)"
      | Page_empty -> "  (this keeper wrote no files in the window)"
    in
    box_line_styled buf cols ~style:Ansi.dim empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match List.nth_opt changes idx with
      | None -> box_empty buf cols
      | Some change ->
          let line =
            Printf.sprintf "  %-6s %-10s %-44s %s"
              (Option.fold ~none:"-" ~some:string_of_int
                 change.Masc.Tui_decode.fc_turn)
              (Terminal_text.single_line
                 (Option.value ~default:"-" change.Masc.Tui_decode.fc_task_id))
              (Terminal_text.single_line (change_row_address change))
              (change_row_summary change)
          in
          (* A call that failed still changed what the keeper tried to do, and
             it is the row an operator is looking for. Dim marks it as an
             attempt rather than hiding it. *)
          let style =
            if change.Masc.Tui_decode.fc_succeeded then Ansi.reset else Ansi.dim
          in
          let marker = if idx = scroll then ">" else " " in
          box_line_styled buf cols ~style (marker ^ String.sub line 1 (String.length line - 1))
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:Ansi.dim
      (Printf.sprintf "[%d changes, scroll %d]" shown scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~hints:"j/k:scroll  Enter:what was written  d:what the tree holds  o:editor  r:refresh  q:quit");
  finish_surface state ~surface_key:"changes" ~rows:terminal_rows ~cols buf

(* One tree-diff row. Same three layers as the tool-call reading, plus the
   line numbers git computed -- the part an [Edit] cannot have, because it
   records two pieces of text and not where in the file they sit. *)
let tree_diff_row_span ~width (row : Masc.Tui_decode.git_diff_row) =
  let background, marker =
    match row.Masc.Tui_decode.gdr_kind with
    | Masc.Tui_decode.Gd_removed -> (Span.bg Ansi.bg_removed, "-")
    | Masc.Tui_decode.Gd_added -> (Span.bg Ansi.bg_added, "+")
    | Masc.Tui_decode.Gd_context -> (Span.plain, " ")
  in
  let gutter =
    Printf.sprintf "%s %s %s "
      (Diff.line_number_cell row.Masc.Tui_decode.gdr_old_line)
      (Diff.line_number_cell row.Masc.Tui_decode.gdr_new_line)
      marker
  in
  let text_style =
    match row.Masc.Tui_decode.gdr_kind with
    | Masc.Tui_decode.Gd_context -> Span.combine background (Span.weight Ansi.dim)
    | Masc.Tui_decode.Gd_added | Masc.Tui_decode.Gd_removed -> background
  in
  let composed =
    Span.concat
      [ Span.text (Span.combine background (Span.weight Ansi.dim)) gutter
      ; Span.text text_style
          (Terminal_text.single_line row.Masc.Tui_decode.gdr_text)
      ]
  in
  Span.pad_to width background (Span.truncate width composed)

(* What the tree holds for the file the cursor names. Separate from the
   tool-call reading by decision, not by accident: one says what the keeper
   tried to write and the other what survived, and a single view would make
   whichever it drew look like the whole answer. *)
let render_changes_tree_diff (state : state)
    (change : Masc.Tui_decode.file_change) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let diff_rows =
    match state.changes_tree_diff with
    | None -> []
    | Some diff -> diff.Masc.Tui_decode.gd_rows
  in
  let total = List.length diff_rows in
  let header =
    Printf.sprintf "%s %s  vs HEAD  %s"
      (screen_title " MASC Tree")
      (Terminal_text.single_line (change_row_address change))
      (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  box_line_styled buf cols ~style:Ansi.dim
    "  old   new     what the working tree holds, against its last commit";
  box_divider buf cols;
  (match state.changes_tree_diff_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:Theme.bad
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows =
    7 + if Option.is_some state.changes_tree_diff_error then 2 else 0
  in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.changes_diff_scroll max_scroll) in
  if total = 0 then begin
    (* Three different facts, and none of them is the others: not read yet, a
       failed read, and a file that matches its last commit. *)
    let empty =
      match (state.changes_tree_diff, state.changes_tree_diff_error) with
      | _, Some _ -> "  (the read failed; nothing here is a reading)"
      | None, None -> "  (reading the tree)"
      | Some diff, None ->
          if diff.Masc.Tui_decode.gd_has_changes then
            "  (the tree reports a change and sent no lines)"
          else "  (this file matches its last commit)"
    in
    box_line_styled buf cols ~style:Ansi.dim empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      match List.nth_opt diff_rows (i + scroll) with
      | None -> box_empty buf cols
      | Some row ->
          box_line_span buf cols (tree_diff_row_span ~width:(cols - 4) row)
    done;
  box_line_styled buf cols ~style:Ansi.dim
    (if total > content_height then
       Printf.sprintf "[%d lines, scroll %d]  esc closes" total scroll
     else "  esc closes");
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~hints:"j/k:scroll  esc:back  o:open in editor  q:quit");
  finish_surface state ~surface_key:"changes" ~rows:terminal_rows ~cols buf

(* The surface has two readings: the list, and one change opened. The open row
   is held as an index, so a refresh that shortens the list closes the diff
   rather than drawing a change the answer no longer holds. *)
let render_changes (state : state) =
  let opened =
    match (state.changes_diff_row, state.changes) with
    | Some row, Some snapshot ->
        List.nth_opt snapshot.Masc.Tui_decode.fcs_changes row
    | Some _, None | None, (Some _ | None) -> None
  in
  match opened with
  | Some change ->
      (* A path being read names the tree reading. Both readings of the same
         row exist at once; which one is drawn is the operator's last key, not
         whichever answer arrived last. *)
      if Option.is_some state.changes_tree_diff_path then
        render_changes_tree_diff state change
      else render_changes_diff state change
  | None -> render_changes_list state

(* Where the gate can deliver.

   Configured and reachable are separate columns because they call for
   different actions: one is a setup gap, the other is something that was
   working and is not. A connector that is set up but unreachable is the row
   an operator acts on. *)
let render_connectors (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let connectors =
    match state.connectors with
    | None -> []
    | Some s -> s.Masc.Tui_decode.cs_connectors
  in
  let shown = List.length connectors in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.connectors with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Connectors") timestamp
          (connection_badge state.connection_status)
    | Some snapshot ->
        Printf.sprintf "%s (%d of %d available)  %s  %s"
          (screen_title " MASC Connectors")
          snapshot.Masc.Tui_decode.cs_active snapshot.Masc.Tui_decode.cs_total
          timestamp (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let col_hdr =
    Printf.sprintf "  %-16s %-11s %-11s %-10s %s" "Connector" "Configured"
      "Reachable" "Status" "Channel"
  in
  box_line_styled buf cols ~style:Ansi.dim col_hdr;
  box_divider buf cols;
  (match state.connectors_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:Theme.bad
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = if Option.is_some state.connectors_error then 9 else 7 in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.connectors_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.connectors ~error:state.connectors_error
      with
      | Page_failed -> "  (load failed; nothing here is a reading)"
      | Page_unread -> "  (not loaded yet)"
      | Page_empty -> "  (no connectors registered)"
    in
    box_line_styled buf cols ~style:Ansi.dim empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match List.nth_opt connectors idx with
      | None -> box_empty buf cols
      | Some c ->
          let open Masc.Tui_decode in
          let yes_no flag = if flag then "yes" else "no" in
          let line =
            Printf.sprintf "  %-16s %-11s %-11s %-10s %s"
              (Terminal_text.single_line c.cn_display_name)
              (yes_no c.cn_available) (yes_no c.cn_connected)
              (Terminal_text.single_line c.cn_status)
              (Terminal_text.single_line_or ~default:"-" c.cn_channel)
          in
          let style =
            (* Set up and unreachable is the row to act on: it was working.
               Never configured is dim -- it is a choice, not a fault. *)
            if c.cn_available && not c.cn_connected then Theme.bad
            else if not c.cn_available then Ansi.dim
            else Ansi.reset
          in
          box_line_styled buf cols ~style line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:Ansi.dim
      (Printf.sprintf "[%d connectors, scroll %d]" shown scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state
       ~hints:"j/k:scroll  b:bind  u:unbind  Tab:next  q:quit  r:refresh");
  finish_surface state ~surface_key:"connectors" ~rows:terminal_rows ~cols buf

let runtime_refresh_badge refresh_state =
  let open Masc.Tui_decode in
  let label, style =
    match refresh_state with
    | Runtime_probe_fresh -> "fresh", Theme.ok
    | Runtime_probe_recent -> "recent", Ansi.cyan
    | Runtime_probe_served_stale -> "stale", Theme.warn
    | Runtime_probe_warming_up -> "warming", Theme.warn
  in
  style ^ label ^ Ansi.reset

let runtime_overall_badge status =
  let open Masc.Tui_decode in
  let style =
    match status with
    | Runtime_probe_reachable -> Theme.ok
    | Runtime_probe_no_http_runtimes | Runtime_probe_warming -> Ansi.dim
    | Runtime_probe_degraded -> Theme.warn
    | Runtime_probe_unreachable -> Theme.bad
  in
  style ^ runtime_probe_status_to_string status ^ Ansi.reset

let runtime_route_badge (runtime : Masc.Tui_decode.runtime_option) =
  if runtime.ro_dispatchable then Ansi.cyan ^ "ready" ^ Ansi.reset
  else Theme.bad ^ "blocked" ^ Ansi.reset

let runtime_probe_badge = function
  | None -> Ansi.dim ^ "unobserved" ^ Ansi.reset
  | Some (probe : Masc.Tui_decode.runtime_provider_probe) ->
      let open Masc.Tui_decode in
      let style =
        match probe.rpp_status with
        | Runtime_provider_reachable -> Theme.ok
        | Runtime_provider_skipped_cli -> Ansi.dim
        | Runtime_provider_missing_auth | Runtime_provider_auth_failed ->
            Theme.warn
        | Runtime_provider_network_error
        | Runtime_provider_server_error
        | Runtime_provider_endpoint_not_found
        | Runtime_provider_http_error
        | Runtime_provider_unknown_http_status
        | Runtime_provider_invalid_endpoint
        | Runtime_provider_invalid_execution_transport -> Theme.bad
      in
      let label =
        match probe.rpp_status with
        | Runtime_provider_skipped_cli -> "CLI not probed"
        | status -> runtime_provider_status_to_string status
      in
      style ^ label ^ Ansi.reset

let runtime_probe_detail = function
  | None -> []
  | Some (probe : Masc.Tui_decode.runtime_provider_probe) ->
      let latency =
        Option.map (fun value -> Printf.sprintf "%.0fms" value) probe.rpp_latency_ms
      in
      let http =
        Option.map (fun value -> Printf.sprintf "HTTP %d" value) probe.rpp_http_status
      in
      let error = Terminal_text.optional_single_line probe.rpp_error in
      let checked =
        Some ("checked " ^ Terminal_text.clock_timestamp probe.rpp_checked_at)
      in
      List.filter_map Fun.id [ latency; http; error; checked ]

let runtime_column_widths cols =
  if cols >= 140 then 18, 30, 30, 22
  else if cols >= 120 then 14, 24, 24, 22
  else 10, 20, 20, 22

let runtime_column width text =
  let clipped = fit_width text width in
  clipped
  ^ String.make
      (max 0 (width - Message_layout.display_width clipped))
      ' '

(* Lane candidates come from /runtime/resolved; reachability comes from the
   cached runtime-probe document. Exact runtime-id joining happened in the
   decoder module, so drawing never parses ids or reconstructs a lane. *)
let render_runtime (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let ( runtime_lane_width
      , runtime_candidate_width
      , runtime_identity_width
      , runtime_status_width ) =
    runtime_column_widths cols
  in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let candidates =
    match state.runtime_surface with
    | None -> []
    | Some snapshot -> snapshot.Masc.Tui_decode.rss_candidates
  in
  let shown = List.length candidates in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.runtime_surface with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Runtime") timestamp
          (connection_badge state.connection_status)
    | Some snapshot ->
        let lane_count = List.length snapshot.rss_resolved.rrs_lanes in
        let probe_status =
          match snapshot.Masc.Tui_decode.rss_probe with
          | None -> Theme.warn ^ "probe unavailable" ^ Ansi.reset
          | Some probe ->
              runtime_overall_badge probe.rps_status ^ " / "
              ^ runtime_refresh_badge probe.rps_refresh_state
        in
        let probe_read =
          if Option.is_some snapshot.rss_probe_error then
            Theme.warn ^ " / read failed" ^ Ansi.reset
          else ""
        in
        Printf.sprintf "%s (%d lanes, %d candidates)  %s%s  %s  %s"
          (screen_title " MASC Runtime") lane_count shown probe_status probe_read
          timestamp (connection_badge state.connection_status)
  in
  let authority_line =
    match state.runtime_surface with
    | None ->
        "  SSOT: runtime.toml  projections: /api/v1/runtime/resolved + runtime-probe"
    | Some snapshot ->
        let config =
          Terminal_text.single_line_or ~default:"config path unavailable"
            snapshot.rss_resolved.rrs_config_path
        in
        let summary_text =
          match snapshot.Masc.Tui_decode.rss_probe with
          | None -> "probe unavailable"
          | Some probe ->
              let summary = probe.rps_summary in
              Printf.sprintf "%d reachable / %d failed / %d skipped"
                summary.rpsu_reachable summary.rpsu_failed summary.rpsu_skipped
        in
        let probe_note =
          match snapshot.rss_probe_error, snapshot.rss_probe with
          | Some detail, _ -> "  probe: " ^ Terminal_text.single_line detail
          | None, Some probe ->
              (match probe.rps_errors with
               | detail :: _ -> "  probe: " ^ Terminal_text.single_line detail
               | [] -> "")
          | None, None -> ""
        in
        let probe_only_note =
          match snapshot.rss_unassigned_probe_count with
          | 0 -> ""
          | count -> Printf.sprintf "  %d probe-only" count
        in
        Printf.sprintf
          "  SSOT: runtime.toml  projections: resolved + probe  %s  %s%s%s"
          summary_text config probe_only_note probe_note
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let authority_style =
    match state.runtime_surface with
    | Some snapshot when Option.is_some snapshot.rss_probe_error -> Theme.warn
    | Some _ | None -> Ansi.dim
  in
  box_line_styled buf cols ~style:authority_style authority_line;
  box_divider buf cols;
  box_line_styled buf cols ~style:Ansi.dim
    ("  "
     ^ runtime_column runtime_lane_width "LANE" ^ " "
     ^ runtime_column runtime_candidate_width "CANDIDATE" ^ " "
     ^ runtime_column runtime_identity_width "PROVIDER / MODEL" ^ " "
     ^ runtime_column runtime_status_width "ROUTE / PROBE"
     ^ " DETAIL");
  box_divider buf cols;
  (match state.runtime_surface_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:Theme.bad
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = runtime_listing_chrome ~error:state.runtime_surface_error in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.runtime_surface_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      match
        empty_page_of ~snapshot:state.runtime_surface
          ~error:state.runtime_surface_error
      with
      | Page_failed -> "  (load failed; nothing here is a reading)"
      | Page_unread -> "  (not loaded yet)"
      | Page_empty -> "  (no runtime lanes configured)"
    in
    box_line_styled buf cols ~style:Ansi.dim empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for index = 0 to content_height - 1 do
      match List.nth_opt candidates (index + scroll) with
      | None -> box_empty buf cols
      | Some candidate ->
          let open Masc.Tui_decode in
          let runtime = candidate.rcr_runtime in
          let candidate_label =
            Printf.sprintf "%d/%d %s" candidate.rcr_position
              candidate.rcr_candidate_count
              (Terminal_text.single_line runtime.ro_id)
          in
          let provider_model =
            Terminal_text.single_line
              (runtime.ro_provider ^ " / " ^ runtime.ro_model)
          in
          let route_probe =
            runtime_route_badge runtime ^ " / "
            ^ runtime_probe_badge candidate.rcr_probe
          in
          let route_detail =
            if runtime.ro_dispatchable then []
            else
              match Terminal_text.optional_single_line runtime.ro_blocked_reason with
              | Some reason -> [ "blocked: " ^ reason ]
              | None -> []
          in
          let lane_fact =
            match candidate.rcr_preferred_at_ts with
            | Some at ->
                [ "last success "
                  ^ Terminal_text.clock_timestamp
                      (Masc_domain.iso8601_of_unix_seconds at)
                ]
            | None when candidate.rcr_candidate_count = 1 -> [ "single candidate" ]
            | None -> []
          in
          let default_fact = if runtime.ro_is_default then [ "default" ] else [] in
          let detail =
            String.concat " \xc2\xb7 "
              (route_detail @ default_fact @ lane_fact
               @ runtime_probe_detail candidate.rcr_probe)
          in
          let line =
            "  "
            ^ runtime_column runtime_lane_width
                (Terminal_text.single_line candidate.rcr_lane_id)
            ^ " " ^ runtime_column runtime_candidate_width candidate_label
            ^ " " ^ runtime_column runtime_identity_width provider_model
            ^ " " ^ runtime_column runtime_status_width route_probe
            ^ " " ^ detail
          in
          box_line buf cols line
    done;
  let scroll_hint =
    if shown > content_height then
      Printf.sprintf "[%d candidates, scroll %d]  " shown scroll
    else ""
  in
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state
       ~hints:
         (Printf.sprintf "%sj/k:scroll  Tab:next  q:quit  r:live refresh"
            scroll_hint));
  finish_surface state ~surface_key:"runtime" ~rows:terminal_rows ~cols buf

(* The tools a keeper can reach.

   Surfaces is the column that carries the reading: a tool registered and
   projected nowhere is reachable by nothing, which the name and description
   do not say. *)
let render_tools (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let tools =
    match state.tools_inventory with
    | None -> []
    | Some s -> s.Masc.Tui_decode.ts_tools
  in
  let tool_rows = Tool_tree.rows tools in
  let shown = List.length tools in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let unprojected =
    List.length
      (List.filter
         (fun (t : Masc.Tui_decode.tool_entry) ->
           t.Masc.Tui_decode.tl_surfaces = [])
         tools)
  in
  let header =
    match state.tools_inventory with
    | None ->
        Printf.sprintf "%s  (not loaded)  %s  %s"
          (screen_title " MASC Tools") timestamp
          (connection_badge state.connection_status)
    | Some _ when unprojected > 0 ->
        Printf.sprintf "%s (%d, %d on no surface)  %s  %s"
          (screen_title " MASC Tools") shown
          unprojected timestamp (connection_badge state.connection_status)
    | Some _ ->
        Printf.sprintf "%s (%d)  %s  %s"
          (screen_title " MASC Tools") shown timestamp
          (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line buf cols header;
  box_divider buf cols;
  let col_hdr =
    Printf.sprintf "  %-32s %-8s %s" "Tool" "Direct" "Surfaces"
  in
  box_line_styled buf cols ~style:Ansi.dim col_hdr;
  box_divider buf cols;
  (match state.tools_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:Theme.bad
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  let chrome_rows = if Option.is_some state.tools_error then 9 else 7 in
  let content_height = max 1 (rows - chrome_rows) in
  let drawable = List.length tool_rows in
  let max_scroll = max 0 (drawable - content_height) in
  let scroll = max 0 (min state.tools_scroll max_scroll) in
  if shown = 0 then begin
    let warming =
      match state.tools_inventory with
      | Some { Masc.Tui_decode.ts_freshness = Masc.Tui_decode.Warming; _ } -> true
      | Some _ | None -> false
    in
    let empty =
      (* A server still building its inventory answers with an empty list, and
         reading that as "none" told an operator their workspace had no tools
         when it has a hundred. The payload says which of the two it is. *)
      if warming then "  (the server is still building its tool inventory)"
      else
        match
          empty_page_of ~snapshot:state.tools_inventory ~error:state.tools_error
        with
        | Page_failed -> "  (load failed; nothing here is a reading)"
        | Page_unread -> "  (not loaded yet)"
        | Page_empty -> "  (no tools registered)"
    in
    box_line_styled buf cols ~style:Ansi.dim empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match List.nth_opt tool_rows idx with
      | None -> box_empty buf cols
      | Some (Tool_tree.Domain { name; count }) ->
          (* A rule line after the name: the domain is the question the
             section answers, and a heavier separation than the family's
             plain bold keeps the three depths readable apart. The rule is a
             fixed length rather than filling the row -- box_line_styled
             pads, and a domain heading that shouts across the full width
             would outrank the surface header above it. *)
          let rule = "─────────────────────" in
          box_line_styled buf cols ~style:Ansi.bold
            (Printf.sprintf " %s (%d) %s" (Terminal_text.single_line name) count rule)
      | Some (Tool_tree.Family { name; count }) ->
          box_line_styled buf cols ~style:Ansi.bold
            (Printf.sprintf "    %s  (%d)" (Terminal_text.single_line name) count)
      | Some (Tool_tree.Tool t) ->
          let open Masc.Tui_decode in
          let surfaces =
            match t.tl_surfaces with
            | [] -> "none"
            | names -> String.concat ", " names
          in
          (* Indented under the family heading above it, one deeper than the
             family sits under its domain, so the name column reads as a
             three-level tree rather than as a hundred equals. *)
          let line =
            Printf.sprintf "      %-30s %-8s %s"
              (Terminal_text.single_line t.tl_name)
              (if t.tl_direct_call then "yes" else "no")
              (Terminal_text.single_line surfaces)
          in
          let style = if t.tl_surfaces = [] then Theme.warn else Ansi.dim in
          box_line_styled buf cols ~style line
    done;
  if drawable > content_height then
    box_line_styled buf cols ~style:Ansi.dim
      (Printf.sprintf "[%d tools, scroll %d]" shown scroll);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~hints:(Masc_tui_keys.footer_hints state.view));
  finish_surface state ~surface_key:"tools" ~rows:terminal_rows ~cols buf

(** Dispatch a normal-height render based on the current surface. *)
(* One keeper's durable tool-call log, the row vocabulary the chat pane
   uses: the finished glyph for a call that returned, the failure glyph for
   one that returned an error, the subject the trail names the call by. The
   server's own freshness verdict rides the header - a stale page must not
   read as a quiet keeper. *)
let render_keeper_calls (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let keeper_name =
    match List.nth_opt state.keepers state.keeper_cursor with
    | Some keeper -> keeper.k_name
    | None -> "?"
  in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let header =
    match state.keeper_calls with
    | None ->
        Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 calls  (not loaded yet)  %s  %s"
          (Terminal_text.single_line keeper_name)
          timestamp
          (connection_badge state.connection_status)
    | Some snapshot ->
        let freshness =
          match
            (snapshot.Masc.Tui_decode.kcs_health,
             snapshot.Masc.Tui_decode.kcs_latest_age_s)
          with
          | "ok", Some age -> Printf.sprintf "ok · latest %.0fs ago" age
          | health, Some age -> Printf.sprintf "%s · latest %.0fs ago" health age
          | health, None -> health
        in
        Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 calls (%d)  %s  %s  %s"
          (Terminal_text.single_line keeper_name)
          (List.length snapshot.Masc.Tui_decode.kcs_entries)
          freshness timestamp
          (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line_styled buf cols ~style:Ansi.bold header;
  box_divider buf cols;
  let col_hdr =
    Printf.sprintf "  %-8s %s %-24s %-8s %-6s %s" "Time" " " "Tool" "Dur"
      "Turn" "Subject"
  in
  box_line_styled buf cols ~style:Ansi.dim col_hdr;
  box_divider buf cols;
  (match state.keeper_calls_error with
   | None -> ()
   | Some detail ->
       box_line_styled buf cols ~style:Theme.bad
         ("  " ^ Keeper_chat.terminal_safe_text detail);
       box_divider buf cols);
  (match state.keeper_calls with
   | Some snapshot when snapshot.Masc.Tui_decode.kcs_mismatched > 0 ->
       box_line_styled buf cols ~style:Theme.warn
         (Printf.sprintf
            "  %d row(s) named another keeper and were not drawn"
            snapshot.Masc.Tui_decode.kcs_mismatched);
       box_divider buf cols
   | Some _ | None -> ());
  let entries =
    match state.keeper_calls with
    | None -> []
    | Some snapshot -> snapshot.Masc.Tui_decode.kcs_entries
  in
  let shown = List.length entries in
  let extra_rows =
    (if Option.is_some state.keeper_calls_error then 2 else 0)
    + (match state.keeper_calls with
       | Some snapshot when snapshot.Masc.Tui_decode.kcs_mismatched > 0 -> 2
       | Some _ | None -> 0)
  in
  let chrome_rows = 8 + extra_rows in
  let content_height = max 1 (rows - chrome_rows) in
  (* Digested once, for the bound and for the drawing both. Working it out
     twice would let the scroll bound believe in a different table than the
     one on screen. *)
  let rows =
    List.map
      (fun (call : Masc.Tui_decode.keeper_call) ->
        ( call
        , Option.bind call.Masc.Tui_decode.kc_output (fun result ->
              Masc.Keeper_chat_tool_trail.tool_result_digest ~result) ))
      entries
  in
  let max_scroll =
    Message_layout.last_page_start ~height:content_height
      (List.map (fun (_, digest) -> if Option.is_some digest then 2 else 1) rows)
  in
  let scroll = max 0 (min state.keeper_calls_scroll max_scroll) in
  (* How many calls the rows below actually reached. Filled by the drawing so
     the count under the table cannot disagree with the table. *)
  let drawn = ref 0 in
  if shown = 0 then begin
    let empty =
      match (state.keeper_calls, state.keeper_calls_error) with
      | _, Some _ -> "  (load failed; nothing here is a reading)"
      | None, None -> "  (not loaded yet)"
      | Some _, None -> "  (no calls recorded)"
    in
    box_line_styled buf cols ~style:Ansi.dim empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else begin
    (* Rows are spent, not indexed: a call draws one row and, when it answered
       something, a second for what it said. Walking the height rather than
       looping over it keeps [scroll] counting calls, so j/k still moves by
       call and the footer's count still means what it says. *)
    let remaining = ref content_height in
    let idx = ref scroll in
    while !remaining > 0 do
      match List.nth_opt rows !idx with
      | None ->
          box_empty buf cols;
          decr remaining
      | Some (call, digest) ->
          incr idx;
          let open Masc.Tui_decode in
          let glyph, style =
            if call.kc_success then ("✓", Ansi.reset)
            else ("✗", Theme.bad)
          in
          let duration =
            match call.kc_duration_ms with
            | Some ms when ms < 1000. -> Printf.sprintf "%.0fms" ms
            | Some ms -> Printf.sprintf "%.1fs" (ms /. 1000.)
            | None -> "-"
          in
          let turn =
            match call.kc_turn with Some t -> string_of_int t | None -> "-"
          in
          let subject =
            match
              Masc.Keeper_chat_tool_trail.tool_subject ~name:call.kc_tool
                ~args:call.kc_input
            with
            | Some subject -> subject
            | None -> ""
          in
          let line =
            Printf.sprintf "  %-8s %s %-24s %-8s %-6s %s"
              (Terminal_text.clock_timestamp
                 (Masc_domain.iso8601_of_unix_seconds call.kc_at))
              glyph
              (fit_width (Terminal_text.single_line call.kc_tool) 24)
              duration turn
              (Terminal_text.single_line subject)
          in
          box_line_styled buf cols ~style line;
          decr remaining;
          (* What the call answered. The row above says one ran and what it
             was called with; this is the only place that says what came
             back, which is the question a failed call leaves open. It takes
             a failed call's colour so a reason does not read as ordinary
             output. A call that answered nothing draws no row rather than an
             empty one. *)
          (match digest with
           | Some digest when !remaining > 0 ->
               box_line_styled buf cols
                 ~style:(if call.kc_success then Ansi.dim else Theme.bad)
                 (Printf.sprintf "  %-8s %s   %s" "" " "
                    (Terminal_text.single_line ("\xe2\x86\x92 " ^ digest)));
               decr remaining
           | Some _ | None -> ())
    done;
    (* How many calls the height actually reached, not how many would fit if
       each took one row. A call that answered something takes two, so
       counting rows as calls hid the hint exactly when the screen needed it. *)
    drawn := !idx - scroll
  end;
  if scroll > 0 || !drawn < shown then
    box_line_styled buf cols ~style:Ansi.dim
      (Printf.sprintf "[%d calls, showing %d from %d]" shown !drawn scroll)
  else box_empty buf cols;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~hints:"j/k:scroll  Esc:back  Tab:next  q:quit  r:refresh");
  finish_surface state ~clamped:(Keeper_calls scroll) ~surface_key:"keeper-calls" ~rows:terminal_rows ~cols buf

(* The runtime's event feed, newest first, for watching every keeper act at
   once. Rows are built from the events the TUI holds; the filter decides
   which kinds draw; a completed call is paired with its start for a
   duration. Scrolling away from the newest row freezes the view and counts
   what arrives above it, so an operator reading the past is not pushed off
   it by the present. *)
let render_acting (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let module Acting = Masc_tui_acting in
  let now = Unix.localtime (Unix.gettimeofday ()) in
  let timestamp =
    Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
      now.Unix.tm_sec
  in
  let held = List.length state.acting in
  (* The agent_core family names its runtime lane, not the keeper; the
     keeper is the one whose trace the event's correlation id carries. *)
  let traces =
    List.map (fun keeper -> (keeper.k_name, keeper.k_trace_id)) state.keepers
  in
  (* Visible entries, newest first, paired with the events older than each
     -- in a newest-first list, the tail after it -- so a completed call on
     the page can look up its start. Rows are built only for the page: the
     pairing walks the older events, and doing it for a thousand held
     entries on every frame is work the screen never shows. *)
  let visible =
    let rec walk acc = function
      | [] -> List.rev acc
      | entry :: older ->
          if Acting.visible state.acting_filter entry.ae_event then
            walk ((entry, older) :: acc) older
          else walk acc older
    in
    walk [] state.acting
  in
  let row_of (entry, older) =
    let event = entry.ae_event in
    let duration_ms =
      match event with
      | Masc_tui_observer.Agent_core
          ({ Masc_tui_observer.kind = Masc_tui_observer.Tool_completed; _ } as
           completed) ->
          Acting.duration_of_completion
            ~before:(List.map (fun e -> e.ae_event) older)
            completed
      | Masc_tui_observer.Agent_core _ | Masc_tui_observer.Keeper_heartbeat _
      | Masc_tui_observer.Keeper_tool_call _
      | Masc_tui_observer.Keeper_turn_complete _
      | Masc_tui_observer.Keeper_composite_changed _
      | Masc_tui_observer.Keeper_chat_appended _ | Masc_tui_observer.Snapshot _
      | Masc_tui_observer.Other _ ->
          None
    in
    let row = Acting.row_of_event ~duration_ms event in
    { row with Acting.keeper = Acting.keeper_of_event ~traces event }
  in
  let shown = List.length visible in
  let feed =
    match state.observer with
    | Observer_off -> "feed: off"
    | Observer_opening -> "feed: opening"
    | Observer_live { events; _ } -> Printf.sprintf "feed: live %d" events
    | Observer_closed { events; reason; _ } ->
        Printf.sprintf "feed: closed after %d (%s)" events
          (Terminal_text.single_line reason)
  in
  let header =
    Printf.sprintf " MASC Acting (%d of %d held, %s)  %s  %s" shown held
      (Acting.filter_label state.acting_filter) timestamp
      (connection_badge state.connection_status)
  in
  box_top buf cols;
  box_line_styled buf cols ~style:Ansi.bold header;
  box_divider buf cols;
  let dropped =
    if state.acting_dropped = 0 then ""
    else Printf.sprintf "  dropped %d" state.acting_dropped
  in
  let undecodable =
    match state.acting_undecodable_last with
    | None -> ""
    | Some reason ->
        Printf.sprintf "  undecodable %d (last: %s)" state.acting_undecodable
          (Terminal_text.single_line reason)
  in
  let unseen =
    if state.acting_unseen = 0 then ""
    else Printf.sprintf "  %d new above (g)" state.acting_unseen
  in
  box_line_styled buf cols ~style:Ansi.dim
    (Printf.sprintf "  %s%s%s%s" feed dropped undecodable unseen);
  box_divider buf cols;
  let col_hdr =
    Printf.sprintf "  %-8s %-16s %s %-16s %s" "Time" "Keeper" " " "Event"
      "Detail"
  in
  box_line_styled buf cols ~style:Ansi.dim col_hdr;
  box_divider buf cols;
  (* The page indicator has a row of its own whether or not it is drawn, so a
     list that overflows does not push the help line off the bottom. *)
  let chrome_rows = 10 in
  let content_height = max 1 (rows - chrome_rows) in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.acting_scroll max_scroll) in
  if shown = 0 then begin
    let empty =
      match state.observer with
      | Observer_off | Observer_opening -> "  (no events yet: the feed is not open)"
      | Observer_live _ ->
          if held = 0 then "  (no events yet)"
          else "  (nothing under this filter; f shows everything)"
      | Observer_closed _ ->
          if held = 0 then "  (the feed closed before any event arrived)"
          else "  (nothing under this filter; f shows everything)"
    in
    box_line_styled buf cols ~style:Ansi.dim empty;
    for _ = 1 to content_height - 1 do
      box_empty buf cols
    done
  end
  else
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match Option.map row_of (List.nth_opt visible idx) with
      | None -> box_empty buf cols
      | Some row ->
          let style =
            match row.Acting.glyph with
            | Acting.Call_started -> Ansi.cyan
            | Acting.Call_returned -> Theme.ok
            | Acting.Turn_boundary -> Ansi.reset
            | Acting.Turn_settled -> Ansi.bold
            | Acting.Failure -> Theme.bad
            | Acting.Attention -> Theme.warn
            | Acting.Quiet -> Ansi.dim
          in
          let clock =
            if row.Acting.at <= 0. then "--:--:--"
            else
              Terminal_text.clock_timestamp
                (Masc_domain.iso8601_of_unix_seconds row.Acting.at)
          in
          let line =
            Printf.sprintf "  %-8s %-16s %s %-16s %s" clock
              (fit_width (Terminal_text.single_line row.Acting.keeper) 16)
              (Acting.glyph_text row.Acting.glyph)
              (fit_width (Terminal_text.single_line row.Acting.label) 16)
              (Terminal_text.single_line row.Acting.detail)
          in
          box_line_styled buf cols ~style line
    done;
  if shown > content_height then
    box_line_styled buf cols ~style:Ansi.dim
      (Printf.sprintf "[%d rows, scroll %d]" shown scroll)
  else box_empty buf cols;
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~hints:"j/k:scroll  g:newest  G:oldest  f:filter  Tab:next  q:quit");
  finish_surface state ~clamped:(Acting scroll) ~surface_key:"acting" ~rows:terminal_rows ~cols buf

(** Render the runtime picker: the dispatchable catalogue, with the keeper it
    is choosing for and where that keeper points today in the header. *)
let render_runtime_pick (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let keeper_name =
    Terminal_text.single_line_or ~default:"?" state.runtime_pick_keeper
  in
  let current =
    match
      List.find_opt
        (fun (a : Tui_decode.runtime_assignment) ->
          match state.runtime_pick_keeper with
          | Some keeper -> String.equal a.ra_keeper keeper
          | None -> false)
        state.runtime_assignments
    with
    | Some a ->
        Printf.sprintf "%s (%s)"
          (Terminal_text.single_line_or ~default:"-" a.ra_target_id)
          (Terminal_text.single_line a.ra_source)
    | None -> "-"
  in
  (* Only what a keeper can actually be pointed at. The catalogue also lists
     rows the dispatcher refuses; offering one would end in the server's
     rejection, so the picker does not draw them. *)
  let options =
    List.filter
      (fun (o : Tui_decode.runtime_option) -> o.ro_dispatchable)
      state.runtime_catalog
  in
  let count = List.length options in
  box_top buf cols;
  box_line buf cols
    (Printf.sprintf "%s  %scurrent: %s%s"
       (screen_title
         (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 runtime" keeper_name))
       Ansi.dim current Ansi.reset);
  box_divider buf cols;
  (match Terminal_text.optional_single_line state.runtime_catalog_error with
   | Some err ->
       box_line buf cols
         (Theme.bad ^ "  (catalogue unreliable: "
         ^ fit_width err (max 8 (cols - 28))
         ^ ")" ^ Ansi.reset)
   | None ->
       if count = 0 then
         box_line buf cols
           (Ansi.dim ^ "  (loading runtime catalogue\xe2\x80\xa6)" ^ Ansi.reset));
  let content_height = max 0 (rows - 7) in
  let scroll_offset =
    if content_height > 0 && state.runtime_pick_cursor >= content_height then
      state.runtime_pick_cursor - content_height + 1
    else 0
  in
  for i = 0 to content_height - 1 do
    let idx = i + scroll_offset in
    match List.nth_opt options idx with
    | Some option ->
        let is_selected = idx = state.runtime_pick_cursor in
        let line =
          Printf.sprintf "  %s  %s%s"
            (fit_width (Terminal_text.single_line option.ro_id) 44)
            (fit_width
               (Terminal_text.single_line
                  (option.ro_provider ^ " / " ^ option.ro_model))
               (max 8 (cols - 56)))
            (if option.ro_is_default then " [default]" else "")
        in
        box_line buf cols
          (if is_selected then Ansi.reverse ^ ">" ^ Ansi.reset ^ " " ^ line
           else "  " ^ line)
    | None -> box_empty buf cols
  done;
  box_bottom buf cols;
  Buffer.add_string buf
    (Printf.sprintf
       "  %sj/k%s move  %senter%s assign  %sd%s back to default  %sesc%s \
        cancel\n"
       Ansi.cyan Ansi.reset Ansi.cyan Ansi.reset Ansi.cyan Ansi.reset Ansi.dim
       Ansi.reset);
  finish_surface state ~surface_key:"runtime-pick" ~rows:terminal_rows ~cols
    buf

(* The Resources surface: the MCP resource inventory on the left, the
   selected read on the right. Wide terminals show both; narrow ones show
   the list, and Enter swaps to the content until Esc. *)
let render_resources (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  let split = cols >= keeper_split_threshold_cols in
  let list_rows_budget = max 1 (rows - 5) in
  let rows_list =
    match state.resources_list with Some rows -> rows | None -> []
  in
  let total = List.length rows_list in
  let cursor = max 0 (min state.resources_cursor (total - 1)) in
  let list_pane pane_buf pane_cols =
    framed_top pane_buf pane_cols;
    framed_line pane_buf pane_cols
      (Ansi.bold ^ " Resources"
       ^ (if total = 0 then "" else Printf.sprintf " (%d)" total)
       ^ Ansi.reset);
    framed_divider pane_buf pane_cols;
    (* The status line spends one of the budgeted rows, not an extra one:
       an extra row pushed the pane past its height and the frame's last
       casualty was the footer. *)
    let status_rows =
      match state.resources_error with
      | Some detail ->
          framed_line pane_buf pane_cols
            (Theme.bad ^ " " ^ Terminal_text.single_line detail ^ Ansi.reset);
          1
      | None ->
          if total = 0 then begin
            framed_line pane_buf pane_cols
              (Ansi.dim ^ " (loading\xe2\x80\xa6)" ^ Ansi.reset);
            1
          end
          else 0
    in
    let list_rows_budget = max 0 (list_rows_budget - status_rows) in
    let first =
      if cursor < list_rows_budget then 0 else cursor - list_rows_budget + 1
    in
    for i = 0 to list_rows_budget - 1 do
      match List.nth_opt rows_list (first + i) with
      | Some (_, name) ->
          let selected = first + i = cursor in
          let line =
            if selected then
              Theme.selection ^ " " ^ name
              ^ String.make
                  (max 0
                     (pane_cols - 5 - Message_layout.display_width name))
                  ' '
              ^ Ansi.reset
            else " " ^ name
          in
          framed_line pane_buf pane_cols line
      | None -> framed_empty pane_buf pane_cols
    done;
    framed_bottom pane_buf pane_cols
  in
  let content_pane pane_buf pane_cols =
    let title =
      match state.resource_content with
      | Some (uri, _) -> Terminal_text.single_line uri
      | None -> "(Enter reads the selected resource)"
    in
    box_top pane_buf pane_cols;
    box_line pane_buf pane_cols (Ansi.bold ^ " " ^ title ^ Ansi.reset);
    box_divider pane_buf pane_cols;
    let content_height = max 1 (rows - 5) in
    (match state.resource_content_error, state.resource_content with
     | Some detail, _ ->
         box_line pane_buf pane_cols
           (Theme.bad ^ "  " ^ Terminal_text.single_line detail ^ Ansi.reset);
         for _ = 2 to content_height do
           box_empty pane_buf pane_cols
         done
     | None, None ->
         for _ = 1 to content_height do
           box_empty pane_buf pane_cols
         done
     | None, Some (_, lines) ->
         let total_lines = List.length lines in
         let max_scroll = max 0 (total_lines - content_height) in
         let scroll = max 0 (min state.resource_scroll max_scroll) in
         for i = 0 to content_height - 1 do
           match List.nth_opt lines (scroll + i) with
           | Some line -> box_line pane_buf pane_cols ("  " ^ line)
           | None -> box_empty pane_buf pane_cols
         done);
    box_bottom pane_buf pane_cols
  in
  (if split then begin
     let left_cols = keeper_roster_pane_cols in
     let right_cols = cols - left_cols in
     let left_buf = Buffer.create 1024 in
     let right_buf = Buffer.create 4096 in
     list_pane left_buf left_cols;
     content_pane right_buf right_cols;
     let blank_left = String.make left_cols ' ' in
     let rec zip left right =
       match left, right with
       | [], [] -> []
       | l :: lt, r :: rt -> (l ^ r) :: zip lt rt
       | [], r :: rt -> (blank_left ^ r) :: zip [] rt
       | l :: lt, [] -> l :: zip lt []
     in
     List.iter
       (fun line ->
         Buffer.add_string buf line;
         Buffer.add_char buf '\n')
       (zip (frame_lines left_buf) (frame_lines right_buf))
   end
   else if state.resource_focus then content_pane buf cols
   else list_pane buf cols);
  Buffer.add_string buf
    (footer_line state
       ~hints:"j/k:move  J/K:scroll text  Enter:read  Esc:list  r:reload  Tab:next");
  finish_surface state ~surface_key:"resources" ~rows:terminal_rows ~cols buf

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

(* The Config surface: runtime.toml exactly as the server reads it. The
   text is the truth an editor session starts from; editing itself hands
   the terminal to $EDITOR and posts back through the preview gate. *)
let render_config (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  box_top buf cols;
  let path_note =
    match state.runtime_config_view with
    | Some (path, _) -> Ansi.dim ^ path ^ Ansi.reset
    | None -> Ansi.dim ^ "(not loaded)" ^ Ansi.reset
  in
  box_line buf cols
    (Printf.sprintf "%s  %s  %s  %s" (screen_title " MASC Config") path_note
       (Printf.sprintf "%s%s%s" Ansi.dim
          (let now = Unix.localtime (Unix.gettimeofday ()) in
           Printf.sprintf "%02d:%02d:%02d" now.Unix.tm_hour now.Unix.tm_min
             now.Unix.tm_sec)
          Ansi.reset)
       (connection_badge state.connection_status));
  (* Where this server reads from, and how old the binary serving it is. A
     stale binary answers every request as confidently as a current one, so
     the age is the only thing on screen that separates them. *)
  (match state.server_identity with
   | None -> box_line buf cols (Ansi.dim ^ "  (server identity unread)" ^ Ansi.reset)
   | Some identity ->
       box_line buf cols
         (Printf.sprintf "%s  base %s   masc %s   binary %s%s" Ansi.dim
            (fit_width identity.Tui_decode.sid_base_path 28)
            (fit_width identity.Tui_decode.sid_masc_root 32)
            (binary_age_text identity.Tui_decode.sid_binary_commit_age_s)
            Ansi.reset));
  box_divider buf cols;
  let content_height = max 1 (rows - 7) in
  (match state.runtime_config_view_error, state.runtime_config_view with
   | Some detail, _ ->
       box_line buf cols (Theme.bad ^ "  " ^ Keeper_chat.terminal_safe_text detail ^ Ansi.reset);
       for _ = 2 to content_height do
         box_empty buf cols
       done
   | None, None ->
       box_line buf cols (Ansi.dim ^ "  (loading\xe2\x80\xa6)" ^ Ansi.reset);
       for _ = 2 to content_height do
         box_empty buf cols
       done
   | None, Some (_, lines) ->
       let total = List.length lines in
       let max_scroll = max 0 (total - content_height) in
       let scroll = max 0 (min state.config_scroll max_scroll) in
       for i = 0 to content_height - 1 do
         match List.nth_opt lines (scroll + i) with
         | Some line ->
             box_line buf cols
               (Printf.sprintf "%s%4d%s  %s" Ansi.dim (scroll + i + 1)
                  Ansi.reset line)
         | None -> box_empty buf cols
       done);
  box_bottom buf cols;
  Buffer.add_string buf
    (footer_line state
       ~hints:"j/k:scroll  e:edit (preview-checked)  r:reload  Tab:next");
  finish_surface state ~surface_key:"config" ~rows:terminal_rows ~cols buf

let render_surface (state : state) =
  match state.view with
  | Overview ->
      (* Same fallback shape as Board/Planning detail: a detail id whose row
         left the backlog renders the list, not a frame for a missing task. *)
      (match state.task_detail_id with
       | Some _ -> (
           match
             Task_selection.detail_row
               ~detail_id:state.task_detail_id
               ~tasks:state.tasks_domain
           with
           | Some task -> render_task_detail state task
           | None -> render_overview state )
       | None -> render_overview state)
  | Keepers Keeper_list -> render_keeper_list state
  | Keepers Keeper_detail -> render_keeper_detail state
  | Keepers Keeper_logs -> render_keeper_logs state
  | Keepers Keeper_calls -> render_keeper_calls state
  | Keepers Keeper_message -> render_keeper_message state
  | Keepers Keeper_runtime_pick -> render_runtime_pick state
  | Lanes -> render_lanes state
  | Board ->
      (match state.board_mode with
       | Board_list -> render_board_list state
       | Board_compose -> render_board_compose state
       | Board_read post_id ->
           match List.find_opt (fun p -> p.bp_id = post_id) state.board_posts with
           | Some post -> render_board_read state post
           | None -> render_board_list state)
  | Planning ->
      (match state.planning_mode with
       | Planning_list -> render_planning_list state
       | Planning_detail goal_id ->
           let goals = match state.planning with None -> [] | Some p -> p.pl_goals in
           match List.find_opt (fun g -> g.pg_id = goal_id) goals with
           | Some goal ->
               render_planning_detail state
                 ~armed:(goal_action_armed_for state goal_id) goal
           | None -> render_planning_list state)
  | Approvals -> render_approvals state
  | Verification -> render_verification state
  | Harness -> render_harness state
  | Fusion ->
      (match state.fusion_mode with
       | Fusion_list -> render_fusion_list state
       | Fusion_detail run_id -> render_fusion_detail state run_id)
  | Repositories -> render_repositories state
  | Changes -> render_changes state
  | Connectors -> render_connectors state
  | Runtime -> render_runtime state
  | Config -> render_config state
  | Resources -> render_resources state
  | Tools -> render_tools state
  | Acting -> render_acting state
  | System_logs -> render_system_logs state
  | Schedules -> render_schedules state

(* The [?] help screen: every binding, grouped by the surface that answers
   it. The rows come from Masc_tui_keys -- the same table the footers read --
   so the two displays cannot drift apart. A key added to the dispatch gets
   its row there, once. *)
let help_sections : (string * (string * string) list) list =
  Masc_tui_keys.help_sections ()

let help_lines () =
  help_sections
  |> List.concat_map (fun (title, entries) ->
       (Ansi.bold ^ title ^ Ansi.reset)
       :: List.map
            (fun (key, action) ->
              Printf.sprintf
                "  %s%-18s%s %s"
                Ansi.cyan
                key
                Ansi.reset
                action)
            entries
       @ [ "" ])

(* What the help overlay can show right now: the rows its sheet folds to at
   this width, and the height it draws them in. The key handler bounds its
   step against this, so a press that the frame cannot spend is not taken. *)
let help_viewport () =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  ( List.length (Masc_tui_help.sheet ~cols (help_lines ()))
  , Masc_tui_help.content_height ~rows )

(* The [:] palette: a typed filter over every jump the strip and roster
   offer. The list is the same [palette_matches] the Enter key resolves, so
   what is highlighted is what will run. *)
let render_palette (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 2048 in
  let matches = Masc_tui_types.palette_matches state in
  let total = List.length matches in
  let cursor = max 0 (min state.palette_cursor (total - 1)) in
  framed_top buf cols;
  framed_line buf cols
    (Printf.sprintf "%s:%s %s%s" Ansi.bold Ansi.reset
       (Terminal_text.single_line state.palette_query)
       (Ansi.cyan ^ "\xe2\x96\x8c" ^ Ansi.reset));
  framed_divider buf cols;
  let content_height = max 1 (rows - 5) in
  let first =
    if cursor < content_height then 0
    else cursor - content_height + 1
  in
  matches
  |> List.filteri (fun i _ -> i >= first && i < first + content_height)
  |> List.iteri (fun visible_index (label, _) ->
       let selected = first + visible_index = cursor in
       let line =
         if selected then
           Theme.selection ^ " " ^ label
           ^ String.make
               (max 0 (cols - 5 - Message_layout.display_width label))
               ' '
           ^ Ansi.reset
         else " " ^ label
       in
       framed_line buf cols line);
  if total = 0 then
    framed_line buf cols (Ansi.dim ^ "  (no match)" ^ Ansi.reset);
  framed_bottom buf cols;
  Buffer.add_string buf
    (footer_line state
       ~hints:
         (Printf.sprintf "%d/%d  Enter:jump  Esc:close"
            (if total = 0 then 0 else cursor + 1)
            total));
  finish_surface state ~surface_key:"palette" ~rows:terminal_rows ~cols buf

let render_help (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  let buf = Buffer.create 4096 in
  framed_top buf cols;
  framed_line buf cols (screen_title " Help" ^ "  " ^ Ansi.dim
    ^ "Esc or ? to close" ^ Ansi.reset);
  framed_divider buf cols;
  let lines = help_lines () in
  let rendered_rows = Masc_tui_help.sheet ~cols lines in
  let content_height = Masc_tui_help.content_height ~rows in
  let scroll =
    Masc_tui_scroll.normalize
      ~count:(List.length rendered_rows) ~height:content_height state.help_scroll
  in
  rendered_rows
  |> List.filteri (fun i _ -> i >= scroll && i < scroll + content_height)
  |> List.iter (fun line -> framed_line buf cols line);
  framed_bottom buf cols;
  Buffer.add_string buf
    (footer_line state ~hints:"j/k:scroll  Esc:close");
  finish_surface state ~surface_key:"help" ~rows:terminal_rows ~cols buf

let render_terminal_too_small ~rows ~cols =
  let buf = Buffer.create 64 in
  Buffer.add_string buf
    (fit_width
       (Printf.sprintf "terminal too small -- resize to at least %d rows; q: quit"
          Render_schedule.Viewport.minimum_fixed_chrome_rows)
       cols);
  Buffer.add_char buf '\n';
  finish_frame ~surface_key:"terminal-too-small"
    ~cursor:Frame_presenter.Hidden ~rows ~cols buf

(** Keep every high-chrome surface out of a viewport that cannot contain the
    largest declared fixed-row budget. Main ignores hidden surface input, and
    growing the terminal restores the unchanged selected surface. *)
let render (state : state) =
  let terminal_rows, cols = get_terminal_size () in
  (* The composer owns the terminal's last row; everything this surface
     lays out fits above it. *)
  let rows = max 1 (terminal_rows - Composer.rows_for ~terminal_rows) in
  if Render_schedule.Viewport.requires_compact_frame ~rows
  then render_terminal_too_small ~rows ~cols
  else if state.palette_open then render_palette state
  else if state.help_open then render_help state
  else render_surface state
