(** Keeper_error_classify_post_commit — Post-commit side-effect error
    classification and reclassification.

    Extracted from [keeper_error_classify.ml] during godfile decomposition.
    Handles ambiguous partial-commit detection when mutating tools have already
    been invoked before an error occurred.

    @since God file decomposition *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let ambiguous_side_effect_error_prefix =
  "turn outcome ambiguous after committed mutating tool call(s)"

let committed_mutating_tools tool_names =
  tool_names
  |> dedupe_keep_order
  |> List.filter Keeper_tool_dispatch_runtime.has_mutating_side_effect

let is_ambiguous_side_effect_error (err : Agent_sdk.Error.sdk_error) : bool =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Ambiguous_post_commit _) -> true
  | None -> (
      match err with
      | Agent_sdk.Error.Internal msg ->
          String_util.contains_substring msg ambiguous_side_effect_error_prefix
      (* Non-Internal sdk_error variants do not encode the legacy
         ambiguous-side-effect string prefix; the structured
         [Ambiguous_post_commit] arm above covers the new path. *)
      | Agent_sdk.Error.Api _
      | Agent_sdk.Error.Provider _
      | Agent_sdk.Error.Agent _
      | Agent_sdk.Error.Mcp _
      | Agent_sdk.Error.Config _
      | Agent_sdk.Error.Serialization _
      | Agent_sdk.Error.Io _
      | Agent_sdk.Error.Orchestration _ -> false)
  (* All other MASC-internal classifications are unambiguous failures. *)
  | Some (Keeper_turn_driver.Runtime_exhausted _)
  | Some (Keeper_turn_driver.Capacity_backpressure _)

  | Some (Keeper_turn_driver.Accept_rejected _)
  | Some (Keeper_turn_driver.Resumable_cli_session _)
  | Some (Keeper_turn_driver.Turn_timeout _)
  | Some (Keeper_turn_driver.Provider_timeout _)
  (* RFC-0159 Phase A: opaque internal failures are unambiguous failures. *)
  | Some (Keeper_turn_driver.Internal_unhandled_exception _)
  | Some (Keeper_turn_driver.Internal_bridge_exception _)
  | Some (Keeper_turn_driver.Internal_contract_rejected _) ->
      false

let ambiguous_side_effect_error_tools (err : Agent_sdk.Error.sdk_error) =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Ambiguous_post_commit { tools; _ }) ->
      committed_mutating_tools tools
  | Some
      ( Keeper_turn_driver.Runtime_exhausted _
      | Keeper_turn_driver.Capacity_backpressure _
      | Keeper_turn_driver.Accept_rejected _
      | Keeper_turn_driver.Resumable_cli_session _
      | Keeper_turn_driver.Turn_timeout _
      | Keeper_turn_driver.Provider_timeout _
      | Keeper_turn_driver.Internal_unhandled_exception _
      | Keeper_turn_driver.Internal_bridge_exception _
      | Keeper_turn_driver.Internal_contract_rejected _ )
  | None ->
      []

let ambiguous_side_effect_commit_tools ~(tool_names : string list)
    (err : Agent_sdk.Error.sdk_error) : string list =
  if not (is_ambiguous_side_effect_error err)
  then []
  else committed_mutating_tools (tool_names @ ambiguous_side_effect_error_tools err)

let has_ambiguous_side_effect_commit ~(tool_names : string list)
    (err : Agent_sdk.Error.sdk_error) : bool =
  ambiguous_side_effect_commit_tools ~tool_names err <> []

