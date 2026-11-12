(** Keeper_carried_front — see the interface for the contract. *)

type source =
  | Ledger
  | Turn_record of { turn : int }
  | Turn_start_after_seed_refusal
  | Turn_start_after_librarian_refusal
  | This_turn_start_after_seed_refusal
  | This_turn_start_after_librarian_refusal

type seed =
  { first_atom : int
  ; front : Model_input_front.t
  ; source : source
  }

type origin =
  | Carried of source
  | Librarian_snapshot of { end_atom : int; boundary_line : int }
  | Librarian_progress of { end_atom : int }
  | Past_librarian_point of { librarian_end_atom : int; source : source }
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
  | Runtime_execution.Muse_serve _
  | Runtime_execution.Vibe_cli _ -> Hands_over_its_own_list
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

type seed_read =
  { seed : seed option
  ; refused_start : refused_start option
  ; unreadable : unreadable_records option
  ; boundary_error : string option
  }

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
         "model input carried range seed read refused the turn-boundary store \
          runtime=%s detail=%s"
         runtime_id
         detail)
    read.boundary_error
;;

(* A JSON row that does not decode as a turn record gives no seed, and it is
   counted: "no record" and "records that could not be decoded" are different
   answers to why a turn started without a front. A line that is not JSON at
   all never reaches here; [Dated_jsonl.read_recent] skips it uncounted. *)
let seed_read_of_rows ~trace_id rows =
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
  let of_trace (record : Turn_record.t) = String.equal record.Turn_record.trace_id trace_id in
  let newest_response_turn =
    List.fold_left
      (fun newest (record : Turn_record.t) ->
         match record.Turn_record.response_observed_model_input with
         | Some _ when of_trace record ->
           Some (Option.fold ~none:record.absolute_turn ~some:(Int.max record.absolute_turn) newest)
         | Some _ | None -> newest)
      None
      records
  in
  let refused_start =
    List.fold_left
      (fun newest (record : Turn_record.t) ->
         match refused_start_of_record record, newest_response_turn with
         | Some _, Some response_turn when response_turn >= record.absolute_turn -> newest
         | Some refused, (Some _ | None) when of_trace record ->
           (match newest with
            | Some (kept : refused_start) when kept.turn > refused.turn -> newest
            | Some _ | None -> Some refused)
         | Some _, (Some _ | None) | None, (Some _ | None) -> newest)
      None
      records
  in
  { seed = of_records ~trace_id records
  ; refused_start
  ; unreadable
  ; boundary_error = None
  }
;;

let read_generation_floor ~keepers_dir ~keeper_name ~trace_id =
  Result.bind
    (Keeper_turn_boundaries.read ~keepers_dir ~keeper_id:keeper_name)
    (fun lines ->
       let rec loop latest_turn floor = function
         | [] -> Ok floor
         | (line, Error error) :: _ ->
           Error
             (Printf.sprintf
                "turn boundary line %d: %s"
                line
                (Keeper_turn_boundaries.read_error_to_string error))
         | (_, Ok record) :: rest
           when Keeper_turn_boundaries.restarts_history ~trace_id record ->
           (match record.Keeper_turn_boundaries.event with
            | Keeper_turn_boundaries.Turn_ended { turn_ref; _ } ->
              (* The turn began from an empty history, so its end line states
                 the atoms are numbered from zero again: the generation
                 boundary, whether or not a turn-start marker was ever
                 written. The boundary covers the turns that ended before the
                 restarting turn, not the turn itself. *)
              let turn = Ids.Turn_ref.absolute_turn turn_ref in
              loop
                (Some (Option.fold ~none:turn ~some:(Int.max turn) latest_turn))
                latest_turn
                rest
            | Keeper_turn_boundaries.History_restarted _ ->
              loop latest_turn latest_turn rest)
         | (_, Ok record) :: rest ->
           (match record.Keeper_turn_boundaries.event with
            | Keeper_turn_boundaries.Turn_ended { turn_ref; _ }
              when String.equal (Ids.Turn_ref.trace_id turn_ref) trace_id ->
              (* A restart is fenced by the last turn that ended before it,
                 and that turn is the running latest. A turn that merely
                 continues the history leaves [floor] alone, but it still
                 moves the latest, so a restart marker written without a
                 fresh-history end line can name its own boundary. *)
              let turn = Ids.Turn_ref.absolute_turn turn_ref in
              loop
                (Some (Option.fold ~none:turn ~some:(Int.max turn) latest_turn))
                floor
                rest
            | Keeper_turn_boundaries.Turn_ended _
            | Keeper_turn_boundaries.History_restarted _ -> loop latest_turn floor rest)
       in
       loop None None lines)
