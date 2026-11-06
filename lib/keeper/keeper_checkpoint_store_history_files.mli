(** The history snapshots a session directory keeps next to the canonical
    AGENT_CORE checkpoint file, and the paths of both.

    A snapshot is named by the creation time of its checkpoint
    ([agent_core_history_snapshot_id_of_created_at]).
    [save_agent_core_history] makes one as a hardlink of the canonical file,
    or writes the head bytes when the link fails, then prunes the directory to
    the retention window its caller passes in.
    [delete_agent_core_history_files] and
    [delete_all_agent_core_history_files] remove snapshots by name and refuse
    names that are not snapshot files. [leaf_is_real_segment] says whether a
    name stays below the directory it is joined to.
    [Checkpoint_payload_writer] counts the bytes a save submits.
    [before_history_link_hook] runs before the hardlink; the test seam
    [Keeper_checkpoint_store.For_testing.with_before_history_link] sets it.
    [Keeper_checkpoint_store] includes this module. *)

val agent_core_checkpoint_path :
  session_dir:string -> session_id:string -> string

val before_history_link_hook : (unit -> unit) option Atomic.t

val list_agent_core_history_files : session_dir:string -> string list

val agent_core_history_path :
  session_dir:string -> snapshot_id:string -> string

val leaf_is_real_segment : string -> bool

val agent_core_history_snapshot_id_of_created_at : float -> string

val agent_core_history_snapshot_id_of_checkpoint :
  Agent_core.Checkpoint.t -> string

module Checkpoint_payload_writer :
  sig
    type t = Unmeasured | Measured of (int option -> unit)
    val note : t -> int option -> unit
    val count_pieces : string list -> int option
    val canonical :
      t ->
      write:(ownership_root:'a ->
             'b -> (unit -> string list) -> ('c, 'd) result) ->
      ownership_root:'a -> 'b -> (unit -> string list) -> ('c, 'd) result
    val archive : t -> string -> string -> (unit, string) result
  end

val save_agent_core_history :
  payload_writer:Checkpoint_payload_writer.t ->
  session_dir:string ->
  retained:int -> head_bytes:string -> Agent_core.Checkpoint.t -> unit

type history_delete_result =
  | History_deleted of string
  | History_missing of string
  | History_refused of string
  | History_removal_failed of string

val delete_agent_core_history_files :
  session_dir:string ->
  snapshot_ids:string list -> history_delete_result list

type history_cleared =
  { removed : int
  ; left : string list
  }

val delete_all_agent_core_history_files :
  session_dir:string -> (history_cleared, string) result
