module Descriptor = Keeper_tool_descriptor

type verdict =
  | Ask of { because : string }
  | Run of { because : string }

(* The reason a name nothing owns comes back with. Named so the bundle gate
   can tell "could not classify" from a real classification. *)
let unclassifiable_because = "no descriptor declares what this tool does"

(* An undescribed name is one of four things. Closed, so a fifth kind of
   tool added to the bundle stops the build here rather than falling into
   the reject and asking the operator a question they cannot act on. *)
type undescribed =
  | Control of verdict
  | Composition of string list
  | Ad_hoc_plan
  | Attached_service of bool option
      (** A tool from a work service this Keeper is attached to, carrying
          what that service said about whether it only reads. *)
  | Unknown

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
(* The nodes an ad-hoc plan names, read from the tool input. Pure: a JSON
   walk, which is what [Hooks.hook] requires of anything inside
   [pre_tool_use]. *)
let ad_hoc_plan_nodes input =
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
     | Some _ | None -> None)
  | _ -> None
;;

(* The trailing unit is what lets [?composition_plan_index] be left out.
   Every other argument is labelled, so without it nothing marks the
   application as finished and each call reads as a function still waiting
   for the optional. *)
let rec verdict_for ?composition_plan_index ~tool_name ~input () =
  match descriptor_for tool_name with
  | None -> verdict_for_undescribed ?composition_plan_index ~tool_name ~input ()
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

(* What an undescribed name is, decided once.

   Two callers need this and they must not answer differently. [verdict_for]
   asks what to do about a call; the bundle gate asks whether this build can
   place the name at all. Splitting that into two predicates is how one grows
   an arm the other does not have, and the gate then passes while the tool
   still asks with a reason nobody can act on.

   [Ad_hoc_plan] is why the two questions are not the same question.
   [keeper_plan_execute] is a name this build knows, but what it does depends
   on nodes that arrive in the input — so it is classifiable without being
   decidable from the name alone. A gate that asked [verdict_for] with an
   empty input would read that as "cannot classify", which is the empty-input
   trap this policy already avoids one level down when it judges plan nodes on
   static facts rather than on a fabricated [{}]. *)
and undescribed_kind ?composition_plan_index tool_name =
  if String.equal tool_name Keeper_tool_composition_catalog.status_tool_name
  then Control (Run { because = "reads a composition request this keeper made" })
  else if String.equal tool_name Keeper_tool_composition_catalog.cancel_tool_name
  then Control (Run { because = "cancels a request inside masc" })
  else if String.equal tool_name Keeper_tool_composition_catalog.skill_tool_name
  then
    Control
      (Run { because = "reads one instruction skill this keeper already carries" })
  else if String.equal
            tool_name
            Keeper_tool_composition_catalog.plan_execute_tool_name
  then Ad_hoc_plan
  else
    match
      Option.bind composition_plan_index (fun index ->
        Keeper_tool_composition_plan_index.node_tools index ~composition:tool_name)
    with
    | Some node_tools -> Composition node_tools
    | None ->
      (match
         Keeper_identity_tool_index.read_only
           (Keeper_identity_tool_index.shared ())
           ~tool_name
       with
       | Some read_only -> Attached_service read_only
       | None -> Unknown)

and verdict_of_nodes node_tools =
  match List.find_map node_asks_for_approval node_tools with
  | Some (node, because) ->
    Ask { because = Printf.sprintf "node %s: %s" node because }
  | None ->
    Run
      { because =
          Printf.sprintf "every one of its %d nodes runs unasked"
            (List.length node_tools)
      }

and verdict_for_undescribed ?composition_plan_index ~tool_name ~input () =
  match undescribed_kind ?composition_plan_index tool_name with
  | Control verdict -> verdict
  | Attached_service (Some true) ->
    Run { because = "the service says this tool only reads" }
  | Attached_service (Some false) ->
    Ask { because = "the service says this tool can change something there" }
  (* Silence is not permission. On a lane that can ask, this reaches an
     operator; on one that cannot -- the official-client lanes pass no
     approval callback -- it is a refusal, so the reason has to say what
     would change it rather than only what is wrong. *)
  | Attached_service None ->
    Ask
      { because =
          "the service did not say whether this tool only reads; it runs \
           once the service annotates it, or while this keeper is set to yolo"
      }
  | Composition node_tools -> verdict_of_nodes node_tools
  | Ad_hoc_plan ->
    (match ad_hoc_plan_nodes input with
     (* A malformed plan is not a plan whose nodes are all reads. The tool
        will reject it too; asking about it first is the same answer earlier. *)
     | None -> Ask { because = "this plan does not say which tools it runs" }
     | Some node_tools -> verdict_of_nodes node_tools)
  | Unknown ->
    (* Not a safe tool -- one this build cannot classify. Running it unasked
       would make "no descriptor" the quietest way past the gate. *)
    Ask { because = unclassifiable_because }
;;

let classifies ?composition_plan_index ~tool_name () =
  match descriptor_for tool_name with
  | Some _ -> true
  | None ->
    (match undescribed_kind ?composition_plan_index tool_name with
     | Control _ | Composition _ | Ad_hoc_plan | Attached_service _ -> true
     | Unknown -> false)
;;

let question_for ~tool_name ~input =
  let subject =
    Keeper_chat_tool_trail.tool_subject ~name:tool_name
      ~args:(Yojson.Safe.to_string input)
  in
  match subject with
  | None -> Printf.sprintf "Run %s?" tool_name
  | Some subject -> Printf.sprintf "Run %s on %s?" tool_name subject
