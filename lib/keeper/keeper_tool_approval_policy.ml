module Descriptor = Keeper_tool_descriptor

type verdict =
  | Ask of { because : string }
  | Run

(* The reason a name nothing owns comes back with. Named so the bundle gate
   can tell "could not classify" from a real classification. *)
let unclassifiable_because = "no descriptor declares what this tool does"

(* An undescribed name is one of four things. Closed, so a fifth kind of
   tool added to the bundle stops the build here rather than falling into
   the reject and asking the operator a question they cannot act on. *)
type undescribed =
  | Control
  | Composition of string list
  | Attached_service
      (** A tool from a work service this Keeper is attached to. *)
  | Unknown

(* Which families of tools change something outside the turn.

   Spelled out per group rather than defaulted, so a group added later stops
   the build here instead of inheriting "runs without asking". *)
let descriptor_for ?composition_plan_index tool_name =
  match Option.bind composition_plan_index Keeper_tool_composition_plan_index.descriptors with
  | Some descriptors ->
      List.find_opt (fun descriptor ->
        List.mem tool_name (Descriptor.registered_names descriptor)) descriptors
  | None ->
      match Descriptor.descriptors_for_internal tool_name with
      | descriptor :: _ -> Some descriptor
      | [] -> Descriptor.find_public tool_name

(* The host filesystem producer resolves its confined capability before
   authorizing own-playground writes or consulting the durable Gate. Its
   endpoint-owned sibling only admits that playground and refuses external
   paths. This hook cannot replace either producer's resolved authority.
   Execute likewise belongs to its execution Gate, which decides with the
   call's resolved cwd, sandbox profile and grants, and WebSearch/WebFetch
   run through [Keeper_gate.decide_external_service] in their producer. *)
let producer_authorizes descriptor =
  match descriptor.Descriptor.runtime_handler with
  | Descriptor.Tool_execute
  | Descriptor.Tool_write_file | Descriptor.Tool_edit_file
  | Descriptor.Tool_web_search | Descriptor.Tool_web_fetch -> true
  | Keeper_tool_descriptor.Tool_search_files | Keeper_tool_descriptor.Tool_read_file
  | Keeper_tool_descriptor.Tool_lane_status | Keeper_tool_descriptor.Tool_tools_list
  | Keeper_tool_descriptor.Tool_capability_search | Keeper_tool_descriptor.Tool_context_status
  | Keeper_tool_descriptor.Tool_peer_artifact | Keeper_tool_descriptor.Tool_artifact_read
  | Keeper_tool_descriptor.Tool_skill_validate | Keeper_tool_descriptor.Tool_artifact_draft | Keeper_tool_descriptor.Tool_artifact_publish | Keeper_tool_descriptor.Tool_skill_publish
  | Keeper_tool_descriptor.Tool_workspace_memory_read | Keeper_tool_descriptor.Tool_memory_search
  | Keeper_tool_descriptor.Tool_memory_select | Keeper_tool_descriptor.Tool_memory_retract
  | Keeper_tool_descriptor.Tool_memory_write | Keeper_tool_descriptor.Tool_constitution_write
  | Keeper_tool_descriptor.Tool_constitution_read | Keeper_tool_descriptor.Tool_constitution_remove
  | Keeper_tool_descriptor.Tool_wiki_search | Keeper_tool_descriptor.Tool_wiki_read
  | Keeper_tool_descriptor.Tool_surface_read | Keeper_tool_descriptor.Tool_surface_post
  | Keeper_tool_descriptor.Tool_ide_annotate
  | Keeper_tool_descriptor.Tool_voice_dispatch | Keeper_tool_descriptor.Tool_task_dispatch
  | Keeper_tool_descriptor.Tool_board_dispatch | Keeper_tool_descriptor.Tool_masc_task_dispatch
  | Keeper_tool_descriptor.Tool_masc_plan_dispatch | Keeper_tool_descriptor.Tool_masc_run_dispatch
  | Keeper_tool_descriptor.Tool_masc_agent_dispatch
  | Keeper_tool_descriptor.Tool_masc_workspace_dispatch
  | Keeper_tool_descriptor.Tool_masc_misc_dispatch
  | Keeper_tool_descriptor.Tool_browser_tabs
  | Keeper_tool_descriptor.Tool_browser_read | Keeper_tool_descriptor.Tool_browser_session
  | Keeper_tool_descriptor.Tool_browser_goto | Keeper_tool_descriptor.Tool_browser_act
  | Keeper_tool_descriptor.Tool_browser_interact
  | Keeper_tool_descriptor.Tool_masc_agent_timeline_dispatch
  | Keeper_tool_descriptor.Tool_masc_schedule_dispatch
  | Keeper_tool_descriptor.Tool_keeper_composition_result_dispatch
  | Keeper_tool_descriptor.Tool_keeper_code_query_dispatch
  | Keeper_tool_descriptor.Tool_receipt_wait
  | Keeper_tool_descriptor.Tool_keeper_job_dispatch
  | Keeper_tool_descriptor.Tool_masc_keeper_dispatch
  | Keeper_tool_descriptor.Tool_masc_fusion_dispatch
  | Keeper_tool_descriptor.Tool_masc_fusion_status
  | Keeper_tool_descriptor.Tool_masc_fusion_decision
  | Keeper_tool_descriptor.Tool_masc_file_dispatch
  | Keeper_tool_descriptor.Tool_masc_wiki_dispatch
  | Keeper_tool_descriptor.Tool_masc_local_runtime_dispatch
  | Keeper_tool_descriptor.Tool_analyze_image | Keeper_tool_descriptor.Tool_read_image
  | Keeper_tool_descriptor.Tool_lane_addon _ -> false

