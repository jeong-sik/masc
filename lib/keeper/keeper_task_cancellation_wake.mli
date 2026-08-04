(** Deliver a committed Task cancellation to the Keeper that authored the Task.

    Cancellation is the one terminal Task outcome with no reader. Completion
    posts a verdict to Board and submission posts a request, but a cancellation
    wrote a backlog field and an activity row and stopped there.
    {!Keeper_goal_reconciliation_wake} does not cover it: that path targets the
    owner of the Task's Goal, so a Task with no Goal link reaches no one. On the
    reference workspace no Task carried a Goal link at all, which made the
    existing terminal wake unreachable for every one of them.

    The author is resolved from [created_by]. A self-cancellation enqueues
    nothing: the author already knows. *)

type outcome =
  | Delivered of { keeper_name : string }
  | Already_present of { keeper_name : string }
  | Not_cancelled
      (** The committed status is not [Cancelled]; other terminal outcomes have
          their own Board projection. *)
  | Self_cancelled
      (** The canceller authored the Task. *)
  | No_author
      (** The Task carries no [created_by], so there is no addressee. Not an
          error: tasks may be filed without a recorded author. *)
  | Author_not_a_keeper of { author : string }
      (** [created_by] resolves to no Keeper lane — an operator, a client id, or
          a retired Keeper. Not an error: there is no lane to wake. *)
  | Backlog_read_failed of { detail : string }
  | Author_lookup_failed of { author : string; detail : string }
  | Enqueue_failed of { keeper_name : string; detail : string }

val outcome_label : outcome -> string
(** Stable snake_case tag for logs and delivery telemetry. *)

val notify_author :
  config:Workspace.config -> cancelling_agent_name:string -> task_id:string -> outcome
(** Read [task_id] from the backlog and, when it is [Cancelled] by someone other
    than its author, enqueue a durable [Task_cancelled] stimulus on the author's
    lane and wake it. Every non-delivery is a typed outcome rather than a
    silent return, so a caller can surface it. *)
