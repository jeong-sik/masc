type request =
  { scope : Connector_memory_scope.t
  ; query : string
  }

let ( let* ) = Result.bind
let ( let*? ) = Option.bind

let route_scope = function
  | Keeper_continuation_channel.Discord { guild_id; channel_id; thread_id; user_id; _ } ->
    let*? account = Connector_account_ref.discord_user user_id in
    Connector_memory_scope.of_surface ~account
      (Discord { guild_id; channel_id; thread_id; channel_name = None; parent_channel_id = None })
  | Dashboard _ | Slack _ | Telegram _ | Imessage _ | Gate _ | Keeper _ | Unrouted _ -> None
;;

let connector_source (stimulus : Keeper_event_queue.stimulus) =
  match stimulus.payload with
  | Connector_attention { event_id; channel } -> Some (event_id, channel)
  | Bootstrap | Schedule_due _ | Board_routing_pending _ | Board_signal _
  | Board_attention _ | Fusion_completed _ | Ask_answered _ | Hitl_resolved _
  | Completion_authority_rejected _ | Task_cancelled _ | Workspace_message _
  | Delegate_completed _ | Composition_completed _ | Tool_result_ready _
  | Owned_job_completed _ | Task_outcome _ -> None
;;

let original_id = function
  | Keeper_continuation_channel.Discord { reply_to_message_id; _ } -> reply_to_message_id
  | Dashboard _ | Slack _ | Telegram _ | Imessage _ | Gate _ | Keeper _ | Unrouted _ -> None
;;

let select ~keeper_id ~route ~stimuli ~recorded =
  let*? scope = route_scope route in
  let*? routed = List.nth_opt (List.rev stimuli) 0 in
  let*? _, routed_channel = connector_source routed in
  let rec queries acc = function
    | [] ->
      let query = String.concat " " (List.rev acc) |> String.trim in
      if String.equal query "" then None else Some { scope; query }
    | stimulus :: rest ->
      let*? event_id, channel = connector_source stimulus in
      let*? item = List.assoc_opt event_id recorded in
      let*? proof = Keeper_external_attention.original_message_scope item in
      let*? message = item.external_message in
      if proof = scope
         && route_scope channel = Some scope
         && original_id channel = Some message.message_id
         && String.equal item.event_id event_id
         && String.equal item.keeper_name keeper_id
      then queries (item.content_preview :: acc) rest
      else None
  in
  if Keeper_continuation_channel.same_route route routed_channel
  then queries [] stimuli
  else None
;;

let max_prompt_bytes = 4096

let render ~keepers_dir ~keeper_id { scope; query } =
  let* facts = Keeper_memory_os_current.read_personal_facts ~keepers_dir ~keeper_id ~scope in
  match facts with
  | [] -> Ok None
  | _ :: _ ->
    let claims = List.map (fun (fact : Keeper_memory_os_types.fact) -> fact.claim) facts in
    let* ranks =
      Keeper_memory_search_index.rank ~query claims
      |> Result.map_error Keeper_memory_search_index.error_to_string
    in
    let claims = Array.of_list claims in
    let heading =
      "\nPersonal memory for this Discord sender and conversation. Use these claims only to tailor the reply for this sender.\n"
    in
    let left = max_prompt_bytes - String.length heading in
    let _, accepted =
      List.fold_left (fun (left, accepted) (index, _) ->
        let line = Yojson.Safe.to_string (`String claims.(index)) ^ "\n" in
        let bytes = String.length line in
        if bytes <= left then left - bytes, line :: accepted else left, accepted)
        (left, []) ranks
    in
    if List.is_empty accepted then Ok None
    else Ok (Some (heading ^ String.concat "" (List.rev accepted)))
;;

let for_turn ~base_path ~keeper_id ~batch ~route =
  let stimuli = Keeper_heartbeat_source_batch.stimuli batch in
  let recorded = Keeper_heartbeat_source_batch.connector_items batch in
  match select ~keeper_id ~route ~stimuli ~recorded with
  | None -> Ok None
  | Some request ->
    let* _, withdrawn =
      Keeper_heartbeat_source_batch.validate ~diagnostic:None ~standing:(fun selection ->
        Keeper_registry_event_queue.admitted_selection_standing_result
          ~base_path keeper_id ~selection) batch
    in
    if not (List.is_empty withdrawn) then Ok None
    else
      let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
      render ~keepers_dir ~keeper_id request
;;
