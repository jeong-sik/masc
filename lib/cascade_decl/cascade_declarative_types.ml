(** Declarative cascade configuration types (RFC-0058 v2).

    All type names are prefixed with [cascade_] to avoid collision with
    identically-named types in the main masc_mcp library.  OCaml type
    names are resolved globally across library boundaries via .cmi files;
    (include_subdirs no) only prevents source-file inclusion, not type
    name visibility.  Without prefixes, ppx_deriving-generated code
    references the wrong type when [provider], [transport], [binding],
    [strategy], or [tier] exist in both libraries. *)

type cascade_api_format =
  | Messages_api
  | Chat_completions_api
  | Ollama_api
[@@deriving show, eq]

type cascade_transport =
  | Http of string
  | Cli of string
[@@deriving show, eq]

type cascade_credential =
  | Env of string
  | File of string
  | Inline of string
[@@deriving show, eq]

type cascade_provider = {
  id : string;
  display_name : string;
  api_format : cascade_api_format;
  transport : cascade_transport;
  is_non_interactive : bool;
  credentials : cascade_credential option;
}
[@@deriving show, eq]

type cascade_model_spec = {
  id : string;
  api_name : string;
  tools_support : bool;
  max_context : int;
  thinking_support : bool;
  max_thinking_budget : int option;
  streaming : bool;
}
[@@deriving show, eq]

type cascade_binding = {
  provider_id : string;
  model_id : string;
  is_default : bool;
  max_concurrent : int;
  price_input : float option;
  price_output : float option;
  keep_alive : string option;
  num_ctx : int option;
}
[@@deriving show, eq]

type cascade_alias = {
  provider_id : string;
  model_id : string;
  name : string;
  max_input : int option;
  max_output : int option;
  temperature : float option;
  thinking_enabled : bool option;
  thinking_budget : int option;
}
[@@deriving show, eq]

type cascade_strategy =
  | Failover
  | Capacity_aware
  | Weighted_random
  | Circuit_breaker_cycling
  | Priority_tier
  | Sticky
  | Round_robin
[@@deriving show, eq]

type cascade_tier = {
  name : string;
  members : string list;
  strategy : cascade_strategy;
  max_concurrent : int option;
}
[@@deriving show, eq]

type cascade_tier_group = {
  name : string;
  tiers : string list;
  strategy : cascade_strategy;
  fallback : bool;
}
[@@deriving show, eq]

type cascade_route = {
  name : string;
  target : string;
}
[@@deriving show, eq]

type cascade_config = {
  providers : cascade_provider list;
  models : cascade_model_spec list;
  bindings : cascade_binding list;
  aliases : cascade_alias list;
  tiers : cascade_tier list;
  tier_groups : cascade_tier_group list;
  routes : cascade_route list;
  system_targets : cascade_route list;
}
[@@deriving show, eq]

(** {1 Lookup helpers} *)

let provider_of_id (cfg : cascade_config) (id : string) :
    cascade_provider option =
  List.find_opt (fun (p : cascade_provider) -> p.id = id) cfg.providers

let model_of_id (cfg : cascade_config) (id : string) :
    cascade_model_spec option =
  List.find_opt (fun (m : cascade_model_spec) -> m.id = id) cfg.models

let binding_of_key (cfg : cascade_config)
    (provider_id : string) (model_id : string) : cascade_binding option =
  List.find_opt
    (fun (b : cascade_binding) ->
       b.provider_id = provider_id && b.model_id = model_id)
    cfg.bindings

let alias_of_key (cfg : cascade_config)
    (provider_id : string) (model_id : string) (name : string) :
    cascade_alias option =
  List.find_opt
    (fun (a : cascade_alias) ->
       a.provider_id = provider_id && a.model_id = model_id && a.name = name)
    cfg.aliases

let binding_key (b : cascade_binding) : string =
  Printf.sprintf "%s.%s" b.provider_id b.model_id

let alias_key (a : cascade_alias) : string =
  Printf.sprintf "%s.%s.%s" a.provider_id a.model_id a.name
