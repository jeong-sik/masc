open Governance_pipeline_types

(* ── Lethal Trifecta — Combinatorial Risk Assessment ─────────
   Simon Willison's "Lethal Trifecta": an agent simultaneously holding
   (1) untrusted external input, (2) sensitive data access, and
   (3) state modification capability = security incident.

   Meta AI's "Rule of Two": restrict to max 2 of 3 simultaneously.
   When all 3 are present, escalate state_modification tool risk.

   Classification is in code (not TOML) for the same reason as risk
   patterns: security policy changes require code review. *)

(** Per-tool capability classification.
    A tool may belong to multiple classes (e.g. tool_execute spans all 3). *)
let capability_classification : (string * capability_class list) list =
  [
    ("masc_web_search", [ External_input ]);
    ("masc_web_fetch", [ External_input ]);
    ("tool_execute", [ External_input; Sensitive_access; State_modification ]);
    ("tool_search_files", [ External_input; Sensitive_access ]);
    ("tool_read_file", [ Sensitive_access ]);
    ("keeper_memory_search", [ Sensitive_access ]);
    ("keeper_library_search", [ Sensitive_access ]);
    ("keeper_library_read", [ Sensitive_access ]);
    ("keeper_surface_read", [ Sensitive_access ]);
    ("keeper_surface_post", [ State_modification ]);
    ("keeper_person_note_set", [ State_modification ]);
    ("tool_edit_file", [ State_modification ]);
    ("tool_write_file", [ State_modification ]);
  ]

let tool_capabilities name =
  match List.assoc_opt name capability_classification with
  | Some caps -> caps
  | None -> []

let has_capability cls caps =
  List.mem cls caps

(** Compute trifecta status from a set of active tool names.
    Returns (class_count, has_external, has_sensitive, has_state_mod). *)
let assess_trifecta ~active_tool_names =
  let has_ext = ref false in
  let has_sens = ref false in
  let has_mod = ref false in
  List.iter (fun name ->
    let caps = tool_capabilities name in
    if has_capability External_input caps then has_ext := true;
    if has_capability Sensitive_access caps then has_sens := true;
    if has_capability State_modification caps then has_mod := true;
  ) active_tool_names;
  let count =
    (if !has_ext then 1 else 0)
    + (if !has_sens then 1 else 0)
    + (if !has_mod then 1 else 0)
  in
  (count, !has_ext, !has_sens, !has_mod)

(** When trifecta is active (all 3 classes present), escalate risk
    of state_modification tools to at least High.
    This ensures HITL gates fire at lower governance levels. *)
let combinatorial_risk_escalation ~trifecta_active ~tool_name ~base_risk ~input =
  if trifecta_active then
    let caps = tool_capabilities tool_name in
    let read_only_search_tool =
      String.equal tool_name "tool_search_files"
      && Keeper_tool_registry.is_read_only_with_input ~tool_name ~input
    in
    if has_capability State_modification caps && not read_only_search_tool then
      max_risk_level base_risk High
    else
      base_risk
  else
    base_risk

(* ── Risk Assessment ────────────────────────────────────────── *)

(** {2 Risk pattern sets — security-critical SSOT}

    Each pattern is checked against the tool name (case-insensitive substring).
    These are intentionally in code (not TOML) because changing risk
    classification is a security policy change that requires code review.
    Governance LEVEL (development/production/enterprise/paranoid) is the
    configurable dial — see [MASC_GOVERNANCE_LEVEL] env var. *)

