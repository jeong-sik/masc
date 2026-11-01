(** Catalog-backed cost observation.

    Pricing is declared exclusively by {!Model_catalog}.  This module does not
    infer provider identity from a model ID, strip namespaces, maintain a
    fallback table, or treat an unknown model as free. *)

type pricing =
  { input_per_million : float
  ; output_per_million : float
  ; cache_write_multiplier : float option
  ; cache_read_multiplier : float option
  }

type provider_scope =
  | Provider_reference of Model_catalog.provider_reference
  | Selected_provider of Model_catalog.provider_entry

type source =
  { catalog : Model_catalog.t option
  ; scope : provider_scope
  }

let of_catalog ~catalog ~provider = {catalog; scope = Provider_reference provider}
let of_provider_entry ~catalog ~provider = {catalog; scope = Selected_provider provider}

let of_snapshot ~snapshot ~provider =
  of_catalog ~catalog:(Catalog_snapshot.model_catalog_for_provider snapshot provider) ~provider

type cache_price_component =
  | Cache_creation
  | Cache_read

type cost_estimate =
  | Estimated of float
  | Incomplete of cache_price_component list

let pricing_of_catalog_entry (entry : Model_catalog.model_entry) =
  match entry.input_per_million, entry.output_per_million with
  | Some input_per_million, Some output_per_million ->
    Some
      { input_per_million
      ; output_per_million
      ; cache_write_multiplier = entry.cache_write_multiplier
      ; cache_read_multiplier = entry.cache_read_multiplier
      }
  | None, _ | _, None -> None
;;

let pricing_for_model source model_id =
  match source.catalog, Model_identifiers.Model_id.of_string model_id with
  | None, _ | _, Error _ -> None
  | Some catalog, Ok model_id ->
    let row = match source.scope with
      | Provider_reference provider ->
        Model_catalog.lookup_model_for_provider catalog ~provider ~model_id
      | Selected_provider provider ->
        Model_catalog.lookup_model_for_provider_entry catalog ~provider ~model_id
    in
    Option.bind row pricing_of_catalog_entry
;;

let pricing_for_model_opt ?provider model_id =
  let snapshot = Catalog_snapshot.current () in
  match provider with
  | Some provider -> pricing_for_model (of_snapshot ~snapshot ~provider) model_id
  | None ->
    (match Catalog_snapshot.models snapshot, Model_identifiers.Model_id.of_string model_id with
     | None, _ | _, Error _ -> None
     | Some catalog, Ok model_id ->
       Option.bind (Model_catalog.lookup catalog model_id) pricing_of_catalog_entry)
;;

let estimate_cost
      ~(pricing : pricing)
      ~input_tokens
      ~output_tokens
      ?(cache_creation_input_tokens = 0)
      ?(cache_read_input_tokens = 0)
      ()
  =
  let regular_input =
    max 0 (input_tokens - cache_creation_input_tokens - cache_read_input_tokens)
  in
  let missing_cache_components =
    let creation =
      if cache_creation_input_tokens > 0 && Option.is_none pricing.cache_write_multiplier
      then [ Cache_creation ]
      else []
    in
    let read =
      if cache_read_input_tokens > 0 && Option.is_none pricing.cache_read_multiplier
      then [ Cache_read ]
      else []
    in
    creation @ read
  in
  match missing_cache_components with
  | _ :: _ as missing -> Incomplete missing
  | [] ->
    let rate = pricing.input_per_million /. 1_000_000.0 in
    let input_cost = Float.of_int regular_input *. rate in
    let cache_cost token_count = function
      | Some multiplier -> Float.of_int token_count *. rate *. multiplier
      | None -> 0.0
    in
    let cache_write_cost =
      cache_cost cache_creation_input_tokens pricing.cache_write_multiplier
    in
    let cache_read_cost =
      cache_cost cache_read_input_tokens pricing.cache_read_multiplier
    in
    let output_cost =
      Float.of_int output_tokens *. pricing.output_per_million /. 1_000_000.0
    in
    Estimated (input_cost +. cache_write_cost +. cache_read_cost +. output_cost)