let rec verdict_for ~identity_tool_index ~composition_plan_index ~tool_name ~input =
  match descriptor_for ?composition_plan_index tool_name with
  | None -> verdict_for_undescribed ~identity_tool_index ~composition_plan_index ~tool_name ~input
  | Some descriptor -> (
      if producer_authorizes descriptor then Run
      else
      match Descriptor.readonly_for_input descriptor ~input with
      | Some true -> Run
      | Some false | None ->
          (* A write that only moves masc's own durable rows is visible in the
             workspace and undoable there, so it runs. One that leaves — the
             sandbox filesystem, a process, a service — is asked about. The
             descriptor declares which it is; before #31728 this same split
             was read off the tool's group. *)
          if descriptor.Descriptor.policy.Descriptor.leaves_masc then
            Ask { because = "this call reaches outside masc" }
          else Run)

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
   reads the descriptor's static hint and external-effect ownership -- both are
   facts about the tool rather than about one call.

   Today no descriptor's answer would differ ([Grep] is the only one carrying
   [readonly_of_input] and it ignores the argument), so this is the same
   verdict by a route that stays right when that stops being true. *)
and node_asks_for_approval ~composition_plan_index node =
  match descriptor_for ?composition_plan_index node with
  (* Unreachable through dispatch: a plan node is validated against the
     descriptor list before the plan is built. Asked rather than assumed,
     because "no descriptor" is exactly the case this whole arm exists for. *)
  | None -> Some (node, "no descriptor declares what this tool does")
  | Some descriptor ->
    if producer_authorizes descriptor then None
    else
    (match Descriptor.readonly_static_hint descriptor with
     | Some true -> None
     | Some false | None ->
       if descriptor.Descriptor.policy.Descriptor.leaves_masc
       then Some (node, "this call reaches outside masc")
       else None)

(* What an undescribed name is, decided once.

   Two callers need this and they must not answer differently. [verdict_for]
   asks what to do about a call; the bundle gate asks whether this build can
   place the name at all. Splitting that into two predicates is how one grows
   an arm the other does not have, and the gate then passes while the tool
   still asks with a reason nobody can act on. *)
(* The control tools run unasked. Run validates and stores a Keeper-bound
   plan, then executes it, and each leaf keeps its own permissions; status reads a
   composition request this keeper made; cancel ends one inside masc; the
   skill tool reads an instruction Skill this keeper already carries. The
   attached-tool search names the attached tools this keeper already holds
   and makes one of them callable; it reaches no service, and the call to the
   attached tool itself is what the Gate still decides. *)
and undescribed_kind ~identity_tool_index ?composition_plan_index tool_name =
  if String.equal tool_name Keeper_tool_composition_catalog.run_tool_name
     || String.equal tool_name Keeper_tool_composition_catalog.status_tool_name
     || String.equal tool_name Keeper_tool_composition_catalog.cancel_tool_name
     || String.equal tool_name Keeper_tool_composition_catalog.skill_tool_name
     || String.equal tool_name Keeper_identity_tool_search.tool_name
  then Control
  else
    match
      Option.bind composition_plan_index (fun index ->
        Keeper_tool_composition_plan_index.node_tools index ~composition:tool_name)
    with
    | Some node_tools -> Composition node_tools
    | None ->
      if Keeper_identity_tool_index.mem identity_tool_index ~tool_name
      then Attached_service
      else Unknown

and verdict_of_nodes ~composition_plan_index node_tools =
  match List.find_map (node_asks_for_approval ~composition_plan_index) node_tools with
  | Some (node, because) ->
    Ask { because = Printf.sprintf "node %s: %s" node because }
  | None -> Run

and verdict_for_undescribed ~identity_tool_index ~composition_plan_index ~tool_name ~input =
  match undescribed_kind ~identity_tool_index ?composition_plan_index tool_name with
  | Control -> Run
  (* The stream policy delegates every attached tool to the durable Gate,
     and unapproved calls defer to the approvals queue. Provider annotations
     do not independently authorize an external call. *)
  | Attached_service -> Run
  | Composition node_tools -> verdict_of_nodes ~composition_plan_index node_tools
  | Unknown ->
    (* Not a safe tool -- one this build cannot classify. Running it unasked
       would make "no descriptor" the quietest way past the gate. *)
    Ask { because = unclassifiable_because }
;;

let classifies ~identity_tool_index ~composition_plan_index ~tool_name =
  match descriptor_for ?composition_plan_index tool_name with
  | Some _ -> true
  | None ->
    (match undescribed_kind ~identity_tool_index ?composition_plan_index tool_name with
     | Control | Composition _ | Attached_service -> true
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
