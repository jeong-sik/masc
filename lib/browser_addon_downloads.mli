(** Completed Gecko downloads copied into the original worker allocation.
    This broker never reads caller-supplied paths. Blocking operations belong
    in a system thread; no browser or model work is performed here. *)
type t
type descriptor = {
  snapshot_id : string;
  root_device : int;
  root_inode : int;
  device : int;
  inode : int;
  bytes : int;
  sha256 : string;
}
type claim = Snapshot of descriptor | Published of Yojson.Safe.t
val claim_to_json : claim -> Yojson.Safe.t
val claim_of_json : Yojson.Safe.t -> (claim, string) result
val snapshot_path : directory:string -> snapshot_id:string -> (string, string) result
(** Derive [directory/download-snapshots/<canonical UUID>.bin]. The host must
    independently pin its original allocation and verify the claimed descriptor
    before importing; a worker response never supplies a pathname. *)
val create : directory:string -> (t, string) result
(** Pin the canonical private allocation and create a fresh private broker
    root. Existing roots are refused rather than adopted. *)
val publish : t -> string -> (Yojson.Safe.t, string) result
(** Copy one completed, session-owned source with bounded streaming memory.
    The returned opaque snapshot marker may be cached by the BiDi connection.
    Original source identity and contents are checked across the copy. A
    post-copy refusal records the original, opened and final descriptor/path
    properties and copied byte count, without source paths or contents. The
    broker retains its read-only original descriptor until retirement. *)
val bind : t -> actor:string -> route:Browser_lane.route -> verb:Browser_lane.verb ->
  Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** Bind [Page_downloads] rows to this call, replacing private snapshot markers
    with fresh opaque grants and removing source paths. Only owned automation
    downloads are supported. A cached snapshot can be bound by later calls;
    every grant retains its exact actor, route and verb. *)
val claim : t -> id:string -> actor:string -> route:Browser_lane.route ->
  verb:Browser_lane.verb -> (claim, string) result
(** Fresh claims are refused after revocation. A matching publication already
    committed through this broker is returned without another file import.
    Re-reading an already settled grant is idempotent metadata lookup and does
    not acquire a new lifetime; ordinary calls always bind a fresh grant.
    Claims carry immutable snapshot metadata or a publication receipt, never
    a borrowed original-file descriptor. *)
val commit : t -> id:string -> actor:string -> route:Browser_lane.route ->
  verb:Browser_lane.verb -> receipt:Yojson.Safe.t -> (unit, string) result
(** Acknowledge the durable artifact for an exact existing claim. The receipt
    must name the snapshot's digest and byte count. Matching repeated commits
    are idempotent; conflicting receipts are refused, including after revoke.
    The original claim remains held until [release], including when [claim]
    returned an existing publication rather than a snapshot descriptor. *)
val release : t -> id:string -> actor:string -> route:Browser_lane.route ->
  verb:Browser_lane.verb -> (unit, string) result
(** Settle this exact claim without publication, including after revocation.
    This never authorizes another caller or deletes the original download. *)
val revoke : t -> unit
val abandon : t -> (unit, string) result
(** Revoke and join local snapshot preparations, then close private original-file
    descriptors without deleting files. Do not wait for outstanding claims:
    their holders may no longer run. Preserve their exact grant states so an
    existing holder can still commit and release after this call returns.
    Record unconfirmed backend teardown as a sticky cleanup failure. This
    cannot confer deletion authority later. *)
val cleanup : t -> (unit, string) result
(** Revoke new work and join local snapshot preparations. Call only after
    confirmed original backend teardown. Outstanding claimed or committed
    grants prevent deletion: return a sticky error without waiting for their
    holders or changing their states. Existing holders may still commit and
    release after this call returns; later settlement does not clear the error.
    Remove only broker snapshots and committed
    original sources whose pinned inode, owner, permissions and published bytes
    remain unchanged. Historical mtime/ctime may differ; the current properties
    must remain stable across content verification. Close all original-file
    descriptors on success or sticky failure. Unpublished,
    partial, replaced or unknown resources remain and cleanup reports error.
    A failed cleanup stays unconfirmed on later calls. Neither retirement path
    waits for remote claim settlement. *)
