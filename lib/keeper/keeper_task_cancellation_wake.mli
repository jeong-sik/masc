(** Deliver a committed Task cancellation to the Keeper that authored the Task.

    Cancellation is the one terminal Task outcome with no reader. Completion
    posts a verdict to Board and submission posts a request, but a cancellation
    wrote a backlog field and an activity row and stopped there.

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
      (** [created_by] resolves to no Keeper lane — an operator or a client id.
          Not an error: there is no lane to wake. A Keeper whose shutdown
          finalized while retaining its meta still presents a lane here
          and is not filtered out: that decision belongs to the durable intake
          gate in {!Keeper_registry_event_queue}, which admits every retention
          other than [Remove_meta] for all stimulus producers alike. *)
  | Backlog_read_failed of { detail : string }
  | Author_lookup_failed of { author : string; detail : string }
  | Canceller_lookup_failed of { agent_name : string; detail : string }
      (** [cancelled_by] resolves to more than one Keeper, or the lookup itself
          failed. Nothing is enqueued: the author may be among the candidates,
          so the self-cancellation check cannot be decided, and delivering
          anyway would wake a Keeper about its own decision. *)
  | Enqueue_failed of { keeper_name : string; detail : string }

val outcome_label : outcome -> string
(** Stable snake_case tag for logs and delivery telemetry. *)

val notify_author :
  config:Workspace.config -> cancelling_agent_name:string -> task_id:string -> outcome
(** Read [task_id] from the backlog and, when it is [Cancelled] by someone other
    than its author, enqueue a durable [Task_cancelled] stimulus on the author's
    lane and wake it. Every non-delivery is a typed outcome rather than a
    silent return, so a caller can surface it. *)
