(** Task owners whose Keeper route needs inspection.

    A missing Keeper queue means that a verdict cannot be delivered to that
    queue. The owner may still be an active external session. An unreadable
    Keeper record is distinct from a missing queue. Neither observation is a
    question or proof that only an operator can move the Task.

    A projection, not an authority: it reads the backlog every surface already
    reads and adds no state, no field and no gate. Nothing here decides
    anything, and an empty list is a fact about the workspace rather than a
    failure to look.

    It sits in [masc] rather than beside the operator tools because the
    surfaces that draw it sit on both sides of that library: the TUI and the
    operator tools above, the dashboard's attention rules below. All surfaces
    share the same observation of the Keeper route. *)

type item =
  | Held_without_keeper_route of
      { task_id : string
      ; title : string
      ; assignee : string
      ; since : string
      }
  | Producer_record_unreadable of
      { task_id : string
      ; title : string
      ; producer : string
      ; since : string
      ; detail : string
      }

val project :
  config:Workspace_utils_backend_setup.config -> Masc_domain.task list -> item list
(** Oldest claim or start first. The producer route is
    resolved through {!Keeper_producer_route}, the same computation the
    rejection delivery uses, so a missing route means delivery cannot reach
    that name through a Keeper queue. *)

val task_id : item -> string

val title : item -> string

val waiting_since : item -> string
(** The claim/start time; it does not establish when an owner stopped. *)

val summary : item -> string
(** One line, for a surface that has one line. Written here rather than at each
    screen so three screens cannot describe the same row three ways. *)

val next_step : item -> string
(** A suggested inspection or repair. *)
