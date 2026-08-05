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
    belongs at an LLM boundary.

    {b No RFC owns that replacement.} RFC-0000's roadmap records this module as
    the single definition and states the English-only character as fact; it
    does not schedule a language-agnostic successor. Consolidating here was the
    tracked work and it landed, so a replacement touches one call site instead
    of two — but nothing is currently driving one. *)

val deliverable_claims_completion : task_id:string -> string -> bool
(** [deliverable_claims_completion ~task_id deliverable] is [true] when the
    first non-empty line of [deliverable], lowercased and trimmed, starts with
    ["completed"] or ["<task_id> completed"]. See the module note for the
    known false-negative surface. *)
