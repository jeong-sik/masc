(** Byte-identity pins for the filesystem shard toml parity declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [Tool_shard_types.filesystem_tools] before any file moved, so this
    suite passing *before* the TOML replaces a literal is what proves the file
    says the same thing. Written against the published list rather than a loader
    module, so it holds across the whole migration: what a Keeper receives must
    not move whether a declaration lives in OCaml or TOML.

    These four go to MCP clients under their own names. The model-facing
    Read / Edit / Write / Grep are separate tools with separate schemas, and
    their declarations were named after these until the files were renamed to
    what they publish -- which is what freed these names.

    Compared as parsed JSON with keys sorted, per RFC §4 -- object key order is
    not part of a JSON object's meaning, and TOML cannot place a sub-table
    before its parent's scalar keys.

    masc#31573 later changed the published contract deliberately: mode became
    required on tool_edit_file/tool_write_file and absence is rejected instead
    of defaulting to overwrite. The pins moved with that contract. *)

open Alcotest

let rec sorted (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (key, value) -> key, sorted value)
       |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List items -> `List (List.map sorted items)
  | other -> other
;;

(* name, description, input_schema (keys sorted) *)
let expected =
    [ {|tool_read_file|}, {|Read a file as text (truncated at max_bytes). path is REQUIRED. Paths resolve relative to your workspace root, or to the typed `cwd` when you pass one — never a host path like '.masc/playground/your-name/...'. Good: path='lib/foo.ml'. Bad: path=''. For multi-file search, use Grep.|}, {|{"properties":{"max_bytes":{"description":"Max bytes to return (default: 20000)","type":"integer"},"path":{"description":"Relative or absolute file path","type":"string"}},"required":["path"],"type":"object"}|}
    ; {|tool_edit_file|}, {|Write, append, or patch a file. path and mode are required; an absent mode is rejected instead of defaulting to overwrite. For mode='overwrite' or 'append', content is required and non-empty. For mode='patch', old_string and new_string are required; old_string must match exactly once unless replace_all=true. Good overwrite: path='lib/foo.ml', mode='overwrite', content='let x = 1'. Good patch: path='lib/foo.ml', mode='patch', old_string='old', new_string='new'. Bad: path='', content=''. Bad: mode='create' (use overwrite). Creates parent dirs.|}, {|{"properties":{"content":{"description":"File content to write","type":"string"},"mode":{"description":"Write mode; absence is rejected","enum":["overwrite","append","patch"],"type":"string"},"new_string":{"description":"Patch mode replacement substring","type":"string"},"old_string":{"description":"Patch mode substring to replace","type":"string"},"path":{"description":"Relative or absolute file path to write","type":"string"},"replace_all":{"description":"Patch every occurrence instead of exactly one","type":"boolean"}},"required":["path","mode"],"type":"object"}|}
    ; {|tool_write_file|}, {|Write or append a file. path and mode are required; an absent mode is rejected instead of defaulting to overwrite. content is required and non-empty. Good overwrite: path='lib/foo.ml', mode='overwrite', content='let x = 1'. Bad: path='', content=''. Creates parent dirs.|}, {|{"properties":{"content":{"description":"File content to write","type":"string"},"mode":{"description":"Write mode; absence is rejected","enum":["overwrite","append"],"type":"string"},"path":{"description":"Relative or absolute file path to write","type":"string"}},"required":["path","content","mode"],"type":"object"}|}
    ; {|keeper_ide_annotate|}, {|Attach a keeper-authored annotation to a source file line range.

Use this to leave durable IDE context linked to an optional goal, task, or opaque external reference. codebase, file_path, line_start, and content are required. Hand codebase and file_path back exactly as the IDE co-view context names them — never derive them from your sandbox mount layout. The IDE transport stores and renders reference relation/value pairs without interpreting the producer's product vocabulary.|}, {|{"additionalProperties":false,"properties":{"codebase":{"description":"Canonical codebase slug exactly as the co-view context names it (e.g. example.com_owner_repo)","type":"string"},"content":{"description":"Short annotation text shown in the IDE","type":"string"},"file_path":{"description":"Repo-root-relative source file path exactly as the co-view context names it","type":"string"},"goal_id":{"description":"Optional Goal route id","type":"string"},"kind":{"description":"Annotation kind; defaults to Comment","enum":["Comment","Decision","Question","Bookmark"],"type":"string"},"line_end":{"description":"Last 1-based source line; defaults to line_start","minimum":1,"type":"integer"},"line_start":{"description":"First 1-based source line","minimum":1,"type":"integer"},"references":{"description":"Optional opaque links rendered by the IDE without product-specific routing","items":{"additionalProperties":false,"properties":{"reference":{"description":"Opaque reference value preserved without interpretation","type":"string"},"relation":{"description":"Opaque relation label supplied by the producer","type":"string"}},"required":["relation","reference"],"type":"object"},"type":"array"},"task_id":{"description":"Optional Task route id","type":"string"}},"required":["codebase","file_path","line_start","content"],"type":"object"}|}
    ]
;;

let published = Tool_shard_types.filesystem_tools

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_shard_types.filesystem_tools")
;;

let test_descriptions_are_byte_identical () =
  List.iter
    (fun (name, description, _) ->
       check string (name ^ " description") description (find name).description)
    expected
;;

let test_input_schemas_match_with_keys_sorted () =
  List.iter
    (fun (name, _, schema) ->
       check
         string
         (name ^ " input_schema")
         schema
         (Yojson.Safe.to_string (sorted (find name).input_schema)))
    expected
;;

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_shard_types.filesystem_tools in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "filesystem_shard_toml_parity"
    [ ( "byte_identity"
      , [ test_case "descriptions" `Quick test_descriptions_are_byte_identical
        ; test_case
            "input schemas, keys sorted"
            `Quick
            test_input_schemas_match_with_keys_sorted
        ; test_case "published order" `Quick test_the_published_order_is_unchanged
        ] )
    ]
;;
