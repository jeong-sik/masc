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
