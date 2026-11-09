type account_action = Import_current | Sign_in | Use_reference of string

(** Each command publishes the account access of this host tool for
    [base_path] first, and starts Antigravity only when the workspace is a
    single user (multi-account plan D3b). *)
val account : base_path:string -> cli_path:string -> timeout_s:float -> action:account_action -> int
val models : base_path:string -> cli_path:string -> timeout_s:float -> oauth_source:string -> int
val context :
  base_path:string -> python_path:string -> cli_path:string -> timeout_s:float ->
  oauth_source:string -> model_id:string -> int