;;

(* The floor is folded over the whole boundary store, which only grows (a
   turn's end appends) or is replaced. A floor that was read is kept per store
   and trace with the identity the file had before the read, so a store that
   has not changed since is not read again: an idle Keeper's next read reuses
   it, and an append reads it once. A failed read is not kept. *)
type floor_kept =
  { identity : int * int * int * float
  ; floor : int option
  }

let floor_kept : (string * string, floor_kept) Hashtbl.t = Hashtbl.create 16
let floor_kept_mu = Stdlib.Mutex.create ()

let file_identity path =
  match Unix.stat path with
  | stats -> Some (stats.Unix.st_dev, stats.Unix.st_ino, stats.Unix.st_size, stats.Unix.st_mtime)
  | exception Unix.Unix_error _ -> None
;;

let current_generation_floor ~config ~keeper_name ~trace_id =
  let keepers_dir = Workspace.keepers_runtime_dir config in
  let path = Keeper_turn_boundaries.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name in
  let key = path, trace_id in
  let identity = file_identity path in
  let kept = Stdlib.Mutex.protect floor_kept_mu (fun () -> Hashtbl.find_opt floor_kept key) in
  match identity, kept with
  | Some identity, Some kept when kept.identity = identity -> Ok kept.floor
  | (Some _ | None), (Some _ | None) ->
    let read = read_generation_floor ~keepers_dir ~keeper_name ~trace_id in
    (match identity, read with
     | Some identity, Ok floor ->
       Stdlib.Mutex.protect floor_kept_mu (fun () ->
         Hashtbl.replace floor_kept key { identity; floor })
     | None, (Ok _ | Error _) | Some _, Error _ -> ());
    read
;;

let read_seed ~config ~keeper_name ~trace_id =
  let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
  match current_generation_floor ~config ~keeper_name ~trace_id with
  | Error detail ->
    { no_seed_read with boundary_error = Some detail }
  | Ok generation_floor ->
    let unreadable = ref None in
    (* The newest observation when it is a refusal: a refused range met
       before any response-observed record, seed or not. A response that is
       newer answers the history after the refusal, so the refusal behind it
       is not read. *)
    let refused_start = ref None in
    let response_met = ref false in
    let exception Trace_boundary in
    (* Count observations, not intervening rows. A direct retry may reuse its
       turn number, so the last stored response is the latest observation.
       A different trace is the durable generation boundary; a history
       restart is the same-trace boundary after an operator clear. *)
    let seeds =
      try
        Dated_jsonl.collect_matching store 1 ~f:(fun json ->
          match Turn_record.of_json json with
          | Ok record when not (String.equal record.Turn_record.trace_id trace_id) ->
            raise_notrace Trace_boundary
          | Ok record
            when (match generation_floor with
                  | Some floor -> record.Turn_record.absolute_turn <= floor
                  | None -> false) ->
            raise_notrace Trace_boundary
          | Ok record ->
            (match record.Turn_record.response_observed_model_input with
             | Some _ -> response_met := true
             | None ->
               (match !refused_start, refused_start_of_record record with
                | None, (Some _ as refused) when not !response_met ->
                  refused_start := refused
                | (Some _ | None), (Some _ | None) -> ()));
            of_records ~trace_id [ record ]
          | Error first_reason ->
            let count =
              match !unreadable with
              | None -> 1
              | Some (seen : unreadable_records) -> seen.count + 1
            in
            unreadable := Some { count; first_reason };
            None)
      with Trace_boundary -> []
    in
    { seed = List.nth_opt seeds 0
    ; refused_start = !refused_start
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
  | Carried _ | Librarian_snapshot _ | Librarian_progress _ | Past_librarian_point _ | Turn_start _ -> ()
;;

let source_to_string = function
  | Ledger -> "ledger"
  | Turn_record { turn } -> Printf.sprintf "turn_record#%d" turn
  | Turn_start_after_seed_refusal -> "turn_start_after_seed_refusal"
  | Turn_start_after_librarian_refusal -> "turn_start_after_librarian_refusal"
  | This_turn_start_after_seed_refusal -> "this_turn_start_after_seed_refusal"
  | This_turn_start_after_librarian_refusal -> "this_turn_start_after_librarian_refusal"
;;

let seed_to_json (seed : seed) =
  `Assoc
    [ "first_atom", `Int seed.first_atom
    ; "front", Model_input_front.to_json seed.front
    ; "source", `String (source_to_string seed.source)
    ]
;;

let origin_to_string = function
  | Librarian_snapshot _ -> "librarian_snapshot"
  | Librarian_progress _ -> "librarian_progress"
  | Past_librarian_point { source; _ } -> "past_librarian_point:" ^ source_to_string source
  | Carried source -> source_to_string source
  | Turn_start _ -> "turn_start"
  | Turn_start_unknown _ -> "turn_start_unknown"
;;

let rec origin_to_json = function
  | Librarian_snapshot { end_atom; boundary_line } ->
    `Assoc [ "kind", `String "librarian_snapshot"; "end_atom", `Int end_atom;
             "boundary_line", `Int boundary_line ]
  | Carried Ledger -> `Assoc [ "kind", `String "ledger" ]
  | Carried (Turn_record { turn }) ->
    `Assoc [ "kind", `String "turn_record"; "turn", `Int turn ]
  | Carried Turn_start_after_seed_refusal ->
    `Assoc [ "kind", `String "turn_start_after_seed_refusal" ]
  | Carried Turn_start_after_librarian_refusal ->
    `Assoc [ "kind", `String "turn_start_after_librarian_refusal" ]
  | Carried This_turn_start_after_seed_refusal ->
    `Assoc [ "kind", `String "this_turn_start_after_seed_refusal" ]
  | Carried This_turn_start_after_librarian_refusal ->
    `Assoc [ "kind", `String "this_turn_start_after_librarian_refusal" ]
  | Past_librarian_point { librarian_end_atom; source } ->
    `Assoc
      [ "kind", `String "past_librarian_point"
      ; "librarian_end_atom", `Int librarian_end_atom
      ; "front", origin_to_json (Carried source)
      ]
  | Librarian_progress { end_atom } ->
    `Assoc [ "kind", `String "librarian_progress"; "end_atom", `Int end_atom ]
  | Turn_start { end_atom } ->
    `Assoc [ "kind", `String "turn_start"; "end_atom", `Int end_atom ]
  | Turn_start_unknown { reason } ->
    `Assoc [ "kind", `String "turn_start_unknown"; "reason", `String reason ]
;;

type librarian_gap =
  { gap_start_atom : int
  ; gap_end_atom : int
  }

let librarian_gap ~snapshot_cut ~read_position ~accepted_start =
  let covered =
    match snapshot_cut, read_position with
    | Some cut, Some read -> Some (max cut read)
    | Some cut, None -> Some cut
    | None, Some read -> Some read
    | None, None -> None
  in
  match covered with
  | Some covered when accepted_start > covered ->
    Some { gap_start_atom = covered; gap_end_atom = accepted_start }
  | Some _ | None -> None
;;