(* Former [risk_overrides] (9 entries) is removed: eight were corrections
   for substring false-positives on registered tools and are now folded
   into [risk_of_*] typed tables (RFC-0193 / Issue #19032); the last
   ([masc_a2a_query_skill]) was dead code for a non-existent feature.
   [residual_risk_overrides] is now empty. The patterns below classify
   transition-action verbs and unknown (non-[Tool_name]) names. *)

let critical_patterns =
  [ "delete"; "remove"; "drop"; "force"; "reset"; "kill"; "destroy"; "purge" ]

let high_patterns =
  [ "create"; "update"; "write"; "deploy"; "push"; "merge"; "set"; "send"; "inject";
    "spawn"; "modify"; "assign" ]

let medium_patterns =
  [ "claim"; "join"; "leave"; "start"; "stop"; "pause"; "resume"; "confirm"; "approve";
    "reject"; "cancel" ]

let overwrite_sensitive_tools =
  [ "tool_edit_file"; "tool_write_file"; "edit_text_file" ]

let empty_overwrite_payload_keys = [ "content"; "new_string" ]

let contains_pattern name patterns =
  let name_lc = String.lowercase_ascii name in
  List.exists (fun pat ->
    let pat_len = String.length pat in
    let name_len = String.length name_lc in
    if pat_len > name_len then false
    else
      let rec check i =
        if i + pat_len > name_len then false
        else if String.sub name_lc i pat_len = pat then true
        else check (i + 1)
      in
      check 0
  ) patterns

let classify_name name =
  if contains_pattern name critical_patterns then Critical
  else if contains_pattern name high_patterns then High
  else if contains_pattern name medium_patterns then Medium
  else Low

(* ── Keeper-native typed risk SSOT ────────────────────────────────

   Public MASC tool names are owned by schema/descriptor registries, not by
   [Tool_name]. Their risk comes from Tool_catalog metadata, explicit action
   handling, and the fallback name patterns below. Keeper-native names still
   have a closed local type and remain exhaustively classified here. *)

let risk_of_keeper (k : Keeper_tool_name.t) : risk_level =
  let open Keeper_tool_name in
  match k with
  | Execute -> Critical
  | Board_comment | Board_comment_vote | Board_curation_read | Board_curation_submit
  | Board_post_get | Board_list | Board_post | Board_search | Board_stats
  | Board_sub_board_get | Board_sub_board_list | Board_vote | Broadcast
  | Context_status | Handoff | Library_read | Library_search | Memory_search
  | Memory_write | Search_files | Surface_read | Tasks_audit | Tasks_list | Time_now
  | Tool_search | Tools_list | Voice_agent | Voice_listen
  | Voice_session_end | Voice_session_start | Voice_sessions | Voice_speak -> Low
  | Board_sub_board_create | Board_sub_board_update | Task_claim | Task_create | Task_done
  | Surface_post | Keeper_msg | Person_note_set | Persona_create | Persona_update
    -> Medium
  | Fs_edit | Fs_write | Fs_read | Ide_annotate -> High
  | Board_sub_board_delete -> Critical
;;

(* Non-typed names keep explicit overrides when substring matching would
   misclassify them (e.g. "query_skill" contains "kill" -> Critical). *)
let residual_risk_overrides : (string * risk_level) list = []

let transition_action input =
  match input with
  | `Assoc kvs ->
      (match List.assoc_opt "action" kvs with
       | Some (`String action) ->
           let trimmed = String.trim action in
           if trimmed = "" then None else Some (String.lowercase_ascii trimmed)
       | _ -> None)
  | _ -> None

let goal_transition_risk input =
  match transition_action input with
  | Some ("request_complete" | "pause" | "resume" | "reopen") -> Medium
  | Some _ | None -> High

let rec collect_string_values ~keys json =
  match json with
  | `Assoc kvs ->
      List.concat_map
        (fun (key, value) ->
          let normalized_key = String.lowercase_ascii (String.trim key) in
          let direct =
            if List.mem normalized_key keys then
              match value with
              | `String text -> [ text ]
              | _ -> []
            else
              []
          in
          direct @ collect_string_values ~keys value)
        kvs
  | `List values -> List.concat_map (collect_string_values ~keys) values
  | _ -> []

let rec collect_all_string_values json =
  match json with
  | `Assoc kvs ->
      List.concat_map (fun (_, value) -> collect_all_string_values value) kvs
  | `List values -> List.concat_map collect_all_string_values values
  | `String text -> [ text ]
  | _ -> []