let reclassify_error_after_side_effect
    ~(tool_names : string list)
    (err : Agent_sdk.Error.sdk_error) : Agent_sdk.Error.sdk_error =
  let committed_tools = committed_mutating_tools tool_names in
  if committed_tools = [] || is_ambiguous_side_effect_error err then err
  else
    let tools = committed_tools in
    let original = short_preview (Agent_sdk.Error.to_string err) in
    let is_timeout =
      match err with
      | Agent_sdk.Error.Api (Timeout _) -> true
      | Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _)
      | Agent_sdk.Error.Provider
          (Llm_provider.Error.NetworkError { timeout_phase = Some _; _ }) -> true
      | Agent_sdk.Error.Api (RateLimited _)
      | Agent_sdk.Error.Api (Overloaded _)
      | Agent_sdk.Error.Api (ServerError _)
      | Agent_sdk.Error.Api (AuthError _)
      | Agent_sdk.Error.Api (AuthorizationError _)
      | Agent_sdk.Error.Api (PaymentRequired _)
      | Agent_sdk.Error.Api (InvalidRequest _)
      | Agent_sdk.Error.Api (NotFound _)
      | Agent_sdk.Error.Api (ContextOverflow _)
      | Agent_sdk.Error.Api (NetworkError _)
      | Agent_sdk.Error.Provider _
      | Agent_sdk.Error.Agent _
      | Agent_sdk.Error.Mcp _
      | Agent_sdk.Error.Config _
      | Agent_sdk.Error.Serialization _
      | Agent_sdk.Error.Io _
      | Agent_sdk.Error.Orchestration _
      | Agent_sdk.Error.Internal _ -> false
    in
    Keeper_turn_driver.sdk_error_of_masc_internal_error
      (Keeper_turn_driver.Ambiguous_post_commit
         { is_timeout; tools; original_error = original })

let post_commit_failure_kind_of_error (err : Agent_sdk.Error.sdk_error) =
  match err with
  | Agent_sdk.Error.Api (Timeout _) -> Keeper_registry.Post_commit_timeout
  | Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _)
  | Agent_sdk.Error.Provider
      (Llm_provider.Error.NetworkError { timeout_phase = Some _; _ }) ->
      Keeper_registry.Post_commit_timeout
  (* All non-Timeout failures classify as generic post-commit failure. *)
  | Agent_sdk.Error.Api (RateLimited _)
  | Agent_sdk.Error.Api (Overloaded _)
  | Agent_sdk.Error.Api (ServerError _)
  | Agent_sdk.Error.Api (AuthError _)
  | Agent_sdk.Error.Api (AuthorizationError _)
  | Agent_sdk.Error.Api (PaymentRequired _)
  | Agent_sdk.Error.Api (InvalidRequest _)
  | Agent_sdk.Error.Api (NotFound _)
  | Agent_sdk.Error.Api (ContextOverflow _)
  | Agent_sdk.Error.Api (NetworkError _)
  | Agent_sdk.Error.Provider _
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ -> Keeper_registry.Post_commit_failure

let summarize_post_commit_failure
    ~(tool_names : string list)
    ~(kind : Keeper_registry.ambiguous_partial_commit_kind)
    (err : Agent_sdk.Error.sdk_error) =
  let committed_tools = committed_mutating_tools tool_names in
  let tools = String.concat ", " committed_tools in
  let err_preview = short_preview (Agent_sdk.Error.to_string err) in
  match kind with
  | Keeper_registry.Post_commit_timeout ->
      Printf.sprintf
        "Mutating tools [%s] committed before the turn timed out; evidence \
         recorded (error: %s)"
        tools err_preview
  | Keeper_registry.Post_commit_failure ->
      Printf.sprintf
        "Mutating tools [%s] committed before the turn failed; evidence \
         recorded (error: %s)"
        tools err_preview

let classify_post_commit_failure
    ~(tool_names : string list)
    ?kind
    (err : Agent_sdk.Error.sdk_error) =
  let committed_tools = committed_mutating_tools tool_names in
  if committed_tools = []
  then None
  else
    let resolved_kind =
      Option.value ~default:(post_commit_failure_kind_of_error err) kind
    in
    let reclassified =
      reclassify_error_after_side_effect ~tool_names:committed_tools err
    in
    let detail =
      summarize_post_commit_failure
        ~tool_names:committed_tools
        ~kind:resolved_kind
        err
    in
    Some
      ( reclassified,
        Keeper_registry.Ambiguous_partial_commit
          { kind = resolved_kind; detail } )
