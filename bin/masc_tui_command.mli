(** What the operator typed into the composer: a message for the keeper, or
    a command for the TUI.

    The composer is the one input row every surface shows, addressed to the
    keeper the roster cursor points at. Most of what is typed there is a
    message. A line that starts with a slash is a command this module names,
    and a command this build does not know is reported as such rather than
    sent to the keeper as text - a mistyped command should not become an
    instruction the keeper acts on.

    The grammar is closed: one leading slash, one word, the rest of the
    first line, then any further lines. No prefix matching, no aliases. *)

type t =
  | Say of string  (** Plain text for the keeper, unchanged. *)
  | Task_for_keeper of {
      title : string;  (** The rest of the first line after [/task]. *)
      body : string;  (** Every line after the first, as typed. *)
    }
  | Task_missing_title  (** [/task] with nothing after it on the line. *)
  | Help  (** [/help] — draw the command list into the pane. *)
  | About
      (** [/about] or [/splash] — display MASC Horned Reaper ASCII emblem and system telemetry. *)
  | Open_metrics
      (** [/metrics] or [/telemetry] — display multicore engine telemetry, scheduler latency, and fleet metrics. *)
  | Open_settings
      (** [/settings] — open the type-aware Runtime parameters pane. *)
  | Open_diff
      (** [/diff] — open Git working-tree changes and diff for the workspace. *)
  | Open_changes
      (** [/changes] — open recorded file changes for this keeper. *)
  | Toggle_acting_pane
      (** [/activity] — show or hide the Activity pane beside this surface,
          the same toggle as Ctrl-L. *)
  | Show_acting_pane_tab of [ `Fleet | `Changes ]
      (** [/activity fleet], [/activity changes] — show the pane on that
          tab: the fleet's feed, or the selected keeper's file changes. *)
  | Acting_pane_tab_unknown of string
      (** [/activity <word>] with a word that names no tab; reported, not
          guessed. *)
  | Switch_keeper of string
      (** [/keeper <name>] — point this pane at another keeper. *)
  | Switch_keeper_missing_name  (** [/keeper] with no name on the line. *)
  | Interrupt_turn
      (** [/interrupt] — the composer form of the interrupt keybinding, for
          an operator mid-sentence whose hands are already on letters. *)
  | Steer_turn of string
      (** [/steer <message>] — interrupt the streaming turn, then dispatch
          this exact message before ordinary next-turn input. *)
  | Steer_missing_message
      (** [/steer] without replacement text. *)
  | Set_thinking of [ `Cycle | `Hidden | `Folded | `Full ]
      (** [/thinking [hidden|folded|full]] — set or cycle reasoning visibility.
          Replaces the earlier [Toggle_thinking]: two states could not say
          "keep the count but not the text". *)
  | Set_tools of [ `Toggle | `Compact | `Full ]
      (** [/tools [compact|full]] — set or toggle tool-call detail. *)
  | Cycle_memory
      (** [/memory] — cycle Librarian/Memory journal rows: summary, full,
          hidden. Ctrl-N walks the same cycle. *)
  | Open_fleet_memory
      (** [/fleet-memory] — browse the facts of every Keeper in the fleet at
          once. [a] on the Memory overview opens the same screen. *)
  | Find_in_chat of string
      (** [/find <text>] — put the pane on the newest message holding [text].

          A slash word rather than a key: every printable byte in this pane is
          composer text, so [/] cannot arm a search here the way it does on a
          list surface, and the chords are spent. It is also the shape the
          pane already has for doing a thing to this conversation. *)
  | Find_next
      (** [/find] with nothing after it — the next match older than the one
          the pane is parked on, in the text it was last given. The arg-less
          form continues rather than resets, which is what [/thinking] with no
          argument already means here. *)
  | Inspect_context
      (** [/context] — inspect the last provider input observed for this
          Keeper, including exact prompt-block text where it was captured. *)
  | View_image of string
      (** [/image <path>] — draw an image file on the terminal, if it can
          hold one. The path is the rest of the first line, untrimmed of
          nothing but the space after the word: a path may contain spaces,
          and quoting it would be a second grammar. *)
  | View_image_missing_path  (** [/image] with no path on the line. *)
  | Attach_image of string
      (** [/attach <path>] — stage an image to send with the next message to
          this Keeper. Distinct from [/image], which draws on the terminal and
          sends nothing: one is for the operator to look at, the other is for
          the Keeper to read. The path grammar matches [/image]. *)
  | Attach_image_missing_path  (** [/attach] with no path on the line. *)
  | Preset_list  (** [/preset] — list the prompt presets the server holds. *)
  | Preset_save of {
      name : string;
      description : string;
    }
      (** [/preset save <name> [description]] — snapshot prompt overrides,
          keeper instructions and runtime routing under [name]. *)
  | Preset_save_missing_name  (** [/preset save] with no name. *)
  | Preset_restore of string
      (** [/preset restore <name>] — autosave the live state, then apply. *)
  | Preset_restore_missing_name  (** [/preset restore] with no name. *)
  | Unknown of string  (** A slash word this build does not know, by name. *)

type command_help = {
  word : string;  (** The slash word itself, without the slash. *)
  args : string;  (** How the rest of the line reads, or [""] for none. *)
  summary : string;  (** One line on what it does. *)
}

val catalog : command_help list
(** Every command this build knows. {!help_lines} and {!hint} are both drawn
    from it, so a command cannot be described one way in the help and another
    in the composer. *)

val usage : command_help -> string
(** [/word args], or [/word] where there are none. *)

type hint =
  | No_command  (** The composer holds a message, not a command. *)
  | Candidates of {
      typed : string;  (** The word so far, without its slash. *)
      entries : command_help list;
          (** What that word could still become, in catalog order. *)
    }
  | Chosen of command_help  (** The word names this command exactly. *)
  | Unknown_command of string  (** The word begins nothing the parser knows. *)

type hint_span =
  | Typed of string  (** Glyphs the operator has already entered. *)
  | Untyped of string  (** What the word would still need. *)
  | Detail of string  (** Arguments, summaries, separators. *)
  | Wrong of string  (** A word that names no command. *)
(** One piece of a hint row, split where its colour changes. This module
    draws nothing: it says which glyphs were typed and which are still ahead,
    and the renderer decides what each looks like. *)

val hint_spans : hint -> hint_span list
(** The hint as coloured pieces, in reading order. Empty for
    {!No_command}. *)

val hint_span_text : hint_span -> string
(** The glyphs a span carries, whatever kind it is. *)

val hint : string -> hint
(** What to show while the operator is typing. A half-typed word lists its
    candidates rather than describing one, because {!parse} does no prefix
    matching and the line is not sendable yet. *)

val hint_line : hint -> string option
(** {!hint} as one row for the composer's footer, or [None] where there is
    nothing to say. *)

val help_lines : string list
(** One line per command, the list [/help] draws. Kept beside the parser so a
    new command cannot ship without its line. *)

(** How [/keeper <name>] resolved against the roster. *)
type keeper_match =
  | Keeper_found of string
  | Keeper_ambiguous of string list
      (** More than one roster name starts with what was typed; the
          candidates are reported rather than guessed between. *)
  | Keeper_unknown

val resolve_keeper_name : names:string list -> string -> keeper_match
(** Exact name first — a keeper whose full name prefixes another's stays
    reachable — then a unique prefix. Command words stay closed; only the
    name argument matches by prefix. *)

val parse : string -> t
(** Read the composer's text. Leading blanks are not stripped before the
    slash is looked for: an operator who types a space first meant text. *)

val about_banner : ?theme_name:string -> ?active_keepers:int -> unit -> string
(** Horned Reaper ASCII splash emblem and live telemetry card. *)

val task_message : task_id:string -> title:string -> body:string -> string
(** The message handed to the keeper once its task exists: the task id in
    front of what the operator wrote, so the keeper can claim the exact task
    and the operator's own words carry the request. *)

type direction = Next | Prev
(** Direction to step when cycling autocomplete candidates. *)

val autocomplete :
  ?direction:direction ->
  ?keeper_names:string list ->
  string ->
  string option
(** [autocomplete ?direction ?keeper_names text] computes the completed command line.
    [direction] defaults to [Next] (e.g. for Tab or ArrowDown). [Prev] moves backward
    through candidate commands and argument options (e.g. for ArrowUp or Shift-Tab).
    Returns [None] if [text] is not a slash command. *)

val is_slash_navigable : ?keeper_names:string list -> string -> bool
(** [is_slash_navigable ?keeper_names text] determines if the composer input currently
    holds an active slash command prefix or enumerated sub-arguments that should be
    navigated by ArrowUp/ArrowDown instead of message history recall. *)
