(** Dashboard dev-token file and minting helpers for dashboard routes. *)

val dashboard_dev_actor_name : string
val dashboard_dev_token_path : string -> string
val legacy_dashboard_dev_token_path : string -> string
val remove_dashboard_dev_token_file_if_exists : string -> unit

type dashboard_dev_token_candidate =
  | Reusable of string
  | Rotate

val classify_dashboard_dev_token_candidate
  :  base_path:string
  -> string
  -> (dashboard_dev_token_candidate, string) result

val read_reusable_dashboard_dev_token
  :  base_path:string
  -> string
  -> (string option, string) result

val persist_dashboard_dev_token
  :  base_path:string
  -> string
  -> (unit, string) result

val mint_dashboard_dev_token : string -> (string, string) result
val ensure_dashboard_dev_token : string -> (string, string) result
