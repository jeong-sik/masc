(** Startup removal of the checkpoint objects no root head reaches.

    A session's objects under [<session>/objects/] are kept when a root head
    names them, directly or through the segments behind its last one. The
    roots are the session's canonical head, its history archive heads, its
    retained heads under [accepted-checkpoints/] and the Gate preparation heads
    the keepers' operation stores hold for that trace. A head of an earlier
    [checkpoint_version] is not a root: no load reads it again. The bundles
    that the Keepers' turn log lines past each Memory writer's reading name
    are kept as well ({!Keeper_unread_turn_bundles}), so a line not yet read
    reads the content it was written with.

    The pass is run only by the server process that holds the BasePath writer
    lease, after the retained checkpoint sweep and before the scheduler of
    its server loop starts or any keeper runs, so nothing reads or writes a
    session's objects while it runs.

    Every root is read before anything is removed. A root that cannot be read
    or decoded, an [accepted-checkpoints] entry that is not a directory, a head
    of a later version, a segment that cannot be followed,
    or an operation store {!Keeper_retained_checkpoint_sweep.owner_records}
    cannot read stops the pass with nothing removed, because what that head or
    store names is unknown. So does a turn log that cannot be read, or a line
    of it from where reading stands that does not decode. Only entries named
    [objects/<aa>/<sha256>] for a digest beginning with [<aa>] are removed;
    nothing else there is touched. *)

type report =
  { sessions : int  (** session directories with an [objects/] directory *)
  ; roots : int  (** current-version heads read in those sessions *)
  ; turn_log_bundles : int  (** bundles unread turn log lines name, each counted once per session *)
  ; kept : int
  ; removed : int
  ; removed_bytes : int
  ; failures : string list  (** objects that could not be removed, with the cause *)
  }

type error =
  | Owner_stores_unreadable of Keeper_retained_checkpoint_sweep.error
  | Turn_logs_unreadable of Keeper_unread_turn_bundles.error
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

(** [run ~runtime_root ~turns_dir ~memory_dir] removes the objects under
    [<runtime_root>/traces/<session>/objects] that no root reaches. The
    session root is resolved as the store resolves it, so it may be a link;
    below it only entries that are directories themselves are read, and
    nothing else there is touched. [turns_dir] holds the Keepers' turn logs
    and [memory_dir] their Memory writers' commit logs. *)
val run
  :  runtime_root:string
  -> turns_dir:string
  -> memory_dir:string
  -> (report, error) result
