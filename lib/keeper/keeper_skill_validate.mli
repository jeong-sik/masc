(** Read-only static validation of proposed SKILL.md bytes in an exported
    artifact. Uses the canonical authoring validator, without publishing a
    reference, modifying a Skill source, or executing a composition. *)

(** One exported SKILL.md and the package directory it is proposed for. This
    is the [{artifact, package_id}] pair [keeper_skill_validate] takes and
    returns. The operator editor accepts the same pair to publish those exact
    bytes. *)
type draft =
  { artifact : Keeper_peer_artifact_ref.t
  ; package_id : Skill_reference.package_id
  }

(** Accepts exactly the two fields [artifact] and [package_id]. *)
val draft_of_json : Yojson.Safe.t -> (draft, string) result

(** The exported bytes, or an error when the blob is absent, its size differs
    from the reference, or its content no longer hashes to the reference. *)
val read_draft : config:Workspace.config -> draft -> (string, string) result

val handle :
  config:Workspace.config -> args:Yojson.Safe.t -> Keeper_tool_execution.t
