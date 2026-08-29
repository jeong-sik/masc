(** Byte-identity pins for the filesystem tool TOML migration.

    The expected values below are verbatim copies of the OCaml literals the
    migration removed from [keeper_tool_descriptor.ml] — the four
    [~description] strings and the four [*_schema] property tables. The tests
    serialize both sides with [Yojson.Safe.to_string] and compare strings at
    the consumer the migration must not move:
    [Keeper_tool_descriptor.model_visible_schemas] (the agent-core tools
    parameter every Keeper turn carries).

    A drifted description, a reordered JSON key, a lost required entry, or a
    flipped [additionalProperties] is a byte difference here. Read is the one
    closed object of the four and stays closed; the other three were open and
    stay open. *)

open Alcotest

let visible name =
  match
    List.find_opt
      (fun (s : Masc_domain.tool_schema) -> String.equal s.name name)
      (Masc.Keeper_tool_descriptor.model_visible_schemas ())
  with
  | Some schema -> schema
  | None -> failf "%s is absent from the model-visible surface" name
;;

let expected_read_description =
  "Read one existing file from the keeper sandbox or an allowed path with no \
   implicit cwd. Read targets a single FILE; to list a directory use the Execute \
   tool with ls. Pass cwd explicitly for repo-relative reads. Read never inherits \
   Execute cwd."
;;

let expected_edit_description =
  "Patch an existing file by replacing an exact string. Read the file first and \
   copy old_string verbatim from its current bytes, including leading whitespace, \
   indentation, and newlines; the match is exact and byte-sensitive. On \
   'old_string not found', re-Read the file to get the current text instead of \
   retrying the same string."
;;

let expected_write_description =
  "Write full file content into the keeper sandbox or an allowed path. Missing \
   parent directories are created safely; call Write directly instead of using \
   Execute mkdir."
;;

let expected_search_description =
  "Search file contents with ripgrep: provide a regex `pattern` (and optionally \
   path/glob/type). To list a directory, read a file, or run git status/log/diff, \
   use the Execute tool (e.g. argv=['ls','-la','<path>']). Patterns match within a \
   single line; a literal newline in `pattern` is rejected. To match across lines, \
   run `rg -U` through the Execute tool."
;;

let test_descriptions_are_byte_identical () =
  List.iter
    (fun (name, expected) ->
       check string (name ^ " description") expected (visible name).description)
    [ "Read", expected_read_description
    ; "Edit", expected_edit_description
    ; "Write", expected_write_description
    ; "Grep", expected_search_description
    ]
;;

let member (json : Yojson.Safe.t) key =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let property_names name =
  match member (visible name).input_schema "properties" with
  | Some (`Assoc props) -> List.map fst props
  | _ -> failf "%s has no properties object" name
;;

let required_names name =
  match member (visible name).input_schema "required" with
  | Some (`List entries) ->
    List.map (function `String s -> s | _ -> failf "%s: non-string required" name) entries
  | None -> []
  | Some _ -> failf "%s: required is not an array" name
;;

(* Order is part of the byte comparison: the tools parameter is serialized as
   written, so a reordered TOML file moves bytes on the wire. *)
let test_parameters_keep_their_order_and_requirement () =
  List.iter
    (fun (name, props, required) ->
       check (list string) (name ^ " properties, in order") props (property_names name);
       check (list string) (name ^ " required, in order") required (required_names name))
    [ "Read", [ "file_path"; "cwd"; "offset"; "limit" ], [ "file_path" ]
    ; ( "Edit"
      , [ "file_path"; "old_string"; "new_string"; "replace_all" ]
      , [ "file_path"; "old_string"; "new_string" ] )
    ; "Write", [ "file_path"; "content" ], [ "file_path"; "content" ]
    ; "Grep", [ "pattern"; "path"; "glob"; "type"; "-i" ], [ "pattern" ]
    ]
;;

(* Read and Edit are the [closed_object_schema]s of the four, for different
   costs: an unread fifth key on a Read is a silent no-op, and an undeclared
   'content' key on an Edit used to flip the call into a whole-file overwrite
   through translator mode inference (masc#31573). Write and Grep stay open;
   the split is pinned rather than normalized. *)
let test_read_and_edit_stay_closed_and_the_others_stay_open () =
  let additional name = member (visible name).input_schema "additionalProperties" in
  List.iter
    (fun name ->
       check bool (name ^ " is closed") true (additional name = Some (`Bool false)))
    [ "Read"; "Edit" ];
  List.iter
    (fun name ->
       check bool (name ^ " is open") true (additional name = None))
    [ "Write"; "Grep" ]
;;

let () =
  run
    "filesystem_tool_toml_parity"
    [ ( "byte_identity"
      , [ test_case "descriptions" `Quick test_descriptions_are_byte_identical
        ; test_case
            "parameters keep order and requirement"
            `Quick
            test_parameters_keep_their_order_and_requirement
        ; test_case
            "Read and Edit stay closed, the others stay open"
            `Quick
            test_read_and_edit_stay_closed_and_the_others_stay_open
        ] )
    ]
;;
