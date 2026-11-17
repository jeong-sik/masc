open Alcotest
open Masc

let runtime_source = {|
[providers.local]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"
[models.sample]
api-name = "sample"
max-context = 1024
[local.sample]
[runtime]
default = "local.sample"
|}

let fields =
  ["id", "\"reader-a\"";
   "revision", "\"r1\"";
   "kind", "\"document\"";
   "media_types", "[\"application/vnd.openxmlformats-officedocument.wordprocessingml.document\"]";
   "adapter", "\"markitdown_mcp\"";
   "command", "\"~/not-installed/reader\"";
   "args", "[\"-m\", \"markitdown_mcp\", \"\", \" value \" ]"]

let row ?(replace = []) ?(omit = []) ?(extra = []) () =
  let rows = List.filter_map (fun (key, value) ->
    if List.mem key omit then None
    else Some (key, match List.assoc_opt key replace with Some value -> value | None -> value)) fields in
  "[[media_readers]]\n"
  ^ String.concat "\n" (List.map (fun (key,value) -> key ^ " = " ^ value) (rows @ extra)) ^ "\n"

let config = function
  | Ok config -> config
  | Error errors -> fail (String.concat "; "
      (List.map (fun (error : Runtime_toml.parse_error) -> error.path ^ ": " ^ error.message) errors))

let declarations text = (config (Runtime_toml.parse_string text)).Runtime_schema.media_readers

let require_refusal ~path text =
  match Runtime_toml.parse_string text with
  | Ok _ -> failf "invalid declaration loaded: %s" path
  | Error errors ->
    check bool ("error identifies " ^ path) true
      (List.exists (fun (error : Runtime_toml.parse_error) -> String.starts_with ~prefix:path error.path) errors)

let test_absent_empty_and_overlapping_rows () =
  check bool "absent means no declarations" true (declarations runtime_source = []);
  check bool "empty array means no declarations" true
    (declarations ("media_readers = []\n" ^ runtime_source) = []);
  let source = row () ^ row ~replace:["id","\"reader-b\"";"revision","\"r2\""] () ^ runtime_source in
  match declarations source with
  | [first;second] ->
    check (list string) "both IDs remain in declaration order" ["reader-a";"reader-b"]
      [first.id;second.id];
    check bool "overlapping MIME support is not collapsed" true (first.media_types=second.media_types);
    check bool "kind is the existing Keeper type" true (first.kind=Keeper_media_reading.Document);
    check bool "declared adapter" true (first.adapter=Runtime_schema.Markitdown_mcp);
    check string "command is not expanded or checked on the host" "~/not-installed/reader" first.command;
    check (list string) "argument boundaries and whitespace survive"
      ["-m";"markitdown_mcp";"";" value "] first.args
  | [] | [_] | _ :: _ :: _ :: _ -> fail "two declarations were not retained"

let test_array_of_inline_tables_matches_rows () =
  let inline = "media_readers = [{ " ^ String.concat ", "
      (List.map (fun (key,value) -> key ^ " = " ^ value) fields) ^ " }]\n" in
  check bool "equivalent TOML shapes have the same declaration" true
    (declarations (inline ^ runtime_source) = declarations (row () ^ runtime_source));
  let no_support = declarations (row ~replace:["media_types","[]"] () ^ runtime_source) in
  (match no_support with
  | [reader] -> check bool "empty support is retained without a fallback" true (reader.media_types=[])
  | [] | _ :: _ :: _ -> fail "reader with empty support was lost");
  let exact = declarations (row ~replace:["id","\" reader \"";
      "revision","\" revision \"";"command","\" executable \"";
      "kind","\"audio\"";"media_types","[\"X-User/Case-Sensitive\", \" application/x-custom \"]"]
      () ^ runtime_source) in
  match exact with
  | [reader] ->
    check (list string) "nonblank declaration strings are not rewritten"
      [" reader ";" revision ";" executable "] [reader.id;reader.revision;reader.command];
    check (list string) "support strings are exact and not a format whitelist"
      ["X-User/Case-Sensitive";" application/x-custom "] reader.media_types;
    check bool "shared audio kind" true (reader.kind=Keeper_media_reading.Audio)
  | [] | _ :: _ :: _ -> fail "exact declaration strings were refused"

