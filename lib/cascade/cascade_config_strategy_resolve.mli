(** Cascade strategy + priority-tier + concurrency resolution.

    Pulls {!Cascade_config_loader.strategy_config} fields and turns them
    into a typed {!Cascade_strategy.t} value. Owns the priority-tier
    normalization that maps the raw tier matrix against the configured
    candidate model ids.

    Extracted from [cascade_config.ml]. {!Cascade_config} re-exports
    every public binding here so external callers keep their existing
    API.

    @stability Internal *)

val normalize_priority_tiers :
  config_path:string ->
  name:string ->
  string list list ->
  (string list list, string) result

val resolve_strategy :
  ?config_path:string ->
  name:string ->
  unit ->
  Cascade_strategy.t

val resolve_ollama_max_concurrent :
  ?config_path:string ->
  name:string ->
  unit ->
  int option

val resolve_cli_max_concurrent :
  ?config_path:string ->
  name:string ->
  unit ->
  int option
