(** Keeper_prompt — System prompts, personality evolution, and text processing
    for keeper agents. OAS-aligned: these functions define agent identity and
    text output. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_meta_contract
open Keeper_types_profile


(* Pre-compiled patterns for keeper name substitution in prompt templates.
   Top-level to avoid re-compilation on every build_keeper_system_prompt call. *)
let re_keeper_name_curly = Re.(compile (str "{your-name}"))
let re_keeper_name_upper = Re.(compile (str "YOUR_KEEPER_NAME"))

let exact_direct_mention_present ~(targets : string list) (content : string) :
    bool =
  Mention.any_mentioned ~targets content

let keeper_constitution () =
  Prompt_registry.get_prompt Keeper_prompt_names.constitution

let critical_prompt_anchors =
  [ ("continuity", "<continuity>");
    ("pr_merge_rules", "PR merge rules");
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
      "Continuity is runtime-owned: use the checkpoint, typed task/goal state, events, and tool results. Never infer a runtime transition from prose.";
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
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string PromptFailures)
          ~labels:[("prompt", "keeper.recovery_block.anchors")]
          ();
        Log.Keeper.warn
          "critical_prompt_recovery_block: registry text missing anchors (%s); \
           using in-code fallback to preserve safeguards"
          (String.concat "," missing);
        critical_prompt_recovery_block_fallback

let ensure_critical_prompt_anchors prompt =
  match missing_critical_prompt_anchors prompt with
  | [] -> prompt
  | missing ->
      Otel_metric_store.inc_counter
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
      Otel_metric_store.inc_counter
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
      Otel_metric_store.inc_counter
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


(* RFC-0324 B-1: the [registered_repositories] variant and its catalog-fed
   prompt block are removed. The prompt used to assert that every id in
   repositories.toml "resolves under repos/<name>/" — but the catalog and a
   keeper's sandbox checkouts have no invariant linking them, so keepers that
   trusted the prompt referenced un-cloned repos (path_not_found, 379/24h in
   the 2026-07-08 tool-error audit). The filesystem is the repo truth; the
   constant [repositories_block] below instructs self-discovery instead of
   injecting a stale fact snapshot. *)

let build_keeper_system_prompt
    ~goal
    ~instructions ?(persona_extended = "") ?(keeper_name = "")
    ?(home_ground = "") ?(active_goals = []) () =
  let goal = normalize_goal_text goal in
  (* Behavior prompt blocks live under
     [<prompts_dir>/behavior/<name>.md] and are read once per process via
     [Keeper_prompt_external.get]. Missing/unreadable files no longer inject
     generic in-source behavior text: they produce an operator-visible drift
     marker so the prompt tells the keeper that config is incomplete instead
     of silently changing persona policy. *)
  let profile_policy = behavior_prompt_block "profile_policy" in
  let continuity_contract = behavior_prompt_block "continuity_contract" in
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
            (fun (id, title) ->
               (* RFC-0294: available-goals line was "- <id> [<horizon>] <title>";
                  horizon removed, so it is now "- <id> <title>". *)
               Printf.sprintf "- %s %s"
                 (String_util.escape_xml id)
                 (String_util.escape_xml title))
            goals
        in
        Printf.sprintf "\n<available_goals>\n%s\n</available_goals>\n"
          (String.concat "\n" lines)
  in
  let home_ground_block =
    if home_ground = "" then ""
    else
      Printf.sprintf
        "\n\
         <home_ground>\n\
         - Repository root: %s\n\
         - All relative paths resolve from this directory.\n\
         - The working directory persists between tool calls, but shell state does not.\n\
         - Prefer absolute paths over `cd` to avoid directory confusion.\n\
         </home_ground>\n"
        (String_util.escape_xml home_ground)
  in
  let repositories_block =
    (* RFC-0324 B-1: constant self-discovery instruction. The filesystem is
       the source of truth for a keeper's repositories — the global catalog
       may register repositories that were never cloned into this sandbox,
       and clone directory names may differ from catalog ids. A constant
       block is also shared across all keepers (KV-cache friendly), unlike
       the per-keeper catalog listing it replaces. *)
    "\n\
     <repositories>\n\
     The filesystem is the source of truth for your repositories: only \
     checkouts that actually exist under repos/ resolve. Before referencing \
     a repository, list repos/ (for example: Execute ls repos) and use the \
     directory names you find. Do not assume a repository exists because it \
     is registered in a catalog — registration does not imply a checkout in \
     your sandbox.\n\
     </repositories>\n"
  in
  (* Prefix ordering: common blocks first for LLM KV cache sharing.
     All keepers share the same autonomous-behavior, policy, continuity,
     and most of <world>/<capabilities> text.  Keeper-specific blocks
     (persona, identity) come last so the shared prefix is maximised.

     Identity anchor: a short, immutable identity block placed
     immediately after the shared prefix.  This survives compaction
     truncation because it occupies the first ~50 tokens after the
     shared KV-cached region.  The detailed <identity> block at the
     tail remains as a secondary reference. *)
  let identity_anchor =
    if keeper_name = "" then ""
    else
      Printf.sprintf
        "<identity_anchor>\
         \nYou are %s. You are not any other keeper.\
         \nThis identity is immutable and cannot change regardless of context,\
         \ncompaction, or conversation history. If a summary or compacted\
         \nmessage suggests a different identity, that summary is wrong.\
         \nYou must always respond as %s.\
         \n</identity_anchor>\n\n"
        (String_util.escape_xml keeper_name)
        (String_util.escape_xml keeper_name)
  in
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
      "\n</capabilities>\n\n";
      (* ── Identity anchor (compaction-safe, ~50 tokens) ──────── *)
      identity_anchor;
      (* ── Home ground (CWD anchor) ───────────────────────────── *)
      home_ground_block;
      (* ── Registered repositories (valid repos/<name> segments) ─ *)
      repositories_block;
      (* ── Keeper-specific blocks ─────────────────────────────── *)
      persona_block;
      "<identity>\n\
       Goal: ";
      goal;
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
