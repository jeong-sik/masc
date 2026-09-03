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

val refuse_reserved_command : Masc_exec.Shell_ir.t -> (Masc_exec.Shell_ir.t, string) result
(** The shell surface of a lane that has no turn: it refuses a line naming the
    reserved word and passes everything else through.

    An approved effect is replayed by the host, which has no descriptor lookup
    and no dispatch, so it cannot route. Before #32730 that lane passed no
    rewrite at all and the runtime's absent case ran the line as written --
    routing lives in the IR's sandbox field, so an unrouted [masc] line is not
    refused, it execs a host program of that name. *)

val rewrite :
  lookup:(string -> Keeper_tool_descriptor.t option) ->
  dispatch:dispatch ->
  Masc_exec.Shell_ir.t ->
  (Masc_exec.Shell_ir.t, string) result
(** Replace eligible standalone [masc] stages with delegated targets. *)
