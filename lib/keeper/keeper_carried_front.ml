(** Keeper_carried_front — see the interface for the contract. *)

type source =
  | Ledger
  | Turn_record of { turn : int }
  | Halved_after_refusal of { retry : int }

type seed =
  { first_atom : int
  ; atom_count : int
  ; source : source
  }

type origin =
  | Carried of source
  | Whole_history

let of_ledger (ledger : Keeper_model_input_ledger.t) =
  { first_atom = ledger.last.first_atom; atom_count = ledger.last.atom_count; source = Ledger }
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

let of_records ~composer ~trace_id (records : Turn_record.t list) =
  List.fold_left
    (fun newest (record : Turn_record.t) ->
       match
         ( record.Turn_record.model_input_window
         , record.Turn_record.finish_reason
         , composer (record_runtime record) )
       with
       | Some window, Some _, Composes_from_the_history
         when String.equal record.Turn_record.trace_id trace_id ->
         let turn = record.Turn_record.absolute_turn in
         (match newest with
          | Some (newest_turn, _) when newest_turn >= turn -> newest
          | Some _ | None ->
            Some
              ( turn
              , { first_atom =
                    window.Turn_record.total_atoms - window.Turn_record.transmitted_atoms
                ; atom_count = window.Turn_record.total_atoms
                ; source = Turn_record { turn }
                } ))
       | ( Some _
         , Some _
         , (Composes_from_the_history | Hands_over_its_own_list | Not_materialized) )
       | Some _, None, _
       | None, _, _ -> newest)
    None
    records
  |> Option.map snd
;;

let records_read = 200

let read_seed ~config ~keeper_name ~trace_id =
  let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
  (* A record that does not parse is treated as absent, the same boundary the
     forecast reader draws; the erasing conversion is not used. *)
  Dated_jsonl.read_recent store records_read
  |> List.filter_map (fun json ->
         match Turn_record.of_json json with
         | Error _ -> None
         | Ok record -> Some record)
  |> of_records
       ~composer:(fun runtime_id -> composer_of_runtime (Runtime.get_runtime_by_id runtime_id))
       ~trace_id
;;

let for_history ~atom_count seed = if seed.atom_count > atom_count then None else Some seed

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
;;

let seed_to_json seed =
  `Assoc
    [ "first_atom", `Int seed.first_atom
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
  | Whole_history -> `Assoc [ "kind", `String "whole_history" ]
;;
