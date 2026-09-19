(** Operator_task_attention — the tasks only an operator can move.

    A task in a state whose exit belongs to nobody who is still there waits
    forever, and until now nothing drew that fact. Three shapes produce it:

    - a stop the producer asked for, which only an operator may grant
      (RFC-0417 §4.4);
    - work held by an agent that has no Keeper queue, so no claim, release or
      submission under that name will ever be made again;
    - a producer whose Keeper record this binary cannot decode, which is not
      the same as having none and is a repair rather than a judgment.

    A projection, not an authority: it reads the backlog every surface already
    reads and adds no state, no field and no gate. Nothing here decides
    anything, and an empty list is a fact about the workspace rather than a
    failure to look.

    It sits in [masc] rather than beside the operator tools because the
    surfaces that draw it sit on both sides of that library: the TUI and the
    operator tools above, the dashboard's attention rules below. One answer
    for all of them is the whole point — three screens computing "can anyone
    still move this" three ways is how they come to disagree about the same
    task. *)

type item =
  | Held_without_actor of
      { task_id : string
      ; assignee : string
      ; since : string
      }
  | Producer_record_unreadable of
      { task_id : string
      ; producer : string
      ; since : string
      ; detail : string
      }

val project :
  config:Workspace_utils_backend_setup.config -> Masc_domain.task list -> item list
(** Oldest first, so the longest wait is the first row. The producer route is
    resolved through {!Keeper_producer_route}, the same computation the
    rejection delivery uses, so a name this list calls actorless is exactly a
    name that delivery cannot reach. *)

val task_id : item -> string

val waiting_since : item -> string
(** When the task started waiting on the operator: the stop's submission time,
    or the claim/start time of work nobody holds. *)

val summary : item -> string
(** One line, for a surface that has one line. Written here rather than at each
    screen so three screens cannot describe the same row three ways. *)

val next_step : item -> string
(** What ends this wait. Not always a tool: granting a stop is a verdict an
    operator signs in the verify queue, and an undecodable Keeper record is
    repaired outside the task surfaces entirely. *)
