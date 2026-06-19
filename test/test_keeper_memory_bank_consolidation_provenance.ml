(** Regression: cross-trace recurrence consolidation must persist a trace_id.

    [Keeper_memory_bank.consolidate_memory_notes] promotes a text that recurs
    across >= [consolidation_min_group_size] distinct traces to a [long_term]
    row tagged [Cross_trace_recurrence].  The read guard
    [parse_memory_bank_row] rejects any row with an empty [trace_id], so a
    promoted row written without one is silently purged on the next
    read/compaction — losing exactly the cross-trace knowledge consolidation
    just decided was worth keeping.  The progress-cluster path already carries
    a [trace_id]; this pins that the cross-trace path does too, via a
    build -> serialize -> reparse round-trip on the promoted row. *)

module Keeper_memory_bank = Masc.Keeper_memory_bank
open Keeper_memory_bank

(* schema_version and the kind -> horizon mapping are fixed by
   keeper_memory_policy: schema 2, kind "progress" -> horizon "short_term". *)
let progress_row ~trace_id ~text : string =
  `Assoc
    [ ("schema_version", `Int 2)
    ; ("kind", `String "progress")
    ; ("horizon", `String "short_term")
    ; ("source", `String "tool_result")
    ; ("trace_id", `String trace_id)
    ; ("generation", `Int 1)
    ; ("priority", `Int 50)
    ; ("text", `String text)
    ; ("ts_unix", `Float 1_700_000_000.0)
    ]
  |> Yojson.Safe.to_string

let parse_or_fail line =
  match parse_memory_bank_row line with
  | Some r -> r
  | None -> Alcotest.failf "fixture row should parse but did not: %s" line

(* One text repeated across four distinct traces (>= the min group size of 3,
   with margin).  Each trace contributes a single progress row, so the
   same-trace progress consolidation path stays below its group threshold and
   only the cross-trace recurrence path fires. *)
let recurring_text =
  "Database migration step 3 completed and verified against staging"

let input_rows () =
  [ "trace-a"; "trace-b"; "trace-c"; "trace-d" ]
  |> List.map (fun trace_id ->
         parse_or_fail (progress_row ~trace_id ~text:recurring_text))

let test_cross_trace_row_survives_reparse () =
  let consolidated, _dropped = consolidate_memory_notes (input_rows ()) in
  let cross_trace_rows =
    List.filter
      (fun (r : keeper_memory_row_raw) -> r.source = Cross_trace_recurrence)
      consolidated
  in
  (* Non-vacuous: consolidation actually produced a cross-trace promotion. *)
  Alcotest.(check bool)
    "cross-trace recurrence row was produced" true
    (cross_trace_rows <> []);
  List.iter
    (fun (r : keeper_memory_row_raw) ->
      (* The promoted row carries a non-empty trace_id ... *)
      Alcotest.(check bool)
        "promoted cross-trace row has non-empty trace_id" true
        (row_trace_id r <> "");
      (* ... so re-reading its serialized form survives the read guard
         instead of being silently dropped. *)
      let serialized = Yojson.Safe.to_string r.json in
      match parse_memory_bank_row serialized with
      | Some _ -> ()
      | None ->
          Alcotest.failf
            "promoted cross-trace row was purged on reparse (empty trace_id?): \
             %s"
            serialized)
    cross_trace_rows

let () =
  Alcotest.run "keeper_memory_bank_consolidation_provenance"
    [ ( "cross_trace_recurrence"
      , [ Alcotest.test_case "promoted row survives reparse" `Quick
            test_cross_trace_row_survives_reparse
        ] )
    ]
