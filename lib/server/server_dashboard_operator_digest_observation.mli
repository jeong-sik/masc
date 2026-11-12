(** Captured workspace owner of the default Operator Digest observation.

    The canonical [operator_digest] payload retains the existing digest and
    query metadata, adding [observer_instance_id],
    [digest_publication_generation], [digest_publication_sequence], and
    [digest_observation_state] ([initializing], [ready], [error]). Failures
    retain this owner's last-good rows with error diagnostics. Parameterized
    HTTP computations must not install their rows into this default owner. *)

type owner
type attempt
type origin = Source_read | Default_request
type completion = Installed of origin | Failed of origin | Invalidated
type publication_status = Current | Superseded | Source_pending | Retired

type publication = {
  json : Yojson.Safe.t;
  source : Server_dashboard_http_cache.surface_snapshot;
  generation : int;
}

val owner_for_scope :
  state:Mcp_server.server_state -> Mcp_server.workspace_scope -> owner
(** A retired lookup gets a private owner; it cannot replace the current
    workspace cache. All admission/publication guards are non-I/O. *)

val cache : owner -> Server_dashboard_http_cache.cached_surface
val is_current : owner -> bool
val has_observation : owner -> bool
(** Complete and partial retained bodies satisfy the cold HTTP read; a failed
    read with no body does not. GET cannot bypass partial-read retry backoff. *)
val has_terminal_answer : owner -> bool
(** A current-scope actual read has completed or failed. A no-result error
    answers default GET without bypassing the source worker's failure retry;
    it does not become a successful observation. A new owner is still cold. *)
val begin_attempt : owner -> origin:origin -> attempt
val publish_observation : attempt -> Dashboard_projection_cache.digest_observation -> bool
val publish_failure_message : attempt -> string -> bool
(** Admit only the captured scope and ordered attempt. Source notices during
    a read leave trailing debt without discarding its completed observation.
    Generation fences prepared payloads, not atomic source coherence. The same
    successful attempt cannot later publish a timeout failure. Partial reads
    install readable rows in [error] state without stamping full success. *)

val invalidate : owner -> unit
(** Fence already prepared payloads and notify coalesced trailing read debt. *)
val next_deadline_unix : owner -> float option
val subscribe_completed : owner -> (completion -> unit) -> (unit -> unit)
(** Synchronous, non-I/O metadata only; listeners may enqueue bounded debt.
    Listener exceptions cannot replace the original completion or cancellation. *)

val publication : owner -> publication
val publication_status : owner -> publication -> publication_status
val publication_is_current : owner -> publication -> bool
(** [Source_pending] means no read has completed since the latest input notice.
    An older preparation is [Superseded] after the current read has settled,
    preserving bounded publication debt without a source-pending busy loop. *)

val cache_identity : owner -> string
(** Captured process/workspace/source incarnation for HTTP cache keys. *)
