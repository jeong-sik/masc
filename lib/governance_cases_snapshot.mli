(** Lightweight filesystem reader for [.masc/governance_v2/cases/].
    Exposed so dashboard surfaces can report the real count of
    [pending_ruling] cases instead of a hardcoded zero.  See #7815. *)

type case =
  { id : string
  ; title : string
  ; status : string
  ; risk_class : string
  ; created_at : float
  }

(** [cases_dir ~base_path] is the on-disk location the helper scans. *)
val cases_dir : base_path:string -> string

(** Load every case in [base_path/.masc/governance_v2/cases/*.json] whose
    name does not start with ["_"] (reserved for markers).  Unreadable
    or malformed files are skipped with WARN+metric observability; the
    caller still gets an empty list when the directory does not exist. *)
val load_all : base_path:string -> case list

(** Count of cases whose [status] equals the given string. *)
val count_by_status : base_path:string -> status:string -> int

(** Convenience: number of cases with [status = "pending_ruling"]. *)
val pending_ruling_count : base_path:string -> int

(** Age in seconds of the oldest case currently stuck in
    [pending_ruling], relative to [now_ts].  Returns [None] when no
    such case exists or when the newest created_at is in the future
    (clock skew). *)
val oldest_pending_ruling_age_s : base_path:string -> now_ts:float -> float option
