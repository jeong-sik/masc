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
       RFC-0431. *)
    ; slot_1 : string
    ; slot_2 : string
    }

  (* A slot, so the accessor below is total. *)
  type category =
    | Slot_1
    | Slot_2

  (* One place says which hue a slot carries, so the contrast suite measures
     the mapping the renderer actually draws instead of a copy of it.

     Four, because the palette holds seven hues and three of them are spoken
     for by colours a categorical mark must not be mistaken for: [bad]'s red,
     [ok]'s green, and the receding black. A fifth slot would have to take one
     of those back, and the file pane draws both bad and ok on the rows it
     colours by kind. Cyan and yellow still read as info and warn, which is
     safe only on a surface that draws neither. *)
  let category_colour = function
    (* The two colours a theme names that no surface drawing a slot also
       draws as a state. The file listing shares a terminal row with a pane
       that draws bad, ok, info and warn -- red, green, cyan and yellow --
       which is four of the seven, and a slot on any of them is a status
       token to the byte on that row. Two is what is left, and it is why the
       kind axes rest on glyphs and words with colour on top rather than
       under. *)
    | Slot_1 -> Masc_tui_theme.Bright_blue
    | Slot_2 -> Masc_tui_theme.Bright_magenta

  let all_categories = [ Slot_1; Slot_2 ]

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
        (* See [category_colour]: the hues no status token draws. *)
        ; slot_1 = of_colour (category_colour Slot_1)
        ; slot_2 = of_colour (category_colour Slot_2)
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

(* A row of places a reader can switch between, with the one being read
   marked: the mark and the name in the information colour, the others dim,
   two cells apart. The surface strip above every screen draws its entries this
   way, and the smaller strips inside a screen -- Activity's two readings,
   Config's panes, Planning's tabs, Metrics' sections -- each drew their own
   variant: a "|" between names on two of them, a space before the unmarked
   names on two, a different colour on one. *)
(* [width] is what the row can spare for the strip. A strip wider than that
   used to be cut by the row's fitter from the right, so beside the roster pane
   the Keeper detail's nine tabs ended at "Automatio…" and a reader on Runs
   had no mark anywhere on the row; Config's seven panes lost "voice" the
   same way. The entries are cut around the current one instead: it always
   draws, its neighbours fill what is left, one side at a time, and a dim
   "…" stands where entries were dropped. Entries that fit draw exactly as
   before. *)
let tab_strip_gap = "  "

let tab_strip_cut = "\xe2\x80\xa6"

(* The cells this strip needs to keep its promise: the current entry whole,
   with the cut marks its position calls for. Below this the window cannot
   grow past the current entry and [fit_width] cuts into the entry itself --
   a row would read "@p@" where it means "prompts", which names nothing. A
   row that draws a strip asks for this before it spends the width on
   anything that can give way. *)
let tab_strip_min_width (tabs : (string * bool) list) =
  let cells text = Masc_tui_message_layout.display_width text in
  let entries = Array.of_list tabs in
  let n = Array.length entries in
  if n = 0 then 0
  else begin
    let current =
      let rec find i = if i >= n then 0 else if snd entries.(i) then i else find (i + 1) in
      find 0
    in
    let label, _ = entries.(current) in
    let cut = cells tab_strip_cut + cells tab_strip_gap in
    cells Masc_tui_theme.Glyph.current_entry
    + cells label
    + (if current > 0 then cut else 0)
    + (if current < n - 1 then cut else 0)
  end

