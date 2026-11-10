(** The memory IDs a Keeper Memory commit changed and the counter that counts
    them, [masc_keeper_memory_changes_total] (RFC-0517 §2.2).

    The store moves the counter after a commit that rewrote the snapshot. The
    memory health row reads it back for each Keeper. Both name the series
    here, so the row reads the series the store writes. The counter lives in
    this process: it starts at zero with the server, and the journal does not
    record the pass. *)

type counts =
  { added : int  (** IDs the result holds that the basis did not *)
  ; absorbed : int  (** IDs that left through an applied absorption *)
  ; superseded : int  (** IDs that left through an applied revision *)
  ; dropped : int  (** every other ID that left, support invalidations included *)
  }

val count : keeper_id:string -> pass:Keeper_memory_commit_pass.t -> counts -> unit
(** Move the counter by each count, labelled with the keeper, the pass and
    the change ([added], [absorbed], [superseded] or [dropped]). *)

type by_pass = (Keeper_memory_commit_pass.t * counts) list
(** One [counts] per pass, in {!Keeper_memory_commit_pass.all} order. *)

val since_start : keeper_id:string -> by_pass
(** What this process has counted for the keeper, every pass included. A pass
    that has not committed for the keeper reads zero. *)

val by_pass_to_json : by_pass -> Yojson.Safe.t
(** An object with one member per pass label, each an object with one member
    per change label. *)

val by_pass_of_json : Yojson.Safe.t -> (by_pass, string) result
(** Takes exactly what {!by_pass_to_json} writes for {!since_start}: every pass
    and every change once and nothing else, each count a non-negative int. *)
