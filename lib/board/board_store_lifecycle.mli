val initialize_store : Board_types.store -> (unit, Board_types.board_error) result
(** Quiescent fresh-store initialization shared by explicit stores and global.
    Loads all sources best effort and recovers an original deletion decision.
    Refused/unknown owners cannot be reset by calling this again. *)

type claim
(** The BasePath the process store belongs to, and the store that opens on it.
    Holding a claim reads no Board file. *)

val claim_global : Board_workspace_binding.t -> claim
(** Name the BasePath of the process store. The first claim wins: a later call
    returns the earlier claim unchanged, whatever binding it passes, so the
    caller compares {!claimed_binding} with its own request before
    {!open_claim}. *)

val claimed_binding : claim -> Board_workspace_binding.t

val open_claim : claim -> Board_types.store
(** Force the sole protected lazy store on the claimed BasePath. Construction
    and ordered best-effort loading happen inside the force callback. *)

val global : unit -> Board_types.store
(** Open the claimed store. When nobody claimed one, claim the process
    environment's BasePath first. *)

(** Test setup only, before concurrent fibers exist. Drops the claim; the next
    claim names the BasePath again. *)
val reset_global_for_test : unit -> unit
