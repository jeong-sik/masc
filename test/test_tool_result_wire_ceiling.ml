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


(* The agent-core ceiling sits deliberately {e above} the bracket the wire
   ceiling hides under. That is the whole point: MASC owns the wire on that
   lane, no CLI is between the model and the result, and nothing spills. *)
let test_the_agent_core_ceiling_clears_the_spill_bracket () =
  check
    bool
    "agent-core carries more than the official-client ceiling"
    true
    (Common.max_agent_core_inline_result_bytes > Common.max_tool_result_wire_bytes);
  check
    bool
    "and more than the smallest result a CLI was seen to spill"
    true
    (Common.max_agent_core_inline_result_bytes > observed_smallest_spill_bytes)
;;

let test_the_agent_core_projection_carries_that_ceiling () =
  match Tool_output.agent_core_model_projection with
  | Tool_output.Store_above { threshold_bytes } ->
    check
      int
      "the agent-core projection stores above the agent-core ceiling"
      Common.max_agent_core_inline_result_bytes
      threshold_bytes
  | Tool_output.Inline_up_to _ ->
    fail "the agent-core projection must still store, only higher"
;;

(* The regression this file exists to stop next. One bundle is built before
   the turn resolves a runtime, and a heterogeneous lane fallback can change
   the lane between attempts, so a projection captured when the tool is built
   describes whichever lane was guessed rather than the one that ran. If this
   drops to 1, someone turned the question back into an answer. *)
let test_the_projection_is_asked_on_every_call () =
  let asks = ref 0 in
  let tool =
    Masc.Tool_bridge.agent_core_tool_of_masc_with_execution_env
      ~model_projection:
        (fun () ->
           incr asks;
           Tool_output.default_model_projection)
      ~name:"lane_probe"
      ~description:"count projection decisions"
      ~input_schema:(`Assoc [ "type", `String "object" ])
      (fun _execution_env _input ->
         Tool_result.make_ok
           ~tool_name:"lane_probe"
           ~start_time:0.0
           ~data:(`String "ok")
           ())
  in
  let invocation turn =
    Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:""
      ~turn
      ~completion:Agent_core.Tool_contract.Continue_after_success
      ~schedule:
        { planned_index = 0
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Agent_core.Tool_contract.Serial
        }
  in
  List.iter
    (fun turn ->
       match Agent_core.Tool.execute ~invocation:(invocation turn) tool (`Assoc []) with
       | Ok _ -> ()
       | Error _ -> fail "expected the probe tool to execute")
    [ 1; 2 ];
  check int "asked once per call, not once per bundle" 2 !asks
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
        ; test_case
            "the agent-core ceiling clears the spill bracket"
            `Quick
            test_the_agent_core_ceiling_clears_the_spill_bracket
        ; test_case
            "the agent-core projection carries that ceiling"
            `Quick
            test_the_agent_core_projection_carries_that_ceiling
        ; test_case
            "the projection is asked on every call"
            `Quick
            test_the_projection_is_asked_on_every_call
        ] )
    ]
;;
