(** The account gate's decision for a request path, against the route inventory.

    This layer answers one question: is this path a route the inventory names?
    A path no entry covers is refused, so a route that reaches the network
    without passing the inventory cannot be served by accident. Which accesses
    survive in multi-account mode is the mode's question, decided above this
    module; keeping it separate means this refusal cannot be widened by a mode
    edit. *)

type refusal =
  | Uninventoried of
      { path : string
      ; method_ : Httpun.Method.t
      }
      (** No inventory entry answers this path and method. *)
  | Keeper_prefix_missing
      (** The inventory has no entry for the keeper prefix, so every keeper
          sub-route is unnameable. *)

type decision =
  | Allowed of Server_account_route.entry
  | Refused of refusal

val decide :
  Server_account_route.entry list -> path:string -> method_:Httpun.Method.t -> decision
(** [decide entries ~path ~method_] is [Allowed entry] when {!Server_account_route.covering}
    names an entry, and [Refused (Uninventoried _)] otherwise. An empty
    inventory refuses everything. *)

val reconcile : Server_account_route.entry list -> (unit, string) result
(** [reconcile entries] is the boot check: [Error] when the inventory is empty,
    when the keeper prefix is absent, when a [Prefix] entry does not end in [/]
    (it would also cover the paths beside it, so [/api/v1/board] would answer
    for [/api/v1/board-secret]), or when one exact path appears twice with two
    different accesses (dispatch would serve the last one while the inventory
    names both, so a reader could take the wrong access). [Ok ()] means every
    row the gate can be asked about names one access and no prefix reaches
    beside itself. *)

val refusal_text : refusal -> string
(** One line for the operator, naming the path and the method. *)