let rec collect_string_list_values ~keys json =
  match json with
  | `Assoc kvs ->
      List.concat_map
        (fun (key, value) ->
          let normalized_key = String.lowercase_ascii (String.trim key) in
          let direct =
            if List.mem normalized_key keys then
              match value with
              | `List values ->
                  values
                  |> List.filter_map (function
                         | `String text ->
                             let trimmed = String.trim text in
                             if trimmed = "" then None else Some trimmed
                         | _ -> None)
              | _ -> []
            else
              []
          in
          direct @ collect_string_list_values ~keys value)
        kvs
  | `List values -> List.concat_map (collect_string_list_values ~keys) values
  | _ -> []

(** Lazily-built set of canonical destructive substring patterns from
    {!Eval_gate.destructive_patterns}. Used to discriminate "real" destructive
    payloads (rm -rf, drop table, git push --force, ...) from
    {!Eval_gate.detect_evasion} indicator hits (variable expansion, hex
    escapes, ...).

    PR-J (2026-04-25): Before this split, [Eval_gate.detect_destructive]
    folded both pattern lists into a single [(string * string) option]
    return.  A normal [tool_execute echo "x: $(date)" && pwd] payload has
    no destructive substring but trips the [\$[({]] evasion regex,
    causing [classify_with_payload] to escalate every keeper subprocess
    that uses command substitution to Critical — which is the bulk of
    real-world Execute invocations.  Splitting the severity here lets
    governance treat the two cases differently (Critical vs Medium). *)
let default_policy = Destructive_ops_policy.default

let destructive_pattern_strings =
  lazy (List.map (fun p -> p.Shell_safety_types.pattern)
          (Destructive_ops_policy.patterns default_policy))

(** Outcome of inspecting a tool input payload for shell-style risk.
    Strictly internal — drives {!classify_with_payload}'s level decision. *)
type payload_severity =
  | Payload_clean
  | Payload_evasion_only
  | Payload_destructive

(** Walk every string value in [input] and report the worst severity hit.
    Stops early once a destructive pattern is found.  An [Evasion_only]
    result means the payload contains a suspicious meta-pattern (command
    substitution, hex escape, base64 decode, ...) that does not match any
    canonical destructive substring — these still warrant a confirmation
    gate but should not collapse to Critical. *)
let payload_severity input : payload_severity =
  let dest_pats = Lazy.force destructive_pattern_strings in
  let strings = collect_all_string_values input in
  let rec loop acc = function
    | [] -> acc
    | text :: rest ->
        (match Eval_gate.detect_destructive default_policy text with
         | None -> loop acc rest
         | Some (pat, _) ->
             if List.mem pat dest_pats then Payload_destructive
             else loop Payload_evasion_only rest)
  in
  loop Payload_clean strings

let has_destructive_payload input =
  (* Enumerate every [payload_severity] variant. A future severity
     (e.g. [Payload_admin_only], [Payload_data_exfil]) added between
     Evasion_only and Destructive should be classified deliberately —
     the [_ -> false] catch-all would have silently inherited
     "not destructive" for a new high-risk class. *)
  match payload_severity input with
  | Payload_destructive -> true
  | Payload_clean | Payload_evasion_only -> false

let has_empty_overwrite_payload input =
  collect_string_values ~keys:empty_overwrite_payload_keys input
  |> List.exists (fun text -> String.trim text = "")

(* RFC-0085 PR-13 — Removed unused [_tool_names_of_input]: defined
   in this module with underscore prefix (OCaml convention for unused)
   and confirmed 0 callers across lib/ + bin/. *)

let classify_with_contract_risk ~tool_name:_ ~input:_ =
  (* Contract_risk removed *)
  None

let classify_with_metadata ~tool_name =
  let meta = Tool_catalog.metadata tool_name in
  match (meta.Tool_catalog.destructive, meta.Tool_catalog.readonly) with
  | Some true, _ -> Some Critical
  | _, Some true -> Some Low
  | _ -> None

let classify_with_payload ~tool_name ~input =
  match payload_severity input with
  | Payload_destructive -> Some Critical
  | Payload_evasion_only ->
      (* PR-J: command substitution / hex escape / base64 decode hits in the
         payload don't auto-imply destructive intent (e.g. `$(date -u +%FT%TZ)`
         in a CI helper).  Surface them at Medium so a confirmation gate
         fires only at higher governance levels, instead of unconditionally
         flagging every script that uses normal shell features as Critical. *)
      Some Medium
  | Payload_clean ->
      if List.mem tool_name overwrite_sensitive_tools && has_empty_overwrite_payload input
      then Some Critical
      else None

let pre_metadata_risk_overrides : (string * risk_level) list =
  [ "masc_bind", Medium; "masc_unbind", Medium; "masc_goal_upsert", Medium; "masc_goal_verify", Medium ]

let baseline_risk ~tool_name ~input =
  match List.assoc_opt tool_name pre_metadata_risk_overrides with
  | Some level -> level
  | None ->
    match classify_with_metadata ~tool_name with
    | Some level -> level
    | None ->
      if String.equal tool_name "masc_goal_transition" then
        goal_transition_risk input
      else if
        String.equal tool_name
          (Tool_name.Task_name.to_string Tool_name.Task_name.Transition)
      then (
        (* transition risk depends on the action verb, not the tool name *)
        match transition_action input with
        | Some action -> classify_name action
        | None -> Low)
      else (
        match Keeper_tool_name.of_string tool_name with
        | Some typed -> risk_of_keeper typed
        | None -> (
            match List.assoc_opt tool_name residual_risk_overrides with
            | Some level -> level
            | None -> classify_name tool_name))

let keeper_mutation_requires_high_floor ~tool_name ~input =
  match tool_name with
  | "tool_edit_file" | "tool_write_file" -> true
  | "tool_search_files" -> false
  | _ -> false

let assess_risk ~tool_name ~input =
  let base_risk =
    match classify_with_payload ~tool_name ~input with
    | Some level -> level
    | None -> (
        let baseline = baseline_risk ~tool_name ~input in
        match classify_with_contract_risk ~tool_name ~input with
        | Some level -> max_risk_level baseline level
        | None -> baseline)
  in
  if keeper_mutation_requires_high_floor ~tool_name ~input
  then max_risk_level base_risk High
  else base_risk
