(** Board persistence paths and JSONL rotation policy.

    All paths are derived from [Env_config_core.base_path] +
    [Env_config_core.cluster_name] via [Coord_utils.masc_root_dir_from],
    so they reflect the active cluster at call time. *)

val board_base_path : unit -> string
val board_masc_dir : unit -> string
val persist_path : unit -> string
val comments_path : unit -> string
val reactions_path : unit -> string
val sub_boards_path : unit -> string
val ensure_dir : string -> unit
val ensure_masc_dir : unit -> unit
val max_jsonl_bytes : int
val rotate_if_needed : string -> unit
