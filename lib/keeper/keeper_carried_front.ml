(** Keeper_carried_front — see the interface for the contract. *)

type source =
  | Ledger
  | Turn_record of { turn : int }
  | Turn_start_after_refusal
  | This_turn_start_after_refusal
  | Turn_start_at_max_context
  | Librarian_point_at_max_context

type seed =
  { first_atom : int
  ; front : Model_input_front.t
  ; source : source
  }

type origin =
  | Carried of source
  | Covered of { end_atom : int }
  | Turn_start of { end_atom : int }
  | Turn_start_unknown of { reason : string }

type turn_start =
  | Turn_boundary of { end_atom : int }
  | Turn_boundary_unknown of { reason : string }

let turn_start_to_string = function
  | Turn_boundary { end_atom } -> Printf.sprintf "boundary:%d" end_atom
  | Turn_boundary_unknown { reason } -> "unknown:" ^ reason
;;

let of_ledger (ledger : Keeper_model_input_ledger.t) =
  match ledger.last.ends with
  | Keeper_model_input_ledger.No_atom_carried -> None
  | Keeper_model_input_ledger.Carried_atoms { front_digest; end_digest = _ } ->
    Some { first_atom = ledger.last.first_atom; front = Model_input_front.At_atom front_digest; source = Ledger }
;;

type composer =
  | Composes_from_the_history
  | Hands_over_its_own_list
  | Not_materialized

let composer_of_execution = function
  | Runtime_execution.Agent_core _ -> Composes_from_the_history
  | Runtime_execution.Codex_app_server _
  | Runtime_execution.Claude_code _
  | Runtime_execution.Antigravity_cli _
  | Runtime_execution.Acp _ -> Hands_over_its_own_list
;;

let composer_of_runtime = function
  | Some (runtime : Runtime_instance.t) -> composer_of_execution runtime.Runtime_instance.execution
  | None -> Not_materialized
;;

let composer_to_string = function
  | Composes_from_the_history -> "composes_from_the_history"
  | Hands_over_its_own_list -> "hands_over_its_own_list"
  | Not_materialized -> "not_materialized"
;;

(* The response-observed field certifies this range at the producer. A
   runtime can leave today's catalog without changing that historical fact;
   [for_history] checks whether its opening position still names this history.
   Historical motivation: #36997 records a 2026-09-18 incident where skipping
   official-client records resent 13 MB per candidate on Agent Core turn 4059,
   after 20 claude_code turns. Preserve that response evidence, subject to the
   same history-position check. *)
(* A turn that skipped no atom names no front. Its opening atom is
   the oldest one because nothing was skipped, not because a later turn may
   start there, so reading it as a seed sends the next start back to the
   beginning. Treating a full-history response as a narrowed range would undo
   the carried front for every official-client start after it. A history short
   enough to go whole loses nothing: seeding its oldest atom and seeding
   nothing both carry everything. *)
let carried_front_of_window (window : Turn_record.model_input_window) =
  if window.Turn_record.transmitted_atoms > 0
     && window.Turn_record.transmitted_atoms >= window.Turn_record.total_atoms
  then None
  else
    Some
      ( window.Turn_record.total_atoms - window.Turn_record.transmitted_atoms
      , window.Turn_record.model_input_front )
;;

let of_records ~trace_id (records : Turn_record.t list) =
  List.fold_left
    (fun newest (record : Turn_record.t) ->
       match
         record.Turn_record.response_observed_model_input
       with
       | Some observed
         when String.equal record.Turn_record.trace_id trace_id ->
         let turn = record.Turn_record.absolute_turn in
         (match newest with
          | Some (newest_turn, _) when newest_turn > turn -> newest
          | Some _ | None ->
            (match carried_front_of_window observed.Turn_record.window with
             | None -> newest
             | Some (first_atom, front) ->
               Some (turn, { first_atom; front; source = Turn_record { turn } })))
       | Some _ | None -> newest)
    None
    records
  |> Option.map snd
;;

type unreadable_records =
  { count : int
  ; first_reason : string
  }

type refused_start =
  { runtime_profile : string
  ; first_atom : int
  ; front : Model_input_front.t
  ; turn : int
  }

(* The whole refused range counts, a refused whole history too: its start is
   atom 0, where [carried_front_of_window] names no seed. *)
