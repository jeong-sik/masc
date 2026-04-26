(** Tool_local_runtime_bench -- concurrency benchmark against runtime pool. *)

include Tool_local_runtime_http
module Oas_types = Oas.Types

let pctl percentile values =
  match values with
  | [] -> None
  | _ ->
    let sorted = List.sort compare values in
    let len = List.length sorted in
    let index =
      int_of_float (Float.floor (percentile *. float_of_int (max 0 (len - 1))))
    in
    List.nth_opt sorted index
;;

let error_message_of_http_error = function
  | Llm_provider.Http_client.ProviderTerminal { message; _ } -> message
  | Llm_provider.Http_client.NetworkError { message; _ } -> message
  | Llm_provider.Http_client.AcceptRejected { reason } -> reason
  | Llm_provider.Http_client.CliTransportRequired { kind } ->
    Printf.sprintf "%s provider requires a CLI transport" kind
  | Llm_provider.Http_client.ProviderTerminal
      { kind = Llm_provider.Http_client.Max_turns { turns; limit }; message } ->
    Printf.sprintf "provider terminal: max turns exceeded (%d/%d): %s" turns limit message
  | Llm_provider.Http_client.ProviderTerminal
      { kind = Llm_provider.Http_client.Other subtype; message } ->
    Printf.sprintf "provider terminal: %s: %s" subtype message
  | Llm_provider.Http_client.HttpError { code; body } ->
    (try
       let json = Yojson.Safe.from_string body in
       match Yojson.Safe.Util.member "error" json with
       | `Assoc fields ->
         (match List.assoc_opt "message" fields with
          | Some (`String msg) -> msg
          | _ -> Printf.sprintf "HTTP %d" code)
       | _ -> Printf.sprintf "HTTP %d" code
     with
     | Yojson.Json_error _ -> Printf.sprintf "HTTP %d" code)
;;

let per_runtime_breakdown_to_yojson counts =
  counts
  |> Hashtbl.to_seq_values
  |> List.of_seq
  |> List.sort (fun a b ->
    compare
      (Yojson.Safe.Util.member "runtime_id" a |> Yojson.Safe.Util.to_string)
      (Yojson.Safe.Util.member "runtime_id" b |> Yojson.Safe.Util.to_string))
;;

let update_runtime_breakdown counts ~runtime_id ~(sample : bench_sample) =
  let prev =
    match Hashtbl.find_opt counts runtime_id with
    | Some (`Assoc fields) -> fields
    | _ ->
      [ "runtime_id", `String runtime_id
      ; "success_count", `Int 0
      ; "failure_count", `Int 0
      ; "latencies", `List []
      ]
  in
  let int_field name =
    match List.assoc_opt name prev with
    | Some (`Int value) -> value
    | _ -> 0
  in
  let latencies =
    match List.assoc_opt "latencies" prev with
    | Some (`List items) -> items
    | _ -> []
  in
  let fields =
    if sample.success
    then
      [ "runtime_id", `String runtime_id
      ; "success_count", `Int (int_field "success_count" + 1)
      ; "failure_count", `Int (int_field "failure_count")
      ; "latencies", `List (`Int sample.latency_ms :: latencies)
      ]
    else
      [ "runtime_id", `String runtime_id
      ; "success_count", `Int (int_field "success_count")
      ; "failure_count", `Int (int_field "failure_count" + 1)
      ; "latencies", `List latencies
      ]
  in
  Hashtbl.replace counts runtime_id (`Assoc fields)
;;

let finalize_runtime_breakdown json =
  match json with
  | `Assoc fields ->
    let latencies =
      match List.assoc_opt "latencies" fields with
      | Some (`List items) ->
        List.filter_map
          (function
            | `Int value -> Some value
            | _ -> None)
          items
      | _ -> []
    in
    `Assoc
      [ "runtime_id", Option.value ~default:`Null (List.assoc_opt "runtime_id" fields)
      ; ( "success_count"
        , Option.value ~default:`Null (List.assoc_opt "success_count" fields) )
      ; ( "failure_count"
        , Option.value ~default:`Null (List.assoc_opt "failure_count" fields) )
      ; "p50_latency_ms", int_opt_to_json (pctl 0.50 latencies)
      ; "p95_latency_ms", int_opt_to_json (pctl 0.95 latencies)
      ; "max_latency_ms", int_opt_to_json (pctl 1.0 latencies)
      ]
  | _ -> json
