(** Git clone policy helpers used by [Tool_code_write]. *)

val reset_policy_config_cache : unit -> unit
(** Clears the cached tool-policy config. Test isolation seam. *)

val get_policy_config : base_path:string -> Keeper_tool_policy_config.t option
(** Loads the resolved tool-policy config for [base_path], returning [None] when
    policy loading fails. *)

val extract_github_org : string -> string option
(** Parses the GitHub organization segment from a supported clone URL. *)

val extract_github_org_repo : string -> string option
(** Parses ["org/repo"] from a supported clone URL. *)

val canonical_github_https_clone_url : string -> string option
(** Converts supported GitHub clone URLs to canonical HTTPS form. *)

val normalize_github_clone_url : string -> string
(** Returns the canonical HTTPS URL when the input is supported, otherwise the
    original input. *)

val validate_clone_url : base_path:string -> string -> (unit, string) Result.t
(** Validates clone URL policy against [tool_policy.toml]. *)
