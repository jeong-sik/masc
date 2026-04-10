(** Event-parsing helpers for operator digest.

    Pure functions that extract fields from team-session event JSON
    and compute per-actor turn statistics.  Extracted from
    operator_digest_types to keep that module focused on types and
    serializers. *)

module U = Yojson.Safe.Util

let event_ts_iso json =
  match U.member "ts_iso" json with `String value -> Some value | _ -> None

let event_ts_unix json =
  match U.member "ts" json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit raw -> float_of_string_opt raw
  | _ -> (
      match event_ts_iso json with
      | Some iso -> Resilience.Time.parse_iso8601_opt iso
      | None -> None)

let event_type json =
  match U.member "event_type" json with `String value -> Some value | _ -> None

let event_detail_actor json =
  match U.member "detail" json |> U.member "actor" with
  | `String actor ->
      let trimmed = String.trim actor in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let event_detail_kind json =
  match U.member "detail" json |> U.member "kind" with
  | `String kind ->
      let trimmed = String.trim kind in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let event_detail_message json =
  match U.member "detail" json |> U.member "message" with
  | `String message ->
      let trimmed = String.trim message in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let count_spawn_failures events =
  List.fold_left
    (fun acc json ->
      match (event_type json, U.member "detail" json |> U.member "success") with
      | Some "team_step_spawn", `Bool false -> acc + 1
      | _ -> acc)
    0 events

let count_detached_actors events =
  List.fold_left
    (fun acc json ->
      match event_type json with
      | Some "session_agent_detached" -> acc + 1
      | _ -> acc)
    0 events

let empty_note_turn_actors events =
  events
  |> List.filter_map (fun json ->
         match (event_type json, event_detail_kind json, event_detail_actor json) with
         | Some "team_turn", Some "note", Some actor -> (
             match event_detail_message json with None -> Some actor | Some _ -> None)
         | _ -> None)
  |> Worker_contract_types.dedup_strings

let turn_count_by_actor events actor_name =
  List.fold_left
    (fun acc json ->
      match (event_type json, event_detail_actor json) with
      | Some "team_turn", Some actor when String.equal actor actor_name -> acc + 1
      | _ -> acc)
    0 events

let empty_note_turn_count_for_actor events actor_name =
  List.fold_left
    (fun acc json ->
      match (event_type json, event_detail_kind json, event_detail_actor json) with
      | Some "team_turn", Some "note", Some actor when String.equal actor actor_name -> (
          match event_detail_message json with None -> acc + 1 | Some _ -> acc)
      | _ -> acc)
    0 events

let last_turn_ts_iso_for_actor events actor_name =
  events
  |> List.filter_map (fun json ->
         match (event_type json, event_detail_actor json) with
         | Some "team_turn", Some actor when String.equal actor actor_name ->
             event_ts_iso json
         | _ -> None)
  |> List.rev |> function value :: _ -> Some value | [] -> None

let last_turn_age_sec_for_actor events actor_name ~now =
  events
  |> List.filter_map (fun json ->
         match (event_type json, event_detail_actor json) with
         | Some "team_turn", Some actor when String.equal actor actor_name ->
             event_ts_unix json
         | _ -> None)
  |> List.rev
  |> function
  | ts :: _ -> Some (max 0 (int_of_float (now -. ts)))
  | [] -> None
