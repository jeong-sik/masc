open Schedule_domain

type state =
  { version : int
  ; updated_at : float
  ; schedules : Schedule_domain.schedule_request list
  ; wakes : Schedule_domain.wake_record list
  }

type store_error =
  | Schedule_already_exists
  | Schedule_not_found
  | Invalid_initial_status of string
  | Invalid_status_transition of string
  | Schedule_not_due_candidate
  | Schedule_not_running
  | Persistence_failed of string
  | Corrupt_ledger of
      { primary_err : string
      ; recovery_err : string option
      }

type running_recovery_reason =
  | Retryable_dispatch_failure of string
  | Interrupted_by_process_restart

type read_error =
  | Corrupt_read_ledger of
      { primary_err : string
      ; recovery_err : string option
      }

(* RFC-0234: a parsed-or-absent ledger load. [Fresh] = the file is legitimately
   absent (empty store, [default_state] is correct). [Corrupt] = the file is
   present but neither it nor the [.last-good] recovery file parses; callers must
   NOT collapse this to [default_state] and must NOT overwrite the on-disk file,
   because the bytes may still hold schedule intent worth manual recovery. *)
type load_outcome =
  | Loaded of state
  | Fresh
  | Corrupt of
      { primary_err : string
      ; recovery_err : string option
      }

(* Raised by the read-only accessor [get_schedule] on a
   corrupt-but-present ledger. Read paths cannot silently return an empty list
   (that would hide operator data) and they have no [result] channel, so they
   fail loud. The mutating paths use [load] directly and refuse via
   [Corrupt_ledger] instead of raising, so they never overwrite the file. *)
exception
  Corrupt_ledger_exn of
    { primary_err : string
    ; recovery_err : string option
    }

let ( let* ) = Result.bind

let corrupt_message ~primary_err ~recovery_err =
  match recovery_err with
  | None ->
    Printf.sprintf
      "schedule ledger is present but unparseable (primary: %s); no .last-good \
       recovery file exists"
      primary_err
  | Some recovery_err ->
    Printf.sprintf
      "schedule ledger is present but unparseable (primary: %s; .last-good \
       recovery: %s)"
      primary_err recovery_err
;;

let store_error_to_string = function
  | Schedule_already_exists -> "schedule already exists"
  | Schedule_not_found -> "schedule not found"
  | Invalid_initial_status reason -> "invalid initial schedule status: " ^ reason
  | Invalid_status_transition reason -> "invalid schedule status transition: " ^ reason
  | Schedule_not_due_candidate -> "schedule is not due"
  | Schedule_not_running -> "schedule is not running"
  | Persistence_failed msg -> "schedule persistence failed: " ^ msg
  | Corrupt_ledger { primary_err; recovery_err } ->
    corrupt_message ~primary_err ~recovery_err
;;

let running_recovery_reason_to_string = function
  | Retryable_dispatch_failure detail ->
    "retryable schedule dispatch failure: " ^ detail
  | Interrupted_by_process_restart ->
    "schedule wake interrupted by process restart"
;;

let read_error_to_string = function
  | Corrupt_read_ledger { primary_err; recovery_err } ->
    corrupt_message ~primary_err ~recovery_err
;;

(* NDT-OK: store boundary timestamp for projection metadata; replay uses the
   persisted [updated_at] value instead of recomputing it. *)
let now () = Unix.gettimeofday ()

let schedules_path config =
  Filename.concat (Workspace_utils.masc_dir config) "schedules.json"
;;

let recovery_path config = schedules_path config ^ ".last-good"

let ensure_dirs config = Workspace_utils.mkdir_p (Workspace_utils.masc_dir config)

let default_state () =
  { version = 1; updated_at = now (); schedules = []; wakes = [] }
;;

let state_to_yojson (state : state) =
  `Assoc
    [ "version", `Int state.version
    ; "updated_at", `Float state.updated_at
    ; ( "schedules"
      , `List (List.map Schedule_domain.schedule_request_to_yojson state.schedules)
      )
    ; ( "wakes"
      , `List
          (List.map Schedule_domain.wake_record_to_yojson state.wakes) )
    ]
;;

let int_field name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some _ -> Error ("expected int field: " ^ name)
  | None -> Error ("missing field: " ^ name)
;;

let float_field name fields =
  match List.assoc_opt name fields with
  | Some (`Float value) -> Ok value
  | Some (`Int value) -> Ok (float_of_int value)
  | Some _ -> Error ("expected float field: " ^ name)
  | None -> Error ("missing field: " ^ name)
;;

let list_field name fields =
  match List.assoc_opt name fields with
  | Some (`List value) -> Ok value
  | Some _ -> Error ("expected list field: " ^ name)
  | None -> Error ("missing field: " ^ name)
