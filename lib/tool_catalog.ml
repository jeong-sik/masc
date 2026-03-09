type visibility =
  | Default
  | Hidden

type lifecycle =
  | Active
  | Deprecated

type metadata = {
  visibility : visibility;
  lifecycle : lifecycle;
  canonical_name : string option;
  replacement : string option;
  reason : string option;
  allow_direct_call_when_hidden : bool;
}

let default_metadata =
  {
    visibility = Default;
    lifecycle = Active;
    canonical_name = None;
    replacement = None;
    reason = None;
    allow_direct_call_when_hidden = false;
  }

let unimplemented_tool_names = [ "masc_archive_save" ]

(** Kept for backward compatibility; controls visibility of unimplemented tools. *)
let placeholder_tool_names = unimplemented_tool_names

let placeholder_tools_enabled () =
  match Sys.getenv_opt "MASC_PLACEHOLDER_TOOLS_ENABLED" with
  | Some "1" | Some "true" | Some "TRUE" | Some "yes" | Some "YES" -> true
  | _ -> false

let metadata name =
  let deprecated ?canonical_name ?replacement reason =
    {
      visibility = Hidden;
      lifecycle = Deprecated;
      canonical_name;
      replacement;
      reason = Some reason;
      allow_direct_call_when_hidden = false;
    }
  in
  let hidden_active ?canonical_name ?replacement ?(allow_direct_call_when_hidden = true) reason =
    {
      visibility = Hidden;
      lifecycle = Active;
      canonical_name;
      replacement;
      reason = Some reason;
      allow_direct_call_when_hidden;
    }
  in
  match name with
  | "masc_archive_save" ->
      {
        visibility = Hidden;
        lifecycle = Active;
        canonical_name = None;
        replacement = None;
        reason = Some "Not implemented: requires Eio server context for persistence.";
        allow_direct_call_when_hidden = false;
      }
  | "masc_claim" | "masc_done" | "masc_release" | "masc_cancel_task" ->
      deprecated
        ~canonical_name:"masc_transition"
        ~replacement:"masc_transition"
        "Superseded by the unified masc_transition entrypoint."
  | "masc_team_session_turn" ->
      {
        (deprecated
           ~canonical_name:"masc_team_session_step"
           ~replacement:"masc_team_session_step"
           "Legacy compatibility entrypoint for plain team-session turn recording; use masc_team_session_step.")
        with
        allow_direct_call_when_hidden = true;
      }
  | "masc_dispatch_route" ->
      deprecated
        ~canonical_name:"masc_dispatch_plan"
        ~replacement:"masc_dispatch_plan"
        "Alias retained for compatibility; use masc_dispatch_plan."
  | "masc_unit_update" ->
      deprecated
        ~canonical_name:"masc_unit_define"
        ~replacement:"masc_unit_define"
        "Alias retained for compatibility; use masc_unit_define."
  | "masc_post_create" | "masc_post_list" | "masc_post_get"
  | "masc_comment_add" | "masc_comment_list" | "masc_vote" ->
      hidden_active
        "Low-usage social feed utility hidden from the default tool list; board tools are the primary collaborative surface."
  | "masc_vote_create" | "masc_vote_cast" | "masc_vote_status" | "masc_votes" ->
      hidden_active
        "Low-usage room vote utility hidden from the default tool list; prefer decision.*, masc_consensus_*, or masc_debate_* for primary coordination workflows."
  | _ when String.starts_with ~prefix:"masc_swarm_" name ->
      deprecated
        "Swarm public tools are deprecated. Use Command Plane V2 dispatch, detachment, and policy tools instead."
  | _ -> (
      match Tool_protocol_game_view.legacy_alias_to_canonical name with
      | Some canonical_name ->
          {
            (deprecated
               ~canonical_name
               ~replacement:canonical_name
               "Legacy compatibility alias hidden from the default tool list.")
            with
            allow_direct_call_when_hidden = true;
          }
      | None -> default_metadata)

let is_visible ?(include_hidden = false) ?(include_deprecated = false) name =
  let meta = metadata name in
  match meta.visibility, meta.lifecycle with
  | Hidden, _ when include_hidden -> true
  | Hidden, _ when placeholder_tools_enabled () && List.mem name placeholder_tool_names -> true
  | Hidden, _ -> false
  | Default, Deprecated -> include_deprecated
  | Default, Active -> true

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
  if placeholder_tools_enabled () then [] else placeholder_tool_names
