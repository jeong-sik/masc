(** Workspace-owned discovery of one published, immutable model proposal.
    Reading checks the descriptor and its referenced proposal only; it never
    scans historical proposals or compares captured facts with live stores. *)
type descriptor = private { proposal_id : string; context_sha256 : string }
type observation = Missing | Available of descriptor | Unavailable of string
val observe : base_path:string -> observation
val publish : base_path:string -> proposal_id:string -> (unit, string) result
(** Resolve and validate the saved proposal before atomically publishing its
    descriptor. An invalid existing descriptor is an error, never a fallback
    to a historical proposal. A failure before rename preserves the preceding
    publication. A post-rename sync failure may leave the new descriptor visible;
    the error is returned and no rollback resurrects an older descriptor.
    A publication is discoverability, not semantic verification or promotion. *)
