(** Immutable preparation of one Goal proof review. A Goal has no Task or
    producer; its subject is the exact pending proof and criterion revision.
    The host-built capability supplies the original evidence and lookup grants.
    Preparation captures both prompt messages before any model dispatch.

    This module is data and preparation only. Retention, dispatch progress and
    final proof commitment belong to their respective host owners. *)

type t

val schema : string
val prepare :
  attempt:int -> authority:Verification_authority_tools.goal_review ->
  (t, string) result
(** Render the Goal's own metric/target question, current-revision reported
    measurement and evidence locator, shared-root layout and submitted-source
    metadata using the current prompt templates. The measurement is untrusted
    context, not a lookup grant or a substitute for reading the declared
    metric's source. It is kept as its own field, so a later attempt asks with
    the same report. No Task contract, generated producer or supplied
    prompt/dispatch closure is used. *)

val subject : t -> Verification_authority_tools.goal_subject
val base_path : t -> string
(** Captured host workspace identity, available during judgment recovery
    without rebuilding the lookup surface. *)
val attempt : t -> int
val submitted_evidence : t -> Workspace_verification_store.submitted_evidence_item list
val measurement : t -> Goal_measurement.observation
(** The reported measurement this attempt was asked with. *)
val question_binding : t -> string
(** The canonical question digest of the host-built Goal review surface. *)
val authority_binding : t -> string
(** The canonical lookup authority digest of the host-built Goal review surface. *)
val lookup_schemas : t -> string list
val root_layout : t -> string list
val prompt : t -> string
val system_instructions : t -> string
val output_contract : t -> string

val question_matches : t -> Verification_authority_tools.goal_review -> bool
(** The current authority asks this original's question: the same Goal,
    request, criterion, workspace and submitted snapshot, and the same question
    digest. An original does not authorize reading evidence for another
    request or workspace. *)

val authority_change :
  t -> Verification_authority_tools.goal_review ->
  (Verifier_review_authority_change.t option, string) result
(** What moved between this original's lookup authority digest and answer
    format and the current ones. [Ok None] when neither moved. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Strict current-schema inverse: reject missing, extra or duplicate fields
    and malformed nested criterion, evidence or measurement. Never rerender a
    retained prompt against today's templates when restoring its original
    bytes. *)
val digest : t -> (string, string) result

type successor_error =
  | Question_changed
  | Prompt_unavailable of string
  | Successor_unavailable of string

val successor :
  authority:Verification_authority_tools.goal_review -> t -> (t, successor_error) result
(** The next attempt asks the parent's question with the current authority.
    The subject, workspace, submitted snapshot, reported measurement and
    question digest come from the parent. The authority digest, tool names and
    root layout come from [authority]. The prompt is rendered now from them
    with the parent's measurement, the instructions from the current prompt
    template, and the output contract is this build's.

    An [authority] for another question is [Question_changed]. A prompt or
    instruction template that cannot be rendered now is [Prompt_unavailable].
    This does not authorize retrying a dispatched or unknown original; the
    durable owner decides that. *)

val is_successor_of : parent:t -> t -> bool
(** [true] when the child is the parent's next attempt and asks the same
    question. Lookup grants and rendered text may differ, because each attempt
    takes the authority current when it was prepared. *)
