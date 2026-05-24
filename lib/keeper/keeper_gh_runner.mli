(** Shared GitHub CLI runner for keeper GH tools.

    Public keeper tools own their JSON schemas and response envelopes; this
    module owns the common [gh] argv routing through the sandbox runner. *)

type result =
  { status : Unix.process_status
  ; output : string
  ; via : string
  ; error : string option
  }

val quote_argv : string list -> string

val run_argv :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  timeout_sec:float ->
  actor:Masc_exec.Agent_id.t ->
  summary:string ->
  env:string array option ->
  host_cwd:string ->
  route_cwd:string ->
  backend_cwd:(unit -> string) ->
  trust:Keeper_sandbox_runner.command_trust ->
  string list ->
  result
