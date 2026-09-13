(** Execute only the operator-selected native action. Child prompts and output
    stay on the terminal; stdout carries the action receipt. *)
val run : base_path:string -> dependency:string -> action:string option -> int

val run_terminal : string list -> (unit, unit) result
(** Run an explicitly selected child with stdin and both outputs on the terminal. *)
