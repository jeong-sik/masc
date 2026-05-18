(** Coord Worktree - Policy parsing & clone-origin validation.

    Read-only helpers around [tool_policy.toml]'s [git_clone] section
    and GitHub URL parsing.  No filesystem mutation. *)

val policy_string_array_of_line :
  key:string -> string -> string list option
(** Parse a TOML-ish [key = ["a", "b"]] line into a list of strings.
    Returns [None] when [key] doesn't match or the array is malformed. *)

val load_git_clone_policy :
  base_path:string -> string list * string list
(** Load [(allowed_orgs, denied_repos)] from [tool_policy.toml].  Canonical
    [<base_path>/.masc/config/tool_policy.toml] takes priority over legacy
    [<base_path>/config/tool_policy.toml].  Returns empty lists when the file
    is missing for compatibility. *)

val extract_github_org_repo : string -> string option
(** [extract_github_org_repo url] returns ["org/repo"] for any GitHub
    [https://] or [git@] URL, or [None] for non-GitHub URLs. *)

val extract_github_org : string -> string option
(** [extract_github_org url] returns the org slug for a GitHub URL. *)

val normalize_github_clone_url : string -> string
(** Normalise any recognised GitHub URL to [https://github.com/<org>/<repo>.git].
    Returns the input unchanged when it is not a GitHub URL. *)

val validate_clone_origin_url :
  base_path:string -> string -> (unit, string) result
(** Validate [origin_url] against the policy at [base_path]. *)
