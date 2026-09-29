val read : base_path:string -> (Yojson.Safe.t, string) result
(** Current durable ledger with best-effort current Keeper fact resolution.
    Old proposal files are ignored. A missing ledger is explicit; a corrupt
    ledger is an error. Resolved claims are observations, not verification. *)

val summary : base_path:string -> (Yojson.Safe.t, string) result
(** Claim/conflict summaries with member fact references only. No original
    bodies or workspace-sized fact array is returned. *)

val detail : base_path:string -> id:string -> (Yojson.Safe.t, string) result
(** Resolve one claim or conflict and its current member facts. *)
