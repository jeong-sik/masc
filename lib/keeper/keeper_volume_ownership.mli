(** Workspace-scoped ownership for Apple Keeper volumes.

    Work and build volume names carry the Keeper name but not its workspace
    (RFC-0400), so same-named Keepers in different workspaces resolve to the
    same disks on one Apple Container runtime store. A marker file at the
    volume's root records which workspace's runtime created it; this module
    interprets that marker and nothing else. It never creates, attaches,
    detaches, or deletes a volume.

    Volumes created before the convention carry no marker. They stay
    [Unverified Unmarked] and callers must keep preserving them; the absence
    of a marker is not evidence of ownership either way. *)

(** The workspace identity recorded on a volume at creation time. *)
type owner_marker =
  { base_path : string  (** Workspace base path exactly as configured. *)
  ; written_at : float  (** Unix seconds, diagnostic only. *)
  }

(** Why a probe could not answer [Owned_by_this_workspace]. *)
type unverified =
  | Inspect_failed of string
    (** The runtime CLI failed, so nothing about the volume is known. *)
  | Unmarked
    (** The volume exists but has no ownership marker; it predates the
        convention and may belong to any workspace. *)
  | Marker_io of string
    (** The volume image could not be opened to read the marker. *)
  | Marker_unreadable of string
    (** A marker exists but does not parse as the documented format. *)
  | Marker_mismatch of { recorded : string; probed : string }
    (** A parseable marker does not name the probing workspace; also used
        for diagnostics when fields disagree. *)

type t =
  | Owned_by_this_workspace
  | Unverified of unverified
  | Owned_by_another_workspace of { recorded : string }

val marker_path : string
(** Guest-visible path of the marker file at the volume root. *)

val marker_to_yojson : owner_marker -> Yojson.Safe.t
(** The documented on-disk format (schema 1). *)

val marker_of_yojson : Yojson.Safe.t -> (owner_marker, string) result
(** Strict parse: schema must be 1 and [base_path] non-empty. *)

val interpret_marker_bytes : probed_base_path:string -> string -> t
(** Interpret raw marker bytes for the workspace asking at
    [probed_base_path]. Malformed bytes are [Unverified], never a guess. *)

val interpret_marker_absent : unit -> t
(** The marker file does not exist: an unmarked legacy volume. *)

val unverified_to_string : unverified -> string
(** Human-readable reason, for logs and reconciliation reports. *)
