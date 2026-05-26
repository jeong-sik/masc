(** Runtime adapter for IDE annotation agent tools.

    @since 0.6.0 — observational IDE Phase 1 *)

val handle_ide_annotate :
  config:Coord.config ->
  keeper_name:string ->
  args:Yojson.Safe.t ->
  string
(** Handle [keeper_ide_annotate] tool call. Creates a line-bound
    annotation in the [.masc-ide/] store and returns the created
    record's id and coordinates on success, or an error message. *)
