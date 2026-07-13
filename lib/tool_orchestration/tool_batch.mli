(** Batch planning for ToolJob execution.

    This module owns the scheduling contract only. It does not execute tools,
    call providers, or know about Keeper runtime policy. Callers can use
    {!plan} to split a turn's jobs into contiguous parallel-read batches,
    sequential workspace jobs, and policy-blocked jobs before choosing an
    executor such as OAS [Async_agent.all]. *)

type execution_kind =
  | Parallel_read
  | Sequential_workspace

type t = {
  batch_id : string;
  execution_kind : execution_kind;
  jobs : Tool_job.t list;
}

val execution_kind_to_string : execution_kind -> string

val plan : Tool_job.t list -> t list
(** Plan jobs in input order. Read-only jobs with no resource keys are grouped
    into contiguous [Parallel_read] batches when they share the same
    [batch_id]. Other jobs become singleton [Sequential_workspace] batches. *)
