(* Chronicle event data model — implementation.

   See chronicle_event.mli for the full interface contract. *)

type actor_kind =
  | Ak_user
  | Ak_keeper
  | Ak_agent
  | Ak_system

type target_kind =
  | Tk_file
  | Tk_module
  | Tk_plan
  | Tk_issue
  | Tk_command
  | Tk_test
  | Tk_conversation

type event_type =
  | Ev_file_opened
  | Ev_file_edited
  | Ev_file_saved
  | Ev_command_executed
  | Ev_keeper_started
  | Ev_keeper_step
  | Ev_keeper_decision
  | Ev_keeper_completed
  | Ev_keeper_error
  | Ev_plan_created
  | Ev_plan_updated
  | Ev_plan_step_completed
  | Ev_plan_blocked
  | Ev_build_completed
  | Ev_test_passed
  | Ev_test_failed
  | Ev_git_commit
  | Ev_git_merge
  | Ev_conversation
  | Ev_suggestion_accepted
  | Ev_suggestion_rejected

type actor = {
  kind : actor_kind;
  id : string;
  display_name : string;
}

type target = {
  kind : target_kind;
  uri : string;
  range : (int * int) option;
}

type project_snapshot = {
  branch : string option;
  commit : string option;
  files_changed : int option;
  dirty : bool option;
}

type content = {
  summary : string;
  detail : string option;
  diff : string option;
  metadata : (string * Yojson.Safe.t) list;
}

type context = {
  session_id : string;
  parent_event_id : string option;
  related_event_ids : string list;
  tags : string list;
  project_state : project_snapshot option;
}

type intent = {
  stated_goal : string option;
  inferred_intent : string option;
  confidence : float;
}

type t = {
  id : string;
  event_type : event_type;
  timestamp : int;
  actor : actor;
  target : target;
  content : content;
  context : context;
  intent : intent option;
}

(* String tables ------------------------------------------------------ *)

let actor_kind_to_string = function
  | Ak_user -> "user"
  | Ak_keeper -> "keeper"
  | Ak_agent -> "agent"
  | Ak_system -> "system"

let actor_kind_of_string = function
  | "user" -> Ok Ak_user
  | "keeper" -> Ok Ak_keeper
  | "agent" -> Ok Ak_agent
  | "system" -> Ok Ak_system
  | other ->
    Error
      (Printf.sprintf
         "unknown actor kind '%s' (expected user|keeper|agent|system)"
         other)

let target_kind_to_string = function
  | Tk_file -> "file"
  | Tk_module -> "module"
  | Tk_plan -> "plan"
  | Tk_issue -> "issue"
  | Tk_command -> "command"
  | Tk_test -> "test"
  | Tk_conversation -> "conversation"

let target_kind_of_string = function
  | "file" -> Ok Tk_file
  | "module" -> Ok Tk_module
  | "plan" -> Ok Tk_plan
  | "issue" -> Ok Tk_issue
  | "command" -> Ok Tk_command
  | "test" -> Ok Tk_test
  | "conversation" -> Ok Tk_conversation
  | other ->
    Error
      (Printf.sprintf
         "unknown target kind '%s' (expected file|module|plan|issue|command|test|conversation)"
         other)

let event_type_to_string = function
  | Ev_file_opened -> "file.opened"
  | Ev_file_edited -> "file.edited"
  | Ev_file_saved -> "file.saved"
  | Ev_command_executed -> "command.executed"
  | Ev_keeper_started -> "keeper.started"
  | Ev_keeper_step -> "keeper.step"
  | Ev_keeper_decision -> "keeper.decision"
  | Ev_keeper_completed -> "keeper.completed"
  | Ev_keeper_error -> "keeper.error"
  | Ev_plan_created -> "plan.created"
  | Ev_plan_updated -> "plan.updated"
  | Ev_plan_step_completed -> "plan.step.completed"
  | Ev_plan_blocked -> "plan.blocked"
  | Ev_build_completed -> "build.completed"
  | Ev_test_passed -> "test.passed"
  | Ev_test_failed -> "test.failed"
  | Ev_git_commit -> "git.commit"
  | Ev_git_merge -> "git.merge"
  | Ev_conversation -> "conversation"
  | Ev_suggestion_accepted -> "suggestion.accepted"
  | Ev_suggestion_rejected -> "suggestion.rejected"

let event_type_of_string = function
  | "file.opened" -> Ok Ev_file_opened
  | "file.edited" -> Ok Ev_file_edited
  | "file.saved" -> Ok Ev_file_saved
  | "command.executed" -> Ok Ev_command_executed
  | "keeper.started" -> Ok Ev_keeper_started
  | "keeper.step" -> Ok Ev_keeper_step
  | "keeper.decision" -> Ok Ev_keeper_decision
  | "keeper.completed" -> Ok Ev_keeper_completed
  | "keeper.error" -> Ok Ev_keeper_error
  | "plan.created" -> Ok Ev_plan_created
  | "plan.updated" -> Ok Ev_plan_updated
  | "plan.step.completed" -> Ok Ev_plan_step_completed
  | "plan.blocked" -> Ok Ev_plan_blocked
  | "build.completed" -> Ok Ev_build_completed
  | "test.passed" -> Ok Ev_test_passed
  | "test.failed" -> Ok Ev_test_failed
  | "git.commit" -> Ok Ev_git_commit
  | "git.merge" -> Ok Ev_git_merge
  | "conversation" -> Ok Ev_conversation
  | "suggestion.accepted" -> Ok Ev_suggestion_accepted
  | "suggestion.rejected" -> Ok Ev_suggestion_rejected
  | other -> Error (Printf.sprintf "unknown event type '%s'" other)

