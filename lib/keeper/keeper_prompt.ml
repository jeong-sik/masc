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


(* The keeper name reaches the prompt through [identity_anchor] and
   [<identity>], both built from [keeper_name] directly. The former
   [{your-name}] / [YOUR_KEEPER_NAME] substitution pass is gone: no prompt asset
   declares either placeholder, so it rewrote nothing while scanning the whole
   shared prompt body on every build. Reintroducing name interpolation belongs
   in declared template variables, not a second substitution mechanism. *)

let exact_direct_mention_present ~(targets : string list) (content : string) :
    bool =
  Mention.any_mentioned ~targets content


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
      system_prompt_body ();
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

let append_trait_clause ~(base : string) ~(clause : string) : string =
  let b = String.trim base in
  let c = String.trim clause in
  if c = "" then b
  else if b = "" then c
  else if String_util.contains_substring_ci b c then b
  else Printf.sprintf "%s; %s" b c

include Keeper_text_processing
