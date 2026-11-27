open Schedule_domain

type state =
  { version : int
  ; updated_at : float
  ; schedules : Schedule_domain.schedule_request list
  ; wakes : Schedule_domain.wake_record list
  ; note_last_written_at : (string * float) list
  }

type raw_ledger =
  { state : state
  ; legacy_notes : Schedule_domain.schedule_note list
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

type recovery_cause = Primary_missing | Primary_unusable

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
  | Expiry_before_reachable_due of
      { schedule_id : string
      ; expiry : Schedule_domain.expiry_before_reachable_due
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
  | Primary_ledger_unavailable of recovery_cause
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

type notes_read_error =
  | Corrupt_notes_log of string
  | Corrupt_notes_ledger of read_error

type read_source =
  | Uninitialized
  | Primary_ledger
  | Recovery_mirror of recovery_cause

(* A parsed-or-absent ledger load.

   [Fresh] = neither the primary ledger nor its [.last-good] mirror exists, so
   [default_state] is correct. [write_state] commits the primary before its
   mirror, so the mirror can lag an acknowledged write. A parseable mirror
   beside an absent or broken primary yields [Recovered] for observation only;
   [load_for_mutation_raw] refuses that source and preserves the surviving bytes.

   [Corrupt] = at least one of the two files exists and no state can be parsed
   from either; callers must NOT collapse this to [default_state] and must NOT
   overwrite the on-disk files, because the bytes may still hold schedule intent
   worth manual recovery. *)
type load_outcome =
  | Loaded of raw_ledger
  | Recovered of raw_ledger * recovery_cause
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
  | Expiry_before_reachable_due
      { schedule_id
      ; expiry = { due_at; expires_at; runner_tick_sec; minimum_expires_at }
      } ->
    Printf.sprintf
      "schedule %s: expires_at %s does not leave one schedule runner tick \
       (%gs) after due_at %s; expires_at must be after %s"
      schedule_id
      (Time_codec.rfc3339_of_unix expires_at)
      runner_tick_sec
      (Time_codec.rfc3339_of_unix due_at)
      (Time_codec.rfc3339_of_unix minimum_expires_at)
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
  | Primary_ledger_unavailable cause ->
    let reason = match cause with
      | Primary_missing -> "missing"
      | Primary_unusable -> "unreadable"
    in
    Printf.sprintf
      "schedule primary ledger is %s; the .last-good recovery mirror is read-only"
      reason
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

let notes_read_error_to_string = function
  | Corrupt_notes_log detail -> "schedule notes log could not be read: " ^ detail
  | Corrupt_notes_ledger err -> read_error_to_string err
;;

(* NDT-OK: store boundary timestamp for projection metadata; replay uses the
   persisted [updated_at] value instead of recomputing it. *)
let now () = Unix.gettimeofday ()

let schedules_filename = "schedules.json"
let schedule_notes_filename = "schedule_notes.jsonl"

let schedules_path config =
  Filename.concat (Workspace_utils.masc_dir config) schedules_filename
;;

let schedule_notes_path config =
  Filename.concat (Workspace_utils.masc_dir config) schedule_notes_filename
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
  ; note_last_written_at = []
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
    ; ( "note_last_written_at"
      , `Assoc (List.map (fun (id, ts) -> id, `Float ts) state.note_last_written_at) )
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
module Note_id_set = Set.Make (String)

let merge_last_written_into map schedule_id ts =
  match Schedule_id_map.find_opt schedule_id map with
  | Some seen when seen >= ts -> map
  | Some _ | None -> Schedule_id_map.add schedule_id ts map
;;

let upsert_note_last_written_at entries ~schedule_id ~ts =
  let map =
    List.fold_left
      (fun acc (id, existing_ts) -> merge_last_written_into acc id existing_ts)
      Schedule_id_map.empty
      entries
  in
  Schedule_id_map.bindings (merge_last_written_into map schedule_id ts)
;;

module Schedule_instance_key = struct
  type t = string * string

  let compare (id_a, inst_a) (id_b, inst_b) =
    let c = String.compare id_a id_b in
    if c <> 0 then c else String.compare inst_a inst_b
  ;;
end

module Schedule_instance_map = Map.Make (Schedule_instance_key)

