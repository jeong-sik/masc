open Result.Syntax
module Invocation = Agent_core.Tool_contract.Invocation
module Delivery = Keeper_skill_async_delivery
type sdk_result =
  | Handler_returned of { bytes : int; sha256 : string }
  | Handler_errored of
      { bytes : int; sha256 : string; recoverable : bool
      ; error_class : Agent_core.Types.tool_error_class option }
type occurrence =
  | Sdk_result of { invocation : Invocation.t; result : sdk_result }
  | Native_started of { official_turn : int; identity : Runtime_native_tools.action_identity }
type t =
  { delivery_sha256 : string; physical_turn_ref : Ids.Turn_ref.t
  ; runtime_id : string; tool_name : string; occurrence : occurrence; observed_at : string }

let digest text = Agent_core_sha256.(digest_string text |> to_hex)
let sdk_result (result : Agent_core.Types.tool_result) = match result with
  | Ok output -> Handler_returned {bytes=String.length output.content;sha256=digest output.content}
  | Error error -> Handler_errored {bytes=String.length error.message;sha256=digest error.message;
      recoverable=error.recoverable;error_class=error.error_class}
let native_identity_json = function
  | Runtime_native_tools.Call_id id -> `Assoc ["kind",`String "call_id";"call_id",`String id]
  | Provider_step {conversation_id;step_index} -> `Assoc ["kind",`String "provider_step";
      "conversation_id",`String conversation_id;"step_index",`Int step_index]
let error_class_json = function
  | Agent_core.Types.Transient -> `String "transient"
  | Deterministic -> `String "deterministic"
  | Unknown -> `String "unknown"
let result_json = function
  | Handler_returned {bytes;sha256} -> `Assoc ["kind",`String "handler_returned";"bytes",`Int bytes;"sha256",`String sha256]
  | Handler_errored {bytes;sha256;recoverable;error_class} -> `Assoc ["kind",`String "handler_errored";
      "bytes",`Int bytes;"sha256",`String sha256;"recoverable",`Bool recoverable;
      "error_class",(match error_class with None -> `Null | Some value -> error_class_json value)]
let occurrence_json = function
  | Sdk_result {invocation;result} -> `Assoc ["kind",`String "sdk_result";
      "invocation",Delivery.invocation_to_json invocation;"result",result_json result]
  | Native_started {official_turn;identity} -> `Assoc ["kind",`String "native_started";
      "official_turn",`Int official_turn;"identity",native_identity_json identity]
let fields value =
  ["delivery_sha256",`String value.delivery_sha256;"physical_turn_ref",Ids.Turn_ref.to_yojson value.physical_turn_ref;
   "runtime_id",`String value.runtime_id;"tool_name",`String value.tool_name;"occurrence",occurrence_json value.occurrence]
let to_json value = `Assoc (fields value @ ["observed_at",`String value.observed_at])
let occurrence_identity value =
  let occurrence = match value.occurrence with
    | Sdk_result {invocation;_} -> `Assoc ["kind",`String "sdk_result";"invocation",Delivery.invocation_to_json invocation]
    | Native_started _ as occurrence -> occurrence_json occurrence in
  `Assoc ["physical_turn_ref",Ids.Turn_ref.to_yojson value.physical_turn_ref;"runtime_id",`String value.runtime_id;
    "occurrence",occurrence] |> Yojson.Safe.to_string |> digest
let identity value = digest (value.delivery_sha256 ^ occurrence_identity value)
let same_fact left right = Yojson.Safe.equal (`Assoc (fields left)) (`Assoc (fields right))
let same_occurrence_fact left right =
  Ids.Turn_ref.equal left.physical_turn_ref right.physical_turn_ref
  && String.equal left.runtime_id right.runtime_id
  && String.equal left.tool_name right.tool_name
  && Yojson.Safe.equal (occurrence_json left.occurrence) (occurrence_json right.occurrence)
let make ~delivery_sha256 ~physical_turn_ref ~runtime_id ~tool_name ~occurrence ~observed_at =
  let* () = Skill_reference.validate_revision_string delivery_sha256 |> Result.map_error (fun _ -> "invalid causal delivery digest") in
  let* () = if Ids.Turn_ref.absolute_turn physical_turn_ref > 0
      && String.trim (Ids.Turn_ref.trace_id physical_turn_ref) <> "" && String.trim runtime_id <> ""
      && String.trim tool_name <> "" then Ok () else Error "blank or invalid physical action identity" in
  let* () = match occurrence with
    | Sdk_result {invocation;result} ->
      let* () = Delivery.validate_invocation invocation in
      let bytes,sha256 = match result with Handler_returned r -> r.bytes,r.sha256
        | Handler_errored r -> r.bytes,r.sha256 in
      let* () = if bytes >= 0 then Ok () else Error "invalid action text byte count" in
      Skill_reference.validate_revision_string sha256 |> Result.map_error (fun _ -> "invalid action text digest")
    | Native_started {official_turn;identity} ->
      let valid_identity = match identity with
        | Runtime_native_tools.Call_id id -> String.trim id <> ""
        | Provider_step {conversation_id;step_index} -> String.trim conversation_id <> "" && step_index >= 0 in
      if official_turn >= 0 && valid_identity then Ok () else Error "invalid native start identity" in
  let* () = Time_codec.parse_rfc3339 observed_at |> Result.map ignore |> Result.map_error (fun _ -> "invalid action clock") in
  Ok {delivery_sha256;physical_turn_ref;runtime_id;tool_name;occurrence;observed_at}
