(* Canonical Goal documents; source classification and publication stay in the store. *)

open Result.Syntax

let clamp_priority p =
  max 1 (min 5 p)

type goal = {
  id : string;
  criterion_revision : string;
  title : string;
  metric : string option;
  target_value : string option;
  due_date : string option;
  priority : int;
  phase : Goal_phase.t;
  last_review_note : string option;
  last_review_at : string option;
  created_at : string;
  updated_at : string;
}

type criterion = Criterion of {
  revision : string;
  title : string;
  metric : string option;
  target_value : string option;
}

let criterion_of_goal (goal : goal) =
  Criterion { revision = goal.criterion_revision; title = goal.title;
              metric = goal.metric; target_value = goal.target_value }

let criterion_equal (Criterion left) (Criterion right) =
  String.equal left.revision right.revision
  && String.equal left.title right.title
  && Option.equal String.equal left.metric right.metric
  && Option.equal String.equal left.target_value right.target_value

let criterion_to_yojson (Criterion c) =
  `Assoc [ "revision", `String c.revision; "title", `String c.title;
           "metric", Json_util.string_opt_to_json c.metric;
           "target_value", Json_util.string_opt_to_json c.target_value ]

let criterion_of_yojson = function
  | `Assoc fields as json ->
      let expected = [ "revision"; "title"; "metric"; "target_value" ] in
      if List.length fields <> List.length expected
         || List.sort String.compare (List.map fst fields)
            <> List.sort String.compare expected then
        Error "criterion: expected exactly revision, title, metric and target_value"
      else
        let optional_string name =
          match Json_util.assoc_member_opt name json with
          | Some `Null -> Ok None
          | Some (`String value) -> Ok (Some value)
          | _ -> Error ("criterion: invalid " ^ name)
        in
        (match Json_util.assoc_member_opt "revision" json,
               Json_util.assoc_member_opt "title" json with
         | Some (`String revision), Some (`String title)
           when String.trim revision <> "" ->
             let* metric = optional_string "metric" in
             let* target_value = optional_string "target_value" in
             Ok (Criterion { revision; title; metric; target_value })
         | _ -> Error "criterion: revision and title must be strings; revision must not be blank")
  | _ -> Error "criterion: expected object"

type event_kind = Created | Updated | Phase | Edited

type pending_event = {
  event_id : string;
  goal_id : string;
  store_revision : int;
  recorded_at : string;
  kind : event_kind;
  payload : Yojson.Safe.t;
}

let event_kind_to_string = function
  | Created -> "goal_created" | Updated -> "goal_updated"
  | Phase -> "goal_phase" | Edited -> "goal_edited"

let pending_event_to_yojson event =
  `Assoc [ "event_id", `String event.event_id;
           "goal_id", `String event.goal_id;
           "store_revision", `Int event.store_revision;
           "ts", `String event.recorded_at;
           "event_type", `String (event_kind_to_string event.kind);
           "payload", event.payload ]

type notification_delivery =
  | Awaiting_recipients
  | Pending_recipients of Keeper_id.Keeper_name.t list

type pending_notification = {
  notification_id : string;
  goal_id : string;
  sender : string;
  content : string;
  delivery : notification_delivery;
}

type state = {
  version : int;
  updated_at : string;
  goals : goal list;
  pending_events : pending_event list;
  pending_notifications : pending_notification list;
}

