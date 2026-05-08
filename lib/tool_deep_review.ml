module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_deep_review — Adversarial code review with isolated context.

    PR#814 Gap 2: Spawns a review pass using a different model perspective.
    Context is deliberately stripped — only target file contents and the
    reviewer's question are provided. No JIRA, Slack, memory, or
    institutional knowledge.

    This forces the reviewer to evaluate code structurally rather than
    relying on domain context that might mask bugs.

    Uses the same [Oas_worker.run_named] pattern as {!Verifier_oas}. *)

open Printf

let validate_target_files target_files =
  let inputs =
    List.map
      (fun rel_path ->
        if Filename.check_suffix rel_path ".mli" then
          Adversarial_eval.Interface_contract { path = rel_path; content = "" }
        else
          Adversarial_eval.Changed_file { path = rel_path; content = "" })
      target_files
  in
  match Adversarial_eval.validate_inputs inputs with
  | Ok _ -> Ok ()
  | Error (path, kind) ->
      let kind_str =
        match kind with
        | Adversarial_eval.Readme -> "README"
        | Adversarial_eval.Design_doc -> "design_doc"
        | Adversarial_eval.Coord_history -> "room_history"
        | Adversarial_eval.Task_history -> "task_history"
        | Adversarial_eval.Governance_history -> "governance_history"
      in
      Error (sprintf "fresh-context input rejected (%s): %s" kind_str path)

(** Read a file's content, returning at most [max_chars] characters.
    Returns [None] on any file error. *)
let read_file_truncated path ~max_chars =
  try
    let content = Fs_compat.load_file path in
    if String.length content > max_chars then
      Some (String.sub content 0 max_chars ^ "\n... (truncated)")
    else
      Some content
  with Sys_error _ -> None

(** Build the isolated review prompt. Only file contents and the question
    are included — no external context. *)
let build_prompt ~target_files ~question ~base_path =
  match validate_target_files target_files with
  | Error _ as e -> e
  | Ok () ->
      let file_sections =
        List.filter_map (fun rel_path ->
          let full_path = Filename.concat base_path rel_path in
          match read_file_truncated full_path ~max_chars:3000 with
          | Some content -> Some (sprintf "=== %s ===\n%s" rel_path content)
          | None -> None
        ) target_files
      in
      if Stdlib.List.length file_sections = 0 then
        Error "No readable target files found"
      else
        let files_str = String.concat "\n\n" file_sections in
        Ok (sprintf
{|You are an adversarial code reviewer. Your job is to find bugs, edge cases,
and potential issues that a domain-aware reviewer might miss.

IMPORTANT: You have NO access to JIRA, GitHub issues, Slack, design docs,
or any context outside the code below. Review ONLY the code structurally.

QUESTION: %s

FILES:
%s

If you find concerns, list each with file:line and a brief explanation.
If the code looks correct, respond with exactly: NO_ISSUES_FOUND|} question files_str)

(** Run the adversarial review via OAS. Returns (ok, result_json). *)
let handle_deep_review (config : Coord.config) args : bool * string =
  let target_files =
    match Yojson.Safe.Util.(member "target_files" args) with
    | `List files ->
        List.filter_map (function `String s -> Some s | _ -> None) files
    | _ -> []
  in
  let question =
    match Yojson.Safe.Util.(member "question" args) with
    | `String s -> s
    | _ -> ""
  in
  if Stdlib.List.length target_files = 0 || String.equal question "" then
    (false, Yojson.Safe.to_string (`Assoc [
      ("error", `String "target_files (non-empty array) and question (string) are required")
    ]))
  else
    match build_prompt ~target_files ~question ~base_path:config.base_path with
    | Error msg ->
        (false, Yojson.Safe.to_string (`Assoc [
          ("error", `String msg)
        ]))
    | Ok prompt ->
        let cascade_name =
          Keeper_cascade_profile.cascade_name_for_use
            Keeper_cascade_profile.Adversarial_reviewer
        in
        match
          Masc_oas_bridge.run_with_caller
            ~caller:Env_config_oas_bridge.Tool_deep_review (fun () ->
            Oas_worker.run_named
              ~cascade_name
              ~goal:prompt
              ~max_turns:1
              ~temperature:0.5
              ~max_tokens:500
              ~approval:Approval_callbacks.auto_approve
              ()
          )
        with
        | Ok result ->
            let text = Agent_sdk_response.text_of_response result.response in
            let verdict =
              if String.equal (String.trim (String.uppercase_ascii text)) "NO_ISSUES_FOUND"
              then "no_issues"
              else "concern"
            in
            (true, Yojson.Safe.to_string (`Assoc [
              ("verdict", `String verdict);
              ("review", `String text);
              ("files_reviewed", `Int (List.length target_files));
            ]))
        | Error err ->
            let msg = Agent_sdk.Error.to_string err in
            Log.Misc.warn "adversarial review failed: %s" msg;
            (true, Yojson.Safe.to_string (`Assoc [
              ("verdict", `String "unavailable");
              ("error", `String msg);
            ]))

(** Tool schema for MCP registration. *)
let tool_definitions = [
  ("masc_deep_review",
   {|Request adversarial code review with isolated context. The reviewer sees ONLY the specified files and your question — no JIRA, Slack, memory, or design docs. Use this to catch structural bugs that domain context might mask.|},
   [
     ("target_files", "array", true, "List of file paths relative to room base (e.g., [\"lib/foo.ml\"])");
     ("question", "string", true, "Specific question for the reviewer (e.g., 'Are there off-by-one errors?')");
   ]);
]
