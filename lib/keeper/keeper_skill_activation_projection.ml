type unavailable =
  { keeper_name : string
  ; reason : string
  ; detail : string
  }

type outcome =
  | Available of
      { keeper_name : string
      ; ledger : Keeper_skill_activation_ledger.t
      }
  | No_session of { keeper_name : string }
  | Unavailable of unavailable

let resolve ~config ~keeper_name =
  match Keeper_meta_store.read_meta config keeper_name with
  | Error detail ->
    Unavailable { keeper_name; reason = "keeper_meta_unreadable"; detail }
  | Ok None -> No_session { keeper_name }
  | Ok (Some meta) ->
    (match
       Keeper_skill_activation_ledger.load
         ~config
         ~trace_id:meta.runtime.trace_id
     with
     | Ok ledger -> Available { keeper_name; ledger }
     | Error error ->
       Unavailable
         { keeper_name
         ; reason = "activation_ledger_unreadable"
         ; detail = Keeper_skill_activation_ledger.store_error_to_string error
         })
;;

let to_yojson = function
  | Available { keeper_name; ledger } ->
    `Assoc
      [ "status", `String "available"
      ; "keeper_name", `String keeper_name
      ; "ledger", Keeper_skill_activation_ledger.to_yojson ledger
      ]
  | No_session { keeper_name } ->
    `Assoc
      [ "status", `String "no_session"
      ; "keeper_name", `String keeper_name
      ]
  | Unavailable { keeper_name; reason; detail } ->
    `Assoc
      [ "status", `String "unavailable"
      ; "keeper_name", `String keeper_name
      ; "reason", `String reason
      ; "detail", `String detail
      ]
;;
