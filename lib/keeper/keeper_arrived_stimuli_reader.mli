(** The queue reader of every arrived-row preview.

    {!Keeper_arrived_stimuli} opens no file: its caller passes the reader. The
    Agent Core post-tool round and the official-client tool result both pass
    this one, so a row one runtime withholds cannot be listed by the other. *)

val read :
  config:Workspace.config ->
  keeper_name:string ->
  unit ->
  (Keeper_event_queue_state.pending_selection list, string) result
(** The Keeper's pending queue rows that its model may be shown now: the rows
    {!Keeper_board_audience.can_project_queued_stimulus} allows for the
    Keeper's effective metadata. The metadata is read on every call, so a
    readership change during the run applies from the next round. Absent or
    unreadable metadata is [Error]: readership cannot be judged, and the caller
    lists nothing for that round. The queue is not changed. *)
