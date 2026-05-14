(** Chronicle event data model — Master Report Dim02 P1 (RFC-0035 PR-4).

    Backend-side OCaml schema for the chronicle event stream that the
    dashboard's `chronicle-navigator` (#13823) already consumes via
    `dashboard/src/components/chronicle/chronicle-types.ts`.

    This module is the single source of truth for the *emit* side: any
    keeper, plan, git-watcher, or test-runner adapter that wants to
    surface an event in the dashboard chronicle MUST go through
    {!to_yojson}, never hand-roll the JSON. The wire format is fixed by
    the dashboard read model and any change here that breaks JSON
    compatibility will silently drop events from the chronicle UI.

    The module is intentionally:

    - Pure (no Eio, no I/O, no global state).
    - Additive only at the variant level — adding a new
      {!actor_kind} or {!event_type} requires a coordinated
      dashboard release because the read model rejects unknown
      strings.
    - JSON-shape stable: serialisation uses a custom codec, not
      [@@deriving yojson], because the wire format uses camelCase
      (matching TypeScript) while the OCaml record fields use the
      conventional snake_case.

    See {!docs/rfc/RFC-0035-cognitive-ide-roadmap.md} (PR-4) for the
    integration plan and the Master Report (`Chapter 2: Chronicle /
    History / Librarian`, §2.2 ChronicleEvent) for the original
    design rationale.

    @stability Evolving
    @since 0.19.14 *)

(** Kind of actor that produced the event. Wire format: `"user"` |
    `"keeper"` | `"agent"` | `"system"`. *)
type actor_kind =
  | Ak_user
  | Ak_keeper
  | Ak_agent
  | Ak_system

(** Kind of target the event refers to. Wire format: `"file"` |
    `"module"` | `"plan"` | `"issue"` | `"command"` | `"test"` |
    `"conversation"`. *)
type target_kind =
  | Tk_file
  | Tk_module
  | Tk_plan
  | Tk_issue
  | Tk_command
  | Tk_test
  | Tk_conversation

(** Concrete event type taxonomy. Wire format mirrors the dotted
    strings from the dashboard read model (`"file.opened"`,
    `"keeper.step"`, etc.). *)
type event_type =
  | Ev_file_opened
  | Ev_file_edited
  | Ev_file_saved
  | Ev_command_executed
  | Ev_keeper_started
  | Ev_keeper_step
  | Ev_keeper_decision
  | Ev_keeper_completed
  | Ev_keeper_error
  | Ev_plan_created
  | Ev_plan_updated
  | Ev_plan_step_completed
  | Ev_plan_blocked
  | Ev_build_completed
  | Ev_test_passed
  | Ev_test_failed
  | Ev_git_commit
  | Ev_git_merge
  | Ev_conversation
  | Ev_suggestion_accepted
  | Ev_suggestion_rejected

(** Actor stamp on an event. *)
type actor = {
  kind : actor_kind;
  id : string;
  display_name : string;
}

(** Target the event acts on. [range], if present, is a 0-based
    inclusive line span. *)
type target = {
  kind : target_kind;
  uri : string;
  range : (int * int) option;
}

(** Snapshot of project state at the moment the event was recorded.
    All fields are optional because not every emitter has access to
    every datum (e.g. a keeper.step event may not include a commit). *)
type project_snapshot = {
  branch : string option;
  commit : string option;
  files_changed : int option;
  dirty : bool option;
}

(** Human-readable content of the event. [summary] is mandatory because
    the dashboard relies on it for the lane title. *)
type content = {
  summary : string;
  detail : string option;
  diff : string option;
  metadata : (string * Yojson.Safe.t) list;
}

(** Threading context that lets the dashboard build a reply graph and
    a tag cloud. *)
type context = {
  session_id : string;
  parent_event_id : string option;
  related_event_ids : string list;
  tags : string list;
  project_state : project_snapshot option;
}

(** Optional intent stamp (the SDK / host's interpretation of the
    actor's goal). [confidence] is in the closed interval [0.0, 1.0]. *)
type intent = {
  stated_goal : string option;
  inferred_intent : string option;
  confidence : float;
}

(** A single chronicle event. [timestamp] is Unix milliseconds since
    the epoch. *)
type t = {
  id : string;
  event_type : event_type;
  timestamp : int;
  actor : actor;
  target : target;
  content : content;
  context : context;
  intent : intent option;
}

(** {1 String round-trips for the variant taxonomies}

    These are exposed because they are useful in tests and in
    Prometheus label code; the JSON codecs ({!to_yojson} / {!of_yojson})
    use them internally. *)

val actor_kind_to_string : actor_kind -> string
val actor_kind_of_string : string -> (actor_kind, string) result

val target_kind_to_string : target_kind -> string
val target_kind_of_string : string -> (target_kind, string) result

val event_type_to_string : event_type -> string
val event_type_of_string : string -> (event_type, string) result

(** {1 JSON codec}

    Wire format matches the dashboard
    `dashboard/src/components/chronicle/chronicle-types.ts`. Field
    names use camelCase (`eventType`, `displayName`, `sessionId`,
    `parentEventId`, `relatedEventIds`, `projectState`, `filesChanged`,
    `statedGoal`, `inferredIntent`). *)

val to_yojson : t -> Yojson.Safe.t

val of_yojson : Yojson.Safe.t -> (t, string) result

(** {1 Invariant check}

    Lightweight structural validation. Returns [Ok ()] on a well-formed
    event; otherwise [Error msg] with a single string. Decoders that
    want to reject malformed inputs should call this after
    {!of_yojson}. *)
val is_well_formed : t -> (unit, string) result
