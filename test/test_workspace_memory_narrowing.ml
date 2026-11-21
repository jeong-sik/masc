(* The curator's classification decisions, against the rules of RFC
   curator-narrows-a-refused-batch-and-sets-a-refused-fact-aside and the
   bugs specs/bug-models/CuratorNarrow.tla names. A run drives one pass to
   its end with a reply for each batch sent; the frame and the kept size cut
   a request as Workspace_memory_request.prepare would. *)

module N = Masc.Workspace_memory_narrowing
module Ledger = Masc.Workspace_memory_ledger
module Request = Masc.Workspace_memory_request

let fact n : Ledger.fact_ref =
  Ledger.Ordinary { keeper_id = "keeper"; claim_sha256 = Printf.sprintf "f%d" n }
;;

let facts = List.map fact

let name : Ledger.fact_ref -> string = function
  | Ledger.Ordinary { claim_sha256; keeper_id = _ } -> claim_sha256
  | Ledger.Source_bound { claim_sha256; keeper_id = _; path = _ } -> claim_sha256
;;

let names list = List.map name list
let label numbers = List.map (Printf.sprintf "f%d") numbers
let first_lane = { N.lane = "lane-1"; requests = 0 }

let size =
  Alcotest.testable
    (fun ppf -> function
       | Request.Fill_frame -> Format.pp_print_string ppf "fill_frame"
       | Request.Up_to count -> Format.fprintf ppf "up_to %d" count)
    ( = )
;;

type reply =
  | Answered
  | Heard of (N.slot * N.word) list

let start ?(wake = N.Commit) ?(slots = [ "a" ]) ?(generation = first_lane) memory pending =
  N.start memory ~generation ~slots ~wake ~pending:(facts pending)
;;

(* Drives a pass to its end. [frame] is how many facts a request holds at
   most. Returns the memory and every batch sent with the slots walked. *)
let run ?(frame = max_int) memory pass ~reply =
  let rec loop memory pass sent_so_far =
    match N.next memory pass with
    | None -> memory, List.rev sent_so_far
    | Some request ->
      let room =
        match request.N.size with
        | Request.Fill_frame -> frame
        | Request.Up_to count -> min count frame
      in
      let sent = List.take room request.N.facts in
      let result =
        match reply sent request.N.slots with
        | Answered -> N.answered memory pass ~sent
        | Heard heard -> N.unanswered memory pass ~sent ~heard
      in
      (match result with
       | Ok (memory, pass) -> loop memory pass ((names sent, request.N.slots) :: sent_so_far)
       | Error error -> Alcotest.fail (N.error_to_string error))
  in
  loop memory pass []
;;

let batches sent = List.map fst sent
let check_batches message expected sent =
  Alcotest.(check (list (list string))) message (List.map label expected) (batches sent)
;;

let fresh ?(slots = [ "a" ]) () = N.empty first_lane ~slots

let all_refused () =
  let memory, pass = start (fresh ()) [ 1; 2; 3; 4 ] in
  run memory pass ~reply:(fun _ _ -> Heard [ "a", N.Unsized ])
;;

(* §4.2: a lane that refuses every request sets each fact aside after
   2N - 1 refused batches, and asks none of them again (bugs resend,
   rebuild_from_all). *)
let test_every_request_refused () =
  let memory, sent = all_refused () in
  check_batches
    "each refused batch splits in two and none is sent twice"
    [ [ 1; 2; 3; 4 ]; [ 1; 2 ]; [ 1 ]; [ 2 ]; [ 3; 4 ]; [ 3 ]; [ 4 ] ]
    sent;
  Alcotest.(check (list string))
    "every fact is set aside"
    (label [ 1; 2; 3; 4 ])
    (List.sort String.compare (names (N.set_aside memory)));
  Alcotest.(check bool) "nothing waits for the tick" false (N.waiting memory);
  let memory, pass = start ~wake:N.Tick memory [ 1; 2; 3; 4 ] in
  Alcotest.(check bool) "a tick pass asks nothing" true (Option.is_none (N.next memory pass))
;;

