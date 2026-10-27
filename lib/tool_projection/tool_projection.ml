(** Model-facing projection of typed tool results to AGENT_CORE.

    [Tool_projection] holds the result-projection half of the former
    [Tool_bridge]: typed [Tool_result.result] values become
    [Agent_core.Types.tool_result] under a descriptor's
    [Tool_output.model_projection], with artifact-manifest persistence and the
    externalization budget. It lives in its own leaf library so mid-level
    libraries (masc_task_handlers) can project results without depending on
    the root masc library, which depends on them. [Tool_bridge] re-exports
    this surface unchanged. *)

let default_externalize_threshold_bytes = Common.max_tool_result_wire_bytes

let semantic_answer_fingerprint reader (result : Tool_result.result) =
  match reader (Tool_result.message result) with
  | None -> None
  | Some answer ->
    Some
      (Agent_core_sha256.(digest_string (answer |> Yojson.Safe.sort |> Yojson.Safe.to_string) |> to_hex))

type projection_error_kind =
  | Artifact_storage_failure
  | Inline_budget_exceeded

type externalization_error =
  { kind : projection_error_kind
  ; message : string
  }

let artifact_manifest_metadata_key = "masc.artifact_manifest"
let artifact_projection_metadata_key = "masc.artifact_projection"

let metadata_with_artifact_manifest metadata reference projection =
  let manifest = Tool_output.normalized_artifact_ref_to_json reference in
  let owned_fields =
    [ artifact_manifest_metadata_key, manifest
    ; artifact_projection_metadata_key, Tool_output.artifact_projection_to_json projection ]
  in
  match metadata with
  | None -> `Assoc owned_fields
  | Some (`Assoc fields) ->
    `Assoc
      (owned_fields
       @ (fields |> List.remove_assoc artifact_manifest_metadata_key
                 |> List.remove_assoc artifact_projection_metadata_key))
  | Some payload ->
    `Assoc
      (owned_fields @ [ "masc.payload", payload ])
;;

