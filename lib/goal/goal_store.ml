(* Goal store — shared planning goals with a dedicated lifecycle phase.
   [phase] is the only persisted lifecycle representation.

   RFC-0444: the store is read through one closed sum, [source]. A store this
   build cannot read is [Unavailable], carrying the reason, the state of the
   .last-good mirror and the operator's next step; it never reads as an empty
   state. The only empty state is [Uninitialized]: neither goals.json nor its
   mirror exists. 2026-09-08 (#34459) 97 goals read as 0 for 7h29m because
   the reader folded a decode failure into a default state (B1). *)

let ( let* ) = Result.bind

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

type state = {
  version : int;
  updated_at : string;
  goals : goal list;
}

let goal_to_yojson (goal : goal) =
  `Assoc
    [
      ("id", `String goal.id);
      ("criterion_revision", `String goal.criterion_revision);
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

let state_to_yojson (state : state) =
  `Assoc
    [
      ("version", `Int state.version);
      ("updated_at", `String state.updated_at);
      ("goals", `List (List.map goal_to_yojson state.goals));
    ]

(* {1 Decoder}

   A rejection names the member this build's decoder refused. The name is
   data, so [Schema_rejected] below carries it without reading it back out of
   a sentence. *)

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
            | Some phase_json ->
                (match Goal_phase.of_yojson phase_json with
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
      Ok { version; updated_at; goals }
  | json ->
      rejected ~field:document_root_field
        ("state is not an object: " ^ Yojson.Safe.to_string json)

let schema_rejection_to_string { field; detail } =
  Printf.sprintf "%s (field %s)" detail field

let validate_state_json json =
  match state_of_yojson json with
  | Ok _ -> Ok ()
  | Error rejection -> Error (schema_rejection_to_string rejection)

type rollup = {
  active_count : int;
  verifying_count : int;
  awaiting_confirmation_count : int;
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

(* The one empty state this module constructs. Its only call is the first
   write on an [Uninitialized] store (RFC-0444 §2.2, criterion 2); no reader
   builds it. *)
let default_state : unit -> state = fun () ->
  { version = 1; updated_at = Masc_domain.now_iso (); goals = [] }

(* {1 Source (RFC-0444 §2.1)} *)

type source =
  | Uninitialized
  | Available of state
  | Unavailable of unavailable

(* The value itself is defined in masc_types ([Goal_store_unavailable]) so
   the task-creation contract below this library can carry it; the manifest
   re-export keeps every constructor addressable as [Goal_store.X]. *)
and unavailable = Goal_store_unavailable.t =
  { file : string
  ; reason : reason
  ; mirror : mirror_status
  ; reset_step : reset_step
  }

and reason = Goal_store_unavailable.reason =
  | Missing_after_init
  | Unreadable of Unix.error
  | Not_json of string
  | Schema_rejected of { field : string; detail : string }

and mirror_status = Goal_store_unavailable.mirror_status =
  | Mirror_absent
  | Mirror_unreadable of Unix.error
  | Mirror_decodes of { goal_count : int; updated_at : string }
  | Mirror_rejected of reason

and reset_step = Goal_store_unavailable.reset_step =
  | Repair_field of string
  | Reset_goal_store
  | Restore_permission

type lookup =
  | Goal_found of goal
  | Goal_absent
  | Store_unavailable of unavailable

(* [Unix.error] is the kernel's sum, not this module's; only [EACCES] names a
   step other than a reset, so the remaining errnos share one arm. *)
let reset_step_of_reason = function
  | Schema_rejected { field; _ } -> Repair_field field
  | Unreadable Unix.EACCES -> Restore_permission
  | Unreadable _ -> Reset_goal_store
  | Missing_after_init -> Reset_goal_store
  | Not_json _ -> Reset_goal_store

let unavailable_to_string = Goal_store_unavailable.to_string

(* {2 Reading a file with its errno}

   The shared read chain ([Workspace_utils.read_json_result] →
   [Safe_ops.read_file_safe] → [Fs_compat.load_file]) renders every failure
   to a sentence and reads a missing or blank file as [`Assoc []], so neither
   [Unreadable of Unix.error] nor the absent/blank split can come out of it.
   The store opens the file itself. The read is inline on the calling
   fiber: goals.json holds the current set only (97 rows ≈ 40 KB on
   2026-09-08), well under the reads that measured on the main domain
   (RFC main-domain-scheduler-latency §8.8). *)

type file_read =
  | File_absent
  | File_unreadable of Unix.error
  | File_bytes of string

let read_chunk_bytes = 65536

let read_file path : file_read =
  match Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> File_absent
  | exception Unix.Unix_error (error, _, _) -> File_unreadable error
  | fd ->
      let buffer = Buffer.create read_chunk_bytes in
      let chunk = Bytes.create read_chunk_bytes in
      (* A directory opens read-only and fails on the first [read] with
         EISDIR, which is why the loop classifies its own errno. *)
      let rec drain () =
        match Unix.read fd chunk 0 read_chunk_bytes with
        | 0 -> File_bytes (Buffer.contents buffer)
        | count ->
            Buffer.add_subbytes buffer chunk 0 count;
            drain ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> drain ()
        | exception Unix.Unix_error (error, _, _) -> File_unreadable error
      in
      Fun.protect
        ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
        drain

let decode_bytes bytes : (state, reason) result =
  match Yojson.Safe.from_string bytes with
  | exception Yojson.Json_error detail -> Error (Not_json detail)
  | json ->
      (match state_of_yojson json with
       | Ok state -> Ok state
       | Error { field; detail } -> Error (Schema_rejected { field; detail }))

(* The mirror is evidence of how far the primary drifted, never state: a
   mirror that decodes is reported with its size and stamp and is not served
   (RFC-0444 §5, "보여주되 서빙하지 않는다"). *)
let mirror_status_of_read = function
  | File_absent -> Mirror_absent
  | File_unreadable error -> Mirror_unreadable error
  | File_bytes bytes ->
      (match decode_bytes bytes with
       | Ok state ->
           Mirror_decodes
             { goal_count = List.length state.goals; updated_at = state.updated_at }
       | Error reason -> Mirror_rejected reason)

let make_unavailable config ~reason ~mirror =
  { file = goals_path config; reason; mirror; reset_step = reset_step_of_reason reason }

(* Only opens and reads: no directory creation, rename, write, delete or log
   line. A primary that decodes is [Available] without the mirror being
   opened at all. *)
let load_source config : source =
  let read_mirror () = mirror_status_of_read (read_file (goals_recovery_path config)) in
  match read_file (goals_path config) with
  | File_absent ->
      (match read_mirror () with
       | Mirror_absent -> Uninitialized
       | (Mirror_unreadable _ | Mirror_decodes _ | Mirror_rejected _) as mirror ->
           Unavailable (make_unavailable config ~reason:Missing_after_init ~mirror))
  | File_unreadable error ->
      Unavailable (make_unavailable config ~reason:(Unreadable error) ~mirror:(read_mirror ()))
  | File_bytes bytes ->
      (match decode_bytes bytes with
       | Ok state -> Available state
       | Error reason -> Unavailable (make_unavailable config ~reason ~mirror:(read_mirror ())))

let find_goal_in goals id =
  List.find_opt (fun goal -> String.equal goal.id id) goals

let find_goal config ~goal_id : lookup =
  match load_source config with
  | Uninitialized -> Goal_absent
  | Unavailable u -> Store_unavailable u
  | Available state ->
      (match find_goal_in state.goals goal_id with
       | Some goal -> Goal_found goal
       | None -> Goal_absent)

(* {1 Writing} *)

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

let replace_goal goals updated =
  List.map (fun goal -> if String.equal goal.id updated.id then updated else goal) goals

type delete_goal_outcome =
  | Deleted
  | Deleted_with_orphaned_links of string

type delete_goal_error =
  | Unknown_goal of string
  | Store_unavailable of unavailable
  | Persistence_failed of string

let delete_goal_error_to_string = function
  | Unknown_goal msg -> msg
  | Store_unavailable u -> unavailable_to_string u
  | Persistence_failed msg -> "goal persistence failed: " ^ msg

type goal_reference_error =
  | Goal_source_unavailable of unavailable
  | Goal_lock_failed of Masc_domain.masc_error
  | Goal_missing of string

(* Defined after [lookup] and [delete_goal_error] on purpose: a bare
   [Store_unavailable] resolves to this type, and the two functions that
   build the other two annotate their result. *)
type write_error =
  | Store_unavailable of unavailable
  | Goal_not_found of string
  | Rejected of string
  | Persist_failed of string

let write_error_to_string = function
  | Store_unavailable u -> unavailable_to_string u
  | Goal_not_found goal_id -> "goal not found: " ^ goal_id
  | Rejected detail -> detail
  | Persist_failed detail -> "goal persistence failed: " ^ detail

(* Goal membership and the dependent commit share the Goal lock. Callbacks
   may acquire backlog then link locks, never re-enter the Goal store. *)
let with_existing_goals config ~goal_ids f =
  match goal_ids with
  | [] -> Ok (f ())
  | first_id :: _ ->
    (match Workspace_utils.with_file_lock_r config (goals_path config) (fun () ->
      match load_source config with
      | Unavailable u -> Error (Goal_source_unavailable u)
      | Uninitialized -> Error (Goal_missing first_id)
      | Available state ->
        match List.find_opt
          (fun id -> not (List.exists (fun (goal : goal) -> String.equal goal.id id) state.goals))
          goal_ids with
        | Some id -> Error (Goal_missing id)
        | None -> Ok (f ())) with
     | Ok result -> result
     | Error error -> Error (Goal_lock_failed error))

let update_state config f : (state, write_error) result =
  Workspace_utils.with_file_lock config (goals_path config) (fun () ->
      let current : (state, write_error) result =
        match load_source config with
        | Unavailable u -> Error (Store_unavailable u)
        (* The first write creates the store; nothing writes an empty state
           ahead of it (RFC-0444 §2.2). *)
        | Uninitialized -> Ok (default_state ())
        | Available state -> Ok state
      in
      let* state = current in
      let next_state = f state in
      (* A closure that hands back the very state it received has nothing to
         commit: on an [Uninitialized] store this is what keeps a refused
         first upsert from pre-writing an empty goals.json. *)
      if next_state == state then Ok state
      else
        match write_state_result config next_state with
        | Ok () -> Ok next_state
        | Error detail -> Error (Persist_failed detail))

let transact_goal config ~goal_id f =
  Workspace_utils.with_file_lock config (goals_path config) (fun () ->
      let loaded : (goal * state, write_error) result =
        match load_source config with
        | Unavailable u -> Error (Store_unavailable u)
        | Uninitialized -> Error (Goal_not_found goal_id)
        | Available state ->
          (match find_goal_in state.goals goal_id with
           | None -> Error (Goal_not_found goal_id)
           | Some goal -> Ok (goal, state))
      in
      let* current, state = loaded in
      match f current with
      | Error detail -> Error (Rejected detail)
      | Ok (updated, result) ->
        if not (String.equal updated.id current.id) then
          Error (Rejected "goal transaction cannot replace goal identity")
        else if updated = current then Ok (current, result)
        else
          let now = Masc_domain.now_iso () in
          let updated = { updated with updated_at = now } in
          let next = { version = state.version + 1; updated_at = now;
                       goals = replace_goal state.goals updated } in
          (match write_state_result config next with
           | Ok () -> Ok (updated, result)
           | Error detail -> Error (Persist_failed detail)))

type conditional_update =
  | Goal_updated of goal
  | Goal_phase_mismatch of Goal_phase.t

let update_goal_if_phase config ~goal_id ~expected_phase f
    : (conditional_update, write_error) result =
  Workspace_utils.with_file_lock config (goals_path config)
    (fun () : (conditional_update, write_error) result ->
      match load_source config with
      | Unavailable u -> Error (Store_unavailable u)
      | Uninitialized -> Error (Goal_not_found goal_id)
      | Available state ->
        (match find_goal_in state.goals goal_id with
         | None -> Error (Goal_not_found goal_id)
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
           (match write_state_result config next_state with
            | Ok () -> Ok (Goal_updated updated_goal)
            | Error detail -> Error (Persist_failed detail))))

let delete_goal config ~goal_id : (delete_goal_outcome, delete_goal_error) result =
  Workspace_utils.with_file_lock config (goals_path config)
    (fun () : (delete_goal_outcome, delete_goal_error) result ->
      let deleted : (unit, delete_goal_error) result =
        match load_source config with
        | Unavailable u -> Error (Store_unavailable u)
        | Uninitialized -> Error (Unknown_goal "Goal not found")
        | Available state ->
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
            | Error msg -> Error (Persistence_failed msg))
      in
      match deleted with
      | Error _ as error -> error
      | Ok () ->
        (* Keep membership removal and link cleanup in the same Goal lock.
           Persistence remains two stores; a cleanup failure is reported explicitly. *)
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
           Ok (Deleted_with_orphaned_links warning)))

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

