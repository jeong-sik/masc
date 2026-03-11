type visibility =
  | Default
  | Hidden

type lifecycle =
  | Active
  | Deprecated

type implementation_status =
  | Real
  | Adapter
  | Simulation
  | Placeholder

type metadata = {
  visibility : visibility;
  lifecycle : lifecycle;
  implementation_status : implementation_status;
  canonical_name : string option;
  replacement : string option;
  reason : string option;
  allow_direct_call_when_hidden : bool;
}

let default_metadata =
  {
    visibility = Default;
    lifecycle = Active;
    implementation_status = Real;
    canonical_name = None;
    replacement = None;
    reason = None;
    allow_direct_call_when_hidden = false;
  }

let placeholder_tools_enabled () =
  match Sys.getenv_opt "MASC_PLACEHOLDER_TOOLS_ENABLED" with
  | Some "1" | Some "true" | Some "TRUE" | Some "yes" | Some "YES" -> true
  | _ -> false

let deprecated ?canonical_name ?replacement ?(allow_direct_call_when_hidden = false)
    ?(implementation_status = Adapter) reason =
  {
    visibility = Hidden;
    lifecycle = Deprecated;
    implementation_status;
    canonical_name;
    replacement;
    reason = Some reason;
    allow_direct_call_when_hidden;
  }

let hidden_active ?canonical_name ?replacement ?(allow_direct_call_when_hidden = true)
    ?(implementation_status = Real) reason =
  {
    visibility = Hidden;
    lifecycle = Active;
    implementation_status;
    canonical_name;
    replacement;
    reason = Some reason;
    allow_direct_call_when_hidden;
  }

let explicit_metadata : (string * metadata) list =
  [
    ( "masc_archive_save",
      {
        visibility = Hidden;
        lifecycle = Active;
        implementation_status = Placeholder;
        canonical_name = None;
        replacement = None;
        reason =
          Some
            "Placeholder only: requires Eio server context for persistence and is not part of the truthful default tool surface.";
        allow_direct_call_when_hidden = false;
      } );
    ( "masc_claim",
      deprecated ~canonical_name:"masc_transition" ~replacement:"masc_transition"
        "Superseded by the unified masc_transition entrypoint." );
    ( "masc_done",
      deprecated ~canonical_name:"masc_transition" ~replacement:"masc_transition"
        "Superseded by the unified masc_transition entrypoint." );
    ( "masc_release",
      deprecated ~canonical_name:"masc_transition" ~replacement:"masc_transition"
        "Superseded by the unified masc_transition entrypoint." );
    ( "masc_cancel_task",
      deprecated ~canonical_name:"masc_transition" ~replacement:"masc_transition"
        "Superseded by the unified masc_transition entrypoint." );
    ( "masc_team_session_turn",
      deprecated ~canonical_name:"masc_team_session_step"
        ~replacement:"masc_team_session_step" ~allow_direct_call_when_hidden:true
        "Legacy compatibility entrypoint for plain team-session turn recording; use masc_team_session_step." );
    ( "masc_dispatch_route",
      deprecated ~canonical_name:"masc_dispatch_plan"
        ~replacement:"masc_dispatch_plan"
        "Alias retained for compatibility; use masc_dispatch_plan." );
    ( "masc_unit_update",
      deprecated ~canonical_name:"masc_unit_define"
        ~replacement:"masc_unit_define"
        "Alias retained for compatibility; use masc_unit_define." );
    ( "masc_post_create",
      hidden_active
        "Low-usage social feed utility hidden from the default tool list; board tools are the primary collaborative surface." );
    ( "masc_post_list",
      hidden_active
        "Low-usage social feed utility hidden from the default tool list; board tools are the primary collaborative surface." );
    ( "masc_post_get",
      hidden_active
        "Low-usage social feed utility hidden from the default tool list; board tools are the primary collaborative surface." );
    ( "masc_comment_add",
      hidden_active
        "Low-usage social feed utility hidden from the default tool list; board tools are the primary collaborative surface." );
    ( "masc_comment_list",
      hidden_active
        "Low-usage social feed utility hidden from the default tool list; board tools are the primary collaborative surface." );
    ( "masc_vote",
      hidden_active
        "Low-usage social feed utility hidden from the default tool list; board tools are the primary collaborative surface." );
    ( "masc_vote_create",
      hidden_active
        "Low-usage room vote utility hidden from the default tool list; prefer decision.*, masc_consensus_*, or masc_debate_* for primary coordination workflows." );
    ( "masc_vote_cast",
      hidden_active
        "Low-usage room vote utility hidden from the default tool list; prefer decision.*, masc_consensus_*, or masc_debate_* for primary coordination workflows." );
    ( "masc_vote_status",
      hidden_active
        "Low-usage room vote utility hidden from the default tool list; prefer decision.*, masc_consensus_*, or masc_debate_* for primary coordination workflows." );
    ( "masc_votes",
      hidden_active
        "Low-usage room vote utility hidden from the default tool list; prefer decision.*, masc_consensus_*, or masc_debate_* for primary coordination workflows." );
  ]