;;

let default_local_model_id () =
  let _label, model_id = Cascade_runtime.default_local_model_label_and_id () in
  model_id
;;

let is_oas_managed_runtime_pool = function
  | None -> true
  | Some pool ->
    let trimmed = String.trim pool in
    trimmed = ""
    || String.equal trimmed Local_runtime_pool.default_pool_label
    || String.equal trimmed "default"
;;

let runtime_base_url_for_pool runtime_pool =
  match runtime_pool with
  | Some pool ->
    let trimmed = String.trim pool in
    if is_oas_managed_runtime_pool (Some trimmed)
    then Llm_provider.Provider_registry.next_llama_endpoint ()
    else if
      String.starts_with ~prefix:"http://" trimmed
      || String.starts_with ~prefix:"https://" trimmed
    then trimmed
    else (
      let snapshots = Local_runtime_pool.snapshots () in
      match
        List.find_opt
          (fun (runtime : Local_runtime_pool.runtime_snapshot) ->
             String.equal runtime.id trimmed)
          snapshots
      with
      | Some runtime -> runtime.base_url
      | None -> trimmed)
  | None -> Llm_provider.Provider_registry.next_llama_endpoint ()
;;

let model_label_for_pool ~model_id runtime_pool =
  match runtime_pool with
  | Some pool ->
    let trimmed = String.trim pool in
    if is_oas_managed_runtime_pool (Some trimmed)
    then Provider_adapter.make_local_label model_id
    else (
      let base_url =
        if
          String.starts_with ~prefix:"http://" trimmed
          || String.starts_with ~prefix:"https://" trimmed
        then trimmed
        else runtime_base_url_for_pool runtime_pool
      in
      Printf.sprintf "custom:%s@%s" model_id base_url)
  | None -> Provider_adapter.make_local_label model_id
;;

let ensure_runtime_reachable ?runtime_pool ~timeout_sec () =
  let base_url = runtime_base_url_for_pool runtime_pool |> String.trim in
  let health_url = base_url ^ "/health" in
  let probe_timeout = max 1 (min 2 timeout_sec) in
  match http_get_text_with_status ~timeout_sec:probe_timeout health_url with
  | Ok (Some 200, _) -> Ok ()
  | Ok (status, _) ->
    let status_text =
      match status with
      | Some code -> string_of_int code
      | None -> "no-status"
    in
    Error
      (Printf.sprintf
         "runtime unavailable: provider health check returned %s for %s"
         status_text
         health_url)
  | Error err -> Error (Printf.sprintf "runtime unavailable: %s" err)
;;

let oas_completion_at ?runtime_pool ~model_id ~prompt ~max_tokens ~timeout_sec () =
  match Masc_eio_env.get_opt () with
  | None ->
    (* MASC-OAS boundary: raw curl fallback removed.
         Bench must run inside an Eio-managed context. *)
    ( { success = false
      ; latency_ms = 0
      ; error = Some "Eio environment not available; bench requires OAS runtime context"
      }
    , "unknown" )
  | Some env ->
    let started = Time_compat.now () in
    let model_label = model_label_for_pool ~model_id runtime_pool in
    (match Cascade_config.parse_model_string ~max_tokens model_label with
     | None ->
       ( { success = false
         ; latency_ms = 0
         ; error = Some ("invalid model label: " ^ model_label)
         }
       , "unknown" )
     | Some provider_config ->
       let runtime_id =
         Local_runtime_pool.runtime_id_of_base_url provider_config.base_url
       in
       let messages : Oas_types.message list =
         [ { Oas_types.role = Oas_types.User
           ; content = [ Oas_types.Text prompt ]
           ; name = None
           ; tool_call_id = None
           ; metadata = []
           }
         ]
       in
       let run_completion () =
         Llm_provider.Complete.complete
           ~sw:env.sw
           ~net:env.net
           ~config:provider_config
           ~messages
           ()
       in
       let outcome =
         match env.clock with
         | Some clock ->
           (try
              Ok
                (Eio.Time.with_timeout_exn
                   clock
                   (float_of_int timeout_sec)
                   run_completion)
            with
            | Eio.Time.Timeout -> Error "timeout")
         | None -> Ok (run_completion ())
       in
       let latency_ms = int_of_float ((Time_compat.now () -. started) *. 1000.0) in
       let sample =
         match outcome with
         | Error message -> { success = false; latency_ms; error = Some message }
         | Ok (Ok _response) -> { success = true; latency_ms; error = None }
         | Ok (Error http_error) ->
           { success = false
           ; latency_ms
           ; error = Some (error_message_of_http_error http_error)
           }
       in
       sample, runtime_id)
