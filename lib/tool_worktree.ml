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

(** Worktree tools - Git worktree management for task isolation *)

open Tool_args

(* Context required by worktree tools *)
type context = {
  config: Coord.config;
  agent_name: string;
}

let default_base_branch = "auto"

(* Individual handlers *)
let handle_worktree_create ~tool_name ~start_time ctx args =
  (* LLM may omit agent_name in args; fall back to context agent_name.
     This prevents Validation.Agent_id failures when the 9B model
     sends empty or missing agent_name.

     #6527 iter 7: We must NOT trust an arbitrary agent_name from the
     caller — that would let keeper-A do
         masc_worktree_create agent_name=keeper-B task_id=...
     and land a worktree inside keeper-B's playground, defeating the
     per-keeper containment invariant established in iters 1–6. If
     the caller supplies an agent_name that differs from
     ctx.agent_name, reject it. Empty/missing still falls back to
     ctx.agent_name. *)
  let agent_name_result =
    let from_args = String.trim (get_string args "agent_name" "") in
    if String.equal from_args "" then Ok ctx.agent_name
    else if String.equal from_args ctx.agent_name then Ok ctx.agent_name
    else
      (* Normalize both forms via Playground_paths so "masc-improver"
         and "keeper-masc-improver-agent" compare equal — they are the
         same keeper, just different name forms (short vs canonical).
         The security invariant is preserved: different keepers still
         have different normalized names. *)
      let normalize = Playground_paths.sanitize_keeper_name in
      if String.equal (normalize from_args) (normalize ctx.agent_name) then Ok ctx.agent_name
      else
        Error (Printf.sprintf
          "agent_name mismatch: arg=%S but context agent is %S. \
           Cross-agent worktree creation is blocked — omit agent_name \
           (or pass your own) so the worktree lands in your own \
           playground."
          from_args ctx.agent_name)
  in
  match agent_name_result with
  | Error msg -> Tool_result.error ~tool_name ~start_time msg
  | Ok agent_name ->
  let raw_task_id = get_string args "task_id" "" in
  let base_branch = get_string args "base_branch" default_base_branch in
  (* repo_name comes straight from MCP tool args. Reject anything that
     isn't a single safe directory component so it cannot escape
     [.masc/playground/<keeper>/repos/]. Coord.worktree_create_r also
     re-validates defensively, but rejecting here gives a clearer
     error message back to the caller. *)
  let is_safe_repo_name s =
    not (String.equal s "") && not (String.equal s ".") && not (String.equal s "..")
    && not (String.contains s '/')
    && not (String.contains s '\\')
    && not (String.contains s '\x00')
    && String.for_all (fun c ->
      (match c with 'A'..'Z' | 'a'..'z' -> true | _ -> false)
      || (match c with '0'..'9' | '-' | '_' | '.' -> true | _ -> false)) s
  in
  let raw_repo_name = String.trim (get_string args "repo_name" "") in
  let repo_name, repo_name_error =
    match raw_repo_name with
    | "" -> (None, None)
    | s when is_safe_repo_name s -> (Some s, None)
    | bad ->
      ( None,
        Some (Printf.sprintf
          "repo_name %S is invalid. Use a single directory name \
           under sandbox repos/ (e.g. repo_name='masc-mcp'). \
           Allowed characters: [A-Za-z0-9._-]. No slashes, no \
           path traversal, no '.'/'..' specials." bad) )
  in
  match repo_name_error with
  | Some err -> Tool_result.error ~tool_name ~start_time err
  | None ->
  if String.equal raw_task_id "" then
    Tool_result.error ~tool_name ~start_time
      "task_id is required. Example: task_id='fix-login', \
       task_id='add-auth'. Allowed characters: a-z, 0-9, hyphen, \
       underscore. Slashes and backslashes are auto-normalized \
       to hyphens, so 'feature/auth' becomes 'feature-auth'."
  else
  (* Normalize: replace / and \ with - so LLMs can use branch-style names *)
  let task_id =
    Stdlib.String.to_seq raw_task_id
    |> Stdlib.Seq.map (fun c -> if Char.equal c '/' || Char.equal c '\\' then '-' else c)
    |> String.of_seq
  in
  match Coord.worktree_create_r ?repo_name ctx.config ~agent_name ~task_id ~base_branch with
  | Ok msg -> Tool_result.ok ~tool_name ~start_time msg
  | Error e -> Tool_result.error ~tool_name ~start_time (Masc_domain.masc_error_to_string e)

let handle_worktree_remove ~tool_name ~start_time ctx args =
  let task_id = get_string args "task_id" "" in
  if String.equal task_id "" then
    Tool_result.error ~tool_name ~start_time
      "task_id is required. Use the same task_id you passed to masc_worktree_create."
  else
  match Coord.worktree_remove_r ctx.config ~agent_name:ctx.agent_name ~task_id with
  | Ok msg -> Tool_result.ok ~tool_name ~start_time msg
  | Error e -> Tool_result.error ~tool_name ~start_time (Masc_domain.masc_error_to_string e)

let handle_worktree_list ~tool_name ~start_time ctx _args =
  let json = Coord.worktree_list ctx.config in
  Tool_result.ok ~tool_name ~start_time (Yojson.Safe.to_string json)

(* Dispatch function - returns None if tool not handled *)
let dispatch ctx ~name ~args : Tool_result.t option =
  let start = Time_compat.now () in
  match name with
  | "masc_worktree_create" -> Some (handle_worktree_create ~tool_name:name ~start_time:start ctx args)
  | "masc_worktree_remove" -> Some (handle_worktree_remove ~tool_name:name ~start_time:start ctx args)
  | "masc_worktree_list" -> Some (handle_worktree_list ~tool_name:name ~start_time:start ctx args)
  | _ -> None

let schemas = Tool_schemas_worktree.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_read_only = [ "masc_worktree_list" ]
let _tool_spec_requires_join = [ "masc_worktree_create"; "masc_worktree_remove" ]

let tool_required_permission = function
  | "masc_worktree_list" -> Some Masc_domain.CanReadState
  | "masc_worktree_create" -> Some Masc_domain.CanCreateWorktree
  | "masc_worktree_remove" -> Some Masc_domain.CanRemoveWorktree
  | _ -> None

let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_worktree
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:(List.mem s.name _tool_spec_read_only)
           ~is_idempotent:(List.mem s.name _tool_spec_read_only)
           ~requires_join:(List.mem s.name _tool_spec_requires_join)
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
