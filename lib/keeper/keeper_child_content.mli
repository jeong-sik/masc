(** Scoped complete Child observations for public read transport. Decoded values
    are unprivileged views, never runtime witnesses or input/publication grants. *)

type origin =
  { keeper_name : string
  ; source : Runtime_native_tasks.source
  ; attempt : Runtime_native_tasks.attempt
  ; invocation : Runtime_native_tasks.invocation
  }

type parent_occurrence =
  { call_id : string; call_envelope_uuid : string; call_ordinal : int }
(** Original native Agent occurrence observed with this body. It may already
    have returned; absence remains unknown and is never upgraded by this codec. *)

type parent_evidence =
  | Explicit_parent_input
  | Response_inherited_parent_input
  | Command_inherited_parent_input of { stamp_uuid : string }
(** Historical evidence kind for the original Agent call, not proof that Child
    consumed an input group. No input text or consumed-member list is exposed. *)

type attribution =
  | Original_parent_input of parent_evidence
  | Parent_input_refused of Keeper_claude_task_binding.rejection

type view = private
  { origin : origin
  ; observation_id : string
  ; envelope_uuid : string
  ; ordinal : int
  ; channel : Runtime_claude_code.content_channel
  ; parent_tool_use_id : string
  ; parent_occurrence : parent_occurrence option
  ; message_id : string option
  ; model : string
  ; text : string
  ; attribution : attribution
  }
(** [observation_id] names the actual accepted complete-frame observation;
    blocks of that frame share it, repeated accepted frames have distinct IDs.
    Original provider UUID/ordinal/channel remain exact correlations. Neither ID
    is a delivery/commit receipt, ordering clock or liveness claim. Optional
    message/parent absence is unreported or unknown, not an inferred value.
    Body is a complete snapshot, including empty text, never a root delta. *)

type error = Invalid_view of string | Malformed_json of string
val to_json : view -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (view, error) result
(** Canonical [masc.child_content.v1] closed objects. Unknown/duplicate/null
    members and malformed schema/numbers are refused. Nonnegative ordinal and
    attempt index use the shared JSON-safe integer contract. Opaque protocol
    identities remain byte-identical; no spelling convention grants ownership.
    Decode cannot create a runtime record, sealed binding or publication. *)
val redact : (string -> string) -> view -> view
(** Redact human body/model leaves again at public read serialization. Preserve
    every identity, optional absence, evidence and typed refusal. This is not
    an inverse into publication authority. *)
val error_to_string : error -> string

type publication
val prepare : keeper_name:string -> source:Keeper_native_task_journal.source ->
  attempt:Runtime_native_tasks.attempt -> redact_text:(string -> string) ->
  Keeper_claude_task_binding.child_observation -> (publication, error) result
(** Sole publication constructor accepts an actual sealed runtime/binding
    decision. It snapshots only redacted human body/model leaves; all protocol
    identity/evidence/refusal facts are preserved. Raw content is not retained.
    Redaction operates on each complete field/body snapshot independently; it
    does not provide streaming-secret guarantees across child blocks or replay
    snapshots, and touches no root buffer. Source/attempt are the caller's
    captured execution facts; this does not prove
    workspace authorization, durable commit, child input consumption or Task/run
    ownership. A durable sink must independently capture its workspace scope. *)
val view : publication -> view
(** Read-only redacted view. There is no inverse from public view to publication. *)
