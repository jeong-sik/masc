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

(* RFC-0234: a parsed-or-absent ledger load.

   [Fresh] = neither the primary ledger nor its [.last-good] mirror exists, so
   [default_state] is correct. [write_state] commits both files together, so an
   absent primary next to a parseable mirror means the primary was removed
   out-of-band rather than never written; that case yields [Loaded] from the
   mirror (and logs a warning) instead of [Fresh], because collapsing it to
   [default_state] lets the next [write_state] mirror an empty state over the
   only surviving copy.

   [Corrupt] = at least one of the two files exists and no state can be parsed
   from either; callers must NOT collapse this to [default_state] and must NOT
   overwrite the on-disk files, because the bytes may still hold schedule intent
   worth manual recovery. *)
type load_outcome =
  | Loaded of state
  | Fresh
  | Corrupt of
      { primary_err : string
      ; recovery_err : string option
      }

(* Raised by the read-only accessor [get_schedule] when ledger bytes exist on
   disk but yield no state. Read paths cannot silently return an empty list
   (that would hide operator data) and they have no [result] channel, so they
   fail loud. The mutating paths use [load] directly and refuse via
   [Corrupt_ledger] instead of raising, so they never overwrite those bytes. *)
exception
  Corrupt_ledger_exn of
    { primary_err : string
    ; recovery_err : string option
    }

let ( let* ) = Result.bind

(* [primary_err] states why the primary yielded no state (unparseable, or
   absent while a mirror file remains). [recovery_err] is [None] when no
   [.last-good] mirror exists and [Some _] when the mirror exists but yields no
   state. *)
let corrupt_message ~primary_err ~recovery_err =
  match recovery_err with
  | None ->
    Printf.sprintf
      "schedule ledger could not be loaded (primary: %s); no .last-good recovery \
       file exists"
      primary_err
  | Some recovery_err ->
    Printf.sprintf
      "schedule ledger could not be loaded (primary: %s; .last-good recovery: %s)"
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
    let* updated_at = Schedule_domain.float_field "updated_at" fields in
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

(* Probe result for the [.last-good] recovery mirror. An absent mirror and an
   unparseable mirror are kept apart because they lead to opposite outcomes when
   the primary is also absent: no mirror means an uninitialised store ([Fresh]),
   an unparseable mirror means corruption the operator must see ([Corrupt]). *)
type recovery_outcome =
  | Recovery_loaded of state
  | Recovery_absent
  | Recovery_unparseable of string

(* Parse the [.last-good] recovery file. [read_json_result] folds file-read
   failure and JSON failure into one [Error message]; a mirror that exists but
   yields no state is reported as [Recovery_unparseable] either way. *)
let load_recovery config : recovery_outcome =
  let recovery = recovery_path config in
  if Workspace_utils.path_exists config recovery then (
    match Workspace_utils.read_json_result config recovery with
    | Ok recovery_json ->
      (match state_of_yojson recovery_json with
       | Ok state -> Recovery_loaded state
       | Error parse_err -> Recovery_unparseable parse_err)
    | Error read_err -> Recovery_unparseable read_err)
  else
    Recovery_absent
;;

let absent_primary_message path =
  Printf.sprintf "primary ledger file does not exist: %s" path
;;

(* Probe result for the primary ledger. [Primary_absent] used to be an [if]
   above the recovery match rather than a constructor, which split one decision
   over two axes into two separate nested matches. The halves then drifted:
   recovering from the mirror logged a warning when the primary was absent and
   said nothing when the primary was corrupt — the more alarming of the two. *)
type primary_failure =
  | Primary_absent
  | Primary_unparseable of string

(* [read_json_result] folds file-read failure and JSON failure into one
   [Error message], so an existing-but-broken primary surfaces as
   [Primary_unparseable] rather than being silently swallowed. *)
let load_primary config : (state, primary_failure) Result.t =
  let path = schedules_path config in
  if not (Workspace_utils.path_exists config path)
  then Error Primary_absent
  else (
    match Workspace_utils.read_json_result config path with
    | Ok json ->
      (match state_of_yojson json with
       | Ok state -> Ok state
       | Error parse_err -> Error (Primary_unparseable parse_err))
    | Error read_err -> Error (Primary_unparseable read_err))
;;

let primary_failure_message ~path = function
  | Primary_absent -> absent_primary_message path
  | Primary_unparseable detail -> detail
