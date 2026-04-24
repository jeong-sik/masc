type t = latest:Keeper_types.keeper_meta -> caller:Keeper_types.keeper_meta -> Keeper_types.keeper_meta

let caller_wins ~(latest : Keeper_types.keeper_meta) ~(caller : Keeper_types.keeper_meta) =
  { caller with meta_version = latest.meta_version }

(* Heartbeat-owned fields, enumerated explicitly so a future compiler
   error in [sync_keeper_presence]/[ensure_keeper_room_presence]
   forces a reviewer to update this list too. *)
let heartbeat_fields_from_disk ~(latest : Keeper_types.keeper_meta) ~(caller : Keeper_types.keeper_meta) =
  {
    caller with
    meta_version = latest.meta_version;
    joined_room_ids = latest.joined_room_ids;
    last_seen_seq_by_room = latest.last_seen_seq_by_room;
  }
