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
  let windowed =
    List.filter_map
      (fun (a : Keeper_canary_failover.attempt) ->
        match a.event with
        | Keeper_canary_failover.Routed | Keeper_canary_failover.Failed -> None
        | Keeper_canary_failover.Completed ->
          (match a.keeper_turn_id with
           | Some turn when String.compare a.ts window_start >= 0 ->
             Some (turn, a.ts, a.runtime_id)
           | Some _ | None -> None))
      attempts
  in
  let served = List.map (fun (turn, _, rid) -> (turn, rid)) windowed in
  (* Chronologically last Completed row wins for a turn — its reply is the
     one the transcript kept. Chronological order = list order is not
     guaranteed by the wire (same lesson as classify in
     keeper_canary_failover.ml), so compare timestamps directly; a ts tie
     falls to the later row. *)
  let completed_for turn =
    List.fold_left
      (fun acc (t, ts, rid) ->
        if t <> turn
        then acc
        else (
          match acc with
          | Some (best_ts, _) when String.compare best_ts ts > 0 -> acc
          | Some _ | None -> Some (ts, rid)))
      None
      windowed
    |> Option.map snd
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
