module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_local_runtime_bench -- concurrency benchmark against runtime pool. *)

include Tool_local_runtime_http
module Oas_types = Agent_sdk.Types


(* http_error_message moved to Provider_http_error.to_message (SSOT,
   2026-06-24): four byte-for-output-identical copies unified. *)
let pctl percentile values =
  match values with
  | [] -> None
  | _ ->
      let sorted = List.sort compare values in
      let len = List.length sorted in
      let index =
        Stdlib.Int.of_float
          (Float.floor
             (percentile *. Stdlib.Float.of_int (max 0 (len - 1))))
      in
      List.nth_opt sorted index

let error_message_of_http_error = Provider_http_error.to_message

let per_runtime_breakdown_to_yojson counts =
  counts
  |> Hashtbl.to_seq_values
  |> List.of_seq
  |> List.sort (fun a b ->
         String.compare (Json_util.get_string a "runtime_id" |> Option.value ~default:"") (Json_util.get_string b "runtime_id" |> Option.value ~default:""))

let update_runtime_breakdown counts ~runtime_id ~(sample : bench_sample) =
  let prev =
    match Hashtbl.find_opt counts runtime_id with
    | Some (`Assoc fields) -> fields
    | _ ->
        [
          ("runtime_id", `String runtime_id);
          ("success_count", `Int 0);
          ("failure_count", `Int 0);
          ("latencies", `List []);
        ]
  in
  let int_field name =
    match List.assoc_opt name prev with Some (`Int value) -> value | _ -> 0
  in
  let latencies =
    match List.assoc_opt "latencies" prev with
    | Some (`List items) -> items
    | _ -> []
  in
  let fields =
    if sample.success then
      [
        ("runtime_id", `String runtime_id);
        ("success_count", `Int (int_field "success_count" + 1));
        ("failure_count", `Int (int_field "failure_count"));
        ("latencies", `List (`Int sample.latency_ms :: latencies));
      ]
    else
      [
        ("runtime_id", `String runtime_id);
        ("success_count", `Int (int_field "success_count"));
        ("failure_count", `Int (int_field "failure_count" + 1));
        ("latencies", `List latencies);
      ]
  in
  Hashtbl.replace counts runtime_id (`Assoc fields)

let finalize_runtime_breakdown json =
  match json with
  | `Assoc fields ->
      let latencies =
        match List.assoc_opt "latencies" fields with
        | Some (`List items) ->
            List.filter_map
              (function `Int value -> Some value | _ -> None)
              items
        | _ -> []
      in
      `Assoc
        [
          ("runtime_id", Option.value ~default:`Null (List.assoc_opt "runtime_id" fields));
          ("success_count", Option.value ~default:`Null (List.assoc_opt "success_count" fields));
          ("failure_count", Option.value ~default:`Null (List.assoc_opt "failure_count" fields));
          ("p50_latency_ms", Json_util.int_opt_to_json (pctl 0.50 latencies));
          ("p95_latency_ms", Json_util.int_opt_to_json (pctl 0.95 latencies));
          ("max_latency_ms", Json_util.int_opt_to_json (pctl 1.0 latencies));
        ]
  | _ -> json

let validate_requested_model (runtime : Runtime.t) = function
  | None -> Ok runtime
  | Some requested_model ->
      let requested_model = String.trim requested_model in
      if String.equal requested_model "" then
        Error "model must be a non-empty configured model id"
      else if String.equal requested_model runtime.provider_config.model_id then
        Ok runtime
      else
        Error
          (Printf.sprintf
             "runtime %S is configured for model %S, not requested model %S"
             runtime.id
             runtime.provider_config.model_id
             requested_model)

let resolve_runtime ?model_id = function
  | None ->
      (match Runtime.get_default_runtime () with
       | Some runtime -> validate_requested_model runtime model_id
       | None ->
           Error
             "default runtime is not initialized; load runtime.toml before running the benchmark")
  | Some runtime_id ->
      let runtime_id = String.trim runtime_id in
      if String.equal runtime_id "" then
        Error "runtime_pool must be a non-empty runtime.toml runtime id"
      else
        (match Runtime.get_runtime_by_id runtime_id with
         | Some runtime -> validate_requested_model runtime model_id
         | None ->
             Error
               (Printf.sprintf
                  "runtime %S is not materialized from runtime.toml"
                  runtime_id))

