(** Per-tool deferral is declared in the tool's own file, and a declaration
    that cannot be read is not silently a declaration of nothing.

    The axis this replaces is per-source: every descriptor tool loaded because
    it was a descriptor, every attached tool deferred because it was attached.
    That is the shape PR #31728 removed at the Keeper level (RFC-0389 tool
    groups) for the reason it recurs here — a roster somebody maintains, and
    the tools themselves saying nothing about their own cost. *)

open Alcotest
open Masc

let loading = testable (fun ppf l -> Fmt.string ppf (Tool_definition_toml.loading_to_string l)) ( = )

(* Silence is the answer for a tool that declares nothing: every tool did,
   before this axis existed, and none of them should move by default. *)
let test_absent_declaration_is_always_loaded () =
  check
    loading
    "a tool with no defer_loading key rides in every request"
    Tool_definition_toml.Always_loaded
    (Tool_loading_declarations.loading_of_tool "keeper_tool_search")
;;

(* A name with no file at all: tools built in OCaml rather than declared in
   TOML cannot opt in, and deferring one would hide a schema nothing serves. *)
let test_unknown_name_is_always_loaded () =
  check
    loading
    "a name with no tool file rides in every request"
    Tool_definition_toml.Always_loaded
    (Tool_loading_declarations.loading_of_tool "no-such-tool-exists")
;;

let test_declaration_round_trips () =
  let contents =
    {|name = "fixture_tool"
description = "fixture"
defer_loading = true

[[params]]
name = "q"
type = "string"
required = true
description = "fixture param"
|}
  in
  match Tool_definition_toml.load ~name:"fixture_tool" ~contents with
  | Error message -> fail message
  | Ok loaded ->
    check loading "defer_loading = true reads as Deferrable"
      Tool_definition_toml.Deferrable loaded.loading
;;

let test_false_is_always_loaded () =
  let contents =
    {|name = "fixture_tool"
description = "fixture"
defer_loading = false
|}
  in
  match Tool_definition_toml.load ~name:"fixture_tool" ~contents with
  | Error message -> fail message
  | Ok loaded ->
    check loading "defer_loading = false reads as Always_loaded"
      Tool_definition_toml.Always_loaded loaded.loading
;;

(* TOML puts a bare key after a [[params]] table inside that table. The
   declaration then belongs to a parameter, where it means nothing -- so the
   loader must reject it rather than let it read as "declared nothing". *)
let test_declaration_after_a_params_table_is_rejected () =
  let contents =
    {|name = "fixture_tool"
description = "fixture"

[[params]]
name = "q"
type = "string"
required = true
description = "fixture param"

defer_loading = true
|}
  in
  match Tool_definition_toml.load ~name:"fixture_tool" ~contents with
  | Ok (_ : Tool_definition_toml.loaded) ->
    fail "a misplaced defer_loading must not load as an absent one"
  | Error message ->
    check bool
      ("the error names the key: " ^ message)
      true
      (Astring.String.is_infix ~affix:"defer_loading" message)
;;

let test_non_bool_is_rejected () =
  let contents =
    {|name = "fixture_tool"
description = "fixture"
defer_loading = "yes"
|}
  in
  match Tool_definition_toml.load ~name:"fixture_tool" ~contents with
  | Ok (_ : Tool_definition_toml.loaded) -> fail "a string must not read as a flag"
  | Error message ->
    check bool
      ("the error names the key: " ^ message)
      true
      (Astring.String.is_infix ~affix:"defer_loading" message)
;;

(* The swallow this module must not do: a file that cannot be read has to
   raise, because "declares nothing" and "could not be read" are the same
   answer at every call site. *)
let test_a_malformed_file_raises_rather_than_reading_as_absent () =
  let contents =
    {|name = "fixture_tool"
description = "fixture"

[[params]]
name = "q"
type = "string"
required = true
description = "fixture param"

defer_loading = true
|}
  in
  match
    Tool_loading_declarations.loading_of_declaration
      ~path:"tools/fixture_tool.toml"
      ~name:"fixture_tool"
      ~contents
  with
  | (_ : Tool_definition_toml.loading) ->
    fail "a file that does not parse must not read as one declaring nothing"
  | exception Failure message ->
    check bool
      ("the failure names the file: " ^ message)
      true
      (Astring.String.is_infix ~affix:"tools/fixture_tool.toml" message)
;;

let test_a_well_formed_file_reads_through_the_same_door () =
  let contents =
    {|name = "fixture_tool"
description = "fixture"
defer_loading = true
|}
  in
  check
    loading
    "the declaration reads as Deferrable"
    Tool_definition_toml.Deferrable
    (Tool_loading_declarations.loading_of_declaration
       ~path:"tools/fixture_tool.toml"
       ~name:"fixture_tool"
       ~contents)
;;

(* The way out of a listing. A deferred tool is named but not described, and
   the model reaches it by asking one of these three. Deferring one of them
   would leave its own name in the listing that only it can read: the tools
   below it become unreachable, and nothing reports it, because a name in a
   listing is a live tool as far as every other check can tell. *)
let test_the_tools_that_load_deferred_tools_are_never_deferred () =
  List.iter
    (fun name ->
       check
         loading
         (name ^ " rides in every request")
         Tool_definition_toml.Always_loaded
         (Tool_loading_declarations.loading_of_tool name))
    [ "keeper_tool_search"; "keeper_tools_list"; "keeper_capability_search" ]
;;

let () =
  run
    "tool loading declarations"
    [ ( "declaration"
      , [ test_case "absent is always loaded" `Quick test_absent_declaration_is_always_loaded
        ; test_case "unknown name is always loaded" `Quick test_unknown_name_is_always_loaded
        ; test_case "true round trips" `Quick test_declaration_round_trips
        ; test_case "false is always loaded" `Quick test_false_is_always_loaded
        ; test_case "misplaced is rejected" `Quick
            test_declaration_after_a_params_table_is_rejected
        ; test_case "non-bool is rejected" `Quick test_non_bool_is_rejected
        ; test_case "a malformed file raises" `Quick
            test_a_malformed_file_raises_rather_than_reading_as_absent
        ; test_case "a well-formed file reads through the same door" `Quick
            test_a_well_formed_file_reads_through_the_same_door
        ; test_case "the tools that load deferred tools are never deferred" `Quick
            test_the_tools_that_load_deferred_tools_are_never_deferred
        ] )
    ]
;;