let tab_strip ~width (tabs : (string * bool) list) =
  let draw (label, current) =
    if current then
      Ansi.bold ^ Theme.info () ^ Masc_tui_theme.Glyph.current_entry ^ label
      ^ Ansi.reset
    else Ansi.dim ^ label ^ Ansi.reset
  in
  let cells text = Masc_tui_message_layout.display_width text in
  let entries = Array.of_list tabs in
  let n = Array.length entries in
  if n = 0 then ""
  else begin
    let widths =
      Array.map
        (fun (label, current) ->
          (if current then cells Masc_tui_theme.Glyph.current_entry else 0)
          + cells label)
        entries
    in
    let gap = cells tab_strip_gap in
    let span lo hi =
      let sum = ref 0 in
      for i = lo to hi do
        sum := !sum + widths.(i)
      done;
      !sum + (gap * (hi - lo))
    in
    if span 0 (n - 1) <= width then String.concat tab_strip_gap (List.map draw tabs)
    else begin
      let cut = cells tab_strip_cut + gap in
      let fits lo hi =
        span lo hi
        + (if lo > 0 then cut else 0)
        + (if hi < n - 1 then cut else 0)
        <= width
      in
      let current =
        let rec find i =
          if i >= n then 0 else if snd entries.(i) then i else find (i + 1)
        in
        find 0
      in
      let lo = ref current and hi = ref current in
      (* Grown a neighbour at a time, the side alternating, so a current
         entry in the middle keeps both its neighbours before either side
         reaches further. *)
      let prefer_right = ref true in
      let growing = ref true in
      while !growing do
        let right () =
          if !hi + 1 < n && fits !lo (!hi + 1) then (incr hi; true) else false
        in
        let left () =
          if !lo > 0 && fits (!lo - 1) !hi then (decr lo; true) else false
        in
        let grew = if !prefer_right then right () || left () else left () || right () in
        if grew then prefer_right := not !prefer_right else growing := false
      done;
      let shown =
        List.init (!hi - !lo + 1) (fun i -> draw entries.(!lo + i))
        |> String.concat tab_strip_gap
      in
      let mark = Ansi.dim ^ tab_strip_cut ^ Ansi.reset in
      let drawn =
        (if !lo > 0 then mark ^ tab_strip_gap else "")
        ^ shown
        ^ if !hi < n - 1 then tab_strip_gap ^ mark else ""
      in
      (* The window is seeded with the current entry and only grows under
         [fits], so an entry wider than the whole budget is drawn anyway. At a
         hundred columns the Config row had two cells left for its strip and
         the strip spent sixteen on the marked tab and its cut; the frame
         took those cells back from the end of the row, which is where the
         clock and the connection badge are. [tab_strip_width] exists to stop exactly that,
         and its own reasoning says why the strip is the one that gives way:
         a strip can drop tabs and mark the cut, and a badge has no way of
         saying it was shortened.

         So the strip keeps its promise here rather than leaving the frame to
         enforce it on whatever sits furthest right. [fit_width] pads a short
         string, which would push that tail out by hand, so it is asked only
         when the strip is actually over. *)
      if Masc_tui_message_layout.display_width drawn > width then
        Masc_tui_message_layout.fit_width drawn width
      else drawn
    end
  end

(* The cells a row leaves its strip: the frame's inner width less everything
   the row draws around the strip, gaps included. Callers hand over the text
   they draw rather than a number, so the two cannot disagree.

   [after] is what the row draws to the strip's right on the same line -- the
   clock and the connection badge, mostly. It was not asked for, so the strip
   took every cell the row had left and the frame cut whatever followed: at a
   hundred columns the Planning title lost its badge and half its clock, and
   the Config panes lost both and half of "(load failed)" as well. A strip has
   its own way of giving cells back (it drops tabs and marks the cut), and the
   badge has none, so the badge is what the row must keep.

   Required rather than optional, so a row that draws something after its
   strip cannot forget to say so: the compiler asks every caller, including
   the ones whose strips are short enough to fit today. A strip that owns its
   whole row passes "". *)
