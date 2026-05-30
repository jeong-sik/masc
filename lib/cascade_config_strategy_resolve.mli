(** Cascade strategy + concurrency resolution.

    Pulls {!Cascade_config_loader.strategy_config} fields and turns them
    into a typed {!Cascade_strategy.t} value.

    Extracted from [cascade_config.ml]. {!Cascade_config} re-exports
    every public binding here so external callers keep their existing
    API.

    @stability Internal *)

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
