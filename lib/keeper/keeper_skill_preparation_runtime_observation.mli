(** Persistence boundary for Skill preparation observations. Cache collection
    does not depend on the manifest writer or runtime orchestration. *)
type phase = Direct_task_resolution | Autonomous_task_resolution | Executable_setup

val with_turn_result :
  ?preview:Keeper_turn_preview.writer ->
  config:Workspace.config -> keeper_name:string -> turn_ref:Ids.Turn_ref.t -> phase:phase ->
  (unit -> ('a, 'e) result) -> ('a, 'e) result
(** Append one best-effort manifest observation after this operation settles.
    The original turn reference is supplied by its owner. Sample clocks are
    offsets within this capture only, never inferred from publication age,
    planned batches or another turn. Persistence runs outside cache locks and
    after the measured interval; its overhead remains separate and unmeasured.
    A supplied writer also observes the enclosing live Skill scope, including
    report publication. That enclosing span is distinct from capture offsets. *)
