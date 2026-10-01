(** The top-level tables of runtime.toml that belong to a reader other than
    a provider's model bindings.

    A provider's bindings are a top-level table too, named after the provider
    id ([[codex.gpt-5.6]]). A provider called [voice] would make [[voice.tts]]
    both its bindings and the voice settings, so no provider may be called by
    any name here. Model ids never become top-level tables and may use
    these names.

    Each reader takes its table's name from {!key}, which keeps the spelling
    in one place and makes a new table something that is added here before
    anything reads it.

    The keeper runtime settings ([turn], [wire_capture], [web_search], ...)
    are not listed. [Keeper_runtime_setting_registry] owns those names and
    [Keeper_runtime_config.owned_namespaces] derives them from it. *)

type t =
  | Providers  (** the provider catalogue *)
  | Models  (** model declarations *)
  | Model_sets  (** shared model lists referenced by providers *)
  | Runtime  (** default runtime, lanes, assignments *)
  | Exec  (** SSH execution endpoints *)
  | Egress  (** per-keeper egress allowances *)
  | Lsp  (** language servers *)
  | Typesafeai  (** the TypeSafeAI lane's destinations *)
  | Skills  (** skill sources *)
  | Fusion  (** Fusion presets and seats *)
  | Board  (** Board moderation settings *)
  | Voice  (** voice endpoints and keeper voices *)
  | Tui  (** picks the TUI keeps *)
  | Slack  (** the Slack connector *)
  | Discord  (** the Discord connector *)
  | Repositories  (** the pull-request reader *)
  | Browser  (** the browser lane *)
  | Memory_os  (** read by scripts/memory_os_judge_eval.py *)
[@@deriving enumerate]
(* [all] is generated, so a table added to [t] is in it. *)

val key : t -> string
(** The table's name as runtime.toml spells it. *)

val path : t -> string -> string
(** [path table rest] is [rest] under the table, dotted the way runtime.toml
    and its error locations spell it: [path Runtime "lanes"] is
    ["runtime.lanes"]. [rest] is used as written. *)

val of_key : string -> t option
(** The table a top-level name belongs to; [None] for any other name. *)
