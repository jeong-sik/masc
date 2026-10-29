(** Startup removal of the checkpoint objects no root head reaches
    (RFC-0476 §3.6).

    A session's objects under [<session>/objects/] are kept when a root head
    names them, directly or through the segments behind its last one. The
    roots are the session's canonical head, its history archive heads, its
    retained heads under [accepted-checkpoints/], the Gate preparation heads
    the keepers' operation stores hold for that trace, and the heads journal
    input adoption copied for that trace. A head of an earlier
    [checkpoint_version] is not a root: no load reads it again.

    The pass is run only by the server process that holds the BasePath writer
    lease, after the retained checkpoint sweep and before its scheduler starts
    or any keeper runs, so nothing reads or writes a session's objects while
    it runs.

    Every root is read before anything is removed. A root that cannot be read
    or decoded, a head of a later version, a segment that cannot be followed,
    or an operation store {!Keeper_retained_checkpoint_sweep.owner_records}
    cannot read stops the pass with nothing removed, because what that head or
    store names is unknown. Only entries named [objects/<aa>/<sha256>] for a
    digest beginning with [<aa>] are removed; nothing else there is touched. *)

type report =
  { sessions : int  (** session directories with an [objects/] directory *)
  ; roots : int  (** current-version heads read in those sessions *)
  ; kept : int
  ; removed : int
  ; removed_bytes : int
  ; failures : string list  (** objects that could not be removed, with the cause *)
  }

type error =
  | Owner_stores_unreadable of Keeper_retained_checkpoint_sweep.error
  | Listing_failed of
      { path : string
      ; detail : string
      }
  | Root_unreadable of
      { path : string
      ; detail : string
      }
  | Root_unusable of
      { root : string
      ; detail : string
      }
      (** Not a head this binary decodes, or one a later binary wrote. *)
  | Segment_unreachable of
      { root : string
      ; segment : string
      ; detail : string
      }

val error_to_string : error -> string

(** [run ~runtime_root ~journal_inputs_dir ~journal_input_head] removes the
    objects under [<runtime_root>/traces/<session>/objects] that no root
    reaches. Each directory directly under [journal_inputs_dir] may hold a
    copied head named [journal_input_head]. Directories are read without
    following symlinks. *)
val run :
  runtime_root:string ->
  journal_inputs_dir:string ->
  journal_input_head:string ->
  (report, error) result
