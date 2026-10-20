let ( let* ) = Result.bind

type t = Exact_output of Lane_addon_exact.request

let request_id = function Exact_output request -> request.Lane_addon_exact.request_id

let request_of_json = function
  | `Assoc fields as json ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "exact_output") ->
       Lane_addon_exact.request_of_json json |> Result.map (fun request -> Exact_output request)
     | Some (`String kind) -> Error ("this host has no request kind " ^ kind)
     | Some _ | None -> Error "a host request requires a string kind")
  | _ -> Error "a host request must be an object"

let listing_of_json = function
  | `Assoc [ "requests", `List values ] ->
    let* requests =
      List.fold_right
        (fun value acc ->
           let* acc = acc in
           let* request = request_of_json value in
           Ok (request :: acc))
        values (Ok [])
    in
    let ids = List.map request_id requests in
    if List.length (List.sort_uniq String.compare ids) <> List.length ids
    then Error "a listing names the same request id twice"
    else Ok requests
  | _ -> Error "a host request listing must be exactly {\"requests\": [...]}"

let result_arguments ~request_id ~result = `Assoc [ "request_id", `String request_id; "result", result ]

let accepted_of_json = function
  | `Assoc [ "accepted", `Bool accepted ] -> Ok accepted
  | _ -> Error "lane_host_result must answer exactly {\"accepted\": bool}"

type availability = { revision : string; request_ids : string list }
let availability_to_json state = `Assoc ["revision",`String state.revision;
  "request_ids",`List (List.map (fun id -> `String id) state.request_ids)]
let availability_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=["request_ids";"revision"] ->
      let* revision = match List.assoc "revision" fields with
        | `String value when String.trim value<>"" -> Ok value | _ -> Error "invalid host request revision" in
      let* request_ids = match List.assoc "request_ids" fields with
        | `List values -> List.fold_right (fun value acc -> let* rest=acc in
            match value with `String id when String.trim id<>"" -> Ok (id::rest)
              | _ -> Error "invalid pending host request id") values (Ok [])
        | _ -> Error "pending host requests must be an array" in
      if List.length request_ids <> List.length (List.sort_uniq String.compare request_ids)
      then Error "duplicate pending host request id" else Ok {revision;request_ids}
  | _ -> Error "invalid host request availability"
