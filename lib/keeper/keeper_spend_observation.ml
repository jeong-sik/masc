type t =
  | Agent_core_response of
      { response_id : string
      ; ordinal : int
      ; model : string
      ; usage : Keeper_usage_resolution.sample option
      }
  | Client_report of Keeper_client_usage_report.t

let field = "spend_observation"

let ( let* ) = Result.bind

let sample_opt_to_json = function
  | Some sample -> Keeper_usage_resolution.sample_to_json sample
  | None -> `Null
;;

let count_to_json = function
  | Keeper_client_usage_report.Running_count usage ->
    `Assoc
      [ "kind", `String "running"
      ; "usage", Keeper_usage_resolution.sample_to_json
                   (Keeper_usage_resolution.sample_of_api_usage usage)
      ]
  | Keeper_client_usage_report.Count_replaced -> `Assoc [ "kind", `String "replaced" ]
;;

let to_json = function
  | Agent_core_response { response_id; ordinal; model; usage } ->
    `Assoc
      [ "kind", `String "agent_core_response"
      ; "response_id", `String response_id
      ; "ordinal", `Int ordinal
      ; "model", `String model
      ; "usage", sample_opt_to_json usage
      ]
  | Client_report report ->
    `Assoc
      [ "kind", `String "client_report"
      ; "official_turn", `Int report.official_turn
      ; "response_id", `String report.response_id
      ; "model", `String report.model
      ; "conversation_id", `String report.conversation_id
      ; "position", `String (Keeper_usage_resolution.position_to_string report.position)
      ; "usage_scope", `String (Runtime_usage_scope.to_string report.usage_scope)
      ; "count", count_to_json report.count
      ; ( "vendor_total_tokens"
        , match report.vendor_total_tokens with
          | Some total -> `Int total
          | None -> `Null )
      ]
;;

let member name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (name ^ " is missing")
;;

let string_of name fields =
  match member name fields with
  | Ok (`String value) -> Ok value
  | Ok _ -> Error (name ^ " must be a string")
  | Error _ as error -> error
;;

let int_of name fields =
  match member name fields with
  | Ok (`Int value) -> Ok value
  | Ok _ -> Error (name ^ " must be an integer")
  | Error _ as error -> error
;;

let sample_opt_of_json = function
  | `Null -> Ok None
  | json -> Result.map Option.some (Keeper_usage_resolution.sample_of_json json)
;;

let count_of_json = function
  | `Assoc fields ->
    let* kind = string_of "kind" fields in
    (match kind with
     | "running" ->
       let* usage = member "usage" fields in
       let* sample = Keeper_usage_resolution.sample_of_json usage in
       Ok
         (Keeper_client_usage_report.Running_count
            (Keeper_usage_resolution.api_usage_of_sample sample))
     | "replaced" -> Ok Keeper_client_usage_report.Count_replaced
     | other -> Error (Printf.sprintf "unknown count kind %S" other))
  | _ -> Error "count must be an object"
;;

let of_json = function
  | `Assoc fields ->
    let* kind = string_of "kind" fields in
    (match kind with
     | "agent_core_response" ->
       let* response_id = string_of "response_id" fields in
       let* ordinal = int_of "ordinal" fields in
       let* model = string_of "model" fields in
       let* usage_json = member "usage" fields in
       let* usage = sample_opt_of_json usage_json in
       Ok (Agent_core_response { response_id; ordinal; model; usage })
     | "client_report" ->
       let* official_turn = int_of "official_turn" fields in
       let* response_id = string_of "response_id" fields in
       let* model = string_of "model" fields in
       let* conversation_id = string_of "conversation_id" fields in
       let* position_text = string_of "position" fields in
       let* position = Keeper_usage_resolution.position_of_string position_text in
       let* scope_text = string_of "usage_scope" fields in
       let* usage_scope =
         match Runtime_usage_scope.of_string scope_text with
         | Some scope -> Ok scope
         | None -> Error (Printf.sprintf "unknown usage scope %S" scope_text)
       in
       let* count_json = member "count" fields in
       let* count = count_of_json count_json in
       let* vendor_total_tokens =
         match member "vendor_total_tokens" fields with
         | Ok `Null -> Ok None
         | Ok (`Int total) -> Ok (Some total)
         | Ok _ -> Error "vendor_total_tokens must be null or an integer"
         | Error _ as error -> error
       in
       Ok
         (Client_report
            { official_turn
            ; response_id
            ; model
            ; conversation_id
            ; position
            ; usage_scope
            ; count
            ; vendor_total_tokens
            })
     | other -> Error (Printf.sprintf "unknown observation kind %S" other))
  | _ -> Error "a spend observation must be an object"
;;

let observe spend = function
  | Agent_core_response { response_id; ordinal; model; usage } ->
    Keeper_turn_spend.observe_agent_core_response
      spend
      ~response_id
      ~ordinal
      ~model
      (Option.map Keeper_usage_resolution.api_usage_of_sample usage)
  | Client_report report -> Keeper_turn_spend.observe_client_report spend report
;;
