(** Byte-identity pins for the web tool toml parity declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [[ Tool_schemas_misc.web_search_schema; Tool_schemas_misc.web_fetch_schema ]] before any file moved, so this
    suite passing *before* the TOML replaces a literal is what proves the file
    says the same thing. Written against the published list rather than a loader
    module, so it holds across the whole migration: what a Keeper receives must
    not move whether a declaration lives in OCaml or TOML.

    These two are reached as individual values rather than through a list --
    the descriptor names each one directly -- so the suite pins them the same
    way. Nothing here derives a value from an owner module.

    Compared as parsed JSON with keys sorted, per RFC §4 -- object key order is
    not part of a JSON object's meaning, and TOML cannot place a sub-table
    before its parent's scalar keys. *)

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
    [ {|masc_web_search|}, {|Search the public web. Use exact tool name WebSearch. Example input: {"query":"OCaml 5.2 release date","limit":5,"includeContent":true}. Returns result.results with title, url, snippet. With includeContent:true the response gains a human-readable content_text rendering of every fetched page. When the configured provider is brave_llm_context the response instead carries grounded=true, context_text (pre-extracted chunks) and sources metadata, with no results rows — includeContent is then a no-op since the content already rides inline. Do not use snake_case names like web_search.|}, {|{"additionalProperties":false,"properties":{"contentMaxChars":{"default":4000,"description":"Maximum fetched characters per result inside content_text.","maximum":20000,"minimum":100,"type":"integer"},"contentTimeout":{"default":15,"description":"Per-result content fetch timeout in seconds.","maximum":60,"minimum":1,"type":"integer"},"includeContent":{"description":"When true, also fetch each result page and add a human-readable content_text rendering. Recommended for research.","type":"boolean"},"limit":{"description":"Maximum number of results to return (1-10, default 5).","type":"integer"},"query":{"description":"Plain-text search query. Example: \"OCaml 5.2 release date\".","type":"string"}},"required":["query"],"type":"object"}|}
    ; {|masc_web_fetch|}, {|Fetch one web page for deeper reading. Use exact tool name WebFetch. Example input: {"url":"https://ocaml.org/news","extractMode":"markdown","maxChars":5000}. Returns text, title, final_url, http_status, truncated. Use after WebSearch when you need a citation or full article text. Do not use snake_case names like web_fetch.|}, {|{"additionalProperties":false,"properties":{"extractMode":{"default":"markdown","description":"Output extraction mode. markdown (default) preserves headings/lists/links; text returns flattened plain text.","enum":["markdown","text"],"type":"string"},"maxChars":{"default":50000,"description":"Maximum extracted content characters to return. Longer pages come back as a head/tail window around a [TRUNCATED ...] marker whose full_text path holds the complete extraction.","maximum":100000,"minimum":1,"type":"integer"},"timeout":{"default":15,"description":"Request timeout in seconds.","maximum":60,"minimum":1,"type":"integer"},"url":{"description":"Full URL to fetch. Example: \"https://ocaml.org/news\".","type":"string"}},"required":["url"],"type":"object"}|}
    ]
;;

let published = [ Tool_schemas_misc.web_search_schema; Tool_schemas_misc.web_fetch_schema ]

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from [ Tool_schemas_misc.web_search_schema; Tool_schemas_misc.web_fetch_schema ]")
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
    "[ Tool_schemas_misc.web_search_schema; Tool_schemas_misc.web_fetch_schema ] in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "web_tool_toml_parity"
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
