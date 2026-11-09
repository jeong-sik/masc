(** Pure decoder and immutable external provider catalog.

    Provider entries describe connection and runtime metadata without teaching
    AGENT_CORE about any downstream coordinator. {!Catalog_snapshot.of_catalogs}
    admits this explicit overlay with model seeds before the whole selection
    can be published. This decoder owns no process-wide publication state.

    @since 0.194.0 *)

type auth_mode =
  | No_auth
  | Api_key_env of string
  | Setup_token_env of string
[@@deriving show]

type entry =
  { id : string
  ; aliases : string list
  ; kind : Provider_kind.t
  ; base_url : string
  ; request_path : string
  ; auth : auth_mode
  ; default_model : string option
  ; discovery_timeout_s : float option
    (** Positive finite total deadline for one discovery HTTP request. *)
  ; max_context : int option
  ; capabilities : Capability_profile.capabilities option
    (** [None] explicitly declares models-only policy. An unknown model obtains
        no provider-wide profile; this never represents an omitted JSON field. *)
  ; credential_scope : string option
  }

type t

(** Build a catalog from typed entries while enforcing the same closed
    invariants as the JSON boundary: unique provider ids/aliases, exact
    endpoint/default-model/auth strings, positive limits, typed auth environments,
    and tool-choice capability dependencies. The [auth] sum is the sole
    credential carrier; there is no duplicate environment-key field. *)
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

    Provider id, kind, base_url, request_path, auth object/type and
    capabilities_base are required and cannot be [null]. The explicit
    [capabilities_base="models_only"] choice accepts no provider-wide
    capability overrides. Named presets are resolved from the closed vocabulary.
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
