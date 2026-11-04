module Client = Typesafeai_client

let schema = "masc.health.typesafeai.v1"

let iso at = Masc_domain.iso8601_of_unix_seconds at

let same_destination (a : Client.destination_id) (b : Client.destination_id) =
  String.equal a.destination_uri b.destination_uri && String.equal a.model b.model
;;

let outcome_of outcomes destination =
  List.find_map
    (fun (asked, outcome) -> if same_destination asked destination then Some outcome else None)
    outcomes
;;

(* Only the operator can add credit or change a key; every other refusal
   ends on the vendor's side. *)
let operator_can_fix : Client.refusal_class -> bool = function
  | Payment_required | Credential_refused -> true
  | Rate_limited | Server_error | Request_refused | Response_unusable | Transport -> false
;;

let outcome_json : Client.destination_outcome option -> Yojson.Safe.t = function
  | None -> `Assoc [ "kind", `String "not_asked" ]
  | Some (Answered { at }) -> `Assoc [ "kind", `String "answered"; "at", `String (iso at) ]
  | Some (Refusing { since; last_at; last; last_answer_at }) ->
    `Assoc
      [ "kind", `String "refusing"
      ; "since", `String (iso since)
      ; "last_at", `String (iso last_at)
      ; "last", `String (Client.refusal_class_to_string last)
      ; ( "last_answer_at"
        , match last_answer_at with
          | Some at -> `String (iso at)
          | None -> `Null )
      ]
;;

let strings values = `List (List.map (fun value -> `String value) values)

let section_json ~configured ~outcomes =
  match configured with
  | Error reason ->
    `Assoc
      [ "schema", `String schema
      ; "status", `String "disabled"
      ; "reason", `String (Typesafeai_config.unavailable_reason_to_string reason)
      ; "operator_action_required", `Bool false
      ; "operator_action_reasons", `List []
      ; "status_reasons", `List []
      ; "destinations", `List []
      ]
  | Ok (first, rest) ->
    let rows =
      List.map (fun destination -> destination, outcome_of outcomes destination) (first :: rest)
    in
    let refusing =
      List.filter_map
        (fun ((destination : Client.destination_id), outcome) ->
           match outcome with
           | Some (Client.Refusing { since; last; _ }) -> Some (destination, since, last)
           | Some (Client.Answered _) | None -> None)
        rows
    in
    let action_reasons =
      List.filter_map
        (fun ((destination : Client.destination_id), since, last) ->
           if operator_can_fix last
           then
             Some
               (Printf.sprintf "%s %s since=%s" (Client.refusal_class_to_string last)
                  destination.destination_uri (iso since))
           else None)
        refusing
    in
    let status_reasons =
      List.map
        (fun ((destination : Client.destination_id), _, last) ->
           Printf.sprintf "%s %s" (Client.refusal_class_to_string last) destination.destination_uri)
        refusing
    in
    let asked = List.exists (fun (_, outcome) -> Option.is_some outcome) rows in
    let every_one_refusing =
      List.for_all
        (fun (_, outcome) ->
           match outcome with
           | Some (Client.Refusing _) -> true
           | Some (Client.Answered _) | None -> false)
        rows
    in
    let status =
      if not asked then Health_status.Idle
      else if every_one_refusing then Health_status.Degraded
      else if action_reasons <> [] then Health_status.Warning
      else Health_status.Ok
    in
    `Assoc
      [ "schema", `String schema
      ; "status", `String (Health_status.to_string status)
      ; "operator_action_required", `Bool (action_reasons <> [])
      ; "operator_action_reasons", strings action_reasons
      ; "status_reasons", strings status_reasons
      ; ( "destinations"
        , `List
            (List.map
               (fun (destination, outcome) ->
                  `Assoc
                    [ "destination", Client.destination_id_to_yojson destination
                    ; "outcome", outcome_json outcome
                    ])
               rows) )
      ]
;;

let configured_destinations () =
  Typesafeai_config.lane_destinations ()
  |> Result.map (fun (first, rest) -> Client.identify first, List.map Client.identify rest)
;;

let health_json () =
  section_json
    ~configured:(configured_destinations ())
    ~outcomes:(Client.destination_outcomes ())
;;

let health_placeholder ~status =
  `Assoc
    [ "schema", `String schema
    ; "status", `String (Health_status.to_string status)
    ; "operator_action_required", `Bool false
    ; "operator_action_reasons", `List []
    ; "status_reasons", `List []
    ; "destinations", `List []
    ]
;;
