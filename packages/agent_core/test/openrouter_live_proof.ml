(* Live proof that an OpenRouter row reaches the wire and comes back whole.

   Not wired into any test alias: it needs OPENROUTER_API_KEY and spends real
   money, the same shape as test_local_llm needing a llama-server. Run it after
   changing the OpenRouter rows or the reasoning streaming axis:

     OPENROUTER_LIVE=1 dune exec \
       packages/agent_core/test/openrouter_live_proof.exe

   What it settles that a unit test cannot: the SSE parser tests feed a
   hand-pasted delta, so they prove the parser reads the shape they were given.
   This drives the real catalog row through the real dialect to the real
   gateway, so it also proves the row resolves, the effort is encodable, and
   the encrypted reasoning item survives the streaming path. gpt-5.5 is the
   case that matters: it streams delta.reasoning = null with the item only in
   delta.reasoning_details. *)

module Provider_config = Llm_provider.Provider_config
module Model_catalog = Llm_provider.Model_catalog

let model_id = "openai/gpt-5.5"

let config api_key =
  { (Provider_config.make
       ~kind:Provider_config.OpenAI_compat
       ~provider_id:"openrouter"
       ~model_id
       ~base_url:"https://openrouter.ai/api/v1"
       ~api_key
       ~request_path:"/chat/completions"
       ~headers:
         [ "Content-Type", "application/json"
         ; "HTTP-Referer", "https://github.com/jeong-sik/masc"
         ; "X-Title", "MASC"
         ]
       ())
    with
    Provider_config.enable_thinking = Some true
  ; reasoning_effort = Some Llm_provider.Reasoning_effort.High
  ; max_tokens = Some 600
  }
;;

let classify_blocks blocks =
  List.fold_left
    (fun (text, thinking, details) block ->
       match (block : Agent_core.Types.content_block) with
       | Agent_core.Types.Text s -> text ^ s, thinking, details
       | Agent_core.Types.Thinking { content; _ } -> text, thinking ^ content, details
       | Agent_core.Types.ReasoningDetails { details = d; _ } ->
         text, thinking, details @ d
       | _ -> text, thinking, details)
    ("", "", [])
    blocks
;;

let detail_type (d : Agent_core.Types.reasoning_detail) =
  match Yojson.Safe.Util.member "type" d.raw with
  | `String s -> s
  | _ -> "<untyped>"
;;

let () =
  if Sys.getenv_opt "OPENROUTER_LIVE" <> Some "1"
  then (
    print_endline "skipped: set OPENROUTER_LIVE=1 to run this live proof";
    exit 0);
  let api_key =
    match Sys.getenv_opt "OPENROUTER_API_KEY" with
    | Some key when String.trim key <> "" -> key
    | Some _ | None ->
      prerr_endline "OPENROUTER_API_KEY is unset";
      exit 1
  in
  (match Model_catalog.load_default () with
   | Ok catalog -> Model_catalog.set_global catalog
   | Error detail ->
     Printf.eprintf "embedded catalog unavailable: %s\n" detail;
     exit 1);
  (match Provider_config.capabilities_for_config_model (config api_key) with
   | None ->
     Printf.eprintf "no capabilities resolved for %s\n" model_id;
     exit 1
   | Some caps ->
     Printf.printf
       "resolved streaming dialect: %s\n%!"
       (match
          (Llm_provider.Reasoning_dialect.of_capabilities caps)
            .Llm_provider.Reasoning_dialect.streaming
        with
        | Llm_provider.Reasoning_dialect.Delta_field_and_details f ->
          "delta_field_and_details:" ^ f
        | Llm_provider.Reasoning_dialect.Delta_field f -> "delta_field:" ^ f
        | Llm_provider.Reasoning_dialect.No_streaming_reasoning -> "none"
        | Llm_provider.Reasoning_dialect.Template_parser -> "template_parser"));
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let deltas = ref 0 in
  match
    Llm_provider.Complete.complete_stream
      ~sw
      ~net:(Eio.Stdenv.net env)
      ~clock:(Eio.Stdenv.clock env)
      ~body_timeout_s:180.0
      ~config:(config api_key)
      ~messages:
        [ Agent_core.Types.user_msg
            "Work out 4177 * 3391 step by step, then state the product."
        ]
      ~on_event:(fun _ -> incr deltas)
      ()
  with
  | Error e ->
    let described =
      match (e : Llm_provider.Http_client.http_error) with
      | Llm_provider.Http_client.HttpError { code; body; _ } ->
        Printf.sprintf "HTTP %d: %s" code body
      | Llm_provider.Http_client.NetworkError { message; _ } -> "network: " ^ message
      | Llm_provider.Http_client.TimeoutError { message; _ } -> "timeout: " ^ message
      | Llm_provider.Http_client.AcceptRejected { reason } -> "rejected: " ^ reason
      | _ -> "unclassified transport failure"
    in
    Printf.eprintf "stream failed: %s\n" described;
    exit 1
  | Ok response ->
    let text, thinking, details = classify_blocks response.content in
    Printf.printf "sse events: %d\n" !deltas;
    Printf.printf "reply: %s\n" (String.trim text);
    Printf.printf "readable thinking chars: %d\n" (String.length thinking);
    Printf.printf "reasoning details: %d\n" (List.length details);
    let by_type =
      List.fold_left
        (fun acc d ->
           let t = detail_type d in
           match List.assoc_opt t acc with
           | Some n -> (t, n + 1) :: List.remove_assoc t acc
           | None -> (t, 1) :: acc)
        []
        details
    in
    List.iter (fun (t, n) -> Printf.printf "  %s x%d\n" t n) (List.sort compare by_type);
    let encrypted =
      List.exists (fun d -> detail_type d = "reasoning.encrypted") details
    in
    if not encrypted && details <> []
    then
      (* Readable summaries alone are not the thing at risk: the summary rides
         delta.reasoning too, so a plain delta: row would still have caught it.
         The encrypted item is the half that only reaches us through the
         details array. *)
      prerr_endline
        "WARN: details arrived but none were encrypted; the run proved less than intended";
    if details = []
    then (
      prerr_endline
        "FAIL: the stream carried no reasoning_details; the encrypted item was dropped";
      exit 1);
    print_endline "PASS: the encrypted reasoning item survived the streaming path"
;;
