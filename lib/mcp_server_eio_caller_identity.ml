type owner_keeper_identity = string * string option

type direct_call_authority =
  | Catalog_policy
  | Restricted_profile

type t = {
  agent_name : string;
  agent_name_is_ephemeral : bool;
      (** Ephemerality of [agent_name] decided from the carried origin
          (the re-tagged [minted_name] after the auth-token fallback),
          for the resolved-name cache to store without a substring
          re-probe. Computed before [resolve_explicit_bound_alias],
          which only rewrites [Stable] (explicit) names — those carry
          [false], and a [false] bit re-derives correctly on read-back,
          so the pre-alias computation stays behavior-exact. *)
  token : string option;
  has_explicit_agent_name : bool;
  verified_internal_keeper_runtime : bool;
  owner_keeper_identity : owner_keeper_identity option;
  mode_gate_error : string option;
}

let silent_auth_token_error_kind err =
  Auth_error_kind.to_string (Auth_error_kind.classify err)

let caller_agent_name_from_arguments arguments =
  let nonempty_nonunknown key =
    match Safe_ops.json_string_opt key arguments with
    | Some value ->
        let value = String.trim value in
        if value <> "" && value <> "unknown" then
          Some value
        else
          None
    | None -> None
  in
  match nonempty_nonunknown "_agent_name" with
  | Some _ as value -> value
  | None -> None

let direct_call_block_message name =
  Printf.sprintf
    "Tool '%s' is hidden from the default tool surface and not callable directly."
    name

let resolve_owner_keeper_identity config owner_name =
  let candidates =
    [
      Keeper_identity.canonical_keeper_name owner_name;
      Keeper_identity.canonical_keeper_name_from_agent_name owner_name;
    ]
    |> List.filter_map (function
         | Some value ->
             let trimmed = String.trim value in
             if trimmed <> "" then
               Some trimmed
             else
               None
         | None -> None)
    |> List.sort_uniq String.compare
  in
  let rec loop = function
    | [] -> None
    | candidate :: rest -> (
        match Keeper_meta_store.read_meta_resolved config candidate with
        | Ok (Some (resolved_name, meta)) ->
            Some
              (resolved_name, Option.map Keeper_id.Uid.to_string meta.keeper_id)
        | Ok None -> loop rest
        | Error _ -> loop rest)
  in
  loop candidates

(** A resolved caller name tagged with the origin decided at mint time.

    Replaces [Client_name_kind], a standalone string classifier whose
    [is_transient name = String.starts_with name ~prefix:"agent-" ||
    Nickname.is_dictionary_generated_nickname name] re-derived a name's
    origin at auth-fallback read time. The cache and
    [Client_identity.from_mcp_params] launder a known-system-ephemeral
    ["agent-…"] origin into a bare [string], so by read time the origin
    is gone and only a substring probe could recover it. Carrying the
    origin from where the name is minted lets the gate match a typed
    value instead.

    - [Stable] — caller supplied [_agent_name]; a stable identity.
    - [Ephemeral] — system-minted (own generated ["agent-…"] fallback,
      a [`System_fallback] identity, or a cached ephemeral name).
    - [Resolved_external] — a name that did not originate in this
      process as a fallback (caller-supplied tool-domain [agent_name],
      or a cached non-ephemeral name). It must not be reclassified by
      string shape, because that rewrites explicit generated aliases to
      the bearer-token owner. *)
type minted_name =
  | Stable of string
  | Ephemeral of string
  | Resolved_external of string

let minted_name_to_string = function
  | Stable s | Ephemeral s | Resolved_external s -> s

let resolve_initial_agent_name ~identity ~cached_resolved_agent ~explicit_agent_name =
  let identity_session_prefix =
    let len = min 8 (String.length identity.Client_identity.session_key) in
    if len = 0 then
      "anon"
    else
      String.sub identity.session_key 0 len
  in
  let generated_fallback_agent_name =
    Printf.sprintf "agent-%s" identity_session_prefix
  in
  match explicit_agent_name with
  | Some agent_name -> Stable agent_name
  | None -> (
      match cached_resolved_agent with
      | Some (cached, true) -> Ephemeral cached
      | Some (cached, false) -> Resolved_external cached
      | None ->
          if identity.Client_identity.agent_name <> "" then (
            match identity.Client_identity.agent_name_origin with
            | `System_fallback -> Ephemeral identity.Client_identity.agent_name
            | `Supplied -> Resolved_external identity.Client_identity.agent_name)
          else
            (* Own generated ["agent-%s"] fallback: system-minted. *)
            Ephemeral generated_fallback_agent_name)

(** Gate for the silent auth-token fallback: should a token resolve
    replace this minted name?

    Total match over [minted_name] — no [_ ->] wildcard, no standalone
    string classifier. Reproduces the old
    [(not has_explicit_agent_name)
     && (String.starts_with agent_name ~prefix:"agent-"
         || Nickname.is_dictionary_generated_nickname agent_name)]:

    - [Stable _] — caller supplied [_agent_name] ([has_explicit] was
      true), so the old [(not has_explicit)] guard was already [false].
      → [false].
    - [Ephemeral _] — system-minted (own ["agent-…"] fallback /
      [`System_fallback] identity / cached ephemeral). The old code
      reached these with [has_explicit = false] and they always matched
      [starts_with "agent-"] (the generated fallback) or were the
      laundered ephemeral origin. → [true].
    - [Resolved_external _] — caller-supplied tool-domain [agent_name]
      or a cached non-ephemeral name. Do not re-run the old string
      classifier here; explicit generated aliases are still explicit
      external identities and must not be silently rewritten by a bearer
      token. *)
