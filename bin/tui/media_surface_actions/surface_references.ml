module T = Masc_tui_types
module Tui_decode = Masc.Tui_decode
module Tui_decode_fusion = Masc.Tui_decode_fusion
module Op_const = Masc.Operator_action_constants
module Link = Masc_tui_link
module Approvals_model = Masc_tui_approvals_model
module Op_proj = Masc_tui_operator_projection
module Fusion_model = Masc_tui_fusion_model
module Overview_tasks = Masc_tui_overview_tasks
module Work_schedule = Masc_tui_work_actions.Board_schedule_actions

(* Where a reference lands, and what it opens when it gets there.

   The surfaces already print [masc://] references beside what they name and
   [Y] already copies the one under the cursor. Reading that same reference
   back is the other half: without it the screen knows where the answer is and
   the operator still walks over by hand.

   Tasks and Goals live under Work. A Task reference opens Work's Tasks detail. *)
let follow_target (kind : Link.kind) (id : string) =
  match kind with
  | Link.Task -> Some (T.Planning, Some id)
  | Link.Goal -> Some (T.Planning, Some id)
  | Link.Board_post -> Some (T.Board, Some id)
  | Link.Schedule -> Some (T.Schedules, Some id)
  | Link.Fusion_run -> Some (T.Fusion, Some id)
  | Link.Keeper -> Some (T.Keepers T.Keeper_list, Some id)

let approval_row_reference = function
  | Approvals_model.Keeper_tool_row ask -> Some (Link.reference Link.Keeper ask.Tui_decode.kta_keeper)
  | Approvals_model.Gate_row pending -> Some (Link.reference Link.Keeper pending.Tui_decode.gp_keeper)
  | Approvals_model.Operator_row item ->
      Option.bind item.Op_proj.ap_target_id (fun target_id ->
          match
            Op_const.target_type_of_string
              item.Op_proj.ap_target_type
          with
          | Some Op_const.Keeper ->
              Some (Link.reference Link.Keeper target_id)
          | Some Op_const.Goal -> Some (Link.reference Link.Goal target_id)
          | Some Op_const.Workspace | None -> None)

let selected_surface_reference (state : T.state) =
  let board () =
    match state.T.board_mode with
    | T.Board_read post_id -> Some (Link.reference Link.Board_post post_id)
    | T.Board_list ->
        Option.map
          (fun (post : T.board_post) -> Link.reference Link.Board_post post.T.bp_id)
          (List.nth_opt (T.board_posts state) state.T.board_cursor)
    | T.Board_compose -> None
  in
  let planning () =
    match state.T.planning_mode with
    | T.Planning_detail goal_id -> Some (Link.reference Link.Goal goal_id)
    | T.Planning_list when Overview_tasks.is_focused state.T.task_focus ->
        (match state.T.task_detail_id with
         | Some task_id -> Some (Link.reference Link.Task task_id)
         | None ->
             Option.map
               (fun (task : Tui_decode.task) -> Link.reference Link.Task task.Tui_decode.id)
               (Overview_tasks.work_selected_task state.T.tasks
                  ~selected:(Overview_tasks.selection state.T.task_focus)))
    | T.Planning_list ->
        Option.bind state.T.planning (fun (snapshot : Tui_decode.planning_snapshot) ->
            T.planning_visible_goals ~filter:state.T.planning_filter
              ~sort:state.T.planning_sort snapshot.Tui_decode.pl_goals
            |> Fun.flip List.nth_opt state.T.planning_cursor
            |> Option.map (fun (goal : Tui_decode.planning_goal) -> Link.reference Link.Goal goal.Tui_decode.pg_id))
  in
  match state.T.view with
  | T.Board -> board ()
  | T.Planning -> planning ()
  | T.Schedules ->
      (match Work_schedule.schedule_detail_on_screen state with
       | Some row -> Some (Link.reference Link.Schedule row.T.sch_schedule_id)
       | None ->
           Option.bind state.T.schedules (fun (snapshot : T.schedule_snapshot) ->
             Option.map (fun (row : T.schedule_row) -> Link.reference Link.Schedule row.T.sch_schedule_id)
               (List.nth_opt snapshot.T.scs_rows state.T.schedule_cursor)))
  | T.Harness ->
      (match state.T.harness_detail with
       | Some (task_id, _) -> Some (Link.reference Link.Task task_id)
       | None ->
           Option.bind state.T.harness (fun (snapshot : Tui_decode.harness_snapshot) ->
               Option.map
                 (fun (verdict : Tui_decode.harness_verdict) ->
                    Link.reference Link.Task verdict.Tui_decode.hv_task_id)
                 (List.nth_opt snapshot.Tui_decode.hs_verdicts
                    state.T.harness_cursor)))
  | T.Fusion ->
      (match state.T.fusion_mode, Fusion_model.fusion_snapshot state with
       | T.Fusion_historical_detail reference, _ ->
           Some (Link.reference Link.Board_post reference.Tui_decode_fusion.fhe_post_id)
       | T.Fusion_detail run_id, _ -> Some (Link.reference Link.Fusion_run run_id)
       | T.Fusion_list, Some _ ->
           Option.map
             (function
               | Tui_decode_fusion.Fusion_retained_run run -> Link.reference Link.Fusion_run run.Tui_decode_fusion.fur_run_id
               | Tui_decode_fusion.Fusion_historical_evidence evidence ->
                   Link.reference Link.Board_post evidence.Tui_decode_fusion.fhe_post_id)
             (Fusion_model.selected_fusion_entry state)
       | T.Fusion_list, None -> None)
  (* Dashboard has no row cursor. Task references belong to Work. *)
  | T.Overview -> None
  | T.Keepers _ ->
      Option.map
        (fun (keeper : Tui_decode.keeper) -> Link.reference Link.Keeper keeper.Tui_decode.k_name)
        (T.selected_keeper state)
  | T.Lanes -> None
  | T.Clients -> None
  | T.Verification ->
      (* The task, not the request: a verification request is a question about
         a task, and the task is the thing another surface can open. *)
      Option.bind state.T.verification (fun (snapshot : Tui_decode.verification_snapshot) ->
          Option.map
            (fun (request : Tui_decode.verification_request) ->
               Link.reference Link.Task request.Tui_decode.vr_task_id)
            (List.nth_opt snapshot.Tui_decode.vs_requests
               state.T.verification_cursor))
  | T.Approvals ->
      (* An ask names what it is asking about. A keeper's tool ask names the
         keeper; an operator ask carries a typed target, so the kind is read
         through [target_type_of_string] rather than matched as text. A
         Workspace target, or one this build does not know, points at no
         surface and gets no reference. *)
      Option.bind
        (List.nth_opt (Approvals_model.approval_items state) state.T.approval_cursor)
        approval_row_reference
  | T.Acting | T.Metrics
  | T.Memory | T.Repositories | T.Changes | T.Connectors | T.Runtime | T.Config | T.Resources | T.Tools
  | T.Code | T.System_logs -> None

let next_board_sort = function
  | T.Board_hot -> T.Board_trending
  | T.Board_trending -> T.Board_recent
  | T.Board_recent -> T.Board_updated
  | T.Board_updated -> T.Board_discussed
  | T.Board_discussed -> T.Board_hot

(* A filter or sort change can leave the cursor past the end of the new
   list; clamp it so the next j/k has somewhere to move from. *)
let clamp_planning_cursor (state : T.state) =
  let count =
    match state.T.planning with
    | None -> 0
    | Some planning ->
        List.length
          (T.planning_visible_goals ~filter:state.T.planning_filter
             ~sort:state.T.planning_sort planning.Tui_decode.pl_goals)
  in
  if state.T.planning_cursor >= count then
    state.T.planning_cursor <- max 0 (count - 1)
