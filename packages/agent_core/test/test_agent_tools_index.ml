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

let tool_use id name = Types.ToolUse { id; name; input = `Assoc [] }

let admit names blocks =
  Agent_tools.admit_tool_use_names
    (Agent_tools.build_index (List.map make_tool names))
    blocks
;;

let admitted_names (admission : Agent_tools.tool_use_admission) =
  List.filter_map
    (function
      | Types.ToolUse { name; _ } -> Some name
      | _ -> None)
    admission.admitted
;;

let test_admission_keeps_exact_name () =
  let admission = admit [ "Execute" ] [ tool_use "t1" "Execute" ] in
  check (list string) "exact name survives" [ "Execute" ] (admitted_names admission);
  check (list string) "nothing rejected" [] admission.rejected_names
;;

(* The recovered call must be STORED under the registered name, not merely
   dispatched under it: the transcript is what the next request replays, so
   leaving the fused spelling here keeps handing the model the bad example
   that #29999 stopped short of removing. *)
let test_admission_stores_recovered_call_under_registered_name () =
  let admission = admit [ "Execute" ] [ tool_use "t1" "Execute1139645993.1" ] in
  check (list string) "stored under stem" [ "Execute" ] (admitted_names admission);
  check (list string) "recovery is not a rejection" [] admission.rejected_names
;;

(* masc#29337 live shape: the tail carries [-] and [e], which suffix recovery
   refuses by contract, so no registered tool answers this name. *)
let test_admission_drops_unroutable_name () =
  let admission = admit [ "Execute" ] [ tool_use "t1" "Execute-1.1111e1111111" ] in
  check (list string) "call is gone" [] (admitted_names admission);
  (* The wire name is what the turn has to name back to the model: nothing
     else in the transcript still says what it called. *)
  check
    (list string)
    "the wire name is kept"
    [ "Execute-1.1111e1111111" ]
    admission.rejected_names
;;

(* Length alone decides nothing: a long all-digit tail is still a call number,
   so recovery answers it and the transcript stores the stem either way. *)
let test_admission_recovers_long_digit_tail () =
  let name = "Execute" ^ String.make 4096 '9' in
  let admission = admit [ "Execute" ] [ tool_use "t1" name ] in
  check (list string) "stored under stem" [ "Execute" ] (admitted_names admission);
  check (list string) "nothing rejected" [] admission.rejected_names
;;

(* The 62,946-byte name measured on 2026-08-24 was digits around an [e], which
   no registered tool answers. It reached the transcript intact and the turn
   that carried it cost 862 seconds, so the shape is pinned here. *)
let test_admission_drops_degenerate_long_name () =
  let name = "Execute" ^ String.make 2048 '1' ^ "e" ^ String.make 2048 '9' in
  let admission = admit [ "Execute" ] [ tool_use "t1" name ] in
  check (list string) "no call survives" [] (admitted_names admission);
  check (list string) "the wire name is kept whole" [ name ] admission.rejected_names
;;

let test_admission_keeps_non_tool_blocks () =
  let blocks = [ Types.Text "thinking out loud"; tool_use "t1" "Execute-1.1e1" ] in
  let admission = admit [ "Execute" ] blocks in
  check (list string) "one call dropped" [ "Execute-1.1e1" ] admission.rejected_names;
  check
    (list string)
    "text block untouched"
    [ "thinking out loud" ]
    (List.filter_map
       (function
         | Types.Text text -> Some text
         | _ -> None)
       admission.admitted)
;;

let test_admission_is_per_call () =
  let blocks =
    [ tool_use "t1" "Execute"; tool_use "t2" "Execute-1.1e1"; tool_use "t3" "Grep" ]
  in
  let admission = admit [ "Execute"; "Grep" ] blocks in
  check (list string) "routable calls kept" [ "Execute"; "Grep" ] (admitted_names admission);
  check
    (list string)
    "only the unroutable one dropped"
    [ "Execute-1.1e1" ]
    admission.rejected_names
;;

(* What the model reads. The refusal is only actionable if it says which name
   was refused, and the sentence it lands in is replayed on every later
   request, so the rendering is bounded on both axes. *)
let test_describe_names_quotes_in_arrival_order () =
  check
    string
    "names in arrival order, quoted"
    "\"Beta\", \"Alpha\""
    (Agent_tools.describe_rejected_names [ "Beta"; "Alpha" ])
;;

let test_describe_names_states_one_lesson_per_name () =
  check
    string
    "a name repeated in one turn is one lesson"
    "\"Alpha\", \"Beta\""
    (Agent_tools.describe_rejected_names [ "Alpha"; "Beta"; "Alpha" ])
;;

let test_describe_names_counts_what_it_left_out () =
  let names = List.init 11 (fun index -> Printf.sprintf "Tool%d" index) in
  check
    string
    "lists eight and says how many it did not"
    "\"Tool0\", \"Tool1\", \"Tool2\", \"Tool3\", \"Tool4\", \"Tool5\", \"Tool6\", \"Tool7\" and 3 more"
    (Agent_tools.describe_rejected_names names)
;;

(* The 62,946-byte name measured on 2026-08-24 is the reason this is clipped:
   unclipped, one malformed call would grow every later request. *)
let test_describe_names_clips_a_long_name () =
  let rendered = Agent_tools.describe_rejected_names [ String.make 4096 'x' ] in
  check bool "clipped, not carried whole" true (String.length rendered < 100);
  let rec has_ellipsis index =
    index + 3 <= String.length rendered
    && (String.sub rendered index 3 = "..." || has_ellipsis (index + 1))
  in
  check bool "says it clipped" true (has_ellipsis 0)
;;

(* A clip that lands inside a multi-byte character would put an invalid byte in
   the prompt and replay it on every later request. *)
let test_describe_names_clips_on_a_utf8_boundary () =
  let name = String.concat "" (List.init 40 (fun _ -> "\xed\x95\x9c")) in
  let rendered = Agent_tools.describe_rejected_names [ name ] in
  let rec valid index =
    if index >= String.length rendered
    then true
    else (
      let byte = Char.code rendered.[index] in
      let width =
        if byte < 0x80 then 1 else if byte land 0xE0 = 0xC0 then 2
        else if byte land 0xF0 = 0xE0 then 3
        else if byte land 0xF8 = 0xF0 then 4
        else 0
      in
      if width = 0 || index + width > String.length rendered
      then false
      else (
        let rec continues offset =
          offset >= width
          || (Char.code rendered.[index + offset] land 0xC0 = 0x80 && continues (offset + 1))
        in
        continues 1 && valid (index + width)))
  in
  check bool "every byte sequence is complete" true (valid 0)
;;

let test_admission_preserves_original_tool_indices () =
  let blocks =
    [ Types.Text "before"
    ; tool_use "t0" "Execute"
    ; tool_use "dropped" "Unknown"
    ; Types.Thinking { content = "between"; signature = None }
    ; tool_use "t1" "Grep"
    ]
  in
  let admission = admit [ "Execute"; "Grep" ] blocks in
  let sources =
    List.map
      (fun (source : Hooks.admitted_tool_use_source) ->
         source.planned_index, source.source_tool_use_ordinal)
      admission.tool_source_map.admitted_tool_sources
  in
  check int "complete pre-admission ToolUse inventory" 3
    admission.tool_source_map.source_tool_use_count;
  check
    (list (pair int int))
    "admitted ordinals retain their pre-admission tool ordinal"
    [ 0, 0; 1, 2 ]
    sources
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
    ; ( "history admission"
      , [ test_case "exact name survives" `Quick test_admission_keeps_exact_name
        ; test_case
            "recovered call is stored under the registered name"
            `Quick
            test_admission_stores_recovered_call_under_registered_name
        ; test_case
            "unroutable name never reaches history"
            `Quick
            test_admission_drops_unroutable_name
        ; test_case
            "long digit tail still recovers to the stem"
            `Quick
            test_admission_recovers_long_digit_tail
        ; test_case
            "degenerate long name never reaches history"
            `Quick
            test_admission_drops_degenerate_long_name
        ; test_case "non-tool blocks pass through" `Quick test_admission_keeps_non_tool_blocks
        ; test_case "admission is per call" `Quick test_admission_is_per_call
        ; test_case
            "admission retains original tool indices"
            `Quick
            test_admission_preserves_original_tool_indices
        ] )
    ; ( "rejected name rendering"
      , [ test_case
            "quotes names in arrival order"
            `Quick
            test_describe_names_quotes_in_arrival_order
        ; test_case
            "one lesson per name"
            `Quick
            test_describe_names_states_one_lesson_per_name
        ; test_case
            "counts what it left out"
            `Quick
            test_describe_names_counts_what_it_left_out
        ; test_case "clips a long name" `Quick test_describe_names_clips_a_long_name
        ; test_case
            "clips on a UTF-8 boundary"
            `Quick
            test_describe_names_clips_on_a_utf8_boundary
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
