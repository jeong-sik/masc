(** Keeper_prompt — System prompts, personality evolution, and text processing
    for keeper agents. OAS-aligned: these functions define agent identity and
    text output. *)

open Keeper_types


(* Pre-compiled patterns for keeper name substitution in prompt templates.
   Top-level to avoid re-compilation on every build_keeper_system_prompt call. *)
let re_keeper_name_curly = Re.(compile (str "{your-name}"))
let re_keeper_name_upper = Re.(compile (str "YOUR_KEEPER_NAME"))

let exact_direct_mention_present ~(targets : string list) (content : string) :
    bool =
  Mention.any_mentioned ~targets content

(* Compiled once to avoid recompilation on every constitution fallback. *)
let re_state_block_instruction_var =
  Re.(compile (str "{{state_block_instruction}}"))

(* Fallback substitution for the [state_block_instruction] template variable on
   the raw constitution template.  Used when [render_prompt_template] returns
   [Error] (e.g. unrelated unresolved variable, malformed template) so the
   "State block template" anchor still appears in the prompt — otherwise the
   raw template surfaces a literal [{{state_block_instruction}}] placeholder
   and [missing_critical_prompt_anchors] reports [state_block_template] missing,
   triggering the recovery-guard warn loop observed in the keeper logs
   (~51 emissions / restart, all with keeper_name=null because the constitution
   path runs before the per-keeper context is bound). *)
let substitute_state_block_instruction_fallback raw =
  Re.replace_string re_state_block_instruction_var
    ~by:Keeper_state_block_prompt.instruction_text raw

let keeper_constitution () =
  match
    Prompt_registry.render_prompt_template Keeper_prompt_names.constitution
      [ ("state_block_instruction", Keeper_state_block_prompt.instruction_text) ]
  with
  | Ok value -> value
  | Error msg ->
      (* Preserve the original Error path (the render error is still real, e.g.
         a newly-introduced unresolved variable in the template) by emitting
         the same counter + warn the world-prompt fallback below uses.  But
         instead of returning the raw template with [{{state_block_instruction}}]
         unsubstituted (the silent-fallback bug), substitute the single
         variable we know about so the "State block template" anchor still
         appears in the prompt.  Any *other* unresolved variables remain
         visible as [{{name}}] placeholders, which is what the operator needs
         to see in order to fix the template. *)
      Prometheus.inc_counter
        Keeper_metrics.(to_string PromptFailures)
        ~labels:[("prompt", Keeper_prompt_names.constitution)]
        ();
      Log.Keeper.warn
        "keeper_constitution: template render failed (%s), falling back to \
         raw template with state_block_instruction substituted; other \
         variables may still be unresolved"
        msg;
      substitute_state_block_instruction_fallback
        (Prompt_registry.get_prompt Keeper_prompt_names.constitution)

let critical_prompt_anchors =
  [ ("continuity", "<continuity>");
    ("pr_merge_rules", "PR merge rules");
    ("state_block_template", "State block template");
    ("world", "<world>") ]

let missing_critical_prompt_anchors prompt =
  List.filter_map
    (fun (name, needle) ->
      if String_util.contains_substring prompt needle then None else Some name)
    critical_prompt_anchors

let critical_prompt_recovery_block_fallback =
  String.concat "\n"
    [ "<continuity>";
      "Recovery guard: preserve keeper technical instructions even if prompt templates were compacted or partially loaded.";
      "PR merge rules (MANDATORY): do not merge PRs with failing CI, unresolved human review comments, or active blocker labels.";
      Printf.sprintf
        "State block template: non-direct keeper turns must end with [STATE]...[/STATE] containing %s."
        Keeper_state_block_prompt.field_summary;
      "</continuity>";
      "";
      "<world>";
      "Recovery guard: act from the configured base path and active runtime tool schema; do not invent paths, repos, PRs, tasks, or tools.";
      "</world>" ]

(* Recovery fallback content normally lives at
   config/prompts/keeper.recovery_block.md so operators can edit it with the
   other prompts. Keep the in-code fallback because this guard must still work
   when prompt file loading is exactly what degraded.

   The registry version is trusted only when it carries all required anchors:
   an operator who accidentally edits out [<continuity>] or [PR merge rules]
   would otherwise produce a non-empty block that [ensure_critical_prompt_anchors]
   appends without restoring the missing safeguard — a silent regression vs the
   previous hardcoded path. Drift triggers the existing prompt failure counter
   plus a warn so the operator hears about it. *)
