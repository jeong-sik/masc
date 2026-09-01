(** Byte-identity pins for the keeper runtime tool declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [Keeper_tool_runtime_schemas.schemas]
    before any file moved, so this suite passing *before* the TOML replaces a
    literal is what proves the file says the same thing. Written against the
    published list rather than a loader module, so it holds across the whole
    migration.

    Two of the four build values from an owner module rather than literals:
    keeper_artifact_read takes its max_bytes bounds and default from
    [Keeper_artifact_read], and analyze_image takes its media-type enum from
    [Keeper_vision_tool]. A TOML literal would cut that derivation, so they
    stay in OCaml until each has a test pinning the file against its owner, the
    way [test_operator_surface_toml_parity] pins the masc_config category enum.

    One value moved rather than being pinned: masc_fusion_status declared an
    empty ["required"], which says nothing an absent one does not -- both
    readers fold them together. Every tool that emitted one was cleaned in the
    same campaign, and this pin carries the cleaned value.

    Compared as parsed JSON with keys sorted, per RFC §4. *)

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
    [ {|keeper_artifact_read|}, {|Restore the content of a [masc:blob ...] ToolResult by its sha256. The marker's bytes= field is the artifact's total size. max_bytes defaults to the 65536 maximum, so one call returns most artifacts whole; read whole artifacts, not small slices. If the response has eof=false, continue from next_offset until eof=true. Text pages use UTF-8; arbitrary bytes use base64. The runtime never re-inlines a stored artifact into model history; this tool is the only way to read one.|}, {|{"additionalProperties":false,"properties":{"max_bytes":{"default":65536,"description":"Maximum source bytes in this model-visible page. Defaults to the maximum; lower it only for a deliberate slice, not for paging.","maximum":65536,"minimum":1,"type":"integer"},"offset":{"default":0,"description":"Byte offset to read from. Continue a paged read at the returned next_offset.","minimum":0,"type":"integer"},"sha256":{"description":"Exact sha256 from a [masc:blob ...] ToolResult.","type":"string"}},"required":["sha256"],"type":"object"}|}
    ; {|masc_fusion|}, {|Run an out-of-band panel+judge deliberation. A panel of models from the configured preset answers the prompt independently; a judge model synthesises consensus, contradictions, partial coverage, unique insights, and blind spots. Advisory only: this keeper turn continues immediately; when the deliberation completes you are WOKEN with the result, and the conclusion (or the failure reason) is appended to your chat lane (also visible in the dashboard) — do not poll masc_fusion_status while waiting. Returns a status with a run_id. Panels answer from their own knowledge only: they cannot see your files, tasks, or conversation, so phrase the prompt self-contained. Set web_tools=true to let the panel and judge ground their answers with web_search / web_fetch. Gated by runtime.toml [fusion] (disabled by default).|}, {|{"additionalProperties":false,"properties":{"preset":{"description":"Panel preset name from runtime.toml [fusion.presets]. Omitted uses the configured default_preset.","type":"string"},"prompt":{"description":"Question or task to deliberate. A panel of models answers independently, then a judge synthesises consensus, contradictions, partial coverage, unique insights, and blind spots. Out-of-band: the synthesis arrives asynchronously on this keeper's chat lane, not inline in this turn.","type":"string"},"topology":{"description":"How to reduce the panel answers. \"simple\" (default): panel -> one judge -> result. \"refine\": panel -> judge -> a second judge that critically reviews and improves the first synthesis against the panel evidence -> result (deeper, two judge passes). \"conditional\": like simple, but escalates to a second (refine) judge only when the first judge could not decide (verdict insufficient); otherwise returns the first synthesis. \"judge_of_judges\": several distinct judges each synthesise the panel independently and a meta-judge reconciles them (requires the preset to configure >= 2 judges). \"staged_judge_of_judges\": first judges are grouped by [fusion].staged_judge_group_size, each group is reconciled by a stage meta-judge, then a final meta-judge reconciles the stage results (requires at least two exact groups; ragged counts are rejected). Unknown values are rejected.","type":"string"},"web_tools":{"description":"When true, the panel and judge agents are given web_search / web_fetch tools to ground their answers. Defaults to false; the selected preset may also enable web tools on its own (the effective setting is this flag OR the preset's).","type":"boolean"}},"required":["prompt"],"type":"object"}|}
    ; {|masc_fusion_status|}, {|Read the status of out-of-band fusion deliberations started by masc_fusion. With no argument, lists tracked runs (in-progress and recently completed); with a run_id, returns that single run. Each run reports keeper, preset, started_at (unix seconds), and status (running | completed | failed); failed runs also carry error and failure_code. Prefer waiting for the completion wake over polling this tool — the result reaches you without it. Read-only — does not start a deliberation. In-memory and server-lifetime: runs do not survive a restart.|}, {|{"additionalProperties":false,"properties":{"run_id":{"description":"Optional fusion run id (the run_id returned by masc_fusion). When given, returns that single run's status; when omitted, lists every tracked run (in-progress and recently completed).","type":"string"}},"type":"object"}|}
    ; {|keeper_analyze_image|}, {|Read a stored image artifact and return a text description or answer. Delegates to a vision model in a sub-call; the image is never added to this conversation. Returns the extracted text, or a typed error (invalid_args | eio_context_unavailable | artifact_load_failed | invalid_timeout | image_too_large | invalid_media_type | invalid_request | no_capable_runtime | empty_extraction | truncated_extraction | timeout | provider_error).|}, {|{"additionalProperties":false,"properties":{"artifact":{"description":"Handle of a stored image artifact (the content-addressed id returned when the image was stored). The raw image is read in a vision sub-call and never enters this conversation.","type":"string"},"media_type":{"description":"Optional image MIME type override (e.g. image/png, image/jpeg). Sniffed from the bytes when omitted.","enum":["image/png","image/jpeg","image/gif","image/webp"],"type":"string"},"query":{"description":"What to ask about the image, e.g. \"describe the chart\" or \"transcribe the text\".","type":"string"}},"required":["artifact","query"],"type":"object"}|}
    ];;

let published = Masc.Keeper_tool_runtime_schemas.schemas

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Keeper_tool_runtime_schemas.schemas")
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
    "Keeper_tool_runtime_schemas.schemas in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "keeper_tool_runtime_schemas_toml_parity"
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
