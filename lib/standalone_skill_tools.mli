(** Read-only instruction Skills for standalone tool-using agents.
    Uses the published workspace snapshot; never starts a Keeper or executes
    a composition. The snapshot and advertised bodies are frozen per run. *)
val of_snapshot :
  config:Workspace.config ->
  ?on_result:(input:Yojson.Safe.t -> Tool_result.result -> unit) ->
  Skill_catalog_snapshot.t -> Agent_core.Tool.t list

val for_workspace :
  config:Workspace.config ->
  ?on_result:(input:Yojson.Safe.t -> Tool_result.result -> unit) ->
  unit -> (Agent_core.Tool.t list, string) result
(** No published snapshot means no Skill tool. Workspace resolution errors
    remain explicit, so callers can report missing optional capabilities. *)
