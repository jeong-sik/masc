(** Which verifier step could not settle a Verifying goal: applying the
    committed proof, re-arming its pending request, or reading its retained
    original before dispatch.

    The goal verifier scan produces it and the planning wire carries it as a
    lowercase token, so the server and the TUI decoder both read this module
    rather than the verifier runtime. *)

type t =
  | Reconcile_proof
  | Rearm_proof
  | Read_original

val to_string : t -> string
(** The wire token: [reconcile_proof], [rearm_proof] or [read_original]. *)

val of_string : string -> t option
(** Inverse of {!to_string}; [None] for any other token. *)