let ensure_runtime_reachable (runtime : Runtime.t) ~timeout_sec =
  match runtime.provider.healthcheck_path with
  | None -> Ok ()
  | Some healthcheck_path ->
      let health_url =
        runtime.provider_config.base_url
        |> Uri.of_string
        |> fun base -> Uri.with_path base healthcheck_path
        |> Uri.to_string
      in
      (match http_get_text_with_status ~timeout_sec health_url with
       | Ok (Some 200, _) -> Ok ()
       | Ok (status, _) ->
           let status_text =
             match status with
             | Some code -> Int.to_string code
             | None -> "no-status"
           in
           Error
             (Printf.sprintf
                "runtime %S unavailable: provider health check returned %s for %s"
                runtime.id
                status_text
                health_url)
       | Error err ->
           Error (Printf.sprintf "runtime %S unavailable: %s" runtime.id err))

let oas_completion_at (runtime : Runtime.t) ~prompt ~max_tokens ~timeout_sec () =
  match Masc_eio_env.get_opt () with
  | None ->
      (* MASC-OAS boundary: raw curl fallback removed.
         Bench must run inside an Eio-managed context. *)
      ( { success = false; latency_ms = 0;
          error = Some "Eio environment not available; bench requires OAS runtime context" },
        runtime.id )
  | Some env -> (
      let started = Time_compat.now () in
      let provider_config =
        { runtime.provider_config with max_tokens = Some max_tokens }
      in
          let messages : Oas_types.message list = [ Oas_types.user_msg prompt ] in
          let run_completion () =
            Llm_provider.Complete.complete ~sw:env.sw ~net:env.net
              ~config:provider_config ~messages ()
          in
          let outcome =
            try Ok (Eio.Time.with_timeout_exn env.clock (Stdlib.Float.of_int timeout_sec) run_completion)
            with Eio.Time.Timeout -> Error "timeout"
          in
          let latency_ms =
            Stdlib.Int.of_float ((Time_compat.now () -. started) *. 1000.0)
          in
          let sample =
            match outcome with
            | Error message -> { success = false; latency_ms; error = Some message }
            | Ok (Ok _response) -> { success = true; latency_ms; error = None }
            | Ok (Error http_error) ->
                {
                  success = false;
                  latency_ms;
                  error = Some (error_message_of_http_error http_error);
                }
          in
          (sample, runtime.id))

let run_bench ?model_id ?runtime_pool ~parallelism ~rounds ~prompt ~max_tokens
    ~timeout_sec () =
  match resolve_runtime ?model_id runtime_pool with
  | Error _ as err -> err
  | Ok runtime ->
    (match ensure_runtime_reachable runtime ~timeout_sec with
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
                 let sample, runtime_id =
                   oas_completion_at runtime ~prompt ~max_tokens ~timeout_sec ()
                 in
                 update_runtime_breakdown runtime_breakdown ~runtime_id ~sample;
                 results.(offset + fiber_idx) <- Some sample))
      done;
      let samples = results |> Array.to_list |> List.filter_map (fun item -> item) in
      let success_count =
        List.fold_left
          (fun acc (sample : bench_sample) ->
            if sample.success then acc + 1 else acc)
          0 samples
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
        runtime_breakdown |> per_runtime_breakdown_to_yojson
        |> List.map finalize_runtime_breakdown
      in
      Ok
        (`Assoc
          [
            ("server_url", `String runtime.provider_config.base_url);
            ("source", `String "oas_complete");
            ("model_id", `String runtime.provider_config.model_id);
            ("runtime_pool", `String runtime.id);
            ("parallelism", `Int parallelism);
            ("rounds", `Int rounds);
            ("total_requests", `Int (List.length samples));
            ("success_count", `Int success_count);
            ("failure_count", `Int failure_count);
            ( "success_rate",
              `Float
                (if Stdlib.List.length samples = 0 then 0.0
                 else
                   Stdlib.Float.of_int success_count
                   /. Stdlib.Float.of_int (List.length samples)) );
            ("p50_latency_ms", Json_util.int_opt_to_json (pctl 0.50 latencies));
            ("p95_latency_ms", Json_util.int_opt_to_json (pctl 0.95 latencies));
            ("max_latency_ms", Json_util.int_opt_to_json (pctl 1.0 latencies));
            ("configured_max_concurrent_models", `Int Inference_utils.max_concurrent_models);
            ("configured_capacity", `Int (Local_runtime_pool.configured_capacity ()));
            ("measured_ceiling", Json_util.int_opt_to_json (Local_runtime_pool.measured_ceiling ()));
            ("per_runtime_breakdown", `List runtime_breakdown);
            ( "errors",
              `List (errors |> List.map (fun message -> `String message)) );
          ]))
