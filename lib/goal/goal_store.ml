(* Goal store — shared planning goals with a dedicated lifecycle phase.
   [phase] is the only persisted lifecycle representation. *)

let ( let* ) = Result.bind

let clamp_priority p =
  max 1 (min 5 p)

type goal = {
  id : string;
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

type state = {
  version : int;
  updated_at : string;
  goals : goal list;
}

let rec state_to_yojson (state : state) =
  `Assoc
    [
      ("version", `Int state.version);
      ("updated_at", `String state.updated_at);
      ("goals", `List (List.map (fun goal -> goal_to_yojson goal) state.goals));
    ]

and goal_to_yojson (goal : goal) =
  `Assoc
    [
      ("id", `String goal.id);
      ("title", `String goal.title);
      ("metric", Json_util.string_opt_to_json goal.metric);
      ("target_value", Json_util.string_opt_to_json goal.target_value);
      ("due_date", Json_util.string_opt_to_json goal.due_date);
      ("priority", `Int goal.priority);
      ("phase", Goal_phase.to_yojson goal.phase);
      ("last_review_note", Json_util.string_opt_to_json goal.last_review_note);
      ("last_review_at", Json_util.string_opt_to_json goal.last_review_at);
      ("created_at", `String goal.created_at);
      ("updated_at", `String goal.updated_at);
    ]

and state_of_yojson = function
  | `Assoc _ as json ->
      begin
        match Json_util.assoc_member_opt "version" json, Json_util.assoc_member_opt "updated_at" json, Json_util.assoc_member_opt "goals" json with
        | Some (`Int version), Some (`String updated_at), Some (`List goals_json) ->
            let rec collect acc = function
              | [] -> Ok (List.rev acc)
              | row :: rest -> (
                  match goal_of_yojson row with
                  | Ok goal -> collect (goal :: acc) rest
                  | Error msg -> Error msg)
            in
            Result.map
              (fun goals -> { version; updated_at; goals })
              (collect [] goals_json)
        | _ -> Error "state_of_yojson: invalid state"
      end
  | json ->
      Error ("state_of_yojson: " ^ Yojson.Safe.to_string json)