;;

let collect_results parse rows =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | row :: rest ->
      let* value = parse row in
      loop (value :: acc) rest
  in
  loop [] rows
;;

let state_of_yojson = function
  | `Assoc fields ->
    let* version = int_field "version" fields in
    let* updated_at = float_field "updated_at" fields in
    let* schedules_json = list_field "schedules" fields in
    let* wakes_json = list_field "wakes" fields in
    let* schedules =
      collect_results Schedule_domain.schedule_request_of_yojson schedules_json
    in
    let* wakes =
      collect_results Schedule_domain.wake_record_of_yojson wakes_json
    in
    Ok { version; updated_at; schedules; wakes }
  | json -> Error ("state_of_yojson: " ^ Yojson.Safe.to_string json)
;;

(* Parse the [.last-good] recovery file. Returns [Ok state] on a clean parse, or
   [Error message] describing why recovery is unavailable (absent or unparseable). *)
let load_recovery config =
  let recovery = recovery_path config in
  if Workspace_utils.path_exists config recovery then
    match Workspace_utils.read_json_result config recovery with
    | Ok recovery_json -> state_of_yojson recovery_json
    | Error read_err -> Error read_err
  else
    Error "no .last-good recovery file"
;;

(* Total load that distinguishes a fresh (absent) ledger from a corrupt
   (present-but-unparseable) one. [read_json_result] folds file-read failure and
   parse failure into a single [Error message], so an existing-but-broken primary
   surfaces here rather than being silently swallowed. *)
let load config : load_outcome =
  ensure_dirs config;
  let path = schedules_path config in
  if not (Workspace_utils.path_exists config path) then
    Fresh
  else (
    let primary =
      match Workspace_utils.read_json_result config path with
      | Ok json -> state_of_yojson json
      | Error read_err -> Error read_err
    in
    match primary with
    | Ok state -> Loaded state
    | Error primary_err ->
      (match load_recovery config with
       | Ok state -> Loaded state
       | Error recovery_err ->
         Corrupt { primary_err; recovery_err = Some recovery_err }))
;;

(* Read-only accessor used by [get_schedule]. [Fresh] yields the
   empty default (correct for an uninitialised store); [Corrupt] raises rather
   than returning an empty list, so a corrupt ledger is operator-visible instead
   of masquerading as "no schedules". Does not write to disk. *)
let read_state_result config =
  match load config with
  | Loaded state -> Ok state
  | Fresh -> Ok (default_state ())
  | Corrupt { primary_err; recovery_err } ->
    Error (Corrupt_read_ledger { primary_err; recovery_err })
;;

let read_state config =
  match read_state_result config with
  | Ok state -> state
  | Error (Corrupt_read_ledger { primary_err; recovery_err }) ->
    raise (Corrupt_ledger_exn { primary_err; recovery_err })
;;

(* Resolve the current state for a mutation. [Corrupt] is refused as a typed
   [Corrupt_ledger] error so the mutating function aborts BEFORE calling
   [write_state]; this is what prevents the corrupt-but-present ledger from being
   overwritten with an empty default on the next write. *)
let load_for_mutation config : (state, store_error) result =
  match load config with
  | Loaded state -> Ok state
  | Fresh -> Ok (default_state ())
  | Corrupt { primary_err; recovery_err } ->
    Error (Corrupt_ledger { primary_err; recovery_err })
;;

(* Write the primary ledger, then mirror to [.last-good]. The [.last-good] file
   is written only here, immediately after a fully-formed in-memory [state] is
   serialised, so it can only ever hold a parseable snapshot. The previous
   recovery path was useless because corruption arrived on disk out-of-band
   (e.g. schema evolution / partial write of the primary), never through this
   serialise step. Refusing to read a corrupt primary into [state] (above) means
   we never round-trip corruption through here either. *)
let write_state config state =
  ensure_dirs config;
  let json = state_to_yojson state in
  let* () =
    Workspace_utils.write_json_result config (schedules_path config) json
    |> Result.map_error (fun msg -> Persistence_failed msg)
  in
  (match Workspace_utils.write_json_result config (recovery_path config) json with
   | Ok () -> ()
   | Error msg ->
     Log.Misc.warn
       "schedule_store: primary ledger committed; recovery mirror write failed for %s: %s"
       (recovery_path config)
       msg);
  Ok ()
;;

let bump_state state ~schedules ~wakes =
  { version = state.version + 1; updated_at = now (); schedules; wakes }
;;

let find_schedule state schedule_id =
  List.find_opt
    (fun (request : Schedule_domain.schedule_request) ->
      String.equal request.schedule_id schedule_id)
    state.schedules
;;

let replace_schedule schedules (updated : schedule_request) =
  List.map
    (fun (request : schedule_request) ->
      if String.equal request.schedule_id updated.schedule_id then
        updated
      else
        request)
    schedules
;;

let is_due_wake_candidate (request : schedule_request) =
  match request.status with
  | Due -> true
  | Scheduled | Running | Succeeded | Failed | Cancelled | Expired ->
    false
;;

let get_schedule config ~schedule_id = find_schedule (read_state config) schedule_id

let make_wake_record ~now (request : schedule_request) =
  { schedule_instance_id = request.schedule_instance_id
  ; schedule_id = request.schedule_id
  ; started_at = now
  ; finished_at = None
  ; due_at = request.due_at
  ; payload_digest = Schedule_domain.payload_digest request.payload
  ; status = Wake_running
  ; detail = None
  ; error = None
  }
;;

let last_wake_for_schedule_instance state ~schedule_instance_id ~schedule_id =
  List.find_opt
    (fun (wake : wake_record) ->
       String.equal wake.schedule_instance_id schedule_instance_id
       && String.equal wake.schedule_id schedule_id)
    state.wakes
;;

let update_latest_running_wake wakes ~schedule_id update =
  let rec loop acc = function
    | [] ->
      Error
        (Invalid_status_transition
           "running schedule has no matching running wake record")
    | (wake : wake_record) :: rest
      when String.equal wake.schedule_id schedule_id
           && wake.status = Wake_running ->
      Ok (List.rev_append acc (update wake :: rest))
    | wake :: rest -> loop (wake :: acc) rest
  in
  loop [] wakes
;;

let fail_wake_for_recovery ~now ~reason wake =
  { wake with
    status = Wake_failed
  ; finished_at = Some now
  ; detail = None
  ; error = Some (running_recovery_reason_to_string reason)
  }
;;

let validate_initial_request (request : Schedule_domain.schedule_request) =
  if Schedule_domain.is_terminal request.status then
    Error (Invalid_initial_status "terminal requests cannot be inserted")
  else
    match request.status with
    | Scheduled -> Ok ()
    | _ ->
      Error
        (Invalid_initial_status
           "new requests must start scheduled")
;;

let insert_request config (request : Schedule_domain.schedule_request) =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let* state = load_for_mutation config in
    match find_schedule state request.schedule_id with
    | Some _ -> Error Schedule_already_exists
    | None ->
      let* () = validate_initial_request request in
      let schedules = request :: state.schedules in
      let next_state =
        bump_state state ~schedules ~wakes:state.wakes
      in
      let* () = write_state config next_state in
      Ok request)
;;

let cancel_request config ~schedule_id =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let* state = load_for_mutation config in
    match find_schedule state schedule_id with
    | None -> Error Schedule_not_found
    | Some request ->
      if Schedule_domain.is_terminal request.status || request.status = Running
      then
        Error
          (Invalid_status_transition
             "only scheduled or due requests can be cancelled")
      else
        let updated_request =
          { request with Schedule_domain.status = Schedule_domain.Cancelled }
        in
        let schedules = replace_schedule state.schedules updated_request in
        let next_state =
          bump_state state ~schedules ~wakes:state.wakes
        in
        let* () = write_state config next_state in
        Ok updated_request)
;;

let refresh_due config ~now =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let* state = load_for_mutation config in
    let schedules, changed =
      List.fold_right
        (fun request (schedules, changed) ->
          let updated = Schedule_domain.mark_due ~now request in
          let changed =
            if updated.Schedule_domain.status <> request.Schedule_domain.status
            then changed + 1
            else changed
          in
          updated :: schedules, changed)
        state.schedules
        ([], 0)
    in
    if changed = 0 then
      Ok (state, 0)
    else (
      let next_state =
        bump_state state ~schedules ~wakes:state.wakes
      in
      let* () = write_state config next_state in
      Ok (next_state, changed)))
;;

let reschedule_due_recurring config ~now ~schedule_ids =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let* state = load_for_mutation config in
    let schedules, changed =
      List.fold_right
        (fun (request : schedule_request) (schedules, changed) ->
          if
            not
              (List.exists
                 (String.equal request.schedule_id)
                 schedule_ids)
          then
            request :: schedules, changed
          else
            match Schedule_domain.reschedule_after_due_signal ~now request with
            | None -> request :: schedules, changed
            | Some updated -> updated :: schedules, changed + 1)
        state.schedules
        ([], 0)
    in
    if changed = 0 then
      Ok (state, 0)
    else (
      let next_state =
        bump_state state ~schedules ~wakes:state.wakes
      in
      let* () = write_state config next_state in
      Ok (next_state, changed)))
;;

let start_due_candidate config ~now ~schedule_id =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let* state = load_for_mutation config in
    match find_schedule state schedule_id with
    | None -> Error Schedule_not_found
    | Some request ->
      if not (is_due_wake_candidate request) then
        Error Schedule_not_due_candidate
      else
        let updated = { request with status = Running } in
        let schedules = replace_schedule state.schedules updated in
        let wakes = make_wake_record ~now request :: state.wakes in
        let next_state = bump_state state ~schedules ~wakes in
        let* () = write_state config next_state in
        Ok updated)
;;

let accept_running config ~now ~schedule_id ?detail () =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let* state = load_for_mutation config in
    match find_schedule state schedule_id with
    | None -> Error Schedule_not_found
    | Some request ->
      if request.status <> Running
      then (
        match
          last_wake_for_schedule_instance
            state
            ~schedule_instance_id:request.schedule_instance_id
            ~schedule_id
        with
        | Some { status = (Wake_succeeded | Wake_failed); _ } ->
          Ok request
        | Some { status = Wake_running; _ } | None ->
          Error Schedule_not_running)
      else
        let updated =
          match Schedule_domain.next_due_after ~now request with
          | Some due_at -> { request with status = Scheduled; due_at }
          | None -> { request with status = Succeeded }
        in
        let schedules = replace_schedule state.schedules updated in
        let* wakes =
          update_latest_running_wake state.wakes ~schedule_id
            (fun wake ->
               { wake with
                 status = Wake_succeeded
               ; finished_at = Some now
               ; detail
               ; error = None
               })
        in
        let next_state = bump_state state ~schedules ~wakes in
        let* () = write_state config next_state in
        Ok updated)
;;

let cancel_matching config ~should_cancel =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let* state = load_for_mutation config in
    let rec cancel schedules changed = function
      | [] -> Ok (List.rev schedules, changed)
      | (request : schedule_request) :: rest when not (should_cancel request) ->
        cancel (request :: schedules) changed rest
      | ({ status = (Scheduled | Due); _ } as request) :: rest ->
        cancel ({ request with status = Cancelled } :: schedules) true rest
      | ({ status = Running; _ } as request) :: _ ->
        Error
          (Invalid_status_transition
             (Printf.sprintf
                "cannot cancel running schedule %s while retiring its consumer"
                request.schedule_id))
      | request :: rest -> cancel (request :: schedules) changed rest
    in
    let* schedules, changed = cancel [] false state.schedules in
    if changed
    then
      write_state
        config
        (bump_state state ~schedules ~wakes:state.wakes)
    else Ok ())
;;

let fail_running config ~now ~schedule_id ~error =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let* state = load_for_mutation config in
    match find_schedule state schedule_id with
    | None -> Error Schedule_not_found
    | Some request ->
      if request.status <> Running then
        Error Schedule_not_running
      else
        let updated = { request with status = Failed } in
        let schedules = replace_schedule state.schedules updated in
        let* wakes =
          update_latest_running_wake state.wakes ~schedule_id
            (fun wake ->
               { wake with
                 status = Wake_failed
               ; finished_at = Some now
               ; detail = None
               ; error = Some error
               })
        in
        let next_state = bump_state state ~schedules ~wakes in
        let* () = write_state config next_state in
        Ok updated)
;;

let retry_running config ~now ~schedule_id ~reason =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let* state = load_for_mutation config in
    match find_schedule state schedule_id with
    | None -> Error Schedule_not_found
    | Some request ->
      if request.status <> Running then
        Error Schedule_not_running
      else
        let updated = { request with status = Due } in
        let schedules = replace_schedule state.schedules updated in
        let* wakes =
          update_latest_running_wake state.wakes ~schedule_id
            (fail_wake_for_recovery ~now ~reason)
        in
        let next_state = bump_state state ~schedules ~wakes in
        let* () = write_state config next_state in
        Ok updated)
;;

let recover_running_on_startup config ~now =
  let reason = Interrupted_by_process_restart in
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let* state = load_for_mutation config in
    let rec recover schedules_rev wakes recovered = function
      | [] -> Ok (List.rev schedules_rev, wakes, recovered)
      | (request : schedule_request) :: rest ->
        (match request.status with
         | Running ->
           (match
              List.find_opt
                (fun (wake : wake_record) ->
                   String.equal
                     wake.schedule_instance_id
                     request.schedule_instance_id
                   && String.equal wake.schedule_id request.schedule_id
                   && Float.equal wake.due_at request.due_at
                   && String.equal
                        wake.payload_digest
                        (Schedule_domain.payload_digest request.payload))
                wakes
            with
            | Some { status = Wake_running; _ } ->
              let* wakes =
                update_latest_running_wake wakes
                  ~schedule_id:request.schedule_id
                  (fail_wake_for_recovery ~now ~reason)
              in
              recover
                ({ request with status = Due } :: schedules_rev)
                wakes
                (recovered + 1)
                rest
            | Some { status = (Wake_succeeded | Wake_failed); _ }
            | None ->
              Error
                (Invalid_status_transition
                   "running schedule has no active wake record"))
         | Scheduled | Due | Succeeded | Failed | Cancelled | Expired ->
           recover (request :: schedules_rev) wakes recovered rest)
    in
    let* schedules, wakes, recovered =
      recover [] state.wakes 0 state.schedules
    in
    if recovered = 0 then
      Ok (state, 0)
    else
      let next_state = bump_state state ~schedules ~wakes in
      let* () = write_state config next_state in
      Ok (next_state, recovered))
;;

let fail_due_candidate config ~now ~schedule_id ~error =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let* state = load_for_mutation config in
    match find_schedule state schedule_id with
    | None -> Error Schedule_not_found
    | Some request ->
      if not (is_due_wake_candidate request) then
        Error Schedule_not_due_candidate
      else
        let updated = { request with status = Failed } in
        let wake =
          { (make_wake_record ~now request) with
            status = Wake_failed
          ; finished_at = Some now
          ; error = Some error
          }
        in
        let schedules = replace_schedule state.schedules updated in
        let wakes = wake :: state.wakes in
        let next_state = bump_state state ~schedules ~wakes in
        let* () = write_state config next_state in
        Ok updated)
;;

let prune_completed config =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let* state = load_for_mutation config in
    let before_count = List.length state.schedules in
    let schedules =
      List.filter
        (fun (request : schedule_request) ->
           match request.status with
           | Scheduled | Due | Running -> true
           | Succeeded | Failed | Cancelled | Expired -> false)
        state.schedules
    in
    let after_count = List.length schedules in
    let pruned_count = before_count - after_count in
    let remaining_ids =
      List.map (fun (r : schedule_request) -> r.schedule_id) schedules
    in
    let wakes =
      List.filter
        (fun (wake : wake_record) ->
           List.mem wake.schedule_id remaining_ids)
        state.wakes
    in
    let next_state = bump_state state ~schedules ~wakes in
    let* () = write_state config next_state in
    Ok (next_state, pruned_count))
;;

let due_wake_candidates state =
  state.schedules
  |> List.filter is_due_wake_candidate
;;
