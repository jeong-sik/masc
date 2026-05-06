(** Cognitive mode FSM - Master Report Dim01 P0 #2 backend (RFC-0035 PR-7).

    Backend OCaml mirror of the dashboard's `CognitiveMode` enum and
    `CognitiveModeState` interface (`dashboard/src/cockpit-entrypoints.ts`).
    Four modes - {!Cockpit}, {!Code}, {!Split}, {!Explode} - covering
    Master Report section 1.4's four cognitive load profiles.

    Backend ownership boundary:

    - This module owns the **mode taxonomy**, the **load/layout
      classification**, the **transition rules**, and the **JSON
      wire format** that the dashboard consumes.
    - This module does NOT own dashboard route targets
      (`tab` / `params`) or the `cockpitModes` mapping. Those are
      dashboard-only concerns and stay in TypeScript so a route
      change does not require a backend pin bump.

    The module is intentionally pure - no I/O, no Eio, no global
    state. Mode transitions are functions of (current mode, signal),
    not of wall-clock time, so call sites can be tested
    deterministically.

    @stability Evolving
    @since 0.19.17 *)

(** The four cognitive modes (Master Report section 1.4). Wire format:
    `"cockpit"` | `"code"` | `"split"` | `"explode"`. *)
type t =
  | Cockpit  (** L1 situational awareness - all panels visible *)
  | Code     (** CLT extraneous-load minimised - editor only *)
  | Split    (** Working-memory dual task - side-by-side compare *)
  | Explode  (** Information-foraging exploration - graph view *)

(** {1 Mode taxonomy round-trips} *)

val to_string : t -> string

val of_string : string -> (t, string) result

(** Master Report ordering used by the dashboard's `COGNITIVE_MODE_ORDER`. *)
val all : t list

(** {1 Load profile classification} *)

(** Cognitive load category attached to each mode (Master Report
    section 1.4). Wire format: `"situational" | "focused" |
    "comparative" | "exploratory"`. *)
type load_kind =
  | Situational
  | Focused
  | Comparative
  | Exploratory

val load_to_string : load_kind -> string
val load_of_string : string -> (load_kind, string) result

(** [load_of_mode m] returns the canonical load category for [m]. *)
val load_of_mode : t -> load_kind

(** {1 Layout hint} *)

(** Layout hint the dashboard uses to choose a panel arrangement. Wire
    format: `"all-panels" | "editor-first" | "side-by-side"
    | "graph-map"`. Hyphenated form matches `chronicle-types.ts` style. *)
type layout =
  | All_panels
  | Editor_first
  | Side_by_side
  | Graph_map

val layout_to_string : layout -> string
val layout_of_string : string -> (layout, string) result

(** [layout_of_mode m] returns the canonical layout for [m]. *)
val layout_of_mode : t -> layout

(** {1 Mode state record} *)

(** Backend view of a `CognitiveModeState`. Lacks the dashboard-only
    `target` and `cockpitModes` fields by design. *)
type state = {
  mode : t;
  label : string;
  load : load_kind;
  layout : layout;
}

(** [state_of_mode m] returns the canonical state record for [m]. *)
val state_of_mode : t -> state

(** {1 Transition rules}

    Each mode has a set of triggers that move the user out of it.
    Master Report section 1.4's transition-trigger column
    is the authoritative source. *)

type signal =
  | Project_open
  | Review_started
  | File_edit_started
  | Sustained_focus_window  (** sustained editing window over N minutes *)
  | Diff_view_requested
  | Reference_lookup        (** parallel lookup while editing *)
  | Codebase_exploration
  | Learning_session
  | Reset_to_overview       (** explicit user "show overview" *)

val signal_to_string : signal -> string

(** [transition ~current ~signal] returns the next mode given the
    current mode and an incoming signal. The function is deterministic
    and total: every (mode, signal) pair has a defined target.

    By design, signals are interpreted as observed user intent rather
    than guarded edge labels. For example, [Codebase_exploration]
    moves to {!Explode} even when [current] is {!Cockpit}. Unknown
    wire values are rejected at the JSON/string decode boundary, not
    by transition. *)
val transition : current:t -> signal:signal -> t

(** {1 JSON codec}

    Wire format matches the dashboard. Modes serialise as a single
    string; states serialise as an object with [mode] / [label] /
    [load] / [layout] keys (camelCase or kebab-case match dashboard
    convention: keys are camelCase, layout values are kebab-case
    strings). *)

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

val state_to_yojson : state -> Yojson.Safe.t
val state_of_yojson : Yojson.Safe.t -> (state, string) result
