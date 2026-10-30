(** Sessions — public API facade.

    Re-exports types from {!Sessions_types} and store operations from
    {!Sessions_store}.

    @stability Evolving
    @since 0.93.1 *)

include module type of Sessions_types
include module type of Sessions_store

(** {1 Participant lookup} *)

(** [participant_by_name session name] returns the first participant (in
    [session.participants] order) whose [name] equals [name] exactly, or
    [None] if none match. If several participants share [name], only the
    first is returned. The lookup is case-sensitive and does not inspect
    aliases. *)
val participant_by_name : Runtime.session -> string -> Runtime.participant option
