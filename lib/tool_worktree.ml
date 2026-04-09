(** Worktree tools - Git worktree management for task isolation *)

open Tool_args

(* Context required by worktree tools *)
type context = {
  config: Room.config;
  agent_name: string;
}

type result = bool * string

(* Individual handlers *)
let handle_worktree_create ctx args =
  (* LLM may omit agent_name in args; fall back to context agent_name.
     This prevents Validation.Agent_id failures when the 9B model
     sends empty or missing agent_name. *)
  let agent_name =
    let from_args = get_string args "agent_name" "" in
    if from_args = "" then ctx.agent_name else from_args
  in
  let raw_task_id = get_string args "task_id" "" in
  let base_branch = get_string args "base_branch" "develop" in
  if raw_task_id = "" then
    (false, "task_id is required. Example: task_id='fix-login', task_id='add-auth'. \
             Use a-z, 0-9, hyphen, underscore only. No slashes.")
  else
  (* Normalize: replace / and \ with - so LLMs can use branch-style names *)
  let task_id =
    String.to_seq raw_task_id
    |> Seq.map (fun c -> if c = '/' || c = '\\' then '-' else c)
    |> String.of_seq
  in
  match Room.worktree_create_r ctx.config ~agent_name ~task_id ~base_branch with
  | Ok msg -> (true, msg)
  | Error e -> (false, Types.masc_error_to_string e)

let handle_worktree_remove ctx args =
  let task_id = get_string args "task_id" "" in
  if task_id = "" then
    (false, "task_id is required. Use the same task_id you passed to masc_worktree_create.")
  else
  match Room.worktree_remove_r ctx.config ~agent_name:ctx.agent_name ~task_id with
  | Ok msg -> (true, msg)
  | Error e -> (false, Types.masc_error_to_string e)

let handle_worktree_list ctx _args =
  let json = Room.worktree_list ctx.config in
  (true, Yojson.Safe.to_string json)

(* Dispatch function - returns None if tool not handled *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_worktree_create" -> Some (handle_worktree_create ctx args)
  | "masc_worktree_remove" -> Some (handle_worktree_remove ctx args)
  | "masc_worktree_list" -> Some (handle_worktree_list ctx args)
  | _ -> None

let schemas = Tool_schemas_worktree.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_read_only = [ "masc_worktree_list" ]
let _tool_spec_requires_join = [ "masc_worktree_create"; "masc_worktree_remove" ]

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
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
           ()))
    schemas
