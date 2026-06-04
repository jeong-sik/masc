(** Keeper name validation.

    Small SSOT for keeper/persona handle syntax so persona authoring does not
    need to depend on the full [Keeper_config] runtime/config surface. *)

val validate : string -> bool
