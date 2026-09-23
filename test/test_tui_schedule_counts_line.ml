(* The Automation tab's one-line answer to "is anything live for this Keeper,
   and how much closed work is below?"

   The tab drew its rows and nothing else. On the live fleet [code-reviewer]
   held 100 schedule requests, 1 scheduled and 99 terminal, and the rows come
   live-first -- so the screen was one live row followed by a page of closed
   work, with no way to learn that without scrolling to the end of it. *)

open Alcotest
module Types = Masc_tui_types
module Domain = Schedule_domain

let counts pairs = List.map (fun (status, count) -> (status, count)) pairs

let test_the_line_splits_live_from_closed () =
  check string "the live fleet's code-reviewer reading"
    "1 scheduled \xc2\xb7 99 closed (36 succeeded, 63 cancelled)"
    (Types.schedule_counts_line
       (counts
          [ (Domain.Scheduled, 1)
          ; (Domain.Due, 0)
          ; (Domain.Running, 0)
          ; (Domain.Succeeded, 36)
          ; (Domain.Failed, 0)
          ; (Domain.Cancelled, 63)
          ; (Domain.Expired, 0)
          ]))

(* A disposition nothing is in is not a fact about this Keeper. Every zero
   above is left out, and a store that is entirely closed says so rather than
   drawing "0 scheduled". *)
let test_a_disposition_nothing_is_in_is_not_drawn () =
  check string "no live row left"
    "nothing live \xc2\xb7 4 closed (4 cancelled)"
    (Types.schedule_counts_line
       (counts
          [ (Domain.Scheduled, 0)
          ; (Domain.Due, 0)
          ; (Domain.Running, 0)
          ; (Domain.Succeeded, 0)
          ; (Domain.Failed, 0)
          ; (Domain.Cancelled, 4)
          ; (Domain.Expired, 0)
          ]));
  check string "nothing closed yet"
    "2 scheduled, 1 running"
    (Types.schedule_counts_line
       (counts
          [ (Domain.Scheduled, 2)
          ; (Domain.Due, 0)
          ; (Domain.Running, 1)
          ; (Domain.Succeeded, 0)
          ; (Domain.Failed, 0)
          ; (Domain.Cancelled, 0)
          ; (Domain.Expired, 0)
          ]))

(* Live and closed are split by [Schedule_domain.is_terminal], the rule the
   store itself uses, rather than by a word list written here. This walks the
   shared status list so a status added to the contract lands on whichever
   side that rule puts it, and is counted in the closed total if it is
   terminal. *)
let test_the_split_follows_the_stores_own_rule () =
  List.iter
    (fun status ->
      let line = Types.schedule_counts_line [ (status, 7) ] in
      let word = Domain.schedule_status_to_string status in
      if Domain.is_terminal status then
        check string
          (Printf.sprintf "%s is closed" word)
          (Printf.sprintf "nothing live \xc2\xb7 7 closed (7 %s)" word)
          line
      else
        check string (Printf.sprintf "%s is live" word)
          (Printf.sprintf "7 %s" word)
          line)
    Domain.all_schedule_statuses

let () =
  run "tui_schedule_counts_line"
    [ ( "counts_line"
      , [ test_case "the line splits live from closed" `Quick
            test_the_line_splits_live_from_closed
        ; test_case "a disposition nothing is in is not drawn" `Quick
            test_a_disposition_nothing_is_in_is_not_drawn
        ; test_case "the split follows the store's own rule" `Quick
            test_the_split_follows_the_stores_own_rule
        ] )
    ]
