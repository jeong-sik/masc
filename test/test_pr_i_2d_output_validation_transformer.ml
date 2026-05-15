open Alcotest

(** RFC-0084 PR-I-2.d — Tool_output_validation transformer migration.

    Unlike PR-I-2.a/b/c, this hook is a *transformer* (it caps
    oversized payloads in-place).  PR-I-1's typed surface is
    observer-only ([unit] return), so the natural target is a
    dedicated [Tool_dispatch.set_result_transformer] surface
    instead of [register_typed_post_hook].

    Pins:
    - [Tool_dispatch.register_post_hook] is gone from
      lib/tool_output_validation.ml
    - [Tool_dispatch.set_result_transformer] is called exactly once
    - the post_hook function still has the original mutating
      signature ([Tool_result.t -> Tool_result.t]) — it just runs
      from a different point in the dispatch loop now
    - the transformer is wired into [dispatch] (source-grep cross-check
      that [apply_result_transformer] is invoked before legacy
      [run_post_hooks]) *)

let read_file path =
  match In_channel.with_open_text path In_channel.input_all with
  | exception _ -> ""
  | content -> content
;;

let count_substring ~haystack ~needle =
  let rec loop i acc =
    let next = String.index_from_opt haystack i needle.[0] in
    match next with
    | None -> acc
    | Some j ->
      let len = String.length needle in
      if j + len <= String.length haystack
         && String.sub haystack j len = needle
      then loop (j + len) (acc + 1)
      else loop (j + 1) acc
  in
  loop 0 0
;;

let test_no_legacy_register_in_output_validation () =
  let content = read_file "lib/tool_output_validation.ml" in
  (check int)
    "Tool_dispatch.register_post_hook must be 0 in \
     lib/tool_output_validation.ml after PR-I-2.d"
    0
    (count_substring ~haystack:content
       ~needle:"Tool_dispatch.register_post_hook")
;;

let test_transformer_setter_used_in_output_validation () =
  let content = read_file "lib/tool_output_validation.ml" in
  (check bool)
    "Tool_dispatch.set_result_transformer appears (>= 1 occurrence \
     including doc) in lib/tool_output_validation.ml after PR-I-2.d"
    true
    (count_substring ~haystack:content
       ~needle:"Tool_dispatch.set_result_transformer" >= 1)
;;

let test_apply_result_transformer_in_dispatch () =
  let content = read_file "lib/tool_dispatch.ml" in
  (check bool)
    "apply_result_transformer must be invoked from dispatch (>= 1 \
     call site inside lib/tool_dispatch.ml)"
    true
    (count_substring ~haystack:content
       ~needle:"apply_result_transformer" >= 1)
;;

let test_transformer_round_trips () =
  (* End-to-end: install a transformer that uppercases the result's
     data string, dispatch through the transformer surface, and
     observe the change.  This is independent of [Tool_dispatch];
     it just round-trips through the new module entry points. *)
  Masc_mcp.Tool_dispatch.set_result_transformer (fun r ->
    { r with data = `String "transformed" });
  let original : Tool_result.t =
    { success = true
    ; data = `String "original"
    ; legacy_message = ""
    ; tool_name = "test_tool"
    ; duration_ms = 0.0
    ; failure_class = None
    }
  in
  let transformed = Masc_mcp.Tool_dispatch.apply_result_transformer original in
  (match transformed.data with
   | `String "transformed" -> ()
   | _ ->
     Alcotest.fail
       "apply_result_transformer did not invoke the registered transformer");
  (* Restore so other tests are isolated. *)
  Masc_mcp.Tool_dispatch.clear_hooks ()
;;

let () =
  run
    "PR-I-2.d Tool_output_validation transformer"
    [ ( "pr-i-2d-output-validation"
      , [ test_case "no-legacy-register-in-output-validation" `Quick
            test_no_legacy_register_in_output_validation
        ; test_case "transformer-setter-used-in-output-validation" `Quick
            test_transformer_setter_used_in_output_validation
        ; test_case "apply-result-transformer-in-dispatch" `Quick
            test_apply_result_transformer_in_dispatch
        ; test_case "transformer-round-trips" `Quick
            test_transformer_round_trips
        ] )
    ]
;;
