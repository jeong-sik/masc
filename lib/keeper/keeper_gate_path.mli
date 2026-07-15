(** Single source of truth for Keeper Gate state below one workspace runtime
    root. Operator control-plane state is intentionally a separate owner. *)

val dir : base_path:string -> string
val mode : base_path:string -> string
val pending : base_path:string -> string
