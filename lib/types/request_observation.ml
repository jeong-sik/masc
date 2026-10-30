type provider_request =
  { node_id : string
  ; turn : int
  ; ordinal : int
  ; provenance : Llm_provider.Completion_outcome.request_provenance option
  }
type evidence =
  | Not_dispatched
  | No_durable_scope
  | No_matching_call
  | Read_failed of string
  | Recorded of { call_id : string; requests : provider_request list }
type t = { runtime_profile : string; attempt : int; evidence : evidence }
open Result.Syntax

let request_to_json (request : provider_request) =
  `Assoc ["node_id", `String request.node_id; "turn", `Int request.turn;
    "ordinal", `Int request.ordinal; "provenance",
    (match request.provenance with None -> `Null | Some fact ->
      Llm_provider.Completion_outcome.request_provenance_to_yojson fact)]

let to_json observation =
  let evidence = match observation.evidence with
    | Not_dispatched -> `Assoc ["status", `String "not_dispatched"]
    | No_durable_scope -> `Assoc ["status", `String "no_durable_scope"]
    | No_matching_call -> `Assoc ["status", `String "no_matching_call"]
    | Read_failed detail -> `Assoc ["status", `String "read_failed"; "detail", `String detail]
    | Recorded {call_id;requests} -> `Assoc ["status", `String "recorded";
        "call_id", `String call_id; "requests", `List (List.map request_to_json requests)] in
  `Assoc ["runtime_profile", `String observation.runtime_profile;
    "attempt", `Int observation.attempt; "evidence", evidence]

let fields keys = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare keys -> Ok fields
  | _ -> Error "request_observation: missing, duplicate or unknown fields"
let text = function
  | `String value when String.trim value <> "" -> Ok value
  | _ -> Error "request_observation: expected nonempty string"
let ordinal = function
  | `Int value when value >= 0 -> Ok value
  | _ -> Error "request_observation: expected nonnegative integer"
let decode_list decode values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value::rest -> let* value=decode value in loop (value::acc) rest in
  loop [] values
let list decode = function
  | `List values -> decode_list decode values
  | _ -> Error "request_observation: expected list"
let request_of_json json =
  let* fs=fields ["node_id";"turn";"ordinal";"provenance"] json in
  let* node_id=text (List.assoc "node_id" fs) in
  let* turn=ordinal (List.assoc "turn" fs) in
  let* ordinal=ordinal (List.assoc "ordinal" fs) in
  let* provenance=match List.assoc "provenance" fs with
    | `Null -> Ok None
    | value -> Result.map Option.some (Llm_provider.Completion_outcome.request_provenance_of_yojson value) in
  Ok {node_id;turn;ordinal;provenance}
let evidence_of_json json =
  let* status=match json with
    | `Assoc fs -> (match List.assoc_opt "status" fs with Some value -> text value | None -> Error "request_observation: missing status")
    | _ -> Error "request_observation: expected evidence object" in
  match status with
  | "not_dispatched" -> let* _=fields ["status"] json in Ok Not_dispatched
  | "no_durable_scope" -> let* _=fields ["status"] json in Ok No_durable_scope
  | "no_matching_call" -> let* _=fields ["status"] json in Ok No_matching_call
  | "read_failed" -> let* fs=fields ["status";"detail"] json in
    let* detail=text (List.assoc "detail" fs) in Ok (Read_failed detail)
  | "recorded" -> let* fs=fields ["status";"call_id";"requests"] json in
    let* call_id=text (List.assoc "call_id" fs) in
    let* requests=list request_of_json (List.assoc "requests" fs) in
    let ids=List.map (fun (r:provider_request) -> r.node_id) requests in
    if List.length ids <> List.length (List.sort_uniq String.compare ids)
    then Error "request_observation: duplicate provider node" else Ok (Recorded {call_id;requests})
  | _ -> Error "request_observation: unknown evidence status"
let of_json json =
  let* fs=fields ["runtime_profile";"attempt";"evidence"] json in
  let* runtime_profile=text (List.assoc "runtime_profile" fs) in
  let* attempt=ordinal (List.assoc "attempt" fs) in
  let* evidence=evidence_of_json (List.assoc "evidence" fs) in
  Ok {runtime_profile;attempt;evidence}
