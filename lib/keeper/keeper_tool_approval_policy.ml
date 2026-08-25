module Descriptor = Keeper_tool_descriptor

type verdict =
  | Ask of { because : string }
  | Run of { because : string }

let verdict_because = function
  | Ask { because } | Run { because } -> because

(* Which families of tools change something outside the turn.

   Spelled out per group rather than defaulted, so a group added later stops
   the build here instead of inheriting "runs without asking". *)
let group_changes_the_world (group : Keeper_tool_group.t) =
  match group with
  | Keeper_tool_group.Execute_group -> true (* runs a program *)
  | Keeper_tool_group.Filesystem_group -> true (* writes files *)
  | Keeper_tool_group.Board_group -> false (* posts inside masc, undoable and visible *)
  | Keeper_tool_group.Search_files_group -> false
  | Keeper_tool_group.Voice_group -> false
  | Keeper_tool_group.Workspace_group -> false
  | Keeper_tool_group.Surface_group -> false
  | Keeper_tool_group.Memory_group -> false
  | Keeper_tool_group.Meta_group -> false
  | Keeper_tool_group.Core_group -> false

let descriptor_for tool_name =
  match Descriptor.descriptors_for_internal tool_name with
  | descriptor :: _ -> Some descriptor
  | [] -> Descriptor.find_public tool_name

let verdict_for_descriptor ~tool_name (descriptor : Keeper_tool_descriptor.t) ~input =
  match Descriptor.readonly_for_input descriptor ~input with
  | Some true -> Run { because = "this call only reads" }
  | Some false | None -> (
      let group = descriptor.Keeper_tool_descriptor.keeper_tool_group in
      if group_changes_the_world group then
        Ask
          { because =
              Printf.sprintf "%s tools change something outside this turn"
                (Descriptor.keeper_tool_group_to_string group)
          }
      else
        Run
          { because =
              Printf.sprintf "%s tools stay inside masc"
                (Descriptor.keeper_tool_group_to_string group)
          })

let verdict_for ~tool_name ~input =
  match descriptor_for tool_name with
  | None ->
      (* Not a safe tool -- one this build cannot classify. Running it unasked
         would make "no descriptor" the quietest way past the gate. *)
      Ask { because = "no descriptor declares what this tool does" }
  | Some descriptor -> verdict_for_descriptor ~tool_name descriptor ~input

let question_for ~tool_name ~input =
  let subject =
    Keeper_chat_tool_trail.tool_subject ~name:tool_name
      ~args:(Yojson.Safe.to_string input)
  in
  match subject with
  | None -> Printf.sprintf "Run %s?" tool_name
  | Some subject -> Printf.sprintf "Run %s on %s?" tool_name subject