let goal_to_yojson (goal : goal) =
  `Assoc
    ([
      ("id", `String goal.id);
      ("criterion_revision", `String goal.criterion_revision);
      ("title", `String goal.title);
      ("metric", Json_util.string_opt_to_json goal.metric);
      ("target_value", Json_util.string_opt_to_json goal.target_value);
      ("due_date", Json_util.string_opt_to_json goal.due_date);
      ("priority", `Int goal.priority);
      ("phase", `String (Goal_phase.to_string goal.phase));
      ("last_review_note", Json_util.string_opt_to_json goal.last_review_note);
      ("last_review_at", Json_util.string_opt_to_json goal.last_review_at);
      ("created_at", `String goal.created_at);
      ("updated_at", `String goal.updated_at);
    ] @ match Goal_phase.resume_phase goal.phase with
        | None -> []
        | Some target -> ["resume_phase", `String (Goal_phase.to_string target)])

let pending_notification_to_yojson (notice : pending_notification) =
  let recipients = match notice.delivery with
    | Awaiting_recipients -> `Null
    | Pending_recipients names ->
        `List (List.map (fun name -> `String (Keeper_id.Keeper_name.to_string name)) names) in
  `Assoc ["notification_id", `String notice.notification_id; "goal_id", `String notice.goal_id;
    "sender", `String notice.sender; "content", `String notice.content; "recipients", recipients]

let state_to_yojson (state : state) =
  `Assoc
    [
      ("version", `Int state.version);
      ("updated_at", `String state.updated_at);
      ("goals", `List (List.map goal_to_yojson state.goals));
      ("pending_events", `List (List.map pending_event_to_yojson state.pending_events));
      ("pending_notifications", `List (List.map pending_notification_to_yojson state.pending_notifications));
    ]

(* {1 Decoder}

   A rejection names the member this build's decoder refused. The name is
   data, so the store carries it in [Schema_rejected] without reading it back
   out of a sentence. *)

type schema_rejection = { field : string; detail : string }

(* JSONPath spelling of the document root: the member to name when the whole
   document is not an object and no member of it exists to point at. *)
let document_root_field = "$"

let rejected ~field detail : ('a, schema_rejection) result =
  Error { field; detail }

let accepted_goal_fields =
  [ "id"
  ; "criterion_revision"
  ; "title"
  ; "metric"
  ; "target_value"
  ; "due_date"
  ; "priority"
  ; "phase"
  ; "resume_phase"
  ; "last_review_note"
  ; "last_review_at"
  ; "created_at"
  ; "updated_at"
  ]

let goal_of_yojson : Yojson.Safe.t -> (goal, schema_rejection) result = function
  | `Assoc fields as json ->
      let unknown_field =
        List.find_map
          (fun (field, _) ->
            if List.mem field accepted_goal_fields then None else Some field)
          fields
      in
      let id_opt = Json_util.assoc_member_opt "id" json in
      let title_opt = Json_util.assoc_member_opt "title" json in
      (match unknown_field, id_opt, title_opt with
      | Some field, _, _ ->
          rejected ~field
            (Printf.sprintf "unknown Goal field %S is not accepted" field)
      | None, Some (`String id), Some (`String title) ->
          let* criterion_revision =
            match List.filter (fun (key, _) -> String.equal key "criterion_revision") fields with
            | [ _, `String revision ] when String.trim revision <> "" -> Ok revision
            | _ ->
                rejected ~field:"criterion_revision"
                  (Printf.sprintf
                     "goal %S: criterion_revision must be a non-blank string" id)
          in
          (* Phase is required: a row without [phase] is a decode error, not
             a silent Active default. The silent default caused main red
             #23901 once. *)
          let* phase =
            match Json_util.assoc_member_opt "phase" json with
            | None | Some `Null ->
                rejected ~field:"phase"
                  (Printf.sprintf "goal %S has no phase field" id)
            | Some _ ->
                (match Goal_phase.of_fields json with
                 | Ok phase -> Ok phase
                 | Error detail ->
                     rejected ~field:"phase"
                       (Printf.sprintf "goal %S: %s" id detail))
          in
          let* created_at =
            match Json_util.assoc_member_opt "created_at" json with
            | Some (`String value) -> Ok value
            | _ ->
                rejected ~field:"created_at"
                  (Printf.sprintf "goal %S: created_at missing" id)
          in
          let* updated_at =
            match Json_util.assoc_member_opt "updated_at" json with
            | Some (`String value) -> Ok value
            | _ ->
                rejected ~field:"updated_at"
                  (Printf.sprintf "goal %S: updated_at missing" id)
          in
          (* Required with the same force as phase (#23901): a missing or
             non-int priority resurfacing as a silent 3 hides a corrupt row
             behind a plausible value. Live stores measured zero such rows
             (2026-09-02, 79 goals). *)
          let* priority =
            match Json_util.assoc_member_opt "priority" json with
            | Some (`Int value) -> Ok (clamp_priority value)
            | _ ->
                rejected ~field:"priority"
                  (Printf.sprintf "goal %S: priority must be an int 1-5" id)
          in
          Ok
            {
              id;
              criterion_revision;
              title;
              metric = Json_util.get_string json "metric";
              target_value = Json_util.get_string json "target_value";
              due_date = Json_util.get_string json "due_date";
              priority;
              phase;
              last_review_note = Json_util.get_string json "last_review_note";
              last_review_at = Json_util.get_string json "last_review_at";
              created_at;
              updated_at;
            }
      | None, Some (`String id), _ ->
          rejected ~field:"title"
            (Printf.sprintf "goal %S: title must be a string" id)
      | None, _, _ -> rejected ~field:"id" "goal id must be a string")
  | other_json ->
      rejected ~field:"goals"
        ("goal row is not an object: " ^ Yojson.Safe.to_string other_json)

let pending_event_of_yojson = function
  | `Assoc fields as json ->
      let expected = [ "event_id"; "goal_id"; "store_revision"; "ts"; "event_type"; "payload" ] in
      if List.sort String.compare (List.map fst fields) <> List.sort String.compare expected then
        rejected ~field:"pending_events" "unexpected pending event fields"
      else
        let* kind = match Json_util.get_string json "event_type" with
          | Some "goal_created" -> Ok Created | Some "goal_updated" -> Ok Updated
          | Some "goal_phase" -> Ok Phase | Some "goal_edited" -> Ok Edited
          | _ -> rejected ~field:"pending_events" "unknown pending event kind" in
        (match Json_util.get_string json "event_id", Json_util.get_string json "goal_id",
               Json_util.get_int json "store_revision", Json_util.get_string json "ts",
               Json_util.assoc_member_opt "payload" json with
         | Some event_id, Some goal_id, Some store_revision, Some recorded_at, Some (`Assoc _ as payload)
           when event_id <> "" && goal_id <> "" && store_revision > 0 ->
             Ok { event_id; goal_id; store_revision; recorded_at; kind; payload }
         | _ -> rejected ~field:"pending_events" "malformed pending event")
  | _ -> rejected ~field:"pending_events" "pending event must be an object"

let pending_notification_of_yojson = function
  | `Assoc fields as json ->
      let expected = ["notification_id"; "goal_id"; "sender"; "content"; "recipients"] in
      if List.sort String.compare (List.map fst fields) <> List.sort String.compare expected then
        rejected ~field:"pending_notifications" "unexpected notification fields"
      else
        let* delivery = match Json_util.assoc_member_opt "recipients" json with
          | Some `Null -> Ok Awaiting_recipients
          | Some (`List values) ->
              let rec names acc = function
                | [] -> Ok (Pending_recipients (List.rev acc))
                | `String raw :: rest ->
                    (match Keeper_id.Keeper_name.of_string raw with
                     | Ok name when not (List.exists (Keeper_id.Keeper_name.equal name) acc) ->
                         names (name :: acc) rest
                     | Ok _ | Error _ ->
                         rejected ~field:"pending_notifications" "invalid or duplicate recipient")
                | _ -> rejected ~field:"pending_notifications" "invalid or duplicate recipient" in
              names [] values
          | _ -> rejected ~field:"pending_notifications" "missing recipients" in
        (match Json_util.get_string json "notification_id", Json_util.get_string json "goal_id",
               Json_util.get_string json "sender", Json_util.get_string json "content" with
         | Some notification_id, Some goal_id, Some sender, Some content
           when goal_id <> "" && String.trim sender <> "" && content <> "" ->
             (match Workspace_request_id.of_string notification_id with
              | Error detail -> rejected ~field:"pending_notifications" detail
              | Ok request_id ->
                  let notification_id = Workspace_request_id.to_string request_id in
                  Ok {notification_id; goal_id; sender; content; delivery})
         | _ -> rejected ~field:"pending_notifications" "invalid notification identity or content")
  | _ -> rejected ~field:"pending_notifications" "notification must be an object"

let state_of_yojson : Yojson.Safe.t -> (state, schema_rejection) result = function
  | `Assoc _ as json ->
      let* version =
        match Json_util.assoc_member_opt "version" json with
        | Some (`Int version) -> Ok version
        | _ -> rejected ~field:"version" "version must be an int"
      in
      let* updated_at =
        match Json_util.assoc_member_opt "updated_at" json with
        | Some (`String updated_at) -> Ok updated_at
        | _ -> rejected ~field:"updated_at" "updated_at must be a string"
      in
      let* rows =
        match Json_util.assoc_member_opt "goals" json with
        | Some (`List rows) -> Ok rows
        | _ -> rejected ~field:"goals" "goals must be a list"
      in
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | row :: rest ->
            let* goal = goal_of_yojson row in
            collect (goal :: acc) rest
      in
      let* goals = collect [] rows in
      let* pending_events =
        let seen = Hashtbl.create 16 in
        let rec collect_events acc = function
          | [] -> Ok (List.rev acc)
          | row :: rest ->
              let* event = pending_event_of_yojson row in
              if Hashtbl.mem seen event.event_id then
                rejected ~field:"pending_events" "duplicate pending event_id"
              else begin
                Hashtbl.add seen event.event_id ();
                collect_events (event :: acc) rest
              end in
        match Json_util.assoc_member_opt "pending_events" json with
        | None -> Ok []
        | Some (`List rows) -> collect_events [] rows
        | Some _ -> rejected ~field:"pending_events" "pending_events must be a list" in
      let* pending_notifications =
        let rec collect acc = function
          | [] -> Ok (List.rev acc)
          | row :: rest ->
              let* notice = pending_notification_of_yojson row in
              if List.exists (fun old -> old.notification_id = notice.notification_id) acc then
                rejected ~field:"pending_notifications" "duplicate notification identity"
              else collect (notice :: acc) rest in
        match Json_util.assoc_member_opt "pending_notifications" json with
        | None -> Ok []
        | Some (`List rows) -> collect [] rows
        | Some _ -> rejected ~field:"pending_notifications" "pending_notifications must be a list" in
      Ok { version; updated_at; goals; pending_events; pending_notifications }
  | json ->
      rejected ~field:document_root_field
        ("state is not an object: " ^ Yojson.Safe.to_string json)

let schema_rejection_to_string { field; detail } =
  Printf.sprintf "%s (field %s)" detail field

let validate_state_json json =
  match state_of_yojson json with
  | Ok _ -> Ok ()
  | Error rejection -> Error (schema_rejection_to_string rejection)
