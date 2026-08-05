(** SSOT for detecting whether a task deliverable's prose claims completion.

    Used as a conflict tripwire by two consumers:
    - {!Verification_protocol.submit_request_spec}: escalate a verification
      request to [conflict_triage] when a submitted deliverable asserts
      completion.
    - {!Tool_workspace}: flag a [Todo] task whose deliverable already claims
      done in workspace status and conflict projections.

    {b Known limitation (WORKAROUND).} Completion is detected by an
    English-only prefix match ("<task_id> completed" / "completed ..."), so a
    deliverable phrased differently — or written in another language (e.g.
    Korean "완료했습니다") — reads as {i not} claiming completion (false
    negative). This module is the single deterministic definition used by
    those consumers. *)

val deliverable_claims_completion : task_id:string -> string -> bool
(** [deliverable_claims_completion ~task_id deliverable] is [true] when the
    first non-empty line of [deliverable], lowercased and trimmed, starts with
    ["completed"] or ["<task_id> completed"]. See the module note for the
    known false-negative surface. *)
