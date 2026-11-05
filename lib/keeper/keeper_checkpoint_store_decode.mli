(** Reading a checkpoint file and decoding its head, with the errors that stop
    either step.

    [read_checkpoint_bytes] reads a file inside the owned chain below the
    parent of the session directory and reports a missing file as
    [Not_found]. [head_of_bytes_off_scheduler] and
    [decode_head_off_scheduler] decode a head, and for the second the messages
    it names, on the CPU pool instead of the calling fiber;
    [offload_checkpoint_cpu] runs any such conversion there.
    [classify_core_error] and [classify_objects_error] map the decoders'
    errors onto [checkpoint_load_error]. [load_agent_core_history_file] loads
    one history snapshot by name and answers a name that is not a single
    directory entry as [Not_found]. [Keeper_checkpoint_store] includes this
    module. *)

val offload_checkpoint_cpu : (unit -> 'a) -> 'a

val head_of_bytes_off_scheduler :
  string -> (Agent_core.Checkpoint_objects.head, Agent_core.Checkpoint_objects.load_error) result

val decode_head_off_scheduler :
  session_dir:string ->
  memo:Agent_core.Checkpoint_objects.memo ->
  string ->
  (Agent_core.Checkpoint_objects.head * Agent_core.Checkpoint.t, Agent_core.Checkpoint_objects.load_error) result

type checkpoint_read_failure =
  | Os_error of Unix.error
  | Changed_while_read
  | Read_raised

type checkpoint_load_error =
  | Not_found
  | Store_error of string
  | Parse_error of string
  (** A canonical this binary recognises as an earlier [checkpoint_version].
      Apart from [Parse_error] because the two need opposite answers: a
      superseded canonical is replaceable, a corrupt one is not. *)
  | Superseded_version of { expected : int; got : int }
  (** A canonical a *later* [checkpoint_version] wrote: an older binary is
      reading a newer workspace. Nothing here replaces or deletes it, because
      the newer binary can still read it. Only a writer that bumped the
      version is told apart this way (#38680). *)
  | Newer_version of { expected : int; got : int }
  | Io_error of string
  | Read_failed of { cause : checkpoint_read_failure; detail : string }
  (** Catch-all for agent-core errors outside the Io / Serialization families
      (Api / Agent / Mcp / Config / Orchestration / Internal).
      Distinct from Io_error so observers can tell a local
      checkpoint-store I/O failure apart from an agent-core failure that
      surfaced during a load. (#8605 family) *)
  | Agent_core_error of string
  | Objects_invalid of Agent_core.Checkpoint_objects.load_error
  (** The head names a message object or bundle that is missing, unreadable
      or not what the head says it is. *)

val classify_core_error : Agent_core_base.Error.t -> checkpoint_load_error

val classify_objects_error : Agent_core.Checkpoint_objects.load_error -> checkpoint_load_error

val read_checkpoint_bytes :
  session_dir:string -> string -> (string, checkpoint_load_error) result

val load_agent_core_history_file :
  session_dir:string ->
  snapshot_id:string ->
  (Agent_core.Checkpoint.t, checkpoint_load_error) result
