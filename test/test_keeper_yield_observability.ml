(* A yield record that carries only [turns_used] cannot distinguish a Keeper
   cooperating with a real queue from one that never finishes a turn. These
   fix what the record says about the queue it yielded to. *)

open Alcotest

module Run = Masc.Keeper_agent_run
module Q = Keeper_event_queue

let stimulus ~post_id ~arrived_at ~payload =
  { Q.post_id; urgency = Q.Normal; arrived_at; payload }
;;

let queue_of stimuli = List.fold_left Q.enqueue Q.empty stimuli

let test_summary_reports_what_the_turn_yielded_to () =
  let now = 1000. in
  let pending =
    queue_of
      [ stimulus ~post_id:"a" ~arrived_at:940. ~payload:Q.Bootstrap
      ; stimulus ~post_id:"b" ~arrived_at:990. ~payload:Q.Bootstrap
      ; stimulus ~post_id:"c" ~arrived_at:995. ~payload:Q.Bootstrap
      ]
  in
  let s = Run.durable_stimulus_summary ~now pending in
  check int "every waiting stimulus is counted" 3 s.pending_count;
  (match s.head with
   | Some head ->
     check
       bool
       "the head is the one that will run next"
       true
       (head.Q.payload = Q.Bootstrap)
   | None -> fail "a non-empty queue reported no head");
  check (float 0.001) "the head's wait is measured, not the newest" 60. s.head_age_sec;
  check
    int
    "every waiting payload is retained, not deduplicated in the value"
    3
    (List.length s.kinds)
;;

let test_empty_queue_reports_absence_not_a_fabricated_head () =
  let s = Run.durable_stimulus_summary ~now:1000. Q.empty in
  check int "no pending" 0 s.pending_count;
  check bool "no head is named" true (s.head = None);
  check (float 0.001) "no age is invented" 0. s.head_age_sec;
  check int "no kinds" 0 (List.length s.kinds)
;;

let test_head_age_never_goes_negative () =
  (* A stimulus stamped by a different clock can be ahead of [now]. A negative
     age would read as a stimulus from the future rather than a clock skew. *)
  let pending =
    queue_of [ stimulus ~post_id:"a" ~arrived_at:2000. ~payload:Q.Bootstrap ]
  in
  let s = Run.durable_stimulus_summary ~now:1000. pending in
  check (float 0.001) "skew clamps to zero" 0. s.head_age_sec
;;

let test_summary_renders_every_field () =
  let pending =
    queue_of [ stimulus ~post_id:"a" ~arrived_at:900. ~payload:Q.Bootstrap ]
  in
  let rendered =
    Run.durable_stimulus_summary ~now:1000. pending
    |> Run.durable_stimulus_summary_to_string
  in
  List.iter
    (fun fragment ->
       check
         bool
         (fragment ^ " is present in the log line")
         true
         (Astring.String.is_infix ~affix:fragment rendered))
    [ "pending=1"; "head=bootstrap"; "head_age_sec=100.0"; "kinds=[bootstrap]" ]
;;

let () =
  run
    "Keeper yield observability"
    [ ( "durable stimulus summary"
      , [ test_case
            "reports what the turn yielded to"
            `Quick
            test_summary_reports_what_the_turn_yielded_to
        ; test_case
            "empty queue reports absence"
            `Quick
            test_empty_queue_reports_absence_not_a_fabricated_head
        ; test_case
            "head age never goes negative"
            `Quick
            test_head_age_never_goes_negative
        ; test_case "renders every field" `Quick test_summary_renders_every_field
        ] )
    ]
;;
