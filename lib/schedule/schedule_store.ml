open Schedule_domain

type state =
  { version : int
  ; updated_at : float
  ; schedules : Schedule_domain.schedule_request list
  ; wakes : Schedule_domain.wake_record list
  ; notes : Schedule_domain.schedule_note list
  }

type attempted_transition =
  | Modify_schedule
  | Cancel_schedule
  | Cancel_for_consumer_retirement

type mutation_authority =
  | Operator_authority
  | Named_authority of
      { name : string
      ; wake_keeper_name : Schedule_domain.schedule_request -> string option
      }

type store_error =
  | Schedule_already_exists
  | Schedule_not_found
  | Not_schedule_owner of
      { schedule_id : string
      ; caller : string
      ; scheduled_by_id : string
      ; wake_target : string option
      }
  | Invalid_initial_status of string
  | Transition_refused of
      { schedule_id : string
      ; current : Schedule_domain.schedule_status
      ; attempted : attempted_transition
      ; last_wake : Schedule_domain.wake_record option
      }
  | Changed_due_already_past of
      { schedule_id : string
      ; stored_due_at : float
      ; due_at : float
      ; now : float
      }
  | Interval_below_runner_tick of
      { schedule_id : string
      ; below : Schedule_domain.interval_below_runner_tick
      }
  | Running_wake_absent of { schedule_id : string }
  | Running_wake_settled of
      { schedule_id : string
      ; wake : Schedule_domain.wake_record
      }
  | Schedule_not_due_candidate
  | Running_attempt_superseded of { schedule_id : string }
  | Running_attempt_unavailable of { schedule_id : string; reason : string }
  | Stale_instance of
      { schedule_id : string
      ; expected : string
      ; found : string
      }
  | Persistence_failed of string
  | Corrupt_ledger of
      { primary_err : string
      ; recovery_err : string option
      }

type failure_scope = Occurrence_failure | Schedule_failure

type running_recovery_reason =
  | Retryable_dispatch_failure of string
  | Interrupted_by_process_restart

type attempt_scope =
  { root : string
  ; device : int
  ; inode : int
  ; backend : Workspace_utils.storage_backend
  }

type running_attempt =
  { original : Schedule_domain.schedule_request
  ; attempt_id : Schedule_domain.wake_attempt_id
  ; scope : attempt_scope
  }

type started_dispatch =
  { request : Schedule_domain.schedule_request
  ; attempt : running_attempt
  }

type read_error =
  | Corrupt_read_ledger of
      { primary_err : string
      ; recovery_err : string option
      }

type recovery_cause = Primary_missing | Primary_unusable

type read_source =
  | Uninitialized
  | Primary_ledger
  | Recovery_mirror of recovery_cause

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
  | Loaded of state * read_source
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

open Result.Syntax

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

let attempted_transition_to_string = function
  | Modify_schedule -> "modify"
  | Cancel_schedule -> "cancel"
  | Cancel_for_consumer_retirement -> "cancel_for_consumer_retirement"
;;

let store_error_to_string = function
  | Schedule_already_exists -> "schedule already exists"
  | Schedule_not_found -> "schedule not found"
  | Not_schedule_owner { schedule_id; caller; scheduled_by_id; wake_target = _ } ->
    Printf.sprintf
      "schedule %s was scheduled by %s and would not wake %s; a caller \
       changes only the schedules it made or the ones that wake it"
      schedule_id scheduled_by_id caller
  | Invalid_initial_status reason -> "invalid initial schedule status: " ^ reason
  | Transition_refused { schedule_id; current; attempted; last_wake = _ } ->
    let current = Schedule_domain.schedule_status_to_string current in
    (match attempted with
     | Modify_schedule ->
       Printf.sprintf
         "schedule %s is %s; only scheduled or due requests can be modified"
         schedule_id
         current
     | Cancel_schedule ->
       Printf.sprintf
         "schedule %s is %s; only scheduled or due requests can be cancelled"
         schedule_id
         current
     | Cancel_for_consumer_retirement ->
       Printf.sprintf
         "schedule %s is %s; its consumer cannot be retired while that wake is \
          being delivered"
         schedule_id
         current)
  | Changed_due_already_past { schedule_id; stored_due_at; due_at; now } ->
    Printf.sprintf
      "schedule %s: due time %s replaces %s and is before now (%s); a changed due \
       time is due at or after the current second"
      schedule_id
      (Time_codec.rfc3339_of_unix due_at)
      (Time_codec.rfc3339_of_unix stored_due_at)
      (Time_codec.rfc3339_of_unix now)
  | Interval_below_runner_tick
      { schedule_id; below = { interval_sec; runner_tick_sec } } ->
    Printf.sprintf
      "schedule %s: recurrence.interval_sec %d is shorter than the schedule \
       runner tick (%gs); the runner would fire it once per tick, not every \
       %d seconds"
      schedule_id
      interval_sec
      runner_tick_sec
      interval_sec
  | Running_wake_absent { schedule_id } ->
    Printf.sprintf "running schedule %s has no wake record" schedule_id
  | Running_wake_settled { schedule_id; wake } ->
    Printf.sprintf
      "running schedule %s has no running wake; its newest wake already %s"
      schedule_id
      (Schedule_domain.wake_status_to_string wake.Schedule_domain.status)
  | Schedule_not_due_candidate -> "schedule is not due"
  | Running_attempt_superseded { schedule_id } ->
    Printf.sprintf "schedule %s running attempt was superseded" schedule_id
  | Running_attempt_unavailable { schedule_id; reason } ->
    Printf.sprintf "schedule %s running attempt authority unavailable: %s" schedule_id reason
  | Stale_instance { schedule_id; expected; found } ->
    Printf.sprintf
      "schedule %s is now instance %s; the update was built from instance %s"
      schedule_id
      found
      expected
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

let schedules_filename = "schedules.json"

let schedules_path config =
  Filename.concat (Workspace_utils.masc_dir config) schedules_filename
;;

let with_ledger_lock config f =
  Workspace_utils.with_file_lock config (schedules_path config) f
;;

let recovery_path config = schedules_path config ^ Common.recovery_mirror_suffix

let ensure_dirs config = Workspace_utils.mkdir_p (Workspace_utils.masc_dir config)