;;

(* Total load that distinguishes an uninitialised store from a corrupt one and
   from a primary removed out-of-band. [read_json_result] folds file-read failure
   and parse failure into a single [Error message], so an existing-but-broken
   primary surfaces here rather than being silently swallowed.

   The absent-primary branch consults the [.last-good] mirror for the same reason
   the present-but-unparseable branch does: [write_state] writes both files, so
   the mirror is the surviving copy whenever the primary is removed after a
   successful commit. Reporting [Fresh] there would hand [default_state] to the
   callers below, and the next [write_state] would overwrite the mirror with it. *)
let load config : load_outcome =
  ensure_dirs config;
  let path = schedules_path config in
  (* The next [write_state] rewrites the primary from this state. The warning
     records that the state came from the mirror, so the repair is visible
     rather than silent — for either reason the primary was unusable. *)
  let recovered_from_mirror ~primary_err state =
    Log.Misc.warn
      "schedule_store: %s; loaded %d schedules and %d wakes from recovery \
       mirror %s"
      primary_err
      (List.length state.schedules)
      (List.length state.wakes)
      (recovery_path config);
    Loaded state
  in
  match load_primary config with
  | Ok state -> Loaded state
  | Error primary ->
    let primary_err = primary_failure_message ~path primary in
    (* The outcome depends on both probes, so both are matched together. The
       recovery axis is enumerated in full; the primary axis is collapsed only
       where the answer provably does not depend on it, because [primary_err]
       already carries the difference.

       The one cell where the primary axis does decide is [Recovery_absent]:
       no primary and no mirror is an uninitialised store ([Fresh]), while a
       broken primary and no mirror is corruption the operator must see. *)
    (match primary, load_recovery config with
     | (Primary_absent | Primary_unparseable _), Recovery_loaded state ->
       recovered_from_mirror ~primary_err state
     | Primary_absent, Recovery_absent -> Fresh
     | Primary_unparseable _, Recovery_absent ->
       Corrupt { primary_err; recovery_err = None }
     | (Primary_absent | Primary_unparseable _), Recovery_unparseable recovery_err
       -> Corrupt { primary_err; recovery_err = Some recovery_err })
;;

(* Read-only accessor used by [get_schedule]. [Fresh] yields the empty default,
   and [load] narrows [Fresh] to "neither the primary nor the [.last-good] mirror
   exists"; a primary removed out-of-band arrives here as [Loaded] from the
   mirror instead of as an empty state. [Corrupt] errors rather than returning an
   empty list, so a ledger that cannot be parsed is operator-visible instead of
   masquerading as "no schedules". Does not write to disk. *)
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
   [write_state]; this is what prevents an unparseable ledger from being
   overwritten with an empty default on the next write. [Fresh] means [load]
   found neither the primary nor the [.last-good] mirror, so [default_state] adds
   no data loss; a primary removed while the mirror survives arrives as [Loaded],
   and the write that follows restores the primary. *)
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

(* Terminal wake records are history, not state: the runner never reads a
   finished wake back, only [update_latest_running_wake] touches one, and it
   looks for a [Wake_running] row. Kept unbounded they grew to 6,534 records /
   5.3 MB against 64 schedules (measured 2026-08-29, 24 days of history — the
   history was 90x the state it annotated), and every mutation rewrites that
   whole file under the store lock. On 2026-08-28 two runner ticks died on it:

     schedule_runner: startup recovery crashed / tick crashed:
       Failed to acquire distributed lock for key: schedules.json
       (50 attempts exhausted)

   The bound is per schedule_id, not global, because a broken schedule
   out-writes a healthy one by two orders of magnitude. Three schedules alone
   held 3,757 of the 6,534 records after one four-hour incident; a global cap
   would have been spent entirely on them and evicted every other schedule's
   history — exactly the record an operator needs to tell a broken schedule
   from a quiet one. *)
let terminal_wakes_retained_per_schedule = 32

let is_running_wake (wake : Schedule_domain.wake_record) =
  match wake.Schedule_domain.status with
  | Schedule_contract_values.Wake_running -> true
  | Schedule_contract_values.Wake_succeeded | Schedule_contract_values.Wake_failed -> false
;;

