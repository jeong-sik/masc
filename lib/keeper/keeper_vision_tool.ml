module Va = Multimodal.Vision_analyze
module Store = Multimodal.Vision_artifact_store

type complete_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

(* Mirrors Keeper_librarian_runtime.default_complete / with_timeout (neither is
   exposed). Replicated rather than shared: two tiny consumers do not yet justify
   a shared keeper_provider_subcall module (repetition over premature
   abstraction); extract one if a third sub-call appears. *)
let default_complete : complete_fn =
 fun ~sw ~net ?clock ~config ~messages () ->
  Llm_provider.Complete.complete ~sw ~net ?clock ~config ~messages ()

(* Only [Eio.Time.Timeout] is caught here; [Eio.Cancel.Cancelled] and other
   exceptions are intentionally propagated so caller cancellation is not
   swallowed by the tool-level timeout handler. *)
let with_timeout ?clock ~timeout_sec f =
  match clock with
  | None -> Some (f ())
  | Some clock ->
    (try Some (Eio.Time.with_timeout_exn clock timeout_sec f) with
     | Eio.Time.Timeout -> None)

(* One-shot vision read: shorter than a full keeper turn. *)
let default_timeout_sec = 120.0

(* Thinking is forced off (below), so the budget only needs room for the answer;
   keep it well above the 64-token point where the 2026-06-25 gemma4 reply
   truncated entirely into the thinking phase. *)
let vision_default_max_tokens = 1024

let truncated_of_stop_reason : Agent_sdk.Types.stop_reason -> bool = function
  | Agent_sdk.Types.MaxTokens -> true
  | Agent_sdk.Types.EndTurn
  | Agent_sdk.Types.StopToolUse
  | Agent_sdk.Types.StopSequence
  | Agent_sdk.Types.Refusal
  | Agent_sdk.Types.PauseTurn
  | Agent_sdk.Types.Compaction
  | Agent_sdk.Types.ContextWindowExceeded
  | Agent_sdk.Types.Unknown _ -> false

let provider_for_vision (provider_cfg : Llm_provider.Provider_config.t) =
  { provider_cfg with
    max_tokens =
      (match provider_cfg.max_tokens with
       | Some _ as configured -> configured
       | None -> Some vision_default_max_tokens)
  ; temperature = Some 0.0
  ; tool_choice = None
  ; disable_parallel_tool_use = true
  ; response_format = Agent_sdk.Types.Off
  ; output_schema = None
  ; enable_thinking = Some false
  ; preserve_thinking = Some false
  ; thinking_budget = None
  ; clear_thinking = Some true
  }

let message_of_request (req : Va.request) : Agent_sdk.Types.message =
  Agent_sdk.Types.make_message
    ~role:Agent_sdk.Types.User
    [ Agent_sdk.Types.text_block req.Va.query
    ; Agent_sdk.Types.image_block
        ~source_type:"base64"
        ~media_type:req.Va.image_media_type
        ~data:(Base64.encode_string req.Va.image_bytes)
        ()
    ]

let first_vision_runtime_id () : (string, string) result =
  match Runtime_agent.first_media_capable_runtime ~modality:"image" with
  | Some id -> Ok id
  | None -> Error "no image-capable runtime configured"

(* Per-keeper content-addressed store dir. Phase 2 ingestion (§2.3) will write
   incoming images here under the same path. *)
let vision_store_dir ~keeper_name =
  Filename.concat (Config_dir_resolver.keepers_dir ()) (keeper_name ^ ".vision")

let store_artifact ~dir bytes =
  Eio_guard.run_in_systhread (fun () -> Store.store ~dir bytes)

let load_artifact ~dir handle =
  Eio_guard.run_in_systhread (fun () -> Store.load ~dir handle)

let ok_json text =
  Yojson.Safe.to_string (`Assoc [ "ok", `Bool true; "text", `String text ])

(* Default to Runtime_failure: an unclassified error is treated as an internal
   keeper-health fault, not a caller validation or workflow business rule. *)
let err_json ?detail ?(failure_class = Tool_result.Runtime_failure) code =
  let fields =
    [ "ok", `Bool false
    ; "error", `String code
    ; ( "failure_class"
      , `String (Tool_result.tool_failure_class_to_string failure_class) )
    ]
  in
  let fields =
    match detail with
    | Some d -> fields @ [ "detail", `String d ]
    | None -> fields
  in
  Yojson.Safe.to_string (`Assoc fields)

let failure_class_of_http_error err =
  if Runtime_attempt_fsm.should_try_next err
  then Tool_result.Transient_error
  else Tool_result.Policy_rejection
;;

