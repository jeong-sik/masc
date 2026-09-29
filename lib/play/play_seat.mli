(** Who sits at the shared machine (RFC play-link-for-the-shared-machine
    §2.6, §2.8): the names a player can hand the controller to. *)

val keeper_names : Workspace.config -> (string list, string) result
(** The persisted fleet and the keepers declared in TOML that have not booted
    yet, sorted and deduplicated. A fleet that does not list is an [Error],
    not an empty fleet. *)

val participants : base_path:string -> keepers:string list -> now:float -> string list
(** [keepers], every operator ([Admin] credential) and every invite ([Player]
    credential) that has not expired, sorted and deduplicated. [Worker]
    credentials are agents' MCP clients, not seats at the machine. *)