let critical_prompt_recovery_block () =
  let from_registry =
    String.trim (Prompt_registry.get_prompt Keeper_prompt_names.recovery_block)
  in
  if String.equal from_registry "" then critical_prompt_recovery_block_fallback
  else
    match missing_critical_prompt_anchors from_registry with
    | [] -> from_registry
    | missing ->
        Prometheus.inc_counter
          Keeper_metrics.(to_string PromptFailures)
          ~labels:[("prompt", "keeper.recovery_block.anchors")]
          ();
        Log.Keeper.warn
          "critical_prompt_recovery_block: registry text missing anchors (%s); \
           using in-code fallback to preserve safeguards"
          (String.concat "," missing);
        critical_prompt_recovery_block_fallback

let state_block_output_guard_text =
  "Output guard: this turn uses runtime-managed continuity. Do not output raw [STATE] or [/STATE] blocks in visible text; the runtime will synthesize and persist state metadata when needed."

let ensure_critical_prompt_anchors prompt =
  match missing_critical_prompt_anchors prompt with
  | [] -> prompt
  | missing ->
      Prometheus.inc_counter
        Keeper_metrics.(to_string PromptFailures)
        ~labels:[("prompt", "critical_prompt_anchors")]
        ();
      Log.Keeper.warn
        "build_keeper_system_prompt: critical prompt anchors missing (%s); \
         appending recovery guard"
        (String.concat "," missing);
      prompt ^ "\n\n" ^ critical_prompt_recovery_block ()

(** Resolve the <world> prompt. Falls back to the raw template text if
    rendering fails so prompt wiring bugs do not brick keepers. *)
let render_world_prompt () : string =
  match
    Prompt_registry.render_prompt_template Keeper_prompt_names.world []
  with
  | Ok rendered -> rendered
  | Error msg ->
      Prometheus.inc_counter
        Keeper_metrics.(to_string PromptFailures)
        ~labels:[("prompt", Keeper_prompt_names.world)]
        ();
      Log.Keeper.warn
        "render_world_prompt: template render failed, falling back to raw \
         template (keepers may see unrendered placeholders): %s"
        msg;
      Prompt_registry.get_prompt Keeper_prompt_names.world

let behavior_prompt_block name =
  match Keeper_prompt_external.get name with
  | Some content -> String.trim content
  | None ->
      Prometheus.inc_counter
        Keeper_metrics.(to_string PromptFailures)
        ~labels:[("prompt", "behavior/" ^ name)]
        ();
      Log.Keeper.warn
        "build_keeper_system_prompt: behavior prompt %s missing; \
         rendering config-drift marker instead of generic in-source behavior"
        name;
      Printf.sprintf
        "Behavior prompt config drift: missing config/prompts/behavior/%s.md. \
         Preserve the keeper's configured goal, persona, and runtime policy; \
         ask the operator to restore the missing behavior prompt file."
        name

let missing_personality_field_marker field =
  (* F-3: per-field Prometheus counter retained (operator dashboards key on
     specific field labels); WARN aggregation handled by caller so 3 missing
     fields per cycle emit 1 WARN with structured field list instead of 3
     separate WARNs. Pre-fix volume: ~666/24h (3 fields × 134 cycles + dups).
     Post-fix worst case: ~134/24h with field list preserved in message. *)
  Prometheus.inc_counter
    Keeper_metrics.(to_string PromptFailures)
    ~labels:[("prompt", "personality/" ^ field)]
    ();
  Printf.sprintf
    "Personality config drift: empty %s field. Preserve the keeper's \
     configured goal, persona, and runtime policy; ask the operator to \
     restore this self-model field."
    field

let log_missing_personality_fields missing_fields =
  match missing_fields with
  | [] -> ()
  | fields ->
      Log.Keeper.warn
        "build_keeper_system_prompt: personality fields empty: [%s]; \
         rendering config-drift markers instead of generic in-source \
         self-model text"
        (String.concat ", " fields)

