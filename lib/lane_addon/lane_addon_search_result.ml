(* Lane Add-on web-search service port (task-2527 E11, layer 1).

   The secret-free half of the port a [world.web_search] package speaks:
   the request shape it lists and the result envelope the host answers
   with. The provider chain, its credentials, the cache and the rate
   limit stay on the host — this module carries none of them, so a
   package can type-check against the port without ever seeing a key.

   Result identity and sources are preserved, not summarised: the
   envelope embeds the serving provider's own typed result [data] under
   [search] (rows, or a grounded [context_text] envelope), plus the
   request identity, the serving provider and every per-provider error
   the chain kept. A package that re-reads a delivered result therefore
   sees what a Keeper saw, minus nothing the wire carried. *)

type request = {
  request_id : string;
  query : string;
  limit : int option;
}

let request_id request = request.request_id

let request_to_json request =
  `Assoc ([ "kind", `String "web_search"; "request_id", `String request.request_id;
            "query", `String request.query ]
          @ match request.limit with
            | Some limit -> [ "limit", `Int limit ]
            | None -> [])

open Result.Syntax

type result = {
  serving_provider : string option;
  provider_errors : (string * string) list;
  search : Yojson.Safe.t;
}

let result_to_json result =
  `Assoc [ "serving_provider",
           Option.fold ~none:`Null
             ~some:(fun provider -> `String provider) result.serving_provider;
           "provider_errors",
           `List (List.map (fun (provider, detail) ->
               `Assoc [ "provider", `String provider; "detail", `String detail ])
              result.provider_errors);
           "search", result.search ]

let result_of_json value =
  match value with
  | `Assoc fields ->
    let serving_provider = match List.assoc_opt "serving_provider" fields with
      | None | Some `Null -> Ok None
      | Some (`String provider) when String.trim provider <> "" -> Ok (Some provider)
      | Some _ -> Error "serving_provider must be a provider name or null" in
    let provider_errors = match List.assoc_opt "provider_errors" fields with
      | None -> Ok []
      | Some (`List entries) ->
        List.fold_left (fun acc entry ->
            match acc with
            | Error _ -> acc
            | Ok pairs ->
              (match entry with
               | `Assoc [ ("provider", `String provider); ("detail", `String detail) ]
                 when String.trim provider <> "" && String.trim detail <> "" ->
                 Ok ((provider, detail) :: pairs)
               | _ -> Error "provider_errors entries are {provider, detail} strings"))
          (Ok []) entries
        |> (function
            | Ok pairs -> Ok (List.rev pairs)
            | Error message -> Error message)
      | Some _ -> Error "provider_errors must be an array" in
    let search = match List.assoc_opt "search" fields with
      | Some search -> Ok search
      | None -> Error "a web_search result requires the search envelope" in
    let* serving_provider = serving_provider in
    let* provider_errors = provider_errors in
    let* search = search in
    let unknown = List.find_opt (fun (key, _) -> not (List.mem key
        [ "serving_provider"; "provider_errors"; "search" ])) fields in
    (match unknown with
     | Some (key, _) -> Error ("a web_search result has no key " ^ key)
     | None -> Ok { serving_provider; provider_errors; search })
  | _ -> Error "a web_search result must be an object"

let request_of_json = function
  | `Assoc fields ->
    let known = [ "kind"; "request_id"; "query"; "limit" ] in
    (match List.find_opt (fun (key, _) -> not (List.mem key known)) fields with
     | Some (key, _) -> Error ("a web_search request has no key " ^ key)
     | None ->
       let request_id = match List.assoc_opt "request_id" fields with
         | Some (`String id) when String.trim id <> "" -> Ok id
         | _ -> Error "a web_search request requires a non-blank request_id" in
       let query = match List.assoc_opt "query" fields with
         | Some (`String query) when String.trim query <> "" -> Ok query
         | _ -> Error "a web_search request requires a non-blank query" in
       let limit = match List.assoc_opt "limit" fields with
         | None | Some `Null -> Ok None
         | Some (`Int limit) when limit > 0 -> Ok (Some limit)
         | Some _ -> Error "limit must be a positive integer or null" in
       let* request_id = request_id in
       let* query = query in
       let* limit = limit in
       Ok { request_id; query; limit })
  | _ -> Error "a web_search request must be an object"

(* A package displays what it plans, not the plan summary's identity. *)
let plan_summary ?limit query =
  `Assoc [ "query", `String query;
           "limit", match limit with Some limit -> `Int limit | None -> `Null ]
