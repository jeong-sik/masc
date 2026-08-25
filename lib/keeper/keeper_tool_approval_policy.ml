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

(* The node tools a composition-shaped call will run, or [None] when this name
   is not composition-shaped.

   Two sources, because compositions carry their plan in two different places.
   A [keeper_compose_<name>] entry is declared in the catalog, so the bundle
   builder wrote its nodes into the index when it materialised the tool. An
   ad-hoc [keeper_plan_execute] has no catalog entry: its nodes arrive in the
   tool input, and reading them here judges the plan actually being run rather
   than a fixed one.

   Both stay pure. The index read is an in-memory lookup and the input read is
   a JSON walk; neither opens anything, which is what [Hooks.hook] requires of
   whatever runs inside [pre_tool_use]. *)
let plan_node_tools ~tool_name ~input =
  if String.equal tool_name Keeper_tool_composition_catalog.plan_execute_tool_name
  then (
    match input with
    | `Assoc fields ->
      (match List.assoc_opt "nodes" fields with
       | Some (`List nodes) ->
         Some
           (List.filter_map
              (function
                | `Assoc node ->
                  (match List.assoc_opt "tool" node with
                   | Some (`String tool) -> Some tool
                   | Some _ | None -> None)
                | _ -> None)
              nodes)
       (* A malformed plan is not a plan whose nodes are all reads. It falls
          through to the reject below and is asked about, which is also what
          the tool itself will do with it. *)
       | Some _ | None -> None)
    | _ -> None)
  else
    Keeper_tool_composition_plan_index.node_tools
      (Keeper_tool_composition_plan_index.shared ())
      ~composition:tool_name
;;

let rec verdict_for ~tool_name ~input =
  match descriptor_for tool_name with
  | None -> verdict_for_undescribed ~tool_name ~input
  | Some descriptor -> (
      match Descriptor.readonly_for_input descriptor ~input with
      | Some true ->
          Run { because = "this call only reads" }
      | Some false | None ->
          let group = descriptor.keeper_tool_group in
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

(* A name with no descriptor is either a composition, whose nodes each have
   one, or something this build cannot classify at all.

   Folding the nodes is exact rather than approximate: a plan node may only
   name a descriptor-backed tool ([Keeper_tool_plan_request.plan_of_json]
   validates every node against the descriptor list and
   [Keeper_tool_plan.create] rejects an [Unknown_tool]), so the recursion
   below always terminates one level down and never re-enters this arm.

   A plan of reads runs. One node that would be asked about makes the whole
   plan asked about, and the reason names that node -- otherwise the operator
   sees a composition name and has to go read the plan to learn why they are
   being asked. *)
(* One node, judged without its input.

   The plan holds input *templates*, not the values a node will receive, so
   there is no input to hand [readonly_for_input]. Passing an empty object
   instead would not be neutral: a descriptor whose readonly answer depends on
   its input would be asked about a call it never sees, and whatever [{}]
   happens to produce would be pinned as the answer for every plan. So this
   reads the descriptor's static hint and, failing that, the group -- both are
   facts about the tool rather than about one call.

   Today no descriptor's answer would differ ([Grep] is the only one carrying
   [readonly_of_input] and it ignores the argument), so this is the same
   verdict by a route that stays right when that stops being true. *)
and node_asks_for_approval node =
  match descriptor_for node with
  (* Unreachable through dispatch: a plan node is validated against the
     descriptor list before the plan is built. Asked rather than assumed,
     because "no descriptor" is exactly the case this whole arm exists for. *)
  | None -> Some (node, "no descriptor declares what this tool does")
  | Some descriptor ->
    (match Descriptor.readonly_static_hint descriptor with
     | Some true -> None
     | Some false | None ->
       let group = descriptor.keeper_tool_group in
       if group_changes_the_world group
       then
         Some
           ( node
           , Printf.sprintf "%s tools change something outside this turn"
               (Descriptor.keeper_tool_group_to_string group) )
       else None)

(* The two control tools that ride beside an async composition.

   They have no descriptor for the same reason a composition has none — they
   are materialised as Agent-Core tools — but they are not compositions
   either, so there is no plan to fold and the arm below would ask about them.
   Reading the status of a request this keeper already made, and cancelling
   one, are both smaller than the composition they are about, and neither
   reaches outside masc. Board tools run unasked on that same reasoning.

   Named through the catalog rather than as literals here: the catalog is what
   the surface builds them from, so one spelling cannot drift from the other.
   They only exist on a turn that has an async composition
   (keeper_tool_composition_surface.ml gates them on [has_async]); naming them
   on a turn that does not costs nothing, because nothing can call them. *)
and control_tool_verdict tool_name =
  if String.equal tool_name Keeper_tool_composition_catalog.status_tool_name
  then Some (Run { because = "reads a composition request this keeper made" })
  else if String.equal tool_name Keeper_tool_composition_catalog.cancel_tool_name
  then Some (Run { because = "cancels a request inside masc" })
  else None

and verdict_for_undescribed ~tool_name ~input =
  match control_tool_verdict tool_name with
  | Some verdict -> verdict
  | None ->
  match plan_node_tools ~tool_name ~input with
  | None ->
    (* Not a safe tool -- one this build cannot classify. Running it unasked
       would make "no descriptor" the quietest way past the gate. *)
    Ask { because = "no descriptor declares what this tool does" }
  | Some node_tools ->
    let asked = List.find_map node_asks_for_approval node_tools in
    (match asked with
     | Some (node, because) ->
       Ask { because = Printf.sprintf "node %s: %s" node because }
     | None ->
       Run
         { because =
             Printf.sprintf "every one of its %d nodes runs unasked"
               (List.length node_tools)
         })
;;

let question_for ~tool_name ~input =
  let subject =
    Keeper_chat_tool_trail.tool_subject ~name:tool_name
      ~args:(Yojson.Safe.to_string input)
  in
  match subject with
  | None -> Printf.sprintf "Run %s?" tool_name
  | Some subject -> Printf.sprintf "Run %s on %s?" tool_name subject
