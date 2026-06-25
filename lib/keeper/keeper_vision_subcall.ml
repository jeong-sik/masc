(** See {!Keeper_vision_subcall} (.mli) for the contract and design trail. *)

type error =
  | Missing_artifact of string
  | Subcall_failed of string
  | Timed_out of float
  | Extraction of Multimodal.Vision_analyze.extraction_error
  | No_vision_runtime

let string_of_error = function
  | Missing_artifact msg -> "missing_artifact: " ^ msg
  | Subcall_failed msg -> "subcall_failed: " ^ msg
  | Timed_out s -> Printf.sprintf "timeout: vision sub-call exceeded %gs" s
  | Extraction e -> Multimodal.Vision_analyze.string_of_error e
  | No_vision_runtime -> "no_vision_runtime"
;;

type complete_fn =
  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?body_timeout_s:float
  -> config:Llm_provider.Provider_config.t
  -> messages:Agent_sdk.Types.message list
  -> unit
  -> (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

let default_complete : complete_fn =
  fun ~sw ~net ?clock ?body_timeout_s ~config ~messages () ->
  Llm_provider.Complete.complete ~sw ~net ?clock ?body_timeout_s ~config ~messages ()
;;

let render_http_error (err : Llm_provider.Http_client.http_error) =
  (* SSOT renderer the librarian uses for provider failures
     (Keeper_librarian_runtime:471, Tool_local_runtime_verify:80). *)
  Provider_http_error.to_message err
;;

let run
    ?(complete = default_complete)
    ~sw
    ~net
    ~clock
    ~(provider_config : Llm_provider.Provider_config.t)
    ~timeout_sec
    (req : Multimodal.Vision_analyze.request)
  : (string, error) result
  =
  let messages =
    [ Agent_sdk.Types.make_message
        ~role:Agent_sdk.Types.User
        [ Agent_sdk.Types.Text req.query
        ; Agent_sdk.Types.image_block
            ~media_type:req.image_media_type
            ~data:req.image_bytes
            ()
        ]
    ]
  in
  (* Hard P0 bound: cancel the whole sub-call (connect/read/TLS are all under
     Eio cancellation) at [timeout_sec] on the turn's [clock]. [body_timeout_s]
     is forwarded for provider-side attribution; the outer guard is the
     authoritative bound. Only [Eio.Time.Timeout] is caught — [Eio.Cancel.Cancelled]
     (turn cancelled) propagates so the turn unwinds normally. Mirrors
     [Keeper_librarian_runtime.with_timeout]. *)
  let outcome =
    try
      Some
        (Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
           complete
             ~sw
             ~net
             ~clock
             ~body_timeout_s:timeout_sec
             ~config:provider_config
             ~messages
             ()))
    with
    | Eio.Time.Timeout -> None
  in
  match outcome with
  | None -> Error (Timed_out timeout_sec)
  | Some (Error http_err) -> Error (Subcall_failed (render_http_error http_err))
  | Some (Ok resp) ->
    let content = Agent_sdk_response.text_of_response resp in
    let done_reason =
      Multimodal.Vision_analyze.done_reason_of_string (Agent_sdk_response.stop_reason_string resp)
    in
    (match Multimodal.Vision_analyze.classify ~done_reason ~content with
     | Ok text -> Ok text
     | Error e -> Error (Extraction e))
;;