and goal_of_yojson = function
  | `Assoc fields as json ->
      let accepted_fields =
        [ "id"
        ; "title"
        ; "metric"
        ; "target_value"
        ; "due_date"
        ; "priority"
        ; "phase"
        ; "last_review_note"
        ; "last_review_at"
        ; "created_at"
        ; "updated_at"
        ]
      in
      let unknown_field =
        List.find_map
          (fun (field, _) ->
            if List.mem field accepted_fields then None else Some field)
          fields
      in
      let id_opt = Json_util.assoc_member_opt "id" json in
      let title_opt = Json_util.assoc_member_opt "title" json in
      (match unknown_field, id_opt, title_opt with
      | Some field, _, _ ->
          Error
            (Printf.sprintf
               "goal_of_yojson: unknown Goal field %S is not accepted"
               field)
      | None, Some (`String id), Some (`String title) ->
          let phase =
            (* Phase is required: a row without [phase] is a decode error, not
               a silent Active default. The silent default caused main red
               #23901 once. *)
            match Json_util.assoc_member_opt "phase" json with
            | None | Some `Null ->
                Error
                  (Printf.sprintf "goal_of_yojson: goal %S has no phase field" id)
            | Some phase_json -> Goal_phase.of_yojson phase_json
          in
          let created_at =
            match Json_util.assoc_member_opt "created_at" json with
            | Some (`String value) -> Ok value
            | _ -> Error "goal_of_yojson: created_at missing"
          in
          let updated_at =
            match Json_util.assoc_member_opt "updated_at" json with
            | Some (`String value) -> Ok value
            | _ -> Error "goal_of_yojson: updated_at missing"
          in
          (match phase, created_at, updated_at with
           | Ok phase, Ok created_at, Ok updated_at ->
             Ok
               {
                    id;
                    title;
                    metric = Json_util.get_string json "metric";
                    target_value = Json_util.get_string json "target_value";
                    due_date = Json_util.get_string json "due_date";
                    priority =
                      (match Json_util.assoc_member_opt "priority" json with
                      | Some (`Int value) -> clamp_priority value
                      | _ -> 3);
                    phase;
                    last_review_note = Json_util.get_string json "last_review_note";
                    last_review_at = Json_util.get_string json "last_review_at";
                    created_at;
                    updated_at;
                  }
           | Error msg, _, _ -> Error msg
           | _, Error msg, _ -> Error msg
           | _, _, Error msg -> Error msg)
      | None, _, _ -> Error "goal_of_yojson: invalid goal")
  | other_json ->
      Error ("goal_of_yojson: " ^ Yojson.Safe.to_string other_json)

type rollup = {
  active_count : int;
  verifying_count : int;
  done_count : int;
  dropped_count : int;
}
[@@deriving yojson]

let parse_goal_phase = function
  | Some s -> Goal_phase.parse s
  | None -> None

let goals_path config =
  Filename.concat (Workspace_utils.masc_dir config) "goals.json"

let goals_recovery_path config =
  goals_path config ^ ".last-good"

let ensure_dirs config =
  Workspace_utils.mkdir_p (Workspace_utils.masc_dir config)

let default_state () =
  { version = 1; updated_at = Masc_domain.now_iso (); goals = [] }

(* A store that exists but does not decode must not license a write.  The
   read-modify-write paths below take the file lock, read, then overwrite BOTH
   goals.json and its .last-good mirror — so a lenient empty fallback on the read
   turns one undecodable row into permanent loss of every goal.  [load_state]
   separates "no store yet" (legitimately empty) from "store present, undecodable"
   so writers can refuse while readers keep the lenient behaviour. *)
type load_outcome =
  | Loaded of state
  | Undecodable of string

let load_state config : load_outcome =
  ensure_dirs config;
  let path = goals_path config in
  if Workspace_utils.path_exists config path then
    match Workspace_utils.read_json_result config path with
    | Ok json ->
        (match state_of_yojson json with
         | Ok state -> Loaded state
         | Error primary_msg ->
             let recovery = goals_recovery_path config in
             if Workspace_utils.path_exists config recovery then
               match Workspace_utils.read_json_result config recovery with
               | Ok recovery_json ->
                   (match state_of_yojson recovery_json with
                    | Ok state ->
                        Log.Misc.warn
                          "goal_store: primary goals.json corrupt (%s), recovered from %s"
                          primary_msg recovery;
                        Loaded state
                    | Error recovery_msg ->
                        Log.Misc.error
                          "goal_store: both primary and recovery goals.json corrupt (primary: %s, recovery: %s)"
                          primary_msg recovery_msg;
                        Undecodable
                          (Printf.sprintf
                             "primary: %s; recovery: %s" primary_msg recovery_msg))
               | Error recovery_read_msg ->
                   Log.Misc.warn
                     "goal_store: goals.json corrupt (%s), recovery read failed: %s"
                     primary_msg recovery_read_msg;
                   Undecodable
                     (Printf.sprintf
                        "primary: %s; recovery unreadable: %s"
                        primary_msg recovery_read_msg)
             else
               (Log.Misc.warn
                  "goal_store: goals.json corrupt (%s), no .last-good available"
                  primary_msg;
                Undecodable primary_msg))
    | Error primary_msg ->
        let recovery = goals_recovery_path config in
        if Workspace_utils.path_exists config recovery then
          match Workspace_utils.read_json_result config recovery with
          | Ok recovery_json ->
              (match state_of_yojson recovery_json with
               | Ok state ->
                   Log.Misc.warn
                     "goal_store: primary goals.json unreadable (%s), recovered from %s"
                     primary_msg recovery;
                   Loaded state
               | Error recovery_msg ->
                   Log.Misc.error
                     "goal_store: primary unreadable (%s), recovery corrupt (%s)"
                     primary_msg recovery_msg;
                   Undecodable
                     (Printf.sprintf
                        "primary unreadable: %s; recovery: %s" primary_msg recovery_msg))
          | Error recovery_msg ->
              Log.Misc.error
                "goal_store: primary unreadable (%s), recovery unreadable (%s)"
                primary_msg recovery_msg;
              Undecodable
                (Printf.sprintf
                   "primary unreadable: %s; recovery unreadable: %s"
                   primary_msg recovery_msg)
        else
          (Log.Misc.warn
             "goal_store: goals.json unreadable (%s), no .last-good available"
             primary_msg;
           Undecodable primary_msg)
  else
    Loaded (default_state ())

(* Read-only view: an undecodable store reads as empty, unchanged from before.
   Only the locked write paths escalate it to an error. *)
let read_state config =
  match load_state config with
  | Loaded state -> state
  | Undecodable _ -> default_state ()

let undecodable_store_error config detail =
  Printf.sprintf
    "goal_store: refusing to write over a store that did not decode (%s); reset or \
     repair %s before writing"
    detail
    (goals_path config)

let write_state_result config state =
  ensure_dirs config;
  let json = state_to_yojson state in
  let* () = Workspace_utils.write_json_result config (goals_path config) json in
  (match Workspace_utils.write_json_result config (goals_recovery_path config) json with
   | Ok () -> ()
   | Error msg ->
     Log.Misc.warn
       "goal_store: primary goals.json committed; recovery mirror write failed for %s: %s"
       (goals_recovery_path config)
       msg);
  Ok ()

let write_state config state =
  match write_state_result config state with
  | Ok () -> ()
  | Error msg ->
    Log.Misc.warn "goal_store.write_state failed for %s: %s"
      (goals_path config)
      msg

let now_ms () =
  int_of_float (Time_compat.now () *. 1000.0)

(* The suffix used to be [Hashtbl.hash (gettimeofday ())] masked to 16 bits.
   Two goals minted in the same millisecond hash near-identical clock values,
   so the part meant to separate them was the part most correlated with what
   it was separating. [Random_id] is the entropy source the rest of the tree
   uses; take 4 bytes from it instead. *)
let gen_goal_id () =
  Printf.sprintf "goal-%d-%s" (now_ms ()) (Random_id.hex ~bytes:4)

let find_goal goals id =
  List.find_opt (fun goal -> String.equal goal.id id) goals

let replace_goal goals updated =
  List.map (fun goal -> if String.equal goal.id updated.id then updated else goal) goals

let update_state config f =
  let lock_path = goals_path config in
  Workspace_utils.with_file_lock config lock_path (fun () ->
      match load_state config with
      | Undecodable detail -> Error (undecodable_store_error config detail)
      | Loaded state ->
        let next_state = f state in
        let* () = write_state_result config next_state in
        Ok next_state)

let get_goal config ~goal_id =
  read_state config |> fun state -> find_goal state.goals goal_id

type conditional_update =
  | Goal_updated of goal
  | Goal_phase_mismatch of Goal_phase.t

let update_goal_if_phase config ~goal_id ~expected_phase f =
  let lock_path = goals_path config in
  Workspace_utils.with_file_lock config lock_path (fun () ->
      match load_state config with
      | Undecodable detail -> Error (undecodable_store_error config detail)
      | Loaded state ->
        (match find_goal state.goals goal_id with
         | None -> Error "goal not found"
         | Some goal when goal.phase <> expected_phase ->
           Ok (Goal_phase_mismatch goal.phase)
         | Some goal ->
           let now = Masc_domain.now_iso () in
           let updated_goal = f { goal with updated_at = now } in
           let next_state =
             { version = state.version + 1
             ; updated_at = now
             ; goals = replace_goal state.goals updated_goal
             }
           in
           let* () = write_state_result config next_state in
           Ok (Goal_updated updated_goal)))

type delete_goal_outcome =
  | Deleted
  | Deleted_with_orphaned_links of string

type delete_goal_error =
  | Unknown_goal of string
  | Persistence_failed of string

let delete_goal_error_to_string = function
  | Unknown_goal msg -> msg
  | Persistence_failed msg -> "goal persistence failed: " ^ msg

let delete_goal config ~goal_id =
  let deleted =
    Workspace_utils.with_file_lock config (goals_path config) (fun () ->
      match load_state config with
      | Undecodable detail ->
        Error (Persistence_failed (undecodable_store_error config detail))
      | Loaded state ->
      if not (List.exists (fun goal -> String.equal goal.id goal_id) state.goals) then
        Error (Unknown_goal "Goal not found")
      else (
        match
          write_state_result
            config
            { version = state.version + 1
            ; goals =
                List.filter
                  (fun goal -> not (String.equal goal.id goal_id))
                  state.goals
            ; updated_at = Masc_domain.now_iso ()
            }
        with
        | Ok () -> Ok ()
        | Error msg -> Error (Persistence_failed msg)))
  in
  match deleted with
  | Error _ as error -> error
  | Ok () ->
    (* This is best-effort cascade cleanup across two file stores, not a
       cross-file transaction. A structural fix would either co-locate
       goal-task links with goals or add a higher-level transaction lock that
       covers every goal/link mutation path. *)
    (match Workspace_goal_index.prune_links_for_goal_result config ~goal_id with
     | Ok () -> Ok Deleted
     | Error detail ->
       Log.Misc.warn
         "goal_store.delete_goal: goal %s removed but goal_task_links prune failed: %s"
         goal_id
         detail;
       let warning =
         Printf.sprintf
           "goal deleted but failed to prune goal_task_links for %s: %s"
           goal_id
           detail
       in
       Ok (Deleted_with_orphaned_links warning))

let sort_goals goals =
  (* Sort key is [(priority asc, updated_at desc)]. *)
  List.sort
    (fun left right ->
      let by_priority = compare left.priority right.priority in
      if by_priority <> 0 then
        by_priority
      else
        String.compare right.updated_at left.updated_at)
    goals

let list_goals config ?phase () =
  read_state config
  |> fun state -> state.goals
  |> List.filter (fun goal ->
         match phase with
         | None -> true
         | Some phase -> goal.phase = phase)
  |> sort_goals

let blank_opt = function
  | None -> true
  | Some raw -> String.trim raw = ""

let upsert_goal config ?id ?title ?metric ?target_value ?due_date
    ?priority ?phase () =
  let is_new_goal = id = None in
  if is_new_goal && (title = None || title = Some "") then
    Error "title required for new goal"
  else
    (* DET-OK: typed optional API param (not parsed input) — a new goal
       without an explicit phase starts Executing, same as the removed match. *)
    let default_phase = Option.value phase ~default:Goal_phase.Executing in
    let now = Masc_domain.now_iso () in
        let resolved_id = Option.value id ~default:(gen_goal_id ()) in
        let was_created = ref false in
        let refusal = ref None in
        let state_result =
          update_state config (fun state ->
              match find_goal state.goals resolved_id with
              | Some existing ->
                  (* DET-OK: typed optional param — omitted phase preserves
                     the stored phase (same arm the removed match had). *)
                  let next_phase = Option.value phase ~default:existing.phase in
                  let next_goal =
                      {
                        existing with
                        title = Option.value title ~default:existing.title;
                        metric = (match metric with Some _ -> metric | None -> existing.metric);
                        target_value =
                          (match target_value with
                          | Some _ -> target_value
                          | None -> existing.target_value);
                        due_date =
                          (match due_date with
                          | Some _ -> due_date
                          | None -> existing.due_date);
                        priority =
                          clamp_priority
                            (Option.value priority ~default:existing.priority);
                        phase = next_phase;
                        updated_at = now;
                      }
                  in
                  {
                    version = state.version + 1;
                    updated_at = now;
                    goals = replace_goal state.goals next_goal;
                  }
              | None ->
                  (* RFC-0387 B1: a goal is created only with a declared
                     measurable success condition — both [metric] and
                     [target_value], non-blank. Updates (the arm above) are
                     not gated: the obligation is declared at creation. The
                     create/update split is decided HERE, inside the write
                     lock on the freshly decoded state: an undecodable store
                     is rejected by [update_state]'s fail-closed path before
                     this closure runs, so the B1 refusal below can only ever
                     fire against a store that was actually read and found
                     not to hold the row. On refusal the closure returns the
                     state unchanged and [update_state] rewrites the same
                     bytes; the error is carried out via [refusal]. *)
                  if blank_opt metric || blank_opt target_value then (
                    refusal :=
                      Some
                        "metric and target_value are required for a new goal \
                         (RFC-0387 B1: a goal must declare a measurable \
                         success condition)";
                    state)
                  else (
                  let new_goal =
                      {
                        id = resolved_id;
                        title = Option.value title ~default:"Untitled goal";
                        metric;
                        target_value;
                        due_date;
                        priority = clamp_priority (Option.value priority ~default:3);
                        phase = default_phase;
                        last_review_note = None;
                        last_review_at = None;
                        created_at = now;
                        updated_at = now;
                      }
                  in
                  was_created := true;
                  {
                    version = state.version + 1;
                    updated_at = now;
                    goals = state.goals @ [ new_goal ];
                  }))
        in
        (match state_result with
        | Error msg -> Error msg
        | Ok state ->
          (match !refusal with
           | Some msg -> Error msg
           | None ->
          (match find_goal state.goals resolved_id with
          | Some goal ->
              Ok (goal, if !was_created then `created else `updated)
          | None ->
              Error "failed to save goal")))

let compute_rollup goals =
  let count predicate =
    List_util.count_if predicate goals
  in
  {
    active_count = count (fun goal -> goal.phase = Goal_phase.Executing);
    verifying_count = count (fun goal -> goal.phase = Goal_phase.Verifying);
    done_count = count (fun goal -> goal.phase = Goal_phase.Completed);
    dropped_count = count (fun goal -> goal.phase = Goal_phase.Dropped);
  }
