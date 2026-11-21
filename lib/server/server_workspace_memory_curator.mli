(** One serialized in-process Workspace Memory Curator owner per physical
    workspace.

    Drains pending Keeper ordinary and source-bound facts through its own
    lane, [Standalone_lane.Workspace_memory_curator], via
    {!Agent_core.Exact_output.execute_flow_once} (with declared CLI
    fallback), writes two-phase {!Workspace_memory_log}
    commits, updates {!Workspace_memory_ledger} and
    {!Workspace_memory_briefing}, and notifies subscribed MCP clients via
    {!Mcp_server_eio_resource.notify_world_memory_updated}. *)

val start : sw:Eio.Switch.t -> config:Workspace.config -> unit
(** Start one serialized daemon owner for the resolved physical workspace
    under [sw], recover any incomplete {!Workspace_memory_log} batches, and
    subscribe to Keeper memory commits and to registry updates of its own
    lane. Without a table for that lane the owner asks no model: declaring
    the Librarian's Memory lane does not start it. No-op when an owner for
    that physical workspace already runs. *)

val retry_pending_observations : base_path:string -> unit
(** The maintenance tick. Wake an existing owner, as a tick, only when its
    prior pass left something for the tick: a classification that waits for a
    slot that said nothing ([Lane_silent]), a registry replacement in
    progress, a failure of masc's own, or a briefing that waits for a slot
    that has not refused its request or that failed. A tick pass asks the
    waiting facts again with the new ones, and the briefing's request of the
    slots that have not refused it. A briefing request every slot refused
    does not wait for the tick. Shutdown owners stay stopped. *)

type refresh = Queued | No_owner | Unavailable of string

val request : base_path:string -> refresh
(** Resolve the physical workspace off-domain and queue one drain cycle on its
    existing owner without running model or storage work in the caller. The
    classification and briefing memories start over in a new generation: the
    facts set aside and the briefing request every slot refused are asked
    again, and a pass in flight writes nothing more. *)

(** Why a classification pass asked no slot. *)
type lane_standing =
  | Not_published of Runtime_exact_output_registry.publication_error
  | Not_resolved of Runtime_exact_output_registry.lane_resolution_error
      (** No table for the lane, the lane is off, or no slot of it was
          accepted. *)
  | Replacement_in_progress

(** The step of a classification pass at which masc itself failed. *)
type host_step =
  | Reading  (** The Keepers' stores, the ledger, or the reconciled ledger and its log. *)
  | Preparing  (** The request: the prompt or the neighbor index. *)
  | Walking  (** No Eio context, or masc's own failure stopped the walk. *)
  | Recording  (** The answer into the ledger and its log. *)
  | Deciding  (** The narrowing refused a request the pass did not give. *)

(** How a classification pass ended (RFC
    curator-narrows-a-refused-batch-and-sets-a-refused-fact-aside §4.6). *)
type step_end =
  | Nothing_pending  (** The ledger holds a disposition for every fact. *)
  | Not_asked of lane_standing
  | Drained  (** Every pending fact was classified or is set aside. *)
  | Lane_silent
      (** A batch met only slots that said nothing, or a fact waits for a
          slot that has not refused it. *)
  | Host_failed of host_step * string  (** The text is shown only. *)

module For_testing : sig
  type idle_checkpoint
  type idle_result = Owner_idle of idle_checkpoint | Owner_stopped | Owner_missing
  type snapshot =
    { pending : bool
    ; in_flight : bool
    ; observation_retry : bool
    ; stopped : bool
    ; idle_waiters : int
    ; classification : step_end option  (** [None] before the first pass ends. *)
    ; set_aside : Workspace_memory_ledger.fact_ref list
    }

  val snapshot : base_path:string -> snapshot option
  (** [None] means there is no owner for this physical workspace. *)

  val await_idle : ?after:idle_checkpoint -> base_path:string -> unit -> idle_result
  (** Atomically check idle and subscribe under the owner's mutex. *)

  val is_idle : base_path:string -> bool
  val stop : base_path:string -> unit
end
