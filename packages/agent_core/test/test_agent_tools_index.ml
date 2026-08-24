open Alcotest
open Agent_core

let make_tool ?(content = "ok") name =
  Tool.create
    ~name
    ~description:("desc:" ^ name ^ ":" ^ content)
    ~parameters:[]
    (fun _ -> Ok { Types.content; _meta = None })
;;

let tool_description = function
  | None -> None
  | Some (tool : Tool.t) -> Some tool.schema.description
;;

let legacy_find tools name =
  List.find_opt (fun (tool : Tool.t) -> String.equal tool.schema.name name) tools
;;

let check_lookup_matches_legacy tools name =
  let index = Agent_tools.build_index tools in
  check
    (option string)
    ("lookup " ^ name)
    (tool_description (legacy_find tools name))
    (tool_description (Agent_tools.find_in_index index name))
;;

let test_exact_lookup_matches_list_find () =
  let tools = [ make_tool "alpha"; make_tool "beta"; make_tool "gamma" ] in
  List.iter (check_lookup_matches_legacy tools) [ "alpha"; "beta"; "gamma"; "missing" ]
;;

let test_duplicate_exact_name_preserves_first_match () =
  let tools = [ make_tool ~content:"first" "dup"; make_tool ~content:"second" "dup" ] in
  let index = Agent_tools.build_index tools in
  match Agent_tools.find_in_index index "dup" with
  | None -> fail "expected dup"
  | Some tool ->
    check string "first duplicate wins" "desc:dup:first" tool.schema.description
;;

let test_case_variant_never_dispatches () =
  let tools = [ make_tool "READ_FILE" ] in
  let index = Agent_tools.build_index tools in
  check
    (option string)
    "case variant is not inferred"
    None
    (tool_description (Agent_tools.find_in_index index "read_file"))
;;

let test_user_tool_case_variant_does_not_fallback () =
  let tools = [ make_tool "mytool" ] in
  let index = Agent_tools.build_index tools in
  (match Agent_tools.find_in_index index "mytool" with
   | None -> fail "exact match should still work"
   | Some _ -> ());
  check
    (option string)
    "case-variant returns None for user tool"
    None
    (tool_description (Agent_tools.find_in_index index "MYTOOL"));
  check
    (option string)
    "title-cased variant returns None for user tool"
    None
    (tool_description (Agent_tools.find_in_index index "MyTool"))
;;

let test_user_tool_case_variant_does_not_dispatch_neighbor () =
  (* Stronger regression: a user tool is registered under its lowercase
     name. A title-case variant must return None, not silently dispatch
     the lowercase neighbor (which would alter tool identity and audit context). *)
  let tools = [ make_tool ~content:"lowercased" "fetcha" ] in
  let index = Agent_tools.build_index tools in
  check
    (option string)
    "uppercase variant of unregistered user tool returns None"
    None
    (tool_description (Agent_tools.find_in_index index "FetchA"))
;;

(* GLM-family providers fuse a per-call sequence number onto the tool name
   (live shape 2026-08-24, keeper/polisher turns 3042-3044). The suffix
   recovery accepts one registered stem plus a [0-9._] tail and nothing
   else; the boundary cases below pin each refusal. *)
let test_strip_suffix_resolves_glm_call_number_shape () =
  let available = [ "Execute"; "Grep"; "Read" ] in
  check
    (option string)
    "dot-separated call number resolves to the registered stem"
    (Some "Execute")
    (Agent_tools.strip_registered_suffix ~available "Execute1139645993.1");
  check
    (option string)
    "bare call number resolves to the registered stem"
    (Some "Grep")
    (Agent_tools.strip_registered_suffix ~available "Grep1349427591")
;;

let test_strip_suffix_refuses_non_numeric_tails () =
  let available = [ "Execute"; "Grep"; "Read" ] in
  check
    (option string)
    "alphabetic tail stays None"
    None
    (Agent_tools.strip_registered_suffix ~available "Execute_foo");
  check
    (option string)
    "unknown stem stays None"
    None
    (Agent_tools.strip_registered_suffix ~available "Nope12345.1");
  check
    (option string)
    "exact registered name is not the strip's job"
    None
    (Agent_tools.strip_registered_suffix ~available "Execute")
;;

(* Underscore tails are a reject on purpose: registered names themselves carry
   underscores (masc_board_*, keeper_broadcast), so admitting [_] here would
   recover one stem's underscore suffix onto another stem's name. No observed
   GLM shape has used an underscore tail — reopen this only with a live one. *)
let test_strip_suffix_refuses_underscore_tails () =
  check
    (option string)
    "underscore tail stays None"
    None
    (Agent_tools.strip_registered_suffix
       ~available:[ "keeper_broadcast"; "keeper_broadcast_channel" ]
       "keeper_broadcast_1770374959066");
  check
    (option string)
    "reviewer's search_files_2 shape stays None"
    None
    (Agent_tools.strip_registered_suffix
       ~available:[ "search_files" ]
       "search_files_2")
;;

let test_strip_suffix_refuses_ambiguous_prefix () =
  (* With [_] out of the tail class, an underscore stem's numeric tail is
     uniquely its own: "alpha_17" only reads as alpha_1 + "7". Ambiguity needs
     two registered stems separated by digits alone — "alpha12" reads as both
     alpha + "12" and alpha1 + "2" — and recovery must refuse rather than pick. *)
  check
    (option string)
    "underscore stem with a numeric tail resolves to that stem"
    (Some "alpha_1")
    (Agent_tools.strip_registered_suffix
       ~available:[ "alpha"; "alpha_1" ]
       "alpha_17");
  check
    (option string)
    "two digit-separated stems stay None"
    None
    (Agent_tools.strip_registered_suffix
       ~available:[ "alpha"; "alpha1" ]
       "alpha12")
;;

let () =
  run
    "Agent_tools_index"
    [ ( "lookup"
      , [ test_case
            "exact lookup matches list find"
            `Quick
            test_exact_lookup_matches_list_find
        ; test_case
            "duplicate exact name preserves first match"
            `Quick
            test_duplicate_exact_name_preserves_first_match
        ; test_case
            "case variant never dispatches"
            `Quick
            test_case_variant_never_dispatches
        ; test_case
            "user tool case variant does not fallback"
            `Quick
            test_user_tool_case_variant_does_not_fallback
        ; test_case
            "user tool case variant does not dispatch lowercase neighbor"
            `Quick
            test_user_tool_case_variant_does_not_dispatch_neighbor
        ] )
    ; ( "suffix recovery"
      , [ test_case
            "glm call-number shape resolves to the registered stem"
            `Quick
            test_strip_suffix_resolves_glm_call_number_shape
        ; test_case
            "non-numeric tails and unknown stems stay None"
            `Quick
            test_strip_suffix_refuses_non_numeric_tails
        ; test_case
            "ambiguous prefix stays None"
            `Quick
            test_strip_suffix_refuses_ambiguous_prefix
        ; test_case
            "underscore tails stay None"
            `Quick
            test_strip_suffix_refuses_underscore_tails
        ] )
    ]
;;
