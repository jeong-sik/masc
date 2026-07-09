(** SSOT for detecting whether a task deliverable's prose claims completion.

    Used as a conflict tripwire in two places:
    - {!Verification_protocol.submit_request_spec}: escalate a verification
      request to [conflict_triage] when a submitted deliverable asserts
      completion.
    - {!Workspace_status_rendering} (consumed by [tool_workspace]): flag a
      [Todo] task whose deliverable already claims done.

    {b Known limitation (WORKAROUND).} Completion is detected by an
    English-only prefix match ("<task_id> completed" / "completed ..."), so a
    deliverable phrased differently — or written in another language (e.g.
    Korean "완료했습니다") — reads as {i not} claiming completion (false
    negative). Whether prose asserts completion is a semantic judgment that
    belongs at an LLM boundary; the language-agnostic replacement is tracked
    under RFC-0323 (conflict-triage lane). This module exists to hold a single
    deterministic implementation so that replacement touches one call site
    instead of two. *)

val deliverable_claims_completion : task_id:string -> string -> bool
(** [deliverable_claims_completion ~task_id deliverable] is [true] when the
    first non-empty line of [deliverable], lowercased and trimmed, starts with
    ["completed"] or ["<task_id> completed"]. See the module note for the
    known false-negative surface. *)
