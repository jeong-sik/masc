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
    context captured in the existing immutable prompt, not a lookup grant or
    a substitute for reading the declared metric's source. No Task
    contract, generated producer or supplied prompt/dispatch closure is used. *)

val subject : t -> Verification_authority_tools.goal_subject
val base_path : t -> string
(** Captured host workspace identity, available during judgment recovery
    without rebuilding the lookup surface. *)
val attempt : t -> int
val submitted_evidence : t -> Workspace_verification_store.submitted_evidence_item list
val lookup_binding : t -> string
val lookup_schemas : t -> string list
val root_layout : t -> string list
val prompt : t -> string
val system_instructions : t -> string
val output_contract : t -> string

val matches_authority : t -> Verification_authority_tools.goal_review -> bool
(** Compare the complete captured authority binding and exact subject. An
    original does not authorize reading evidence on another request/workspace. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Strict current-schema inverse: reject missing, extra or duplicate fields
    and malformed nested criterion/evidence. Never rerender a retained prompt
    against today's templates when restoring its original bytes. *)
val digest : t -> (string, string) result
val successor : t -> (t, string) result
(** Change only the attempt identity. This pure operation does not authorize
    retrying a dispatched or unknown original. The durable owner decides that. *)
