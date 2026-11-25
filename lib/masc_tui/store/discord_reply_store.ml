open Masc_tui_core
open Masc_tui_protocol

module Reply = Wire_discord_reply

type phase =
  | Awaiting of { request : Reply.request; first_send : bool }
  | Observed of Reply.state
  | Unobserved of Say.t
  | Rejected of Say.t
  | Absent of { can_retry : bool }

type attempt = {
  target : Reply.target;
  operation_id : string;
  retry_content : string option;
  workspace : Wire_work.expected_workspace;
  phase : phase;
}

type t = { epoch : Epoch.t; attempts : attempt list }

let empty = { epoch = Epoch.initial; attempts = [] }

let current_attempts epoch t =
  if Epoch.is_current ~current:epoch ~reply:t.epoch then t.attempts
  else
    (* The server receipt outlives a connection. A renewed connection can
       check it, but a missing receipt cannot establish the same operator
       identity, so the old payload is no longer eligible for replay. *)
    List.map
      (fun a ->
        let phase =
          match a.phase with
          | Awaiting _ ->
              Unobserved
                (Say.make ~ko:"서버 연결이 바뀌었습니다" ~en:"Server connection changed")
          | Absent _ -> Absent { can_retry = false }
          | Observed _ | Unobserved _ | Rejected _ as phase -> phase
        in
        { a with phase; retry_content = None })
      t.attempts

let find ~epoch ~workspace target t =
  List.find_opt
    (fun a -> a.workspace = workspace && Reply.equal_target a.target target)
    (current_attempts epoch t)

let set ~epoch attempt t =
  let others =
    current_attempts epoch t
    |> List.filter (fun a ->
           a.workspace <> attempt.workspace
           || not (Reply.equal_target a.target attempt.target))
  in
  { epoch; attempts = attempt :: others }

let next_request ~target ~content = function
  | Some { phase = Awaiting _; _ } -> None
  | Some { phase = Unobserved _ | Observed (Reply.Sending | Reply.Outcome_unknown); operation_id; _ } ->
      Some (Reply.Status { target; operation_id })
  | Some { phase = Absent _; operation_id; retry_content; _ } ->
      (match retry_content with
       | Some content -> Some (Reply.Send { target; operation_id; content })
       | None -> Some (Reply.Status { target; operation_id }))
  | None | Some { phase = Observed (Reply.Delivered _ | Reply.Refused _) | Rejected _; _ } ->
      if String.equal (String.trim content) "" then None
      else Some (Reply.Send { target; operation_id = Random_id.uuid_v7 (); content })

let submit ~epoch ~workspace request t =
  let target, operation_id = Reply.identity request in
  match request with
  | Reply.Send { content; _ } ->
      let first_send =
        match find ~epoch ~workspace target t with
        | Some a -> not (String.equal a.operation_id operation_id)
        | None -> true
      in
      set ~epoch
        { target; operation_id; retry_content = Some content; workspace;
          phase = Awaiting { request; first_send } } t
  | Reply.Status _ ->
      (match find ~epoch ~workspace target t with
       | Some a when String.equal a.operation_id operation_id ->
           set ~epoch { a with phase = Awaiting { request; first_send = false } } t
       | Some _ | None -> t)