(* JSON helpers ------------------------------------------------------- *)

let opt_str_assoc key = function
  | None -> []
  | Some s -> [ key, `String s ]

let opt_int_assoc key = function
  | None -> []
  | Some i -> [ key, `Int i ]

let opt_bool_assoc key = function
  | None -> []
  | Some b -> [ key, `Bool b ]

let opt_assoc key v = function
  | None -> []
  | Some x -> [ key, v x ]

(* Encoders ----------------------------------------------------------- *)

let actor_to_yojson { kind; id; display_name } : Yojson.Safe.t =
  `Assoc
    [
      "type", `String (actor_kind_to_string kind);
      "id", `String id;
      "displayName", `String display_name;
    ]

let range_to_yojson (a, b) : Yojson.Safe.t = `List [ `Int a; `Int b ]

let target_to_yojson { kind; uri; range } : Yojson.Safe.t =
  `Assoc
    ([
       "type", `String (target_kind_to_string kind);
       "uri", `String uri;
     ]
    @ opt_assoc "range" range_to_yojson range)

let project_snapshot_to_yojson { branch; commit; files_changed; dirty }
    : Yojson.Safe.t =
  `Assoc
    (opt_str_assoc "branch" branch
    @ opt_str_assoc "commit" commit
    @ opt_int_assoc "filesChanged" files_changed
    @ opt_bool_assoc "dirty" dirty)

let content_to_yojson { summary; detail; diff; metadata } : Yojson.Safe.t =
  `Assoc
    ([ "summary", `String summary ]
    @ opt_str_assoc "detail" detail
    @ opt_str_assoc "diff" diff
    @
    match metadata with
    | [] -> []
    | _ -> [ "metadata", `Assoc metadata ])

let context_to_yojson
    { session_id; parent_event_id; related_event_ids; tags; project_state }
    : Yojson.Safe.t =
  `Assoc
    ([ "sessionId", `String session_id ]
    @ opt_str_assoc "parentEventId" parent_event_id
    @ [
        "relatedEventIds",
          `List (List.map (fun s -> `String s) related_event_ids);
        "tags", `List (List.map (fun s -> `String s) tags);
      ]
    @ opt_assoc "projectState" project_snapshot_to_yojson project_state)

let intent_to_yojson { stated_goal; inferred_intent; confidence }
    : Yojson.Safe.t =
  `Assoc
    (opt_str_assoc "statedGoal" stated_goal
    @ opt_str_assoc "inferredIntent" inferred_intent
    @ [ "confidence", `Float confidence ])

let to_yojson
    { id; event_type; timestamp; actor; target; content; context; intent } =
  `Assoc
    ([
       "id", `String id;
       "eventType", `String (event_type_to_string event_type);
       "timestamp", `Int timestamp;
       "actor", actor_to_yojson actor;
       "target", target_to_yojson target;
       "content", content_to_yojson content;
       "context", context_to_yojson context;
     ]
    @ opt_assoc "intent" intent_to_yojson intent)

(* Decoders ----------------------------------------------------------- *)

let ( let* ) = Result.bind

let expect_assoc ~where = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Printf.sprintf "%s: expected JSON object" where)

let find_field fields name =
  try Some (List.assoc name fields) with Not_found -> None

let require_string fields name =
  match find_field fields name with
  | Some (`String s) -> Ok s
  | Some _ -> Error (Printf.sprintf "field '%s' must be a string" name)
  | None -> Error (Printf.sprintf "missing required string field '%s'" name)

let require_int fields name =
  match find_field fields name with
  | Some (`Int n) -> Ok n
  | Some _ -> Error (Printf.sprintf "field '%s' must be an integer" name)
  | None -> Error (Printf.sprintf "missing required int field '%s'" name)

let optional_string fields name =
  match find_field fields name with
  | None | Some `Null -> Ok None
  | Some (`String s) -> Ok (Some s)
  | Some _ -> Error (Printf.sprintf "field '%s' must be a string when present" name)

let optional_int fields name =
  match find_field fields name with
  | None | Some `Null -> Ok None
  | Some (`Int n) -> Ok (Some n)
  | Some _ -> Error (Printf.sprintf "field '%s' must be an integer when present" name)

let optional_bool fields name =
  match find_field fields name with
  | None | Some `Null -> Ok None
  | Some (`Bool b) -> Ok (Some b)
  | Some _ -> Error (Printf.sprintf "field '%s' must be a bool when present" name)

let string_list fields name =
  match find_field fields name with
  | None | Some `Null -> Ok []
  | Some (`List xs) ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | `String s :: rest -> loop (s :: acc) rest
      | _ ->
        Error (Printf.sprintf "field '%s' must be a list of strings" name)
    in
    loop [] xs
  | Some _ -> Error (Printf.sprintf "field '%s' must be a list" name)

let actor_of_yojson json =
  let* fields = expect_assoc ~where:"actor" json in
  let* type_str = require_string fields "type" in
  let* kind = actor_kind_of_string type_str in
  let* id = require_string fields "id" in
  let* display_name = require_string fields "displayName" in
  Ok { kind; id; display_name }

let range_of_yojson json =
  match json with
  | `List [ `Int a; `Int b ] -> Ok (a, b)
  | _ -> Error "range must be a JSON array of two integers"

let target_of_yojson json =
  let* fields = expect_assoc ~where:"target" json in
  let* type_str = require_string fields "type" in
  let* kind = target_kind_of_string type_str in
  let* uri = require_string fields "uri" in
  let* range =
    match find_field fields "range" with
    | None | Some `Null -> Ok None
    | Some j ->
      let* r = range_of_yojson j in
      Ok (Some r)
  in
  Ok { kind; uri; range }

let project_snapshot_of_yojson json =
  let* fields = expect_assoc ~where:"projectState" json in
  let* branch = optional_string fields "branch" in
  let* commit = optional_string fields "commit" in
  let* files_changed = optional_int fields "filesChanged" in
  let* dirty = optional_bool fields "dirty" in
  Ok { branch; commit; files_changed; dirty }

let content_of_yojson json =
  let* fields = expect_assoc ~where:"content" json in
  let* summary = require_string fields "summary" in
  let* detail = optional_string fields "detail" in
  let* diff = optional_string fields "diff" in
  let metadata =
    match find_field fields "metadata" with
    | Some (`Assoc kvs) -> kvs
    | _ -> []
  in
  Ok { summary; detail; diff; metadata }

let context_of_yojson json =
  let* fields = expect_assoc ~where:"context" json in
  let* session_id = require_string fields "sessionId" in
  let* parent_event_id = optional_string fields "parentEventId" in
  let* related_event_ids = string_list fields "relatedEventIds" in
  let* tags = string_list fields "tags" in
  let* project_state =
    match find_field fields "projectState" with
    | None | Some `Null -> Ok None
    | Some j ->
      let* ps = project_snapshot_of_yojson j in
      Ok (Some ps)
  in
  Ok { session_id; parent_event_id; related_event_ids; tags; project_state }

let intent_of_yojson json =
  let* fields = expect_assoc ~where:"intent" json in
  let* stated_goal = optional_string fields "statedGoal" in
  let* inferred_intent = optional_string fields "inferredIntent" in
  let* confidence =
    match find_field fields "confidence" with
    | Some (`Float f) -> Ok f
    | Some (`Int n) -> Ok (float_of_int n)
    | Some _ -> Error "intent.confidence must be a number"
    | None -> Error "intent.confidence is required"
  in
  Ok { stated_goal; inferred_intent; confidence }

let of_yojson json =
  let* fields = expect_assoc ~where:"chronicle event" json in
  let* id = require_string fields "id" in
  let* event_type_str = require_string fields "eventType" in
  let* event_type = event_type_of_string event_type_str in
  let* timestamp = require_int fields "timestamp" in
  let* actor =
    match find_field fields "actor" with
    | Some j -> actor_of_yojson j
    | None -> Error "missing required field 'actor'"
  in
  let* target =
    match find_field fields "target" with
    | Some j -> target_of_yojson j
    | None -> Error "missing required field 'target'"
  in
  let* content =
    match find_field fields "content" with
    | Some j -> content_of_yojson j
    | None -> Error "missing required field 'content'"
  in
  let* context =
    match find_field fields "context" with
    | Some j -> context_of_yojson j
    | None -> Error "missing required field 'context'"
  in
  let* intent =
    match find_field fields "intent" with
    | None | Some `Null -> Ok None
    | Some j ->
      let* i = intent_of_yojson j in
      Ok (Some i)
  in
  Ok { id; event_type; timestamp; actor; target; content; context; intent }

(* Invariant check ---------------------------------------------------- *)

let is_well_formed t =
  if String.length t.id = 0 then Error "id must be non-empty"
  else if t.timestamp <= 0 then Error "timestamp must be positive"
  else if String.length t.actor.id = 0 then
    Error "actor.id must be non-empty"
  else if String.length t.actor.display_name = 0 then
    Error "actor.displayName must be non-empty"
  else if String.length t.target.uri = 0 then
    Error "target.uri must be non-empty"
  else if String.length t.content.summary = 0 then
    Error "content.summary must be non-empty"
  else if String.length t.context.session_id = 0 then
    Error "context.sessionId must be non-empty"
  else
    match t.intent with
    | None -> Ok ()
    | Some { confidence; _ } ->
      if (not (Float.is_finite confidence))
         || confidence < 0.0
         || confidence > 1.0
      then
        Error "intent.confidence must be a finite float in [0.0, 1.0]"
      else Ok ()
