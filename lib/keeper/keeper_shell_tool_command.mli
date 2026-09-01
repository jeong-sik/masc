(** Converts declared [masc ...] shell stages into delegated typed-tool calls.

    The conversion owns no Keeper turn context. Its caller supplies only the
    descriptor lookup and typed dispatch functions needed by a delegated
    stage, keeping the Shell IR owner below [Keeper_tool_runtime] in the module
    dependency graph. *)

type runtime

val create_runtime :
  descriptor_for_internal:(string -> Keeper_tool_descriptor.t option) ->
  call:
    (descriptor:Keeper_tool_descriptor.t ->
     args:Yojson.Safe.t ->
     Keeper_tool_execution.t option) ->
  runtime

val split_words : string list -> (string * string list) option
(** Match literal words against the closed [shell_command] declaration table.
    The longest declared path wins. *)

val args_json_of_words :
  descriptor:Keeper_tool_descriptor.t ->
  string list ->
  (Yojson.Safe.t, string) result
(** Map positional words to the descriptor schema's required fields. *)

val rewrite :
  runtime:runtime ->
  Masc_exec.Shell_ir.t ->
  (Masc_exec.Shell_ir.t, string) result
(** Replace eligible [masc] stages with delegated targets. Refusals are typed
    pre-dispatch errors returned as [Error]. *)
