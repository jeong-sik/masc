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

    All top-level runtime.toml tables (including typed runtime settings tables
    such as [memory], [wiki_contents], [maintenance], [transport], [turn], etc.)
    are declared here as the single source of truth. *)

type t =
  | Providers  (** the provider catalogue *)
  | Models  (** model declarations *)
  | Media_readers  (** external audio/document reader declarations *)
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
  | Machines  (** activity of the workspace MSX and DOS machines *)
  | Memory_os  (** read by scripts/memory_os_judge_eval.py *)
  | Keeper_settings  (** runtime.toml schema version metadata *)
  | Reactive  (** reactive keeper turn settings *)
  | Autonomous  (** autonomous keeper turn settings *)
  | Heartbeat  (** keeper heartbeat cadence and keepalive settings *)
  | Wire_capture  (** wire capture diagnostic settings *)
  | Debug  (** keeper debug settings *)
  | Turn  (** keeper turn runtime settings *)
  | Supervisor  (** keeper supervisor settings *)
  | Metrics  (** keeper metrics rotation settings *)
  | Memory  (** keeper memory working-set and Memory OS settings *)
  | Wiki_contents  (** wiki table-of-contents injection settings *)
  | Vision  (** keeper vision tool settings *)
  | Maintenance  (** JSONL retention and maintenance settings *)
  | Transport  (** HTTP/2, HTTPS, WebSocket, and gRPC transport settings *)
  | Sandbox  (** keeper sandbox and microVM settings *)
  | Web_search  (** web search provider settings *)
  | Otel  (** OpenTelemetry export settings *)
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
