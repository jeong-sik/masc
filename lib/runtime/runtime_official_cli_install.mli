type client = Codex | Claude | Antigravity
val name : client -> string
val source_url : client -> string

(** {1 Where a client runs from}

    One lookup for the three official clients. The runtime spawns what it
    answers ({!Runtime_adapter}), the vendor installer checks its result with
    it, and the setup wizard shows and stores it ([masc runtime-client-path]),
    so the list, the selection, the verification and the turn agree on
    whether a client is there (masc #37747). *)

(** Where [command] runs from for [client], or [None] when it is nowhere.
    - [command] with a directory part is a path: it is answered as given
      when it is an executable regular file.
    - Otherwise the first PATH directory holding it, the way the shell finds
      it, so [masc] runs the same client the operator's terminal runs.
    - Otherwise, when [command] is the client's own name ({!name}), the
      directory the vendor installer writes to: [CODEX_INSTALL_DIR] for Codex
      when set, else [~/.local/bin]. A shell whose PATH does not hold that
      directory yet -- the one the installer was run from -- still finds the
      client. A custom command name is not looked for there.
    A link is answered as the link, never its target: the Claude Code
    installer keeps [~/.local/bin/claude] as a link into a versioned
    directory that an update replaces. Reads PATH, HOME and CODEX_INSTALL_DIR
    from the process environment at the call. *)
val locate : client -> command:string -> string option

(** {!locate} for the client's own name. *)
val executable : client -> string option

(** What to spawn for a configured [command]: {!locate}'s answer, or
    [command] as configured when nothing is found, so that the spawn's own
    error names what was asked for. *)
val spawn_path : client -> command:string -> string

val install : run:(string list -> (unit, string) result) -> client -> (unit, string) result
(** Execute only after explicit selection. Downloads the documented vendor script
    over HTTPS into a private temporary directory, runs it as the current user,
    then checks the installed executable's version. This is not account/model
    verification or an independently pinned binary publisher attestation. The
    injected terminal runner must preserve interactive input and route stdout
    away from any machine-readable receipt. *)
