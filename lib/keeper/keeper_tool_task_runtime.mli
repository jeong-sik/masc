(** Agent task tool runtime — claim, transition, list. *)

(** Build a failed tool-result payload for a caller-input validation error,
    tagged with [Tool_result.Policy_rejection] (RFC-0062 §3.2: "validation
    reject"). Exposed so the keeper failure-circuit-breaker gates can be tested
    end-to-end: the resulting payload is exempt from the health breaker (Gate
    #1) yet still counted by the per-(tool,args) breaker (Gate #2). *)
val validation_error_json : string -> string

(** RFC-0323 G-2: machine identity under which the RFC-0199 deterministic
    probe approves its own submission ([Workspace.submit_and_approve_task_r]).
    Distinct from every keeper identity key, so the FSM self-approval check
    holds. Exposed so tests can pin its [Validation.Agent_id] validity. *)
val deterministic_probe_verifier : string

val handle_keeper_task_tool :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  name:string ->
  args:Yojson.Safe.t ->
  string