let test_invalid_fields_are_rejected () =
  List.iter (fun (key,value) ->
    require_refusal ~path:("media_readers[0]." ^ key)
      (row ~replace:[key,value] () ^ runtime_source))
    ["id","\"   \""; "revision","\"\""; "kind","\"image\"";
     "adapter","\"shell\""; "command","\" \"";
     "command","\"command\\u0000suffix\"";
     "args","[\"valid\", \"bad\\u0000arg\"]";
     "args","\"one string\""; "args","[1]";
     "media_types","[\"\"]"; "media_types","[3]";
     "media_types","\"application/pdf\""; "revision","1"; "id","false"];
  List.iter (fun (key,_) ->
    require_refusal ~path:("media_readers[0]." ^ key)
      (row ~omit:[key] () ^ runtime_source)) fields;
  require_refusal ~path:"media_readers[0].argz"
    (row ~extra:["argz","[]"] () ^ runtime_source);
  require_refusal ~path:"media_readers[1].id"
    (row () ^ row ~replace:["revision","\"changed\""] () ^ runtime_source)

let test_section_shape_and_namespace_are_owned () =
  List.iter (fun section -> require_refusal ~path:"media_readers" (section ^ runtime_source))
    ["media_readers = 1\n";
     "media_readers = [\"not a row\"]\n";
     "[media_readers.docx]\ncommand = 'reader'\n"];
  check bool "provider namespace is reserved" true
    (List.mem "media_readers" Runtime_toml.reserved_provider_ids);
  require_refusal ~path:"providers.media_readers"
    (runtime_source ^ "\n[providers.media_readers]\nprotocol = 'openai-compatible-http'\nendpoint = 'http://127.0.0.1:9/v1'\n")

let test_parsed_input_does_not_overwrite_duplicate_keys () =
  let values = List.map (fun (key,_) ->
    let value = match key with
      | "id" -> Otoml.TomlString "reader-a"
      | "revision" -> Otoml.TomlString "r1"
      | "kind" -> Otoml.TomlString "document"
      | "media_types" -> Otoml.TomlArray [Otoml.TomlString "application/pdf"]
      | "adapter" -> Otoml.TomlString "markitdown_mcp"
      | "command" -> Otoml.TomlString "reader"
      | "args" -> Otoml.TomlArray []
      | _ -> fail "unexpected fixture field" in
    key,value) fields in
  let duplicate_row = Otoml.TomlTable (values @ ["id",Otoml.TomlString "reader-b"]) in
  let duplicate_top = Otoml.TomlTable
      ["media_readers",Otoml.TomlArray [];"media_readers",Otoml.TomlArray []] in
  List.iter (fun document ->
    match Runtime_toml.parse_toml document with
    | Error errors -> check bool "duplicate declaration key is reported" true
        (List.exists (fun (error : Runtime_toml.parse_error) ->
          String.starts_with ~prefix:"media_readers" error.path) errors)
    | Ok _ -> fail "duplicate parsed key silently overwrote a declaration")
    [Otoml.TomlTable ["media_readers",Otoml.TomlArray [duplicate_row]];duplicate_top]

let test_original_source_and_captured_rows_survive_new_reading () =
  let first_text = row () ^ runtime_source ^ "\n[keeper]\ninstructions = 'original instruction'\n" in
  let first = Server_runtime_config_source.prepare first_text in
  let captured = (config first.runtime).Runtime_schema.media_readers in
  let second_text = row ~replace:["command","\"different-command\"";"revision","\"r2\""] () ^ runtime_source in
  let second = Server_runtime_config_source.prepare second_text in
  let current = (config second.runtime).Runtime_schema.media_readers in
  check string "original source remains exact" first_text first.source_text;
  check bool "old immutable declaration list is unchanged" true
    (captured = declarations first_text);
  check bool "changed source cannot reuse the previous declaration list" false (current=captured);
  (match first.keeper with
   | Ok document -> check (option string) "Keeper projection remains independent"
       (Some "original instruction") (Keeper_toml_loader.toml_string_opt document "keeper.instructions")
   | Error detail -> fail detail);
  let malformed = row ~replace:["adapter","\"unknown\""] () ^ runtime_source in
  let failed = Server_runtime_config_source.prepare malformed in
  check bool "Runtime error is not an empty successful config" true (Result.is_error failed.runtime);
  check string "invalid source remains available for repair" malformed failed.source_text;
  check bool "failed reading does not mutate old capture" true (captured=declarations first_text)

let () = run "runtime media reader declarations"
  ["declaration input",[
    test_case "absent, empty and overlapping declarations" `Quick test_absent_empty_and_overlapping_rows;
    test_case "inline tables retain the same declaration" `Quick test_array_of_inline_tables_matches_rows;
    test_case "strict field validation" `Quick test_invalid_fields_are_rejected;
    test_case "section shape and provider namespace" `Quick test_section_shape_and_namespace_are_owned;
    test_case "duplicate parsed keys cannot overwrite" `Quick test_parsed_input_does_not_overwrite_duplicate_keys;
    test_case "source observations retain immutable rows" `Quick test_original_source_and_captured_rows_survive_new_reading;
  ]]
