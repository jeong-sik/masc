(** Producer-owned result dependencies. These identify original work; they
    grant no launch, cancellation or execution authority. *)
type composition = private
  { request_id : string
  ; composition_run_id : Keeper_tool_plan.Composition_run_id.t
  ; skill_reference : Skill_reference.t
  ; composition_tool : string
  ; parent_tool_use_id : string
  ; source_turn : int
  ; source_task_id : string option
  }

val composition_of_json : Yojson.Safe.t -> (composition, string) result
val composition_to_json : composition -> Yojson.Safe.t
val composition_of_request_context :
  request_id:string -> (string * Yojson.Safe.t) list -> (composition, string) result
(** Capture only a named composition producer's original source. [None] for
    [source_task_id] is an explicitly absent Task in that accepted source. *)

type t =
  | Owned_job of Keeper_owned_job_identity.Job_id.t
  | Composition_result of composition

type readiness = Waiting | Ready

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val normalize : t list -> t list
val list_of_json : Yojson.Safe.t -> (t list, string) result
(** Require a nonempty array without duplicate dependency identities. *)
