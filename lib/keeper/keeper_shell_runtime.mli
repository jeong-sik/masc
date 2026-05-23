(** Runtime helpers for keeper shell ops.

    Extracted from [keeper_shell_ops.ml] to make op handlers
    independently extractable.  All functions take previously-captured
    variables as explicit parameters. *)

val coreutils : Host_config.coreutils

(** {1 Render helpers (from [Keeper_shell_render])} *)

val render_process_result :
  root:string ->
  keeper_name:string ->
  op:string ->
  ?cwd:string ->
  cmd:string ->
  string list ->
  string

val render_completed_process_result :
  root:string ->
  keeper_name:string ->
  op:string ->
  ?cwd:string ->
  cmd:string ->
  ?extra:(string * Yojson.Safe.t) list ->
  Unix.process_status ->
  string ->
  string

val render_docker_process_result :
  root:string ->
  keeper_name:string ->
  op:string ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  cwd:string ->
  cmd:string ->
  docker_cmd:string ->
  timeout_sec:float ->
  string

(** {1 Turn-runtime path helpers} *)

val rewrite_turn_runtime_paths_to_host :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> string -> string

val hostify_turn_runtime_output :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> string -> string

(** {1 Docker read helpers} *)

val docker_git_log_path :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> string -> (string, string) result

(** {1 Git log helpers} *)

val git_log_argv_core :
  format:string -> count:int -> grep:string -> ?file_path:string -> ?cwd:string -> unit -> string list

val git_log_response_json :
  ok:bool ->
  op:string ->
  cwd:Yojson.Safe.t ->
  count:int ->
  grep:string ->
  ?via:string ->
  status:Unix.process_status ->
  output:string ->
  limit:int ->
  Yojson.Safe.t

(** {1 Target validation} *)

val containment_check :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> string -> (unit, string) result

val repo_check :
  keeper_id:string -> base_path:string -> string -> (unit, string) result

val validate_resolved_path :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> base_path:string -> string -> (unit, string) result

val read_target :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> args:Yojson.Safe.t -> root:string -> (string, string) result

val cwd_target :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> args:Yojson.Safe.t -> root:string -> (string, string) result

val path_error :
  op:string -> meta:Keeper_types.keeper_meta -> raw_path:string -> string -> string

val with_read_target :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  root:string ->
  op:string ->
  raw_path:string ->
  (string -> string) ->
  string

val with_cwd_target :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  root:string ->
  op:string ->
  raw_path:string ->
  (string -> string) ->
  string

(** {1 Readonly-op JSON response builders} *)

val readonly_json_fields :
  ?ok_when:(Unix.process_status -> bool) ->
  op:string ->
  path:string ->
  via:string ->
  status:Unix.process_status ->
  output_field:string ->
  output:Yojson.Safe.t ->
  ?extra:(string * Yojson.Safe.t) list ->
  unit ->
  (string * Yojson.Safe.t) list

val readonly_json_string : (string * Yojson.Safe.t) list -> string

(** {1 Unified execution helpers} *)

val run_readonly_op :
  ?ok_exit_codes:int list ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  op:string ->
  target:string ->
  host_argv:string list ->
  docker_argv:(string -> string list) ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  (string * Unix.process_status * string, string) result

val run_cwd_op :
  root:string ->
  keeper_name:string ->
  op:string ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  cwd:string ->
  cmd:string ->
  ?map_output:(string -> string) ->
  command_argv:string list ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  string

(** {1 Op-specific readonly helpers} *)

val run_ls_op :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  op:string ->
  target:string ->
  limit:int ->
  timeout_sec:float ->
  unit ->
  string

val run_cat_op :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  op:string ->
  target:string ->
  max_bytes:int ->
  timeout_sec:float ->
  unit ->
  string

val run_head_tail_op :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  op:string ->
  target:string ->
  n:int ->
  timeout_sec:float ->
  unit ->
  string

val run_tree_op :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  op:string ->
  target:string ->
  limit:int ->
  timeout_sec:float ->
  unit ->
  string

val run_wc_op :
  root:string ->
  keeper_name:string ->
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  op:string ->
  target:string ->
  timeout_sec:float ->
  unit ->
  string

val run_readonly_json_op :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  op:string ->
  target:string ->
  host_argv:string list ->
  docker_argv:(string -> string list) ->
  ?max_bytes:int ->
  ?ok_exit_codes:int list ->
  ?ok_when:(Unix.process_status -> bool) ->
  timeout_sec:float ->
  output_field:string ->
  output_of_out:(string -> Yojson.Safe.t) ->
  ?extra:(string * Yojson.Safe.t) list ->
  unit ->
  string
