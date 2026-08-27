(** Per-keeper on/off switch for an attached outside service.

    Detach does not exist, and would be the wrong tool if it did: it burns
    the consent, and getting the service back means walking OAuth again. An
    operator who is nervous about a keeper's Jira for an afternoon needs a
    switch, not a divorce. Off keeps the token and the written catalog and
    simply stops the keeper's turns from being handed that provider's tools;
    on hands them back on the next turn.

    Fresh-state contract: no file means every attached service is on. A row
    in [identity/disabled.json] means that (keeper, provider) is off. An
    unreadable file is an error, never an empty list — reading it as
    "nothing is off" would hand a keeper the tools an operator turned off.

    The switch sits in front of the durable Gate, not instead of it: a
    provider that is on still has its writes decided by
    {!Keeper_identity_gate}. Off is for "do not even offer it". *)

type off_row = {
  keeper_name : string;
  provider_id : string;
  actor : string;
  changed_at : string;
}

val path : base_path:string -> string
(** [identity/disabled.json] under the workspace runtime root. *)

val disabled_rows : base_path:string -> (off_row list, string) result
(** Every switch an operator has thrown, in the order they were thrown. *)

val is_disabled :
  base_path:string ->
  keeper_name:string ->
  provider_id:string ->
  (bool, string) result

val disabled_providers_for_keeper :
  base_path:string -> keeper_name:string -> (string list, string) result

val set :
  Workspace.config ->
  actor:string ->
  keeper_name:string ->
  provider_id:string ->
  enabled:bool ->
  (unit, string) result
(** Throw or clear one switch, atomically, with an audit record. Setting the
    state it already has writes nothing. [enabled:true] removes the row
    rather than storing a synonym for "on", so the file is also the list of
    switches actually thrown. *)
