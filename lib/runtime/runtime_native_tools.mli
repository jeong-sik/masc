(** Native-tool posture for official-client runtimes (RFC-0390).

    Each CLI runtime (Claude Code, Codex, Antigravity) ships its own agent
    tools. MASC decides per keeper how much of that built-in surface a turn
    may use; effects beyond the declared posture run through MASC tools,
    which the approval gate can see. *)

type posture =
  | Native_none  (** Reads and effects both go through MASC tools only. *)
  | Native_read  (** Built-in read tools allowed; effects stay MASC-owned. *)
  | Native_full  (** The full built-in surface, effects included. *)

(** Where an official-client turn takes its native posture from. *)
type posture_source =
  | Declared_on_disk
      (** The operator's [keepers/<name>.toml] states it (or states nothing
          and the runtime default stands). A keeper nothing declares is
          refused at profile load (audit F386). *)
  | Program_defined of posture
      (** The program that created the keeper states it as a value. Such a
          keeper has no declaration on disk and none is looked for: the
          task-completion reviewer is one (RFC-0390, #36066 fallout). *)

val posture_source_of_required : posture option -> posture_source
(** [None] at the turn driver's [?required_native_posture] means the keeper
    is declared on disk; [Some posture] is a program-defined one. *)

type action_identity =
  | Call_id of string
  | Provider_step of
      { conversation_id : string
      ; step_index : int
      }

type origin =
  | Built_in
  | Mcp_wrapper

type observation =
  { identity : action_identity option
  ; tool_name : string option
  ; origin : origin
  }
(** Bounded identity reported by an official CLI for one built-in tool step.
    Missing fields stay [None]; adapters must not turn a provider step ordinal
    into a call id. *)

type exact_action = action_identity * string
(** Admit only an exact built-in provider identity with a non-empty tool name.
    MCP wrapper steps are observed but their canonical MASC invocation is the
    action authority; the admitting projection stays internal to
    [observe_exact_action]. *)

type completion_outcome =
  | End_observed
  | Completion_reported
  | Error_reported
  | Decline_reported
  | Result_received of { is_error : bool option }
  | Unrecognized_status of string
(** Provider facts, never MASC execution receipts. [Completion_reported] does
    not establish exit zero. A Claude result may omit [is_error]; omission is
    retained rather than manufactured into an explicit success report. *)

type completion = { outcome : completion_outcome; exit_code : int option }
type finished = { observation : observation; completion : completion }

type progress =
  | Output_observed of { byte_count : int }
  | Message_reported of { message : string }
  | Heartbeat_reported of { elapsed_seconds : int }

val progress_to_json : progress -> Yojson.Safe.t
(** Numeric progress fields use {!Runtime_json_integer.of_json}: byte counts
    are positive and heartbeat seconds are nonnegative JSON safe integers. *)
val progress_of_json : Yojson.Safe.t -> (progress, string) result
val redact_progress : (string -> string) -> progress -> progress
(** Progress is provider observation, not output content or a completion.
    Output bytes count each received delta; equal deltas are separate observations.
    Heartbeat seconds are a nonnegative provider report, independent of local
    elapsed time. A later report may be smaller without being rejected. *)

val end_observed : completion
val completion_to_json : completion -> Yojson.Safe.t
val completion_of_json : Yojson.Safe.t -> (completion, string) result
(** Strict closed-object decoder: duplicate fields and fields outside the
    selected outcome variant are errors, including contradictory reports.
    A non-null exit code uses {!Runtime_json_integer.of_json}; negative safe
    integers remain valid provider facts. *)
val redact_completion : (string -> string) -> completion -> completion
val observe_exact_action :
  official_turn:int ->
  observe:(official_turn:int -> identity:action_identity -> tool_name:string -> unit) ->
  observation -> unit

val call_id : observation -> string option
(** Return a literal provider call id when one exists. A provider step is not
    flattened into this field. *)

val stream_content_type : string
(** Internal AGENT_CORE content-block discriminator used only to carry a typed
    native observation through the Keeper stream bridge. *)

val to_string : posture -> string
val of_string : string -> posture option

val valid_posture_strings : string list
(** For error messages, in declaration order. *)

(** Current hard-coded stance of each runtime, kept as the default when a
    keeper profile declares nothing. One value per runtime because the
    runtimes genuinely differ today; unifying them silently would change
    some lane's behaviour. *)

val claude_code_default : posture
val codex_default : posture
val antigravity_default : posture
val muse_default : posture
val muse_none_supported : bool
(** MSP cannot remove all built-in tools. Keeper Muse admission rejects a
    requested [Native_none] rather than claiming suppression. *)

val claude_code_read_tool_names : string list
(** Built-in Claude Code tools that observe without effect. *)

val degrade_on_admission : posture:posture -> none_supported:bool -> unit -> posture
(** The safest posture the client can run when admission cannot honor the
    declared one: [full] degrades to [read] (effects stay behind the MASC
    approval gate), [none] on a client without a disable switch degrades
    to [read]. Used with a typed event, never silently — see
    RFC-0390 admission review. *)

val claude_code_tools_arg : posture -> string
(** Value for the [--tools] flag: [""] disables the built-in set,
    ["default"] enables all of it, otherwise a comma-separated allowlist. *)

val claude_setting_sources_arg : string
(** The [--setting-sources=] argv token naming no settings layer: the CLI
    loads no skills, hooks, subagents, or CLAUDE.md from disk. A loaded layer
    could carry code that runs outside the MASC approval gate. *)