let string_member key json =
  match Yojson.Safe.Util.member key json with
  | `String s -> Some s
  | _ -> None

(* Magic-byte media-type sniff. Phase 1 has no ingestion metadata, so sniff the
   stored bytes; default conservatively to PNG (the common keeper screenshot
   format). *)
let sniff_media_type bytes =
  let starts prefix =
    let lp = String.length prefix in
    String.length bytes >= lp && String.equal (String.sub bytes 0 lp) prefix
  in
  if starts "\x89PNG" then "image/png"
  else if starts "\xff\xd8\xff" then "image/jpeg"
  else if starts "GIF8" then "image/gif"
  else if
    String.length bytes >= 12
    && String.equal (String.sub bytes 0 4) "RIFF"
    && String.equal (String.sub bytes 8 4) "WEBP"
  then "image/webp"
  else "image/png"

let normalize_media_type value =
  String.trim value |> String.lowercase_ascii

let supported_image_media_types =
  [ "image/png"; "image/jpeg"; "image/gif"; "image/webp" ]

let supported_image_media_type media_type =
  List.mem media_type supported_image_media_types

let supported_image_media_types_csv =
  String.concat ", " supported_image_media_types

let media_type_for_request ~bytes args =
  match string_member "media_type" args with
  | Some raw when String.trim raw <> "" ->
    let media_type = normalize_media_type raw in
    if supported_image_media_type media_type then Ok media_type
    else
      Error
        (Printf.sprintf
           "unsupported image media_type %S; expected one of %s"
           raw
           supported_image_media_types_csv)
  | _ -> Ok (sniff_media_type bytes)

(* Typed outcome of the one-shot vision sub-call core, shared by the tool
   handler [handle] (renders it to JSON) and eager ingestion eviction
   ([Keeper_vision_ingest], renders it to a placeholder). One SSOT for runtime
   resolution + the bounded provider call + the §2.2 empty/truncated
   classification — eager and lazy differ only in WHEN they call this. *)
type vision_outcome =
  | Vo_ok of string
  | Vo_invalid_request of string
  | Vo_no_runtime of string
  | Vo_timeout
  | Vo_provider of
      { failure_class : Tool_result.tool_failure_class
      ; detail : string
      }
  | Vo_empty
  | Vo_truncated

(* Resolve the first image-capable runtime, send one {query + image} message
   under [with_timeout], classify the reply. [clock = None] runs unbounded only
   on the no-Eio path (tests); prod threads the turn's clock. *)
let run_vision_inner
    ?(complete = default_complete)
    ?(timeout_sec = default_timeout_sec)
    ~sw
    ?clock
    ~net
    ~query
    ~media_type
    ~bytes
    () : vision_outcome =
  match Va.make_request ~query ~image_media_type:media_type ~image_bytes:bytes with
  | Error msg -> Vo_invalid_request msg
  | Ok req ->
    (match first_vision_runtime_id () with
     | Error msg -> Vo_no_runtime msg
     | Ok runtime_id ->
       (match Runtime.get_runtime_by_id runtime_id with
        | None -> Vo_no_runtime (Printf.sprintf "runtime %S not found" runtime_id)
        | Some rt ->
          let config = provider_for_vision rt.Runtime.provider_config in
          let messages = [ message_of_request req ] in
          (match
             with_timeout ?clock ~timeout_sec (fun () ->
               complete ~sw ~net ?clock ~config ~messages ())
           with
           | None -> Vo_timeout
           | Some (Error err) ->
             Vo_provider
               { failure_class = failure_class_of_http_error err
               ; detail = Provider_http_error.to_message err
               }
           | Some (Ok (response : Agent_sdk.Types.api_response)) ->
             let text = Agent_sdk_response.text_of_response response in
             let truncated = truncated_of_stop_reason response.stop_reason in
             (match Va.classify ~truncated ~content:text with
              | Ok t -> Vo_ok t
              | Error Va.Empty_extraction -> Vo_empty
             | Error Va.Truncated_extraction -> Vo_truncated))))
;;

let run_vision ?complete ?timeout_sec ~sw ?clock ~net ~query ~media_type ~bytes () =
  try run_vision_inner ?complete ?timeout_sec ~sw ?clock ~net ~query ~media_type ~bytes ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Vo_provider
      { failure_class = Tool_result.Runtime_failure
      ; detail = "vision sub-call raised: " ^ Printexc.to_string exn
      }
;;

let handle
    ?(complete = default_complete)
    ?(timeout_sec = default_timeout_sec)
    ?sw
    ?clock
    ?net
    ~(meta : Keeper_meta_contract.keeper_meta)
    ~args
    () =
  match string_member "artifact" args, string_member "query" args with
  | None, _ | _, None ->
    err_json
      ~failure_class:Tool_result.Policy_rejection
      ~detail:"requires string fields: artifact, query"
      "invalid_args"
  | Some handle_str, Some query ->
    (match sw, net with
     | None, _ | _, None ->
       err_json
         ~failure_class:Tool_result.Runtime_failure
         "eio_context_unavailable"
     | Some sw, Some net ->
       let dir = vision_store_dir ~keeper_name:meta.name in
       (match load_artifact ~dir (Store.of_string handle_str) with
        | Error msg ->
          err_json
            ~failure_class:Tool_result.Runtime_failure
            ~detail:msg
            "artifact_load_failed"
        | Ok bytes ->
          (match media_type_for_request ~bytes args with
           | Error msg ->
             err_json
               ~failure_class:Tool_result.Policy_rejection
               ~detail:msg
               "invalid_media_type"
           | Ok media_type ->
             (match
                run_vision ~complete ~timeout_sec ~sw ?clock ~net ~query
                  ~media_type ~bytes ()
              with
              | Vo_ok t -> ok_json t
              | Vo_invalid_request msg ->
                err_json
                  ~failure_class:Tool_result.Policy_rejection
                  ~detail:msg
                  "invalid_request"
              | Vo_no_runtime msg ->
                err_json
                  ~failure_class:Tool_result.Runtime_failure
                  ~detail:msg
                  "no_capable_runtime"
              | Vo_timeout ->
                err_json ~failure_class:Tool_result.Transient_error "timeout"
              | Vo_provider { failure_class; detail } ->
                err_json ~failure_class ~detail "provider_error"
              | Vo_empty ->
                err_json
                  ~failure_class:Tool_result.Workflow_rejection
                  "empty_extraction"
              | Vo_truncated ->
                err_json
                  ~failure_class:Tool_result.Runtime_failure
                  "truncated_extraction"))))
