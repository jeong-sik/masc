(** Pure durable value for one accepted asynchronous composition run.

    The accepted surface digest records what the accepting caller observed. It
    is never compared with a later surface and therefore cannot become a
    resume gate. Effects such as persistence and execution stay outside this
    module. *)

type origin =
  | Skill_composition of Skill_reference.t
  | Assembler_proposal of
      { assembler_run_id :
          Keeper_plan_proposal_execution_request.Assembler_run_id.t
      ; proposal_id : Keeper_plan_proposal.Proposal_id.t
      }

type t

type object_name =
  | Recipe
  | Origin
  | Invocation
  | Schedule

type decode_error =
  | Expected_object of object_name
  | Duplicate_field of
      { object_name : object_name
      ; field : string
      }
  | Unknown_field of
      { object_name : object_name
      ; field : string
      }
  | Missing_field of
      { object_name : object_name
      ; field : string
      }
  | Expected_string of
      { object_name : object_name
      ; field : string
      }
  | Expected_int of
      { object_name : object_name
      ; field : string
      }
  | Invalid_composition_run_id of
      Keeper_tool_plan.Composition_run_id.error
  | Invalid_origin_kind of string
  | Invalid_skill_reference of Skill_reference.decode_error
  | Invalid_assembler_run_id
  | Invalid_proposal_id of string
  | Invalid_execution_mode of string
  | Invalid_completion of string
  | Invalid_plan of Keeper_tool_plan_request.error
  | Invalid_checkpoint of Agent_core.Error.t

val create
  :  composition_run_id:Keeper_tool_plan.Composition_run_id.t
  -> origin:origin
  -> accepted_surface_digest:string
  -> plan:Keeper_tool_plan.t
  -> invocation:Agent_core.Tool_contract.Invocation.t
  -> accepted_checkpoint:Agent_core.Checkpoint.t
  -> (t, Keeper_tool_plan_request.encode_error) result
(** Construction rejects plans that still contain unbound parameters. *)

val to_yojson
  :  t
  -> (Yojson.Safe.t, Keeper_tool_plan_request.encode_error) result

val of_yojson
  :  descriptors:Keeper_tool_descriptor.t list
  -> Yojson.Safe.t
  -> (t, decode_error) result

val composition_run_id : t -> Keeper_tool_plan.Composition_run_id.t
val origin : t -> origin

val accepted_surface_digest : t -> string
(** Observational value only; callers must not use it as a resume gate. *)

val plan : t -> Keeper_tool_plan.t
val invocation : t -> Agent_core.Tool_contract.Invocation.t
val accepted_checkpoint : t -> Agent_core.Checkpoint.t
