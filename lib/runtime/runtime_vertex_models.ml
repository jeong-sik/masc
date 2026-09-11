type model = { id : string; display_name : string }
type page = { models : model list; next_page_token : string option }

let parse_page body =
  let ( let* ) = Result.bind in
  let model = function
    | `Assoc fields ->
      (match List.assoc_opt "name" fields with
       | Some (`String name) ->
         (match String.split_on_char '/' name with
          | ["publishers"; "google"; "models"; id] when id <> "" ->
            let display_name = match List.assoc_opt "displayName" fields with
              | Some (`String value) when String.trim value <> "" -> value
              | _ -> id in
            Ok {id; display_name}
          | _ -> Error "Vertex returned an invalid Google publisher model name")
       | _ -> Error "Vertex returned a model without its resource name")
    | _ -> Error "Vertex returned an invalid model entry"
  in
  try
    match Yojson.Safe.from_string body with
    | `Assoc fields ->
      let* rows = match List.assoc_opt "publisherModels" fields with
        | None -> Ok [] | Some (`List rows) -> Ok rows
        | _ -> Error "Vertex returned an invalid publisherModels list" in
      let* next_page_token = match List.assoc_opt "nextPageToken" fields with
        | None | Some (`String "") -> Ok None
        | Some (`String value) -> Ok (Some value)
        | _ -> Error "Vertex returned an invalid page token" in
      let* reversed = List.fold_left (fun result row ->
        let* rows = result in let* row = model row in Ok (row :: rows)) (Ok []) rows in
      Ok {models=List.rev reversed; next_page_token}
    | _ -> Error "Vertex returned an invalid publisher model response"
  with Yojson.Json_error _ -> Error "Vertex returned invalid JSON"

let discover_with ~get ~base_url =
  let ( let* ) = Result.bind in
  let* _ = Llm_provider.Vertex_endpoint.parse_base_url base_url in
  let root = Uri.of_string base_url |> fun uri ->
    Uri.with_path uri "/v1beta1/publishers/google/models" in
  let rec pages seen token rows =
    let uri = match token with None -> root | Some token -> Uri.add_query_param' root ("pageToken",token) in
    let* body = get ~url:(Uri.to_string uri) in
    let* page = parse_page body in
    let rows = List.rev_append page.models rows in
    match page.next_page_token with
    | None -> Ok (List.rev rows)
    | Some next when List.mem next seen -> Error "Vertex repeated a model-list page token"
    | Some next -> pages (next :: seen) (Some next) rows
  in pages [] None []

let discover ~sw ~net ~base_url =
  let source = Runtime_google_adc.credential_source () in
  let config = Llm_provider.Provider_config.make ~kind:Gemini ~model_id:""
    ~base_url ~auth_scheme:Bearer_token ~credential_source:source () in
  let get ~url =
    let ( let* ) = Result.bind in
    let* headers = Llm_provider.Provider_config.resolve_auth_headers config in
    match Llm_provider.Http_client.get_sync ~sw ~net ~url ~headers () with
    | Error _ -> Error "Vertex model discovery request failed"
    | Ok response when response.status >= 200 && response.status < 300 -> Ok response.body
    | Ok response -> Error (Printf.sprintf "Vertex model discovery returned HTTP %d" response.status)
  in
  Result.map (fun models -> `Assoc [
    "source", `String "vertex_publisher_models_api";
    "account_availability_verified", `Bool false;
    "models", `List (List.map (fun model -> `Assoc [
      "id", `String model.id; "display_name", `String model.display_name;
      "account_availability_verified", `Bool false]) models)])
    (discover_with ~get ~base_url)
