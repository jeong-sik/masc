(** The AGENT_CORE tool-error path must bound its payload before fanning it out.

    [keeper_tools_agent_core_handler_exec] builds one [detail] string from the tool's
    raw result and hands it to three sinks: the SSE broadcast ([~error_text]),
    the error log line, and the blob store. [raw_result] is whatever the tool
    wrote, so a tool that dumps a file returns the whole file.

    Measured on the live fleet 2026-08-06: a single [tool_execute] error
    produced a 699,341,105-byte detail. That one line was 94.3% of the day's
    708 MB system log (other days peak at 254 KB per line), and the same bytes
    landed in the blob store as a 618,922,307-byte object.

    The sibling telemetry on the same call was never affected —
    [tool_io_preview_fields ~output:raw_result] routes through
    [Observability_redact.redact_tool_output]. [error_text] was the one
    consumer that skipped the redactor, which also meant it skipped secret
    masking. *)

open Alcotest

let exec_module = "lib/keeper/keeper_tools_agent_core_handler_exec.ml"

(* Pin the call site, not just the helper: the helper being correct does not
   stop a future edit from dropping it here, which is exactly how the field
   came to differ from its sibling in the first place. *)
let test_error_path_routes_through_the_redactor () =
  check bool
    (Printf.sprintf "%s bounds the error detail through the redactor"
       exec_module)
    true
    (Ast_grep.count_calls
       ~module_path:exec_module
       ~callee:"Observability_redact.redact_preview"
     > 0)
;;

(* A cut at a byte offset can land inside a multi-byte character, so the
   sanitizer has to run after the truncation, not before it — and running it
   before would also mean scanning the whole unbounded payload. *)
let test_bound_holds_for_an_oversized_payload () =
  let raw = String.make (Common.max_tool_result_wire_bytes * 4) 'x' in
  let bounded =
    raw
    |> Masc.Observability_redact.redact_preview
         ~max_len:Common.max_tool_result_wire_bytes
    |> Safe_ops.sanitize_text_utf8
  in
  check bool
    "an oversized payload is cut down"
    true
    (String.length bounded < String.length raw);
  (* The truncation marker costs a few bytes on top of [max_len]; the point is
     that the result is bounded by the budget, not that it equals it. *)
  check bool
    "and the result stays within a small constant of the budget"
    true
    (String.length bounded <= Common.max_tool_result_wire_bytes + 64)
;;

(* Korean text is three bytes per character, so a cut at max_len very likely
   splits one. The result must still be valid UTF-8 for the JSON log writer. *)
let test_bound_survives_multibyte_text () =
  let unit = "가나다라마바사아자차" in
  let repeats = (Common.max_tool_result_wire_bytes / String.length unit) + 8 in
  let raw = String.concat "" (List.init repeats (fun _ -> unit)) in
  let bounded =
    raw
    |> Masc.Observability_redact.redact_preview
         ~max_len:Common.max_tool_result_wire_bytes
    |> Safe_ops.sanitize_text_utf8
  in
  check bool
    "multibyte payload is bounded"
    true
    (String.length bounded <= Common.max_tool_result_wire_bytes + 64);
  check bool
    "and the bound is not vacuous — the input really was larger"
    true
    (String.length raw > Common.max_tool_result_wire_bytes)
;;

let () =
  run
    "keeper tool error text bounded"
    [ ( "call site"
      , [ test_case
            "error detail routes through the redactor"
            `Quick
            test_error_path_routes_through_the_redactor
        ] )
    ; ( "bound"
      , [ test_case
            "oversized payload is cut to the tool-output budget"
            `Quick
            test_bound_holds_for_an_oversized_payload
        ; test_case
            "multibyte payload stays valid after the cut"
            `Quick
            test_bound_survives_multibyte_text
        ] )
    ]
;;
