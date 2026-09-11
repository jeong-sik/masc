type location = Global | Regional of string

let valid_component value =
  value <> "" && String.for_all (function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' -> true
    | _ -> false) value

let base_url ~project ~location =
  if not (valid_component project) then Error "Vertex project must be a project ID or number"
  else
    let resolved = match location with
      | Global -> Ok ("aiplatform.googleapis.com", "global")
      | Regional region when valid_component region ->
        Ok (region ^ "-aiplatform.googleapis.com", region)
      | Regional _ -> Error "Vertex region must be a region identifier"
    in
    Result.map (fun (host, region) ->
      Printf.sprintf "https://%s/v1/projects/%s/locations/%s/publishers/google"
        host project region) resolved

let parse_base_url value =
  let uri = Uri.of_string value in
  match String.split_on_char '/' (Uri.path uri) with
  | [""; "v1"; "projects"; project; "locations"; region; "publishers"; "google"] ->
    let location = if region = "global" then Global else Regional region in
    (match base_url ~project ~location with
     | Ok expected when String.equal expected value -> Ok (project, location)
     | _ -> Error "Vertex endpoint must be the canonical HTTPS Google publisher endpoint")
  | _ -> Error "Vertex endpoint must include project, location and Google publisher"
