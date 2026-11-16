(** Immutable observation indexes for one parsed transcript prefix. The store
    owns their lifetime together with its file identity and redaction policy.
    Appending rows preserves older snapshots; no acknowledgement is persisted
    or advanced here. *)
type t

val empty : t
val append : t -> Keeper_chat_types.chat_message list -> t
(** Rows must be in file append order. Historical answers remain indexed even
    when a reader's acknowledgement has moved past them. For [k] new rows and
    [N] retained rows, index updates cost [O(k log(N+k))], excluding row parsing,
    redaction and variable-length content/identity comparisons. *)

val of_messages : Keeper_chat_types.chat_message list -> t
(** Initial index construction costs [O(N log N)] for [N] rows, with the same
    exclusions as {!append}. *)

val contains_message : message_id:string -> t -> bool
(** Whether any parsed row has this exact ID, regardless of role, answers or
    acknowledgement. Uses the retained row positions without traversing rows. *)

val messages : t -> Keeper_chat_types.chat_message list
(** The full transcript in append order; only explicit whole-history readers
    materialize this list. *)

val pending_users : ?ack_id:string -> t -> Keeper_chat_types.chat_message list
(** Unanswered user rows after the first occurrence of [ack_id], in append
    order. Missing/absent acknowledgement means all user rows. Answered turn
    references and delivery keys are checked across the entire prefix. *)

val fleet_candidates_rev : t -> Keeper_chat_types.chat_message list
(** Newest-first user rows on Agent/Broadcast surfaces. The observer applies
    its current targets and lane classifier before taking its requested limit;
    this context is independent of the reactive acknowledgement. *)
