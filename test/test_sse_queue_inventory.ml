open Alcotest

module Q = Sse_queue_inventory

let register state session_id client_id kind =
  Q.register state ~session_id ~client_id ~kind ~last_event_id:0 ~last_seen_at:0.0

let observe state session_id client_id depth event_id seen =
  Q.observe state ~session_id ~client_id ~queue_depth:depth
    ~last_event_id:event_id ~last_seen_at:seen

let names entries = List.map (fun (entry : Q.entry) -> entry.session_id) entries
let describe entries = List.map (fun (entry : Q.entry) ->
  Printf.sprintf "%s:%d:%d:%d:%.0f" entry.session_id entry.client_id
    entry.queue_depth entry.last_event_id entry.last_seen_at) entries

let test_ranking_and_counts () =
  let state = Q.empty in
  let state = register state "a" 1 Q.Observer in
  let state = register state "b" 2 Q.Agent_stream in
  let state = register state "c" 3 Q.Presence in
  let state = observe state "a" 1 2 10 10.0 in
  let state = observe state "b" 2 5 20 20.0 in
  let state = observe state "c" 3 5 30 5.0 in
  check int "three sessions" 3 (Q.count state);
  check int "observer count" 1 (Q.count_kind state Q.Observer);
  check int "agent count" 1 (Q.count_kind state Q.Agent_stream);
  check int "presence count" 1 (Q.count_kind state Q.Presence);
  check int "queue sum" 12 (Q.total_queue_depth state);
  check int "maximum" 5 (Q.max_queue_depth state);
  check (list string) "depth then age" ["c"; "b"; "a"] (names (Q.hot ~limit:3 state));
  check (list string) "fixed-size top" ["c"; "b"] (names (Q.hot ~limit:2 state));
  let state = observe state "c" 3 0 30 5.0 in
  check int "drain subtracts depth" 7 (Q.total_queue_depth state);
  check (list string) "drained session leaves ranking" ["b"; "a"] (names (Q.hot ~limit:3 state))

let test_retired_owner_is_inert () =
  let state = register Q.empty "shared" 1 Q.Observer in
  let state = observe state "shared" 1 4 1 10.0 in
  let state = register state "shared" 2 Q.Presence in
  let state = observe state "shared" 1 99 100 20.0 in
  let state = Q.remove state ~session_id:"shared" ~client_id:1 in
  check int "successor remains" 1 (Q.count state);
  check int "prior observer is gone" 0 (Q.count_kind state Q.Observer);
  check int "new presence is retained" 1 (Q.count_kind state Q.Presence);
  check int "old queued events are withdrawn" 0 (Q.total_queue_depth state);
  let state = observe state "shared" 2 1 101 21.0 in
  check (list string) "new owner remains observable" ["shared"] (names (Q.hot ~limit:3 state));
  let state = Q.remove state ~session_id:"shared" ~client_id:2 in
  check int "current owner can be removed" 0 (Q.count state);
  check int "removal clears queued count" 0 (Q.total_queue_depth state)

let test_against_reference () =
  let rng = Random.State.make [| 47561 |] in
  let reference : Q.entry option array = Array.make 12 None in
  let state = ref Q.empty in
  let next_id = ref 0 in
  let kind () = match Random.State.int rng 3 with
    | 0 -> Q.Observer | 1 -> Q.Agent_stream | _ -> Q.Presence in
  for step = 1 to 3000 do
    let index = Random.State.int rng (Array.length reference) in
    let session_id = Printf.sprintf "session-%02d" index in
    let pick_id () = match reference.(index) with
      | Some entry when Random.State.bool rng -> entry.client_id
      | None | Some _ -> -1 in
    (match Random.State.int rng 3 with
     | 0 ->
         incr next_id;
         let client_id = !next_id and kind = kind () in
         let event_id = Random.State.int rng 100 and seen = float_of_int (Random.State.int rng 10) in
         reference.(index) <- Some { session_id; client_id; kind; queue_depth = 0;
                                    last_event_id = event_id; last_seen_at = seen };
         state := Q.register !state ~session_id ~client_id ~kind ~last_event_id:event_id ~last_seen_at:seen
     | 1 ->
         let client_id = pick_id () in
         let queue_depth = Random.State.int rng 8 in
         let last_event_id = Random.State.int rng 100 and last_seen_at = float_of_int (Random.State.int rng 10) in
         state := Q.observe !state ~session_id ~client_id ~queue_depth ~last_event_id ~last_seen_at;
         (match reference.(index) with
          | Some previous when previous.client_id = client_id ->
              reference.(index) <- Some { previous with queue_depth; last_event_id; last_seen_at }
          | None | Some _ -> ())
     | _ ->
         let client_id = pick_id () in
         state := Q.remove !state ~session_id ~client_id;
         (match reference.(index) with
          | Some previous when previous.client_id = client_id -> reference.(index) <- None
          | None | Some _ -> ()));
    let entries = Array.to_list reference |> List.filter_map Fun.id in
    let count_kind kind = List.length (List.filter (fun (entry : Q.entry) -> entry.kind = kind) entries) in
    let sum = List.fold_left (fun n (entry : Q.entry) -> n + entry.queue_depth) 0 entries in
    let expected = entries |> List.filter (fun (entry : Q.entry) -> entry.queue_depth > 0)
      |> List.sort (fun (left : Q.entry) (right : Q.entry) ->
          let c = Int.compare right.queue_depth left.queue_depth in
          if c <> 0 then c else
          let c = Float.compare left.last_seen_at right.last_seen_at in
          if c <> 0 then c else String.compare left.session_id right.session_id) in
    let max_depth = match expected with [] -> 0 | first :: _ -> first.queue_depth in
    let label what = Printf.sprintf "%s at step %d" what step in
    check int (label "count") (List.length entries) (Q.count !state);
    check int (label "observers") (count_kind Q.Observer) (Q.count_kind !state Q.Observer);
    check int (label "agents") (count_kind Q.Agent_stream) (Q.count_kind !state Q.Agent_stream);
    check int (label "presence") (count_kind Q.Presence) (Q.count_kind !state Q.Presence);
    check int (label "queue sum") sum (Q.total_queue_depth !state);
    check int (label "maximum") max_depth (Q.max_queue_depth !state);
    check (list string) (label "hot queues") (describe (List.take 3 expected))
      (describe (Q.hot ~limit:3 !state))
  done

let () =
  run "sse queue inventory"
    [ "updates",
      [ test_case "ranking and counts" `Quick test_ranking_and_counts
      ; test_case "retired owner cannot change successor" `Quick test_retired_owner_is_inert
      ; test_case "incremental view matches a reference scan" `Quick test_against_reference
      ] ]
