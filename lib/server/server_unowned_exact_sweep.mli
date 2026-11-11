(* HIGH-RISK-UNREVIEWED: this pass deletes Exact records and execution links. *)

(** Delete the Exact records and original execution links that no live
    original owns (RFC-0498 §4.4).

    Only a configured declaration whose package needs an original is swept:
    {!Server_workspace_memory_addon_validation.original_required} or
    {!Server_librarian_addon_validation.original_required}, the same answers
    the Exact authority gives. A request of that declaration without a live
    original ends as [Unowned] and no original can grant it later, so a
    rerun ends as [Not_allowed] with or without its record and link.

    The Exact records and links are listed first, outside the settlement
    barrier, because the links are read whole. The live originals are read
    and the files deleted inside the barrier. An original is retained before
    its Exact run starts, so a listed file whose original is live is seen
    owned. Every link goes before any record: a link left without its record
    stops a rerun with an error, a record left without its link does not.
    Passive slot companions use the same original-owner fence and are removed
    before links, with separate counts; live originals retain them. *)

type report =
  { declarations : int
  ; live_originals : int
  ; kept_exact_records : int
  ; kept_proofs : int
  ; kept_observations : int
  ; removed_observations : int
  ; removed_observation_bytes : int64
  ; removed_proofs : int
  ; removed_proof_bytes : int64
  ; removed_exact_records : int
  ; removed_exact_record_bytes : int64
  }

type error =
  | Sweep_refused of string
      (** A directory, link or live original could not be read or has an
          unknown shape, or the barrier could not be taken. Nothing was
          deleted. The detail names the failure class only, never record
          contents. *)
  | Removal_stopped of
      { removed_proofs : int
      ; removed_exact_records : int
      ; removed_observations : int
      ; detail : string
      }
      (** A deletion failed. The counts say how many went before it. *)

val error_to_string : error -> string

val run :
  store:Lane_addon_store.t ->
  declarations:Lane_addon_config.declaration list ->
  (report, error) result
(** Blocking. Reads each listed link whole; call it off the server domain.
    The caller holds the workspace process lease. *)

val run_for_workspace : Workspace.config -> (report, error) result
(** {!run} over the workspace's Lane store and its configured declarations. *)
