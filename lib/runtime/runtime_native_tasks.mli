(** Provider-native task vocabulary and public transport data.

    These values describe observations, not MASC task/execution receipts.
    Decoding transport data grants no runtime ownership: the Claude runtime's
    admitted owner and callback observation remain separate private types. *)

type status =
  | Task_pending | Task_running | Task_completed | Task_failed | Task_killed | Task_paused

type terminal = Task_completed_notice | Task_failed_notice | Task_stopped_notice
type reason = Worker_restart
type boundary = Task_terminal_unobserved | Task_terminal_observed
(** [Task_terminal_unobserved] means no terminal evidence was observed. It does
    not assert running, pending, process liveness, or future delivery. *)

type usage = { total_tokens : int; tool_uses : int; duration_ms : int }
(** Signed provider-reported JSON safe integers, never root model usage. *)

type event =
  | Task_registered of
      { subagent_type : string option; is_backgrounded : bool option
      ; skip_transcript : bool option; ambient : bool option }
  | Task_patched of
      { status : status option; is_backgrounded : bool option
      ; end_time : int option; total_paused_ms : int option }
  | Task_progress_reported of { usage : usage; last_tool_name : string option }
  | Task_terminal_reported of
      { outcome : terminal; reason : reason option; usage : usage option
      ; skip_transcript : bool option; ambient : bool option }
(** [None] means not reported, including boolean fields: it is not [Some false].
    Registration supplies no status. [ambient=true] must not contribute to
    activity; [skip_transcript=true] must not create an inline transcript entry.
    Raw prompt, description, summary, error and output-file bodies are excluded. *)

type source =
  | Operation of { operation_id : string }
  | Autonomous_turn of { turn_ref : string }
(** The real owning execution/turn, not a synthetic operation for autonomous work.
    Batch subscriber identity remains in the enclosing delivery transport. *)

type attempt =
  { routing_run_id : string; runtime_id : string; lane_attempt_index : int }
(** The materialized driver attempt captured before dispatch, not the runtime
    selected when a delayed event arrives. The index is nonnegative. *)

type invocation =
  { receiver_generation : string; session_id : string; client_uuid : string }
(** Actual host input ticket, frozen through explicit root attribution.
    Generation distinguishes receiver invocations even when a session resumes.
    This public record is not a privileged input ticket or proof of consumption. *)

type native_call =
  { session_id : string; call_id : string; call_envelope_uuid : string; call_ordinal : int }
(** Original provider envelope and nonnegative block ordinal. The call can
    already have ended. Its session must match the invocation session. Neither
    a current stream scope nor a tool index is used. *)

type origin =
  { keeper_name : string; source : source; attempt : attempt
  ; invocation : invocation; native_call : native_call
  ; task_id : string; run_id : string }
(** Opaque identity strings remain byte-identical. No ID prefix, timestamp or
    whitespace convention grants ownership. Runtime/base authority belongs to
    the authenticated enclosing journal/subscription, not a public path field. *)

type t = private
  { origin : origin; uuid : string; event : event; boundary : boundary }
(** Public, unprivileged transport data. A successful decode must never be
    converted into a runtime-admitted owner. [uuid] is the provider observation
    UUID, independent of the input UUID and native-call envelope UUID.
    [boundary] is the runtime registry's post-event fact, not a root turn end. *)

val make : origin:origin -> uuid:string -> event:event -> boundary:boundary ->
  (t, string) result
(** Validate transport numeric and event/boundary consistency. This does not
    validate a live session, native-call ownership, replay or task-run ordering.
    The future Keeper converter must obtain those from admitted runtime values
    and the exact originating input ticket, never the latest ticket. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Canonical [masc.native_task_observation.v1] closed objects: all required fields
    must occur exactly once, optional fields are omitted for [None], and explicit
    nulls/unknown fields/duplicates are rejected. Numeric decoding uses
    {!Runtime_json_integer.of_json}; no sign constraint is inferred for provider
    usage, end_time or total_paused_ms. Identity strings have no spelling test.
    No caller may infer a currently active task from successful decoding. *)

val redact : (string -> string) -> t -> t
(** Redact only reported subagent_type and last_tool_name. Preserve identities,
    enum facts, numbers and absent/false/true flags. Call before durable publish
    and at public serialization; this function touches no model content buffer. *)
