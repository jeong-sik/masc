(** Keeper_carried_front — see the interface for the contract. *)

type source =
  | Ledger
  | Turn_record of { turn : int }
  | Halved_after_refusal of { retry : int }
  | Evicted_after_refusal of { retry : int }

type seed =
  { first_atom : int
  ; front_digest : string
  ; source : source
  }

type origin =
  | Carried of source
  | Whole_history

let of_ledger (ledger : Keeper_model_input_ledger.t) =
  match ledger.last.ends with
  | Keeper_model_input_ledger.No_atom_carried -> None
  | Keeper_model_input_ledger.Carried_atoms { front_digest; end_digest = _ } ->
    Some { first_atom = ledger.last.first_atom; front_digest; source = Ledger }
;;

type composer =
  | Composes_from_the_history
  | Hands_over_its_own_list
  | Not_materialized

let composer_of_execution = function
  | Runtime_execution.Agent_core _ -> Composes_from_the_history
  | Runtime_execution.Codex_app_server _
  | Runtime_execution.Claude_code _
  | Runtime_execution.Antigravity_cli _ -> Hands_over_its_own_list
;;

let composer_of_runtime = function
  | Some (runtime : Runtime.t) -> composer_of_execution runtime.Runtime.execution
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
(* A turn that carried its whole history names no front. Its opening atom is
   the oldest one because nothing was skipped, not because a later turn may
   start there, so reading it as a seed sends the next start back to the
   beginning. [Runtime_execution.Codex_app_server] hands its list over whole
   on every turn, so without this one Codex turn in a lane undoes the carried
   front for every official-client start after it (#37350). A history short
   enough to go whole loses nothing: seeding its oldest atom and seeding
   nothing both carry everything. *)
let carried_front_of_window (window : Turn_record.model_input_window) =
  if window.Turn_record.transmitted_atoms >= window.Turn_record.total_atoms
  then None
  else
    Some
      ( window.Turn_record.total_atoms - window.Turn_record.transmitted_atoms
      , window.Turn_record.front_atom_digest )
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
             | Some (first_atom, front_digest) ->
               Some (turn, { first_atom; front_digest; source = Turn_record { turn } })))
       | Some _ | None -> newest)
    None
    records
  |> Option.map snd
;;

type unreadable_records =
  { count : int
  ; first_reason : string
  }

type seed_read =
  { seed : seed option
  ; unreadable : unreadable_records option
  ; boundary_error : string option
  }

let no_seed_read = { seed = None; unreadable = None; boundary_error = None }

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
  { seed = of_records ~trace_id (List.rev records_rev)
  ; unreadable
  ; boundary_error = None
  }
;;

let current_generation_floor ~config ~keeper_name ~trace_id =
  Result.bind
    (Keeper_turn_boundaries.read
       ~keepers_dir:(Workspace.keepers_runtime_dir config)
       ~keeper_id:keeper_name)
    (fun lines ->
       let rec loop latest_turn floor = function
         | [] -> Ok floor
         | (line, Error error) :: _ ->
           Error
             (Printf.sprintf
                "turn boundary line %d: %s"
                line
                (Keeper_turn_boundaries.read_error_to_string error))
         | ( _,
             Ok
               { Keeper_turn_boundaries.event =
                   Keeper_turn_boundaries.Turn_ended { turn_ref; _ }
               ; _
               } )
           :: rest
           when String.equal (Ids.Turn_ref.trace_id turn_ref) trace_id ->
           let turn = Ids.Turn_ref.absolute_turn turn_ref in
           loop
             (Some (Option.fold ~none:turn ~some:(Int.max turn) latest_turn))
             floor
             rest
         | ( _,
             Ok
               { Keeper_turn_boundaries.event =
                   Keeper_turn_boundaries.History_restarted { trace_id = restarted }
               ; _
               } )
           :: rest
           when String.equal restarted trace_id ->
           loop latest_turn latest_turn rest
         | (_, Ok _) :: rest -> loop latest_turn floor rest
       in
       loop None None lines)
;;

let read_seed ~config ~keeper_name ~trace_id =
  let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
  match current_generation_floor ~config ~keeper_name ~trace_id with
  | Error detail ->
    { seed = None
    ; unreadable = None
    ; boundary_error = Some detail
    }
  | Ok generation_floor ->
    let unreadable = ref None in
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
          | Ok record -> of_records ~trace_id [ record ]
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
    ; unreadable = !unreadable
    ; boundary_error = None
    }
;;

type dropped_front =
  | Front_atom_missing
  | Front_message_differs

let for_history ~digest_at (seed : seed) =
  match digest_at seed.first_atom with
  | None -> Error Front_atom_missing
  | Some digest when String.equal digest seed.front_digest -> Ok seed
  | Some _ -> Error Front_message_differs
;;

let dropped_front_to_string = function
  | Front_atom_missing -> "front_atom_missing"
  | Front_message_differs -> "front_message_differs"
;;

let clamp ~atom_count first_atom =
  if atom_count <= 0 then 0 else max 0 (min first_atom (atom_count - 1))
;;

let halve ~first_atom ~atom_count =
  let first_atom = clamp ~atom_count first_atom in
  let carried = atom_count - first_atom in
  if carried <= 1 then None else Some (first_atom + (carried / 2))
;;

let source_to_string = function
  | Ledger -> "ledger"
  | Turn_record { turn } -> Printf.sprintf "turn_record#%d" turn
  | Halved_after_refusal { retry } -> Printf.sprintf "halved_after_refusal#%d" retry
  | Evicted_after_refusal { retry } -> Printf.sprintf "evicted_after_refusal#%d" retry
;;

let seed_to_json (seed : seed) =
  `Assoc
    [ "first_atom", `Int seed.first_atom
    ; "front_digest", `String seed.front_digest
    ; "source", `String (source_to_string seed.source)
    ]
;;

let origin_to_string = function
  | Carried source -> source_to_string source
  | Whole_history -> "whole_history"
;;

let origin_to_json = function
  | Carried Ledger -> `Assoc [ "kind", `String "ledger" ]
  | Carried (Turn_record { turn }) ->
    `Assoc [ "kind", `String "turn_record"; "turn", `Int turn ]
  | Carried (Halved_after_refusal { retry }) ->
    `Assoc [ "kind", `String "halved_after_refusal"; "retry", `Int retry ]
  | Carried (Evicted_after_refusal { retry }) ->
    `Assoc [ "kind", `String "evicted_after_refusal"; "retry", `Int retry ]
  | Whole_history -> `Assoc [ "kind", `String "whole_history" ]
;;
