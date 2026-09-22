(** [masc runtime-client-path]: where an official client runs from, as the
    runtime will spawn it ({!Runtime_official_cli_install.locate}). The
    setup wizard asks this instead of looking for the client itself, so its
    list, its selection and the runtime's verification agree (masc #37747).
    Prints one JSON object on stdout and returns the exit code. *)

val client_arg : Runtime_official_cli_install.client Cmdliner.Arg.conv
(** [claude-code], [codex] or [antigravity]: the dependency names
    [prerequisite-actions] takes. *)

val to_json
  :  client:Runtime_official_cli_install.client
  -> command:string
  -> path:string option
  -> Yojson.Safe.t
(** [{"schema": "masc.runtime_client_path.v1", "client", "command", "path"}];
    [path] is [null] when the client is nowhere. *)

val run : client:Runtime_official_cli_install.client -> command:string option -> int
(** [command] defaults to the client's own name. *)
