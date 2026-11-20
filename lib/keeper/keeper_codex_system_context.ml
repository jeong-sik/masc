module Assembly = Keeper_context_assembly
module Store = Keeper_official_client_session_store

type t = {
  full_receipt : Store.held_context;
  developer_context : string list;
  observations_in_developer : Assembly.system_observation list;
  persistent_context : Store.held_context list;
  replaced_context : Store.carried_context list;
}

let receipt context text : Store.held_context =
  {context; sha256 = Agent_core_sha256.(digest_string text |> to_hex)}

let standing_blocks =
  Keeper_official_client_context_projection.standing_system_blocks

let supported_observation =
  Keeper_official_client_context_projection.supported_standing_system_observation

let join pieces =
  List.filter (fun text -> String.trim text <> "") pieces
  |> String.concat "\n\n" |> String.trim

let replacement_notice =
  Keeper_official_client_context_projection.standing_system_replacement_notice

let prepare ~full_system ~system_prompt ~posture_notes ~assembly ~previously_held =
  let full_receipt = receipt Store.Codex_system_prompt full_system in
  let base_context = Store.Context_block Prompt_block_id.Keeper_instructions in
  let partition = Option.bind assembly (fun assembly ->
    match assembly.Assembly.system_prompt with
    | Some issued when String.equal issued.text system_prompt
        && List.for_all supported_observation issued.observations -> Some issued
    | Some _ | None -> None) in
  match partition with
  | None ->
    let refresh = match previously_held with
      | None -> false
      | Some held -> not (List.mem full_receipt held) in
    { full_receipt; developer_context = if refresh then [full_system] else []
    ; observations_in_developer = []
    ; persistent_context = [full_receipt]
    ; replaced_context = [Store.Codex_system_prompt; base_context] }
  | Some issued ->
    let base_receipt = receipt base_context (join (issued.base_text :: posture_notes)) in
    let observation_receipts = List.map (fun observation ->
      let block, text = Assembly.observation_block observation in
      receipt (Store.Context_block block) text) issued.observations in
    let replaced_context = Store.Codex_system_prompt :: base_context
      :: List.map (fun block -> Store.Context_block block) standing_blocks in
    let persistent_context = full_receipt :: base_receipt :: observation_receipts in
    let developer_context = match previously_held with
      | None -> []
      | Some held when not (List.mem base_receipt held) ->
        [join [replacement_notice; full_system]]
      | Some held ->
        let held_observations = List.filter (fun (held : Store.held_context) ->
          List.exists (fun block -> held.context = Store.Context_block block) standing_blocks) held in
        if List.length held_observations = List.length observation_receipts
           && List.for_all (fun current -> List.mem current held_observations) observation_receipts
        then []
        else
          [join (replacement_notice :: List.map (fun observation ->
             snd (Assembly.observation_block observation)) issued.observations @ posture_notes)]
    in
    { full_receipt; developer_context
    ; observations_in_developer =
        (match developer_context with [] -> [] | _ :: _ -> issued.observations)
    ; persistent_context; replaced_context }

let with_carried_context plan carried =
  plan.persistent_context @ List.filter (fun (held : Store.held_context) ->
    not (List.mem held.context plan.replaced_context)) carried