(* A running wake is live only while something can still settle it.
   [cancel_request] refuses to cancel a Running schedule and the settle
   paths ([accept_running] and its failure twin) only move a Running
   request, so the moment a schedule lands in a terminal state its
   still-[Wake_running] rows are orphaned: no runner will ever return for
   them, yet [is_running_wake] kept classifying them as live state. That is
   how a cancelled schedule's wake rows survived every prune (observed
   2026-08-25, sched-0f061d3a: rows retained across restarts and builds).
   A wake with no schedule row at all is the same fact one step earlier --
   the owner left the store. Fold both into the terminal side below so the
   per-schedule retention cap, not eternity, bounds them. *)
let wake_is_settleable ~schedules (wake : Schedule_domain.wake_record) =
  match
    List.find_opt
      (fun (request : Schedule_domain.schedule_request) ->
         String.equal
           request.Schedule_domain.schedule_id
           wake.Schedule_domain.schedule_id)
      schedules
  with
  | None -> false
  | Some { Schedule_domain.status = Scheduled | Due | Running; _ } -> true
  | Some { Schedule_domain.status = Succeeded | Failed | Cancelled | Expired; _ } -> false
;;

let settle_running_wake ~now ~reason (wake : wake_record) =
  { wake with
    status = Wake_failed
  ; finished_at = Some now
  ; error = Some reason
  }
;;

(* Disposition at the cancel boundary: when a schedule lands in Cancelled,
   its in-flight [Wake_running] rows can never be settled by the runner that
   was handed them -- no future occurrence will ever consume them (task-370
   live evidence: 17 cancelled rows held awaiting_ack up to 22.8 days across
   four restarts and three builds). Terminating the wake rows at the cancel
   boundary closes that infinite retain, while [detail] stays intact so the
   queue-evidence projection keeps reporting the receipt (and its
   awaiting_ack occurrence_status) it needs for [retained_terminal_wake].
   [error] records the disposition origin; the per-schedule terminal
   retention cap then bounds the history. *)
let settle_wakes_for_cancelled_schedule ~now wakes ~schedule_id =
  List.map
    (fun (wake : wake_record) ->
       if
         String.equal wake.Schedule_domain.schedule_id schedule_id
         && wake.status = Wake_running
       then
         settle_running_wake
           ~now
           ~reason:"cancelled schedule settles its in-flight wake"
           wake
       else wake)
    wakes
;;

(* In-flight wakes are never dropped as running rows: they are live state
   the runner settles. A running row whose schedule can no longer settle it
   (cancelled, expired, succeeded, failed, or the schedule row itself gone)
   is disposed into a terminal row here -- same boundary argument as cancel,
   because no runner will ever arrive to claim it. [detail] survives so the
   projection keeps its receipt; [error] names the origin. Only terminal
   rows are trimmed, newest first within each schedule. *)
let prune_wakes ~now ~schedules wakes =
  let running, terminal =
    List.partition
      (fun wake -> is_running_wake wake)
      wakes
  in
  let live, to_dispose =
    List.partition
      (fun wake -> wake_is_settleable ~schedules wake)
      running
  in
  let dispositions =
    List.map
      (fun wake ->
         settle_running_wake
           ~now
           ~reason:"schedule left running; wake disposed at store sweep"
           wake)
      to_dispose
  in
  let terminal' = dispositions @ terminal in
  let newest_first =
    List.stable_sort
      (fun (left : Schedule_domain.wake_record) (right : Schedule_domain.wake_record) ->
         Float.compare right.Schedule_domain.started_at left.Schedule_domain.started_at)
      terminal'
  in
  let kept_per_schedule : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let retained =
    List.filter
      (fun (wake : Schedule_domain.wake_record) ->
         let schedule_id = wake.Schedule_domain.schedule_id in
         let kept = Option.value (Hashtbl.find_opt kept_per_schedule schedule_id) ~default:0 in
         if kept < terminal_wakes_retained_per_schedule
         then (
           Hashtbl.replace kept_per_schedule schedule_id (kept + 1);
           true)
         else false)
      newest_first
  in
  live @ retained
;;

let bump_state state ~schedules ~wakes =
  let stamp = now () in
  { version = state.version + 1
  ; updated_at = stamp
  ; schedules
  ; wakes = prune_wakes ~now:stamp ~schedules wakes
  }
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

