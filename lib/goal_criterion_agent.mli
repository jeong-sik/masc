(** Application-owned B2 semantic reviewer. Uses the existing verifier_exact
    structured reviewer and read-only Goal lookup; no Keeper or proof action. *)
val start : sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Workspace_utils.config -> unit
(** The application caller holds the workspace's process-lifetime owner lease
    (HTTP and stdio boot acquire it before post-readiness owner lanes). A new
    installation reconciles prior dispatch intent once, before new workers;
    duplicate starts in the same live lane do not retire its dispatches. *)
module For_testing : sig
  val process : ?sw:Eio.Switch.t option -> Workspace_utils.config ->
    goal_id:string -> (unit, Goal_criterion_review.error) result
  val recover : ?sw:Eio.Switch.t option -> Workspace_utils.config ->
    (unit, Goal_criterion_review.error) result
end