let observe ~epoch ~workspace request result t =
  let target, operation_id = Reply.identity request in
  match find ~epoch ~workspace target t with
  | Some ({ phase = Awaiting { request = pending; first_send }; _ } as a)
    when String.equal a.operation_id operation_id && pending = request ->
      let phase, retry_content =
        match result with
        | Ok state -> Observed state, None
        | Error `Absent -> Absent { can_retry = Option.is_some a.retry_content }, a.retry_content
        | Error (`Unobserved reason) -> Unobserved reason, a.retry_content
        | Error (`Rejected reason) ->
            if first_send then Rejected reason, a.retry_content
            else Unobserved reason, None
      in
      Some (set ~epoch { a with phase; retry_content } t)
  | Some
      { phase = Awaiting _ | Observed _ | Unobserved _ | Rejected _ | Absent _; _ }
  | None -> None

let status = function
  | Awaiting { request = Reply.Send _; _ } ->
      `Pending, Say.make ~ko:"Discord에 답장을 요청하는 중" ~en:"Submitting Discord reply"
  | Awaiting { request = Reply.Status _; _ } ->
      `Pending, Say.make ~ko:"전송 결과를 조회하는 중" ~en:"Checking Discord delivery"
  | Observed Reply.Sending ->
      `Pending, Say.make ~ko:"Discord에 전송 중 · Enter로 결과 조회" ~en:"Sending to Discord · Enter checks delivery"
  | Observed (Reply.Delivered id) ->
      `Delivered, Say.make ~ko:("Discord 전송 완료 · " ^ id) ~en:("Delivered to Discord · " ^ id)
  | Observed (Reply.Refused reason) ->
      let message =
        match reason with
        | Reply.Binding_changed ->
            Say.make ~ko:"Keeper의 Discord 연결이 바뀌어 전송하지 못했습니다" ~en:"Keeper’s Discord binding changed"
        | Reply.Discord_unconfigured ->
            Say.make ~ko:"Discord 연결을 사용할 수 없습니다" ~en:"Discord connection is unavailable"
        | Reply.Discord_rejected ->
            Say.make ~ko:"Discord가 답장을 거절했습니다" ~en:"Discord rejected the reply"
      in
      `Failed, message
  | Observed Reply.Outcome_unknown ->
      `Failed, Say.make ~ko:"Discord 전송 여부 불명 · Enter로 다시 조회" ~en:"Discord delivery unknown · Enter checks again"
  | Rejected reason -> `Failed, reason
  | Unobserved reason ->
      `Failed,
      Say.make
        ~ko:("Enter로 결과 조회 · " ^ Say.resolve Say.Lang_ko reason)
        ~en:("Enter checks delivery · " ^ Say.resolve Say.Lang_en reason)
  | Absent { can_retry = true } ->
      `Failed, Say.make ~ko:"영수증 없음 · Enter로 같은 작업 재시도" ~en:"No receipt found · Enter retries the same operation"
  | Absent { can_retry = false } ->
      `Failed, Say.make ~ko:"영수증 없음 · Enter로 다시 조회" ~en:"No receipt found · Enter checks again"

let target_of_form (kind : Nav.inline_action_kind) =
  match kind with
  | Nav.Discord_reply_form
      { keeper; chat_id; guild_id; channel_id; message_id;
        workspace_base_path; workspace_masc_root } ->
      let target : Reply.target =
        { keeper; chat_id;
          origin = { guild_id; channel_id; original_message_id = message_id } }
      in
      let workspace : Wire_work.expected_workspace =
        { base_path = workspace_base_path; masc_root = workspace_masc_root }
      in
      Some (target, workspace)
  | Nav.Btw_query
  | Nav.Gate_reject _
  | Nav.Verification_reject _
  | Nav.Harness_overrule _
  | Nav.Task_cancel _
  | Nav.Goal_drop _
  | Nav.Schedule_form
  | Nav.Connector_form
  | Nav.Repo_add_form
  | Nav.Board_new_post
  | Nav.Board_goal_proposal
  | Nav.Goal_confirmation_proof
  | Nav.Memory_act_form
  | Nav.Wiki_edit_form
  | Nav.Fusion_launch_form
  | Nav.Runtime_assign_form
  | Nav.Setup_account_key_form
  | Nav.Setup_login_start_form
  | Nav.Board_comment _
  | Nav.Github_token_form _
  | Nav.Code_finder_form
  | Nav.Code_search_form
  | Nav.Runtime_lane_create
  | Nav.Runtime_lane_edit _
  | Nav.Runtime_lane_delete _
  | Nav.Task_create_form
  | Nav.Task_transition_form _
  | Nav.Task_link_goal _
  | Nav.Goal_upsert_form _
  | Nav.Board_delete_post _
  | Nav.Keeper_lifecycle_form _
  | Nav.Keeper_purge_confirm _
  | Nav.Addon_attach_form
  | Nav.Addon_detach_confirm _
  | Nav.Addon_invoke_action _
  | Nav.Setup_login_input_form _
  | Nav.Keeper_control_confirm _
  | Nav.Keeper_clear_form _
  | Nav.Keeper_operator_note_form _
  | Nav.Tool_execute_form _
  | Nav.Skill_create_form
  | Nav.Skill_edit_form _
  | Nav.Skill_delete_confirm _
  | Nav.Prompt_override_form _
  | Nav.Preset_create_form
  | Nav.Runtime_param_set_form _
  | Nav.Default_route_edit
  | Nav.Lane_rename_form _
  | Nav.Addon_decl_form _
  | Nav.Addon_act_form _
  | Nav.Browser_interact_form _ ->
      None

let phase a = a.phase

let can_compose = function
  | None | Some { phase = Observed (Reply.Delivered _ | Reply.Refused _) | Rejected _; _ } -> true
  | Some { phase = Awaiting _ | Observed (Reply.Sending | Reply.Outcome_unknown)
                  | Unobserved _ | Absent _; _ } -> false

let rejected_content = function
  | Some { phase = Rejected _; retry_content; _ } -> retry_content
  | None
  | Some { phase = Awaiting _ | Observed _ | Unobserved _ | Absent _; _ } -> None