let wakes_for_schedule_instance state ~schedule_instance_id ~schedule_id =
  List.filter
    (fun (wake : wake_record) ->
       String.equal wake.schedule_instance_id schedule_instance_id
       && String.equal wake.schedule_id schedule_id)
    state.wakes
;;

let last_wake_for_schedule_instance state ~schedule_instance_id ~schedule_id =
  match wakes_for_schedule_instance state ~schedule_instance_id ~schedule_id with
  | wake :: _ -> Some wake
  | [] -> None
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
    | Due | Running | Succeeded | Failed | Cancelled | Expired ->
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

let update_request config (request : Schedule_domain.schedule_request) =
  Workspace_utils.with_file_lock config (schedules_path config) (fun () ->
    let* state = load_for_mutation config in
    match find_schedule state request.schedule_id with
    | None -> Error Schedule_not_found
    | Some current ->
      (match current.status with
       | Scheduled | Due ->
         let* () = validate_initial_request request in
         let schedules = replace_schedule state.schedules request in
         let next_state = bump_state state ~schedules ~wakes:state.wakes in
         let* () = write_state config next_state in
         Ok request
       | Running | Succeeded | Failed | Cancelled | Expired ->
         Error
           (Invalid_status_transition
              "only scheduled or due requests can be modified")))
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
        (* Disposition at the cancel boundary: settle this schedule's
           in-flight wake rows here rather than sweeping them later, so the
           awaiting_ack retain cannot outlive the cancel (22.8-day live
           evidence). [bump_state] then sees finished rows, not orphaned
           running ones. *)
        let wakes =
          settle_wakes_for_cancelled_schedule ~now:(now ()) state.wakes ~schedule_id
        in
        let next_state =
          bump_state state ~schedules ~wakes
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

let start_due_candidate ?started_at config ~now ~schedule_id =
  (* [now] is the runner tick that judged the candidate due; [started_at] is
     the moment this attempt actually began. They differ by however long the
     tick spent before reaching this schedule, and a wake stamped with the
     tick time reports that delay as zero. *)
  let started_at = Option.value started_at ~default:now in
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
        let wakes = make_wake_record ~now:started_at request :: state.wakes in
        let next_state = bump_state state ~schedules ~wakes in
        let* () = write_state config next_state in
        Ok updated)
;;

let accept_running ?finished_at config ~now ~schedule_id ?detail () =
  (* [now] anchors the next occurrence; [finished_at] stamps the wake. The
     two are one value only when the caller has no clock of its own. *)
  let finished_at = Option.value finished_at ~default:now in
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
               ; finished_at = Some finished_at
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
      (* Already terminal: nothing to cancel, and no error to raise. *)
      | ({ status = Succeeded | Failed | Cancelled | Expired; _ } as request) :: rest ->
        cancel (request :: schedules) changed rest
    in
    let* schedules, changed = cancel [] false state.schedules in
    if changed
    then
      (* Disposition at the cancel boundary: the matched schedules just
         landed in Cancelled, so their in-flight wake rows are settled
         here -- same boundary, same argument as [cancel_request]. *)
      let wakes =
        List.fold_left
          (fun wakes (request : schedule_request) ->
             if should_cancel request then
               settle_wakes_for_cancelled_schedule
                 ~now:(now ())
                 wakes
                 ~schedule_id:request.schedule_id
             else wakes)
          state.wakes
          schedules
      in
      write_state config (bump_state state ~schedules ~wakes)
    else Ok ())
;;

let fail_running ?finished_at config ~now ~schedule_id ~error =
  let finished_at = Option.value finished_at ~default:now in
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
               ; finished_at = Some finished_at
               ; detail = None
               ; error = Some error
               })
        in
        let next_state = bump_state state ~schedules ~wakes in
        let* () = write_state config next_state in
        Ok updated)
;;

let retry_running ?finished_at config ~now ~schedule_id ~reason =
  let finished_at = Option.value finished_at ~default:now in
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
            (fail_wake_for_recovery ~now:finished_at ~reason)
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

let fail_due_candidate ?attempted_at config ~now ~schedule_id ~error =
  (* The consumer refused the payload before any work began, so the attempt
     starts and ends at the same instant: [attempted_at] (default [now]). *)
  let attempted_at = Option.value attempted_at ~default:now in
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
          { (make_wake_record ~now:attempted_at request) with
            status = Wake_failed
          ; finished_at = Some attempted_at
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
