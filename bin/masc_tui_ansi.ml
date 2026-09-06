(** ANSI escape codes and terminal helpers — split from masc_tui.ml (#3808) *)

(** ANSI escape codes.

    The strings themselves live in [Masc_tui_theme] — a pure, test-linkable
    library — and this module re-exports them under the names the renderer
    has always used. The contracts (NO_COLOR keeps [reset] and [reverse];
    [default_fg] leaves bold and dim alone) are documented there. *)
module Ansi = struct
  let clear = Masc_tui_theme.Term.clear
  let hide_cursor = Masc_tui_theme.Term.hide_cursor
  let show_cursor = Masc_tui_theme.Term.show_cursor

  let colors_enabled = Masc_tui_theme.colors_enabled
  let style = Masc_tui_theme.style

  let reset = Masc_tui_theme.Sgr.reset
  let bold = Masc_tui_theme.Sgr.bold
  let dim = Masc_tui_theme.Sgr.dim
  let underline = Masc_tui_theme.Sgr.underline
  let no_underline = Masc_tui_theme.Sgr.no_underline
  let italic = Masc_tui_theme.Sgr.italic
  let no_italic = Masc_tui_theme.Sgr.no_italic
  let strike = Masc_tui_theme.Sgr.strike
  let no_strike = Masc_tui_theme.Sgr.no_strike

  let red = Masc_tui_theme.Sgr.red
  let green = Masc_tui_theme.Sgr.green
  let yellow = Masc_tui_theme.Sgr.yellow
  let blue = Masc_tui_theme.Sgr.blue
  let magenta = Masc_tui_theme.Sgr.magenta
  let cyan = Masc_tui_theme.Sgr.cyan
  let white = Masc_tui_theme.Sgr.white

  let default_fg = Masc_tui_theme.Sgr.default_fg
  let gray = Masc_tui_theme.Sgr.gray
  let bright_red = Masc_tui_theme.Sgr.bright_red
  let bright_green = Masc_tui_theme.Sgr.bright_green
  let bright_yellow = Masc_tui_theme.Sgr.bright_yellow
  let bright_blue = Masc_tui_theme.Sgr.bright_blue
  let bright_magenta = Masc_tui_theme.Sgr.bright_magenta
  let bright_cyan = Masc_tui_theme.Sgr.bright_cyan

  let move_to = Masc_tui_theme.Term.move_to
  let reverse = Masc_tui_theme.Sgr.reverse

  let box_h = Masc_tui_theme.Box.h
  let box_v = Masc_tui_theme.Box.v
  let box_tl = Masc_tui_theme.Box.tl
  let box_tr = Masc_tui_theme.Box.tr
  let box_bl = Masc_tui_theme.Box.bl
  let box_br = Masc_tui_theme.Box.br
  let box_l = Masc_tui_theme.Box.l
  let box_r = Masc_tui_theme.Box.r
end

(** Semantic styles for state and content syntax.

    A fact about health, phase, or attention draws through these names, so
    one remap -- a theme, a colourblind palette -- moves every reading at
    once. The boundary: state goes through the top-level names; syntax colours
    stay under [Syntax], because "this word is green" is content (a diff or a
    code literal) rather than a reading of state. Renderers do not choose raw
    red, yellow, or green themselves. *)
module Theme = struct
  (* Resolved against the terminal's own palette, so a colour the reader's
     theme leaves unreadable is lifted rather than drawn and lost. The palette
     arrives after start-up from the OSC answers and can arrive again; the
     generation says which. Rebuilt only when that changes, because these are
     read once per drawn row. *)
  type resolved =
    { generation : int
    ; ok : string
    ; warn : string
    ; bad : string
    ; info : string
    ; muted : string
    ; user : string
    ; inbound : string
    ; keeper : string
    ; tool : string
    ; quiet : string
    ; probe : string
    ; message : string
    (* Six slots for an axis whose members are kinds, not degrees. A file
       type, a goal phase, a sandbox: nothing in such a set outranks its
       siblings and the reader's only job is to tell them apart, which is
       neither what [ok]/[warn]/[bad] say nor what [tone] says. Without
       them a surface reaches past the theme for a colour name, and a
       constant SGR does not move when the terminal palette answers -- so
       the rows saying "kind" were the ones a theme could not reach.

       Numbered, not named. Two axes never on the same screen can hold the
       same slot, and a global kind-to-colour map runs out of colours.

       Five, not six, and none of them is free of status. The theme names
       seven ANSI colours and [status_ansi_color] already claims five --
       green, yellow, red, cyan and the receding black -- so a slot is the
       same bytes as some status token by construction. Red is the one
       nobody can use: it is [bad], and it turned a media file's mark into
       the failure text sharing its terminal row. Blue and magenta are the
       only hues status leaves alone; a surface reaching for any of the
       other three owes a check that it does not draw that status token.
       RFC-0427. *)
    ; slot_1 : string
    ; slot_2 : string
    ; slot_3 : string
    ; slot_4 : string
    ; slot_5 : string
    }

  (* A slot, so the accessor below is total. *)
  type category =
    | Slot_1
    | Slot_2
    | Slot_3
    | Slot_4
    | Slot_5

  (* One place says which hue a slot carries, so the contrast suite measures
     the mapping the renderer actually draws instead of a copy of it. *)
  let category_colour = function
    | Slot_1 -> Masc_tui_theme.Bright_cyan
    | Slot_2 -> Masc_tui_theme.Bright_yellow
    | Slot_3 -> Masc_tui_theme.Bright_green
    | Slot_4 -> Masc_tui_theme.Bright_magenta
    | Slot_5 -> Masc_tui_theme.Bright_blue

  let all_categories = [ Slot_1; Slot_2; Slot_3; Slot_4; Slot_5 ]

  let resolved_cache : resolved option Atomic.t = Atomic.make None

  let rec resolved () =
    let probed = Masc_tui_terminal_palette.snapshot () in
    let generation = Masc_tui_terminal_palette.snapshot_generation probed in
    let previous = Atomic.get resolved_cache in
    match previous with
    | Some cached when cached.generation = generation -> cached
    | Some _ | None ->
      let palette = Masc_tui_terminal_palette.snapshot_palette probed in
      let of_state = Masc_tui_theme.status_readable palette in
      let of_colour = Masc_tui_theme.ansi_readable palette in
      let next =
        { generation
        ; ok = of_state Masc_tui_theme.Ok
        ; warn = of_state Masc_tui_theme.Warn
        ; bad = of_state Masc_tui_theme.Bad
        ; info = of_state Masc_tui_theme.Info
        ; muted = of_state Masc_tui_theme.Muted
        ; user = of_colour Masc_tui_theme.Bright_cyan
        (* Green against the operator's cyan: two lines addressed to the same
           Keeper, and the pane has to say which of them the reader wrote.
           Not a status colour -- a broadcast is neither good news nor bad. *)
        ; inbound = of_colour Masc_tui_theme.Bright_green
        ; keeper = of_colour Masc_tui_theme.Bright_blue
        ; tool = of_colour Masc_tui_theme.Bright_magenta
        ; quiet = of_colour Masc_tui_theme.Bright_black
        ; probe = of_colour Masc_tui_theme.Bright_cyan
        ; message = of_colour Masc_tui_theme.Bright_magenta
        (* Every hue but the receding one and [bad]'s red. *)
        ; slot_1 = of_colour (category_colour Slot_1)
        ; slot_2 = of_colour (category_colour Slot_2)
        ; slot_3 = of_colour (category_colour Slot_3)
        ; slot_4 = of_colour (category_colour Slot_4)
        ; slot_5 = of_colour (category_colour Slot_5)
        }
      in
      if Atomic.compare_and_set resolved_cache previous (Some next) then next
      else resolved ()
  ;;

  (* Which slot a surface gives to which member is the surface's own
     business; this only promises the six are distinct and that all six
     move when the palette does. *)
  let category = function
    | Slot_1 -> (resolved ()).slot_1
    | Slot_2 -> (resolved ()).slot_2
    | Slot_3 -> (resolved ()).slot_3
    | Slot_4 -> (resolved ()).slot_4
    | Slot_5 -> (resolved ()).slot_5

  let ok () = (resolved ()).ok
  let warn () = (resolved ()).warn
  let bad () = (resolved ()).bad
  let info () = (resolved ()).info
  let muted () = (resolved ()).muted

  (* Who is speaking is a reading too, so the role colours draw through the
     same path as the state ones. Measured on the twelve schemes, they need it
     as much: the Keeper's blue reads at 2.26:1 on default-light and the tool
     trail's bright black at 1.69:1 on Nord, which is the row an operator
     scans to see what a keeper just did. *)
  let user_origin () = (resolved ()).user
  let inbound_origin () = (resolved ()).inbound
  let keeper_origin () = (resolved ()).keeper
  let tool_origin () = (resolved ()).tool
  let quiet_origin () = (resolved ()).quiet

  (* The two next-action colours that are not a health reading. A keeper about
     to be probed is not unwell, and one a person just spoke to is not well --
     they say which kind of thing is about to happen, so they draw through
     their own names rather than borrowing [ok] and [bad]. *)
  let action_probe () = (resolved ()).probe
  let action_message () = (resolved ()).message
  let selection = Masc_tui_theme.selection
  let border_focus = Masc_tui_theme.border_focus

  (* A row drawn behind the ones around it.

     Not a synonym for [Ansi.dim]. SGR 2 modifies whatever colour is already
     open -- dim red stays red -- so it is the right thing where a coloured
     run needs to be quieter. This replaces the colour outright, which is only
     what a row wants when the whole row is the quiet thing. Those are
     different jobs and both remain.

     The palette arrives after start-up, from the terminal's answer to the
     OSC query, and can arrive again; the generation is what says which. The
     escape is rebuilt only when it changes, because this is read once per
     drawn row. *)
  let recede_cache : (int * string) option Atomic.t = Atomic.make None

  let rec recede () =
    (* Named for what it holds rather than [snapshot]: an AST guard counts the
       palette reads inside the binding [Chat_theme.snapshot], and a local of
       that name here joins its count. *)
    let probed = Masc_tui_terminal_palette.snapshot () in
    let generation = Masc_tui_terminal_palette.snapshot_generation probed in
    let previous = Atomic.get recede_cache in
    match previous with
    | Some (cached_generation, style) when cached_generation = generation ->
      style
    | Some _ | None ->
      let style =
        Masc_tui_theme.recede
          ~theme_mode:(Masc_tui_terminal_palette.snapshot_theme_mode probed)
          (Masc_tui_terminal_palette.snapshot_palette probed)
      in
      if Atomic.compare_and_set recede_cache previous
           (Some (generation, style))
      then style
      else recede ()
  ;;

  (* The Activity pane's ground, rebuilt only when the palette changes, for
     the same reason [recede] is: it is read once per drawn pane row. *)
  let side_pane_background_cache : (int * string) option Atomic.t =
    Atomic.make None

  let rec side_pane_background () =
    let probed = Masc_tui_terminal_palette.snapshot () in
    let generation = Masc_tui_terminal_palette.snapshot_generation probed in
    let previous = Atomic.get side_pane_background_cache in
    match previous with
    | Some (cached_generation, style) when cached_generation = generation ->
      style
    | Some _ | None ->
      let style =
        Masc_tui_theme.side_pane_background
          (Masc_tui_terminal_palette.snapshot_palette probed)
      in
      if Atomic.compare_and_set side_pane_background_cache previous
           (Some (generation, style))
      then style
      else side_pane_background ()
  ;;

  module Syntax = struct
    let keyword = Masc_tui_theme.Syntax.keyword
    let string = Masc_tui_theme.Syntax.string_
    let code_comment = Masc_tui_theme.Syntax.code_comment
    let code_number = Masc_tui_theme.Syntax.code_number
    let code_type = Masc_tui_theme.Syntax.code_type
    let code_span = Masc_tui_theme.Syntax.code_span
    let link = Masc_tui_theme.Syntax.link
    let rule = Masc_tui_theme.Syntax.rule
    let json_key = Masc_tui_theme.Syntax.json_key
    let json_number = Masc_tui_theme.Syntax.json_number
    let json_literal = Masc_tui_theme.Syntax.json_literal
    let json_punctuation = Masc_tui_theme.Syntax.json_punctuation
    let diff_added = Masc_tui_theme.Syntax.diff_added
    let diff_removed = Masc_tui_theme.Syntax.diff_removed
    let diff_added_bg = Masc_tui_theme.Syntax.diff_added_bg
    let diff_removed_bg = Masc_tui_theme.Syntax.diff_removed_bg
    let diff_row_foreground = Masc_tui_theme.Syntax.diff_row_foreground
  end
end

(** One owner for the visual distinction between conversation roles.

    Role and state are different axes: a Keeper message is not a success, and
    a user message is not merely informational. The renderer asks this module
    for its badge/gutter and body styles instead of rebuilding that mapping.
    Both human and Keeper prose deliberately keep the terminal's foreground. *)
module Chat_theme = struct
  type snapshot =
    { palette_generation : int
    ; user_background : string
    }

  type body_context =
    { opening : string
    ; markdown_close : string
    (* Full reset and reopen for the folded-origin gutter, whose own spans can
       change weight, foreground, and background. *)
    ; inline_restore : string
    (* A bare link changes only underline and foreground. Closing only those
       two attributes preserves an enclosing diff background and any weight. *)
    ; link_restore : string
    ; palette_generation : int
    ; ambient_background : bool
    }

  let origin : Masc_tui_message_layout.style -> string = function
    | Masc_tui_message_layout.User -> Theme.user_origin ()
    | Masc_tui_message_layout.Inbound -> Theme.inbound_origin ()
    | Masc_tui_message_layout.Keeper -> Theme.keeper_origin ()
    | Masc_tui_message_layout.Status -> Theme.warn ()
    (* Quiet, not warn. The pane answering a command is reference, and drawing
       twenty lines of it in the colour reserved for a turn needing attention
       is what made [/help] read as an alarm. *)
    | Masc_tui_message_layout.Local -> Theme.quiet_origin ()
    | Masc_tui_message_layout.Journal -> Theme.info ()
    | Masc_tui_message_layout.Error -> Theme.bad ()
    | Masc_tui_message_layout.Tool -> Theme.tool_origin ()
    | Masc_tui_message_layout.Skill Masc_tui_message_layout.Skill_live ->
      Theme.info ()
    | Masc_tui_message_layout.Skill Masc_tui_message_layout.Skill_used ->
      Theme.ok ()
    | Masc_tui_message_layout.Skill Masc_tui_message_layout.Skill_attention ->
      Theme.warn ()
    | Masc_tui_message_layout.Skill Masc_tui_message_layout.Skill_failure ->
      Theme.bad ()
    | Masc_tui_message_layout.Thinking -> Theme.quiet_origin ()

  let body : Masc_tui_message_layout.style -> string = function
    | Masc_tui_message_layout.User | Masc_tui_message_layout.Inbound
    | Masc_tui_message_layout.Keeper -> Ansi.reset
    | Masc_tui_message_layout.Status -> Theme.warn ()
    (* The badge is quiet; the body is not dimmed. A command list is read. *)
    | Masc_tui_message_layout.Local -> Ansi.reset
    | Masc_tui_message_layout.Journal -> Ansi.reset
    | Masc_tui_message_layout.Error -> Theme.bad ()
    | Masc_tui_message_layout.Tool -> Ansi.reset
    | Masc_tui_message_layout.Skill skill ->
      origin (Masc_tui_message_layout.Skill skill)
    | Masc_tui_message_layout.Thinking -> Ansi.dim

  let link_foreground : Masc_tui_message_layout.style -> string = function
    | Masc_tui_message_layout.Status -> Theme.warn ()
    | Masc_tui_message_layout.Error -> Theme.bad ()
    | Masc_tui_message_layout.User | Masc_tui_message_layout.Inbound
    | Masc_tui_message_layout.Keeper | Masc_tui_message_layout.Tool
    | Masc_tui_message_layout.Local | Masc_tui_message_layout.Journal
    | Masc_tui_message_layout.Skill _ | Masc_tui_message_layout.Thinking ->
      Ansi.default_fg

  let link_style_restore style =
    Ansi.no_underline ^ link_foreground style

  let snapshot_cache : snapshot option Atomic.t = Atomic.make None

  let rec snapshot () =
    let palette_snapshot = Masc_tui_terminal_palette.snapshot () in
    let palette_generation =
      Masc_tui_terminal_palette.snapshot_generation palette_snapshot
    in
    let previous = Atomic.get snapshot_cache in
    match previous with
    | Some snapshot when snapshot.palette_generation = palette_generation ->
      snapshot
    | Some _ | None ->
      let next =
        { palette_generation
        ; user_background =
            Masc_tui_theme.user_message_background
              (Masc_tui_terminal_palette.snapshot_palette palette_snapshot)
        }
      in
      if Atomic.compare_and_set snapshot_cache previous (Some next) then next
      else snapshot ()
  ;;

  let body_context snapshot style =
    let opening = body style in
    let link_restore = link_style_restore style in
    match style, snapshot.user_background with
    | Masc_tui_message_layout.User, background
      when String.length background > 0 ->
      let ambient = Ansi.reset ^ background in
      { opening = ambient
      ; markdown_close = ambient
      ; inline_restore = ambient
      ; link_restore
      ; palette_generation = snapshot.palette_generation
      ; ambient_background = true
      }
    | Masc_tui_message_layout.User, _ ->
      { opening
      ; markdown_close = Ansi.reset
      ; inline_restore = Ansi.reset ^ opening
      ; link_restore
      ; palette_generation = snapshot.palette_generation
      ; ambient_background = false
      }
    (* The ambient background is the reader's own voice on the page, so it
       belongs to {!User} alone. An inbound line is prose like a Keeper's and
       takes the plain ground; its mark and colour say where it came from. *)
    | ( Masc_tui_message_layout.Inbound
      | Masc_tui_message_layout.Keeper
      | Masc_tui_message_layout.Status
      | Masc_tui_message_layout.Local
      | Masc_tui_message_layout.Journal
      | Masc_tui_message_layout.Error
      | Masc_tui_message_layout.Tool
      | Masc_tui_message_layout.Skill _
      | Masc_tui_message_layout.Thinking ), _ ->
      { opening
      ; markdown_close = Ansi.reset
      ; inline_restore = Ansi.reset ^ opening
      ; link_restore
      ; palette_generation = 0
      ; ambient_background = false
      }
end

(** A screen title.

    Emphasis belongs to the words that name the screen, not to the whole header
    line. Headers interpolate coloured badges, and the reset that closes a badge
    also closes any style wrapped around the line, so styling the line bolded a
    different amount of text on every screen -- as far as its first badge, which
    sits in a different place each time. Eight screens wrapped the line and eight
    drew it plain, and the four styles that came out of that were not a
    decision. *)
let screen_title text = Ansi.bold ^ text ^ Ansi.reset

(** Keep the last valid shape in the shared cache, but re-probe once per
    input/render loop. The probe is a direct ioctl now, so this does not spawn
    a process, and terminals that omit or coalesce SIGWINCH cannot leave layout
    geometry stuck at the startup size. A transient probe failure reuses that
    last valid shape; the fallback is used only before the first valid probe. *)
let terminal_size_cache =
  Masc_tui_render_schedule.Terminal_size_cache.create ~fallback:(24, 80)

let invalidate_terminal_size () =
  Masc_tui_render_schedule.Terminal_size_cache.invalidate terminal_size_cache

(* Asked of the tty itself, without a child process.

   [tput] reads the size from TIOCGWINSZ on its own stdout, and this probe
   captured that stdout through a pipe, so the ioctl never saw a terminal and
   [tput] answered from the static terminfo entry instead -- 80x24 for most
   terminals, returned as though it were a measurement. #30187 found the other
   half: since #30160 pointed stderr at a file, a child probe can inherit no
   tty fd at all, which is why it reached for /dev/tty by name.

   Both halves are answered by asking the kernel directly. [Terminal_size]
   tries the three standard descriptors and then /dev/tty, and says [None]
   rather than guessing when none of them is a terminal -- the [tput] fallback
   is gone because a fabricated 80x24 is the failure, not the cure. Two
   processes per resize become none. *)
let probe_terminal_size () = Terminal_size.get ()

let refresh_terminal_size () =
  Masc_tui_render_schedule.Terminal_size_cache.refresh terminal_size_cache
    ~probe:probe_terminal_size

(** Get terminal size (fallback to 80x24). *)
let get_terminal_size () =
  Masc_tui_render_schedule.Terminal_size_cache.get terminal_size_cache
    ~probe:probe_terminal_size

(** Draw horizontal line *)
let draw_hline width =
  String.concat "" (List.init width (fun _ -> Ansi.box_h))

(** Pad or truncate plain text without counting ANSI style bytes. *)
let fit_width = Masc_tui_message_layout.fit_width

(** External values become one printable logical row before renderer-owned ANSI
    styling or width calculation is applied. *)
module Terminal_text = struct
  let single_line text = Masc.Tui_decode.sanitize_terminal_text text
  let preview_line text = Masc.Tui_decode.preview_line text
  let optional_single_line = Option.map single_line

  let single_line_or ~default value =
    Option.value ~default (optional_single_line value)

  let single_lines values = List.map single_line values
  let short_timestamp text = Masc.Tui_decode.short_timestamp_for_terminal text
  (* The screen's clock is the terminal's zone. This is the one place that
     names it, so every row clock and the header clock agree. *)
  let clock_timestamp text =
    Masc.Tui_decode.clock_timestamp_for_terminal ~localtime:Unix.localtime text
end

(** Task status icon *)
let task_status_icon status =
  match status with
  | Masc_domain.Done _ -> "\xe2\x97\x8f"  (* filled circle *)
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.AwaitingVerification _ -> "\xe2\x97\x90"  (* half circle *)
  | Masc_domain.Todo -> "\xe2\x97\x8b"  (* empty circle *)
  | Masc_domain.Cancelled _ -> "\xc3\x97"

(** Priority indicator. Empty for everything but the top priority — the glyph
    owner in [Masc_tui_theme.Glyph] says which ranks speak at all. *)
let priority_indicator p =
  let glyph = Masc_tui_theme.Glyph.priority p in
  if String.equal glyph "" then "" else Theme.bad () ^ glyph ^ Ansi.reset

(** Context ratio tone: healthy capacity recedes; only pressure and danger
    claim an attention colour. All three resolve against the terminal palette. *)
let ctx_color ratio =
  match Masc_tui_observation_layout.context_pressure ratio with
  | Masc_tui_observation_layout.Danger -> Theme.bad ()
  | Masc_tui_observation_layout.Pressure -> Theme.warn ()
  | Masc_tui_observation_layout.Quiet -> Theme.muted ()

(** Format context ratio as a visual bar *)
let ctx_bar ratio width =
  let width = Masc_tui_render_schedule.nonnegative_width width in
  let visible_ratio =
    Float.of_int (Masc_tui_observation_layout.percentage_tenths ratio) /. 1000.0
  in
  let filled = int_of_float (visible_ratio *. float_of_int width) in
  let filled = max 0 (min width filled) in
  let empty = width - filled in
  let color = ctx_color ratio in
  let empty_color = Ansi.reset ^ Theme.recede () in
  Printf.sprintf "%s%s%s%s"
    color
    (String.make filled '#')
    (empty_color ^ String.make empty '-' ^ Ansi.reset)
    Ansi.reset

(* The framed family keeps the full border box. Modals (palette, help) and
   side-by-side panes still need it: a border is what separates an overlay
   from the surface under it, and two panes from each other. *)

(* The box's measurements live in [Masc_tui_frame] so the helpers that draw
   it and the callers that measure against it read one set. *)
let framed_rule_width cols = Masc_tui_frame.rule_width ~cols
let framed_inner_width cols = Masc_tui_frame.inner_width ~cols
let framed_chrome_rows = Masc_tui_frame.chrome_rows
let framed_content_height ~rows = Masc_tui_frame.content_height ~rows

let framed_top buf cols =
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_tl (draw_hline (framed_rule_width cols)) Ansi.box_tr Ansi.reset)

let framed_bottom buf cols =
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_bl (draw_hline (framed_rule_width cols)) Ansi.box_br Ansi.reset)

let framed_divider buf cols =
  Buffer.add_string buf (Printf.sprintf "%s%s%s%s%s\n"
    Ansi.gray Ansi.box_l (draw_hline (framed_rule_width cols)) Ansi.box_r Ansi.reset)

let framed_line buf cols content =
  let inner = framed_inner_width cols in
  Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    (fit_width content inner)
    Ansi.gray Ansi.box_v Ansi.reset)

let framed_line_styled buf cols ~style content =
  let inner = framed_inner_width cols in
  let content = fit_width content inner in
  Buffer.add_string buf
    (Printf.sprintf "%s%s%s %s%s%s %s%s%s\n" Ansi.gray Ansi.box_v
       Ansi.reset style content Ansi.reset Ansi.gray Ansi.box_v Ansi.reset)

let framed_empty buf cols =
  let inner = framed_inner_width cols in
  Buffer.add_string buf (Printf.sprintf "%s%s%s %s %s%s%s\n"
    Ansi.gray Ansi.box_v Ansi.reset
    (String.make inner ' ')
    Ansi.gray Ansi.box_v Ansi.reset)

(* 3D block drop shadow framing for modal overlays. The modal body width is
   shrunk by 1 column and a solid block (█) is drawn along the right edge in
   dim weight, preserving the exact cols display width without wrapping. *)
let shadow_block = "\xe2\x96\x88"

let framed_shadow_top buf cols =
  if cols < 20 then framed_top buf cols
  else
    let rule = draw_hline (framed_rule_width (cols - 1)) in
    Buffer.add_string buf
      (Printf.sprintf "%s%s%s%s%s \n"
         Ansi.gray Ansi.box_tl rule Ansi.box_tr Ansi.reset)

let framed_shadow_bottom buf cols =
  if cols < 20 then framed_bottom buf cols
  else
    let rule = draw_hline (framed_rule_width (cols - 1)) in
    Buffer.add_string buf
      (Printf.sprintf "%s%s%s%s%s%s%s%s\n"
         Ansi.gray Ansi.box_bl rule Ansi.box_br Ansi.reset
         Ansi.dim shadow_block Ansi.reset)

let framed_shadow_divider buf cols =
  if cols < 20 then framed_divider buf cols
  else
    let rule = draw_hline (framed_rule_width (cols - 1)) in
    Buffer.add_string buf
      (Printf.sprintf "%s%s%s%s%s%s%s%s\n"
         Ansi.gray Ansi.box_l rule Ansi.box_r Ansi.reset
         Ansi.dim shadow_block Ansi.reset)

let framed_shadow_line buf cols content =
  if cols < 20 then framed_line buf cols content
  else
    let inner = framed_inner_width (cols - 1) in
    Buffer.add_string buf
      (Printf.sprintf "%s%s%s %s %s%s%s%s%s%s\n"
         Ansi.gray Ansi.box_v Ansi.reset
         (fit_width content inner)
         Ansi.gray Ansi.box_v Ansi.reset
         Ansi.dim shadow_block Ansi.reset)

let framed_shadow_line_styled buf cols ~style content =
  if cols < 20 then framed_line_styled buf cols ~style content
  else
    let inner = framed_inner_width (cols - 1) in
    let content = fit_width content inner in
    Buffer.add_string buf
      (Printf.sprintf "%s%s%s %s%s%s %s%s%s%s%s%s\n"
         Ansi.gray Ansi.box_v Ansi.reset
         style content Ansi.reset
         Ansi.gray Ansi.box_v Ansi.reset
         Ansi.dim shadow_block Ansi.reset)

let framed_shadow_empty buf cols =
  if cols < 20 then framed_empty buf cols
  else
    let inner = framed_inner_width (cols - 1) in
    Buffer.add_string buf
      (Printf.sprintf "%s%s%s %s %s%s%s%s%s%s\n"
         Ansi.gray Ansi.box_v Ansi.reset
         (String.make inner ' ')
         Ansi.gray Ansi.box_v Ansi.reset
         Ansi.dim shadow_block Ansi.reset)

(* Full-screen surfaces draw without the outer box: the terminal edge is
   already the frame, and a border around everything separates nothing (the
   clutter audit's first offender). Every helper keeps its old geometry --
   one row per call, content width {!framed_inner_width} -- so no surface's row budget
   or wrap math moves. *)

let box_top buf _cols = Buffer.add_char buf '\n'
let box_bottom buf _cols = Buffer.add_char buf '\n'

let box_divider buf cols =
  Buffer.add_string buf
    (Printf.sprintf " %s%s%s \n" Ansi.gray (draw_hline (framed_rule_width cols)) Ansi.reset)

(* Rows keep the framed geometry -- two margin cells each side, content
   width {!framed_inner_width} -- and still span the full [cols], so anything that
   measures a row (the PTY suite does) reads the same width either way. *)
let box_line buf cols content =
  let inner = framed_inner_width cols in
  Buffer.add_string buf (Printf.sprintf "  %s  \n" (fit_width content inner))

let box_line_styled buf cols ~style content =
  let inner = framed_inner_width cols in
  let content = fit_width content inner in
  Buffer.add_string buf
    (Printf.sprintf "  %s%s%s  \n" style content Ansi.reset)

(* The selected row of a borderless list: one reverse-video band across the
   full row, box_line's geometry (two margin cells each side, content width
   {!framed_inner_width}). Reverse survives NO_COLOR by contract, so this is also the
   selection signal a colourless terminal keeps. Content must carry no SGR
   of its own -- an inner reset would cut the band short; callers fold a
   styled row with [Masc_tui_theme.strip_sgr] first. *)
let box_line_selected buf cols content =
  let inner = framed_inner_width cols in
  Buffer.add_string buf
    (Printf.sprintf "%s  %s  %s\n" Masc_tui_theme.selection
       (fit_width content inner) Ansi.reset)

let box_empty buf cols =
  Buffer.add_string buf (String.make cols ' ');
  Buffer.add_char buf '\n'
