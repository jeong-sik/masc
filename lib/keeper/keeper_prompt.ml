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
  String.concat ""
    [
      (* ── Shared prefix (identical across all keepers) ────────── *)
      "<system>\n";
      system_prompt_body ();
      "\n</system>\n\n";
      (* ── Keeper-specific blocks ─────────────────────────────── *)
      identity_block;
      workspace_block;
      (* Operator instructions and the goals open right now. *)
      "<instructions>";
      custom;
      active_goals_block;
      "</instructions>";
    ]

include Keeper_text_processing
