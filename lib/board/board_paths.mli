(** Board persistence paths and JSONL rotation policy.

    Unbound path helpers are derived from [Env_config_core.base_path] +
    [Env_config_core.cluster_name] via [Workspace_utils.masc_root_dir_from],
    so they reflect the active cluster at call time. Bound store loads use
    the workspace directory captured before their global store was loaded. *)

val board_base_path : unit -> string
val board_masc_dir : unit -> string
type persisted_file = Posts | Comments | Reactions | Sub_boards | Votes
val file_path : workspace_masc_dir:string -> persisted_file -> string
val store_file_path : Board_types.store -> persisted_file -> string
(** Bound stores use their captured workspace for every load. Standalone stores
    use the current configured workspace. *)
val persist_path : unit -> string
val comments_path : unit -> string
val reactions_path : unit -> string
val sub_boards_path : unit -> string
val ensure_dir : string -> unit
val ensure_masc_dir : unit -> unit
val max_jsonl_bytes : int
val rotate_if_needed : string -> unit