let poison sent _ = if List.mem (fact 2) sent then Heard [ "a", N.Unsized ] else Answered

(* §4.2 and §5: one refused fact is set aside and the others are classified
   in the same pass (bug fail_fast). *)
let test_poison_fact () =
  let memory, pass = start (fresh ()) [ 1; 2; 3 ] in
  let memory, sent = run memory pass ~reply:poison in
  check_batches "the pass goes on past each refusal" [ [ 1; 2; 3 ]; [ 1 ]; [ 2; 3 ]; [ 2 ]; [ 3 ] ] sent;
  Alcotest.(check (list string)) "only the refused fact is set aside" (label [ 2 ]) (names (N.set_aside memory));
  Alcotest.(check bool) "nothing waits for the tick" false (N.waiting memory)
;;

(* §4.2: an unusable answer and a missed deadline are not refusals. The fact
   waits, and the tick asks it again only at the slots that did not refuse
   it (bug aside_on_unusable). *)
let test_unspoken_slot_keeps_the_fact () =
  let slots = [ "a"; "b" ] in
  let memory, pass = start ~slots (fresh ~slots ()) [ 1 ] in
  let memory, _ =
    run memory pass ~reply:(fun _ _ -> Heard [ "a", N.Unusable; "b", N.Unsized ])
  in
  Alcotest.(check (list string)) "not set aside" [] (names (N.set_aside memory));
  Alcotest.(check bool) "waits for the tick" true (N.waiting memory);
  let memory, pass = start ~wake:N.Tick ~slots memory [ 1 ] in
  let memory, sent = run memory pass ~reply:(fun _ _ -> Heard [ "a", N.Sized ]) in
  Alcotest.(check (list (list string))) "the tick walks the slot that did not refuse" [ [ "a" ] ]
    (List.map snd sent);
  Alcotest.(check (list string)) "set aside once every slot refused" (label [ 1 ])
    (names (N.set_aside memory));
  let memory, pass = start ~slots (fresh ~slots ()) [ 2 ] in
  let memory, _ = run memory pass ~reply:(fun _ _ -> Heard [ "a", N.Overdue ]) in
  Alcotest.(check bool) "a missed deadline waits too" true (N.waiting memory);
  let memory, pass = start ~wake:N.Tick ~slots memory [ 2 ] in
  let _, sent = run memory pass ~reply:(fun _ _ -> Answered) in
  Alcotest.(check (list (list string))) "the tick walks both slots" [ [ "a"; "b" ] ] (List.map snd sent)
;;

let refuse_over_two word sent _ = if List.length sent > 2 then Heard [ "a", word ] else Answered

(* §4.1: the size is kept only after a batch that came down by size
   refusals is answered, and later batches are cut to it (bug
   size_after_unsized). *)
let test_size_from_sized_refusals_only () =
  let memory, pass = start (fresh ()) [ 1; 2; 3; 4 ] in
  let memory, _ = run memory pass ~reply:(refuse_over_two N.Sized) in
  Alcotest.(check size) "kept after size refusals" (Request.Up_to 2) (N.size memory);
  let memory, pass = start memory [ 5; 6; 7 ] in
  let _, sent = run memory pass ~reply:(fun _ _ -> Answered) in
  check_batches "later batches are cut to it" [ [ 5; 6 ]; [ 7 ] ] sent;
  let memory, pass = start (fresh ()) [ 1; 2; 3; 4 ] in
  let memory, _ = run memory pass ~reply:(refuse_over_two N.Unsized) in
  Alcotest.(check size) "not kept after a refusal with no size" Request.Fill_frame (N.size memory);
  let slots = [ "a"; "b" ] in
  let memory, pass = start ~slots (fresh ~slots ()) [ 1; 2; 3; 4 ] in
  let memory, _ =
    run memory pass ~reply:(fun sent _ ->
      if List.length sent > 2 then Heard [ "a", N.Sized; "b", N.Unusable ] else Answered)
  in
  Alcotest.(check size) "not kept when another slot answered unusably" Request.Fill_frame
    (N.size memory)
;;

