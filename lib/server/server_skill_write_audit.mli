(** The one audit row a Skill package write leaves, whoever asked for it: the
    operator editor route or a Keeper's [keeper_skill_publish]. *)

(** Line count for the audit [lines] metric. A final ['\n'] ends the last line
    rather than starting a new one (["a\nb\n"] -> 2). *)
val line_count : string -> int

(** What the row is about. [Published] names the exact reference the editor
    created. [Attempted] names the package a write began on when the editor
    cannot prove whether it committed: a [SKILL.md] may still be on disk and
    reach the catalog at the next refresh, so the attempt is recorded too. *)
type subject =
  | Published of Skill_reference.t
  | Attempted of
      { source_id : string
      ; package_id : string
      }

(** Append a [skill_write] row. [evidence] is the Keeper's own list and is
    recorded as given; the operator route passes none. A failing audit append
    is logged, never raised, except cancellation. *)
val record :
  Workspace.config ->
  agent_id:string ->
  subject:subject ->
  source_text:string ->
  status:string ->
  ?evidence:string list ->
  outcome:Audit_log.outcome ->
  unit ->
  unit
