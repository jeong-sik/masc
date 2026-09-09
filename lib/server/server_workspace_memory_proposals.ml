module Store = Workspace_memory_proposal
let row (id, proposal) = `Assoc [
  "id", `String id;
  "proposal", Store.to_json proposal;
  "semantic_verification", `String "not_performed"]
let error status detail = status, `Assoc ["error", `String detail]
let failure = function
  | Store.Invalid detail -> error `Bad_request detail
  | Store.Unavailable detail -> error `Service_unavailable detail
let get ~base_path ~id =
  match id with
  | Some id -> (match Store.read ~base_path ~id with
      | Ok (Some proposal) -> `OK, row (id, proposal)
      | Ok None -> error `Not_found "Workspace memory proposal not found"
      | Error e -> failure e)
  | None -> (match Store.list ~base_path with
      | Ok proposals -> `OK, `Assoc ["proposals", `List (List.map row proposals);
          "semantic_verification", `String "not_performed"]
      | Error e -> failure e)
let post ~base_path body =
  match (try Ok (Yojson.Safe.from_string body) with Yojson.Json_error detail -> Error detail) with
  | Error detail -> error `Bad_request detail
  | Ok json -> (match Store.submit ~base_path json with
      | Ok proposal -> `OK, row proposal
      | Error e -> failure e)
