open Alcotest

module KG = Masc_mcp.Keeper_guards
module KTD = Masc_mcp.Keeper_tool_disclosure

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
      ~tool_name:"keeper_bash"
      ~reason_code:"keeper_deny"
      ~reason_text:"tool is on the keeper deny list"
  in
  check bool "prefix" true (String.starts_with ~prefix:"[tool_skipped]" result);
  check bool "tool" true (str_contains result "tool=keeper_bash");
  check bool "code" true (str_contains result "code=keeper_deny");
  check bool "reason encoded" true (str_contains result "reason=tool%20is%20on")
;;

let test_render_inline_skip_reason_cost () =
  let result =
    KG.render_inline_skip_reason
      ~tool_name:"keeper_bash"
      ~reason_code:"cost_gate"
      ~reason_text:"accumulated_cost_usd=0.5100 exceeded limit=0.5000"
  in
  check bool "prefix" true (String.starts_with ~prefix:"[tool_skipped]" result);
  check bool "code" true (str_contains result "code=cost_gate");
  check bool "reason encoded equals" true (str_contains result "0.5100%20exceeded")
;;

let test_render_inline_skip_reason_destructive () =
  let result =
    KG.render_inline_skip_reason
      ~tool_name:"keeper_bash"
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

let test_render_inline_with_replacement () =
  let result =
    KG.render_inline_skip_reason
      ~tool_name:"keeper_board_post"
      ~reason_code:"keeper_deny"
      ~reason_text:"denied"
  in
  check bool "has replacement" true (str_contains result "replacement=")
;;

let test_normalize_override_passthrough () =
  let override_text =
    "[tool_skipped] tool=keeper_bash source=keeper_hook code=keeper_deny \
     reason=tool%20is%20on%20the%20keeper%20deny%20list"
  in
  match
    KTD.normalize_response_text ~text:override_text ~tool_names:[ "keeper_bash" ] ()
  with
  | Ok text -> check string "passes through" override_text text
  | Error e -> fail ("unexpected error: " ^ e)
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
            "render inline skip cost"
            `Quick
            test_render_inline_skip_reason_cost
        ; test_case
            "render inline skip destructive"
            `Quick
            test_render_inline_skip_reason_destructive
        ; test_case
            "render inline escape edge cases"
            `Quick
            test_render_inline_escape_edge_cases
        ; test_case
            "render inline replacement"
            `Quick
            test_render_inline_with_replacement
        ; test_case
            "normalize override passthrough"
            `Quick
            test_normalize_override_passthrough
        ] )
    ]
;;