let parse_note_last_written_at fields =
  match List.assoc_opt "note_last_written_at" fields with
  | None -> Ok Schedule_id_map.empty
  | Some (`Assoc entries) ->
    let rec loop acc = function
      | [] -> Ok acc
      | (schedule_id, value) :: rest ->
        let* ts =
          match value with
          | `Float v when Float.is_finite v -> Ok v
          | `Int v -> Ok (float_of_int v)
          | `Float _ | `Bool _ | `Intlit _ | `String _ | `Null | `Assoc _ | `List _ ->
            Error ("note_last_written_at." ^ schedule_id ^ ": expected finite float")
        in
        loop (merge_last_written_into acc schedule_id ts) rest
    in
    loop Schedule_id_map.empty entries
  | Some (`Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _) ->
    Error "expected object field: note_last_written_at"
;;

let raw_ledger_of_yojson = function
  | `Assoc fields ->
    let* version = int_field "version" fields in
    let* updated_at = Schedule_domain.float_field "updated_at" fields in
    let* schedules_json = list_field "schedules" fields in
    let* wakes_json = list_field "wakes" fields in
    let* note_last_written_map = parse_note_last_written_at fields in
    let* legacy_notes_json =
      (* Back-compat: ledgers written before the schedule_notes.jsonl split may
         still carry an inline [notes] list; keep decoding and validating it so
         reads include legacy notes and the next mutation migrates them safely. *)
      match List.assoc_opt "notes" fields with
      | None -> Ok []
      | Some (`List value) -> Ok value
      | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _) ->
        Error "expected list field: notes"
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
    let* legacy_notes =
      collect_results Schedule_domain.schedule_note_of_yojson legacy_notes_json
    in
    let note_last_written_map =
      List.fold_left
        (fun acc (note : Schedule_domain.schedule_note) ->
           if Float.is_finite note.created_at
           then merge_last_written_into acc note.schedule_id note.created_at
           else acc)
        note_last_written_map
        legacy_notes
    in
    let state =
      { version
      ; updated_at
      ; schedules
      ; wakes
      ; note_last_written_at = Schedule_id_map.bindings note_last_written_map
      }
    in
    Ok { state; legacy_notes }
  | json -> Error ("state_of_yojson: " ^ Yojson.Safe.to_string json)
;;

let state_of_yojson json = Result.map (fun raw -> raw.state) (raw_ledger_of_yojson json)

(* Probe result for the [.last-good] recovery mirror. An absent mirror and an
   unparseable mirror are kept apart because they lead to opposite outcomes when
   the primary is also absent: no mirror means an uninitialised store ([Fresh]),
   an unparseable mirror means corruption the operator must see ([Corrupt]). *)
type recovery_outcome =
  | Recovery_loaded of raw_ledger
  | Recovery_absent
  | Recovery_unparseable of string

(* Parse the [.last-good] recovery file. A mirror that exists but yields no
   state — unreadable, unparsable, blank, or not a state — is reported as
   [Recovery_unparseable] either way. *)
let load_recovery config : recovery_outcome =
  match Workspace_utils.read_json_doc config (recovery_path config) with
  | Ok None -> Recovery_absent
  | Ok (Some recovery_json) ->
    (match raw_ledger_of_yojson recovery_json with
     | Ok raw -> Recovery_loaded raw
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
let decode_primary config path : (raw_ledger, primary_failure) Result.t =
  match Workspace_utils.read_json_doc config path with
  | Ok None -> Error Primary_absent
  | Ok (Some json) ->
    (match raw_ledger_of_yojson json with
     | Ok raw -> Ok raw
     | Error parse_err -> Error (Primary_unparseable parse_err))
  | Error read_err ->
    Error (Primary_unparseable (Workspace_utils.json_doc_error_to_string read_err))
;;

(* The decoded primary, kept with the file version it was read from. The
   ledger keeps terminal schedules until their retention passes, and it is
   read far more often than it is written -- every Keeper's world observation,
   the dashboard and the schedule tools read all of it, a runner commit writes
   it -- so a reader of an unchanged file takes the state the last miss
   decoded. [write_state] keeps the state it wrote, so its own write is not a
   miss. A miss reads, parses and decodes as one job on the domain pool when
   one is installed. *)
let decoded_primary : raw_ledger File_version_cache.t = File_version_cache.create ()

(* The Memory backend is authoritative over its local mirror. A mirror's
   inode/mtime cannot version backend state, nor distinguish two independent
   backend instances using the same workspace path. *)
let load_primary config : (raw_ledger, primary_failure) Result.t =
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
  (* A mirror may lag an acknowledged primary write. Keep it available for
     observation, with its provenance, but never authorize mutations from it. *)
  let recovered_from_mirror ~primary_err ~cause (raw : raw_ledger) =
    Log.Misc.warn
      "schedule_store: %s; loaded %d schedules and %d wakes from recovery \
       mirror %s"
      primary_err
      (List.length raw.state.schedules)
      (List.length raw.state.wakes)
      (recovery_path config);
    Recovered (raw, cause)
  in
  match load_primary config with
  | Ok raw -> Loaded raw
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
     | Primary_absent, Recovery_loaded raw ->
       recovered_from_mirror ~primary_err ~cause:Primary_missing raw
     | Primary_unparseable _, Recovery_loaded raw ->
       recovered_from_mirror ~primary_err ~cause:Primary_unusable raw
     | Primary_absent, Recovery_absent -> Fresh
     | Primary_unparseable _, Recovery_absent ->
       Corrupt { primary_err; recovery_err = None }
     | (Primary_absent | Primary_unparseable _), Recovery_unparseable recovery_err
       -> Corrupt { primary_err; recovery_err = Some recovery_err })
;;

(* Read-only accessor used by [get_schedule]. [Fresh] yields the empty default,
   and [load] narrows [Fresh] to "neither the primary nor the [.last-good] mirror
   exists"; a primary removed out-of-band arrives here as [Recovered] from the
   mirror instead of as an empty state. [Corrupt] errors rather than returning an
   empty list, so a ledger that cannot be parsed is operator-visible instead of
   masquerading as "no schedules". Does not write to disk. *)
let read_state_observed config =
  match load config with
  | Loaded raw -> Ok (raw.state, Primary_ledger)
  | Recovered (raw, cause) -> Ok (raw.state, Recovery_mirror cause)
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

(* The primary is the mutation authority. Recovery mirrors can lag successful
   commits, so promoting one would lose accepted work or revive settled wakes.
   [Fresh] means neither file exists and may initialize a new ledger. *)
let load_for_mutation_raw config : (raw_ledger, store_error) result =
  match load config with
  | Loaded raw -> Ok raw
  | Recovered (_, cause) -> Error (Primary_ledger_unavailable cause)
  | Fresh -> Ok { state = default_state (); legacy_notes = [] }
  | Corrupt { primary_err; recovery_err } ->
    Error (Corrupt_ledger { primary_err; recovery_err })
;;

(* Append-only schedule note log ([schedule_notes.jsonl]). Notes are history,
   never edited or pruned with terminal schedules; keeping them out of hot
   [schedules.json] keeps runner ticks and [.last-good] rewrites bounded by
   active and recent schedules instead of unbounded note history. *)
type notes_index =
  { rev_by_schedule_id : Schedule_domain.schedule_note list Schedule_id_map.t
        (** Newest-first by [created_at] so monotonic appends are O(1) and
            [List.rev] yields oldest-first chronological order. *)
  ; counts : int Schedule_id_map.t
  ; seen_ids : Note_id_set.t
  ; max_numeric_id : int
  ; rows_end : int
  ; file_identity : (int * int) option
        (** [(st_dev, st_ino)] of [schedule_notes.jsonl] when decoded from a
            local file, used to verify the same inode before [keep_written]. *)
  }

let empty_notes_index =
  { rev_by_schedule_id = Schedule_id_map.empty
  ; counts = Schedule_id_map.empty
  ; seen_ids = Note_id_set.empty
  ; max_numeric_id = 0
  ; rows_end = 0
  ; file_identity = None
  }
;;

let stat_identity_and_size path =
  match Unix.stat path with
  | st -> Some ((st.Unix.st_dev, st.Unix.st_ino), st.Unix.st_size)
  | exception Unix.Unix_error _ -> None
;;

let numeric_note_id_opt id =
  match int_of_string_opt id with
  | Some n when n > 0 -> Some n
  | Some _ | None -> None
;;

(* Insert into a newest-first list (descending [created_at]). Equal timestamps
   stay newer-first so [List.rev] preserves earlier-appended notes first. *)
let rec insert_newest_first (note : Schedule_domain.schedule_note) = function
  | [] -> [ note ]
  | (head : Schedule_domain.schedule_note) :: tail as list ->
    if Float.compare note.created_at head.created_at >= 0
    then note :: list
    else head :: insert_newest_first note tail
;;

let insert_note_into_index (idx : notes_index) (note : Schedule_domain.schedule_note) =
  if Note_id_set.mem note.note_id idx.seen_ids
  then idx
  else (
    let seen_ids = Note_id_set.add note.note_id idx.seen_ids in
    let max_numeric_id =
      match numeric_note_id_opt note.note_id with
      | Some n -> max idx.max_numeric_id n
      | None -> idx.max_numeric_id
    in
    let prev_rev =
      Option.value (Schedule_id_map.find_opt note.schedule_id idx.rev_by_schedule_id) ~default:[]
    in
    let prev_count =
      Option.value (Schedule_id_map.find_opt note.schedule_id idx.counts) ~default:0
    in
    { rev_by_schedule_id =
        Schedule_id_map.add note.schedule_id (insert_newest_first note prev_rev) idx.rev_by_schedule_id
    ; counts = Schedule_id_map.add note.schedule_id (prev_count + 1) idx.counts
    ; seen_ids
    ; max_numeric_id
    ; rows_end = idx.rows_end
    ; file_identity = idx.file_identity
    })
;;

let decode_notes_jsonl_bytes ~path ~rows_end ~file_identity content : (notes_index, string) result =
  let lines = String.split_on_char '\n' content in
  let rec loop line_no idx = function
    | [] -> Ok { idx with rows_end; file_identity }
    | raw :: rest ->
      let trimmed = String.trim raw in
      if String.equal trimmed ""
      then loop (line_no + 1) idx rest
      else (
        match Yojson.Safe.from_string trimmed with
        | exception Yojson.Json_error msg ->
          Error (Printf.sprintf "%s line %d: invalid JSON (%s)" path line_no msg)
        | json ->
          (match Schedule_domain.schedule_note_of_yojson json with
           | Error msg -> Error (Printf.sprintf "%s line %d: %s" path line_no msg)
           | Ok note -> loop (line_no + 1) (insert_note_into_index idx note) rest))
  in
  loop 1 empty_notes_index lines
;;

let decoded_notes : notes_index File_version_cache.t = File_version_cache.create ()

let read_notes_from_local_file path : (notes_index, string) result =
  let before_id = Option.map fst (stat_identity_and_size path) in
  let handle_rows = function
    | Fs_compat.Private_jsonl_rows.Rows_missing -> Ok empty_notes_index
    | Fs_compat.Private_jsonl_rows.Rows_present { rows; rows_end; end_offset = _ } ->
      let after_id = Option.map fst (stat_identity_and_size path) in
      let file_identity =
        match before_id, after_id with
        | Some b, Some a when b = a -> Some a
        | (Some _ | None), (Some _ | None) -> None
      in
      Domain_pool_ref.submit_cpu_or_inline ~name:"Schedule_store.decode_notes_jsonl" (fun () ->
        decode_notes_jsonl_bytes ~path ~rows_end ~file_identity rows)
  in
  match Fs_compat.read_private_jsonl_rows_locked_result path with
  | Fs_compat.Private_file_succeeded rows -> handle_rows rows
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = rows; cleanup_failure } ->
    Log.Misc.warn
      "schedule_store: schedule notes read succeeded; descriptor cleanup failed for %s: %s"
      path
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
    handle_rows rows
  | Fs_compat.Private_file_failed error ->
    Error (Fs_compat.Private_jsonl_rows.error_to_string error)
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    Error
      (Fs_compat.Private_jsonl_rows.error_to_string error
       ^ "; "
       ^ Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
;;

let load_notes_index config : (notes_index, string) result =
  let path = schedule_notes_path config in
  match config.Workspace_utils.backend with
  | Workspace_utils.FileSystem _ ->
    File_version_cache.load decoded_notes path ~decode:(fun () ->
      read_notes_from_local_file path)
  | Workspace_utils.Memory _ ->
    (match Workspace_utils.key_of_path config path with
     | Some key ->
       (match Workspace_utils.backend_get config ~key with
        | Error err ->
          Error
            (Printf.sprintf "backend_get failed for %s: %s" key (Backend_types.show_error err))
        | Ok None -> Ok empty_notes_index
        | Ok (Some content) ->
          decode_notes_jsonl_bytes
            ~path
            ~rows_end:(String.length content)
            ~file_identity:None
            content)
     | None -> read_notes_from_local_file path)
;;

let encode_note_line (note : Schedule_domain.schedule_note)
  : (string * Schedule_domain.schedule_note, string) result
  =
  let* encoded, repaired_json =
    Workspace_utils.encode_json_compact_with_value
      (Schedule_domain.schedule_note_to_yojson note)
  in
  let* repaired_note = Schedule_domain.schedule_note_of_yojson repaired_json in
  Ok ((encoded :> string), repaired_note)
;;

(* Pure preparation of any unmigrated legacy inline notes from [schedules.json].
   Validates and encodes all missing rows before any disk write runs. *)
let prepare_legacy_notes_batch ~(current_index : notes_index)
    (legacy_notes : Schedule_domain.schedule_note list)
  : ((string * Schedule_domain.schedule_note list) option, store_error) result
  =
  let missing_rev, _ =
    List.fold_left
      (fun (acc, seen) (note : Schedule_domain.schedule_note) ->
         if Note_id_set.mem note.note_id seen
         then acc, seen
         else note :: acc, Note_id_set.add note.note_id seen)
      ([], current_index.seen_ids)
      legacy_notes
  in
  let missing = List.rev missing_rev in
  match missing with
  | [] -> Ok None
  | _ :: _ ->
    let* payload, repaired_notes =
      Domain_pool_ref.submit_cpu_or_inline ~name:"Schedule_store.encode_legacy_notes" (fun () ->
        let buf = Buffer.create (List.length missing * 256) in
        let rec loop acc = function
          | [] -> Ok (Buffer.contents buf, List.rev acc)
          | note :: rest ->
            let* line, repaired = encode_note_line note in
            Buffer.add_string buf line;
            Buffer.add_char buf '\n';
            loop (repaired :: acc) rest
        in
        loop [] missing)
      |> Result.map_error (fun msg ->
        Persistence_failed ("legacy schedule notes encoding failed: " ^ msg))
    in
    Ok (Some (payload, repaired_notes))
;;

(* Precondition: for [FileSystem], caller already holds the lease fence via
   [Workspace_utils.commit_under_held_lease config (schedules_path config)].
   [keep_written] runs inside that fence only when the observed inode and
   exact byte size match the expected append end offset. *)
let append_encoded_notes_under_fence config ~(current_index : notes_index) ~notes suffix
  : (notes_index, store_error) result
  =
  ensure_dirs config;
  let path = schedule_notes_path config in
  let updated_idx = List.fold_left insert_note_into_index current_index notes in
  match config.Workspace_utils.backend with
  | Workspace_utils.Memory _ ->
    (match Workspace_utils.key_of_path config path with
     | Some key ->
       let* existing =
         match Workspace_utils.backend_get config ~key with
         | Ok None -> Ok ""
         | Ok (Some content) -> Ok content
         | Error err ->
           Error
             (Persistence_failed
                (Printf.sprintf "backend_get failed for %s: %s" key (Backend_types.show_error err)))
       in
       let next_content = existing ^ suffix in
       let* () =
         match Workspace_utils.backend_set config ~key ~value:next_content with
         | Ok () -> Ok ()
         | Error err ->
           Error
             (Persistence_failed
                (Printf.sprintf "backend_set failed for %s: %s" key (Backend_types.show_error err)))
       in
       if Workspace_utils.should_dual_write_local config
       then (
         match Fs_compat.save_file_atomic_rename_only path next_content with
         | Ok () -> ()
         | Error detail ->
           Log.Misc.warn
             "schedule_store: authoritative notes committed; local mirror write failed for %s: %s"
             path
             detail);
       File_version_cache.forget decoded_notes path;
       Ok { updated_idx with rows_end = String.length next_content; file_identity = None }
     | None ->
       Error (Persistence_failed ("schedule notes path outside workspace: " ^ path)))
  | Workspace_utils.FileSystem _ ->
    let* end_offset =
      match Fs_compat.append_private_jsonl_durable_locked_with_end_offset_result path suffix with
      | Fs_compat.Private_file_succeeded end_offset -> Ok end_offset
      | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = end_offset; cleanup_failure } ->
        Log.Misc.warn
          "schedule_store: schedule notes append committed; descriptor cleanup failed for %s: %s"
          path
          (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
        Ok end_offset
      | Fs_compat.Private_file_failed error ->
        File_version_cache.forget decoded_notes path;
        Error (Persistence_failed (Fs_compat.private_jsonl_append_error_to_string error))
      | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
        File_version_cache.forget decoded_notes path;
        Error
          (Persistence_failed
             (Fs_compat.private_jsonl_append_error_to_string error
              ^ "; "
              ^ Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
    in
    let expected_end = current_index.rows_end + String.length suffix in
    match stat_identity_and_size path with
    | Some (cur_id, cur_size)
      when end_offset = expected_end
           && cur_size = end_offset
           && (match current_index.file_identity with
               | None -> current_index.rows_end = 0
               | Some prev_id -> prev_id = cur_id) ->
      let next_idx = { updated_idx with rows_end = end_offset; file_identity = Some cur_id } in
      File_version_cache.keep_written decoded_notes path next_idx;
      Ok next_idx
    | Some _ | None ->
      File_version_cache.forget decoded_notes path;
      (* The note append already committed durably; never report a reload error
         as [Persistence_failed] that could invite a duplicate retry. *)
      (match read_notes_from_local_file path with
       | Ok refreshed -> Ok refreshed
       | Error msg ->
         Log.Misc.warn
           "schedule_store: notes committed; post-append reload failed for %s: %s"
           path
           msg;
         Ok { updated_idx with rows_end = end_offset; file_identity = None })
;;

let read_notes_for_schedule_result config ~schedule_id =
  let* legacy_notes =
    match load config with
    | Loaded raw -> Ok raw.legacy_notes
    | Recovered (raw, _) -> Ok raw.legacy_notes
    | Fresh -> Ok []
    | Corrupt { primary_err; recovery_err } ->
      Error (Corrupt_notes_ledger (Corrupt_read_ledger { primary_err; recovery_err }))
  in
  let* notes_idx =
    load_notes_index config
    |> Result.map_error (fun detail -> Corrupt_notes_log detail)
  in
  let merged =
    match legacy_notes with
    | [] -> notes_idx
    | _ :: _ -> List.fold_left insert_note_into_index notes_idx legacy_notes
  in
  let rev_notes =
    Option.value
      (Schedule_id_map.find_opt schedule_id merged.rev_by_schedule_id)
      ~default:[]
  in
  Ok (List.rev rev_notes)
;;

let read_notes_for_schedule config ~schedule_id =
  match read_notes_for_schedule_result config ~schedule_id with
  | Ok notes -> notes
  | Error (Corrupt_notes_ledger (Corrupt_read_ledger { primary_err; recovery_err })) ->
    raise (Corrupt_ledger_exn { primary_err; recovery_err })
  | Error (Corrupt_notes_log detail) ->
    failwith ("schedule notes log could not be read: " ^ detail)
;;

let encode_state_payload state =
  Domain_pool_ref.submit_cpu_or_inline ~name:"Schedule_store.write_state" (fun () ->
    let raw_json = state_to_yojson state in
    let+ content, json =
      Workspace_utils.encode_json_compact_with_value raw_json
    in
    let reread =
      if json == raw_json then Ok { state; legacy_notes = [] }
      else raw_ledger_of_yojson json
    in
    content, reread)
  |> Result.map_error (fun msg -> Persistence_failed ("ledger encoding failed: " ^ msg))
;;

(* Precondition: caller already holds the lease fence via
   [Workspace_utils.commit_under_held_lease config (schedules_path config)].
   Write the primary ledger, update [decoded_primary], then mirror to
   [.last-good] inside the same fence so a lost lease cannot clobber a newer
   holder's primary or recovery mirror. *)
let write_encoded_state_under_fence config ~content ~reread =
  ensure_dirs config;
  let path = schedules_path config in
  let written = Workspace_utils.write_encoded_json_commit_result config path content in
  (* Every writer of the ledger holds its lock and lease fence, and the
     FileSystem backend renames a new file into place, so after a write that
     landed the file at [path] is the bytes [reread] was decoded for. Anything
     else -- a write that failed and may or may not have landed, a Memory
     backend whose local file is a mirror, a state that does not decode from
     its own encoding -- leaves the file a version nothing is kept for. *)
  (match written, reread, config.Workspace_utils.backend with
   | Ok { Workspace_utils.mirror_error = None }, Ok written_raw, Workspace_utils.FileSystem _ ->
     File_version_cache.keep_written decoded_primary path written_raw
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

let publish_under_ledger_lease config publish =
  match Workspace_utils.commit_under_held_lease config (schedules_path config) publish with
  | Ok outcome -> outcome
  | Error refusal ->
    Error (Persistence_failed (Workspace_utils.lease_commit_refusal_to_string refusal))
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
let with_observed_mutation_core config f =
  let attempted = ref false in
  let mark_attempted () = attempted := true in
  let result =
    try
      Ok (Workspace_utils.with_file_lock config (schedules_path config)
            (fun () -> f ~mark_attempted))
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

let with_observed_mutation config f =
  with_observed_mutation_core config (fun ~mark_attempted ->
    let observed_write ~legacy_notes config state =
      (* Mark attempted at entry so encoding/publication failures still trigger
         observer revalidation, while keeping all disk I/O after encoding. *)
      mark_attempted ();
      let* content, reread = encode_state_payload state in
      let* legacy_plan =
        match legacy_notes with
        | [] -> Ok None
        | _ :: _ ->
          let* current_index =
            load_notes_index config
            |> Result.map_error (fun msg ->
              Persistence_failed ("schedule notes load failed: " ^ msg))
          in
          let* batch = prepare_legacy_notes_batch ~current_index legacy_notes in
          Ok (Option.map (fun (payload, notes) -> current_index, payload, notes) batch)
      in
      publish_under_ledger_lease config (fun () ->
        let* () =
          match legacy_plan with
          | None -> Ok ()
          | Some (current_index, payload, notes) ->
            let* _ =
              append_encoded_notes_under_fence config ~current_index ~notes payload
            in
            Ok ()
        in
        write_encoded_state_under_fence config ~content ~reread)
    in
    f observed_write)
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

let bump_state ?note_last_written_at state ~schedules ~wakes =
  let stamp = now () in
  let note_last_written_at =
    Option.value note_last_written_at ~default:state.note_last_written_at
  in
  { version = state.version + 1
  ; updated_at = stamp
  ; schedules
  ; wakes = prune_wakes ~now:stamp ~schedules wakes
  ; note_last_written_at
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
      (fun written_about (schedule_id, created_at) ->
         keep written_about schedule_id created_at)
      written_about
      state.note_last_written_at
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
  ; oldest_finished_last_written : float option
  }

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

(* Notes (task-381): the store owns identity and ordering. [note_id] stays a
   monotonic counter above both [state.version] and the highest numeric id in
   [schedule_notes.jsonl], so ids never collide after deletes, restarts, or
   partial failures. Note appends intentionally bypass [bump_state] so wakes
   are not pruned, and append the note body to [schedule_notes.jsonl] instead
   of rewriting note history inside [schedules.json]. *)
let append_note config ~schedule_id ~author_id ~author_kind ~body ~now =
  with_observed_mutation_core config (fun ~mark_attempted ->
    let* raw = load_for_mutation_raw config in
    let state = raw.state in
    match find_schedule state ~schedule_id with
    | None -> Error Schedule_not_found
    | Some _ ->
      let* notes_idx =
        load_notes_index config
        |> Result.map_error (fun msg ->
          Persistence_failed ("schedule notes load failed: " ^ msg))
      in
      mark_attempted ();
      let* legacy_batch =
        prepare_legacy_notes_batch ~current_index:notes_idx raw.legacy_notes
      in
      let legacy_max_id =
        List.fold_left
          (fun acc (n : Schedule_domain.schedule_note) ->
             match numeric_note_id_opt n.note_id with
             | Some id -> max acc id
             | None -> acc)
          notes_idx.max_numeric_id
          raw.legacy_notes
      in
      let next_numeric_id = max (state.version + 1) (legacy_max_id + 1) in
      let note =
        { Schedule_domain.note_id = string_of_int next_numeric_id
        ; schedule_id
        ; author_id
        ; author_kind
        ; created_at = now
        ; body
        }
      in
      let* encoded_line, repaired_note =
        encode_note_line note
        |> Result.map_error (fun msg ->
          Persistence_failed ("schedule note encoding failed: " ^ msg))
      in
      let note_last_written_at =
        upsert_note_last_written_at state.note_last_written_at ~schedule_id ~ts:now
      in
      let next_state =
        { version = state.version + 1
        ; updated_at = now
        ; schedules = state.schedules
        ; wakes = state.wakes
        ; note_last_written_at
        }
      in
      let* content, reread = encode_state_payload next_state in
      (* All validation and encoding succeeded. Enter a single lease-fenced
         publication section: flush missing legacy notes first (if any), commit
         the slim ledger + recovery mirror, then append the new note line. *)
      publish_under_ledger_lease config (fun () ->
        let* notes_idx =
          match legacy_batch with
          | None -> Ok notes_idx
          | Some (payload, repaired_legacy) ->
            append_encoded_notes_under_fence config ~current_index:notes_idx
              ~notes:repaired_legacy payload
        in
        let* () = write_encoded_state_under_fence config ~content ~reread in
        let* next_idx =
          append_encoded_notes_under_fence config ~current_index:notes_idx
            ~notes:[ repaired_note ] (encoded_line ^ "\n")
        in
        let count =
          Option.value (Schedule_id_map.find_opt schedule_id next_idx.counts) ~default:0
        in
        Ok (repaired_note, count)))
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

let expiry_reaches_first_due ~runner_tick_sec (request : schedule_request) =
  Schedule_domain.expiry_reaches_first_due
    ~runner_tick_sec
    ~due_at:request.due_at
    ~expires_at:request.expires_at
  |> Result.map_error (fun expiry ->
    Expiry_before_reachable_due { schedule_id = request.schedule_id; expiry })
;;

let insert_request config ~runner_tick_sec (request : Schedule_domain.schedule_request) =
  with_observed_mutation config (fun write_state ->
    let* raw = load_for_mutation_raw config in
    let state = raw.state in
    match find_schedule state ~schedule_id:request.schedule_id with
    | Some _ -> Error Schedule_already_exists
    | None ->
      let* () = validate_initial_request request in
      let* () = interval_fires_as_declared ~runner_tick_sec request in
      let* () = expiry_reaches_first_due ~runner_tick_sec request in
      let schedules = request :: state.schedules in
      let next_state =
        bump_state state ~schedules ~wakes:state.wakes
      in
      let* () = write_state ~legacy_notes:raw.legacy_notes config next_state in
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
    let* raw = load_for_mutation_raw config in
    let state = raw.state in
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
        let* () = expiry_reaches_first_due ~runner_tick_sec request in
        let schedules = replace_schedule state.schedules request in
        let next_state = bump_state state ~schedules ~wakes:state.wakes in
        let* () = write_state ~legacy_notes:raw.legacy_notes config next_state in
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
    let* raw = load_for_mutation_raw config in
    let state = raw.state in
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
           bump_state state ~schedules ~wakes
         in
         let* () = write_state ~legacy_notes:raw.legacy_notes config next_state in
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
  let note_last_written_at =
    List.filter
      (fun (schedule_id, _) -> holds_a_kept_schedule schedule_id)
      state.note_last_written_at
  in
  ( kept
  , List.filter
      (fun (wake : Schedule_domain.wake_record) ->
         holds_a_kept_schedule wake.Schedule_domain.schedule_id)
      state.wakes
  , note_last_written_at
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
    let* raw = load_for_mutation_raw config in
    let state = raw.state in
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
    let schedules, wakes, note_last_written_at, forgotten =
      if now < state.updated_at
      then schedules, state.wakes, state.note_last_written_at, 0
      else if changed = 0 && nothing_to_forget ()
      then schedules, state.wakes, state.note_last_written_at, 0
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
      let next_state =
        bump_state ~note_last_written_at state ~schedules ~wakes
      in
      let* () = write_state ~legacy_notes:raw.legacy_notes config next_state in
      Ok (next_state, changed)))
;;

let reschedule_due_recurring config ~now ~schedule_ids =
  let target_ids = Schedule_id_set.of_list schedule_ids in
  with_observed_mutation config (fun write_state ->
    let* raw = load_for_mutation_raw config in
    let state = raw.state in
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
        bump_state state ~schedules ~wakes:state.wakes
      in
      let* () = write_state ~legacy_notes:raw.legacy_notes config next_state in
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

let load_authoritative_raw config ~schedule_id =
  match load_primary config with
  | Ok raw -> Ok raw
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
    let* raw = load_authoritative_raw config ~schedule_id in
    let state = raw.state in
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
        let next_state = bump_state state ~schedules ~wakes in
        let* () = write_state ~legacy_notes:raw.legacy_notes config next_state in
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
    let* raw = load_authoritative_raw config ~schedule_id in
    let state = raw.state in
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
        let next_state = bump_state state ~schedules ~wakes in
        let* () = write_state ~legacy_notes:raw.legacy_notes config next_state in
        Ok updated)
;;

let accept_running ?finished_at config ~now ~attempt ?detail () =
  settle_running config ~now ~finished_at:(Option.value finished_at ~default:now) ~attempt (Accept detail)
;;

let cancel_matching ?withdraw_queued_wakes config ~should_cancel =
  with_observed_mutation config (fun write_state ->
    let* raw = load_for_mutation_raw config in
    let state = raw.state in
    let rec cancel schedules changed matched = function
      | [] -> Ok (List.rev schedules, changed, List.rev matched)
      | (request : schedule_request) :: rest when not (should_cancel request) ->
        cancel (request :: schedules) changed matched rest
      | ({ status = (Scheduled | Due); _ } as request) :: rest ->
        cancel ({ request with status = Cancelled } :: schedules) true (request :: matched) rest
      | ({ status = Running; _ } as request) :: _ ->
        Error
          (transition_refused state request ~attempted:Cancel_for_consumer_retirement)
      (* Already terminal: nothing to cancel in the ledger, and no error to raise,
         but still pass to [withdraw_queued_wakes] so already-delivered stimuli
         waiting in the consumer's queue are withdrawn under the ledger lock. *)
      | ({ status = Succeeded | Failed | Cancelled | Expired; _ } as request) :: rest ->
        cancel (request :: schedules) changed (request :: matched) rest
    in
    let* schedules, changed, matched = cancel [] false [] state.schedules in
    let* () =
      match withdraw_queued_wakes, matched with
      | None, ([] | _ :: _) | Some _, [] -> Ok ()
      | Some withdraw, (_ :: _ as matched) ->
        withdraw matched
        |> Result.map_error (fun detail ->
          Persistence_failed ("scheduled wake withdrawal failed: " ^ detail))
    in
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
      write_state ~legacy_notes:raw.legacy_notes config (bump_state state ~schedules ~wakes)
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
    let* raw = load_for_mutation_raw config in
    let state = raw.state in
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
      let next_state = bump_state state ~schedules ~wakes in
      let* () = write_state ~legacy_notes:raw.legacy_notes config next_state in
      Ok (next_state, recovered))
;;

let fail_due_candidate ?attempted_at config ~now ~(candidate : schedule_request) ~error =
  (* The consumer refused the payload before any work began, so the attempt
     starts and ends at the same instant: [attempted_at] (default [now]). *)
  let attempted_at = Option.value attempted_at ~default:now in
  let schedule_id = candidate.schedule_id in
  with_observed_mutation config (fun write_state ->
    let* raw = load_authoritative_raw config ~schedule_id in
    let state = raw.state in
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
        let next_state = bump_state state ~schedules ~wakes in
        let* () = write_state ~legacy_notes:raw.legacy_notes config next_state in
        Ok updated)
;;

let prune_completed config =
  with_observed_mutation config (fun write_state ->
    let* raw = load_for_mutation_raw config in
    let state = raw.state in
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
    let note_last_written_at =
      List.filter
        (fun (schedule_id, _) -> Schedule_id_set.mem schedule_id remaining_ids)
        state.note_last_written_at
    in
    if pruned_count = 0
       && List.length wakes = List.length state.wakes
       && List.length note_last_written_at = List.length state.note_last_written_at
    then
      Ok (state, 0)
    else
      let next_state = bump_state ~note_last_written_at state ~schedules ~wakes in
      let* () = write_state ~legacy_notes:raw.legacy_notes config next_state in
      Ok (next_state, pruned_count))
;;

let due_wake_candidates state =
  state.schedules
  |> List.filter is_due_wake_candidate
;;
