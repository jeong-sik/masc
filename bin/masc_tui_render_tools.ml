(** The Tools surface: what the selected Keeper's turn called, and what the
    process has registered.

    Lifted out of masc_tui_render.ml whole. The file that #3808 split out of
    masc_tui.ml had grown back to 16,533 lines, and it could not be split
    again while Ansi/Theme/Terminal_text lived inside the same executable
    stanza -- any surface that draws has to reach them, so any surface that
    moved had to stay. masc_tui_ansi is a library now, which is what makes a
    per-surface module possible at all.

    Twelve definitions moved; the interface exposes the two the rest of the
    renderer actually calls. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi

module Tool_tree = Masc_tui_tool_tree
module Tool_table = Masc_tui_tool_table
let json_assoc_member_opt = Masc_tui_json.member_opt

(* Newest events the Skill Timeline section draws. The full count still
   prints in the heading; the cap keeps one busy ledger from pushing the
   usage and catalog sections off the first screen. *)
let skill_timeline_display_cap = 15

(* Two deliberately separate readings: the selected Keeper's exact turn
   surface, then the process-wide registered catalog. A registered tool is not
   evidence that a Keeper can call it. *)
(* The rule that closes a domain heading. Fixed length rather than filling
   the row: box_line_styled pads, and a heading that shouted across the full
   width would outrank the surface header above it. *)
let tool_domain_rule_cells = 21

let tool_domain_rule =
  String.concat "" (List.init tool_domain_rule_cells (fun _ -> Ansi.box_h))

let skill_instruction_origin_text = function
  | Masc.Keeper_skill_activation_ledger.Task_instruction { task_ids } ->
      "task_instruction tasks="
      ^ (Masc.Keeper_skill_activation_ledger.task_id_set_to_list task_ids
         |> List.map Keeper_id.Task_id.to_string
         |> String.concat ",")
  | Masc.Keeper_skill_activation_ledger.Session_instruction ->
      "session_instruction"

let skill_composition_origin_text ~tool_name = function
  | Masc.Keeper_skill_activation_ledger.Task_composition
      { task_ids } ->
      Printf.sprintf "task_composition tasks=%s tool=%s"
        (Masc.Keeper_skill_activation_ledger.task_id_set_to_list task_ids
         |> List.map Keeper_id.Task_id.to_string
         |> String.concat ",")
        tool_name
  | Masc.Keeper_skill_activation_ledger.Session_composition ->
      "session_composition tool=" ^ tool_name

let skill_served_content_text = function
  | Masc.Keeper_skill_activation_ledger.Skill_body { bytes; sha256 } ->
      Printf.sprintf "body bytes=%d sha256=%s" bytes sha256
  | Masc.Keeper_skill_activation_ledger.Skill_resource
      { relative_path; bytes; sha256 } ->
      Printf.sprintf "resource=%s bytes=%d sha256=%s" relative_path bytes sha256

let skill_invocation_text = function
  | Masc.Keeper_skill_activation_ledger.Instruction_invocation
      { origin; served_content } ->
    skill_instruction_origin_text origin, skill_served_content_text served_content
  | Masc.Keeper_skill_activation_ledger.Composition_invocation
      { origin; tool_name } ->
    ( skill_composition_origin_text ~tool_name origin
    , "composition invocation tool=" ^ tool_name )

let skill_delivery_text ~has_action = function
  | None -> "pending"
  | Some (delivery : Masc.Keeper_skill_activation_ledger.delivery) ->
      let kind, turn, proof =
        match delivery.boundary with
        | Masc.Keeper_skill_activation_ledger.Model_response { agent_core_turn } ->
          "provider_delivery", agent_core_turn, ""
        | Official_client_result_handoff { agent_core_turn } ->
          ( "official_client_result_handoff"
          , agent_core_turn
          , if has_action
            then " proof=complete_later_action"
            else " proof=incomplete_no_later_action" )
      in
      Printf.sprintf
        "%s turn=%d runtime=%s bytes=%d sha256=%s at=%s%s"
        kind
        turn
        (Terminal_text.single_line delivery.runtime_id)
        delivery.content_bytes
        (Terminal_text.single_line delivery.content_sha256)
        delivery.delivered_at
        proof

let skill_action_lines actions =
  List.map
    (fun (action : Masc.Keeper_skill_activation_ledger.action) ->
       let identity =
         match action.identity with
         | Masc.Keeper_skill_activation_ledger.Call_id call_id ->
           "call=" ^ call_id
         | Masc.Keeper_skill_activation_ledger.Provider_step
             { conversation_id; step_index } ->
           Printf.sprintf "step=%s:%d" conversation_id step_index
       in
       Ansi.dim,
       Printf.sprintf
         "       action turn=%d runtime=%s tool=%s %s at=%s"
         action.agent_core_turn
         (Terminal_text.single_line action.runtime_id)
         (Terminal_text.single_line action.tool_name)
         (Terminal_text.single_line identity)
         (Terminal_text.single_line action.observed_at))
    actions

let async_request_observation_lines (state : state) =
  match state.tools_async_observation_error, state.tools_async_observation with
  | Some detail, _ ->
    [ Theme.bad (), " Async broker — " ^ Terminal_text.single_line detail ]
  | None, None -> [ Theme.warn (), " Async broker — not loaded" ]
  | None, Some json ->
    (match json_assoc_member_opt "status" json with
     | Some (`String "unavailable") ->
       [ Theme.bad (), " Async broker — durable inventory unavailable" ]
     | Some (`String "ready") ->
       let int_field json name =
         match json_assoc_member_opt name json with
         | Some (`Int value) -> value
         | Some _ | None -> 0
       in
       let summary_lines =
         match json_assoc_member_opt "summary" json with
         | Some (`Assoc _ as summary) ->
           [ Ansi.bold,
             Printf.sprintf
               " Async broker — active=%d · runtime-owned=%d · ownership-unknown=%d · record-errors=%d"
               (int_field summary "active")
               (int_field summary "runtime_owned")
               (int_field summary "ownership_unknown")
               (int_field summary "record_errors")
           ]
         | Some _ | None -> [ Theme.bad (), " Async broker — summary is malformed" ]
       in
       let request_lines =
         match json_assoc_member_opt "requests" json with
         | Some (`List requests) ->
           List.map
             (fun request ->
                let string_field name fallback =
                  match json_assoc_member_opt name request with
                  | Some (`String value) -> value
                  | Some _ | None -> fallback
                in
                let elapsed =
                  match json_assoc_member_opt "elapsed_sec" request with
                  | Some (`Float value) -> Printf.sprintf "%.1fs" value
                  | Some (`Int value) -> Printf.sprintf "%ds" value
                  | Some _ | None -> "?s"
                in
                let ownership = string_field "worker_ownership" "unknown" in
                (if String.equal ownership "runtime_owned"
                 then Theme.ok ()
                 else Theme.warn ()),
                Printf.sprintf
                  "   %s · %s · %s · %s · %s"
                  (Terminal_text.single_line (string_field "request_id" "?"))
                  (Terminal_text.single_line (string_field "keeper_name" "?"))
                  (Terminal_text.single_line (string_field "status" "?"))
                  elapsed
                  (Terminal_text.single_line ownership))
             requests
         | Some _ | None -> [ Theme.bad (), "   async request rows are malformed" ]
       in
       let recovery_lines =
         match json_assoc_member_opt "startup_recovery" json with
         | Some (`Assoc _ as recovery) ->
           [ Ansi.dim,
             Printf.sprintf
               "   startup recovery: lost=%d finalized=%d cleaned=%d unreadable=%d failed=%d staging=%d/%d/%d"
               (int_field recovery "lost")
               (int_field recovery "finalized")
               (int_field recovery "cleaned")
               (int_field recovery "unreadable")
               (int_field recovery "failed")
               (int_field recovery "staging_files_inspected")
               (int_field recovery "staging_files_deleted")
               (int_field recovery "staging_files_preserved")
           ]
         | Some `Null | None ->
           [ Ansi.dim, "   startup recovery: not observed by this process" ]
         | Some _ -> [ Theme.bad (), "   startup recovery report is malformed" ]
       in
       summary_lines @ request_lines @ recovery_lines
     | Some _ | None -> [ Theme.bad (), " Async broker response is malformed" ])

(* The Tools sections, named where the reader is standing. Same shape as
   {!config_pane_strip}: a reader who has seen one has seen the other. *)
(* Enough of a content hash to tell two of them apart, which is the only
   question a reader asks of one on a screen. The footer already draws commit
   hashes this way and says why; these are the same kind of value and were
   drawn whole, so a 64-character revision ran past the width and arrived cut
   mid-hash -- long enough to fill the line, short of anything to compare.

   Short of the prefix length the value is left as it is: a value that is
   already short is not a hash, and trimming it would take meaning. *)
let short_revision_length = 12

let short_revision value =
  if String.length value <= short_revision_length then value
  else String.sub value 0 short_revision_length ^ "\xe2\x80\xa6"

(* The Skill discovery roots, in the order the catalog consults them.

   The pane named skills and never named where they were looked for, so
   "my Skill is not loaded" had no first question to ask. A root that is
   missing, refused, or read-only contributes nothing and only shows here:
   the editor's own sources endpoint filters to the read-write roots that
   resolved, because it is choosing somewhere to write. *)
let skill_access_short = function
  | "read-write" -> "rw"
  | "read-only" -> "ro"
  | other -> other
;;

let skill_source_reading (observation : Masc.Tui_decode.skill_source_observation) =
  match observation with
  | Masc.Tui_decode.Skill_source_ready count ->
    ( (if count = 0 then Ansi.dim else Theme.ok ())
    , (if count = 0 then "\xc2\xb7" else "\xe2\x9c\x93")
    , Printf.sprintf "%d skill director%s" count
        (if count = 1 then "y" else "ies") )
  | Skill_source_missing -> (Ansi.dim, "\xc2\xb7", "missing")
  | Skill_source_not_directory kind ->
    (Theme.warn (), "!", "not a directory (" ^ kind ^ ")")
  | Skill_source_unavailable operation ->
    (Theme.warn (), "!", "unreadable at " ^ operation)
  | Skill_source_unresolved ->
    (Theme.warn (), "!", "path refused by config")
;;

let skill_config_line (config : Masc.Tui_decode.skill_catalog_config option) =
  match config with
  | None -> []
  | Some (Masc.Tui_decode.Skill_config_configured { revision; resource_read_max_bytes })
    ->
    let cap =
      match resource_read_max_bytes with
      | None -> "no resource read cap"
      | Some bytes -> Printf.sprintf "resource read \xe2\x89\xa4 %d bytes" bytes
    in
    [ ( Ansi.dim
      , Printf.sprintf "   config %s \xc2\xb7 %s"
          (short_revision (Terminal_text.single_line revision))
          cap )
    ]
  | Some (Skill_config_rejected { source_revision; diagnostics }) ->
    (* The catalog still stands on the defaults, so nothing else on the
       screen changes when the operator's section stops parsing. *)
    ( Theme.warn ()
    , Printf.sprintf "   runtime.toml Skill config rejected (rev %s) \xe2\x80\x94 defaults in use"
        (short_revision (Terminal_text.single_line source_revision)) )
    :: List.map
         (fun diagnostic ->
            (Theme.warn (), "     " ^ Terminal_text.single_line diagnostic))
         diagnostics
  | Some Skill_config_unreadable ->
    [ ( Theme.warn ()
      , "   runtime.toml Skill config unreadable \xe2\x80\x94 defaults in use" )
    ]
;;

(* A composition skill's execution plan, as the batches it runs in.

   The flow arrives decoded in full -- every node, the tool it calls, the
   batch it sits in and how that batch runs -- and no renderer read any of
   it, so the pane could say a composition had been invoked twelve times
   without ever saying what it invokes.

   The batches are the ordering the server recorded. The per-node dependency
   edges are recorded too, and they are a graph; a graph does not fit a
   summary row, so they stay for a detail view that does not exist yet.

   Same arrow as the Goal stage rail and the Fusion topology row, so three
   surfaces spell a pipeline one way. *)
let skill_flow_line (flow : Masc.Tui_decode.skill_flow) =
  let tool_of id =
    List.find_map
      (fun (node : Masc.Tui_decode.skill_flow_node) ->
         if String.equal node.sfn_id id then Some node.sfn_tool_name else None)
      flow.sf_nodes
  in
  let batch (b : Masc.Tui_decode.skill_flow_batch) =
    match List.filter_map tool_of b.sfb_node_ids with
    | [] -> None
    | tools ->
      Some
        (Printf.sprintf "%s %s"
           (Terminal_text.single_line b.sfb_execution_mode)
           (String.concat " \xc2\xb7 "
              (List.map Terminal_text.single_line tools)))
  in
  match List.filter_map batch flow.sf_batches with
  | [] -> None
  | parts -> Some (String.concat "  \xe2\x94\x80\xe2\x96\xb6  " parts)
;;

let skill_source_lines ~config ~(sources : Masc.Tui_decode.skill_catalog_source list) =
  let ready =
    List.length
      (List.filter
         (fun (source : Masc.Tui_decode.skill_catalog_source) ->
            match source.scso_observation with
            | Masc.Tui_decode.Skill_source_ready count -> count > 0
            | _ -> false)
         sources)
  in
  let heading =
    ( Ansi.bold
    , Printf.sprintf " Skill Sources \xe2\x80\x94 %d of %d root%s carrying skills"
        ready (List.length sources)
        (if List.length sources = 1 then "" else "s") )
  in
  let rows =
    List.map
      (fun (source : Masc.Tui_decode.skill_catalog_source) ->
         let tone, mark, reading = skill_source_reading source.scso_observation in
         let path =
           match source.scso_path with
           | Some path -> Terminal_text.single_line path
           | None -> "(absolute; path not published)"
         in
         ( tone
         , Printf.sprintf "   %s %-16s %-10s %-26s %-2s  %s" mark
             (Terminal_text.single_line source.scso_id)
             (Terminal_text.single_line source.scso_anchor)
             path
             (skill_access_short source.scso_access)
             reading ))
      sources
  in
  match sources with
  | [] -> []
  | _ -> (heading :: rows) @ skill_config_line config @ [ (Ansi.dim, "") ]
;;
;;

let tools_pane_strip (state : state) =
  let name pane label =
    if state.tools_pane = pane then
      Ansi.bold ^ "\xe2\x96\xb8" ^ label ^ Ansi.reset
    else Ansi.dim ^ " " ^ label ^ Ansi.reset
  in
  String.concat (Ansi.dim ^ " |" ^ Ansi.reset)
    [ name Masc_tui_types.Tools_surface "available"
    ; name Masc_tui_types.Tools_async "async runs"
    ; name Masc_tui_types.Tools_activations "receipts"
    ; name Masc_tui_types.Tools_usage "usage"
    ; name Masc_tui_types.Tools_catalog "all tools"
    ]
  ^ Ansi.dim ^ "  p:next" ^ Ansi.reset
;;

let tools_display_lines (state : state) =
  let registered_tools =
    match state.tools_inventory with
    | None -> []
    | Some s -> s.Masc.Tui_decode.ts_tools
  in
  let effective_lines =
    lazy begin
    match state.tools_inventory with
    | None -> [ (Theme.warn ()), " Effective Keeper Surface — not loaded" ]
    | Some { Masc.Tui_decode.ts_effective = None; _ } ->
        [ (Theme.warn ()), " Effective Keeper Surface — no Keeper selected" ]
    | Some
        { Masc.Tui_decode.ts_effective =
            Some
              (Masc.Tui_decode.Effective_surface_warming { ets_keeper_name });
          _ } ->
        [ (Theme.warn ()),
          Printf.sprintf " Effective Keeper Surface — %s — warming"
            (Terminal_text.single_line ets_keeper_name) ]
    | Some
        { Masc.Tui_decode.ts_effective =
            Some
              (Masc.Tui_decode.Effective_surface_unavailable
                 { ets_keeper_name; ets_reason; ets_detail });
          _ } ->
        [ (Theme.bad ()),
          Printf.sprintf " Effective Keeper Surface — %s — unavailable (%s)"
            (Terminal_text.single_line ets_keeper_name)
            (Terminal_text.single_line ets_reason);
          (Theme.bad ()), "   " ^ Terminal_text.single_line ets_detail ]
    | Some
        { Masc.Tui_decode.ts_effective =
            Some
              (Masc.Tui_decode.Effective_surface_available
                 { ets_keeper_name;
                   ets_runtime_id;
                   ets_official_client_kind;
                   ets_tool_delivery;
                   ets_native_posture;
                   ets_skill_snapshot_revision;
                   ets_skill_resource_read_max_bytes;
                   ets_instruction_skills;
                   ets_skills_left_out;
                   ets_composition_skills;
                   ets_skill_profiles;
                   ets_tool_surface_bytes;
                   ets_skill_tool_surface_bytes;
                   ets_skill_discovery_bytes;
                   ets_skill_eager_body_bytes;
                   ets_skill_body_bytes;
                   ets_tools;
                   ets_tool_surface_sha256;
                 });
          _ } ->
        let native = Option.value ~default:"n/a" ets_native_posture in
        let delivery =
          match ets_tool_delivery with
          | Masc.Tui_decode.Effective_tools_delivered -> "delivered"
          | Masc.Tui_decode.Effective_tools_suppressed_runtime_unsupported ->
            "suppressed:runtime_tools_unsupported"
        in
        let resource_bound =
          match ets_skill_resource_read_max_bytes with
          | Some max_bytes -> Printf.sprintf "%d bytes" max_bytes
          | None -> "not configured"
        in
        (* Names, not the wire form. These were serialised to JSON and then
           cut to the width of the line, so the header read
           [{"identity":{"source_id":"project-masc","package_id"~] -- sixty
           characters that answer nothing, in the place a reader looks first.

           The skills are listed by name a few rows below, so the header's
           job is the count and which ones, and it can say both in less room
           than the envelope of the first one took. *)
        let skill_names refs =
          match refs with
          | [] -> "none"
          | xs ->
            Printf.sprintf "%d · %s" (List.length xs)
              (xs
               |> List.map (fun reference ->
                    reference.Skill_reference.identity.Skill_reference.name)
               |> String.concat " ")
        in
        let instruction = skill_names ets_instruction_skills in
        let composition = skill_names ets_composition_skills in
        let digest =
          match ets_tool_surface_sha256 with
          | None -> "n/a (Agent Core owns the turn)"
          | Some value -> value
        in
        let tool_lines =
          List.map
            (fun (tool : Masc.Tui_decode.effective_tool) ->
               let source =
                 match tool.et_skill_source, tool.et_group with
                 | Some source, _ -> tool.et_origin ^ ":" ^ source
                 | None, Some group -> tool.et_origin ^ ":" ^ group
                 | None, None -> tool.et_origin
               in
               Ansi.dim,
               Tool_table.effective_tool_line
                 ~name:(Terminal_text.single_line tool.et_name)
                 ~origin:(Terminal_text.single_line source))
            ets_tools
        in
        let skill_profile_lines =
          List.mapi
            (fun index (profile : Masc.Tui_decode.effective_skill_profile) ->
               let execution =
                 if String.equal profile.esp_kind "instruction"
                 then "on-demand"
                 else profile.esp_execution
               in
               let reasons =
                 profile.esp_load_reasons
                 |> List.map (function
                      | Masc.Tui_decode.Skill_catalog_default -> "catalog default"
                      | Skill_keeper_profile -> "Keeper profile"
                      | Skill_task task_id -> "Task " ^ task_id)
                 |> String.concat " + "
               in
               [ ( (if index = state.tools_skill_cursor
                    then Theme.selection
                    else Ansi.dim)
                 , Printf.sprintf
                     " %s %-22s %-11s nodes=%d batches=%d parallel=%d discovery=%dB body=%dB"
                     (if index = state.tools_skill_cursor then "▸" else " ")
                     (Terminal_text.single_line profile.esp_name)
                     (Terminal_text.single_line execution)
                     profile.esp_node_count
                     profile.esp_batch_count
                     profile.esp_max_parallelism
                     profile.esp_discovery_bytes
                     profile.esp_body_bytes )
               ; Ansi.dim,
                 "     why loaded: "
                 ^ Terminal_text.single_line
                     (if String.equal reasons "" then "unattributed" else reasons)
               ])
            ets_skill_profiles
          |> List.concat
        in
        let selected_skill_flow_lines =
          match List.nth_opt ets_skill_profiles state.tools_skill_cursor with
          | None -> []
          | Some { Masc.Tui_decode.esp_flow = None; _ } ->
            [ Ansi.dim, "     Flow: instruction body loads on demand; the model orchestrates tools" ]
          | Some { Masc.Tui_decode.esp_flow = Some flow; _ } ->
            (* Grouped under the batch that runs them, rather than listed
               flat with a batch=N to cross-reference. The batches are the
               order; the nodes are what is in each one. Two readings, and
               the old shape made the reader join them by hand.

               A tree, not a graph: the dependencies are already named on the
               node, and drawing edges between rows buys a picture at the
               price of a screen nobody can scan. *)
            let node_by_id id =
              List.find_opt
                (fun node -> String.equal node.sfn_id id)
                flow.sf_nodes
            in
            let dependency_text node =
              match node.sfn_dependencies with
              | [] -> ""
              | values ->
                "  \xe2\x86\x90 "
                ^ (values
                   |> List.map (fun dependency ->
                        dependency.sfd_node_id ^ ":" ^ dependency.sfd_kind)
                   |> String.concat ", ")
            in
            let batch_count = List.length flow.sf_batches in
            let batch_lines =
              flow.sf_batches
              |> List.mapi (fun batch_position batch ->
                let last_batch = batch_position = batch_count - 1 in
                let node_count = List.length batch.sfb_node_ids in
                batch.sfb_node_ids
                |> List.mapi (fun node_position node_id ->
                  let first_node = node_position = 0 in
                  let stem =
                    if first_node then
                      if last_batch then "\xe2\x94\x94" else "\xe2\x94\x9c"
                    else if last_batch then " "
                    else "\xe2\x94\x82"
                  in
                  let label =
                    if first_node then
                      Printf.sprintf "%d %s" batch.sfb_index
                        (Terminal_text.single_line batch.sfb_execution_mode)
                    else ""
                  in
                  let tool, dependencies =
                    match node_by_id node_id with
                    | None -> "(not in nodes)", ""
                    | Some node ->
                      ( Terminal_text.single_line node.sfn_tool_name
                      , dependency_text node )
                  in
                  ( Ansi.dim
                  , Printf.sprintf "     %s %-12s %-18s %s%s" stem label
                      (Terminal_text.single_line node_id) tool dependencies ))
                |> fun lines ->
                if node_count = 0 then
                  [ ( Ansi.dim
                    , Printf.sprintf "     %s %d %s (no nodes)"
                        (if last_batch then "\xe2\x94\x94" else "\xe2\x94\x9c")
                        batch.sfb_index
                        (Terminal_text.single_line batch.sfb_execution_mode) )
                  ]
                else lines)
              |> List.concat
            in
            ( Ansi.bold
            , Printf.sprintf "     Flow  %d batches · %d nodes" batch_count
                (List.length flow.sf_nodes) )
            :: batch_lines
        in
        let selected_skill_evidence_lines =
          match List.nth_opt ets_skill_profiles state.tools_skill_cursor with
          | None -> []
          | Some profile ->
            let key =
              Skill_reference.to_yojson profile.esp_reference |> Yojson.Safe.to_string
            in
            (match state.tools_skill_evidence with
             | Some (observed_key, json) when String.equal key observed_key ->
              (match Tui_decode.decode_skill_evidence json with
               | Error _ ->
                 [ Theme.bad (), "     Retained evidence response is malformed" ]
               | Ok evidence ->
               let evidence_lines =
                 match evidence.Masc.Tui_decode.se_status with
                 | Masc.Tui_decode.Skill_evidence_not_observed_in_retained_coverage ->
                  [ Theme.warn (),
                    "     Retained evidence: not found in retained coverage (not proof of never)"
                  ]
                 | Masc.Tui_decode.Skill_evidence_observed ->
                  let activation_lines =
                    let items, tied =
                      match evidence.se_activation with
                      | None -> [], false
                      | Some (Masc.Tui_decode.Skill_evidence_most_recent_observed item) ->
                        [ item ], false
                      | Some
                          (Masc.Tui_decode.Skill_evidence_most_recent_observed_timestamp_tie
                             items) ->
                        items, true
                    in
                    List.concat_map
                      (fun item ->
                         let activation = item.Masc.Tui_decode.sea_activation in
                         let string_field name =
                           match json_assoc_member_opt name activation with
                           | Some (`String value) -> value
                           | _ -> ""
                         in
                         let delivered =
                           match json_assoc_member_opt "delivery" activation with
                           | Some `Null | None -> "invoked"
                           | Some _ -> "✓ delivered"
                         in
                         let action_count =
                           match json_assoc_member_opt "actions" activation with
                           | Some (`List values) -> List.length values
                           | Some _ | None -> 0
                         in
                         let keepers =
                           item.sea_owner_claims
                           |> List.map (fun claim -> claim.seo_keeper)
                           |> String.concat ","
                         in
                         [ Ansi.bold,
                           Printf.sprintf
                             "     Activation: %s · owner=%s(%s) · actions=%d · at=%s"
                             delivered
                             (Terminal_text.single_line item.sea_owner_status)
                             (Terminal_text.single_line keepers)
                             action_count
                             (Terminal_text.single_line (string_field "activated_at"))
                         ; Ansi.dim,
                           Printf.sprintf
                             "       trace %s · tool use %s%s"
                             (Terminal_text.single_line item.sea_trace_id)
                             (Terminal_text.single_line
                                (string_field "skill_tool_use_id"))
                             (if tied then " · equal-time candidate" else "")
                         ])
                      items
                  in
                  let composition_lines =
                    match evidence.se_composition with
                    | Some (`Assoc _ as composition) ->
                      (match json_assoc_member_opt "result" composition with
                       | Some (`Assoc _ as result) ->
                         let string_field name fallback =
                           match json_assoc_member_opt name composition with
                           | Some (`String value) -> value
                           | _ -> fallback
                         in
                         let duration =
                           match json_assoc_member_opt "duration_ms" result with
                           | Some (`Float value) -> Printf.sprintf "%.0fms" value
                           | Some (`Int value) -> Printf.sprintf "%dms" value
                           | _ -> "?ms"
                         in
                         let success =
                           match json_assoc_member_opt "disposition" result with
                           | Some (`String "completed") -> "✓ completed"
                           | Some (`String "deferred") -> "◌ deferred"
                           | Some (`String "failed") -> "✗ failed"
                           | Some _ | None -> "unknown"
                         in
                         let output =
                           match json_assoc_member_opt "data" result with
                           | Some (`String value) -> value
                           | Some value -> Yojson.Safe.to_string value
                           | None -> "no output"
                         in
                         let settlement_count =
                           match
                             json_assoc_member_opt
                               "executor_settlements"
                               composition
                           with
                           | Some (`List values) -> List.length values
                           | Some _ | None -> 0
                         in
                         [ Ansi.bold,
                           Printf.sprintf
                             "     Composition: %s · %s · keeper=%s · run=%s · settlements=%d"
                             success
                             duration
                             (Terminal_text.single_line
                                (string_field "keeper" "?"))
                             (Terminal_text.single_line
                                (string_field "composition_run_id" "?"))
                             settlement_count
                         ; Ansi.dim, "       " ^ Terminal_text.single_line output
                         ]
                       | Some _ | None ->
                         [ Theme.bad (), "     Composition evidence is malformed" ])
                    | None -> []
                    | Some _ -> [ Theme.bad (), "     Composition evidence is malformed" ]
                  in
                  activation_lines @ composition_lines
               in
               let coverage_lines =
                 let coverage = evidence.Masc.Tui_decode.se_coverage in
                 let composition_scope =
                   match coverage.sec_composition_scope with
                   | Masc.Tui_decode.Skill_evidence_exact_reference_latest_completed ->
                     "latest_completed"
                   | Masc.Tui_decode.Skill_evidence_composition_unavailable ->
                     "unavailable"
                 in
                 let unavailable =
                   List.map
                     Terminal_text.single_line
                     coverage.sec_composition_unavailable
                 in
                   [ Ansi.dim,
                     Printf.sprintf
                       "       coverage retained_sessions=%d ledgers=%d activation=%s gaps=%d owner_gaps=%d exact_reference=%s records_read=%d"
                       coverage.sec_activation_sessions_inspected
                       coverage.sec_activation_ledgers_loaded
                       coverage.sec_activation_scope
                       coverage.sec_activation_gap_count
                       coverage.sec_activation_owner_gap_count
                       composition_scope
                       coverage.sec_composition_records_read
                   ]
                   @
                   (match unavailable with
                    | [] -> []
                    | values ->
                      [ Theme.warn (),
                        "       composition unavailable: " ^ String.concat " · " values
                      ])
               in
               evidence_lines @ coverage_lines)
             | Some _ | None ->
               [ Ansi.dim, "     Retained evidence: Enter to load this exact revision" ])
        in
        [ Ansi.bold,
          Printf.sprintf " Effective Keeper Surface — %s (%d tools)"
            (Terminal_text.single_line ets_keeper_name)
            (List.length ets_tools);
          Ansi.dim,
          Printf.sprintf "   runtime=%s  client=%s  native=%s  delivery=%s"
            (Terminal_text.single_line ets_runtime_id)
            (Terminal_text.single_line ets_official_client_kind)
            native (Terminal_text.single_line delivery);
          Ansi.dim,
          Printf.sprintf "   instruction skills=%s  composition skills=%s"
            (Terminal_text.single_line instruction)
            (Terminal_text.single_line composition);
          Ansi.dim,
          "   skill snapshot="
          ^ short_revision (Terminal_text.single_line ets_skill_snapshot_revision);
          Ansi.dim,
          "   deferred resource bound=" ^ Terminal_text.single_line resource_bound;
          Ansi.bold,
          Printf.sprintf
            "   Skill context: profile discovery=%dB · eager=%dB · deferred bodies=%dB · skill tool schema=%dB/%dB all tools"
            ets_skill_discovery_bytes
            ets_skill_eager_body_bytes
            ets_skill_body_bytes
            ets_skill_tool_surface_bytes
            ets_tool_surface_bytes;
          Ansi.bold,
          "   Skills — J/K select · Enter evidence · e edit · c new instruction · C new composition";
          Ansi.dim, "   digest=" ^ short_revision (Terminal_text.single_line digest) ]
        @ skill_profile_lines
        @ selected_skill_flow_lines
        @ selected_skill_evidence_lines
        (* Said on this surface because this is the one that answers "what can
           this Keeper call". A document the catalog could not read is absent
           from that answer, and absence with nothing beside it reads as a
           skill nobody wrote rather than one that did not load. Drawn only
           when there is one, so a healthy workspace gains no row. *)
        @ (match ets_skills_left_out with
           | [] -> []
           | left_out ->
             ( (Theme.warn ()),
               Printf.sprintf "   %d skill(s) left out of the catalog"
                 (List.length left_out) )
             :: List.map
                  (fun entry ->
                    (Theme.warn ()),
                    "     " ^ Terminal_text.single_line entry)
                  left_out)
        @ [ Ansi.bold, Tool_table.effective_tool_header ]
        @ tool_lines
    end
  in
  let activation_lines =
    lazy begin
    match state.tools_inventory with
    | None -> [ Theme.warn (), " Skill Activations — not loaded" ]
    | Some { Masc.Tui_decode.ts_skill_activations = None; _ } ->
        [ Theme.warn (), " Skill Activations — no Keeper selected" ]
    | Some
        { Masc.Tui_decode.ts_skill_activations =
            Some
              (Masc.Tui_decode.Skill_activations_no_session
                 { sap_keeper_name });
          _ } ->
        [ Theme.warn (),
          Printf.sprintf " Skill Activations — %s — no session"
            (Terminal_text.single_line sap_keeper_name) ]
    | Some
        { Masc.Tui_decode.ts_skill_activations =
            Some
              (Masc.Tui_decode.Skill_activations_unavailable
                 { sap_keeper_name; sap_reason; sap_detail });
          _ } ->
        [ Theme.bad (),
          Printf.sprintf " Skill Activations — %s — unavailable (%s)"
            (Terminal_text.single_line sap_keeper_name)
            (Terminal_text.single_line sap_reason);
          Theme.bad (), "   " ^ Terminal_text.single_line sap_detail ]
    | Some
        { Masc.Tui_decode.ts_skill_activations =
            Some
              (Masc.Tui_decode.Skill_activations_available
                 { sap_keeper_name
                 ; sap_ledger
                 });
          _ } ->
        let sap_activations =
          Masc.Keeper_skill_activation_ledger.activations sap_ledger
        in
        let summary =
          Masc.Keeper_skill_activation_ledger.summarize sap_ledger
        in
        let scoped_summaries =
          Masc.Keeper_skill_activation_ledger.summarize_by_scope sap_ledger
        in
        let scoped_lines =
          List.concat_map
            (fun (scoped : Masc.Keeper_skill_activation_ledger.scoped_summary) ->
               let exact =
                 Skill_reference.to_yojson scoped.scope.reference
                 |> Yojson.Safe.to_string
               in
               let scoped_summary = scoped.summary in
               let runtime_counts values =
                 match values with
                 | [] -> "none"
                 | values ->
                   values
                   |> List.map
                        (fun (item : Masc.Keeper_skill_activation_ledger.runtime_count) ->
                           Printf.sprintf "%s:%d" item.runtime_id item.count)
                   |> String.concat ","
               in
               [ Ansi.dim,
                 "   proof exact=" ^ Terminal_text.single_line exact
               ; Ansi.dim,
                 Printf.sprintf
                   "     snapshot=%s keeper_turn=%s invocation_runtime=%s"
                   (Skill_catalog_snapshot.snapshot_revision_to_string
                      scoped.scope.snapshot_revision
                    |> Terminal_text.single_line)
                   (Ids.Turn_ref.to_string scoped.scope.turn_ref
                    |> Terminal_text.single_line)
                   (Terminal_text.single_line
                      scoped.scope.invocation_runtime_id)
               ; Ansi.dim,
                 Printf.sprintf
                   "     invoked=%d bodies=%d resources=%d provider_deliveries=%d official_handoffs=%d actions=%d composition=%d/%d/%d/%d invalid=%d"
                   scoped_summary.instruction_invocations
                   scoped_summary.skill_bodies_served
                   scoped_summary.skill_resources_served
                   scoped_summary.instruction_provider_deliveries
                   scoped_summary.instruction_official_client_handoffs
                   scoped_summary.instruction_actions_observed
                   scoped_summary.composition_invocations
                   scoped_summary.composition_provider_deliveries
                   scoped_summary.composition_official_client_handoffs
                   scoped_summary.composition_actions_observed
                   scoped_summary.invalid_transitions
               ; Ansi.dim,
                 Printf.sprintf
                   "     provider_delivery_runtimes=%s official_handoff_runtimes=%s action_runtimes=%s"
                   (runtime_counts scoped.provider_delivery_runtime_counts)
                   (runtime_counts
                      scoped.official_client_handoff_runtime_counts)
                   (runtime_counts scoped.action_runtime_counts)
               ])
            scoped_summaries
        in
        let receipt_lines =
          List.concat_map
            (fun (activation : Masc.Keeper_skill_activation_ledger.activation) ->
               let origin, served = skill_invocation_text activation.invocation in
               [ Ansi.dim,
                 "   begin id="
                 ^ Terminal_text.single_line activation.skill_tool_use_id
               ; Ansi.dim,
                 "   receipt_sha256="
                 ^ Masc.Keeper_skill_activation_ledger.receipt_projection_revision
                     sap_ledger
                     ~skill_tool_use_id:activation.skill_tool_use_id
               ; Ansi.dim,
                 "   exact source_id="
                 ^ (activation.identity
                    |> Skill_reference.identity_source_id_to_string
                    |> Terminal_text.single_line)
               ; Ansi.dim,
                 "     package_id="
                 ^ (activation.identity
                    |> Skill_reference.identity_package_id_to_string
                    |> Terminal_text.single_line)
               ; Ansi.dim,
                 "     name="
                 ^ Terminal_text.single_line activation.identity.name
               ; Ansi.dim,
                 "     content_revision="
                 ^ (activation.content_revision
                    |> Skill_reference.content_revision_to_string
                    |> Terminal_text.single_line)
               ; Ansi.dim,
                 Printf.sprintf
                   "     invoked turn=%d id=%s runtime=%s at=%s"
                   activation.agent_core_turn
                   (Terminal_text.single_line activation.skill_tool_use_id)
                   (Terminal_text.single_line activation.runtime_id)
                   (Terminal_text.single_line activation.activated_at)
               ; Ansi.dim,
                 "       served "
                 ^ Terminal_text.single_line served
               ; Ansi.dim,
                 "       delivered "
                 ^ (skill_delivery_text
                      ~has_action:(not (List.is_empty activation.actions))
                      activation.delivery
                    |> Terminal_text.single_line)
               ; Ansi.dim,
                 Printf.sprintf "       snapshot=%s keeper_turn=%s origin=%s"
                   (Skill_catalog_snapshot.snapshot_revision_to_string
                      activation.snapshot_revision
                    |> Terminal_text.single_line)
                   (Ids.Turn_ref.to_string activation.turn_ref
                    |> Terminal_text.single_line)
                   (Terminal_text.single_line origin)
               ]
               @ skill_action_lines activation.actions
               @ [ Ansi.dim,
                   "       end id="
                   ^ Terminal_text.single_line activation.skill_tool_use_id
                 ])
            sap_activations
        in
        let timeline_lines =
          (* Newest-first event stream over the loaded ledger: one line per
             delivery or observed action, so "what just ran" reads top-down
             without walking per-activation receipts. Row clocks go through
             the shared [Terminal_text.clock_timestamp]: slicing HH:MM:SS
             out of the RFC 3339 string would draw a UTC clock under a
             header in the terminal's zone (nine hours apart in Seoul). *)
          let time_of ts = Terminal_text.clock_timestamp ts in
          let events =
            List.concat_map
              (fun (activation :
                     Masc.Keeper_skill_activation_ledger.activation) ->
                 let skill =
                  Terminal_text.single_line activation.identity.name
                 in
                 (match activation.delivery with
                  | Some delivery ->
                    [ ( delivery.delivered_at,
                        Printf.sprintf
                          (* The same size the Context inspector spells, and
                             the attachment notes beside it: this cell divided
                             by 1024 itself and so had no rung above KB, while
                             the resource bound that caps the body is a config
                             value rather than a guarantee. *)
                          "%-8s delivery  %-20s %9s turn#%d %s"
                          (time_of delivery.delivered_at)
                          skill
                          (Masc_tui_context_inspector.format_bytes
                             delivery.content_bytes)
                          activation.agent_core_turn
                          (Terminal_text.single_line delivery.runtime_id) ) ]
                  | None -> [])
                 @ List.map
                     (fun (act :
                             Masc.Keeper_skill_activation_ledger.action) ->
                        ( act.observed_at,
                          Printf.sprintf "%-8s action    %-20s turn#%d %s"
                            (time_of act.observed_at)
                            (Terminal_text.single_line act.tool_name)
                            act.agent_core_turn
                            (Terminal_text.single_line act.runtime_id) ))
                     activation.actions)
              sap_activations
            |> List.sort (fun (left, _) (right, _) ->
                   String.compare right left)
          in
          let total = List.length events in
          let capped =
            List.filteri (fun index _ -> index < skill_timeline_display_cap) events
          in
          [ Ansi.bold,
            Printf.sprintf " Skill Timeline — %d event%s (newest first)"
              total
              (if total = 1 then "" else "s") ]
          @ List.map (fun (_, line) -> (Ansi.dim, "   " ^ line)) capped
        in
        [ Ansi.bold,
          Printf.sprintf " Skill Use — %s (%d receipts)"
            (Terminal_text.single_line sap_keeper_name)
            (List.length sap_activations)
        ; Ansi.bold,
          Printf.sprintf
            "   session totals: invoked=%d bodies=%d resources=%d provider_deliveries=%d official_handoffs=%d actions=%d invalid=%d"
            summary.instruction_invocations
            summary.skill_bodies_served
            summary.skill_resources_served
            summary.instruction_provider_deliveries
            summary.instruction_official_client_handoffs
            summary.instruction_actions_observed
            summary.invalid_transitions
        ; Ansi.dim,
          Printf.sprintf
            "   composition invoked=%d provider_deliveries=%d official_handoffs=%d actions=%d"
            summary.composition_invocations
            summary.composition_provider_deliveries
            summary.composition_official_client_handoffs
            summary.composition_actions_observed
        ; Ansi.dim,
          Printf.sprintf "   session=%s  ledger=%s"
            (Masc.Keeper_skill_activation_ledger.session_id sap_ledger
             |> Keeper_id.Trace_id.to_string
             |> Terminal_text.single_line)
            (Masc.Keeper_skill_activation_ledger.revision sap_ledger
             |> Masc.Keeper_skill_activation_ledger.ledger_revision_to_string
             |> Terminal_text.single_line)
        ; Ansi.dim,
          "   workspace="
          ^ (Masc.Keeper_skill_activation_ledger.workspace_key sap_ledger
             |> Terminal_text.single_line
             |> short_revision)
        ]
        @ timeline_lines
        @ scoped_lines
        @ receipt_lines
    end
  in
  let catalog_lines =
    lazy begin
    let registered_rows = Tool_tree.rows registered_tools in
    let heading =
      [ Ansi.bold,
        Printf.sprintf " Registered Catalog — %d tools"
          (List.length registered_tools);
        Ansi.dim, Tool_table.catalog_tool_header ]
    in
    heading
    @ List.map
        (function
          | Tool_tree.Domain { name; count } ->
              ( Ansi.bold,
                Printf.sprintf " %s (%d) %s"
                  (Terminal_text.single_line name) count tool_domain_rule )
          | Tool_tree.Family { name; count } ->
              Ansi.bold,
              Printf.sprintf "    %s (%d)" (Terminal_text.single_line name) count
          | Tool_tree.Tool tool ->
              let surfaces =
                match tool.Masc.Tui_decode.tl_surfaces with
                | [] -> "none"
                | names -> String.concat ", " names
              in
              (* The name is what an operator scans a hundred rows for, so it
                 keeps the terminal's own weight and the two columns that
                 answer about it are dimmed behind it. Dimming the whole row --
                 as this did -- left the headings above in bold and every tool
                 name on the screen as the faintest thing on it.

                 A tool on no surface is unreachable, and [Surfaces] is the
                 column that says so, so the warning starts there instead of
                 recolouring the name, which is not itself the problem. *)
              let metadata =
                if tool.tl_surfaces = [] then (Theme.warn ()) else Ansi.dim
              in
              ( Masc_tui_theme.tone Masc_tui_theme.Normal,
                Tool_table.catalog_tool_line ~metadata
                  ~name:(Terminal_text.single_line tool.tl_name)
                  ~direct:(if tool.tl_direct_call then "yes" else "no")
                  ~surfaces:(Terminal_text.single_line surfaces) ))
        registered_rows
    end
  in
  let usage_matrix_lines =
    lazy begin
    match state.skills_catalog with
    | None ->
        [ Ansi.dim, " Skill Usage — loading workspace catalog…" ]
    | Some { Masc.Tui_decode.sc_state; _ }
      when sc_state <> Masc.Tui_decode.Skills_ready ->
        [ Ansi.dim,
          Printf.sprintf " Skill Usage — catalog %s"
            (Terminal_text.single_line
               (Masc.Tui_decode.skills_catalog_state_to_string sc_state)) ]
    | Some
        { Masc.Tui_decode.sc_surfaces; sc_rejections; sc_sources; sc_config; _ }
      ->
        let used =
          List.filter
            (fun (surface : Masc.Tui_decode.skills_catalog_surface) ->
               surface.scs_usage <> [])
            sc_surfaces
        in
        (* A skill no keeper has reached yet was drawn nowhere: the pane
           listed only the used ones, so a skill that loaded correctly and has
           never been invoked read exactly like one that failed to load. The
           catalog total says how many there are to account for. *)
        let never_used = List.length sc_surfaces - List.length used in
        let heading =
          skill_source_lines ~config:sc_config ~sources:sc_sources
          @ [ Ansi.bold,
            Printf.sprintf " Skill Usage — %d of %d loaded skill%s used by a keeper%s"
              (List.length used)
              (List.length sc_surfaces)
              (if List.length sc_surfaces = 1 then "" else "s")
              (if never_used <= 0 then ""
               else Printf.sprintf "; %d never invoked" never_used)
          (* One skill's keepers do not fit beside its name -- there can be
             several, joined -- so the rows put them on the line below. The
             header said the two sat side by side and named the second column
             over the first one's trailing spaces; it now stands where each
             reading stands. *)
          ; Ansi.dim, Tool_table.skill_usage_name_indent ^ "SKILL"
          ; Ansi.dim,
            Tool_table.skill_usage_keeper_indent
            ^ "KEEPER  inv/delivered/actions \xc2\xb7 last used" ]
        in
        let rows =
          List.concat_map
            (fun (surface : Masc.Tui_decode.skills_catalog_surface) ->
               let keepers =
                 surface.scs_usage
                 |> List.map (fun (row : Masc.Tui_decode.skill_usage_row) ->
                        Printf.sprintf "%s %d/%d/%d \xc2\xb7 %s"
                          (Terminal_text.single_line row.su_keeper)
                          row.su_invocations row.su_deliveries row.su_actions
                          (Terminal_text.single_line
                             (skill_last_used_label row.su_last_used_at)))
                 |> String.concat " · "
               in
               (* Which kind a skill is says why it has a plan under it, or
                  why it has none: only a composition runs a flow. *)
               let named =
                 Printf.sprintf "%s  %s"
                   (Terminal_text.single_line surface.scs_name)
                   (Terminal_text.single_line surface.scs_kind)
               in
               let flow_rows =
                 match surface.scs_flow with
                 | None -> []
                 | Some flow ->
                   (match skill_flow_line flow with
                    | None -> []
                    | Some line ->
                      [ ( Ansi.dim
                        , Tool_table.skill_usage_keeper_indent ^ line ) ])
               in
               [ (Ansi.bold, Tool_table.skill_usage_name_indent ^ named)
               ; (Ansi.dim, Tool_table.skill_usage_keeper_indent ^ keepers) ]
               @ flow_rows)
            used
        in
        let rejection_rows =
          match sc_rejections with
          | [] -> []
          | rejections ->
            ( Ansi.bold,
              Printf.sprintf " Rejected Skill Sources — %d" (List.length rejections) )
            :: List.concat_map
                 (fun (rejection : Masc.Tui_decode.skill_catalog_rejection) ->
                    let source =
                      rejection.scr_source_id
                      ^ "/"
                      ^ Option.value
                          ~default:"(invalid package)"
                          rejection.scr_package_id
                    in
                    let revision =
                      rejection.scr_content_revision
                      |> Option.map short_revision
                      |> Option.value ~default:"unavailable"
                    in
                    let diagnostics =
                      match rejection.scr_reason with
                      | Masc.Tui_decode.Skill_document_rejected diagnostics ->
                        List.map
                          (fun (diagnostic : Masc.Tui_decode.skill_rejection_diagnostic) ->
                             ( Theme.warn (),
                               Printf.sprintf
                                 "     %s: %s"
                                 (Masc.Tui_decode.skill_diagnostic_code_to_string
                                    diagnostic.srd_diagnostic)
                                 (Terminal_text.single_line diagnostic.srd_message) ))
                          diagnostics
                      | Skill_document_unreadable ->
                        [ Theme.warn (), "     document_unreadable" ]
                      | Skill_exact_identity_duplicate ->
                        [ Theme.warn (), "     exact_identity_duplicate" ]
                      | Skill_invalid_package_id ->
                        [ Theme.warn (), "     invalid_package_id" ]
                    in
                    ( Theme.warn (),
                      Printf.sprintf
                        "   %s · %s"
                        (Terminal_text.single_line source)
                        (Terminal_text.single_line revision) )
                    :: diagnostics)
                 rejections
        in
        heading @ rows @ rejection_rows
    end
  in
  (* One section at a time. These used to be concatenated, and the first of
     them is one row per tool -- ninety-five of them on this workspace -- so
     the other four started past row 120 of a list a terminal shows twenty of.
     They were not missing; they were behind a section that never ends, with
     nothing saying so. *)
  let explanation =
    match state.tools_pane with
    | Masc_tui_types.Tools_surface ->
        [ Theme.info (), " What this answers — what can this Keeper call now?"
        ; Ansi.dim, "   Effective runtime delivery plus loaded Skills."
        ; Ansi.dim, "   Available does not mean used; open usage for evidence."
        ]
    | Masc_tui_types.Tools_async ->
        [ Theme.info (), " What this answers — what is the async composition broker doing?"
        ; Ansi.dim, "   Live queued, running, and recovery state."
        ; Ansi.dim, "   This is neither the tool catalog nor usage history."
        ]
    | Masc_tui_types.Tools_activations ->
        [ Theme.info (), " What this answers — which Skill receipts exist in this Keeper session?"
        ; Ansi.dim, "   Invocations, delivered bodies/resources, and observed actions."
        ; Ansi.dim, "   Missing means not retained here; it does not prove never used."
        ]
    | Masc_tui_types.Tools_usage ->
        [ Theme.info (), " What this answers — which Skills were actually used by each Keeper?"
        ; Ansi.dim, "   Retained invocation/delivery/action totals and last-use time."
        ; Ansi.dim, "   Skills with no retained use are omitted."
        ]
    | Masc_tui_types.Tools_catalog ->
        [ Theme.info (), " What this answers — which tools are registered anywhere in MASC?"
        ; Ansi.dim, "   Registration is not delivery. Surfaces names reachability."
        ; Ansi.dim, "   A tool with surfaces=none is currently unreachable."
        ]
  in
  let pane_lines =
    match state.tools_pane with
    | Masc_tui_types.Tools_surface -> Lazy.force effective_lines
    | Masc_tui_types.Tools_async -> async_request_observation_lines state
    | Masc_tui_types.Tools_activations -> Lazy.force activation_lines
    | Masc_tui_types.Tools_usage -> Lazy.force usage_matrix_lines
    | Masc_tui_types.Tools_catalog -> Lazy.force catalog_lines
  in
  explanation @ pane_lines
;;

