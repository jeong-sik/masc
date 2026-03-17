(** Dashboard HTTP shell status and entity JSON builders. *)

open Types
open Server_utils [@@warning "-33"]
open Dashboard_execution_helpers

let dashboard_shell_status_json (config : Room.config) : Yojson.Safe.t =
  let room_state = Room.read_state config in
  let current_room =
    Room.read_current_room config |> Option.value ~default:"default"
  in
  let tempo = Tempo.get_tempo config in
  let lodge_json = Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  let social_runtime_json = Social_runtime.status_json ~config in
  let gardener_json = Gardener.status_json () in
  let guardian_json = Guardian.status_json () in
  let sentinel_json = Sentinel.status_json () in
  let build = Build_identity.current () in
  `Assoc
    [
      ("room", `String current_room);
      ("current_room", `String current_room);
      ("room_base_path", `String config.base_path);
      ( "cluster",
        `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME"))
      );
      ("project", `String room_state.project);
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool room_state.paused);
      ("lodge", lodge_json);
      ("social_runtime", social_runtime_json);
      ("gardener", gardener_json);
      ("guardian", guardian_json);
      ("sentinel", sentinel_json);
      ("version", `String build.release_version);
      ("build", Build_identity.to_yojson build);
    ]

let dashboard_task_assignee (task : Types.task) =
  match task.task_status with
  | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } ->
      Some assignee
  | Todo | Cancelled _ -> None

let dashboard_task_json (task : Types.task) =
  `Assoc
    [
      ("id", `String task.id);
      ("title", `String task.title);
      ("description", `String task.description);
      ("status", `String (Types.string_of_task_status task.task_status));
      ("priority", `Int task.priority);
      ("assignee", match dashboard_task_assignee task with Some v -> `String v | None -> `Null);
      ("created_at", `String task.created_at);
    ]

let dashboard_agent_json (agent : Types.agent) =
  let (emoji, korean_name) = get_agent_identity agent.name in
  `Assoc
    [
      ("name", `String agent.name);
      ("agent_type", `String agent.agent_type);
      ("status", `String (Types.string_of_agent_status agent.status));
      ("current_task", match agent.current_task with Some task -> `String task | None -> `Null);
      ("joined_at", `String agent.joined_at);
      ("last_seen", `String agent.last_seen);
      ("capabilities", `List (List.map (fun item -> `String item) agent.capabilities));
      ("emoji", `String emoji);
      ("koreanName", `String korean_name);
    ]

let dashboard_message_json (message : Types.message) =
  `Assoc
    [
      ("from", `String message.from_agent);
      ("content", `String message.content);
      ("timestamp", `String message.timestamp);
      ("seq", `Int message.seq);
    ]

let dashboard_current_room_id config =
  Room.current_room_id config

let dashboard_tasks_safe config =
  Room.get_tasks_raw_in_room config (dashboard_current_room_id config)
