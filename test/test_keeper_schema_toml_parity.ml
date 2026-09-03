(** Byte-identity pins for the keeper tool declarations moving to
    [config/tools/masc_keeper_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    The expected values were read off [Keeper_schema.schemas] before any file
    moved, so this suite passing *before* the TOML replaces a literal is what
    proves the file says the same thing. Written against the published list
    rather than a loader module, so it holds across the whole migration: what a
    Keeper receives must not move whether a declaration lives in OCaml or TOML.

    One value moved rather than being pinned: masc_keeper_status declared an
    empty ["required"], which says nothing an absent one does not. Both readers
    already fold them together -- llm_provider/types.ml answers [None] and
    [`Null] with [Ok []], and tool_input_validation.ml treats a non-matching
    key the same way -- so it spent bytes in every turn's tool list to say
    nothing. The other four tools that emitted one were cleaned earlier; this
    was the last caller of [closed_object_schema] passing none.

    Compared as parsed JSON with keys sorted, per RFC §4 -- object key order is
    not part of a JSON object's meaning, and TOML cannot place a sub-table
    before its parent's scalar keys. Everything the order does not carry is
    pinned exactly, and the name list below is pinned in order because the list
    order is the order a model sees the tools in.

    Three of the fifteen carry values an owner module owns: masc_keeper_status
    from [Keeper_status_options_defaults], masc_keeper_sandbox_stop from
    [Keeper_sandbox_control_contract], and the network-mode enum from
    [Keeper_types_profile_sandbox]. All three already read from TOML, so the
    literals in those files are copies and something has to compare them back.
    Two are compared elsewhere -- the stop scopes in [test_enum_mirror_sync]
    and both enums in [test_keeper_tool_descriptor_registry_integrity]. The
    third is compared below. *)

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
    [ {|masc_keeper_sandbox_start|}, {|Start the managed sandbox container for a keeper.|}, {|{"additionalProperties":false,"properties":{"name":{"description":"Keeper handle whose managed sandbox should be started.","type":"string"},"network_mode":{"description":"Optional sandbox network mode. Defaults to the keeper's configured network mode.","enum":["none","inherit"],"type":"string"},"timeout_sec":{"description":"Explicit sandbox start timeout in seconds.","exclusiveMinimum":0.0,"type":"number"},"ttl_sec":{"description":"Managed sandbox lifetime in seconds; omit or use 0 for no automatic expiry.","minimum":0.0,"type":"number"}},"required":["name","timeout_sec"],"type":"object"}|}
    ; {|masc_keeper_sandbox_stop|}, {|Stop the managed sandbox container(s) for a keeper or fleet.|}, {|{"additionalProperties":false,"properties":{"container_kind":{"default":"managed","description":"Container scope to stop: managed, turn, or all (default: managed).","enum":["managed","turn","all"],"type":"string"},"name":{"description":"Optional keeper handle. When omitted, stop matching containers across the active fleet.","type":"string"},"prune_stale":{"default":false,"description":"Also remove stale managed sandbox containers after the targeted stop.","type":"boolean"},"timeout_sec":{"description":"Explicit sandbox stop timeout in seconds.","exclusiveMinimum":0.0,"type":"number"}},"required":["timeout_sec"],"type":"object"}|}
    ; {|masc_keeper_audit|}, {|Audit keeper config, prompt, live runtime metadata, registry presence, autoboot, and keepalive state.|}, {|{"additionalProperties":false,"properties":{"include_ok":{"default":true,"description":"If false, return only keepers with audit issues while keeping summary counts over all audited keepers.","type":"boolean"},"limit":{"default":100,"description":"Maximum number of keepers to audit when name/names are omitted. Clamped to 500.","type":"integer"},"name":{"description":"Optional keeper handle to audit. When omitted, all known keepers in the current base path/config root are audited.","type":"string"},"names":{"description":"Optional keeper handles to audit. Combined with name when both are provided.","items":{"type":"string"},"type":"array"}},"type":"object"}|}
    ; {|masc_keeper_up|}, {|Create or update a durable keeper. Keepers auto-start on server boot and are reconciled back into live presence. Each call snapshots the keeper manifest and commits compare-and-swap: if another writer commits first, the call fails with keeper_manifest_revision_conflict and no side effects. Retry the same call — it re-snapshots the current manifest and applies only the fields you pass, so a retry cannot revert another writer's change.|}, {|{"additionalProperties":false,"properties":{"autoboot_enabled":{"description":"If false, persist the keeper but skip auto-start on future server boots.","type":"boolean"},"instructions":{"description":"Complete Keeper instructions, written to the keeper TOML declaration (kept across handoff).","type":"string"},"max_context_override":{"description":"Optional: absolute context token limit override for this keeper. Use 0 to clear the override.","type":"integer"},"mention_targets":{"description":"Exact direct-mention tokens that can wake the keeper in workspace traffic (for example ['alpha']).","items":{"type":"string"},"type":"array"},"name":{"description":"Keeper handle (stable). Example: 'keeper-helper'","type":"string"},"proactive_enabled":{"description":"If true, scheduled keeper cycles may produce proactive responses.","type":"boolean"},"remote_endpoint":{"description":"Endpoint registry name under [exec.ssh.endpoints.<name>] in runtime.toml. Required with sandbox_profile = \"remote_ssh\"; pass null to clear it when switching the keeper to another sandbox profile.","type":"string"},"runtime_id":{"description":"Optional opaque runtime id. Writes the keeper assignment to runtime.toml.","type":"string"},"sandbox_profile":{"default":"docker","description":"Sandbox isolation profile. Pass explicitly: \"docker\" for containerized execution. \"microvm\" runs each guest as a lightweight VM through Apple's container CLI (host needs the CLI and the sandbox image already present; network defaults to none like docker). \"local\" is fail-closed and only resolves when the dev/test hatch MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1 is set. \"remote_ssh\" targets the SSH remote execution lane (Phase 1; requires remote_endpoint in the keeper TOML, runner lands with the lane).","enum":["local","docker","microvm","remote_ssh"],"type":"string"},"skills":{"additionalProperties":false,"description":"Profile-only exact Keeper Skill name selection. Omit to keep it unchanged; skills={} selects all; names=[] selects none.","properties":{"names":{"description":"Exact canonical Skill names. Unknown names remain observable and do not block known names.","items":{"type":"string"},"type":"array"}},"type":"object"}},"required":["name"],"type":"object"}|}
    ; {|masc_keeper_status|}, {|Get keeper status (keepalive/live/reconcile state plus current context and monitoring tails).|}, {|{"additionalProperties":false,"properties":{"fast":{"description":"Enable fast mode (skip heavy sections unless explicitly enabled).","type":"boolean"},"include_context":{"description":"Include checkpoint-derived context stats (default: !fast).","type":"boolean"},"include_history_tail":{"description":"Include recent history tail + fragment counters (default: !fast).","type":"boolean"},"include_metrics_overview":{"description":"Include metrics overview + skill route scan (default: !fast).","type":"boolean"},"name":{"description":"Non-blank Keeper handle. Optional; defaults to the caller only when omitted.","minLength":1,"pattern":"^.*\\S.*$","type":"string"},"tail_bytes":{"description":"How many bytes from the end of files to scan for tails (default: 60000; range: 1000..65536).","maximum":65536,"minimum":1000,"type":"integer"},"tail_messages":{"description":"How many recent history messages to include (default: 5; maximum: 65536).","maximum":65536,"minimum":0,"type":"integer"},"tail_order":{"description":"Ordering for metrics/history tails and recent memory notes. Default: oldest_first.","enum":["oldest_first","newest_first"],"type":"string"},"tail_turns":{"description":"How many recent turns to include from keeper metrics (default: 3; maximum: 6553).","maximum":6553,"minimum":0,"type":"integer"}},"type":"object"}|}
    ; {|masc_keeper_delegate|}, {|Submit one typed Keeper chat operation and return its durable operation_id without waiting for the turn. A Keeper that submits one is woken with the answer when that turn ends: the reply lands in its own queue, carrying the text, so there is nothing to poll for. Use masc_keeper_delegate_status only to read the operation's state before then.|}, {|{"additionalProperties":false,"properties":{"prompt":{"type":"string"},"target":{"additionalProperties":false,"properties":{"kind":{"enum":["keeper"],"type":"string"},"name":{"type":"string"}},"required":["kind","name"],"type":"object"}},"required":["target","prompt"],"type":"object"}|}
    ; {|masc_keeper_delegate_status|}, {|Read one Keeper chat operation by exact target and operation_id. A Keeper that submitted the operation does not need this to receive the answer: that arrives on its own queue when the turn ends. Use this to see where an operation stands before then.|}, {|{"additionalProperties":false,"properties":{"operation_id":{"type":"string"},"target":{"additionalProperties":false,"properties":{"kind":{"enum":["keeper"],"type":"string"},"name":{"type":"string"}},"required":["kind","name"],"type":"object"}},"required":["target","operation_id"],"type":"object"}|}
    ; {|masc_keeper_delegate_cancel|}, {|Cancel one queued Keeper chat operation by exact target and operation_id.|}, {|{"additionalProperties":false,"properties":{"operation_id":{"type":"string"},"target":{"additionalProperties":false,"properties":{"kind":{"enum":["keeper"],"type":"string"},"name":{"type":"string"}},"required":["kind","name"],"type":"object"}},"required":["target","operation_id"],"type":"object"}|}
    ; {|masc_keeper_delegate_list|}, {|List queued Keeper chat operations owned by the caller for one exact Keeper target.|}, {|{"additionalProperties":false,"properties":{"target":{"additionalProperties":false,"properties":{"kind":{"enum":["keeper"],"type":"string"},"name":{"type":"string"}},"required":["kind","name"],"type":"object"}},"required":["target"],"type":"object"}|}
    ; {|masc_keeper_down|}, {|Submit a durable, non-blocking Keeper shutdown. Returns an operation_id immediately after admission is fenced and the ownership snapshot is persisted. Repeating the call returns the existing operation state.|}, {|{"additionalProperties":false,"properties":{"name":{"description":"Keeper handle","type":"string"},"remove_meta":{"description":"Delete .masc/keepers/<name>.json (default: false). Set true only for permanent removal.","type":"boolean"},"remove_session":{"description":"Delete .masc/traces/<trace_id>/ directory (default: false).","type":"boolean"}},"required":["name"],"type":"object"}|}
    ; {|masc_keeper_list|}, {|List known keepers from persisted keeper metadata. The response carries total (keepers known before limit), limit (the value applied) and truncated, so a short answer is distinguishable from a complete one.|}, {|{"additionalProperties":false,"properties":{"detailed":{"description":"Return keeper summaries (model/context/handoff) instead of names only.","type":"boolean"},"limit":{"description":"Max keepers to return (default: 50). Names are sorted and cut from the end, so a low limit hides whatever sorts last; check truncated in the response.","type":"integer"}},"type":"object"}|}
    ; {|masc_keeper_reset|}, {|Clear a keeper's lifecycle latch: drops the pause bit and the latched reason in one durable write. This is the operator recovery path for a keeper the generic resume transform refuses to unpause — Keeper_meta_contract.mark_resumed deliberately leaves Transcript_corruption_reset_required unchanged, so resume alone cannot free it. Does not touch usage counters, token stats, configuration, goals, or Keeper instructions.|}, {|{"additionalProperties":false,"properties":{"name":{"description":"Keeper handle to reset","type":"string"}},"required":["name"],"type":"object"}|}
    ; {|masc_keeper_msg|}, {|Send a direct message to a keeper. Submits the message as an async chat operation and returns operation_id immediately; poll masc_keeper_delegate_status with target {kind: "keeper", name} and this operation_id to observe the turn settle.|}, {|{"additionalProperties":false,"properties":{"message":{"description":"Message text to send to the keeper","type":"string"},"name":{"description":"Keeper handle to message","type":"string"}},"required":["name","message"],"type":"object"}|}
    ; {|masc_keeper_clear|}, {|Last-resort context clear for a keeper. Wipes user/assistant/tool messages from the checkpoint; keeps the system prompt by default (preserve_system_prompt=true). Set preserve_system_prompt=false to drop the system prompt too. Dispatches Operator_clear_requested to the keeper FSM, which resets context_overflow. Use only when the conversation must be reset and the keeper cannot recover otherwise. Requires a reason for the audit trail.|}, {|{"additionalProperties":false,"properties":{"name":{"description":"Keeper handle","type":"string"},"preserve_system_prompt":{"description":"Keep the system prompt in the cleared context. Defaults to true.","type":"boolean"},"reason":{"description":"Required. Operator explanation for why the context is being cleared (audit trail).","type":"string"}},"required":["name","reason"],"type":"object"}|}
    ];;

let published = Masc.Keeper_schema.schemas

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Keeper_schema.schemas")
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
    "Keeper_schema.schemas in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;


(* The one owner derivation in this file that nothing was checking.

   The sibling two the header names are pinned elsewhere —
   [Keeper_sandbox_control_contract.stop_scope_strings] in
   [test_enum_mirror_sync] and [test_keeper_tool_descriptor_registry_integrity],
   and the network-mode enum in the latter. masc_keeper_status had no such
   pin, so the TOML and [Keeper_status_options_defaults] agreed only by
   nobody having changed one of them. #32763 changed max_tail_bytes from a
   shared constant to its own literal; the value came out the same, and
   nothing here would have said otherwise if it had not. *)
let declared_int schema_name ~field ~key =
  match (find schema_name).input_schema with
  | `Assoc top ->
    (match List.assoc_opt "properties" top with
     | Some (`Assoc properties) ->
       (match List.assoc_opt field properties with
        | Some (`Assoc declaration) ->
          (match List.assoc_opt key declaration with
           | Some (`Int value) -> Some value
           | _ -> None)
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let test_status_bounds_match_their_owner () =
  let module D = Masc.Keeper_status_options_defaults in
  List.iter
    (fun (field, key, owned) ->
       check
         (option int)
         (Printf.sprintf "masc_keeper_status %s %s" field key)
         (Some owned)
         (declared_int "masc_keeper_status" ~field ~key))
    [ "tail_turns", "minimum", D.min_tail_turns
    ; "tail_turns", "maximum", D.max_tail_turns
    ; "tail_messages", "minimum", D.min_tail_messages
    ; "tail_messages", "maximum", D.max_tail_messages
    ; "tail_bytes", "minimum", D.min_tail_bytes
    ; "tail_bytes", "maximum", D.max_tail_bytes
    ]
;;

let () =
  run
    "keeper_schema_toml_parity"
    [ ( "byte_identity"
      , [ test_case "descriptions" `Quick test_descriptions_are_byte_identical
        ; test_case
            "input schemas, keys sorted"
            `Quick
            test_input_schemas_match_with_keys_sorted
        ; test_case "published order" `Quick test_the_published_order_is_unchanged
        ] )
    ; ( "owner_derivation"
      , [ test_case
            "masc_keeper_status bounds match their owner"
            `Quick
            test_status_bounds_match_their_owner
        ] )
    ]
;;
