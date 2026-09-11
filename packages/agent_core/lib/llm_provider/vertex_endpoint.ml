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
