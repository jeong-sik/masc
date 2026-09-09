(** Connection-only configuration projection for an isolated readiness client.
    No inherited MCP servers, plugins, hooks, skills, or instructions are copied. *)
val project_config : ?disabled_mcp_servers:string list -> string -> (string, string) result
val prepare : directory:string -> (string, string) result
(** Create a private CODEX_HOME under the caller-owned ephemeral directory. Copies
    auth.json if present; never copies or changes the original configuration.
    Keyring-only credentials are not extracted into files by verification. *)

val cli_overrides : home:string -> string list
(** Explicit CLI overrides prevent system or ancestor layers re-enabling tools. *)
