(** Current metrics-ledger tool audit for operator control snapshots. *)

type tool_audit =
  { recent_tool_names : string list
      (** Distinct tool names of the newest turns, newest first. *)
  ; latest : Keeper_status_metrics.tool_audit_snapshot
      (** The newest recorded turn; the empty snapshot when the store holds
          no turn row. *)
  }

(** What one read of a Keeper's tool audit produced. An audit that was read
    and holds no tool call is [Read] with empty fields; [Unreadable] says
    nothing about what the Keeper called. *)
type read =
  | Read of tool_audit
  | Unreadable of string
      (** The metrics store could not be read. The text is diagnostic data;
          consumers branch on the constructor. *)

val read :
  Workspace.config
  -> Keeper_meta_contract.keeper_meta
  -> newest_lines:(string list, Dated_jsonl.read_error) result
  -> read
(** The audit the Keeper's metrics store holds now. [newest_lines] is what
    {!Keeper_status_metrics.newest_metrics_lines_result} answered for the
    Keeper: a Keeper row asks that once and gives the answer to this read and
    to its recent activity. The newest turn's audit is read here
    ({!Keeper_status_metrics.latest_tool_audit_snapshot_from_files}).

    Both are facts of the store. One the store holds is answered from
    memory. One it does not hold is read from the store's files: once, when
    the process keeps facts and the read succeeds, and on every call
    otherwise (a process that keeps none, or a store the strict read
    refuses). The read has no cache of its own and takes no read policy. *)

val row_fields : read -> (string * Yojson.Safe.t) list
(** The audit fields of an operator snapshot Keeper row. {!Keeper_status_metrics.tool_audit_read_field} carries the read state and
    {!Keeper_status_metrics.tool_audit_read_error_field} the diagnostic of an
    unreadable store. When the audit was not
    read, the six audit values are [null], not empty lists. *)

val completeness :
  keeper_name:string -> read -> Dashboard_projection_read.completeness
(** [Complete] for a read audit, [Partial] otherwise. *)
