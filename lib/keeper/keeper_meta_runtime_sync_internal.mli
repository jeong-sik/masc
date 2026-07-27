(** Dune-private bridge from durable Keeper metadata writes to the live
    registry projection. The event retains the exact identity authority used
    by the write; consumers may not replace a registry lane by name alone. *)

type transition =
  | Ordinary of
      { trace_id : Keeper_id.Trace_id.t
      ; nonce : int
      }
  | Created of Keeper_lifecycle_nonce.create Keeper_lifecycle_nonce.witness
  | Replaced of Keeper_lifecycle_nonce.replace Keeper_lifecycle_nonce.witness
  | Recovered of
      Keeper_lifecycle_nonce.recover_exact Keeper_lifecycle_nonce.witness

type event =
  { base_path : string
  ; keeper_name : string
  ; transition : transition
  ; persisted : Keeper_meta_contract.keeper_meta
  }

val install_once : (event -> unit) -> (unit, string) result
val emit : event -> unit
