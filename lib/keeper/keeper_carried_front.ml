(** Keeper_carried_front — see the interface for the contract. *)

type source =
  | Ledger
  | Turn_record of { turn : int }
  | Unfinished_turn of { turn : int }
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

let record_runtime (record : Turn_record.t) =
  match record.Turn_record.request_wire_observation with
  | Some observation -> observation.Turn_record.runtime_profile
  | None -> record.Turn_record.runtime_profile
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

(* An official client's record is read too. Its window is measured where the
   Agent Core path measures its own: the three official-client runtimes count
   atoms of the message list masc handed the agent and name the front with
   that list's opening digest (keeper_claude_code_runtime.ml:85-99,
   keeper_codex_runtime.ml:116-127, keeper_antigravity_runtime.ml:158-181),
   and that list is the keeper's checkpoint history — the projection runs over
   [agent.state.messages] (pipeline_stage_prepare.ml:148-154). What it cannot
   answer is a runtime the catalog no longer has, because nothing then says
   which list was counted. Skipping the official ones cost a keeper that had
   run 20 turns on claude_code the whole history on its first Agent Core turn
   after them (2026-09-18: code-reviewer turn 4059, 13 MB per candidate). *)
let of_records ~composer ~trace_id (records : Turn_record.t list) =
  List.fold_left
    (fun newest (record : Turn_record.t) ->
       match
         ( record.Turn_record.model_input_window
         , record.Turn_record.finish_reason
         , composer (record_runtime record) )
       with
       | Some window, finish_reason, (Composes_from_the_history | Hands_over_its_own_list)
         when String.equal record.Turn_record.trace_id trace_id ->
         let turn = record.Turn_record.absolute_turn in
         (match newest with
          | Some (newest_turn, _) when newest_turn >= turn -> newest
          | Some _ | None ->
            let source =
              match finish_reason with
              | Some _ -> Turn_record { turn }
              | None -> Unfinished_turn { turn }
            in
            Some
              ( turn
              , { first_atom =
                    window.Turn_record.total_atoms - window.Turn_record.transmitted_atoms
                ; front_digest = window.Turn_record.front_atom_digest
                ; source
                } ))
       | Some _, _, Not_materialized
       | Some _, _, (Composes_from_the_history | Hands_over_its_own_list)
       | None, _, _ -> newest)
    None
    records
  |> Option.map snd
;;

let records_read = 200

type unreadable_records =
  { count : int
  ; first_reason : string
  }

type seed_read =
  { seed : seed option
  ; unreadable : unreadable_records option
  }

let no_seed_read = { seed = None; unreadable = None }

(* A JSON row that does not decode as a turn record gives no seed, and it is
   counted: "no record" and "records that could not be decoded" are different
   answers to why a turn started without a front. A line that is not JSON at
   all never reaches here; [Dated_jsonl.read_recent] skips it uncounted. *)
let seed_read_of_rows ~composer ~trace_id rows =
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
  { seed = of_records ~composer ~trace_id (List.rev records_rev); unreadable }
;;

let read_seed ~config ~keeper_name ~trace_id =
  let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
  seed_read_of_rows
    ~composer:(fun runtime_id -> composer_of_runtime (Runtime.get_runtime_by_id runtime_id))
    ~trace_id
    (Dated_jsonl.read_recent store records_read)
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
  | Unfinished_turn { turn } -> Printf.sprintf "unfinished_turn#%d" turn
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
  | Carried (Unfinished_turn { turn }) ->
    `Assoc [ "kind", `String "unfinished_turn"; "turn", `Int turn ]
  | Carried (Halved_after_refusal { retry }) ->
    `Assoc [ "kind", `String "halved_after_refusal"; "retry", `Int retry ]
  | Carried (Evicted_after_refusal { retry }) ->
    `Assoc [ "kind", `String "evicted_after_refusal"; "retry", `Int retry ]
  | Whole_history -> `Assoc [ "kind", `String "whole_history" ]
;;