(* §4.3: a new generation, a request to start over and a new slot list
   each start from an empty memory (bug keep_floor). *)
let test_new_generation_empties_memory () =
  let memory, _ = all_refused () in
  let check_empty message (memory, pass) =
    Alcotest.(check (list string)) (message ^ ": nothing set aside") [] (names (N.set_aside memory));
    Alcotest.(check size) (message ^ ": no kept size") Request.Fill_frame (N.size memory);
    let _, sent = run memory pass ~reply:(fun _ _ -> Answered) in
    check_batches (message ^ ": every fact is asked again") [ [ 1; 2; 3; 4 ] ] sent
  in
  check_empty "lane" (start ~generation:{ N.lane = "lane-2"; requests = 0 } memory [ 1; 2; 3; 4 ]);
  check_empty "request" (start ~generation:{ N.lane = "lane-1"; requests = 1 } memory [ 1; 2; 3; 4 ]);
  check_empty "slots" (start ~slots:[ "a"; "b" ] memory [ 1; 2; 3; 4 ])
;;

(* §4.3: a pass that started before the generation changed writes nothing
   of what it hears and ends (bug late_write). *)
let test_older_pass_writes_nothing () =
  let memory, pass = start (fresh ()) [ 1 ] in
  let restarted = N.restart memory ~requests:1 in
  match N.unanswered restarted pass ~sent:(facts [ 1 ]) ~heard:[ "a", N.Unsized ] with
  | Error error -> Alcotest.fail (N.error_to_string error)
  | Ok (memory, pass) ->
    Alcotest.(check (list string)) "the refusal is not kept" [] (names (N.set_aside memory));
    Alcotest.(check bool) "the pass ends" true (Option.is_none (N.next memory pass))
;;

(* §4.1 and §4.4: a fresh batch that met only quiet slots waits. A pass a
   commit woke does not ask it; the next tick pass asks it with the new
   facts as one batch (bug no_quiet_memory). *)
let test_quiet_batch_waits_for_the_tick () =
  let memory, pass = start (fresh ()) [ 1; 2; 3 ] in
  let memory, _ = run memory pass ~reply:(fun _ _ -> Heard []) in
  Alcotest.(check bool) "waits" true (N.waiting memory);
  let memory, pass = start memory [ 1; 2; 3; 4 ] in
  let memory, sent = run memory pass ~reply:(fun _ _ -> Answered) in
  check_batches "a commit pass asks only the new fact" [ [ 4 ] ] sent;
  let memory, pass = start ~wake:N.Tick memory [ 1; 2; 3; 5 ] in
  let memory, sent = run memory pass ~reply:(fun _ _ -> Answered) in
  check_batches "the tick asks the waiting facts with the new one" [ [ 1; 2; 3; 5 ] ] sent;
  Alcotest.(check bool) "nothing waits" false (N.waiting memory)
;;

(* §4.1: after the older half, the newer half is made again on its own; it
   does not take in the facts after it (bug rebuild_from_all). *)
let test_halves_stay_apart () =
  let memory, pass = start (fresh ()) [ 1; 2; 3 ] in
  let _, sent =
    run ~frame:2 memory pass ~reply:(fun sent _ ->
      if List.length sent > 1 then Heard [ "a", N.Unsized ] else Answered)
  in
  check_batches "each half alone, then the fact the frame left out" [ [ 1; 2 ]; [ 1 ]; [ 2 ]; [ 3 ] ] sent
;;

(* §5: an unusable answer and a missed deadline narrow a batch. *)
let test_unusable_or_overdue_batch_narrows () =
  List.iter
    (fun word ->
       let memory, pass = start (fresh ()) [ 1; 2 ] in
       let _, sent =
         run memory pass ~reply:(fun sent _ -> if List.length sent > 1 then Heard [ "a", word ] else Answered)
       in
       check_batches "narrowed" [ [ 1; 2 ]; [ 1 ]; [ 2 ] ] sent)
    [ N.Unusable; N.Overdue ]
;;

(* §4.1 and §4.4: halves that met only quiet slots are kept as they are.
   A commit pass leaves them; a tick pass asks its new facts first, then each
   half as it is. *)
