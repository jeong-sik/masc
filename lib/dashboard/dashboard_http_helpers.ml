(** Dashboard HTTP helpers — shared env-parsing and JSON utility functions.

    Extracted from server_dashboard_http.ml for sub-module reuse. *)


let bool_of_env name =
  match Sys.getenv_opt name with
  | None -> false
  | Some v ->
      let v = v |> String.trim |> String.lowercase_ascii in
      v = "1" || v = "true" || v = "yes" || v = "y"

let bool_default_true_of_env name =
  match Sys.getenv_opt name with
  | None -> true
  | Some v ->
      let v = v |> String.trim |> String.lowercase_ascii in
      not (v = "0" || v = "false" || v = "no" || v = "n")

let int_of_env_default name ~default ~min_v ~max_v =
  let v =
    match Sys.getenv_opt name with
    | None -> default
    | Some s ->
        (Option.value ~default:default (int_of_string_opt (String.trim s)))
  in
  max min_v (min max_v v)

let float_of_env_default name ~default ~min_v ~max_v =
  let v =
    match Sys.getenv_opt name with
    | None -> default
    | Some s ->
        Option.value ~default (float_of_string_opt (String.trim s))
  in
  max min_v (min max_v v)

let dashboard_session_list_limit () = 20

let dashboard_session_list_timeout_s () = 5.0

let operator_snapshot_session_window_seconds () =
  float_of_env_default "MASC_OPERATOR_SNAPSHOT_SESSION_WINDOW_SECONDS"
    ~default:Masc_time_constants.day ~min_v:300.0 ~max_v:(Masc_time_constants.days_to_seconds 7)

let operator_snapshot_session_limit () =
  int_of_env_default "MASC_OPERATOR_SNAPSHOT_SESSION_LIMIT"
    ~default:20 ~min_v:5 ~max_v:200

let operator_snapshot_recent_completed_limit () =
  int_of_env_default "MASC_OPERATOR_SNAPSHOT_RECENT_COMPLETED_LIMIT"
    ~default:5 ~min_v:1 ~max_v:50

let operator_snapshot_status_event_limit () =
  int_of_env_default "MASC_OPERATOR_SNAPSHOT_STATUS_EVENT_LIMIT"
    ~default:200 ~min_v:20 ~max_v:2000

let bool_of_tag_value (raw : string) : bool =
  let v = String.trim raw |> String.lowercase_ascii in
  v = "1" || v = "true" || v = "yes" || v = "y" || v = "on"

let parse_tool_call_detail (detail_opt : string option)
  : string * bool * int option =
  match detail_opt with
  | None -> ("unknown", false, None)
  | Some raw ->
      let parts = String.split_on_char '|' raw |> List.map String.trim in
      let tool_name =
        match parts with
        | head :: _ when head <> "" -> head
        | _ -> "unknown"
      in
      let timeout = ref false in
      let duration_ms = ref None in
      let parse_kv token =
        match String.split_on_char '=' token with
        | [k; v] -> Some (String.trim k, String.trim v)
        | _ -> None
      in
      let tags =
        match parts with
        | _ :: tl -> tl
        | [] -> []
      in
      List.iter
        (fun token ->
          match parse_kv token with
          | Some ("timeout", v) ->
              timeout := bool_of_tag_value v
          | Some ("duration_ms", v) ->
              (match int_of_string_opt v with
               | Some n -> duration_ms := Some (max 0 n)
               | None ->
                 Log.Dashboard.warn "invalid duration_ms value: %s" v)
          | Some (_, _) | None -> ())
        tags;
      (tool_name, !timeout, !duration_ms)

let percentile_int (values : int list) ~(pct : float) : int option =
  match List.sort compare values with
  | [] -> None
  | sorted ->
      let n = List.length sorted in
      let idx =
        int_of_float (ceil (pct *. float_of_int n) -. 1.0)
        |> max 0
        |> min (n - 1)
      in
      List.nth_opt sorted idx

let json_int_opt = function
  | Some v -> `Int v
  | None -> `Null

let safe_age_seconds_opt ~(now_ts : float) ~(event_ts : float) : int option =
  let delta = now_ts -. event_ts in
  if Float.is_nan delta || Float.is_infinite delta then None
  else
    let bounded = max 0.0 (min delta (float_of_int max_int)) in
    Some (int_of_float bounded)

let safe_member key json =
  match json with
  | `Assoc _ -> Yojson.Safe.Util.member key json
  | _ -> `Null

let json_list_field key json =
  match safe_member key json with
  | `List items -> items
  | _ -> []

let json_int_field key json ~default =
  match safe_member key json with
  | `Int value -> value
  | `Intlit raw -> (Option.value ~default:default (int_of_string_opt raw))
  | _ -> default

let json_string_field_opt key json =
  match safe_member key json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let json_assoc_field key json =
  match safe_member key json with
  | `Assoc _ as value -> value
  | _ -> `Assoc []

let json_record_field key json =
  match safe_member key json with
  | `Assoc _ as value -> Some value
  | _ -> None

let count_where items predicate =
  List.fold_left
    (fun acc item -> if predicate item then acc + 1 else acc)
    0 items
