(** Keeper status team session bridge helpers. *)

open Keeper_types

let linked_team_session config (meta : keeper_meta) =
  match meta.active_team_session_id with
  | Some session_id -> Team_session_store.load_session config session_id
  | None -> None

let team_session_state_json config (meta : keeper_meta) =
  match linked_team_session config meta with
  | Some session ->
      `String (Team_session_types.status_to_string session.status)
  | None -> `Null

let team_session_bridge_json config (meta : keeper_meta) =
  let session = linked_team_session config meta in
  let session_exists = Option.is_some session in
  let session_state =
    match session with
    | Some current ->
        `String (Team_session_types.status_to_string current.status)
    | None -> `Null
  in
  `Assoc
    [
      ("enabled", `Bool meta.auto_team_session_enabled);
      ("active_session_id",
       match meta.active_team_session_id with
       | Some session_id -> `String session_id
       | None -> `Null);
      ("session_exists", `Bool session_exists);
      ("session_state", session_state);
      ("last_started_at",
       if String.trim meta.last_team_session_started_at = "" then `Null
       else `String meta.last_team_session_started_at);
      ("start_count_total", `Int meta.team_session_start_count_total);
    ]
