open Alcotest

module KG = Masc.Keeper_guards
module KTR = Keeper_tool_response

let str_contains s sub =
  try
    ignore (Str.search_forward (Str.regexp_string sub) s 0);
    true
  with
  | Not_found -> false
;;

let test_render_inline_skip_reason_deny () =
  let result =
    KG.render_inline_skip_reason
      ~tool_name:"tool_execute"
      ~reason_code:"keeper_deny"
      ~reason_text:"tool is on the keeper deny list"
  in
  check bool "prefix" true (String.starts_with ~prefix:"[tool_skipped]" result);
  check bool "tool" true (str_contains result "tool=tool_execute");
  check bool "code" true (str_contains result "code=keeper_deny");
  check bool "reason encoded" true (str_contains result "reason=tool%20is%20on")
;;

let test_render_inline_skip_reason_policy () =
  let result =
    KG.render_inline_skip_reason
      ~tool_name:"tool_execute"
      ~reason_code:"policy_gate"
      ~reason_text:"policy gate sample"
  in
  check bool "prefix" true (String.starts_with ~prefix:"[tool_skipped]" result);
  check bool "code" true (str_contains result "code=policy_gate");
  check bool "reason encoded equals" true (str_contains result "policy%20gate")
;;

let test_render_inline_skip_reason_destructive () =
  let result =
    KG.render_inline_skip_reason
      ~tool_name:"tool_execute"
      ~reason_code:"destructive_guard"
      ~reason_text:"pattern='rm -rf' (recursive forced deletion)"
  in
  check bool "prefix" true (String.starts_with ~prefix:"[tool_skipped]" result);
  check bool "code" true (str_contains result "code=destructive_guard");
  check bool "pattern encoded" true (str_contains result "pattern%3D")
;;

let test_render_inline_escape_edge_cases () =
  let empty =
    KG.render_inline_skip_reason ~tool_name:"t" ~reason_code:"c" ~reason_text:""
  in
  check bool "empty reason" true (str_contains empty "reason=");
  let pct =
    KG.render_inline_skip_reason ~tool_name:"t" ~reason_code:"c" ~reason_text:"CPU at 90%"
  in
  check bool "percent encoded" true (str_contains pct "90%25")
;;

let test_normalize_override_passthrough () =
  let override_text =
    "[tool_skipped] tool=tool_execute source=keeper_hook code=keeper_deny \
     reason=tool%20is%20on%20the%20keeper%20deny%20list"
  in
  match
    KTR.normalize_response_text ~text:override_text ~tool_names:[ "tool_execute" ] ()
  with
  | Ok text -> check string "passes through" override_text text
  | Error e -> fail ("unexpected error: " ^ e)
;;

let test_normalize_empty_answer_contract () =
  (* Empty answer with tools keeps the generic, provider-neutral fallback. *)
  (match KTR.normalize_response_text ~text:"" ~tool_names:[ "tool_execute" ] () with
   | Ok text ->
     check string "generic tool-list fallback retained"
       "No textual reply was produced. Tools invoked: tool_execute."
       text
   | Error e -> fail ("unexpected error: " ^ e));
  (* Empty answer without tools still fails instead of inventing a reply. *)
  match KTR.normalize_response_text ~text:"" ~tool_names:[] () with
  | Ok _ -> fail "expected error for empty turn with no tools"
  | Error error ->
    check string "empty/no-tool error retained"
      "keeper turn completed with no textual reply"
      error
;;

let () =
  run
    "keeper unified inline skip"
    [ ( "inline_skip_reason"
      , [ test_case
            "render inline skip deny"
            `Quick
            test_render_inline_skip_reason_deny
        ; test_case
            "render inline skip policy"
            `Quick
            test_render_inline_skip_reason_policy
        ; test_case
            "render inline skip destructive"
            `Quick
            test_render_inline_skip_reason_destructive
        ; test_case
            "render inline escape edge cases"
            `Quick
            test_render_inline_escape_edge_cases
        ; test_case
            "normalize override passthrough"
            `Quick
            test_normalize_override_passthrough
        ; test_case
            "normalize empty answer contract"
            `Quick
            test_normalize_empty_answer_contract
        ] )
    ]
;;
