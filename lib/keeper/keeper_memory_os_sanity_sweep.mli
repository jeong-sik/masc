(** Read-only Memory OS sanity sweep.

    This is an operator review packet, not an automatic belief invalidator. The
    code only projects typed Memory OS state: current-vs-expired facts from the
    stored [valid_until] boundary, duplicate claim identities from the Memory OS
    SSOT, and prompt-recall eligibility from the typed fact schema. It does not
    string-match claim prose or infer external truth. Obsolete/superseded
    decisions remain HITL/model-judgement work through the existing
    consolidation-plan index contract. *)

type keeper_error =
  | Missing_fact_store of { facts_path : string }
  | Corrupt_fact_store of { message : string }
  | Fact_store_access_error of { message : string }
  | Fact_store_locked of
      { caller : string
      ; lock_path : string
      ; attempts : int
      }

type fact_row =
  { index : int
  ; claim : string
  ; claim_identity : string
  ; category : string
  ; claim_kind : string option
  ; first_seen : float
  ; valid_until : float option
  ; effective_valid_until : float option
  ; last_verified_at : float option
  ; reference_time : float
  ; current : bool
  ; prompt_recallable : bool
  }

type duplicate_group =
  { claim_identity : string
  ; member_indices : int list
  }

type deterministic_gc_preview =
  { total_input : int
  ; ttl_expired : int
  ; ttl_expired_ephemeral : int
  ; ttl_expired_non_ephemeral : int
  ; ttl_expired_by_category : (string * int) list
  ; dedup_removed : int
  ; written : int
  }

type keeper_result =
  | Keeper_ok of
      { keeper_id : string
      ; facts_path : string
      ; total_facts : int
      ; current_facts : int
      ; expired_facts : int
      ; prompt_recallable_current_facts : int
      ; duplicate_groups : duplicate_group list
      ; facts : fact_row list
      ; gc_preview : deterministic_gc_preview
      }
  | Keeper_error of
      { keeper_id : string
      ; error : keeper_error
      }

type t =
  { keepers_dir : string
  ; results : keeper_result list
  ; total_facts : int
  ; current_facts : int
  ; expired_facts : int
  ; prompt_recallable_current_facts : int
  ; duplicate_group_count : int
  ; deterministic_ttl_expired : int
  ; deterministic_dedup_removed : int
  ; deterministic_written : int
  ; error_count : int
  }

val run_for_keepers_dir
  :  keepers_dir:string
  -> ?keeper_ids:string list
  -> now:float
  -> unit
  -> t
(** Build a read-only report for Memory OS fact stores. Must run inside an Eio
    context because the deterministic GC preview takes the per-keeper fact-store
    lock in dry-run mode. *)

module For_testing : sig
  val row_of_fact :
    now:float -> index:int -> Keeper_memory_os_types.fact -> fact_row

  val duplicate_groups : fact_row list -> duplicate_group list
end

val to_json : t -> Yojson.Safe.t
val render_text : t -> string