let tab_strip_width ~cols ~before ~after =
  Masc_tui_frame.inner_width ~cols
  - Masc_tui_message_layout.display_width (Masc_tui_theme.strip_sgr before)
  - Masc_tui_message_layout.display_width (Masc_tui_theme.strip_sgr after)

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
    (* A bare link changes only underline and foreground. Closing exactly
       those two attributes preserves an enclosing diff background and any
       weight; a dim body then re-asserts its dim, which the foreground
       restore deliberately leaves alone. *)
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
    (* Background news keeps no badge colour of its own: the badge recedes
       with the body it introduces, one rung below speech. *)
    | Masc_tui_message_layout.Journal -> Theme.recede ()
    | Masc_tui_message_layout.Error -> Theme.bad ()
    (* The tool trail recedes with its body; state colour is reserved for
       state, and a tool badge is work, not state. *)
    | Masc_tui_message_layout.Tool -> Theme.quiet_origin ()
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
    (* Speech keeps the terminal foreground: it is the protagonist, and
       everything below it in the hierarchy recedes instead. *)
    | Masc_tui_message_layout.User | Masc_tui_message_layout.Inbound
    | Masc_tui_message_layout.Keeper -> Ansi.reset
    | Masc_tui_message_layout.Status -> Theme.warn ()
    (* The badge is quiet; the body is not dimmed. A command list is read. *)
    | Masc_tui_message_layout.Local -> Ansi.reset
    | Masc_tui_message_layout.Error -> Theme.bad ()
    (* Work, background news and skill chatter sit one rung below speech. *)
    | Masc_tui_message_layout.Journal -> Ansi.dim
    | Masc_tui_message_layout.Tool -> Ansi.dim
    | Masc_tui_message_layout.Skill _ -> Ansi.dim
    | Masc_tui_message_layout.Thinking -> Ansi.dim

  let link_foreground : Masc_tui_message_layout.style -> string = function
    | Masc_tui_message_layout.Status -> Theme.warn ()
    | Masc_tui_message_layout.Error -> Theme.bad ()
    | Masc_tui_message_layout.User | Masc_tui_message_layout.Inbound
    | Masc_tui_message_layout.Keeper | Masc_tui_message_layout.Tool
    | Masc_tui_message_layout.Local | Masc_tui_message_layout.Journal
    | Masc_tui_message_layout.Skill _ | Masc_tui_message_layout.Thinking ->
      Ansi.default_fg

  (* A bare link opens underline and a bright foreground, and the restore
     must close both. [Ansi.default_fg] clears the link colour without
     touching intensity -- SGR 39 is not a reset -- so a dim body re-asserts
     [Ansi.dim] after it, while a full-brightness body stops at the
     foreground. *)
  let link_style_restore style =
    let foreground =
      match style with
      | Masc_tui_message_layout.Journal | Masc_tui_message_layout.Tool
      | Masc_tui_message_layout.Skill _ | Masc_tui_message_layout.Thinking ->
        Ansi.default_fg ^ Ansi.dim
      | Masc_tui_message_layout.User | Masc_tui_message_layout.Inbound
      | Masc_tui_message_layout.Keeper | Masc_tui_message_layout.Status
      | Masc_tui_message_layout.Local | Masc_tui_message_layout.Error ->
        link_foreground style
    in
    Ansi.no_underline ^ foreground

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
       takes the plain ground; its mark and colour say where it came from.

       [markdown_close] reopens the body style after the reset: every chat
       body is markdown-rendered, and the palette closes bold and code spans
       with it. A plain reset would snap a dim body back to full foreground
       after the first closed span. *)
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
      ; markdown_close = Ansi.reset ^ opening
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
  let short_timestamp text =
    Masc.Tui_decode.short_timestamp_for_terminal ~localtime:Unix.localtime text
  (* The screen's clock is the terminal's zone. This is the one place that
     names it, so every row clock and the header clock agree -- which is also
     why no row spells "(local)" beside its own time. Four rows out of the
     thirty-five this TUI draws used to, and a marker on four of them says the
     other thirty-one are something else. The guide states the zone once, for
     the whole screen. *)
  let clock_timestamp text =
    Masc.Tui_decode.clock_timestamp_for_terminal ~localtime:Unix.localtime text
end

(** Task status icon *)
let task_status_icon status =
  match status with
  | Masc_domain.Done _ -> Masc_tui_theme.Glyph.progress_done
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.AwaitingVerification _ -> Masc_tui_theme.Glyph.progress_active
  | Masc_domain.Todo -> Masc_tui_theme.Glyph.progress_waiting
  | Masc_domain.Cancelled _ -> Masc_tui_theme.Glyph.progress_ended

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
  let width = Masc_tui_layout.nonnegative_width width in
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

(* Full-screen surfaces draw without the outer box: the terminal edge is
   already the frame, and a border around everything separates nothing (the
   clutter audit's first offender). Every helper keeps its old geometry --
   one row per call, content width {!framed_inner_width} -- so no surface's row budget
   or wrap math moves. *)

let box_top buf _cols = Buffer.add_char buf '\n'
let box_bottom buf _cols = Buffer.add_char buf '\n'

(* The receded colour, not the flat grey it falls back to. [Theme.recede]
   projects onto the probed palette and holds a 3:1 contrast floor; [Ansi.gray]
   is the value it returns when there is no palette to project onto. So on a
   terminal that reports one, this rule used to sit at whatever grey the SGR
   table happened to give -- which can be the background -- while the rules
   the surfaces draw beside it were receded. *)
let box_divider buf cols =
  Buffer.add_string buf
    (Printf.sprintf " %s%s%s \n" (Theme.recede ())
       (draw_hline (framed_rule_width cols)) Ansi.reset)

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
