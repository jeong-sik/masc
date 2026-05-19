(** See [auth_tool_authorization.mli] for the contract. *)

open Masc_domain

let permission_for_tool tool_name = Tool_permission_map.permission_for_tool tool_name

(** Strict tool auth mode:
    - 0/false: legacy fail-open for unknown tools
    - 1/true: unknown internal tools require at least worker-level permission *)
let is_tool_auth_strict_enabled () = Env_config_core.tool_auth_strict ()

(* #10205 finding 1: SSOT for the internal-tool prefix vocabulary.
   Adding a new internal namespace (e.g. [foo.]) was previously a
   two-predicate edit ([is_masc_tool_name] +
   [is_protocol_canonical_tool_name]) glued by a [||] chain at the
   call site.  Keep the prefixes in one list so the next addition
   is a single edit; predicate identity does not matter to callers,
   which only consume [is_unmapped_internal_tool_name].

   Keeper runtime tools are NOT a prefix: a [keeper_*] prefix
   alone is not enough to cross auth — the catalog must own the
   tool.  That check stays separate. *)
let internal_tool_prefixes = [ "masc_"; "decision."; "experiment."; "client." ]

let has_internal_tool_prefix tool_name =
  List.exists
    (fun pref -> String.starts_with ~prefix:pref tool_name)
    internal_tool_prefixes
;;

let is_unmapped_internal_tool_name tool_name =
  has_internal_tool_prefix tool_name
  || Tool_catalog.is_on_surface Tool_catalog.Keeper_internal tool_name
;;

let unknown_tool_class tool_name =
  if String.trim tool_name = "" then "empty" else "external"
;;

let record_strict_unknown_tool_denial ~agent_name ~tool_name =
  Prometheus.inc_counter
    Prometheus.metric_auth_strict_unknown_tool_denials
    ~labels:[ "agent_name", agent_name; "tool_class", unknown_tool_class tool_name ]
    ()
;;

let unknown_external_tool_error ~agent_name ~tool_name =
  Auth
    (Auth_error.Forbidden
       { agent = agent_name; action = "use unknown non-masc tool: " ^ tool_name })
;;

let authorize_tool ~check_permission config ~agent_name ~token ~tool_name
  : (unit, masc_error) result
  =
  match permission_for_tool tool_name with
  | None ->
    if not (is_tool_auth_strict_enabled ())
    then Ok () (* Legacy fail-open *)
    else if is_unmapped_internal_tool_name tool_name
    then
      (* Conservative default in strict mode for unmapped internal tools. *)
      check_permission config ~agent_name ~token ~permission:CanBroadcast
    else (
      let () = record_strict_unknown_tool_denial ~agent_name ~tool_name in
      Error (unknown_external_tool_error ~agent_name ~tool_name))
  | Some perm -> check_permission config ~agent_name ~token ~permission:perm
;;

let authorize_tool_for_role ~agent_name ~role ~tool_name : (unit, masc_error) result =
  let policy = Tool_access_role.policy_for_role role in
  if not (Tool_access_policy.allows_name policy tool_name)
  then Error (Auth (Auth_error.Forbidden { agent = agent_name; action = tool_name }))
  else if not (is_tool_auth_strict_enabled ())
  then Ok () (* Non-strict: policy check is sufficient *)
  else (
    (* Strict mode: additional gate for unmapped tools *)
    match permission_for_tool tool_name with
    | Some _ -> Ok () (* Mapped tool — policy already checked *)
    | None ->
      if is_unmapped_internal_tool_name tool_name
      then
        (* Unmapped internal tool: require at least Worker *)
        if has_permission role CanBroadcast
        then Ok ()
        else Error (Auth (Auth_error.Forbidden { agent = agent_name; action = tool_name }))
      else (
        let () = record_strict_unknown_tool_denial ~agent_name ~tool_name in
        Error (unknown_external_tool_error ~agent_name ~tool_name)))
;;
