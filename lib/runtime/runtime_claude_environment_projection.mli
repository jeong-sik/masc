(** The environment of a Claude Code child. *)

(** The names a child takes from the environment of the server. With
    [explicit_account] the child takes no credential name: its account is the
    declared directory. *)
val inherited_names : explicit_account:bool -> string list

(** The environment of the child: [inherited] and the switches every child of
    MASC gets. For a declared [account_home] it also holds
    [CLAUDE_CONFIG_DIR=<account_home>] and
    [ANTHROPIC_CONFIG_DIR=<account_home>/anthropic]. The second is the
    directory where Claude Code keeps what it keeps outside
    [CLAUDE_CONFIG_DIR]: the profiles of the [ant] CLI and of workload
    identity federation, and a Console sign-in made without an API key. So
    the child reads no profile of the server's OS user and none of another
    declared account. [inherited] names neither variable when the account is
    declared ({!inherited_names}). *)
val of_inherited : account_home:string option -> string list -> string array
