(** Catalog-backed cost observation.

    Pricing is sourced exclusively from {!Model_catalog}.  Unknown models and
    catalog rows without both input and output rates remain explicit [None];
    they are never classified as free. *)

type pricing =
  { input_per_million : float
  ; output_per_million : float
  ; cache_write_multiplier : float option
  ; cache_read_multiplier : float option
  }

(** Cache-price components that are required by observed usage but absent from
    the selected catalog row. *)
type cache_price_component =
  | Cache_creation
  | Cache_read

(** A cost observation is either exact for the supplied usage or explicitly
    incomplete.  Missing cache multipliers matter only when the corresponding
    observed token count is non-zero. *)
type cost_estimate =
  | Estimated of float
  | Incomplete of cache_price_component list

(** Return the price declared by the active model catalog.

    When [provider] is present, the authoritative scoped row takes precedence;
    bare rows are consulted only when that provider permits them. Omitting
    [provider] explicitly requests provider-independent pricing. Provider
    identity is never inferred from a model id or endpoint. Unknown providers,
    absent rates and missing cache multipliers remain unknown. *)
val pricing_for_model_opt
  : ?provider:Model_catalog.provider_reference -> string -> pricing option

(** Estimate USD cost from an explicit pricing value and provider token usage.
    This function never synthesizes a missing cache multiplier. *)
val estimate_cost
  :  pricing:pricing
  -> input_tokens:int
  -> output_tokens:int
  -> ?cache_creation_input_tokens:int
  -> ?cache_read_input_tokens:int
  -> unit
  -> cost_estimate

(** Fill [usage.cost_usd] only when catalog pricing is available and exact for
    the observed usage.  An absent or incomplete price remains absent. *)
val annotate_usage_cost
  :  ?provider:Model_catalog.provider_reference
  -> model_id:string
  -> Types.api_usage
  -> Types.api_usage

(** Apply {!annotate_usage_cost} to a response usage record. *)
val annotate_response_cost
  :  ?provider:Model_catalog.provider_reference
  -> Types.api_response
  -> Types.api_response
