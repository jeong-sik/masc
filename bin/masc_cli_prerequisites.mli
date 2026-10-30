(** Execute only the operator-selected native action. Child prompts and output
    stay on the terminal; stdout carries the action receipt. *)
val run : base_path:(unit -> string) -> dependency:string -> action:string option -> int
(** [base_path] is read only by a dependency scoped to a workspace. Installing
    an official client or a sandbox happens before there is one. *)

val run_terminal : string list -> (unit, unit) result
(** Run an explicitly selected child with stdin and both outputs on the terminal. *)