let implementation_status_to_string = function
  | Real -> "real"
  | Adapter -> "adapter"
  | Simulation -> "simulation"
  | Placeholder -> "placeholder"

let implementation_allows_public_visibility = function
  | Real | Adapter -> true
  | Simulation | Placeholder -> false

let metadata name =
  match List.assoc_opt name explicit_metadata with
  | Some meta -> meta
  | None -> (
      match name with
      | "masc_swarm_live_run" -> default_metadata
      | _ when String.starts_with ~prefix:"masc_swarm_" name ->
          deprecated
            "Swarm public tools are deprecated. Use Command Plane V2 dispatch, detachment, and policy tools instead."
      | _ -> (
          match Tool_protocol_game_view.legacy_alias_to_canonical name with
          | Some canonical_name ->
              deprecated ~canonical_name ~replacement:canonical_name
                ~allow_direct_call_when_hidden:true
                "Legacy compatibility alias hidden from the default tool list."
          | None -> default_metadata))

let implementation_status name =
  let meta = metadata name in
  meta.implementation_status

let is_placeholder name =
  match implementation_status name with
  | Placeholder -> true
  | Real | Adapter | Simulation -> false

let is_visible ?(include_hidden = false) ?(include_deprecated = false) name =
  let meta = metadata name in
  match meta.visibility, meta.lifecycle with
  | Hidden, _ when include_hidden -> true
  | Hidden, _ when placeholder_tools_enabled () && is_placeholder name -> true
  | Hidden, _ -> false
  | Default, Deprecated -> include_deprecated
  | Default, Active -> implementation_allows_public_visibility meta.implementation_status

let visibility_to_string = function
  | Default -> "default"
  | Hidden -> "hidden"

let lifecycle_to_string = function
  | Active -> "active"
  | Deprecated -> "deprecated"

let metadata_to_fields name =
  let meta = metadata name in
  let base =
    [
      ("visibility", `String (visibility_to_string meta.visibility));
      ("lifecycle", `String (lifecycle_to_string meta.lifecycle));
      ("implementationStatus", `String (implementation_status_to_string meta.implementation_status));
    ]
  in
  let with_canonical =
    match meta.canonical_name with
    | Some canonical_name -> ("canonicalName", `String canonical_name) :: base
    | None -> base
  in
  let with_replacement =
    match meta.replacement with
    | Some replacement -> ("replacement", `String replacement) :: with_canonical
    | None -> with_canonical
  in
  match meta.reason with
  | Some reason -> ("reason", `String reason) :: with_replacement
  | None -> with_replacement

let allow_direct_call name =
  let meta = metadata name in
  match meta.visibility with
  | Default -> true
  | Hidden -> meta.allow_direct_call_when_hidden

let hidden_placeholder_tools () =
  if placeholder_tools_enabled () then []
  else
    explicit_metadata
    |> List.filter_map (fun (name, meta) ->
           match meta.visibility, meta.implementation_status with
           | Hidden, Placeholder -> Some name
           | _ -> None)
