(** Execute only the operator-selected native action. Child prompts and output
    stay on the terminal; stdout carries the action receipt. *)
val run : dependency:string -> action:string option -> int
