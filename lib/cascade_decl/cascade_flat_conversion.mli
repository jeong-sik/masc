(** Flat cascade.toml → 5-layer declarative TOML conversion (RFC-0058 Phase 4).

    Public interface for the conversion logic used by both the CLI tool
    and unit tests.

    @stability Internal *)

(* --- Provider info --- *)

type provider_info = {
  id : string;
  protocol : string;
  transport_kind : [ `Cli of string | `Http of string ];
  is_non_interactive : bool;
}

val provider_registry : provider_info list
val info_of_prefix : string -> provider_info option

(* --- Model string parsing --- *)

val parse_model_string : string -> string * string
(** "prefix:model_id" → (prefix, model_id) *)

(* --- Flat TOML types --- *)

type flat_model_entry = {
  model_string : string;
  supports_tool_choice : bool option;
  weight : int;
}

type flat_profile = {
  name : string;
  models : flat_model_entry list;
  temperature : float option;
  max_tokens : int option;
  thinking_enabled : bool option;
  keeper_assignable : bool;
  fallback_cascade : string option;
  required_capability_profile : string option;
}

(* --- Conversion --- *)

type conversion_result = {
  providers : (string * provider_info) list;
  models : (string * string * string) list;
  bindings : (string * string) list;
  profiles : flat_profile list;
  routes : (string * string) list;
}

val convert : Otoml.t -> conversion_result
(** Parse flat TOML into intermediate conversion result. *)

val convert_and_emit : Otoml.t -> string
(** Parse flat TOML and emit 5-layer declarative TOML string. *)