let build_keeper_system_prompt
    ~goal ~short_goal ~mid_goal ~long_goal ~will ~needs ~desires
    ~instructions ?(persona_extended = "") ?(keeper_name = "")
    ?(active_goals = []) () =
  let goal = normalize_goal_horizon_text goal in
  let short_goal, mid_goal, long_goal =
    resolve_goal_horizons ~goal ~short_goal_opt:(Some short_goal)
      ~mid_goal_opt:(Some mid_goal) ~long_goal_opt:(Some long_goal)
  in
  (* Behavior prompt blocks live under
     [<prompts_dir>/behavior/<name>.md] and are read once per process via
     [Keeper_prompt_external.get]. Missing/unreadable files no longer inject
     generic in-source behavior text: they produce an operator-visible drift
     marker so the prompt tells the keeper that config is incomplete instead
     of silently changing persona policy. *)
  let profile_policy = behavior_prompt_block "profile_policy" in
  let continuity_contract = behavior_prompt_block "continuity_contract" in
  (* Layer 2 PR-B (commit 7): three normalize_self_model_text calls
     consolidated through [Keeper_personality_io.to_prompt_form]. Blank fields
     now render config-drift markers instead of generic self-model text. *)
  let rendered =
    Keeper_personality_io.to_prompt_form
      ~max_bytes:Keeper_config.prompt_render_max_bytes
      { will; needs; desires; instructions = "" }
  in
  (* F-3: aggregate missing personality fields into a single WARN per
     build_keeper_system_prompt call. Per-field Prometheus counters and the
     in-prompt config-drift marker remain unchanged so dashboards and the
     LLM-visible drift signal are preserved. *)
  let missing_personality = ref [] in
  let render_personality_field field value =
    if value = "" then begin
      missing_personality := field :: !missing_personality;
      missing_personality_field_marker field
    end else value
  in
  let will = render_personality_field "will" rendered.will in
  let needs = render_personality_field "needs" rendered.needs in
  let desires = render_personality_field "desires" rendered.desires in
  log_missing_personality_fields (List.rev !missing_personality);
  let custom =
    let s = String.trim instructions in
    if s = "" then ""
    else Printf.sprintf "\nCustom instructions:\n%s\n" s
  in
  let substitute_keeper_name s =
    if keeper_name = "" then s
    else
      s
      |> Re.replace_string re_keeper_name_curly ~by:keeper_name
      |> Re.replace_string re_keeper_name_upper ~by:keeper_name
  in
  let persona_block =
    let s = String_util.escape_xml (String.trim persona_extended) in
    if s = "" then ""
    else Printf.sprintf "<persona>\n%s\n</persona>\n\n" s
  in
  let active_goals_block =
    match active_goals with
    | [] -> ""
    | goals ->
        let lines =
          List.map
            (fun (id, title, horizon) ->
               Printf.sprintf "- %s [%s] %s"
                 (String_util.escape_xml id)
                 (String_util.escape_xml horizon)
                 (String_util.escape_xml title))
            goals
        in
        Printf.sprintf "\n<available_goals>\n%s\n</available_goals>\n"
          (String.concat "\n" lines)
  in
  (* Prefix ordering: common blocks first for LLM KV cache sharing.
     All keepers share the same autonomous-behavior, policy, continuity,
     and most of <world>/<capabilities> text.  Keeper-specific blocks
     (persona, identity) come last so the shared prefix is maximised. *)
  String.concat ""
    [
      (* ── Shared prefix (identical across all keepers) ────────── *)
      Prompt_registry.get_prompt Keeper_prompt_names.core_behavior;
      "\n\n";
      profile_policy;
      "\n\
       \n\
       <continuity>\n";
      continuity_contract;
      "\n";
      keeper_constitution ();
      "\n\
       </continuity>\n\
       \n\
       <world>\n";
      substitute_keeper_name (render_world_prompt ());
      "\n</world>\n\
       \n\
       <capabilities>\n";
      substitute_keeper_name (Prompt_registry.get_prompt Keeper_prompt_names.capabilities);
      "\n</capabilities>\n\
       \n\
       ";
      persona_block;
      "<identity>\n\
       Goal: ";
      goal;
      "\n\
       - Short-term: ";
      short_goal;
      "\n\
       - Mid-term: ";
      mid_goal;
      "\n\
       - Long-term: ";
      long_goal;
      "\n\
       Will: ";
      will;
      "\n\
       Needs: ";
      needs;
      "\n\
       Desires: ";
      desires;
      "\n\
       ";
      custom;
      active_goals_block;
      "</identity>";
    ]
  |> ensure_critical_prompt_anchors

(* XML wrapping stays in code — it is structure, not prompt content. *)
let direct_reply_mode_body () =
  Prompt_registry.get_prompt Keeper_prompt_names.reply_guidelines

let append_direct_reply_mode_prompt ~(base_prompt : string) : string =
  String.concat "\n"
    [
      base_prompt;
      "";
      "<direct_reply_mode>";
      String.trim (direct_reply_mode_body ());
      "</direct_reply_mode>";
    ]

let append_trait_clause ~(base : string) ~(clause : string) : string =
  let b = String.trim base in
  let c = String.trim clause in
  if c = "" then b
  else if b = "" then c
  else if String_util.contains_substring_ci b c then b
  else Printf.sprintf "%s; %s" b c

include Keeper_text_processing
