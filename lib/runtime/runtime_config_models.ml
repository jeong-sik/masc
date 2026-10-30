type context_source = Binding | Provider | Model

type binding = {
  model : string;
  provider : string;
  api_name : string;
  reasoning_effort : Llm_provider.Reasoning_effort.t option;
  temperature : float option;
  context : (context_source * int) option;
  model_context : int option;
  max_tokens : int option;
}

type t = { provider_ids : string list; bindings : binding list }

module Names = Map.Make (String)
module Ids = Set.Make (String)
module Bindings = Set.Make (struct
  type t = string * string
  let compare = Stdlib.compare
end)

open Result.Syntax

let map_result f values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest -> let* value = f value in loop (value :: acc) rest in
  loop [] values

let index ~id values =
  List.fold_left (fun acc value ->
    let* known = acc in
    let name = id value in
    if String.equal name "" || Names.mem name known
    then Error "empty or duplicate Runtime declaration identity"
    else Ok (Names.add name value known)) (Ok Names.empty) values

let positive = function None -> true | Some n -> n > 0

let checked provider_ids bindings =
  let* providers = List.fold_left (fun acc id ->
    let* known = acc in
    if String.equal id "" || Ids.mem id known
    then Error "empty or duplicate projected provider identity"
    else Ok (Ids.add id known)) (Ok Ids.empty) provider_ids in
  let* _ = List.fold_left (fun acc (row : binding) ->
    let* known = acc in
    let key = row.provider, row.model in
    if String.equal row.model ""
       || not (Ids.mem row.provider providers) || Bindings.mem key known
    then Error "invalid or duplicate projected binding identity"
    else if not (positive row.model_context && positive row.max_tokens
                 && positive (Option.map snd row.context))
    then Error "invalid projected token declaration"
    else if not (match row.context, row.model_context with
      | None, None -> true
      | Some (Model, n), Some declared -> n = declared
      | Some ((Binding | Provider), _), _ -> true
      | None, Some _ | Some (Model, _), None -> false)
    then Error "context declaration contradicts its model provenance"
    else if Option.fold ~none:false ~some:(fun n -> not (Float.is_finite n)) row.temperature
    then Error "nonfinite projected temperature"
    else Ok (Bindings.add key known)) (Ok Bindings.empty) bindings in
  Ok {provider_ids; bindings}

let of_config (config : Runtime_schema.config) =
  let* providers = index ~id:(fun (p : Runtime_schema.provider) -> p.id) config.providers in
  let* models = index ~id:(fun (m : Runtime_schema.model_spec) -> m.id) config.models in
  let* bindings = map_result (fun (b : Runtime_schema.binding) ->
    match Names.find_opt b.provider_id providers, Names.find_opt b.model_id models with
    | Some provider, Some model ->
        let context = match b.max_context, provider.max_context, model.max_context with
          | Some n, _, _ -> Some (Binding, n)
          | None, Some n, _ -> Some (Provider, n)
          | None, None, Some n -> Some (Model, n)
          | None, None, None -> None in
        Ok {model=model.id; provider=provider.id; api_name=model.api_name;
            reasoning_effort=model.reasoning_effort; temperature=model.temperature;
            context; model_context=model.max_context; max_tokens=b.max_tokens}
    | None, _ | _, None -> Error "projected binding refers to an absent declaration") config.bindings in
  checked (List.map (fun (p : Runtime_schema.provider) -> p.id) config.providers) bindings

let context_name = function Binding -> "binding" | Provider -> "provider" | Model -> "model"
let optional encode = function None -> `Null | Some value -> encode value
let binding_json (row : binding) =
  `Assoc ["model", `String row.model; "provider", `String row.provider;
    "api_name", `String row.api_name;
    "reasoning_effort", optional (fun e -> `String (Llm_provider.Reasoning_effort.to_string e)) row.reasoning_effort;
    "temperature", optional (fun n -> `Float n) row.temperature;
    "context", optional (fun (source, tokens) ->
      `Assoc ["source", `String (context_name source); "tokens", `Int tokens]) row.context;
    "model_context", optional (fun n -> `Int n) row.model_context;
    "max_tokens", optional (fun n -> `Int n) row.max_tokens]

let to_json ~path ~source_revision result =
  let outcome = match result with
    | Error detail -> `Assoc ["status", `String "unavailable"; "detail", `String detail]
    | Ok projection -> `Assoc ["status", `String "available";
        "provider_ids", `List (List.map (fun id -> `String id) projection.provider_ids);
        "bindings", `List (List.map binding_json projection.bindings)] in
  `Assoc ["path", `String path; "source_revision", `String source_revision; "outcome", outcome]

let field key = function
  | `Assoc fields -> (match List.filter (fun (name, _) -> String.equal name key) fields with
      | [(_, value)] -> Ok value
      | [] -> Error ("missing model projection field: " ^ key)
      | _ -> Error ("duplicate model projection field: " ^ key))
  | _ -> Error "expected model projection object"
let string = function `String s -> Ok s | _ -> Error "expected projected string"
let integer = function `Int n -> Ok n | _ -> Error "expected projected integer"
let number = function
  | `Float n -> Ok n | `Int n -> Ok (float_of_int n)
  | _ -> Error "expected projected number"
let get parse key json = let* value = field key json in parse value
let nullable parse = function `Null -> Ok None | value -> Result.map Option.some (parse value)
let list parse = function `List rows -> map_result parse rows | _ -> Error "expected projected array"
let effort json =
  let* text = string json in
  match Llm_provider.Reasoning_effort.of_string text with
  | Some effort -> Ok effort | None -> Error "unknown projected reasoning effort"
let context json =
  let* source = get string "source" json in
  let* source = match source with
    | "binding" -> Ok Binding | "provider" -> Ok Provider | "model" -> Ok Model
    | _ -> Error "unknown context declaration source" in
  let* tokens = get integer "tokens" json in
  Ok (source, tokens)
let binding json =
  let* model = get string "model" json in
  let* provider = get string "provider" json in
  let* api_name = get string "api_name" json in
  let* reasoning_effort = get (nullable effort) "reasoning_effort" json in
  let* temperature = get (nullable number) "temperature" json in
  let* context = get (nullable context) "context" json in
  let* model_context = get (nullable integer) "model_context" json in
  let* max_tokens = get (nullable integer) "max_tokens" json in
  Ok {model; provider; api_name; reasoning_effort; temperature; context; model_context; max_tokens}

let of_json ~path ~source_revision json =
  let* observed_path = get string "path" json in
  let* observed_revision = get string "source_revision" json in
  let* () =
    if String.equal path "" || String.equal source_revision ""
       || not (String.equal path observed_path && String.equal source_revision observed_revision)
    then Error "model projection belongs to another source observation" else Ok () in
  let* outcome = field "outcome" json in
  let* status = get string "status" outcome in
  match status with
  | "unavailable" -> let* detail = get string "detail" outcome in Error detail
  | "available" ->
      let* provider_ids = get (list string) "provider_ids" outcome in
      let* bindings = get (list binding) "bindings" outcome in
      checked provider_ids bindings
  | _ -> Error "unknown model projection outcome"
