(** Keeper prompt and provider-input reads for the dashboard: the last prompt
    the keeper was told, and what one turn's request to the provider held. *)

val handle_last_prompt_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/last-prompt] with the keeper's last
    assembled prompt as text. A keeper with no capture answers 404, and an
    unknown keeper or a malformed capture 400. *)

val handle_provider_input_continuity_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/provider-input/continuity?turn_ref=...]
    with the continuity evidence of one turn. The three provider-input handlers
    name one keeper and one exact turn: an empty or invalid keeper name, or a
    missing or invalid [turn_ref], answers 400. A snapshot or part that does not
    exist answers 404, and a store that cannot be read or is inconsistent 503.
    The read runs on the CPU pool. *)

val handle_provider_input_part_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/provider-input/part?turn_ref=...&index=...]
    with the content of one part of the turn's request. A missing, negative or
    non-numeric [index] answers 400. *)

val handle_provider_input_manifest_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/provider-input?turn_ref=...] with the
    manifest of the parts of the turn's request. *)

val handle_cache_outcome_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
(** Answer [GET /api/v1/keepers/<name>/cache-outcome?turn_ref=...] with
    {!Keeper_cache_outcome_json.to_json}: why the turn's first request read or
    rewrote the prompt cache. The name and [turn_ref] are checked as for the
    provider-input doors, and a Keeper without a readable creation time
    answers 400. A cost ledger that cannot be read answers 503.

    A runtime's default lifetime is the one the catalog declares for the
    provider that answers it in the running configuration. The read runs on
    the CPU pool. *)
