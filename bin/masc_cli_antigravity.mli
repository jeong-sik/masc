type account_action = Import_current | Sign_in | Use_reference of string
val account : base_path:string -> cli_path:string -> timeout_s:float -> action:account_action -> int
val models : cli_path:string -> timeout_s:float -> oauth_source:string -> int
