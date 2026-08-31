(** Byte-identity pins for the base tool toml parity declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [Tool_shard_types.base_tools] before any file moved, so this
    suite passing *before* the TOML replaces a literal is what proves the file
    says the same thing. Written against the published list rather than a loader
    module, so it holds across the whole migration: what a Keeper receives must
    not move whether a declaration lives in OCaml or TOML.

    keeper_memory_search advertises the source vocabulary that
    [Keeper_tool_memory_runtime] owns. In TOML that becomes a literal --
    nothing there reads an OCaml value -- and [test_enum_mirror_sync] already
    compares the advertised array against the owner, so a value added on one
    side without editing the file fails there.

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
    [ {|keeper_time_now|}, {|Get current server time. Returns now_iso (ISO8601) and now_unix (float). Use to timestamp events, check elapsed time, or include current time in reports.|}, {|{"additionalProperties":false,"properties":{},"type":"object"}|}
    ; {|keeper_context_status|}, {|Check your own persisted checkpoint and session state. Returns: name (your keeper name), checkpoint_bytes, message_count, generation, memory fact counts, sandbox health, and your workspace root plus backend/profile metadata. Context-window occupancy is not currently observed and is not returned. sandbox paths are tool-ready and can be passed directly as path or cwd to keeper tools without prefix. Use when checking checkpoint/session continuity or resolving a path without string-interpolating your own keeper name.|}, {|{"additionalProperties":false,"properties":{},"type":"object"}|}
    ; {|keeper_memory_search|}, {|Search your durable Memory OS facts or conversation history. Memory OS fact results preserve snapshot order and include category and insertion timestamp. Default searches the durable fact store. Use source='history' for raw user messages, source='all' for both.|}, {|{"additionalProperties":false,"properties":{"limit":{"description":"max results (1-10, default 5). Must be a bare integer (e.g. 5); a quoted value is rejected.","type":"integer"},"query":{"description":"keyword to search for","type":"string"},"source":{"description":"Search scope: memory (default, durable facts), history (raw messages), or all","enum":["memory","history","all"],"type":"string"}},"required":["query"],"type":"object"}|}
    ; {|keeper_memory_write|}, {|Record a durable claim that later turns read back. Your context resets between turns, so a conclusion you leave only in this turn's reasoning is gone. Task sequencing and operating constraints belong to their typed domain stores, not memory prose. The runtime records explicit typed provenance and returns validation or persistence failures directly. When source_path is set, the claim is recalled only while the exact source bytes still match.|}, {|{"additionalProperties":false,"properties":{"content":{"description":"Body. Required, must be non-empty. For decisions, lead with the decision then **Why** and **How to apply** lines.","type":"string"},"source_path":{"description":"Optional keeper-visible regular file that makes this claim source-bound.","type":"string"},"title":{"description":"Short hook (≤120 chars). Optional; may be empty.","type":"string"}},"required":["content"],"type":"object"}|}
    ; {|keeper_tools_list|}, {|List the complete Tool and Skill capability inventory frozen for this Keeper turn, including operator-only and unavailable entries with their typed availability. This is capability introspection, not connector content lookup. Use keeper_capability_search to retrieve lexically relevant candidates.|}, {|{"additionalProperties":false,"properties":{},"type":"object"}|}
    ; {|keeper_capability_search|}, {|Search the complete Tool and Skill capability inventory frozen for this Keeper turn. SQLite FTS5 ranks lexical candidates with BM25. Results retain exact typed capability identity and availability but never invoke a candidate.|}, {|{"additionalProperties":false,"properties":{"query":{"description":"FTS5 query over exact capability name, description, and invocation name. No substring, regex, stop-word, threshold, top-N, or intent-expansion heuristic is added.","type":"string"}},"required":["query"],"type":"object"}|}
    ]
;;

let published = Tool_shard_types.base_tools

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_shard_types.base_tools")
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
    "Tool_shard_types.base_tools in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "base_tool_toml_parity"
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
