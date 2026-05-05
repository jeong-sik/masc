type status = {
  cluster : string;
  project : string;
  tempo_interval_s : float;
  paused : bool;
}

let status config =
  let room_state = Coord.read_state config in
  let tempo = Tempo.get_tempo config in
  {
    cluster = Env_config_core.cluster_name ();
    project = room_state.project;
    tempo_interval_s = tempo.current_interval_s;
    paused = room_state.paused;
  }

let task_status_matches status_filter (task : Masc_domain.task) =
  match status_filter with
  | None -> true
  | Some status ->
      String.equal status (Masc_domain.string_of_task_status task.task_status)

let tasks ?status_filter ?(include_done = false) ?(include_cancelled = false)
    config =
  Coord.get_tasks_raw config
  |> List.filter (task_status_matches status_filter)
  |> List.filter (fun (task : Masc_domain.task) ->
         match status_filter with
         | Some _ -> true
         | None ->
             let s = task.task_status in
             if Masc_domain.task_status_is_done s then include_done
             else if Masc_domain.task_status_is_terminal s then include_cancelled
             else true)

let task_assignee (task : Masc_domain.task) =
  Masc_domain.task_assignee_of_status task.task_status

let agents ?status_filter config =
  let agents =
    try Coord.get_agents_raw config
    with Invalid_argument _ -> []
  in
  match status_filter with
  | None -> agents
  | Some status ->
      List.filter
        (fun (agent : Masc_domain.agent) ->
          String.equal status (Masc_domain.string_of_agent_status agent.status))
        agents

let messages ?agent_filter ~since_seq ~limit config =
  let messages = Coord.get_messages_raw config ~since_seq ~limit in
  match agent_filter with
  | None -> messages
  | Some agent ->
      List.filter
        (fun (message : Masc_domain.message) ->
          String.equal agent message.from_agent)
        messages
