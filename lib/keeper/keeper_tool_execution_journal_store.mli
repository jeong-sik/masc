(** The journal file of a prepared run: how it is read, updated, prepared and
    loaded.

    [source], [source_observation], [worker_source] and
    [worker_source_observation] read those parts of an open journal or a
    worker. [validate_owned_path] checks that a path stays under an owned
    root, and [filesystem] turns a filesystem failure into [Persistence_failed]
    and lets a cancellation through. [read_manifest], [frozen_plan] and
    [validate_artifacts] read and check the artifacts a source refers to.
    [strict_read] reads the state of a journal file, and [check_source] checks
    that a state holds the source of an open journal. [update_existing] and
    [update_existing_with_bytes] run a decision over the current state of an
    existing journal and write the bytes it returns. [prepare] creates the
    journal of a source. [load] opens the journal of an existing run and
    checks its artifacts; [load_authority] and [load_authority_state] open it
    without that check, and the latter also returns its state.
    [entry_matches_source] and [validate_request] check an async entry against
    a source or a journal, and [canonical_queued] checks that a request id is
    a canonical queued request of the source.
    [Keeper_tool_execution_journal] includes this module. *)

open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_model

val source : t -> source

val source_observation : t -> source_observation option

val worker_source : worker -> source

val worker_source_observation : worker -> source_observation option

val validate_owned_path :
  root:string ->
  path:string ->
  create:bool ->
  (unit, error) result

val filesystem :
  (unit -> ('a, error) result) ->
  ('a, error) result

val read_manifest :
  base_path:string ->
  Tool_output.artifact_ref ->
  (Yojson.Safe.t, error) result

val frozen_plan :
  base_path:string ->
  source ->
  (Yojson.Safe.t, error) result

val validate_artifacts :
  base_path:string ->
  source ->
  (unit, error) result

val strict_read :
  root:string ->
  string ->
  (state,
   error)
  result

val check_source :
  t ->
  state ->
  (unit, error) result

val update_existing_with_bytes :
  t ->
  (string ->
   state ->
   string option *
   ('a, error) result) ->
  ('a, error) result

val update_existing :
  t ->
  (state ->
   string option *
   ('a, error) result) ->
  ('a, error) result

val prepare : ?observation:source_observation -> base_path:string -> source -> (t, error) result

val load_authority_state :
  base_path:string ->
  keeper_name:string ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  (t *
   state,
   error)
  result

val load_authority :
  base_path:string ->
  keeper_name:string ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  (t,
   error)
  result

val load :
  base_path:string ->
  keeper_name:string ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  (t,
   error)
  result

val entry_matches_source :
  source ->
  Keeper_msg_async.entry -> (unit, string) result

val validate_request : t -> Keeper_msg_async.entry -> (unit, error) result

val canonical_queued :
  t ->
  string -> (unit, error) result
