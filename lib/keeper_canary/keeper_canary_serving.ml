(* See keeper_canary_serving.mli. *)

type check = {
  expected_runtime : string;
  served : (int * string) list;
  mismatched : (int * string) list;
  unattributed : int list;
}

let check ~expected_runtime ~window_start ~turn_ids
    ~(attempts : Keeper_canary_failover.attempt list) : check
  =
  let served =
    List.filter_map
      (fun (a : Keeper_canary_failover.attempt) ->
        match a.event with
        | Keeper_canary_failover.Routed | Keeper_canary_failover.Failed -> None
        | Keeper_canary_failover.Completed ->
          (match a.keeper_turn_id with
           | Some turn when String.compare a.ts window_start >= 0 ->
             Some (turn, a.runtime_id)
           | Some _ | None -> None))
      attempts
  in
  (* Later Completed row wins for a turn: attempts arrive in row order and
     the last completion is the one whose reply the transcript kept. *)
  let completed_for turn =
    List.fold_left
      (fun acc (t, rid) -> if t = turn then Some rid else acc)
      None
      served
  in
  let mismatched, unattributed =
    List.fold_left
      (fun (mis, unat) turn ->
        match completed_for turn with
        | None -> (mis, turn :: unat)
        | Some rid ->
          if String.equal rid expected_runtime
          then (mis, unat)
          else ((turn, rid) :: mis, unat))
      ([], [])
      turn_ids
  in
  { expected_runtime
  ; served
  ; mismatched = List.rev mismatched
  ; unattributed = List.rev unattributed
  }

let all_as_expected c = c.mismatched = [] && c.unattributed = []

let to_yojson c =
  let pair_to_json (turn, rid) =
    `Assoc [ ("turn", `Int turn); ("runtime_id", `String rid) ]
  in
  `Assoc
    [ ("expected_runtime", `String c.expected_runtime)
    ; ("served", `List (List.map pair_to_json c.served))
    ; ("mismatched", `List (List.map pair_to_json c.mismatched))
    ; ("unattributed", `List (List.map (fun t -> `Int t) c.unattributed))
    ]
