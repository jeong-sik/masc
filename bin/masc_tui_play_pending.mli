type kind = Issue_invite of string | Revoke_invite of string
type entry = { id : string; base_path : string; masc_root : string; kind : kind }

val read : path:string -> (entry list, string) result
(** A durable pending request is unknown after restart, including one whose
    response arrived before the old process could acknowledge it. *)
val prepare : path:string -> entry -> (unit, string) result
(** Persist before sending. A pending request for the same origin refuses a
    second mutation, including a request from another TUI process. *)
val settle : path:string -> entry -> (bool, string) result
(** Remove only the matching origin and request ID. [false] means this receipt
    no longer owns the origin. A failed acknowledgement keeps changes blocked. *)
