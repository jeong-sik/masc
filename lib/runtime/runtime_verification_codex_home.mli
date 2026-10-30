(** Connection-only configuration projection for an isolated readiness client.
    No inherited MCP servers, plugins, hooks, skills, or instructions are copied. *)
val project_config : ?disabled_mcp_servers:string list -> string -> (string, string) result
val auth_path : codex_home:string -> string
(** Where Codex keeps a file-backed login under [codex_home] (its [CODEX_HOME]). *)

val prepare : ?source_home:string -> directory:string -> unit -> (string, string) result
(** Create a private CODEX_HOME under the caller-owned ephemeral directory. Copies
    auth.json if present; never copies or changes the original configuration.
    Keyring-only credentials are not extracted into files by verification. *)

val cli_overrides : home:string -> string list
(** Explicit CLI overrides prevent system or ancestor layers re-enabling tools. *)

val credentials_store_key : string
val credentials_store_file : string
(** The Codex [config.toml] setting that keeps the login in [auth.json] under
    [CODEX_HOME] instead of the OS keyring:
    the setting assembled from [credentials_store_key] and [credentials_store_file].
    Verification homes set
    it, and the TUI account form asks the operator to set it in a new home. *)
