(** Who sits at the shared machine (RFC play-link-for-the-shared-machine
    §2.6, §2.8): the names a player can hand the controller to. *)

val keeper_names : Workspace.config -> (string list, string) result
(** The persisted fleet and the keepers declared in TOML that have not booted
    yet, sorted and deduplicated. A fleet that does not list is an [Error],
    not an empty fleet. *)

val participants :
  base_path:string -> keepers:string list -> now:float ->
  (string list, Masc_domain.masc_error) result
(** [keepers] plus unexpired operator ([Admin]) and invite ([Player])
    credentials, sorted and deduplicated. [Worker]
    credentials are agents' MCP clients, not seats at the machine. Credentials
    come from current named authority; unavailable storage returns [Error]. *)

val hand_to : Workspace.config -> now:float -> (string list, string) result
(** The names a pass may hand the controller to: {!participants} over
    {!keeper_names}. [Error] when the fleet or the credentials do not list,
    since then nobody can say who sits at the machine. The play page lists these names and
    [masc_dos_pass] accepts only them. *)

val hand_to_in_transaction :
  transaction:Auth.credential_transaction -> Workspace.config -> now:float ->
  (string list, string) result
(** The same participant projection as {!hand_to}, without a second Auth
    admission. [transaction] must belong to [config]'s workspace. The caller
    keeps it through the actual controller handoff. *)
