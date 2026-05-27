(** {1 Path resolution} *)

val resolve_tool_read_cwd :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result

val resolve_tool_write_cwd :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result

val auto_correct_path :
  meta:Keeper_types.keeper_meta -> string -> string option
(** Auto-correct common LLM-hallucinated path prefixes
    ([/repos/…], [repos/…], [playground/…]) into the keeper's
    real playground bundle path.  Sanitization of [meta.name]
    happens through {!Playground_paths}. *)

val resolve_tool_read_path :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  (string, string) result
(** Resolve the [path] arg against the keeper's read root, with
    {!auto_correct_path} as a fallback when the initial resolution
    fails.  Guards against playground-prefix doubling when both
    [cwd] and [path] independently include the playground prefix. *)

val shell_command_available : string -> bool
(** PATH executable probe for workspace read fallback selection.
    This intentionally avoids [/bin/sh -c] and does not treat empty
    PATH entries as the current directory. *)

val in_playground :
  root:string -> cwd:string -> meta:Keeper_types.keeper_meta -> bool
(** [true] when [cwd] is inside the keeper's sandbox playground,
    or equal to it.  Normalises both paths before comparison so that
    trailing slashes do not affect the result. *)
