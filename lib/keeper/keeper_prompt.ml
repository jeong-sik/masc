(** Keeper_prompt — System prompts, Keeper instructions, and text processing
    for keeper agents. AGENT_CORE-aligned: these functions define agent identity and
    text output. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_meta_contract
open Keeper_types_profile


(* The keeper name reaches the prompt through the [<identity>] block, built
   from [keeper_name] directly. The former
   [{your-name}] / [YOUR_KEEPER_NAME] substitution pass is gone: no prompt asset
   declares either placeholder, so it rewrote nothing while scanning the whole
   shared prompt body on every build. Reintroducing name interpolation belongs
   in declared template variables, not a second substitution mechanism. *)

let exact_direct_mention_present ~(targets : string list) (content : string) :
    bool =
  Mention.any_mentioned ~targets content


(* [keeper] declares no template variables, so it is read directly. *)
let system_prompt_body () : string =
  Prompt_registry.get_prompt Prompt_names.keeper

let render_instruction key vars =
  match Prompt_registry.render_prompt_template key vars with
  | Ok prompt -> prompt
  | Error detail -> invalid_arg (Printf.sprintf "missing or invalid prompt %s: %s" key detail)

let build_keeper_system_prompt
    ~instructions ?(keeper_name = "") ?(workspace_root = "") () =
  let custom =
    let s = String.trim instructions in
    if s = "" then ""
    else
      "\n"
      ^ render_instruction Prompt_names.keeper_instructions_custom [ "instructions", s ]
      ^ "\n"
  in
  let workspace_block =
    if workspace_root = "" then ""
    else
      "\n" ^ String.trim (render_instruction Prompt_names.keeper_workspace
        [ "workspace_root", String_util.escape_xml workspace_root ]) ^ "\n"
  in
  (* Prefix ordering: the shared block comes first for LLM KV cache sharing.
     All keepers share the same <system> text, so keeper-specific blocks come
     after it and the shared prefix stays maximal.

     Identity is stated once, immediately after the shared prefix. *)
  let identity_block =
    if keeper_name = "" then ""
    else
      String.trim (render_instruction Prompt_names.keeper_identity
        [ "keeper_name", String_util.escape_xml keeper_name ]) ^ "\n\n"
  in
  (* The wrapping tags and the custom-instructions heading are slots in
     keeper.md ([keeper.tags.*], [keeper.instructions.custom]); the newlines
     between blocks are structure and stay here. *)
  String.concat
    ""
    [ (* ── Shared prefix (identical across all keepers) ────────── *)
      render_instruction Prompt_names.keeper_tags_system_open []
    ; "\n"
    ; system_prompt_body ()
    ; "\n"
    ; render_instruction Prompt_names.keeper_tags_system_close []
    ; "\n\n"
    ; (* ── Keeper-specific blocks ─────────────────────────────── *)
      identity_block
    ; workspace_block
    ; (* Operator instructions. The Goals a keeper can pick up ride the
         turn's own context, where they change without rewriting the prefix
         every keeper shares. *)
      render_instruction Prompt_names.keeper_tags_instructions_open []
    ; custom
    ; render_instruction Prompt_names.keeper_tags_instructions_close []
    ]
;;

include Keeper_text_processing
