(** The ceiling that keeps a tool result on the model's side of the harness's
    spill line.

    An official-client CLI writes a tool result it considers too large to a
    file under its own session directory and hands the model the path. A
    Keeper cannot open it: its read tools resolve inside the sandbox, and on
    a microvm profile the host path is not mounted at all. Measured
    2026-09-02..03 on the live fleet, eighteen such reads were refused, and
    every one of them was a MASC result — twelve from a Jira search, six from
    {!Keeper_artifact_read} itself.

    That last group is why the value moved. A 64KB constant used to decide
    both when a result becomes a blob and how much of a blob a read returns,
    so a read of an externalized result came back at exactly the size the
    harness spills. Reading an artifact produced another unreadable artifact.

    These tests pin the ordering that has to hold for that not to recur, and
    the measurement the number is chosen from. They do not reach a harness:
    what a CLI does with an oversized result is its own behaviour, observed
    and recorded here rather than asserted. *)

open Alcotest
module Artifact_read = Masc.Keeper_artifact_read

(* Measured on the claude_code lane, 2026-09-03: a 20,000-byte tool result
   passed through whole, and the smallest spilled file on disk was 31,558
   bytes. The harness cuts somewhere in between; the ceiling has to sit under
   the low end of that bracket, not inside it. *)
let observed_passes_through_bytes = 20_000
let observed_smallest_spill_bytes = 31_558

let test_ceiling_is_under_the_observed_spill_bracket () =
  check
    bool
    "under the largest result seen to pass through whole"
    true
    (Common.max_tool_result_wire_bytes < observed_passes_through_bytes);
  check
    bool
    "and so under the smallest result seen spilled"
    true
    (Common.max_tool_result_wire_bytes < observed_smallest_spill_bytes)
;;

(* A read of a stored artifact must not itself be large enough to store. When
   both bounds were the old 64KB constant this was an equality, and the page
   a read returned was exactly a spill. *)
let test_a_page_of_a_blob_is_not_itself_spillable () =
  check
    bool
    "an artifact page fits the wire ceiling"
    true
    (Artifact_read.maximum_max_bytes <= Common.max_tool_result_wire_bytes);
  check
    bool
    "and the default read does too"
    true
    (Artifact_read.default_max_bytes <= Common.max_tool_result_wire_bytes)
;;

let () =
  run
    "Tool result wire ceiling"
    [ ( "ordering"
      , [ test_case
            "the ceiling is under the observed spill bracket"
            `Quick
            test_ceiling_is_under_the_observed_spill_bracket
        ; test_case
            "a page of a blob is not itself spillable"
            `Quick
            test_a_page_of_a_blob_is_not_itself_spillable
        ] )
    ]
;;
