(* HIGH-RISK-UNREVIEWED: this pass deletes files under the settled archive. *)

(** Startup pass over the settled archive (RFC-0498 layer three a). It deletes
    the archived records no live record names and every archived body.

    A live record names the request IDs its progress events hold and, for a
    gate record, its parent execution. The callers that ask whether an
    original is settled pass only those IDs, and a parent records a child's ID
    before the child exists, so no caller asks about an archived record no
    live record names. No code reads an archived body. The pass reads every
    live record and the whole archive and decides each file before it deletes
    one, so a store it cannot classify loses nothing. *)

type report =
  { live_records : int
  ; named_ids : int  (** Distinct request IDs the live records name. *)
  ; kept_records : int  (** Archived records a live record names. *)
  ; removed_records : int
  ; removed_record_bytes : int64
  ; removed_bodies : int
  ; removed_body_bytes : int64
  }

type error =
  | Sweep_refused of string
  (** Nothing was deleted: a live record or an archive entry could not be
      classified. *)
  | Removal_stopped of
      { removed_records : int
      ; removed_bodies : int
      ; detail : string
      }
  (** A deletion failed; the files counted here were deleted before it. *)

val error_to_string : error -> string

val run : store:Lane_addon_store.t -> (report, error) result
(** Call while the workspace process lease excludes original writers and
    settles. A live record in a scope no owner claims, one that does not
    decode, a gate whose parent cannot be read, or an archive entry of an
    unknown shape refuses the pass. Bodies are deleted before records. An
    error names the class of failure, never record or body content. Byte
    counts are logical file sizes. *)

val run_at_startup : base_path:string -> (report, error) result
(** As {!run} for the workspace runtime store. A missing runtime root deletes
    nothing. *)
