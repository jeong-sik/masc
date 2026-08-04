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

(* One anchor, because there is now one shared block. The former
   [<continuity>] / [<world>] pair anchored two of the four shared prompts,
   so a partial load that dropped [capabilities] or [core_behavior] passed
   the check. [<system>] covers the whole merged block. *)
let critical_prompt_anchors = [ ("system", "<system>") ]

let missing_critical_prompt_anchors prompt =
  List.filter_map
    (fun (name, needle) ->
      if String_util.contains_substring prompt needle then None else Some name)
    critical_prompt_anchors

let critical_prompt_recovery_block_fallback =
  String.concat "\n"
    [ "<system>";
      "Recovery guard: preserve keeper technical instructions even if prompt templates were compacted or partially loaded.";
      "Continuity is runtime-owned: use the checkpoint, typed task/goal state, events, and tool results. Never infer a runtime transition from prose.";
      "Act from the configured base path and active runtime tool schema; do not invent paths, repos, PRs, tasks, or tools.";
      "</system>" ]

(* Recovery fallback content normally lives at
   config/prompts/keeper.recovery_block.md so operators can edit it with the
   other prompts. Keep the in-code fallback because this guard must still work
   when prompt file loading is exactly what degraded.

   The registry version is trusted only when it carries all required anchors:
   an operator who accidentally edits out [<system>]
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

(* [keeper.system] declares no template variables, so it is read directly.
   The former [render_world_prompt] carried a render-failure fallback for a
   template that never had a variable to render. *)
let system_prompt_body () : string =
  Prompt_registry.get_prompt Keeper_prompt_names.system

let build_keeper_system_prompt
    ~instructions ?(keeper_name = "")
    ?(workspace_root = "") ?(active_goals = []) () =
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
  let active_goals_block =
    match active_goals with
    | [] -> ""
    | goals ->
        let lines =
          List.map
            (fun (id, title) ->
               match String.trim title with
               | "" -> Printf.sprintf "- %s" (String_util.escape_xml id)
               | title ->
                 Printf.sprintf "- %s %s"
                   (String_util.escape_xml id)
                   (String_util.escape_xml title))
            goals
        in
        Printf.sprintf "\n<available_goals>\n%s\n</available_goals>\n"
          (String.concat "\n" lines)
  in
  let workspace_block =
    if workspace_root = "" then ""
    else
      Printf.sprintf
        "\n\
         <workspace>\n\
         - Visible sandbox root: %s\n\
         - Pass a relative typed `cwd` (usually `.`), not this absolute root.\n\
         - Relative argv path operands resolve from the typed `cwd`.\n\
         - The working directory persists between tool calls, but shell state does not.\n\
         - Prefer relative argv path operands. In Docker, host absolute paths are unavailable.\n\
         </workspace>\n"
        (String_util.escape_xml workspace_root)
  in
  (* Prefix ordering: the shared block comes first for LLM KV cache sharing.
     All keepers share the same <system> text.  Keeper-specific blocks
     (workspace, identity) come last so the shared prefix is maximised.

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
      "<system>\n";
      substitute_keeper_name (system_prompt_body ());
      "\n</system>\n\n";
      (* ── Identity anchor (compaction-safe, ~50 tokens) ──────── *)
      identity_anchor;
      workspace_block;
      (* ── Keeper-specific blocks ─────────────────────────────── *)
      "<identity>";
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
