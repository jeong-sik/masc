(** Dashboard dev-token file and minting helpers for dashboard routes. *)

val dashboard_dev_token_path : string -> string
val ensure_dashboard_dev_token : string -> (string, string) result