;;

let annotate_usage_cost ~source ~model_id (usage : Types.api_usage) =
  match usage.cost_usd with
  | Some _ -> usage
  | None ->
    (match pricing_for_model source model_id with
     | None -> usage
     | Some pricing ->
       (match
          estimate_cost
            ~pricing
            ~input_tokens:usage.input_tokens
            ~output_tokens:usage.output_tokens
            ~cache_creation_input_tokens:usage.cache_creation_input_tokens
            ~cache_read_input_tokens:usage.cache_read_input_tokens
            ()
        with
        | Estimated cost_usd -> { usage with cost_usd = Some cost_usd }
        | Incomplete _ -> usage))
;;

let annotate_response_cost ~source (response : Types.api_response) =
  match response.usage with
  | None -> response
  | Some usage ->
    let model_id = match Option.bind response.telemetry (fun telemetry -> telemetry.Types.reported_model) with
      | Some (Types.Provider_reported_model model) -> Some model
      | Some Types.Provider_model_not_reported | None -> None in
    let usage = match model_id with
      | Some model_id -> annotate_usage_cost ~source ~model_id usage
      | None -> usage in
    { response with
      usage = Some usage
    }
;;

[@@@coverage off]

let admit_fixture_catalogs ~models ~providers =
  match Catalog_snapshot.of_catalogs ~models ~providers with
  | Ok snapshot -> snapshot
  | Error error -> failwith (Catalog_snapshot.error_to_string error)
;;

let close_enough a b = Float.abs (a -. b) < 1e-9

let[@warning "-32"] option_close_enough expected = function
  | Some actual -> close_enough expected actual
  | None -> false
;;

let[@warning "-32"] test_catalog_entry
      ?provider_name
      ?input
      ?output
      ?cache_write
      ?cache_read
      model_id
  =
  let string_field name = function
    | None -> ""
    | Some value -> Printf.sprintf "%s = %S\n" name value
  in
  let float_field name = function
    | None -> ""
    | Some value -> Printf.sprintf "%s = %.17e\n" name value
  in
  Printf.sprintf "[[models]]\nmodel_id = %S\n%s%s%s%s%s"
    model_id
    (string_field "provider_name" provider_name)
    (float_field "input_per_million" input)
    (float_field "output_per_million" output)
    (float_field "cache_write_multiplier" cache_write)
    (float_field "cache_read_multiplier" cache_read)
;;

let[@warning "-32"] with_catalog entries f =
  let original = Catalog_snapshot.current () in
  let catalog =
    Model_catalog.of_toml_string ~source:"pricing inline fixture"
      (String.concat "\n" entries)
    |> Result.get_ok
  in
  Catalog_snapshot.publish (admit_fixture_catalogs ~models:(Some (catalog)) ~providers:(None));
  Fun.protect
    ~finally:(fun () ->
      Catalog_snapshot.publish original)
    f
;;

let%test "catalog-declared pricing is returned" =
  with_catalog
    [ test_catalog_entry
        ~input:3.0
        ~output:15.0
        ~cache_write:1.25
        ~cache_read:0.1
        "declared-model"
    ]
    (fun () ->
       match pricing_for_model_opt "declared-model" with
       | None -> false
       | Some pricing ->
         close_enough pricing.input_per_million 3.0
         && close_enough pricing.output_per_million 15.0
         && option_close_enough 1.25 pricing.cache_write_multiplier
         && option_close_enough 0.1 pricing.cache_read_multiplier)
;;

let%test "catalog miss remains absent" =
  with_catalog
    [ test_catalog_entry ~input:1.0 ~output:2.0 "declared-model" ]
    (fun () -> pricing_for_model_opt "unknown-model" = None)
;;

let%test "partial catalog pricing remains absent" =
  with_catalog
    [ test_catalog_entry ~input:1.0 "partial-model" ]
    (fun () -> pricing_for_model_opt "partial-model" = None)
;;

