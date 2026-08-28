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

type trace_outcome =
  | Trace_available of
      { trace_id : Keeper_id.Trace_id.t
      ; ledger : Keeper_skill_activation_ledger.t
      }
  | Trace_not_recorded of { trace_id : Keeper_id.Trace_id.t }
  | Trace_unavailable of
      { trace_id : Keeper_id.Trace_id.t
      ; reason : string
      ; detail : string
      }

let ledger_fields ledger =
  [ "ledger", Keeper_skill_activation_ledger.to_yojson ledger
  ; ( "summary"
    , Keeper_skill_activation_ledger.(summary_to_yojson (summarize ledger)) )
  ; ( "scoped_summaries"
    , `List
        (List.map
           Keeper_skill_activation_ledger.scoped_summary_to_yojson
           (Keeper_skill_activation_ledger.summarize_by_scope ledger)) )
  ]
;;

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
      ([ "status", `String "available"
       ; "keeper_name", `String keeper_name
       ]
       @ ledger_fields ledger)
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

let resolve_trace ~config ~trace_id =
  match Keeper_skill_activation_ledger.load_existing ~config ~trace_id with
  | Ok (Some ledger) -> Trace_available { trace_id; ledger }
  | Ok None -> Trace_not_recorded { trace_id }
  | Error error ->
    Trace_unavailable
      { trace_id
      ; reason = "activation_ledger_unreadable"
      ; detail = Keeper_skill_activation_ledger.store_error_to_string error
      }
;;

let resolve_trace_string ~config raw_trace_id =
  Keeper_id.Trace_id.of_string raw_trace_id
  |> Result.map (fun trace_id -> resolve_trace ~config ~trace_id)
;;

(* The wire schema tag, written once: three response arms carry it, and the
   dashboard pins this exact string before reading anything else. *)
let trace_schema = "masc.dashboard.skill-activations/v1"

let trace_to_yojson = function
  | Trace_available { trace_id; ledger } ->
    `Assoc
      ([ "schema", `String trace_schema
       ; "status", `String "available"
       ; "trace_id", `String (Keeper_id.Trace_id.to_string trace_id)
       ]
       @ ledger_fields ledger)
  | Trace_not_recorded { trace_id } ->
    `Assoc
      [ "schema", `String trace_schema
      ; "status", `String "not_recorded"
      ; "trace_id", `String (Keeper_id.Trace_id.to_string trace_id)
      ]
  | Trace_unavailable { trace_id; reason; detail } ->
    `Assoc
      [ "schema", `String trace_schema
      ; "status", `String "unavailable"
      ; "trace_id", `String (Keeper_id.Trace_id.to_string trace_id)
      ; "reason", `String reason
      ; "detail", `String detail
      ]
;;
