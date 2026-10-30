(** Host-selected socket resource of a native browser installation. Blocking
    filesystem operations must be offloaded by the server caller. *)
type t
(** The one browser source an allocation's worker serves, with the browser it
    starts: an owned Gecko for automation, a Chrome for Stagehand, a live
    Firefox for the owned BiDi connection. Ego's settings ride the worker's
    arguments, and an external host worker starts no browser. *)
type source =
  | Automation of Browser_addon_automation.configuration
  | Stagehand of Browser_addon_stagehand.configuration
  | Owned_firefox of Browser_addon_live_bidi.configuration
  | Ego
  | External_host
val context : instance_id:string -> source:source ->
  models:Browser_addon_models.configuration option -> (Yojson.Safe.t, string) result
(** Selects a private per-instance socket directory without creating it. Persist
    this immutable descriptor through Native_addon_lease.prepare before mkdir. *)
val check_retained : instance_id:string -> slot:string -> Yojson.Safe.t option -> (unit, string) result
(** Read what {!cleanup} reads for [instance_id] in its installation [slot],
    without a claim, lock, creating or removing anything: the retained cleanup
    envelope and socket acquisition record in [slot]. An operator-retained
    allocation needs no backend decoding or child inspection: its resources
    belong to the operator. An explicit released record instead requires its
    original allocation path to be absent. Other states compare each Chrome
    and live BiDi child claim with its original descriptor. [None] permits no
    allocation record except an explicit released record. *)
val acquire : admission:Native_addon_lease.t -> directory:string -> (t, string) result
(** Before payload spawn, acquire the directory selected by the original native
    reservation and persist its exact identity in that host claim slot. *)
val socket_path : t -> string
val with_download_snapshot : t -> Browser_addon_downloads.descriptor ->
  (Unix.file_descr -> ('a, string) result) -> ('a, string) result
(** Blocking host import scope. Pin the original acquired allocation, private
    snapshot root and regular descriptor, and recheck them after the callback.
    The worker supplies a UUID and identity/digest, never a pathname. The callback
    must consume this descriptor without reopening a path. *)
val arguments : t -> max_message_bytes:int -> string list
(** What {!retain} confirmed about the allocation of a Settled claim. *)
type settlement =
  | Allocation_released
      (** Its known resources were removed, or it never had any. *)
  | Allocation_retained
      (** The operator took it over; nothing of it was removed and it stays
          where it is. *)

(** What {!cleanup} confirmed about the allocation of a Settled claim. *)
type cleanup_result =
  | Cleanup_released
      (** Its known resources were removed, or it never had any. Files an
          earlier cleanup moved out before it failed stay in the folder that
          cleanup's error named. *)
  | Cleanup_kept of { directory : string; files : int }
      (** As [Cleanup_released], after this cleanup moved the [files] files
          the browser left for the Keeper into [directory]. *)
  | Cleanup_retained
      (** The operator took it over; nothing of it was removed. *)
val cleanup : admission:Native_addon_lease.t -> directory:string -> kept_root:string ->
  (cleanup_result, string) result
(** Existing claim must be Settled. The original native reservation decides
    whether cleanup is required, including orphan recovery. Known directories
    are never reused and unknown contents are never recursively deleted. A
    missing acquisition record with an existing socket is unconfirmed. A
    retained allocation is reported as [Cleanup_retained] before decoding
    backend configuration or inspecting its children or contents. The original
    claim, descriptor envelope and acquisition record must still agree.

    Once the browser's child claims are settled and the directory is the one
    acquired, any regular single-link file of this user under [uploads],
    [download-snapshots] or [downloads] moves every one of those trees by
    rename into [kept_root/<instance id>], and the release goes on. Nothing
    the browser left for the Keeper is copied or deleted. [kept_root] and the
    instance folder are made 0700 when absent and must otherwise be
    directories of this user no group or other user can reach. A link, a
    file with more links or another kind of entry in those three trees, a
    [kept_root] on another device than the allocation, or a tree already in
    the instance folder leaves the release unconfirmed with nothing moved.
    An [Error] returned after the first tree moved names the instance
    folder. A later cleanup reads that folder only to move trees an earlier
    pass left behind; once every tree has moved it never reads it, and the
    folder belongs to the operator. *)
type retain_error =
  | Retain_refused of string
      (** The acquisition record was not changed. *)
  | Retained_record_unconfirmed of string
      (** The [retained] record write failed after its rename, or raised. The
          record may already be replaced, and a later {!cleanup} reports what
          it finds. *)
val retain : admission:Native_addon_lease.t -> directory:string -> (settlement, retain_error) result
(** The operator takes over an allocation whose release could not be confirmed.
    The claim must be Settled and each Chrome and live BiDi child claim must
    already be Settled; unlike {!cleanup}, nothing is retired or signalled.
    The allocation's contents are not read or removed: the acquisition record
    becomes [retained] with the recorded directory identity, or, with no
    record, the identity of the private directory found at this instance's own
    path. Only the child configurations needed to confirm settlement are
    decoded; automation/model payloads are not execution authority for this
    handoff. A repeated retain reads only the envelope and retained record.
    With no acquisition record, the full current descriptor is still required.
    An allocation already released is reported as [Allocation_released] and
    left as it is. *)
module For_testing : sig
  val retain : save:(string -> string -> (unit, Fs_compat.atomic_replace_failure) result) ->
    admission:Native_addon_lease.t -> directory:string -> (settlement, retain_error) result
  (** {!retain} with the record write supplied by the test. *)
end