let%test "catalog pricing preserves absent cache multipliers" =
  with_catalog
    [ test_catalog_entry ~input:1.0 ~output:2.0 "partial-cache-pricing" ]
    (fun () ->
       match pricing_for_model_opt "partial-cache-pricing" with
       | Some
           { input_per_million = 1.0
           ; output_per_million = 2.0
           ; cache_write_multiplier = None
           ; cache_read_multiplier = None
           } -> true
       | Some _ | None -> false)
;;

let%test "exact provider pricing precedes provider-independent pricing" =
  with_catalog
    [ test_catalog_entry
        ~input:9.0
        ~output:90.0
        ~cache_write:1.0
        ~cache_read:1.0
        "shared-model"
    ; test_catalog_entry
        ~provider_name:"deepseek"
        ~input:1.0
        ~output:2.0
        ~cache_write:1.0
        ~cache_read:0.1
        "shared-model"
    ]
    (fun () ->
       match
         ( pricing_for_model_opt "shared-model"
         , pricing_for_model_opt ~provider:(Model_catalog.Declared_provider "deepseek") "shared-model" )
       with
       | Some generic, Some exact ->
         close_enough generic.input_per_million 9.0
         && close_enough exact.input_per_million 1.0
       | None, _ | _, None -> false)
;;

let%test "an exact incomplete provider row does not fall through to generic pricing" =
  with_catalog
    [ test_catalog_entry
        ~input:9.0
        ~output:90.0
        ~cache_write:1.0
        ~cache_read:1.0
        "shared-model"
    ; test_catalog_entry ~provider_name:"ollama_cloud" ~input:0.0 "shared-model"
    ]
    (fun () -> pricing_for_model_opt ~provider:(Model_catalog.Declared_provider "ollama_cloud") "shared-model" = None)
;;

let%test "unknown declared provider cannot borrow provider-independent pricing" =
  with_catalog
    [ test_catalog_entry
        ~input:9.0
        ~output:90.0
        ~cache_write:1.0
        ~cache_read:1.0
        "shared-model"
    ]
    (fun () ->
       pricing_for_model_opt ~provider:(Model_catalog.Declared_provider "unknown") "shared-model" = None)
;;

let%test "explicit catalog zero is distinguishable from absence" =
  with_catalog
    [ test_catalog_entry
        ~input:0.0
        ~output:0.0
        ~cache_write:1.0
        ~cache_read:1.0
        "declared-free-model"
    ]
    (fun () ->
       match pricing_for_model_opt "declared-free-model" with
       | Some pricing ->
         close_enough pricing.input_per_million 0.0
         && close_enough pricing.output_per_million 0.0
       | None -> false)
;;

let%test "estimate_cost uses declared rates" =
  let pricing =
    { input_per_million = 3.0
    ; output_per_million = 15.0
    ; cache_write_multiplier = Some 1.25
    ; cache_read_multiplier = Some 0.1
    }
  in
  match estimate_cost ~pricing ~input_tokens:1_000_000 ~output_tokens:100_000 () with
  | Estimated cost -> close_enough cost 4.5
  | Incomplete _ -> false
;;

let%test "absent cache prices do not block a non-cache estimate" =
  let pricing =
    { input_per_million = 3.0
    ; output_per_million = 15.0
    ; cache_write_multiplier = None
    ; cache_read_multiplier = None
    }
  in
  match estimate_cost ~pricing ~input_tokens:1_000_000 ~output_tokens:100_000 () with
  | Estimated cost -> close_enough cost 4.5
  | Incomplete _ -> false
;;

let%test "observed cache tokens expose every missing cache price" =
  let pricing =
    { input_per_million = 3.0
    ; output_per_million = 15.0
    ; cache_write_multiplier = None
    ; cache_read_multiplier = None
    }
  in
  match
    estimate_cost
      ~pricing
      ~input_tokens:100
      ~output_tokens:10
      ~cache_creation_input_tokens:20
      ~cache_read_input_tokens:30
      ()
  with
  | Incomplete components -> components = [ Cache_creation; Cache_read ]
  | Estimated _ -> false
;;

[@@@coverage on]