let list_goals_result config ?phase () : (goal list, unavailable) result =
  match load_source config with
  | Unavailable u -> Error u
  | Uninitialized -> Ok []
  | Available state ->
      Ok (state.goals
          |> List.filter (fun goal -> match phase with
              | None -> true
              | Some phase -> goal.phase = phase)
          |> sort_goals)

let blank_opt = function
  | None -> true
  | Some raw -> String.trim raw = ""

let upsert_goal config ?id ?title ?metric ?target_value ?due_date
    ?priority ?phase () =
  let is_new_goal = id = None in
  if is_new_goal && (title = None || title = Some "") then
    Error (Rejected "title required for new goal")
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
              match find_goal_in state.goals resolved_id with
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
                  let criterion_changed =
                    not (String.equal existing.title next_goal.title)
                    || not (Option.equal String.equal existing.metric next_goal.metric)
                    || not (Option.equal String.equal existing.target_value next_goal.target_value)
                  in
                  let next_goal =
                    if not criterion_changed then next_goal
                    else
                      let phase = match next_goal.phase with
                        | Goal_phase.Awaiting_confirmation | Goal_phase.Verifying | Goal_phase.Completed -> Goal_phase.Executing
                        | Goal_phase.Executing | Goal_phase.Dropped as phase -> phase
                      in
                      { next_goal with criterion_revision = Random_id.hex ~bytes:16;
                        phase; last_review_note = None; last_review_at = None }
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
                     state it received and [update_state] writes nothing; the
                     error is carried out via [refusal]. *)
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
                        criterion_revision = Random_id.hex ~bytes:16;
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
        | Error error -> Error error
        | Ok state ->
          (match !refusal with
           | Some msg -> Error (Rejected msg)
           | None ->
          (match find_goal_in state.goals resolved_id with
          | Some goal ->
              Ok (goal, if !was_created then `created else `updated)
          | None ->
              Error (Rejected "failed to save goal"))))

let compute_rollup goals =
  let count predicate =
    List_util.count_if predicate goals
  in
  {
    active_count = count (fun goal -> goal.phase = Goal_phase.Executing);
    verifying_count = count (fun goal -> goal.phase = Goal_phase.Verifying);
    awaiting_confirmation_count = count (fun goal -> goal.phase = Goal_phase.Awaiting_confirmation);
    done_count = count (fun goal -> goal.phase = Goal_phase.Completed);
    dropped_count = count (fun goal -> goal.phase = Goal_phase.Dropped);
  }
