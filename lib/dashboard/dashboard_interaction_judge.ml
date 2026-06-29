let keeper_name = "interaction-judge"
let production_enabled = false
let disabled_reason = "interaction judge requires Fusion job lifecycle before production"
let disabled_next_action = "migrate_to_fusion_job_lifecycle"

type interaction = {
  source : string;
  target : string;
  strength : float;
  reasoning : string;
} [@@deriving yojson]

type judge_response = {
  stigmergy : (string * float) list;
  interactions : interaction list;
}

type lifecycle_status =
  | Disabled

type lifecycle_next_action =
  | Migrate_to_fusion_job_lifecycle

type lifecycle_event = {
  task_id : string option;
  keeper_id : string;
  lane_id : string;
  caller : string;
  elapsed_s : float option;
  deadline_s : float option;
  last_checkpoint : string option;
  next_action : lifecycle_next_action;
  reason : string option;
}

let lifecycle_status_to_string = function
  | Disabled -> "disabled"

let lifecycle_next_action_to_string = function
  | Migrate_to_fusion_job_lifecycle -> disabled_next_action

let option_to_yojson f = function
  | Some value -> f value
  | None -> `Null

let lifecycle_event_to_yojson event =
  `Assoc [
    ("task_id", option_to_yojson (fun s -> `String s) event.task_id);
    ("keeper_id", `String event.keeper_id);
    ("lane_id", `String event.lane_id);
    ("caller", `String event.caller);
    ("elapsed_s", option_to_yojson (fun f -> `Float f) event.elapsed_s);
    ("deadline_s", option_to_yojson (fun f -> `Float f) event.deadline_s);
    ("last_checkpoint", option_to_yojson (fun s -> `String s) event.last_checkpoint);
    ("next_action", `String (lifecycle_next_action_to_string event.next_action));
    ("reason", option_to_yojson (fun s -> `String s) event.reason);
  ]

let empty_interactions_json =
  `Assoc [("stigmergy", `Assoc []); ("interactions", `List [])]

let disabled_event =
  {
    task_id = None;
    keeper_id = keeper_name;
    lane_id = keeper_name;
    caller = "interaction_judge";
    elapsed_s = None;
    deadline_s = None;
    last_checkpoint = None;
    next_action = Migrate_to_fusion_job_lifecycle;
    reason = Some disabled_reason;
  }

let ( let* ) = Result.bind

let parse_float_field field = function
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error (field ^ " must be a number")

let fold_result f init values =
  List.fold_left
    (fun acc value ->
      match acc with
      | Error _ as err -> err
      | Ok acc -> f acc value)
    (Ok init)
    values

let parse_stigmergy = function
  | `Assoc entries ->
      fold_result
        (fun acc (key, value_json) ->
          let* value = parse_float_field ("stigmergy." ^ key) value_json in
          Ok ((key, value) :: acc))
        []
        entries
      |> Result.map List.rev
  | _ -> Error "stigmergy must be an object"

let parse_interactions = function
  | `List entries ->
      entries
      |> List.mapi (fun index json -> index, json)
      |> fold_result
           (fun acc (index, json) ->
             match interaction_of_yojson json with
             | Ok interaction -> Ok (interaction :: acc)
             | Error msg ->
                 Error (Printf.sprintf "interactions[%d]: %s" index msg))
           []
      |> Result.map List.rev
  | _ -> Error "interactions must be a list"

let parse_judge_response (json : Yojson.Safe.t) : (judge_response, string) result =
  match json with
  | `Assoc fields ->
      let lookup field =
        match List.assoc_opt field fields with
        | Some value -> Ok value
        | None -> Error (field ^ " is required")
      in
      let* stigmergy_json = lookup "stigmergy" in
      let* interactions_json = lookup "interactions" in
      let* stigmergy = parse_stigmergy stigmergy_json in
      let* interactions = parse_interactions interactions_json in
      Ok { stigmergy; interactions }
  | _ -> Error "judge response must be an object"

type runtime_snapshot = {
  enabled : bool;
  judge_online : bool;
  refreshing : bool;
  status : lifecycle_status;
  generated_at : string option;
  expires_at : string option;
  model_used : string option;
  keeper_name : string;
  last_error : string option;
  next_action : lifecycle_next_action option;
  last_event : lifecycle_event option;
}

type state = {
  mu : Eio.Mutex.t;
  mutable started : bool;
  mutable snapshot : runtime_snapshot;
  mutable last_json : Yojson.Safe.t;
}

let states : (string, state) Hashtbl.t = Hashtbl.create 4
let outer_mu = Eio.Mutex.create ()

let get_state base_path =
  Eio_guard.with_mutex outer_mu (fun () ->
      match Hashtbl.find_opt states base_path with
      | Some s -> s
      | None ->
          let s =
            {
              mu = Eio.Mutex.create ();
              started = false;
              snapshot = {
                enabled = production_enabled;
                judge_online = false;
                refreshing = false;
                status = Disabled;
                generated_at = None;
                expires_at = None;
                model_used = None;
                keeper_name;
                last_error = Some disabled_reason;
                next_action = Some Migrate_to_fusion_job_lifecycle;
                last_event = Some disabled_event;
              };
              last_json = empty_interactions_json;
            }
          in
          Hashtbl.replace states base_path s;
          s)

let runtime_status base_path =
  let st = get_state base_path in
  Eio_guard.with_mutex st.mu (fun () -> st.snapshot)

let fresh_interactions_json ~base_path =
  let st = get_state base_path in
  Eio_guard.with_mutex st.mu (fun () ->
    `Assoc [
      ("enabled", `Bool st.snapshot.enabled);
      ("judge_online", `Bool st.snapshot.judge_online);
      ("refreshing", `Bool st.snapshot.refreshing);
      ("status", `String (lifecycle_status_to_string st.snapshot.status));
      ("next_action",
       match st.snapshot.next_action with
       | Some action -> `String (lifecycle_next_action_to_string action)
       | None -> `Null);
      ("last_error", match st.snapshot.last_error with Some e -> `String e | None -> `Null);
      ("lifecycle_event",
       match st.snapshot.last_event with
       | Some event -> lifecycle_event_to_yojson event
       | None -> `Null);
      ("data", st.last_json)
    ]
  )

let mark_disabled st =
  Eio_guard.with_mutex st.mu (fun () ->
    st.started <- false;
    st.snapshot <-
      {
        st.snapshot with
        enabled = false;
        judge_online = false;
        refreshing = false;
        status = Disabled;
        last_error = Some disabled_reason;
        next_action = Some Migrate_to_fusion_job_lifecycle;
        last_event = Some disabled_event;
      };
    st.last_json <- empty_interactions_json)

let start ~sw:_ ~clock:_ ~base_path ~build_facts:_ =
  let st = get_state base_path in
  mark_disabled st