let test_tick_asks_places_as_they_are () =
  let memory, pass = start (fresh ()) [ 1; 2; 3; 4 ] in
  let memory, _ =
    run memory pass ~reply:(fun sent _ ->
      if List.length sent = 4 then Heard [ "a", N.Unsized ] else Heard [])
  in
  let memory, pass = start memory [ 1; 2; 3; 4 ] in
  Alcotest.(check bool) "a commit pass leaves the places" true (Option.is_none (N.next memory pass));
  let memory, pass = start ~wake:N.Tick memory [ 1; 2; 3; 4; 5 ] in
  let memory, sent = run memory pass ~reply:(fun _ _ -> Answered) in
  check_batches "new facts first, then each place" [ [ 5 ]; [ 1; 2 ]; [ 3; 4 ] ] sent;
  Alcotest.(check bool) "nothing waits" false (N.waiting memory)
;;

(* §4.3: a fact that leaves the pending facts is forgotten, and asked as a
   new fact when it comes back. *)
let test_fact_change_forgets () =
  let memory, pass = start (fresh ()) [ 1; 2; 3 ] in
  let memory, _ = run memory pass ~reply:poison in
  let memory, _ = start memory [] in
  Alcotest.(check (list string)) "forgotten" [] (names (N.set_aside memory));
  let memory, pass = start memory [ 2 ] in
  let _, sent = run memory pass ~reply:(fun _ _ -> Answered) in
  check_batches "asked again" [ [ 2 ] ] sent
;;

let test_sent_must_lead_the_request () =
  let memory, pass = start (fresh ()) [ 1; 2; 3 ] in
  let refused = function
    | Error error -> N.error_to_string error
    | Ok _ -> "accepted"
  in
  Alcotest.(check string) "nothing sent"
    (N.error_to_string N.Not_a_prefix_of_the_request)
    (refused (N.answered memory pass ~sent:[]));
  Alcotest.(check string) "not the first facts"
    (N.error_to_string N.Not_a_prefix_of_the_request)
    (refused (N.answered memory pass ~sent:(facts [ 2 ])));
  let memory, empty_pass = start memory [] in
  Alcotest.(check string) "no request out" (N.error_to_string N.No_item)
    (refused (N.answered memory empty_pass ~sent:(facts [ 1 ])))
;;

let test_tick_wins () =
  Alcotest.(check bool) "tick with commit" true (N.combine_wake N.Commit N.Tick = N.Tick);
  Alcotest.(check bool) "commit with commit" true (N.combine_wake N.Commit N.Commit = N.Commit)
;;

let () =
  Alcotest.run
    "workspace_memory_narrowing"
    [ ( "rules"
      , [ Alcotest.test_case "every request refused" `Quick test_every_request_refused
        ; Alcotest.test_case "a poison fact" `Quick test_poison_fact
        ; Alcotest.test_case "an unspoken slot keeps the fact" `Quick test_unspoken_slot_keeps_the_fact
        ; Alcotest.test_case "size from size refusals only" `Quick test_size_from_sized_refusals_only
        ; Alcotest.test_case "a new generation empties the memory" `Quick test_new_generation_empties_memory
        ; Alcotest.test_case "an older pass writes nothing" `Quick test_older_pass_writes_nothing
        ; Alcotest.test_case "a quiet batch waits for the tick" `Quick test_quiet_batch_waits_for_the_tick
        ; Alcotest.test_case "halves stay apart" `Quick test_halves_stay_apart
        ; Alcotest.test_case "an unusable or overdue batch narrows" `Quick test_unusable_or_overdue_batch_narrows
        ; Alcotest.test_case "a tick asks places as they are" `Quick test_tick_asks_places_as_they_are
        ; Alcotest.test_case "a fact change forgets" `Quick test_fact_change_forgets
        ; Alcotest.test_case "the facts sent lead the request" `Quick test_sent_must_lead_the_request
        ; Alcotest.test_case "tick wins" `Quick test_tick_wins
        ] )
    ]
;;
