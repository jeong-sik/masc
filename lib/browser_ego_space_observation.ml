type t = { space : Browser_lane.ego_space; ownership : string; observed_at : float }
open Result.Syntax
let of_sdk ~expected_id ~observed_at = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=["name";"ownership";"spaceId"] ->
    let get key=Option.to_result ~none:("missing SDK Space " ^ key) (List.assoc_opt key fields) in
    let* id=get "spaceId" in let* name=get "name" in
    let* space=Browser_lane.ego_space_of_json (`Assoc ["id",id;"name",name]) in
    let* ownership=get "ownership" in
    (match ownership with
     | `String ownership when String.trim ownership<>"" && Float.is_finite observed_at && space.id=expected_id ->
       Ok {space;ownership;observed_at}
     | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _|`Assoc _ ->
       Error "invalid or foreign SDK Space observation")
  | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _|`Assoc _ ->
    Error "invalid or duplicate SDK Space observation fields"
let to_json t = `Assoc ["spaceId",`Int t.space.id;"spaceName",`String t.space.name;
  "ownership",`String t.ownership;"observedAt",`Float t.observed_at]

let of_json ~expected_id = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=
      ["observedAt";"ownership";"spaceId";"spaceName"] ->
    let get key=Option.to_result ~none:("missing published Space " ^ key) (List.assoc_opt key fields) in
    let* id=get "spaceId" in let* name=get "spaceName" in let* ownership=get "ownership" in
    let* observed_at=get "observedAt" in
    let* observed_at=match observed_at with
      | `Int value -> Ok (float_of_int value)
      | `Float value when Float.is_finite value -> Ok value
      | `Null|`Bool _|`Intlit _|`Float _|`String _|`List _|`Assoc _ -> Error "invalid published Space observation time" in
    of_sdk ~expected_id ~observed_at (`Assoc ["spaceId",id;"name",name;"ownership",ownership])
  | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _|`Assoc _ ->
    Error "invalid or duplicate published Space observation fields"

type unknown_reason = Transport_unavailable of string | Invalid_inventory of string
  | Ambiguous_inventory
type presence_state = Present | Missing | Unknown of unknown_reason
type presence = { space_id : int; observed_at : float; state : presence_state }
let inventory ~expected_id ~observed_at value =
  let unknown detail = {space_id=expected_id;observed_at;state=Unknown (Invalid_inventory detail)},None in
  let row = function
    | `Assoc fields as value when List.sort String.compare (List.map fst fields)=["name";"ownership";"spaceId"] ->
      (match List.assoc_opt "spaceId" fields with
       | Some (`Int id) when id>=0 && Int64.of_int id<=9007199254740991L -> Ok (id,value)
       | None|Some _ -> Error "native inventory row has no Space ID")
    | _ -> Error "native inventory row is not an object" in
  let rec decode acc = function
    | [] -> Ok (List.rev acc)
    | value::rest -> let* observed=row value in decode (observed::acc) rest in
  match value with
  | `List rows ->
    (match decode [] rows with
     | Error detail -> unknown detail
     | Ok observations ->
       let state,observation=match List.filter (fun (id,_) -> id=expected_id) observations with
         | [] -> Missing,None
         | [(_,value)] ->
           (match of_sdk ~expected_id ~observed_at value with
            | Ok observed -> Present,Some observed
            | Error detail -> Unknown (Invalid_inventory detail),None)
         | _::_::_ -> Unknown Ambiguous_inventory,None in
       {space_id=expected_id;observed_at;state},observation)
  | _ -> unknown "native Space inventory is not an array"
let reason_to_json = function
  | Transport_unavailable detail -> `Assoc ["kind",`String "transport_unavailable";"detail",`String detail]
  | Invalid_inventory detail -> `Assoc ["kind",`String "invalid_inventory";"detail",`String detail]
  | Ambiguous_inventory -> `Assoc ["kind",`String "ambiguous_inventory"]
let presence_to_json (presence:presence) = `Assoc (["spaceId",`Int presence.space_id;
  "observedAt",`Float presence.observed_at] @ match presence.state with
  | Present -> ["state",`String "present"] | Missing -> ["state",`String "missing"]
  | Unknown reason -> ["state",`String "unknown";"reason",reason_to_json reason])
let presence_of_json ~expected_id = function
  | `Assoc fields ->
    let* space_id=match List.assoc_opt "spaceId" fields with
      | Some (`Int id) when id=expected_id -> Ok id | None|Some _ -> Error "invalid or foreign Space presence ID" in
    let* observed_at=match List.assoc_opt "observedAt" fields with
      | Some (`Float time) when Float.is_finite time -> Ok time
      | Some (`Int time) -> Ok (float_of_int time) | None|Some _ -> Error "invalid Space presence time" in
    let exact names=if List.sort String.compare (List.map fst fields)=names then Ok ()
      else Error "invalid or duplicate Space presence fields" in
    let* state=match List.assoc_opt "state" fields with
      | Some (`String ("present"|"missing" as state)) ->
        let* ()=exact ["observedAt";"spaceId";"state"] in Ok (if state="present" then Present else Missing)
      | Some (`String "unknown") ->
        let* ()=exact ["observedAt";"reason";"spaceId";"state"] in
        let* reason=match List.assoc_opt "reason" fields with
          | Some (`Assoc ["kind",`String "ambiguous_inventory"]) -> Ok Ambiguous_inventory
          | Some (`Assoc reason) when List.sort String.compare (List.map fst reason)=["detail";"kind"] ->
            (match List.assoc_opt "kind" reason,List.assoc_opt "detail" reason with
             | Some (`String "transport_unavailable"),Some (`String detail) -> Ok (Transport_unavailable detail)
             | Some (`String "invalid_inventory"),Some (`String detail) -> Ok (Invalid_inventory detail)
             | (None|Some _),(None|Some _) -> Error "invalid Space presence reason")
          | None|Some _ -> Error "invalid Space presence reason" in
        Ok (Unknown reason)
      | None|Some _ -> Error "invalid Space presence state" in
    Ok {space_id;observed_at;state}
  | _ -> Error "Space presence must be an object"