;;

let run_bench
      ?model_id
      ?runtime_pool
      ~parallelism
      ~rounds
      ~prompt
      ~max_tokens
      ~timeout_sec
      ()
  =
  match ensure_runtime_reachable ?runtime_pool ~timeout_sec () with
  | Error _ as err -> err
  | Ok () ->
    let total = parallelism * rounds in
    let results = Array.make total None in
    let runtime_breakdown = Hashtbl.create 8 in
    for round_idx = 0 to rounds - 1 do
      let offset = round_idx * parallelism in
      Eio.Fiber.all
        (List.init parallelism (fun fiber_idx ->
           fun () ->
           let resolved_model_id =
             match model_id with
             | Some model when String.trim model <> "" -> model
             | _ -> default_local_model_id ()
           in
           let sample, runtime_id =
             oas_completion_at
               ?runtime_pool
               ~model_id:resolved_model_id
               ~prompt
               ~max_tokens
               ~timeout_sec
               ()
           in
           update_runtime_breakdown runtime_breakdown ~runtime_id ~sample;
           results.(offset + fiber_idx) <- Some sample))
    done;
    let samples = results |> Array.to_list |> List.filter_map (fun item -> item) in
    let success_count =
      List.fold_left
        (fun acc (sample : bench_sample) -> if sample.success then acc + 1 else acc)
        0
        samples
    in
    let failure_count = List.length samples - success_count in
    let latencies =
      samples
      |> List.filter_map (fun (sample : bench_sample) ->
        if sample.success then Some sample.latency_ms else None)
    in
    let errors =
      samples
      |> List.filter_map (fun (sample : bench_sample) -> sample.error)
      |> List.sort_uniq String.compare
    in
    Local_runtime_pool.record_measured_ceiling success_count;
    let runtime_breakdown =
      runtime_breakdown
      |> per_runtime_breakdown_to_yojson
      |> List.map finalize_runtime_breakdown
    in
    Ok
      (`Assoc
          [ "server_url", `String Env_config.Llama.server_url
          ; "source", `String "oas_complete"
          ; "model_id", string_opt_to_json model_id
          ; "runtime_pool", string_opt_to_json runtime_pool
          ; "parallelism", `Int parallelism
          ; "rounds", `Int rounds
          ; "total_requests", `Int (List.length samples)
          ; "success_count", `Int success_count
          ; "failure_count", `Int failure_count
          ; ( "success_rate"
            , `Float
                (if samples = []
                 then 0.0
                 else float_of_int success_count /. float_of_int (List.length samples)) )
          ; "p50_latency_ms", int_opt_to_json (pctl 0.50 latencies)
          ; "p95_latency_ms", int_opt_to_json (pctl 0.95 latencies)
          ; "max_latency_ms", int_opt_to_json (pctl 1.0 latencies)
          ; "configured_max_concurrent_models", `Int Inference_utils.max_concurrent_models
          ; "configured_capacity", `Int (Local_runtime_pool.configured_capacity ())
          ; "measured_ceiling", int_opt_to_json (Local_runtime_pool.measured_ceiling ())
          ; "per_runtime_breakdown", `List runtime_breakdown
          ; "errors", `List (errors |> List.map (fun message -> `String message))
          ])
;;
