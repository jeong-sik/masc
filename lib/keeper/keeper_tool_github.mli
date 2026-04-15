(** Keeper GitHub primitive — atomic gh CLI wrapper with hallucination gate.

    Gate and shared helpers live in {!Keeper_gh_shared}. *)

val handle_keeper_github :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