let default_state () =
  { version = 1
  ; updated_at = now ()
  ; schedules = []
  ; wakes = []
  ; notes = []
  }
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
    ; ( "notes"
      , `List (List.map Schedule_domain.schedule_note_to_yojson state.notes) )
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

module Schedule_id_map = Map.Make (String)
module Schedule_id_set = Set.Make (String)
module Attempt_id_set = Set.Make (String)

module Schedule_instance_key = struct
  type t = string * string

  let compare (id_a, inst_a) (id_b, inst_b) =
    let c = String.compare id_a id_b in
    if c <> 0 then c else String.compare inst_a inst_b
  ;;
end

module Schedule_instance_map = Map.Make (Schedule_instance_key)

let state_of_yojson = function
  | `Assoc fields ->
    let* version = int_field "version" fields in
    let* updated_at = Schedule_domain.float_field "updated_at" fields in
    let* schedules_json = list_field "schedules" fields in
    let* wakes_json = list_field "wakes" fields in
    let* notes_json =
      (* Back-compat: ledgers written before task-381 carry no [notes] list.
         Decode the absent field as an empty list rather than failing the whole
         state parse. *)
      match List.assoc_opt "notes" fields with
      | None -> Ok []
      | Some (`List value) -> Ok value
      | Some _ -> Error "expected list field: notes"
    in
    let* schedules =
      collect_results Schedule_domain.schedule_request_of_yojson schedules_json
    in
    let* wakes =
      collect_results Schedule_domain.wake_record_of_yojson wakes_json
    in
    let* () =
      let rec unique seen = function
        | [] -> Ok ()
        | (wake : wake_record) :: rest ->
          (match wake.attempt_identity with
           | Unidentified -> unique seen rest
           | Identified id ->
             let key = wake_attempt_id_to_string id in
             if Attempt_id_set.mem key seen
             then Error "duplicate wake attempt_id"
             else unique (Attempt_id_set.add key seen) rest)
      in
      unique Attempt_id_set.empty wakes
    in
    let* notes =
      collect_results Schedule_domain.schedule_note_of_yojson notes_json
    in
    Ok { version; updated_at; schedules; wakes; notes }
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

(* Parse the [.last-good] recovery file. A mirror that exists but yields no
   state — unreadable, unparsable, blank, or not a state — is reported as
   [Recovery_unparseable] either way. *)
let load_recovery config : recovery_outcome =
  match Workspace_utils.read_json_doc config (recovery_path config) with
  | Ok None -> Recovery_absent
  | Ok (Some recovery_json) ->
    (match state_of_yojson recovery_json with
     | Ok state -> Recovery_loaded state
     | Error parse_err -> Recovery_unparseable parse_err)
  | Error read_err ->
    Recovery_unparseable (Workspace_utils.json_doc_error_to_string read_err)
;;

let absent_primary_message path =
  Printf.sprintf "primary ledger file does not exist: %s" path
;;

(* Probe result for the primary ledger. [Primary_absent] is a constructor, not
   an [if] above the recovery match: the decision has two axes, and one match
   over both keeps the two halves from drifting apart. *)
type primary_failure =
  | Primary_absent
  | Primary_unparseable of string

(* An existing-but-broken primary — unreadable, unparsable, blank, or not a
   state — surfaces as [Primary_unparseable] rather than being silently
   swallowed; only a primary that does not exist is [Primary_absent]. *)
let decode_primary config path : (state, primary_failure) Result.t =
  match Workspace_utils.read_json_doc config path with
  | Ok None -> Error Primary_absent
  | Ok (Some json) ->
    (match state_of_yojson json with
     | Ok state -> Ok state
     | Error parse_err -> Error (Primary_unparseable parse_err))
  | Error read_err ->
    Error (Primary_unparseable (Workspace_utils.json_doc_error_to_string read_err))
;;

(* The decoded primary, kept with the file version it was read from. The
   ledger keeps terminal schedules until their retention passes and is
   several megabytes, and it is read far more often than it is written -- every Keeper's world
   observation, the dashboard and the schedule tools read all of it, a runner
   commit writes it -- so a reader of an unchanged file takes the state the
   last miss decoded. [write_state] keeps the state it wrote, so its own write
   is not a miss. A miss reads,
   parses and decodes as one job on the domain pool when one is installed. *)
let decoded_primary : state File_version_cache.t = File_version_cache.create ()

(* The Memory backend is authoritative over its local mirror. A mirror's
   inode/mtime cannot version backend state, nor distinguish two independent
   backend instances using the same workspace path. *)
let load_primary config : (state, primary_failure) Result.t =
  let path = schedules_path config in
  let decode () =
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () -> decode_primary config path) in
  match config.Workspace_utils.backend with
  | Workspace_utils.FileSystem _ -> File_version_cache.load decoded_primary path ~decode
  | Workspace_utils.Memory _ -> decode ()
;;

let primary_failure_message ~path = function
  | Primary_absent -> absent_primary_message path
  | Primary_unparseable detail -> detail
;;

(* Total load that distinguishes an uninitialised store from a corrupt one and
   from a primary removed out-of-band. An existing-but-broken primary surfaces
   here rather than being silently swallowed.

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
  let recovered_from_mirror ~primary_err ~cause state =
    Log.Misc.warn
      "schedule_store: %s; loaded %d schedules and %d wakes from recovery \
       mirror %s"
      primary_err
      (List.length state.schedules)
      (List.length state.wakes)
      (recovery_path config);
    Loaded (state, Recovery_mirror cause)
  in
  match load_primary config with
  | Ok state -> Loaded (state, Primary_ledger)
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
     | Primary_absent, Recovery_loaded state ->
       recovered_from_mirror ~primary_err ~cause:Primary_missing state
     | Primary_unparseable _, Recovery_loaded state ->
       recovered_from_mirror ~primary_err ~cause:Primary_unusable state
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
let read_state_observed config =
  match load config with
  | Loaded (state, source) -> Ok (state, source)
  | Fresh -> Ok (default_state (), Uninitialized)
  | Corrupt { primary_err; recovery_err } ->
    Error (Corrupt_read_ledger { primary_err; recovery_err })
;;

let read_state_result config =
  read_state_observed config |> Result.map fst
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
  | Loaded (state, _) -> Ok state
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
  (* One encoding serves both files, compact and on the pool. The ledger keeps
     every terminal schedule (4.3 MB, 1,250 of 1,272 rows, 2026-09-16), and
     encoding it pretty once per file was a 135-151 ms run on the scheduler
     domain each time: four of them within a second when a schedule fired.
     Yojson prints that document compact in 15 ms where the pretty printer
     takes 107 ms. *)
  (* The same job decodes the document it encodes. That state is what a
     reader of the written file decodes -- the strings are the UTF-8 repaired
     ones the bytes carry -- and [written_state] below keeps it, so a write
     does not make the next reader parse the whole ledger again. Parsing is
     the larger part of a read; this decode starts from the document already
     in hand. *)
  let* content, reread =
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
      let json = Safe_ops.sanitize_json_utf8 (state_to_yojson state) in
      Result.map
        (fun content -> content, state_of_yojson json)
        (Workspace_utils.encode_json_compact json))
    |> Result.map_error (fun msg -> Persistence_failed ("ledger encoding failed: " ^ msg))
  in
  let path = schedules_path config in
  let written = Workspace_utils.write_encoded_json_commit_result config path content in
  (* Every writer of the ledger holds its lock, and the FileSystem backend
     renames a new file into place, so after a write that landed the file at
     [path] is the bytes [reread] was decoded for. Anything else -- a write
     that failed and may or may not have landed, a Memory backend whose local
     file is a mirror, a state that does not decode from its own encoding --
     leaves the file a version nothing is kept for. *)
  (match written, reread, config.Workspace_utils.backend with
   | Ok { Workspace_utils.mirror_error = None }, Ok written_state, Workspace_utils.FileSystem _ ->
     File_version_cache.keep_written decoded_primary path written_state
   | (Ok _ | Error _), (Ok _ | Error _), (Workspace_utils.FileSystem _ | Workspace_utils.Memory _) ->
     File_version_cache.forget decoded_primary path);
  let* commit = written |> Result.map_error (fun msg -> Persistence_failed msg) in
  (* Memory's backend is authoritative. Its local mirror can fail after that
     commit; reporting failure then would tell the runner to retry a settlement
     whose schedule and wake have already changed. Memory is volatile: this
     success reports in-process authority, not persistence across restart.
     FileSystem publication failures remain errors. *)
  (match commit.Workspace_utils.mirror_error with
   | None -> ()
   | Some msg ->
     Log.Misc.warn
       "schedule_store: authoritative ledger committed; local mirror write failed for %s: %s"
       (schedules_path config)
       msg);
  (match Workspace_utils.write_encoded_json_result config (recovery_path config) content with
   | Ok () -> ()
   | Error msg ->
     Log.Misc.warn
       "schedule_store: primary ledger committed; recovery mirror write failed for %s: %s"
       (recovery_path config)
       msg);
  Ok ()
;;

let change_observer : (base_path:string -> unit) Atomic.t =
  Atomic.make (fun ~base_path:_ -> ())

let install_change_observer observer = Atomic.set change_observer observer

let replace_change_observer_if_current ~current ~replacement =
  Atomic.compare_and_set change_observer current replacement
;;

let notify_change_observer config =
  let base_path = config.Workspace_utils.base_path in
  let report exn =
    Log.Misc.warn "schedule_store: change observer failed for %s: %s"
      base_path (Printexc.to_string exn)
  in
  match (Atomic.get change_observer) ~base_path with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    (match Fs_compat.execution_context () with
     | Eio_fiber -> Eio.Fiber.check ()
     | Non_eio -> ());
    report exn
  | exception exn -> report exn
;;

(* A publication can fail after landing. Remember an attempted write under the
   lock, but notify only after releasing it: an observer may re-read the
   ledger. A no-op runner tick and a rejected mutation do not notify. *)
let with_observed_mutation config f =
  let attempted = ref false in
  let observed_write config state =
    attempted := true;
    write_state config state
  in
  let result =
    try
      Ok (Workspace_utils.with_file_lock config (schedules_path config)
            (fun () -> f observed_write))
    with exn -> Error (exn, Printexc.get_raw_backtrace ())
  in
  match result with
  | Ok value ->
    if !attempted then notify_change_observer config;
    value
  | Error (exn, backtrace) ->
    if !attempted then (
      match notify_change_observer config with
      | () -> ()
      | exception (Eio.Cancel.Cancelled _ as cancelled) ->
        (match exn with
         | Eio.Cancel.Cancelled _ -> ()
         | _ -> raise cancelled));
    Printexc.raise_with_backtrace exn backtrace
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
let settleable_schedule_ids (schedules : Schedule_domain.schedule_request list) =
  List.fold_left
    (fun (settleable, seen) (request : Schedule_domain.schedule_request) ->
       let id = request.Schedule_domain.schedule_id in
       if Schedule_id_set.mem id seen
       then settleable, seen
       else
         let seen = Schedule_id_set.add id seen in
         match request.Schedule_domain.status with
         | Scheduled | Due | Running -> Schedule_id_set.add id settleable, seen
         | Succeeded | Failed | Cancelled | Expired -> settleable, seen)
    (Schedule_id_set.empty, Schedule_id_set.empty)
    schedules
  |> fst
;;

let settle_running_wake ~now ~kind ~reason (wake : wake_record) =
  { wake with
    status = Wake_failed
  ; finished_at = Some now
  ; settlement_kind = Some kind
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
           ~kind:Cancelled_schedule
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
  let settleable_ids = settleable_schedule_ids schedules in
  let live, to_dispose =
    List.partition
      (fun (wake : Schedule_domain.wake_record) ->
         Schedule_id_set.mem wake.Schedule_domain.schedule_id settleable_ids)
      running
  in
  let dispositions =
    List.map
      (fun wake ->
         settle_running_wake
           ~now
           ~kind:Orphaned_attempt
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
  let _, retained_rev =
    List.fold_left
      (fun (kept_per_schedule, acc) (wake : Schedule_domain.wake_record) ->
         let schedule_id = wake.Schedule_domain.schedule_id in
         let kept =
           Option.value
             (Schedule_id_map.find_opt schedule_id kept_per_schedule)
             ~default:0
         in
         if kept < terminal_wakes_retained_per_schedule
         then
           ( Schedule_id_map.add schedule_id (kept + 1) kept_per_schedule
           , wake :: acc )
         else kept_per_schedule, acc)
      (Schedule_id_map.empty, [])
      newest_first
  in
  live @ List.rev retained_rev
;;

let bump_state state ~schedules ~wakes ~notes =
  let stamp = now () in
  { version = state.version + 1
  ; updated_at = stamp
  ; schedules
  ; wakes = prune_wakes ~now:stamp ~schedules wakes
  ; notes
  }
;;

(* When each schedule id last finished a wake, and when anything was last
   written about it. A note keeps its schedule: someone is still using it. *)
let ledger_times state =
  let keep table schedule_id time =
    match Schedule_id_map.find_opt schedule_id table with
    | Some seen when seen >= time -> table
    | Some _ | None -> Schedule_id_map.add schedule_id time table
  in
  let finished, written_about =
    List.fold_left
      (fun (finished, written_about) (wake : Schedule_domain.wake_record) ->
         match wake.Schedule_domain.finished_at with
         | None -> finished, written_about
         | Some finished_at ->
           let schedule_id = wake.Schedule_domain.schedule_id in
           ( keep finished schedule_id finished_at
           , keep written_about schedule_id finished_at ))
      (Schedule_id_map.empty, Schedule_id_map.empty)
      state.wakes
  in
  let written_about =
    List.fold_left
      (fun written_about (note : Schedule_domain.schedule_note) ->
         keep written_about note.Schedule_domain.schedule_id note.Schedule_domain.created_at)
      written_about
      state.notes
  in
  finished, written_about
;;

(* When anything was last written about [request], if it is a terminal
   schedule that finished a wake. Only such a schedule is forgotten, once
   [now] is more than the retention past this time. *)
let last_written_if_finished ~finished ~written_about (request : schedule_request) =
  if not (Schedule_domain.is_terminal request.status)
  then None
  else
    Option.map
      (fun finished_at ->
         Float.max
           finished_at
           (Option.value
              (Schedule_id_map.find_opt request.schedule_id written_about)
              ~default:finished_at))
      (Schedule_id_map.find_opt request.schedule_id finished)
;;

let compute_oldest_last_written state =
  let finished, written_about = ledger_times state in
  List.fold_left
    (fun oldest request ->
       match last_written_if_finished ~finished ~written_about request, oldest with
       | None, _ -> oldest
       | Some last_written, None -> Some last_written
       | Some last_written, Some earlier -> Some (Float.min_num earlier last_written))
    None
    state.schedules
;;

type prepared_state =
  { state : state
  ; schedules_by_id : Schedule_domain.schedule_request Schedule_id_map.t
  ; wakes_by_instance : Schedule_domain.wake_record list Schedule_instance_map.t
  ; notes_by_schedule_id :
      Schedule_domain.schedule_note list Schedule_id_map.t option Atomic.t
  ; oldest_finished_last_written : float option
  }

let build_notes_by_schedule_id (state : state)
  : Schedule_domain.schedule_note list Schedule_id_map.t
  =
  let notes_rev_by_schedule_id =
    List.fold_left
      (fun acc (note : Schedule_domain.schedule_note) ->
         let existing =
           Option.value (Schedule_id_map.find_opt note.schedule_id acc) ~default:[]
         in
         Schedule_id_map.add note.schedule_id (note :: existing) acc)
      Schedule_id_map.empty
      state.notes
  in
  Schedule_id_map.map
    (fun rev_notes ->
       List.rev rev_notes
       |> List.sort (fun left right ->
         Float.compare left.Schedule_domain.created_at right.Schedule_domain.created_at))
    notes_rev_by_schedule_id
;;

let build_prepared_state (state : state) : prepared_state =
  let schedules_by_id =
    List.fold_left
      (fun acc (request : Schedule_domain.schedule_request) ->
         if Schedule_id_map.mem request.schedule_id acc
         then acc
         else Schedule_id_map.add request.schedule_id request acc)
      Schedule_id_map.empty
      state.schedules
  in
  let wakes_rev_by_instance =
    List.fold_left
      (fun acc (wake : Schedule_domain.wake_record) ->
         let key = wake.schedule_id, wake.schedule_instance_id in
         let existing =
           Option.value (Schedule_instance_map.find_opt key acc) ~default:[]
         in
         Schedule_instance_map.add key (wake :: existing) acc)
      Schedule_instance_map.empty
      state.wakes
  in
  let wakes_by_instance =
    Schedule_instance_map.map List.rev wakes_rev_by_instance
  in
  let oldest_finished_last_written = compute_oldest_last_written state in
  { state
  ; schedules_by_id
  ; wakes_by_instance
  ; notes_by_schedule_id = Atomic.make None
  ; oldest_finished_last_written
  }
;;

let last_prepared_state : prepared_state option Atomic.t = Atomic.make None

let prepared_of_state (state : state) : prepared_state =
  match Atomic.get last_prepared_state with
  | Some prepared when prepared.state == state -> prepared
  | Some _ | None ->
    let prepared =
      Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
        build_prepared_state state)
    in
    Atomic.set last_prepared_state (Some prepared);
    prepared
;;

let notes_by_schedule_id_of_prepared (prepared : prepared_state) =
  match Atomic.get prepared.notes_by_schedule_id with
  | Some notes_map -> notes_map
  | None ->
    let notes_map =
      Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
        build_notes_by_schedule_id prepared.state)
    in
    Atomic.set prepared.notes_by_schedule_id (Some notes_map);
    notes_map
;;

let find_schedule state ~schedule_id =
  let prepared = prepared_of_state state in
  Schedule_id_map.find_opt schedule_id prepared.schedules_by_id
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

(* Notes (task-381): the store owns identity and ordering. [note_id] is a
   global counter (like [version]), so ids never collide after deletes or
   across schedules, and [notes_for_schedule] can promise oldest-first
   reading. Note appends intentionally bypass [bump_state]: notes must not be
   pruned with terminal state, because their value is surviving it. *)
let next_note_id state = string_of_int (state.version + 1)

let make_note state ~schedule_id ~author_id ~author_kind ~body ~now =
  let note_id = next_note_id state in
  { Schedule_domain.note_id
  ; schedule_id
  ; author_id
  ; author_kind
  ; created_at = now
  ; body
  }
;;

let notes_for_schedule state ~schedule_id =
  let prepared = prepared_of_state state in
  let notes_by_schedule_id = notes_by_schedule_id_of_prepared prepared in
  Option.value
    (Schedule_id_map.find_opt schedule_id notes_by_schedule_id)
    ~default:[]
;;

let note_count_per_schedule state schedule_id =
  notes_for_schedule state ~schedule_id |> List.length
;;

let append_note config ~schedule_id ~author_id ~author_kind ~body ~now =
  with_observed_mutation config (fun write_state ->
    let* state = load_for_mutation config in
    match find_schedule state ~schedule_id with
    | None -> Error Schedule_not_found
    | Some _ ->
      let note = make_note state ~schedule_id ~author_id ~author_kind ~body ~now in
      let notes = state.notes @ [ note ] in
      let next_state =
        { version = state.version + 1
        ; updated_at = now
        ; schedules = state.schedules
        ; wakes = state.wakes
        ; notes
        }
      in
      let* () = write_state config next_state in
      Ok (note, note_count_per_schedule next_state schedule_id))
;;

let is_due_wake_candidate (request : schedule_request) =
  match request.status with
  | Due -> true
  | Scheduled | Running | Succeeded | Failed | Cancelled | Expired ->
    false
;;

let get_schedule config ~schedule_id = find_schedule (read_state config) ~schedule_id

let make_wake_record ~attempt_id ~now (request : schedule_request) =
  { schedule_instance_id = request.schedule_instance_id
  ; schedule_id = request.schedule_id
  ; attempt_identity = Identified attempt_id
  ; settlement_kind = None
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
  let prepared = prepared_of_state state in
  Option.value
    (Schedule_instance_map.find_opt
       (schedule_id, schedule_instance_id)
       prepared.wakes_by_instance)
    ~default:[]
;;

let last_wake_for_schedule_instance state ~schedule_instance_id ~schedule_id =
  match wakes_for_schedule_instance state ~schedule_instance_id ~schedule_id with
  | wake :: _ -> Some wake
  | [] -> None
;;

let last_wake_of_request state (request : schedule_request) =
  last_wake_for_schedule_instance
    state
    ~schedule_instance_id:request.schedule_instance_id
    ~schedule_id:request.schedule_id
;;

let transition_refused state (request : schedule_request) ~attempted =
  Transition_refused
    { schedule_id = request.schedule_id
    ; current = request.status
    ; attempted
    ; last_wake = last_wake_of_request state request
    }
;;

(* The wake of exactly this occurrence: a recurring request keeps its instance
   id across occurrences, so the instance alone would also match the wakes of
   the ones already delivered. *)
let is_occurrence_wake (request : schedule_request) (wake : wake_record) =
  String.equal wake.schedule_instance_id request.schedule_instance_id
  && String.equal wake.schedule_id request.schedule_id
  && Float.equal wake.due_at request.due_at
  && String.equal wake.payload_digest (Schedule_domain.payload_digest request.payload)
;;

(* Called once no wake of the request's schedule is running. A wake of this
   occurrence that is still in the ledger has therefore finished, which says
   the delivery already happened; no wake of this occurrence says it was
   never recorded. *)
let running_wake_missing wakes (request : schedule_request) =
  match List.find_opt (is_occurrence_wake request) wakes with
  | Some wake -> Running_wake_settled { schedule_id = request.schedule_id; wake }
  | None -> Running_wake_absent { schedule_id = request.schedule_id }
;;

let update_latest_running_wake wakes (request : schedule_request) update =
  let rec loop acc = function
    | [] -> Error (running_wake_missing wakes request)
    | (wake : wake_record) :: rest
      when is_occurrence_wake request wake
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
  ; settlement_kind = Some (match reason with
      | Retryable_dispatch_failure _ -> Retryable_failure
      | Interrupted_by_process_restart -> Process_interrupted)
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

let interval_fires_as_declared ~runner_tick_sec (request : schedule_request) =
  Schedule_domain.interval_fires_as_declared ~runner_tick_sec request.recurrence
  |> Result.map_error (fun below ->
    Interval_below_runner_tick { schedule_id = request.schedule_id; below })
;;

let insert_request config ~runner_tick_sec (request : Schedule_domain.schedule_request) =
  with_observed_mutation config (fun write_state ->
    let* state = load_for_mutation config in
    match find_schedule state ~schedule_id:request.schedule_id with
    | Some _ -> Error Schedule_already_exists
    | None ->
      let* () = validate_initial_request request in
      let* () = interval_fires_as_declared ~runner_tick_sec request in
      let schedules = request :: state.schedules in
      let next_state =
        bump_state state ~schedules ~wakes:state.wakes ~notes:state.notes
      in
      let* () = write_state config next_state in
      Ok request)
;;

(* "The same due time" and "before now" are read at whole-second resolution:
   a due time is shown, and sent back by an edit form, as RFC 3339 whole
   seconds, while the stored value may carry a fraction. A replacement that
   carries the stored due time back unchanged is accepted even when that time
   has passed: a due row that is edited and keeps its due time was going to
   fire anyway. A replacement that moves the due time behind the clock would
   fire at once for a time nobody chose. Judged under the ledger lock, against
   the row as stored, so a concurrent edit cannot make a stale "unchanged"
   true. *)
let changed_due_not_past ~now ~(current : schedule_request) (request : schedule_request) =
  let current_second = Float.floor now in
  let unchanged =
    Float.equal (Float.floor request.due_at) (Float.floor current.due_at)
  in
  if unchanged || Float.compare request.due_at current_second >= 0
  then Ok ()
  else
    Error
      (Changed_due_already_past
         { schedule_id = request.schedule_id
         ; stored_due_at = current.due_at
         ; due_at = request.due_at
         ; now = current_second
         })
;;

type timing_update = Replace_timing | Keep_timing | Keep_recurrence

(* Only the locked row establishes who scheduled this id. For replacement
   ownership, the target comes from the proposed payload but the scheduler
   still comes from [current], never a stale request supplied by the caller. *)
let authorize_mutation authority ~(current : schedule_request) ~target =
  match authority with
  | Operator_authority -> Ok ()
  | Named_authority { name; wake_keeper_name } ->
    let wake_target = wake_keeper_name target in
    if String.equal current.scheduled_by.id name
       || Option.fold ~none:false ~some:(String.equal name) wake_target
    then Ok ()
    else Error (Not_schedule_owner
      { schedule_id = current.schedule_id
      ; caller = name
      ; scheduled_by_id = current.scheduled_by.id
      ; wake_target
      })
;;

let update_request config ~authority ~now ~runner_tick_sec ?(timing_update = Replace_timing)
    ?expected_instance_id (request : Schedule_domain.schedule_request) =
  with_observed_mutation config (fun write_state ->
    let* state = load_for_mutation config in
    match find_schedule state ~schedule_id:request.schedule_id with
    | None -> Error Schedule_not_found
    | Some current ->
      let* () = authorize_mutation authority ~current ~target:current in
      let* () = authorize_mutation authority ~current ~target:request in
      (* After authorization, so a caller that may not change the row does not
         learn which instance it holds. *)
      let* () =
        match expected_instance_id with
        | Some expected when not (String.equal expected current.schedule_instance_id) ->
          Error
            (Stale_instance
               { schedule_id = request.schedule_id
               ; expected
               ; found = current.schedule_instance_id
               })
        | Some _ | None -> Ok ()
      in
      if Schedule_domain.modify_allowed current.status
      then (
        let request = { request with
          requested_by = current.requested_by; scheduled_by = current.scheduled_by } in
        let request = match timing_update with
          | Replace_timing -> request
          | Keep_recurrence -> { request with recurrence = current.recurrence }
          | Keep_timing ->
            (* The expiry is part of the timing a content edit keeps: a
               replacement that carries none must not turn an expiring
               schedule into one that never reaches [Expired]. An explicit
               expiry on the call still wins. *)
            let expires_at = match request.expires_at with
              | Some _ as given -> given
              | None -> current.expires_at
            in
            { request with
              due_at = current.due_at
            ; recurrence = current.recurrence
            ; expires_at
            }
        in
        let* () = validate_initial_request request in
        let* () = changed_due_not_past ~now ~current request in
        let* () = interval_fires_as_declared ~runner_tick_sec request in
        let schedules = replace_schedule state.schedules request in
        let next_state = bump_state state ~schedules ~wakes:state.wakes ~notes:state.notes in
        let* () = write_state config next_state in
        Ok request)
      else Error (transition_refused state current ~attempted:Modify_schedule))
;;

(* The queued wake is withdrawn under the ledger lock, before the row turns
   [Cancelled]. A wake is enqueued only while its row is [Running]
   ([start_due_candidate] to [accept_running], both under this lock), and a
   [Running] row is refused below, so while the lock is held no occurrence of
   this schedule can be enqueued after the withdrawal and survive the cancel.
   A failed withdrawal writes no schedule ledger change: the row stays active
   and the caller can cancel again. Earlier queue withdrawals remain durable.
   A ledger write that fails after the withdrawal also leaves the
   row active; the withdrawn occurrence stays cancelled in the queue, with the
   queue's own cancellation receipt, and the next occurrence fires as due. *)
let cancel_request config ~authority ~schedule_id ~cancellation ~withdraw_queued_wakes =
  with_observed_mutation config (fun write_state ->
    let* state = load_for_mutation config in
    match find_schedule state ~schedule_id with
    | None -> Error Schedule_not_found
    | Some request ->
      let* () = authorize_mutation authority ~current:request ~target:request in
      (match request.status with
       | Running | Succeeded | Failed | Cancelled | Expired ->
         Error (transition_refused state request ~attempted:Cancel_schedule)
       | Scheduled | Due ->
         let* () =
           withdraw_queued_wakes request cancellation
           |> Result.map_error (fun detail ->
             Persistence_failed ("queued wake withdrawal failed: " ^ detail))
         in
         let updated_request =
           { request with
             Schedule_domain.status = Schedule_domain.Cancelled
           ; cancellation = Some cancellation
           }
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
           bump_state state ~schedules ~wakes ~notes:state.notes
         in
         let* () = write_state config next_state in
         Ok updated_request))
;;

(* How long a finished schedule stays in the ledger after the wake that ended
   it, when the caller has nothing else to say. Every mutation rewrites the
   ledger whole, and a live one held 1,250 finished schedules against 22 live
   ones: 4.3 MB, median finished age 8.6 days (2026-09-16). Seven days is the
   window the user chose on that date, and it is what the runtime setting
   starts at; the caller passes the window it wants to each pass.

   Only a wake tells the ledger when a schedule finished. A cancellation or an
   expiry writes no time of its own, so a schedule that never ran is not
   forgotten here at all -- [prune_completed] is what forgets those, when an
   operator asks. Reading the retention off [due_at] instead would delete a
   long-overdue schedule the moment someone cancelled it. *)
let terminal_schedule_retention_days = 7

let retention_seconds ~retention_days =
  float_of_int retention_days *. 24.0 *. 60.0 *. 60.0
;;

(* One pass forgets at most this many, so a tick's write stays near the size of
   the ledger it already rewrites, and a clock that jumps forward cannot take
   the whole ledger and its .last-good mirror in a single write. *)
let schedules_forgotten_per_pass = 64

let past_retention ~now ~retention_days last_written =
  now -. last_written > retention_seconds ~retention_days
;;

(* The schedules to keep and the wakes of those forgotten. Notes stay: they are
   append-only evidence about intent and history, which [prune_completed] also
   leaves behind, and a note about a schedule the ledger no longer holds is
   still what someone wrote. *)
let forget_finished_schedules ~now ~retention_days state =
  let finished, written_about = ledger_times state in
  let forgettable request =
    match last_written_if_finished ~finished ~written_about request with
    | None -> false
    | Some last_written -> past_retention ~now ~retention_days last_written
  in
  let kept_rev, forgotten_ids, forgotten_count =
    List.fold_left
      (fun (kept_rev, forgotten_ids, forgotten_count) (request : schedule_request) ->
         if forgotten_count >= schedules_forgotten_per_pass
            || not (forgettable request)
         then request :: kept_rev, forgotten_ids, forgotten_count
         else if Schedule_id_set.mem request.schedule_id forgotten_ids
         then kept_rev, forgotten_ids, forgotten_count
         else
           ( kept_rev
           , Schedule_id_set.add request.schedule_id forgotten_ids
           , forgotten_count + 1 ))
      ([], Schedule_id_set.empty, 0)
      state.schedules
  in
  let kept = List.rev kept_rev in
  let holds_a_kept_schedule schedule_id =
    not (Schedule_id_set.mem schedule_id forgotten_ids)
  in
  ( kept
  , List.filter
      (fun (wake : Schedule_domain.wake_record) ->
         holds_a_kept_schedule wake.Schedule_domain.schedule_id)
      state.wakes
  , forgotten_count )
;;

(* The oldest [last_written_if_finished] among a state's schedules, kept on
   the state's prepared projection. [now -. t] never shrinks as [t] gets older,
   so when the oldest is not past the retention no schedule is, and the pass
   would forget nothing. *)
let oldest_last_written state =
  (prepared_of_state state).oldest_finished_last_written
;;

let refresh_due config ~now ~retention_days =
  with_observed_mutation config (fun write_state ->
    let* state = load_for_mutation config in
    let schedules_rev, changed =
      List.fold_left
        (fun (schedules, changed) request ->
          let updated = Schedule_domain.mark_due ~now request in
          let changed =
            if updated.Schedule_domain.status <> request.Schedule_domain.status
            then changed + 1
            else changed
          in
          updated :: schedules, changed)
        ([], 0)
        state.schedules
    in
    let schedules = List.rev schedules_rev in
    (* A clock behind the ledger's own last write cannot judge how long ago
       anything finished, so such a tick only marks what is due. A tick that
       marked nothing holds the loaded state's own schedules, so when the
       oldest of them is inside the retention it has nothing to forget. *)
    let nothing_to_forget () =
      match oldest_last_written state with
      | None -> true
      | Some oldest -> not (past_retention ~now ~retention_days oldest)
    in
    let schedules, wakes, forgotten =
      if now < state.updated_at
      then schedules, state.wakes, 0
      else if changed = 0 && nothing_to_forget ()
      then schedules, state.wakes, 0
      else forget_finished_schedules ~now ~retention_days { state with schedules }
    in
    if changed = 0 && forgotten = 0
    then Ok (state, 0)
    else (
      if forgotten > 0
      then
        Log.Misc.info
          "schedule_store: forgot %d schedule(s) whose wake finished more than %d days ago"
          forgotten
          retention_days;
      let next_state = bump_state state ~schedules ~wakes ~notes:state.notes in
      let* () = write_state config next_state in
      Ok (next_state, changed)))
;;

let reschedule_due_recurring config ~now ~schedule_ids =
  let target_ids = Schedule_id_set.of_list schedule_ids in
  with_observed_mutation config (fun write_state ->
    let* state = load_for_mutation config in
    let schedules_rev, changed =
      List.fold_left
        (fun (schedules, changed) (request : schedule_request) ->
          if not (Schedule_id_set.mem request.schedule_id target_ids)
          then
            request :: schedules, changed
          else
            match Schedule_domain.reschedule_after_due_signal ~now request with
            | None -> request :: schedules, changed
            | Some updated -> updated :: schedules, changed + 1)
        ([], 0)
        state.schedules
    in
    let schedules = List.rev schedules_rev in
    if changed = 0 then
      Ok (state, 0)
    else (
      let next_state =
        bump_state state ~schedules ~wakes:state.wakes ~notes:state.notes
      in
      let* () = write_state config next_state in
      Ok (next_state, changed)))
;;

let same_occurrence (left : schedule_request) (right : schedule_request) =
  String.equal left.schedule_id right.schedule_id
  && String.equal left.schedule_instance_id right.schedule_instance_id
  && Float.equal left.due_at right.due_at
  && String.equal (payload_digest left.payload) (payload_digest right.payload)
;;

let attempt_unavailable schedule_id reason =
  Error (Running_attempt_unavailable { schedule_id; reason })
;;

let load_authoritative config ~schedule_id =
  match load_primary config with
  | Ok state -> Ok state
  | Error failure ->
    attempt_unavailable schedule_id
      (primary_failure_message ~path:(schedules_path config) failure)
;;

let attempt_scope config ~schedule_id =
  Cancel_safe.protect
    ~on_exn:(fun exn -> attempt_unavailable schedule_id (Printexc.to_string exn))
    (fun () ->
      let root = Fs_compat.realpath (Workspace_utils.masc_dir config) in
      let stat = Unix.stat root in
      Ok { root; device = stat.st_dev; inode = stat.st_ino; backend = config.Workspace_utils.backend })
;;

let same_backend left right =
  match left, right with
  | Workspace_utils.Memory left, Workspace_utils.Memory right -> left == right
  | Workspace_utils.FileSystem left, Workspace_utils.FileSystem right -> left == right
  | Workspace_utils.Memory _, Workspace_utils.FileSystem _
  | Workspace_utils.FileSystem _, Workspace_utils.Memory _ -> false
;;

let same_scope left right =
  String.equal left.root right.root && left.device = right.device && left.inode = right.inode
  && same_backend left.backend right.backend
;;

let start_due_candidate ?started_at config ~now ~(candidate : schedule_request) =
  (* [now] is the runner tick that judged the candidate due; [started_at] is
     the moment this attempt actually began. They differ by however long the
     tick spent before reaching this schedule, and a wake stamped with the
     tick time reports that delay as zero. *)
  let started_at = Option.value started_at ~default:now in
  let schedule_id = candidate.schedule_id in
  with_observed_mutation config (fun write_state ->
    let* state = load_authoritative config ~schedule_id in
    match find_schedule state ~schedule_id with
    | None -> Error Schedule_not_found
    | Some request ->
      if not (is_due_wake_candidate request && same_occurrence candidate request) then
        Error Schedule_not_due_candidate
      else
        let updated = { request with status = Running } in
        let* scope = attempt_scope config ~schedule_id in
        let attempt_id = fresh_wake_attempt_id () in
        let wake = make_wake_record ~attempt_id ~now:started_at request in
        let schedules = replace_schedule state.schedules updated in
        let wakes = wake :: state.wakes in
        let next_state = bump_state state ~schedules ~wakes ~notes:state.notes in
        let* () = write_state config next_state in
        Ok { request = updated; attempt = { original = updated; attempt_id; scope } })
;;

type settlement = Accept of Yojson.Safe.t option | Fail of failure_scope * string
  | Retry of running_recovery_reason

let settled_request ~now (request : schedule_request) = function
  | Retry _ -> { request with status = Due }
  | Fail (Schedule_failure, _) -> { request with status = Failed }
  | Accept _ ->
    (match Schedule_domain.next_due_after ~now request with
     | Some due_at -> { request with status = Scheduled; due_at }
     | None -> { request with status = Succeeded })
  | Fail (Occurrence_failure, _) ->
    (match Schedule_domain.next_due_after ~now request with
     | Some due_at -> { request with status = Scheduled; due_at }
     | None -> { request with status = Failed })
;;

let settle_wake ~finished_at verdict wake =
  match verdict with
  | Accept detail -> { wake with status = Wake_succeeded; finished_at = Some finished_at;
      settlement_kind = Some Accepted; detail; error = None }
  | Fail (scope, error) -> { wake with status = Wake_failed; finished_at = Some finished_at;
      settlement_kind = Some (match scope with Schedule_failure -> Schedule_rejected
        | Occurrence_failure -> Occurrence_rejected); detail = None; error = Some error }
  | Retry reason -> fail_wake_for_recovery ~now:finished_at ~reason wake
;;

let same_verdict ~now attempt (request : schedule_request) (wake : wake_record) verdict =
  match wake.finished_at with
  | None -> false
  | Some finished_at ->
    let expected = settled_request ~now attempt.original verdict in
    let expected_wake = settle_wake ~finished_at verdict wake in
    request.status = expected.status && Float.equal request.due_at expected.due_at
    && wake.status = expected_wake.status
    && wake.settlement_kind = expected_wake.settlement_kind
    && Option.equal String.equal wake.error expected_wake.error
    && Option.equal Yojson.Safe.equal wake.detail expected_wake.detail
;;

let terminal_evidence_valid (wake : wake_record) =
  wake.finished_at <> None
  && (match wake.settlement_kind with
      | None -> false
      | Some Accepted -> wake.status = Wake_succeeded && wake.error = None
      | Some (Schedule_rejected | Occurrence_rejected | Retryable_failure
             | Process_interrupted | Unsupported_payload) ->
        wake.status = Wake_failed && wake.error <> None && wake.detail = None
      (* Cancellation/orphan writers preserve any prior receipt detail for
         queue evidence projection; dispatch-failure writers clear it. *)
      | Some (Cancelled_schedule | Orphaned_attempt) ->
        wake.status = Wake_failed && wake.error <> None)
;;

let settle_running config ~now ~finished_at ~(attempt : running_attempt) verdict =
  let schedule_id = attempt.original.schedule_id in
  with_observed_mutation config (fun write_state ->
    let* scope = attempt_scope config ~schedule_id in
    let* () = if same_scope scope attempt.scope then Ok ()
      else attempt_unavailable schedule_id "workspace or backend changed" in
    let* state = load_authoritative config ~schedule_id in
    match find_schedule state ~schedule_id with
    | None -> Error Schedule_not_found
    | Some request ->
      let superseded () = Error (Running_attempt_superseded { schedule_id }) in
      let is_attempt (wake : wake_record) = match wake.attempt_identity with
        | Identified id -> String.equal (wake_attempt_id_to_string id)
            (wake_attempt_id_to_string attempt.attempt_id)
        | Unidentified -> false in
      let* current_running =
        let running = List.filter (fun (wake : wake_record) ->
          is_occurrence_wake request wake && wake.status = Wake_running) state.wakes in
        match request.status, running with
        | Running, [ wake ] ->
          if wake.settlement_kind <> None || wake.finished_at <> None
             || wake.error <> None || wake.detail <> None
          then attempt_unavailable schedule_id "running wake carries terminal settlement evidence"
          else (match wake.attempt_identity with
           | Unidentified -> attempt_unavailable schedule_id "current running wake is unidentified"
           | Identified _ -> Ok (Some wake))
        | Running, [] -> Error (running_wake_missing state.wakes request)
        | Running, _ :: _ :: _ -> attempt_unavailable schedule_id "multiple current running wakes"
        | (Scheduled | Due | Succeeded | Failed | Cancelled | Expired), [] -> Ok None
        | (Scheduled | Due | Succeeded | Failed | Cancelled | Expired), _ :: _ ->
          attempt_unavailable schedule_id "non-running request retains a current running wake" in
      if not (String.equal request.schedule_instance_id attempt.original.schedule_instance_id)
      then superseded ()
      else if (match current_running with Some wake -> not (is_attempt wake) | None -> false)
      then superseded ()
      else match List.find_opt is_attempt state.wakes with
      | None ->
        if not (Float.equal request.due_at attempt.original.due_at) then superseded ()
        else attempt_unavailable schedule_id "the exact attempt wake is absent"
      | Some wake when not (is_occurrence_wake attempt.original wake) ->
        attempt_unavailable schedule_id "attempt identity contradicts its occurrence"
      | Some ({ status = (Wake_succeeded | Wake_failed); _ } as wake) ->
        if not (terminal_evidence_valid wake)
        then attempt_unavailable schedule_id "terminal wake lacks consistent typed settlement evidence"
        else if same_verdict ~now attempt request wake verdict then Ok request else superseded ()
      | Some ({ status = Wake_running; _ } as wake) ->
        if request.status <> Running || not (same_occurrence request attempt.original)
        then attempt_unavailable schedule_id "the exact running wake contradicts its request"
        else
        let updated = settled_request ~now request verdict in
        let schedules = replace_schedule state.schedules updated in
        let wakes = List.map (fun current -> if is_attempt current
          then settle_wake ~finished_at verdict wake else current) state.wakes in
        let next_state = bump_state state ~schedules ~wakes ~notes:state.notes in
        let* () = write_state config next_state in
        Ok updated)
;;

let accept_running ?finished_at config ~now ~attempt ?detail () =
  settle_running config ~now ~finished_at:(Option.value finished_at ~default:now) ~attempt (Accept detail)
;;

let cancel_matching config ~should_cancel =
  with_observed_mutation config (fun write_state ->
    let* state = load_for_mutation config in
    let rec cancel schedules changed = function
      | [] -> Ok (List.rev schedules, changed)
      | (request : schedule_request) :: rest when not (should_cancel request) ->
        cancel (request :: schedules) changed rest
      | ({ status = (Scheduled | Due); _ } as request) :: rest ->
        cancel ({ request with status = Cancelled } :: schedules) true rest
      | ({ status = Running; _ } as request) :: _ ->
        Error
          (transition_refused state request ~attempted:Cancel_for_consumer_retirement)
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
      let cancelled_ids =
        List.fold_left
          (fun acc (request : schedule_request) ->
             if should_cancel request
             then Schedule_id_set.add request.schedule_id acc
             else acc)
          Schedule_id_set.empty
          schedules
      in
      let stamp = now () in
      let wakes =
        List.map
          (fun (wake : wake_record) ->
             if Schedule_id_set.mem wake.Schedule_domain.schedule_id cancelled_ids
                && wake.status = Wake_running
             then
               settle_running_wake
                 ~now:stamp
                 ~kind:Cancelled_schedule
                 ~reason:"cancelled schedule settles its in-flight wake"
                 wake
             else wake)
          state.wakes
      in
      write_state config (bump_state state ~schedules ~wakes ~notes:state.notes)
    else Ok ())
;;

let fail_running ?finished_at config ~now ~attempt ~failure_scope ~error =
  settle_running config ~now ~finished_at:(Option.value finished_at ~default:now) ~attempt
    (Fail (failure_scope, error))
;;

let retry_running ?finished_at config ~now ~attempt ~reason =
  settle_running config ~now ~finished_at:(Option.value finished_at ~default:now) ~attempt (Retry reason)
;;

let recover_running_on_startup config ~now =
  let reason = Interrupted_by_process_restart in
  with_observed_mutation config (fun write_state ->
    let* state = load_for_mutation config in
    let rec recover schedules_rev wakes recovered = function
      | [] -> Ok (List.rev schedules_rev, wakes, recovered)
      | (request : schedule_request) :: rest ->
        (match request.status with
         | Running ->
           (match List.find_opt (is_occurrence_wake request) wakes with
            | Some { status = Wake_running; _ } ->
              let* wakes =
                update_latest_running_wake wakes request
                  (fail_wake_for_recovery ~now ~reason)
              in
              recover
                ({ request with status = Due } :: schedules_rev)
                wakes
                (recovered + 1)
                rest
            | Some ({ status = (Wake_succeeded | Wake_failed); _ } as wake) ->
              Error
                (Running_wake_settled { schedule_id = request.schedule_id; wake })
            | None -> Error (Running_wake_absent { schedule_id = request.schedule_id }))
         | Scheduled | Due | Succeeded | Failed | Cancelled | Expired ->
           recover (request :: schedules_rev) wakes recovered rest)
    in
    let* schedules, wakes, recovered =
      recover [] state.wakes 0 state.schedules
    in
    if recovered = 0 then
      Ok (state, 0)
    else
      let next_state = bump_state state ~schedules ~wakes ~notes:state.notes in
      let* () = write_state config next_state in
      Ok (next_state, recovered))
;;

let fail_due_candidate ?attempted_at config ~now ~(candidate : schedule_request) ~error =
  (* The consumer refused the payload before any work began, so the attempt
     starts and ends at the same instant: [attempted_at] (default [now]). *)
  let attempted_at = Option.value attempted_at ~default:now in
  let schedule_id = candidate.schedule_id in
  with_observed_mutation config (fun write_state ->
    let* state = load_authoritative config ~schedule_id in
    match find_schedule state ~schedule_id with
    | None -> Error Schedule_not_found
    | Some request ->
      if not (is_due_wake_candidate request && same_occurrence candidate request) then
        Error Schedule_not_due_candidate
      else
        let updated = { request with status = Failed } in
        let wake =
          { (make_wake_record ~attempt_id:(fresh_wake_attempt_id ()) ~now:attempted_at request) with
            status = Wake_failed
          ; settlement_kind = Some Unsupported_payload
          ; finished_at = Some attempted_at
          ; error = Some error
          }
        in
        let schedules = replace_schedule state.schedules updated in
        let wakes = wake :: state.wakes in
        let next_state = bump_state state ~schedules ~wakes ~notes:state.notes in
        let* () = write_state config next_state in
        Ok updated)
;;

let prune_completed config =
  with_observed_mutation config (fun write_state ->
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
      List.fold_left
        (fun acc (r : schedule_request) -> Schedule_id_set.add r.schedule_id acc)
        Schedule_id_set.empty
        schedules
    in
    let wakes =
      List.filter
        (fun (wake : wake_record) ->
           Schedule_id_set.mem wake.schedule_id remaining_ids)
        state.wakes
    in
    if pruned_count = 0 && List.length wakes = List.length state.wakes then
      Ok (state, 0)
    else
      let next_state = bump_state state ~schedules ~wakes ~notes:state.notes in
      let* () = write_state config next_state in
      Ok (next_state, pruned_count))
;;

let due_wake_candidates state =
  state.schedules
  |> List.filter is_due_wake_candidate
;;
