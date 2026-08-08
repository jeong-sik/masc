(** Tests for the canonical type projections exposed on OAS ADTs:
    - [Response_shape.summarize_blocks] (the content-block-list core of
      [summarize]).
    - [Types.total_tokens] (billable token pair on [api_usage]). *)

open Alcotest
open Llm_provider

let mk_image () =
  Types.Image { media_type = "image/png"; data = "AAAA"; source_type = Types.Base64 }
;;

(* summarize_blocks folds a bare content_block list into the redacted shape. *)
let test_summarize_blocks_counts () =
  let blocks =
    [ Types.Text "hello"
    ; Types.Thinking { signature = None; content = "abcde" }
    ; Types.RedactedThinking "opaque"
    ; Types.Text "   " (* whitespace-only: trimmed to 0 chars *)
    ; mk_image ()
    ]
  in
  let t = Response_shape.summarize_blocks blocks in
  check int "text_blocks" 2 t.Response_shape.text_blocks;
  check int "text_chars (whitespace trimmed)" 5 t.Response_shape.text_chars;
  check int "thinking_blocks" 1 t.Response_shape.thinking_blocks;
  check int "thinking_chars" 5 t.Response_shape.thinking_chars;
  check int "redacted_thinking_blocks" 1 t.Response_shape.redacted_thinking_blocks;
  check int "image_count" 1 t.Response_shape.image_count;
  check int "distinct content_kinds" 4 (List.length t.Response_shape.content_kinds)
;;

(* The empty list yields all-zero counts. *)
let test_summarize_blocks_empty () =
  let t = Response_shape.summarize_blocks [] in
  check int "text_blocks" 0 t.Response_shape.text_blocks;
  check int "thinking_blocks" 0 t.Response_shape.thinking_blocks;
  check int "tool_use_count" 0 t.Response_shape.tool_use_count;
  check int "content_kinds" 0 (List.length t.Response_shape.content_kinds)
;;

(* total_tokens sums the billable pair and excludes cache tokens. *)
let test_total_tokens () =
  let u =
    { Types.input_tokens = 10
    ; output_tokens = 5
    ; cache_creation_input_tokens = 100
    ; cache_read_input_tokens = 200
    ; cost_usd = Some 0.01
    }
  in
  check int "input + output, cache excluded" 15 (Types.total_tokens u);
  check int "zero usage totals zero" 0 (Types.total_tokens Types.zero_api_usage)
;;

let () =
  run
    "canonical_projections"
    [ ( "response_shape"
      , [ test_case "summarize_blocks counts" `Quick test_summarize_blocks_counts
        ; test_case "summarize_blocks empty" `Quick test_summarize_blocks_empty
        ] )
    ; "usage", [ test_case "total_tokens" `Quick test_total_tokens ]
    ]
;;
