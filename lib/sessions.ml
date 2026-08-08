(** Sessions — public API facade.

    Re-exports types from Sessions_types and store operations from
    Sessions_store. *)

include Sessions_types
include Sessions_store

let participant_by_name (session : Runtime.session) name =
  List.find_opt
    (fun (participant : Runtime.participant) -> String.equal participant.name name)
    session.participants
;;
