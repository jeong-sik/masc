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

let handler : (event -> unit) option Atomic.t = Atomic.make None

let install_once fn =
  if Atomic.compare_and_set handler None (Some fn)
  then Ok ()
  else Error "Keeper runtime metadata sync consumer is already installed"
;;

let emit event =
  Option.iter (fun fn -> fn event) (Atomic.get handler)
;;
