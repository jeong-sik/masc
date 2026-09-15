(** Keeper_producer_route — whether a completion verdict about a Task has a
    Keeper queue to go to.

    A Task's assignee is a free-form agent name. It is a Keeper when a live
    registry entry carries it, or when a Keeper meta file sits at its
    canonical path; an MCP client that claimed and submitted the Task (for
    example [codex-mcp-client]) has neither, and no queue under that name will
    ever be read.

    Both verdict deliveries resolve the assignee here:
    {!Completion_authority_wakeup} for a rejection and
    {!Keeper_task_outcome_wake} for an approval. *)

type t =
  | Keeper of string
      (** The Keeper's name: the live registry entry's, or the assignee's
          own when only its meta file exists (a stopped Keeper). *)
  | No_keeper
      (** No live registry entry, and nothing at the Keeper meta path. *)

val resolve :
  config:Workspace_utils_backend_setup.config -> string -> (t, string) result
(** [Error] when a file is at the meta path but this binary does not decode
    it, or the read fails. That Keeper exists and the boot path
    re-materialises its meta, so the answer is "not now", never
    {!No_keeper}. *)

val has_no_queue_without_writing :
  config:Workspace_utils_backend_setup.config -> string -> bool
(** [true] exactly when there is no registry entry and no file at the Keeper
    meta path. For callers that must not write: {!resolve} repairs an
    off-canon meta in place, which is a durable rewrite and an fsync of
    another Keeper's file, and a caller holding a lease-backed lock cannot
    afford one.

    Every answer other than "no file" is [false]. A meta this decoder will not
    read might still be a Keeper, and treating it as one costs a skipped
    release and a kept obligation, which the next interval retries. The other
    direction releases a task on a guess. *)
