(** Which verifier scan step could not settle a Verifying goal: applying the
    proof the verifier already committed, or re-arming its pending request.

    The goal verifier scan produces it and the planning wire carries it as a
    lowercase token, so the server and the TUI decoder both read this module
    rather than the verifier runtime. *)

type t =
  | Reconcile_proof
  | Rearm_proof

val to_string : t -> string
(** The wire token: [reconcile_proof] or [rearm_proof]. *)

val of_string : string -> t option
(** Inverse of {!to_string}; [None] for any other token. *)