let refused_start_of_record (record : Turn_record.t) =
  Option.map
    (fun (refused : Turn_record.refused_model_input) ->
       { runtime_profile = refused.runtime_profile
       ; first_atom =
           refused.window.Turn_record.total_atoms
           - refused.window.Turn_record.transmitted_atoms
       ; front = refused.window.Turn_record.model_input_front
       ; turn = record.Turn_record.absolute_turn
       })
    record.Turn_record.refused_model_input
;;

(* What the stored records say about one runtime's refusal, read newest first
   in stored order: a direct retry may reuse its turn number, so the turn does
   not order two records of one turn. Only that runtime's own records decide.
   A response from it answers every refusal it made before, the one its own
   record carries too, so a record's response is read before its refusal.
   Another runtime's response says nothing about this runtime's window
   (#54719): a lane that fails over and comes back still opens past the
   refused start. *)
type refusal_scan =
  | Undecided
  | Answered
  | Refused of refused_start

let scan_refusal ~runtime_id scan (record : Turn_record.t) =
  match scan with
  | Answered | Refused _ -> scan
  | Undecided ->
    (match record.Turn_record.response_observed_model_input, refused_start_of_record record with
     | Some { Turn_record.runtime_profile; window = _ }, _
       when String.equal runtime_profile runtime_id -> Answered
     | _, Some refused when String.equal refused.runtime_profile runtime_id -> Refused refused
     | (Some _ | None), (Some _ | None) -> Undecided)
;;

let refused_start_of_scan = function
  | Refused refused -> Some refused
  | Undecided | Answered -> None
;;

type seed_read =
  { seed : seed option
  ; refused_start : refused_start option
  ; unreadable : unreadable_records option
  ; boundary_error : string option
  }

type seed_reader = runtime_id:string -> seed_read

let no_seed_read =
  { seed = None; refused_start = None; unreadable = None; boundary_error = None }
;;

let warn_seed_read_failures ~keeper_name ~runtime_id (read : seed_read) =
  Option.iter
    (fun (unreadable : unreadable_records) ->
       Log.Keeper.warn
         ~keeper_name
         "model input carried range seed read skipped unreadable turn records \
          runtime=%s unreadable=%d first_reason=%s"
         runtime_id
         unreadable.count
         unreadable.first_reason)
    read.unreadable;
  Option.iter
    (fun detail ->
       Log.Keeper.warn
         ~keeper_name
         "model input carried range seed read refused the turn log \
          runtime=%s detail=%s"
         runtime_id
         detail)
    read.boundary_error
;;

(* A JSON row that does not decode as a turn record gives no seed, and it is
   counted: "no record" and "records that could not be decoded" are different
   answers to why a turn started without a front. A line that is not JSON at
   all never reaches here; [Dated_jsonl.read_recent] skips it uncounted. *)
let seed_read_of_rows ~trace_id ~runtime_id rows =
  let records_rev, unreadable =
    List.fold_left
      (fun (records, unreadable) json ->
         match Turn_record.of_json json with
         | Ok record -> record :: records, unreadable
         | Error reason ->
           ( records
           , Some
               (match unreadable with
                | None -> { count = 1; first_reason = reason }
                | Some (seen : unreadable_records) -> { seen with count = seen.count + 1 }) ))
      ([], None)
      rows
  in
  let records = List.rev records_rev in
  let refusal =
    List.fold_left
      (fun scan (record : Turn_record.t) ->
         if String.equal record.Turn_record.trace_id trace_id
         then scan_refusal ~runtime_id scan record
         else scan)
      Undecided
      records_rev
  in
  { seed = of_records ~trace_id records
  ; refused_start = refused_start_of_scan refusal
  ; unreadable
  ; boundary_error = None
  }
;;

(* Why the turn log gave no generation boundary. Each one refuses the seed:
   the boundary it could not read may stand above any record the scan would
   take. *)
type floor_refusal =
  | Log_unread of Private_jsonl_scan.error
  | Line_undecodable of
      { offset : int
      ; reason : Keeper_turn_log_store.undecodable
      }
  | Line_out_of_order of
      { offset : int
      ; error : Keeper_turn_log.order_error
      }

let order_error_to_string : Keeper_turn_log.order_error -> string = function
  | Not_started -> "a line comes before the log's start"
  | Started_twice -> "the log starts twice"
  | Opened_while_open { opened } ->
    Printf.sprintf "a turn opens while the turn opened at %d is open" opened
  | Closed_without_open -> "a turn closes with no turn open"
  | Closed_another_turn { opened; closed } ->
    Printf.sprintf "the turn opened at %d closes while the one opened at %d is open" closed
      opened
  | Own_after_reset { opened } ->
    Printf.sprintf "the turn opened at %d names messages as its own after a reset" opened
;;

let floor_refusal_to_string = function
  | Log_unread error -> "turn log unread: " ^ Private_jsonl_scan.error_to_string error
  | Line_undecodable { offset; reason = Not_json } ->
    Printf.sprintf "turn log line at %d is not JSON" offset
  | Line_undecodable { offset; reason = Malformed error } ->
    Printf.sprintf
      "turn log line at %d does not decode: %s"
      offset
      (Keeper_memory_os_types.wire_error_to_string error)
  | Line_out_of_order { offset; error } ->
    Printf.sprintf "turn log line at %d is out of order: %s" offset
      (order_error_to_string error)
;;

(* RFC librarian-call-only-proposes §11.2. A reset that drops the history
   counts; a recovering purge keeps the history it names and does not. *)
let counts_as_restart : Keeper_turn_log.reset_cause -> bool = function
  | Announced Cleared | Unannounced -> true
  | Announced Recovered -> false
;;

(* One pass over the turn log, oldest line first. [open_turn] is the open
   turn's number when that turn is this trace's. [closed] is the highest
   number among this trace's closed turns so far, whatever their outcome.
   At each counted reset of this trace, [floor] becomes [closed]: a turn
   that closes after the reset, the turn whose tool cleared the history
   among them, is above the floor. *)
type floor_scan =
  { position : Keeper_turn_log.position
  ; open_turn : int option
  ; closed : int option
  ; floor : int option
  }

let floor_scan_start =
  { position = Keeper_turn_log.Nothing_written; open_turn = None; closed = None; floor = None }
;;

let floor_step ~trace_id scan (line : Keeper_turn_log.line) =
  match line with
  | Log_started _ -> scan
  | Opened { turn_ref; _ } ->
    let open_turn =
      if String.equal (Ids.Turn_ref.trace_id turn_ref) trace_id
      then Some (Ids.Turn_ref.absolute_turn turn_ref)
      else None
    in
    { scan with open_turn }
  | Closed _ ->
    let closed =
      match scan.open_turn, scan.closed with
      | Some turn, Some closed -> Some (Int.max turn closed)
      | Some turn, None -> Some turn
      | None, (Some _ | None) -> scan.closed
    in
    { scan with open_turn = None; closed }
  | Reset { cause; after; _ } ->
    if counts_as_restart cause && String.equal after.trace trace_id
    then { scan with floor = scan.closed }
    else scan
;;

(* The lines from [from] on, folded onto [scan], with where the line after
   the last one read starts. [Keeper_turn_log.step] keeps the order, so a
   [Closed] always closes the turn [open_turn] names. A line that does not
   decode or breaks the order stops the read and refuses the floor instead
   of being passed over. A kept scan resumes at its [from]; when that offset
   no longer starts a line, the file is not the one the scan read, and it is
   read again from its first line. *)
let rec read_generation_floor ~path ~trace_id ~from scan =
  match
    Keeper_turn_log_store.fold_from path ~from ~init:(scan, from)
      ~f:(fun (scan, (_ : int)) (scanned : Keeper_turn_log_store.scanned) ->
        match scanned.line with
        | Error reason ->
          Private_jsonl_scan.Stop (Line_undecodable { offset = scanned.at; reason })
        | Ok line ->
          (match Keeper_turn_log.step scan.position ~offset:scanned.at line with
           | Error error ->
             Private_jsonl_scan.Stop (Line_out_of_order { offset = scanned.at; error })
           | Ok position ->
             Private_jsonl_scan.Continue
               (floor_step ~trace_id { scan with position } line, scanned.past)))
  with
  | Ok (Private_jsonl_scan.Reached_end read) -> Ok read
  | Ok (Private_jsonl_scan.Stopped refusal) -> Error refusal
  | Error (Private_jsonl_scan.Scan_failed error) -> Error (Log_unread error)
  | Error (Private_jsonl_scan.Not_a_row_start { from = (_ : int); length = (_ : int) }) ->
    if from > 0
    then read_generation_floor ~path ~trace_id ~from:0 floor_scan_start
    else
      (* Offset 0 starts a line in any file, so the file changed under the
         read. *)
      Error (Log_unread Private_jsonl_scan.Moved)
;;

(* A floor that was read is kept per log and trace with the scan behind it,
   where that scan stopped, and the identity the file had before the read.
   A log that has not changed since is not read again: an idle Keeper's next
   read reuses the floor. A log that grew is read from where the scan
   stopped: the log only appends lines and cuts a torn fragment after its
   last one, so the lines before that point are as the scan read them. A log
   replaced since, or shorter than that point, is read from its first line.
   A failed read is not kept. *)
type floor_kept =
  { identity : int * int * int * float
  ; through : int (* Where the line after the last one read starts. *)
  ; scan : floor_scan
  }

let floor_kept : (string * string, floor_kept) Hashtbl.t = Hashtbl.create 16
let floor_kept_mu = Stdlib.Mutex.create ()

let file_identity path =
  match Unix.stat path with
  | stats -> Some (stats.Unix.st_dev, stats.Unix.st_ino, stats.Unix.st_size, stats.Unix.st_mtime)
  | exception Unix.Unix_error _ -> None
;;

let resume_point identity kept =
  match identity, kept with
  | Some (dev, ino, size, (_ : float)), Some kept ->
    let kept_dev, kept_ino, (_ : int), (_ : float) = kept.identity in
    if Int.equal dev kept_dev && Int.equal ino kept_ino && size >= kept.through
    then kept.through, kept.scan
    else 0, floor_scan_start
  | (Some _ | None), (Some _ | None) -> 0, floor_scan_start
;;

let current_generation_floor ~config ~keeper_name ~trace_id =
  let keepers_dir = Workspace.keepers_runtime_dir config in
  let path = Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name in
  let key = path, trace_id in
  let identity = file_identity path in
  let kept = Stdlib.Mutex.protect floor_kept_mu (fun () -> Hashtbl.find_opt floor_kept key) in
  match identity, kept with
  | Some identity, Some kept when kept.identity = identity -> Ok kept.scan.floor
  | (Some _ | None), (Some _ | None) ->
    let from, scan = resume_point identity kept in
    let read = read_generation_floor ~path ~trace_id ~from scan in
    (match identity, read with
     | Some identity, Ok (scan, through) ->
       Stdlib.Mutex.protect floor_kept_mu (fun () ->
         Hashtbl.replace floor_kept key { identity; through; scan })
     | None, (Ok _ | Error _) | Some _, Error _ -> ());
    Result.map (fun (scan, (_ : int)) -> scan.floor) read
;;

let read_seed ~config ~keeper_name ~trace_id ~runtime_id =
  let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
  match current_generation_floor ~config ~keeper_name ~trace_id with
  | Error refusal ->
    { no_seed_read with boundary_error = Some (floor_refusal_to_string refusal) }
  | Ok generation_floor ->
    let unreadable = ref None in
    let seed = ref None in
    let refusal = ref Undecided in
    let exception Trace_boundary in
    (* Count observations, not intervening rows. A direct retry may reuse its
       turn number, so the last stored response is the latest observation.
       A different trace is the durable generation boundary; a counted reset
       in the turn log is the same-trace boundary after a clear. The scan
       ends once it holds the seed and [runtime_id]'s own newest response or
       refusal; another runtime's response may stand between the two. *)
    (try
       ignore
         (Dated_jsonl.collect_matching store 1 ~f:(fun json ->
            match Turn_record.of_json json with
            | Ok record when not (String.equal record.Turn_record.trace_id trace_id) ->
              raise_notrace Trace_boundary
            | Ok record
              when (match generation_floor with
                    | Some floor -> record.Turn_record.absolute_turn <= floor
                    | None -> false) ->
              raise_notrace Trace_boundary
            | Ok record ->
              refusal := scan_refusal ~runtime_id !refusal record;
              (match !seed with
               | Some _ -> ()
               | None -> seed := of_records ~trace_id [ record ]);
              (match !seed, !refusal with
               | Some _, (Answered | Refused _) -> Some ()
               | None, _ | Some _, Undecided -> None)
            | Error first_reason ->
              let count =
                match !unreadable with
                | None -> 1
                | Some (seen : unreadable_records) -> seen.count + 1
              in
              unreadable := Some { count; first_reason };
              None)
          : unit list)
     with Trace_boundary -> ());
    { seed = !seed
    ; refused_start = refused_start_of_scan !refusal
    ; unreadable = !unreadable
    ; boundary_error = None
    }
;;

type dropped_front =
  | Front_atom_missing
  | Front_message_differs

let for_history ~digest_at (seed : seed) =
  let checked atom expected =
    match digest_at atom with
    | None -> Error Front_atom_missing
    | Some digest when String.equal digest expected -> Ok seed
    | Some _ -> Error Front_message_differs
  in
  match seed.front with
  | Model_input_front.At_atom digest -> checked seed.first_atom digest
  | Model_input_front.After_history digest -> checked (seed.first_atom - 1) digest
  (* A floor (#39013) names no front: its position is the history's atom
     count at the floor turn, past every atom, so it drops whatever the
     history holds. Only an offered-empty history (first_atom = 0) keeps
     an Empty_history seed. *)
  | Model_input_front.Empty_history when seed.first_atom > 0 ->
    Error Front_atom_missing
  | Model_input_front.Empty_history -> Ok seed
;;

let refused_start_for_history ~digest_at (refused : refused_start) =
  for_history
    ~digest_at
    { first_atom = refused.first_atom
    ; front = refused.front
    ; source = Turn_record { turn = refused.turn }
    }
  |> Result.map (fun (_ : seed) -> refused)
;;

let dropped_front_to_string = function
  | Front_atom_missing -> "front_atom_missing"
  | Front_message_differs -> "front_message_differs"
;;

let clamp ~atom_count first_atom =
  if atom_count <= 0 then 0 else max 0 (min first_atom (atom_count - 1))
;;

let clamp_seed ~atom_count (seed : seed) =
  match seed.front with
  | Model_input_front.At_atom _ -> clamp ~atom_count seed.first_atom
  | Model_input_front.After_history _ | Model_input_front.Empty_history ->
    max 0 (min seed.first_atom atom_count)
;;

let newest_atom ~atom_count = if atom_count <= 0 then 0 else atom_count - 1

let warn_range_opens_on_newest_atom ~keeper_name ~reason =
  Log.Keeper.warn
    ~keeper_name
    "turn start unknown, the range opens on the newest atom alone: %s"
    reason
;;

let warn_if_origin_is_unknown_start ~keeper_name = function
  | Turn_start_unknown { reason } -> warn_range_opens_on_newest_atom ~keeper_name ~reason
  | Carried _ | Covered _ | Turn_start _ -> ()
;;

let source_to_string = function
  | Ledger -> "ledger"
  | Turn_record { turn } -> Printf.sprintf "turn_record#%d" turn
  | Turn_start_after_refusal -> "turn_start_after_refusal"
  | This_turn_start_after_refusal -> "this_turn_start_after_refusal"
  | Turn_start_at_max_context -> "turn_start_at_max_context"
  | Librarian_point_at_max_context -> "librarian_point_at_max_context"
;;

let seed_to_json (seed : seed) =
  `Assoc
    [ "first_atom", `Int seed.first_atom
    ; "front", Model_input_front.to_json seed.front
    ; "source", `String (source_to_string seed.source)
    ]
;;

let origin_to_string = function
  | Covered _ -> "covered"
  | Carried source -> source_to_string source
  | Turn_start _ -> "turn_start"
  | Turn_start_unknown _ -> "turn_start_unknown"
;;

let origin_to_json = function
  | Carried Ledger -> `Assoc [ "kind", `String "ledger" ]
  | Carried (Turn_record { turn }) ->
    `Assoc [ "kind", `String "turn_record"; "turn", `Int turn ]
  | Carried Turn_start_after_refusal ->
    `Assoc [ "kind", `String "turn_start_after_refusal" ]
  | Carried This_turn_start_after_refusal ->
    `Assoc [ "kind", `String "this_turn_start_after_refusal" ]
  | Carried Turn_start_at_max_context ->
    `Assoc [ "kind", `String "turn_start_at_max_context" ]
  | Carried Librarian_point_at_max_context ->
    `Assoc [ "kind", `String "librarian_point_at_max_context" ]
  | Covered { end_atom } ->
    `Assoc [ "kind", `String "covered"; "end_atom", `Int end_atom ]
  | Turn_start { end_atom } ->
    `Assoc [ "kind", `String "turn_start"; "end_atom", `Int end_atom ]
  | Turn_start_unknown { reason } ->
    `Assoc [ "kind", `String "turn_start_unknown"; "reason", `String reason ]
;;