let validate_delivery (delivery : Delivery.t) action =
  if not (String.equal action.delivery_sha256 (Delivery.identity delivery))
     || not (Ids.Turn_ref.equal delivery.physical_turn_ref action.physical_turn_ref)
     || not (String.equal delivery.runtime_id action.runtime_id)
  then Error "action differs from the physical receiving context"
  else match delivery.presentation with
    | Manifest_reference -> Error "a manifest reference is not inline-body action authority"
    | Inline_result -> match action.occurrence with
      | Native_started _ -> Ok ()
      | Sdk_result {invocation;_} ->
        let boundary_turn = match delivery.boundary with
          | Keeper_skill_activation_types.Model_response {agent_core_turn}
          | Official_client_result_handoff {agent_core_turn} -> agent_core_turn in
        if Invocation.turn invocation >= boundary_turn then Ok () else Error "SDK action precedes its receiving boundary"
let object_fields names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "unexpected, duplicate or missing async action fields"
let string name fields = match List.assoc_opt name fields with Some (`String value) -> Ok value
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) | None -> Error ("expected string " ^ name)
let integer name fields = match List.assoc name fields with `Int value -> Ok value
  | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> Error ("expected integer " ^ name)
let of_json json =
  let* fields = object_fields ["delivery_sha256";"physical_turn_ref";"runtime_id";"tool_name";"occurrence";"observed_at"] json in
  let* delivery_sha256 = string "delivery_sha256" fields and* runtime_id = string "runtime_id" fields in
  let* physical_turn_ref = Ids.Turn_ref.of_yojson (List.assoc "physical_turn_ref" fields) in
  let* tool_name = string "tool_name" fields and* observed_at = string "observed_at" fields in
  let* occurrence = match List.assoc "occurrence" fields with
    | `Assoc occurrence ->
      let* kind = string "kind" occurrence in
      (match kind with
       | "sdk_result" ->
         let* occurrence = object_fields ["kind";"invocation";"result"] (`Assoc occurrence) in
         let* invocation = Delivery.invocation_of_json (List.assoc "invocation" occurrence) in
         let* result = match List.assoc "result" occurrence with
           | `Assoc fields ->
             let* kind = string "kind" fields in
             let* fields = object_fields (match kind with "handler_returned" -> ["kind";"bytes";"sha256"]
               | "handler_errored" -> ["kind";"bytes";"sha256";"recoverable";"error_class"] | _ -> []) (`Assoc fields) in
             let* bytes = integer "bytes" fields and* sha256 = string "sha256" fields in
             (match kind with
              | "handler_returned" -> Ok (Handler_returned {bytes;sha256})
              | "handler_errored" ->
                let* recoverable = match List.assoc "recoverable" fields with `Bool value -> Ok value
                  | `Null | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> Error "invalid recoverability" in
                let* error_class = match List.assoc "error_class" fields with
                  | `Null -> Ok None
                  | `String "transient" -> Ok (Some Agent_core.Types.Transient)
                  | `String "deterministic" -> Ok (Some Agent_core.Types.Deterministic)
                  | `String "unknown" -> Ok (Some Agent_core.Types.Unknown)
                  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> Error "unknown SDK error class" in
                Ok (Handler_errored {bytes;sha256;recoverable;error_class})
              | _ -> Error "unknown SDK action result")
           | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "SDK action result is not an object" in
         Ok (Sdk_result {invocation;result})
       | "native_started" ->
         let* occurrence = object_fields ["kind";"official_turn";"identity"] (`Assoc occurrence) in
         let* official_turn = integer "official_turn" occurrence in
         let* identity = match List.assoc "identity" occurrence with
           | `Assoc identity ->
             let* kind = string "kind" identity in
             (match kind with
              | "call_id" -> let* identity = object_fields ["kind";"call_id"] (`Assoc identity) in
                let* id = string "call_id" identity in Ok (Runtime_native_tools.Call_id id)
              | "provider_step" -> let* identity = object_fields ["kind";"conversation_id";"step_index"] (`Assoc identity) in
                let* conversation_id = string "conversation_id" identity and* step_index = integer "step_index" identity in
                Ok (Runtime_native_tools.Provider_step {conversation_id;step_index})
              | _ -> Error "unknown native action identity")
           | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "native action identity is not an object" in
         Ok (Native_started {official_turn;identity})
       | _ -> Error "unknown async action occurrence")
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "async action occurrence is not an object" in
  make ~delivery_sha256 ~physical_turn_ref ~runtime_id ~tool_name ~occurrence ~observed_at
