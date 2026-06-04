(** Approval dispatch dependency inversion ref.

    [Tool_inline_dispatch] reads this ref so it does not statically import
    keeper approval queue modules.  Keeper composition code registers the
    backing dispatch implementation. *)

val dispatch : (name:string -> args:Yojson.Safe.t -> string option) ref