let artifact_manifest_from_metadata metadata =
  let rec decode = function
    | `Assoc fields ->
      (match List.assoc_opt artifact_manifest_metadata_key fields with
     | Some json ->
       (match Tool_output.normalized_artifact_ref_of_json json with
        | Tool_output.Decoded_normalized_artifact_ref reference
          when String.equal reference.mime Tool_output.artifact_manifest_mime ->
          let projection =
            match List.assoc_opt artifact_projection_metadata_key fields with
            | None -> Ok Tool_output.Reference_only
            | Some json -> Tool_output.artifact_projection_of_json json
          in
          Result.map (fun projection -> reference, projection) projection
        | Tool_output.Decoded_normalized_artifact_ref _ ->
          Error "artifact manifest metadata has the wrong media type"
        | Tool_output.Not_normalized_artifact_ref ->
          Error "artifact manifest metadata is not a normalized reference"
        | Tool_output.Invalid_normalized_artifact_ref { detail } -> Error detail)
     | None ->
       (match List.assoc_opt "producer" fields with
        | Some producer -> decode producer
        | None ->
          (match List.assoc_opt "masc.payload" fields with
           | Some payload -> decode payload
           | None -> Error "typed artifact result is missing its durable manifest")))
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error "typed artifact result is missing its durable manifest"
  in
  match metadata with
  | Some metadata -> decode metadata
  | None -> Error "typed artifact result is missing its durable manifest"
;;

let artifact_manifest_reference result =
  artifact_manifest_from_metadata (Tool_result.metadata result)
;;

let artifact_result_envelope ~reference ~structured_content ?content () =
  Yojson.Safe.to_string
    (`Assoc
      ([ "structured_content", structured_content
       ; "artifact_manifest", Tool_output.normalized_artifact_ref_to_json reference ]
       @ Option.to_list (Option.map (fun value -> "content", `String value) content)))
;;

let attach_artifact_manifest ?(projection = Tool_output.Reference_only) ~base_path (result : Tool_result.result) =
  match
    Tool_output.normalized_artifact_refs_in_json_strict
      (Tool_result.data result)
  with
  | Error message -> Error { kind = Artifact_storage_failure; message }
  | Ok [] -> Ok result
  | Ok (_ :: _) ->
    (try
       let manifest =
         Tool_output.artifact_manifest_to_json
           ~content:(Tool_result.message result)
           ~structured_content:(Tool_result.data result)
         |> Yojson.Safe.to_string
       in
       let reference =
         Tool_blob_store.put_durable
           (Tool_blob_store.create ~base_path)
           ~bytes:manifest
           ~mime:Tool_output.artifact_manifest_mime
         |> fun reference -> Tool_output.with_preview reference ""
       in
       Ok
         (Tool_result.with_metadata
            (metadata_with_artifact_manifest (Tool_result.metadata result) reference projection)
            result)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       let message = Printexc.to_string exn in
       Log.Misc.error
         "tool_bridge: result manifest persistence failed: %s"
         message;
       Error { kind = Artifact_storage_failure; message })
;;

let resolve_blob_store ?base_path () =
  match base_path with
  | None -> None
  | Some base_path -> Some (Tool_blob_store.create ~base_path)

(** Externalize [msg] when it exceeds the threshold and a blob store is
    available; otherwise pass through unchanged. A configured store that
    cannot persist the bytes returns a typed error: putting the oversized
    payload back on the provider wire would defeat this boundary. *)
let maybe_externalize ?base_path ?stored_preview ?answer_fingerprint ?(mime = "text/plain")
      ?(threshold_bytes = default_externalize_threshold_bytes) (msg : string)
  : (string, externalization_error) result
  =
  if String.length msg <= threshold_bytes then Ok msg
  else
    match resolve_blob_store ?base_path () with
    | None -> Ok msg
    | Some store ->
        (try
           let reference =
             Tool_blob_store.put_durable store ~bytes:msg ~mime
             |> fun reference ->
             (match Tool_output.with_answer_fingerprint reference answer_fingerprint with
              | Ok reference -> reference
              | Error error -> invalid_arg (Tool_output.make_error_to_string error))
           in
           Ok
             (Tool_output.encode_for_agent_core
                (Tool_output.Stored
                   (Option.fold ~none:reference
                      ~some:(Tool_output.with_preview reference) stored_preview)))
         with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          let message = Printexc.to_string exn in
          Log.Misc.error "tool_bridge: blob externalization failed: %s" message;
          Error { kind = Artifact_storage_failure; message })

(** {1 Result Conversion} *)

let make_tool_error ?(recoverable = false) ?error_class message
  : Agent_core.Types.tool_result =
  Error { Agent_core.Types.message; recoverable; error_class }

let project_content ?base_path ?stored_preview ?answer_fingerprint ~model_projection message =
  match model_projection with
  | Tool_output.Store_above { threshold_bytes } ->
    maybe_externalize ?base_path ?stored_preview ?answer_fingerprint ~threshold_bytes message
  | Tool_output.Inline_up_to { maximum_bytes } ->
    if String.length message <= maximum_bytes
    then Ok message
    else
      Error
        { kind = Inline_budget_exceeded
        ; message =
            Printf.sprintf
              "inline tool output exceeds descriptor budget (%d > %d bytes)"
              (String.length message)
              maximum_bytes
        }
;;

let one_line text = String.map (function '\n' | '\r' -> ' ' | c -> c) text

(* The typed error carries the cause in [message]; the model-facing sentence
   must not drop it. For a storage failure the message is a raw exception, so
   the boundary phrase names where it happened and the detail follows it. For
   an inline-budget refusal the message is already a full sentence naming the
   limit and the byte counts, so it is used as-is rather than prefixed with a
   phrase that repeats it. This mirrors [Keeper_terminal_effect_detail], which
   already keeps the detail on the terminal-effect path; without it the model
   and the operator see only a bare label they cannot act on. *)
let externalization_tool_error ~recoverable error =
  let detail = String.trim (one_line error.message) in
  let sentence phrase =
    if String.equal detail "" then phrase
    else Printf.sprintf "%s: %s" phrase detail
  in
  match error.kind with
  | Artifact_storage_failure ->
    make_tool_error
      ~recoverable
      ~error_class:
        (if recoverable
         then Agent_core.Types.Transient
         else Agent_core.Types.Unknown)
      (sentence "tool output artifact storage failed")
  | Inline_budget_exceeded ->
    make_tool_error
      ~recoverable:false
      ~error_class:Agent_core.Types.Deterministic
      (if String.equal detail "" then "tool output exceeds descriptor budget" else detail)
;;

(* The class is typed at the producer and AGENT_CORE folds it into
   [error_class], which no provider wire serializer emits. So the only way the
   class reaches the model is as text on the failure content, and the only
   text the model needs is what to do next. The sentences are prompt assets
   ([config/prompts/tool_failure.<class>.md]), not OCaml literals; the match
   is exhaustive so a new class cannot ship without its sentence key. A key
   with no file and no override is reported and the line carries the class
   alone -- the model still learns the class, and the operator learns the
   deploy is missing a prompt asset. *)
let failure_next_move (class_ : Tool_result.tool_failure_class) : string option =
  let key =
    match class_ with
    | Tool_result.Dependency_unavailable -> Prompt_names.tool_failure_dependency_unavailable
    | Tool_result.Policy_rejection -> Prompt_names.tool_failure_policy_rejection
    | Tool_result.Runtime_failure -> Prompt_names.tool_failure_runtime_failure
    | Tool_result.Workflow_rejection -> Prompt_names.tool_failure_workflow_rejection
    | Tool_result.Operator_cancelled -> Prompt_names.tool_failure_operator_cancelled
  in
  match Prompt_registry.resolve_prompt key with
  | { Prompt_registry.file_exists = false; has_override = false; _ } ->
    Log.Misc.error
      "tool_bridge: prompt %s has no file and no override; the model sees only failure_class=%s"
      key
      (Tool_result.tool_failure_class_to_string class_);
    None
  | resolution -> Some (String.trim resolution.effective)
;;

let agent_core_error_class_of_tool_failure_class = function
  | Tool_result.Policy_rejection
  | Tool_result.Workflow_rejection
  (* Operator interrupt: final for the model — it must not re-attempt what
     an operator explicitly stopped (#28810). *)
  | Tool_result.Operator_cancelled ->
    Agent_core.Types.Deterministic
  | Tool_result.Dependency_unavailable -> Agent_core.Types.Transient
  | Tool_result.Runtime_failure -> Agent_core.Types.Unknown
;;

let project_result
      ?base_path
      ?stored_preview
      ?answer_fingerprint
      ?inline_message
      ?inline_diagnostic
      ?on_externalization_error
      ~model_projection
      ~structured_content
      ~metadata
      message
      on_content
  : Agent_core.Types.tool_result
  =
  let project () =
    project_content ?base_path ?stored_preview ?answer_fingerprint ~model_projection message
  in
  let projected =
    match Tool_output.normalized_artifact_refs_in_json structured_content with
    | [] -> project ()
    | _ :: _ when Option.is_none base_path -> project ()
    | _ :: _ ->
      (match Tool_output.normalized_artifact_refs_in_json_strict structured_content with
       | Error message -> Error { kind = Artifact_storage_failure; message }
       | Ok [] -> Error { kind = Artifact_storage_failure; message = "typed artifact result lost its normalized references" }
       | Ok (_ :: _) ->
         (match artifact_manifest_from_metadata metadata with
          | Ok (reference, artifact_projection) ->
            let reference =
              Option.fold ~none:reference
                ~some:(Tool_output.with_preview reference) stored_preview
            in
            (* The declared fingerprint covers the answer inside the stored
               content; a reader verifies it by unwrapping the manifest
               (Keeper_tool_answer.verified_stored_answer), so a repeated
               call keeps one identity even while the manifest bytes —
               execution time included — differ between runs. *)
            (match Tool_output.with_answer_fingerprint reference answer_fingerprint with
             | Ok reference ->
               let marker () =
                 Tool_output.encode_for_agent_core (Tool_output.Stored reference)
               in
               (match artifact_projection with
                | Tool_output.Reference_only -> Ok (marker ())
                | Tool_output.Inline_with_reference
                | Tool_output.Inline_with_structured_diagnostic ->
                  let inline_content = match artifact_projection with
                    | Tool_output.Reference_only -> None
                    | Tool_output.Inline_with_reference -> inline_message
                    | Tool_output.Inline_with_structured_diagnostic -> inline_diagnostic
                  in
                  let envelope = artifact_result_envelope
                    ~reference ~structured_content ?content:inline_content () in
                  let ceiling = Tool_output.inline_ceiling_bytes model_projection in
                  if String.length envelope <= ceiling
                  then Ok envelope
                  else
                    let content = marker () in
                    if String.length content <= ceiling then Ok content
                    else Error
                      { kind = Inline_budget_exceeded
                      ; message = Printf.sprintf
                          "artifact reference exceeds descriptor budget (%d > %d bytes)"
                          (String.length content) ceiling })
             | Error error ->
               Error
                 { kind = Artifact_storage_failure
                 ; message = Tool_output.make_error_to_string error })
          | Error message -> Error { kind = Artifact_storage_failure; message }))
  in
  match projected with
  | Ok content -> on_content content
  | Error error ->
    Option.iter (fun observe -> observe error) on_externalization_error;
    externalization_tool_error ~recoverable:false error
;;

(* An applied effect cannot be projected again after its manifest failed.
   Bound this recovery envelope directly, using the caller's typed policy. *)
let post_effect_failure_content ~model_projection ~failure_class ~effect_disposition
    ~data ~references =
  let ceiling = max 0 (Tool_output.inline_ceiling_bytes model_projection) in
  let fields =
    [ "message", `String "The effect was applied, but result manifest storage failed. Read the recorded artifacts or current target; do not repeat the effect."
    ; "masc.tool_disposition", `String "failed"
    ; "effect_disposition", `String (Tool_result.failure_effect_disposition_to_string effect_disposition)
    ; "failure_class", `String failure_class
    ] in
  let encode fields = Yojson.Safe.to_string (`Assoc fields) in
  let full = encode (fields @ ["data", data;
    "artifact_refs", `List (List.map Tool_output.normalized_artifact_ref_to_json references)]) in
  if String.length full <= ceiling then full
  else
    let total = List.length references in
    let bounded selected count = encode (fields @
      [ "data_omitted", `Bool true
      ; "artifact_refs", `List (List.rev selected)
      ; "artifact_refs_omitted", `Int (total - count)
      ]) in
    let empty = bounded [] 0 in
    if String.length empty > ceiling then (
      (* A custom policy may not even admit the fixed envelope. The typed error
         still remains non-recoverable; never spill or create another artifact. *)
      let notice = "Effect applied; do not repeat. Read current target." in
      String.sub notice 0 (min ceiling (String.length notice)))
    else
      let selected, count = List.fold_left (fun (selected, count) reference ->
        let admit reference =
          let next = Tool_output.normalized_artifact_ref_to_json reference :: selected in
          if String.length (bounded next (count + 1)) <= ceiling
          then Some (next, count + 1) else None in
        match admit reference with
        | Some next -> next
        | None ->
          (* Preview is descriptive text, not blob identity or a domain
             descriptor. Preserve the canonical retrieval handle if it fits. *)
          (match admit (Tool_output.with_preview reference "") with
           | Some next -> next | None -> selected, count)) ([], 0) references in
      bounded selected count
;;

let to_agent_core_typed_result
      ?base_path
      ?(answer_reader = fun _ -> None)
      ?(model_projection = Tool_output.default_model_projection)
      ?on_externalization_error
      (tr : Tool_result.result)
  : Agent_core.Types.tool_result
  =
  match tr with
  | Tool_result.Completed output ->
    let answer_fingerprint = semantic_answer_fingerprint answer_reader tr in
    project_result
      ?base_path
      ?answer_fingerprint
      ?on_externalization_error
      ~model_projection
      ~structured_content:(Tool_result.data tr)
      ~metadata:(Tool_result.metadata tr)
      (Tool_result.message tr)
      (fun content ->
         Ok { Agent_core.Types.content; content_blocks = output.content_blocks; _meta = output.metadata })
  | Tool_result.Deferred output ->
    let answer_fingerprint = semantic_answer_fingerprint answer_reader tr in
    let disposition_field =
      "masc.tool_disposition", `String (Tool_result.string_of_disposition tr)
    in
    let metadata =
      match output.metadata with
      | None -> `Assoc [ disposition_field ]
      | Some metadata ->
        `Assoc [ disposition_field; "masc.payload", metadata ]
    in
    project_result
      ?base_path
      ?answer_fingerprint
      ?on_externalization_error
      ~model_projection
      ~structured_content:(Tool_result.data tr)
      ~metadata:(Tool_result.metadata tr)
      (Tool_result.message tr)
      (fun content ->
         Ok { Agent_core.Types.content; content_blocks = output.content_blocks; _meta = Some metadata })
  | Tool_result.Failed { effect_disposition; class_; message; data_source; metadata; _ } ->
    let failure_class = Tool_result.tool_failure_class_to_string class_ in
    let next_move = failure_next_move class_ in
    let inline_diagnostic =
      Yojson.Safe.to_string
        (`Assoc
           ([ "masc.tool_disposition", `String "failed"
            ; "failure_class", `String failure_class ]
            @ match next_move with None -> [] | Some value -> [ "next_move", `String value ]))
    in
    let data = Tool_result.data tr in
    (* Keep producer recovery details in model content. Data already carried
       verbatim by the message or metadata needs no second copy. *)
    let model_data =
      match data_source with
      | Tool_result.Message_as_data | Tool_result.Explicit_data `Null -> None
      | Tool_result.Explicit_data
          (`Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _)
        ->
        let carried_by_metadata =
          match metadata with
          | Some metadata -> Yojson.Safe.equal data metadata
          | None -> false
        in
        let carried_as_text =
          match data with
          | `String text -> String.equal text message
          | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> false
        in
        (* Serializing is the expensive check, so it runs only when the two
           cheap ones did not settle it (#34731 review). *)
        if
          carried_by_metadata
          || carried_as_text
          || String.equal (Yojson.Safe.to_string data) message
        then None
        else Some data
    in
    let message =
      match metadata, model_data with
      | None, None ->
        (match next_move with
         | Some next_move ->
           Printf.sprintf "%s\nfailure_class=%s — %s" message failure_class next_move
         | None -> Printf.sprintf "%s\nfailure_class=%s" message failure_class)
      | metadata, model_data ->
        Yojson.Safe.to_string
          (`Assoc
              ([ "message", `String message
               ; "masc.tool_disposition", `String "failed"
               ; "failure_class", `String failure_class
               ]
               @ (match next_move with
                  | Some next_move -> [ "next_move", `String next_move ]
                  | None -> [])
               @ (match model_data with
                  | Some data -> [ "data", data ]
                  | None -> [])
               @ (match metadata with
                  | Some metadata -> [ "masc.payload", metadata ]
                  | None -> [])))
    in
    let stored_preview =
      match next_move with
      | Some next_move ->
        Printf.sprintf "failure_class=%s — %s" failure_class next_move
      | None -> Printf.sprintf "failure_class=%s" failure_class
    in
    let references = Tool_output.normalized_artifact_refs_in_json data in
    match effect_disposition, references, artifact_manifest_from_metadata metadata with
    | Tool_result.Proven_post_effect, (_ :: _), Error _ ->
      make_tool_error ~recoverable:false
        ~error_class:(agent_core_error_class_of_tool_failure_class class_)
        (post_effect_failure_content ~model_projection ~failure_class
           ~effect_disposition ~data ~references)
    | (Tool_result.Proven_post_effect, _::_, Ok _) | (Tool_result.Proven_post_effect, [], _)
    | ((Tool_result.Proven_pre_effect | Tool_result.Effect_outcome_unknown), _, _) -> project_result
      ~stored_preview
      ~inline_message:message
      ~inline_diagnostic
      ?base_path
      ?on_externalization_error
      ~model_projection
      ~structured_content:(Tool_result.data tr)
      ~metadata:(Tool_result.metadata tr)
      message
      (fun message ->
       make_tool_error
         ~recoverable:false
         ~error_class:(agent_core_error_class_of_tool_failure_class class_)
         message)
