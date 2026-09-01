(** Convert declared [masc ...] shell stages into delegated typed-tool calls.

    This module owns no Keeper turn context. The runtime supplies descriptor
    lookup and typed dispatch as closures, keeping the dependency graph
    acyclic. *)

type dispatch =
  descriptor:Keeper_tool_descriptor.t ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t option

val split_words : string list -> (string * string list) option
(** Match literal words against the closed [shell_command] declaration table.
    The longest declared path wins. *)

val args_json_of_words :
  descriptor:Keeper_tool_descriptor.t ->
  string list ->
  (Yojson.Safe.t, string) result
(** Map positional words to the descriptor schema's required fields. *)

val rewrite :
  lookup:(string -> Keeper_tool_descriptor.t option) ->
  dispatch:dispatch ->
  Masc_exec.Shell_ir.t ->
  (Masc_exec.Shell_ir.t, string) result
(** Replace eligible standalone [masc] stages with delegated targets. *)
