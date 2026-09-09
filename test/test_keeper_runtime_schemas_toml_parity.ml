(** The publication order of [Keeper_runtime_schemas_toml.schemas], and the
    keeper_artifact_read bounds and keeper_analyze_image enum against their owners.

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

    The descriptions and schemas this suite also pinned were literals read off
    the same published values before the declarations moved into
    [config/tools/*.toml] -- one producer against a snapshot of itself. Those
    cases are gone; what stays reads the published value. *)

open Alcotest


(* name, description, input_schema (keys sorted), in the order
   Keeper_runtime_schemas_toml.schemas publishes. The three provider Files
   tools are #33639 (RFC-0430 Phase 3); keeper_analyze_image carries the
   runtime_id parameter #34561 added. *)
let expected =
    [ {|keeper_artifact_read|}, {|Restore the content of a [masc:blob ...] ToolResult by its sha256. The marker's bytes= field is the artifact's total size. max_bytes defaults to the 16384 maximum, which is the largest page that never itself becomes an unreadable spilled file; read whole artifacts by paging, not by small slices. If the response has eof=false, continue from next_offset until eof=true. Text pages use UTF-8; arbitrary bytes use base64. The runtime never re-inlines a stored artifact into model history; this tool is the only way to read one.|}, {|{"additionalProperties":false,"properties":{"max_bytes":{"default":16384,"description":"Maximum source bytes in this model-visible page. Defaults to the maximum; lower it only for a deliberate slice, not for paging.","maximum":16384,"minimum":1,"type":"integer"},"offset":{"default":0,"description":"Byte offset to read from. Continue a paged read at the returned next_offset.","minimum":0,"type":"integer"},"sha256":{"description":"Exact sha256 from a [masc:blob ...] ToolResult.","type":"string"}},"required":["sha256"],"type":"object"}|}
    ; {|masc_fusion|}, {|Run an out-of-band panel+judge deliberation.

A panel of models from the configured preset answers the prompt independently; a judge model synthesises consensus, contradictions, partial coverage, unique insights, and blind spots. Advisory only: this keeper turn continues immediately; when the deliberation completes you are WOKEN with the result, and the conclusion (or the failure reason) is appended to your chat lane (also visible in the dashboard) — do not poll masc_fusion_status while waiting. Returns a status with a run_id. Panels answer from their own knowledge only: they cannot see your files, tasks, or conversation, so phrase the prompt self-contained. Set web_tools=true to let the panel and judge ground their answers with web_search / web_fetch. Gated by runtime.toml [fusion] (disabled by default).|}, {|{"additionalProperties":false,"properties":{"preset":{"description":"Panel preset name from runtime.toml [fusion.presets]. Omitted uses the configured default_preset.","type":"string"},"prompt":{"description":"Question or task to deliberate. A panel of models answers independently, then a judge synthesises consensus, contradictions, partial coverage, unique insights, and blind spots. Out-of-band: the synthesis arrives asynchronously on this keeper's chat lane, not inline in this turn.","type":"string"},"topology":{"description":"How to reduce the panel answers. \"simple\" (default): panel -> one judge -> result. \"refine\": panel -> judge -> a second judge that critically reviews and improves the first synthesis against the panel evidence -> result (deeper, two judge passes). \"conditional\": like simple, but escalates to a second (refine) judge only when the first judge could not decide (verdict insufficient); otherwise returns the first synthesis. \"judge_of_judges\": several distinct judges each synthesise the panel independently and a meta-judge reconciles them (requires the preset to configure >= 2 judges). \"staged_judge_of_judges\": first judges are grouped by [fusion].staged_judge_group_size, each group is reconciled by a stage meta-judge, then a final meta-judge reconciles the stage results (requires at least two exact groups; ragged counts are rejected). Unknown values are rejected.","type":"string"},"web_tools":{"description":"When true, the panel and judge agents are given web_search / web_fetch tools to ground their answers. Defaults to false; the selected preset may also enable web tools on its own (the effective setting is this flag OR the preset's).","type":"boolean"}},"required":["prompt"],"type":"object"}|}
    ; {|masc_fusion_status|}, {|Read the status of out-of-band fusion deliberations started by masc_fusion.

With no argument, lists tracked runs (in-progress and recently completed); with a run_id, returns that single run. Each run reports keeper, preset, started_at (unix seconds), and status (running | completed | failed); failed runs also carry error and failure_code. Prefer waiting for the completion wake over polling this tool — the result reaches you without it. Read-only — does not start a deliberation. In-memory and server-lifetime: runs do not survive a restart.|}, {|{"additionalProperties":false,"properties":{"run_id":{"description":"Optional fusion run id (the run_id returned by masc_fusion). When given, returns that single run's status; when omitted, lists every tracked run (in-progress and recently completed).","type":"string"}},"type":"object"}|}
    ; {|masc_file_upload|}, {|Upload an image to the provider Files API and get a file_id back.

The file_id can then be used in a vision request to send the same image many times without re-uploading it, and it allows images larger than the inline size limit. Only images are accepted; the largest allowed file is 64 MiB and files are stored for reuse. Use masc_file_delete when the file is no longer needed.|}, {|{"properties":{"content_base64":{"description":"The file's bytes, base64-encoded.","type":"string"},"filename":{"description":"File name to store, e.g. screenshot.png. Max 512 characters.","type":"string"},"purpose":{"description":"Purpose of the file. The API accepts only \"user_data\" today; omit to use it.","type":"string"}},"required":["filename","content_base64"],"type":"object"}|}
    ; {|masc_file_delete|}, {|Delete an uploaded file from the provider Files API by its file_id.

Deletion is permanent; a vision request that still names the file_id will fail afterwards.|}, {|{"properties":{"file_id":{"description":"The file_id returned by masc_file_upload.","type":"string"}},"required":["file_id"],"type":"object"}|}
    ; {|masc_file_list|}, {|List the files currently stored in the provider Files API.

Each row carries file_id, name, size, and upload time — enough to find a previously uploaded image to reuse in a vision request.|}, {|{"properties":{},"type":"object"}|}
    ; {|keeper_analyze_image|}, {|Read a stored image artifact and return a text description or answer. Delegates to a vision model in a sub-call; the image is never added to this conversation. Returns the extracted text, or a typed error (invalid_args | eio_context_unavailable | artifact_load_failed | invalid_timeout | image_too_large | invalid_media_type | invalid_request | no_capable_runtime | empty_extraction | truncated_extraction | timeout | provider_error).|}, {|{"additionalProperties":false,"properties":{"artifact":{"description":"Handle of a stored image artifact (the content-addressed id returned when the image was stored). The raw image is read in a vision sub-call and never enters this conversation.","type":"string"},"media_type":{"description":"Optional image MIME type override (e.g. image/png, image/jpeg). Sniffed from the bytes when omitted.","enum":["image/png","image/jpeg","image/gif","image/webp"],"type":"string"},"query":{"description":"What to ask about the image, e.g. \"describe the chart\" or \"transcribe the text\".","type":"string"},"runtime_id":{"description":"Optional exact configured vision runtime identifier. When supplied, only that capable runtime is called; errors do not fall back to a different reader. Omit for automatic selection and failover. Useful for comparing readings of the same artifact.","type":"string"}},"required":["artifact","query"],"type":"object"}|}
    ];;

let published = Masc.Keeper_runtime_schemas_toml.schemas

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Keeper_runtime_schemas_toml.schemas")
;;

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Keeper_runtime_schemas_toml.schemas in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;


(* The pin the migration to TOML was supposed to arrive with. Two of these
   schemas declare numbers an OCaml module owns, and moving them into a file
   cut the derivation without leaving anything to notice a divergence. It
   diverged: #32748 lowered keeper_artifact_read's bound to 16,384 and the
   file kept advertising 65,536, so the schema told a model it could ask for
   four times what the handler accepts. These compare the published
   declaration against the owner rather than against a second literal. *)
let declared schema_name ~field ~key =
  match (find schema_name).input_schema with
  | `Assoc top ->
    (match List.assoc_opt "properties" top with
     | Some (`Assoc properties) ->
       (match List.assoc_opt field properties with
        | Some (`Assoc declaration) -> List.assoc_opt key declaration
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let declared_int schema_name ~field ~key =
  match declared schema_name ~field ~key with
  | Some (`Int value) -> Some value
  | _ -> None
;;

let test_artifact_read_bounds_match_their_owner () =
  check
    (option int)
    "keeper_artifact_read declares Keeper_artifact_read.maximum_max_bytes"
    (Some Masc.Keeper_artifact_read.maximum_max_bytes)
    (declared_int "keeper_artifact_read" ~field:"max_bytes" ~key:"maximum");
  check
    (option int)
    "keeper_artifact_read declares Keeper_artifact_read.default_max_bytes"
    (Some Masc.Keeper_artifact_read.default_max_bytes)
    (declared_int "keeper_artifact_read" ~field:"max_bytes" ~key:"default")
;;

let test_analyze_image_enum_matches_its_owner () =
  let declared_types =
    match declared "keeper_analyze_image" ~field:"media_type" ~key:"enum" with
    | Some (`List items) ->
      List.filter_map (function `String value -> Some value | _ -> None) items
    | _ -> []
  in
  check
    (list string)
    "keeper_analyze_image declares Keeper_vision_tool.supported_image_media_types"
    Masc.Keeper_vision_tool.supported_image_media_types
    declared_types
;;

let () =
  run
    "keeper_runtime_schemas_toml_parity"
    [ ( "order"
      , [ test_case "published order" `Quick test_the_published_order_is_unchanged
        ] )
    ; ( "owner_derivation"
      , [ test_case
            "keeper_artifact_read bounds match their owner"
            `Quick
            test_artifact_read_bounds_match_their_owner
        ; test_case
            "keeper_analyze_image enum matches its owner"
            `Quick
            test_analyze_image_enum_matches_its_owner
        ] )
    ]
;;
