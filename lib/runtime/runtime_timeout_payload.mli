(** Shared payload for the four runtime adapter [Timeout] errors.

    The seconds component is the only field present on every adapter.
    [stage] carries the ACP diagnostic (idle-wait stage, JSON-RPC method,
    or stdin-write) and is [None] for the float adapters and Codex.
    [turn_accepted] carries the Codex dispatch fence and is [None] for
    the float adapters and ACP. [None] means the adapter tracks no such
    fact; it is never a defaulted [false]. *)

type t =
  { seconds : float
  ; stage : string option
  ; turn_accepted : bool option
  }

val of_seconds : float -> t
(** Seconds only; both diagnostics [None]. For the float adapters. *)

val of_codex : seconds:float -> turn_accepted:bool -> t
(** Codex mapping: [turn_accepted] is [Some] so the keeper fence branch
    stays exact ([Some false] is safe retry, [Some true] fences). *)

val of_acp : stage:string -> timeout_s:float -> t
(** ACP mapping: the timeout value is [seconds], the diagnostic is
    [stage]. *)
