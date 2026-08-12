module Intent = Keeper_continuation_delivery_intent
module Publisher = Keeper_continuation_delivery_publisher
module Store = Keeper_continuation_delivery_store

type outcome =
  | No_obligation
  | Obligation_committed of
      { intent : Intent.t
      ; recovery_detail : string option
      }
  | Quarantine_required of
      { intent : Intent.t option
      ; detail : string
      }

let quarantine_required ?intent detail = Quarantine_required { intent; detail }

let obligation_committed ?recovery_detail intent =
  Obligation_committed { intent; recovery_detail }
;;

let settle_existing ~config ~keeper_name ~origin =
  match Intent.intent_id_for_origin ~keeper_name origin with
  | Error error -> quarantine_required (Intent.error_to_string error)
  | Ok intent_id ->
    (match Store.load ~config ~keeper_name ~intent_id with
     | Error (Store.Not_found _) -> No_obligation
     | Error error ->
       quarantine_required
         ("exact continuation obligation is unreadable: "
          ^ Store.error_to_string error)
     | Ok intent when not (Intent.same_source intent.Intent.origin origin) ->
       quarantine_required
         ~intent
         "deterministic continuation intent id resolved to a different source"
     | Ok intent when not (Intent.same_origin intent.Intent.origin origin) ->
       quarantine_required
         ~intent
         "continuation source identity was replayed with a different route"
     | Ok intent ->
       (match Publisher.publish ~config intent with
        | Ok (Publisher.Delivered settled)
        | Ok (Publisher.Failed settled)
        | Ok (Publisher.Ambiguous settled) ->
          obligation_committed settled
        | Error error ->
          obligation_committed
            ~recovery_detail:(Publisher.error_to_string error)
            intent))
;;
