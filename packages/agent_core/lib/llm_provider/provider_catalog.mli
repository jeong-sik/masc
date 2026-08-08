(** External provider catalog overlay.

    Provider entries describe connection and runtime metadata without teaching
    OAS about any downstream coordinator. The catalog augments
    {!Provider_registry.default}: built-in entries remain as seed data, while
    file/runtime catalog entries overwrite or add provider ids at process
    startup.

    @since 0.194.0 *)

type auth_mode =
  | No_auth
  | Api_key_env of string
  | Setup_token_env of string
[@@deriving show]

type entry =
  { id : string
  ; aliases : string list
  ; kind : Provider_config.provider_kind
  ; base_url : string
  ; request_path : string
  ; api_key_env : string
  ; auth : auth_mode
  ; default_model : string option
  ; max_context : int option
  ; capabilities : Capabilities.capabilities
  ; credential_scope : string option
  }

type t

(** Build a catalog from typed entries while enforcing the same closed
    invariants as the JSON boundary: unique provider ids/aliases, exact
    endpoint/default-model/auth strings, positive limits, auth/env consistency,
    and tool-choice capability dependencies. *)
val of_entries : entry list -> (t, string) result

(** Return catalog entries in declaration order. *)
val entries : t -> entry list

(** Parse a provider catalog JSON document.

    Expected top-level shape:

    {[
      {
        "schema_version": 1,
        "providers": [
          {
            "id": "vllm-local",
            "kind": "openai_compat",
            "base_url": "http://127.0.0.1:8000",
            "request_path": "/v1/chat/completions",
            "auth": {"type": "none"},
            "capabilities_base": "openai_chat",
            "capabilities": {"supports_tools": true}
          }
        ]
      }
    ]}

    Catalog, provider, auth, and capability objects are closed: duplicate and
    unknown fields are rejected. Optional fields may be absent or [null]; a
    present value must have its declared type. Integer limits must be positive
    and fit OCaml's [int], while string-list items must be exact non-empty
    strings. Capability overrides are accepted only inside the nested
    [capabilities] object. *)
val of_json : Yojson.Safe.t -> (t, string) result

val load_file : string -> (t, string) result

(** Find an entry by id or alias.

    Lookup is case-insensitive (id and alias are trimmed + lowercased
    before comparison). {!of_entries} and {!of_json} reject empty, padded, or
    duplicate identities, including collisions between ids and aliases. *)
val lookup : t -> string -> entry option

(** Return an entry's explicit default model by id or alias. *)
val default_model_for_provider : t -> string -> string option

(** Process-wide catalog overlay.

    Returns only the runtime override installed explicitly with {!set_global};
    [None] means no overlay. OAS never discovers a provider catalog from the
    process environment. Callers that need a JSON overlay must call
    {!load_file} and {!set_global}. *)
val global : unit -> t option

val set_global : t -> unit
val clear_global : unit -> unit