let minted_name_is_transient = function
| Stable _ -> false
| Ephemeral _ -> true
| Resolved_external _ -> false

(** Apply the silent auth-token fallback, returning a re-tagged
    [minted_name].

    On a successful token resolve the result re-tags to
    [Resolved_external resolved] — NOT the stale pre-resolution
    [Ephemeral]. This is load-bearing for the cache bit: the
    ephemerality cached at the write site is
    [minted_name_is_transient] of THIS result, so a system placeholder
    that token-resolve replaces with a real credential name caches the
    new name's transience, not the placeholder's. Every branch returns
    a [minted_name] (failure and no-fire return the input unchanged). *)
let resolve_auth_fallback_agent_name
    ~(config : Workspace_utils_backend_setup.config)
    ~token
    (minted : minted_name) : minted_name =
  let agent_name = minted_name_to_string minted in
  match token with
  | Some t when minted_name_is_transient minted -> (
      match Auth.resolve_agent_from_token config.base_path ~token:t with
      | Ok resolved -> Resolved_external resolved
      | Error err ->
          let error_kind = silent_auth_token_error_kind err in
          Log.Auth.warn
            "[silent:auth_token_resolve_error] agent=%s error_kind=%s - token resolve \
             failed, keeping caller alias"
            agent_name error_kind;
          Otel_metric_store.inc_counter
            Otel_metric_store.metric_silent_auth_token_resolve_error
            ~labels:[ "error_kind", error_kind; "agent", agent_name ]
            ();
          let mode = Auth_strict_mode.current () in
          let mode_label = Auth_strict_mode.to_label mode in
          (match mode with
          | Auth_strict_mode.Off -> ()
          | Auth_strict_mode.Dry_run | Auth_strict_mode.Strict ->
              Log.Auth.warn
                "[would_reject:auth_token_resolve_error] mode=%s agent=%s error_kind=%s \
                 - Phase B PR-2 will reject this request"
                mode_label agent_name error_kind;
              Otel_metric_store.inc_counter
                Otel_metric_store.metric_auth_strict_would_reject
                ~labels:
                  [ "mode", mode_label; "error_kind", error_kind; "agent", agent_name ]
                ());
          (* Token resolve failed: keep the caller alias unchanged,
             preserving its origin tag. *)
          minted)
  | None -> minted
  | Some _ -> minted

let resolve_explicit_bound_alias ~config ~workspace_initialized ~log_mcp_exn
    ~has_explicit_agent_name agent_name =
  if has_explicit_agent_name && not (Nickname.is_generated_nickname agent_name)
  then (
    let resolved = Workspace.resolve_agent_name config agent_name in
    if resolved <> agent_name then (
      try
        if workspace_initialized () then (
          try
            if Workspace.is_agent_session_bound config ~agent_name:resolved then
              resolved
            else
              agent_name
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              log_mcp_exn ~label:"is_agent_session_bound" exn;
              agent_name)
        else
          agent_name
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          log_mcp_exn ~label:"resolve_explicit_bound_alias" exn;
          agent_name)
    else
      agent_name)
  else
    agent_name

let resolve ~(config : Workspace_utils_backend_setup.config) ~tool_name ~arguments ~identity
    ~cached_resolved_agent ~auth_token ~internal_keeper_runtime
    ~direct_call_authority ~workspace_initialized ~log_mcp_exn =
  let explicit_agent_name = caller_agent_name_from_arguments arguments in
  let has_explicit_agent_name = Option.is_some explicit_agent_name in
  let minted_name =
    resolve_initial_agent_name ~identity ~cached_resolved_agent ~explicit_agent_name
  in
  let token = auth_token in
  let verified_internal_keeper_runtime =
    internal_keeper_runtime
    &&
    match token with
    | Some raw -> Auth.verify_internal_keeper_token config.base_path ~token:raw
    | None -> false
  in
  let owner_keeper_identity =
    match token with
    | None -> None
    | Some raw -> (
        match Auth.resolve_agent_from_token config.base_path ~token:raw with
        | Ok owner_name -> resolve_owner_keeper_identity config owner_name
        | Error msg ->
            Log.Auth.routine
              "owner_keeper_identity: token resolve failed: %s"
              (Masc_domain.masc_error_to_string msg);
            None)
  in
  let mode_gate_error =
    if
      match direct_call_authority with
      | Restricted_profile -> false
      | Catalog_policy -> not (Tool_catalog.allow_direct_call tool_name)
    then
      Some (direct_call_block_message tool_name)
    else
      None
  in
  let resolved_minted =
    resolve_auth_fallback_agent_name ~config ~token minted_name
  in
  (* Ephemerality is decided here, from the carried/re-tagged origin —
     not re-derived from the string later. [resolve_explicit_bound_alias]
     can only rewrite [Stable] (explicit) names, which are non-ephemeral,
     so computing the bit before it is behavior-exact. *)
  let agent_name_is_ephemeral = minted_name_is_transient resolved_minted in
  (* Lower the typed minted name to a [string] once, after the gate
     decision. The record field [agent_name] stays a [string]. *)
  let agent_name = minted_name_to_string resolved_minted in
  let agent_name =
    resolve_explicit_bound_alias ~config ~workspace_initialized ~log_mcp_exn
      ~has_explicit_agent_name agent_name
  in
  {
    agent_name;
    agent_name_is_ephemeral;
    token;
    has_explicit_agent_name;
    verified_internal_keeper_runtime;
    owner_keeper_identity;
    mode_gate_error;
  }
