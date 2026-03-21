(** Tool_local_runtime_bench -- concurrency benchmark against runtime pool. *)

include Tool_local_runtime_http

let pctl percentile values =
  match values with
  | [] -> None
  | _ ->
      let sorted = List.sort compare values in
      let len = List.length sorted in
      let index =
        int_of_float
          (Float.floor
             (percentile *. float_of_int (max 0 (len - 1))))
      in
      Some (List.nth sorted index)

let raw_completion_at ~server_url ~model_id ~prompt ~max_tokens ~timeout_sec () =
  let url = String.trim server_url ^ "/v1/chat/completions" in
  let request_body =
    `Assoc
      [
        ("model", `String model_id);
        ( "messages",
          `List
            [
              `Assoc
                [
                  ("role", `String "user");
                  ("content", `String prompt);
                ];
            ] );
        ("temperature", `Float 0.0);
        ("max_tokens", `Int max_tokens);
      ]
    |> Yojson.Safe.to_string
  in
  let started = Time_compat.now () in
  try
    let status, body =
      Process_eio.run_argv_with_stdin_and_status
        ~timeout_sec:(float_of_int (max 1 (timeout_sec + 2)))
        ~stdin_content:request_body
        [
          "curl";
          "-sS";
          "--http1.1";
          "--max-time";
          string_of_int (max 1 timeout_sec);
          "-X";
          "POST";
          url;
          "-H";
          "content-type: application/json";
          "--data-binary";
          "@-";
        ]
    in
    let latency_ms =
      int_of_float ((Time_compat.now () -. started) *. 1000.0)
    in
    match status with
    | Unix.WEXITED 0 -> (
        try
          let json = Yojson.Safe.from_string body in
          let open Yojson.Safe.Util in
          match member "error" json with
          | `Assoc fields -> (
              match List.assoc_opt "message" fields with
              | Some (`String msg) ->
                  { success = false; latency_ms; error = Some msg }
              | _ ->
                  { success = false; latency_ms; error = Some "llama returned error" })
          | _ ->
              ignore
                (match json |> member "choices" |> to_list with
                 | choice :: _ -> choice |> member "message" |> member "content" |> to_string_option
                 | [] -> None);
              { success = true; latency_ms; error = None }
        with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Failure _ ->
          { success = false; latency_ms; error = Some "invalid llama response json" })
    | Unix.WEXITED code ->
        {
          success = false;
          latency_ms;
          error = Some (Printf.sprintf "curl exit code %d" code);
        }
    | Unix.WSIGNALED sig_num ->
        {
          success = false;
          latency_ms;
          error = Some (Printf.sprintf "curl signal %d" sig_num);
        }
    | Unix.WSTOPPED sig_num ->
        {
          success = false;
          latency_ms;
          error = Some (Printf.sprintf "curl stopped %d" sig_num);
        }
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    {
      success = false;
      latency_ms =
        int_of_float ((Time_compat.now () -. started) *. 1000.0);
      error = Some (Printexc.to_string exn);
    }

let raw_completion ~model_id ~prompt ~max_tokens ~timeout_sec () =
  raw_completion_at ~server_url:Env_config.Llama.server_url ~model_id ~prompt
    ~max_tokens ~timeout_sec ()

let per_runtime_breakdown_to_yojson counts =
  counts
  |> Hashtbl.to_seq_values
  |> List.of_seq
  |> List.sort (fun a b ->
         compare
           (Yojson.Safe.Util.member "runtime_id" a |> Yojson.Safe.Util.to_string)
           (Yojson.Safe.Util.member "runtime_id" b |> Yojson.Safe.Util.to_string))

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
          ("p50_latency_ms", int_opt_to_json (pctl 0.50 latencies));
          ("p95_latency_ms", int_opt_to_json (pctl 0.95 latencies));
          ("max_latency_ms", int_opt_to_json (pctl 1.0 latencies));
        ]
  | _ -> json

let run_bench ?model_id ?runtime_pool ~parallelism ~rounds ~prompt ~max_tokens
    ~timeout_sec () =
  let total = parallelism * rounds in
  let results = Array.make total None in
  let runtime_breakdown = Hashtbl.create 8 in
  for round_idx = 0 to rounds - 1 do
    let offset = round_idx * parallelism in
    Eio.Fiber.all
      (List.init parallelism (fun fiber_idx ->
           fun () ->
             match
               Local_runtime_pool.acquire ?preferred_pool:runtime_pool
                 ~model_name:model_id ()
             with
             | Error err ->
                 results.(offset + fiber_idx) <-
                   Some { success = false; latency_ms = 0; error = Some err }
             | Ok assignment ->
                 let sample =
                   raw_completion_at ~server_url:assignment.base_url
                     ~model_id:assignment.model_name ~prompt ~max_tokens
                     ~timeout_sec ()
                 in
                 Local_runtime_pool.release assignment.lease
                   ~success:sample.success ?error:sample.error
                   ~latency_ms:sample.latency_ms ();
                 update_runtime_breakdown runtime_breakdown
                   ~runtime_id:assignment.runtime_id ~sample;
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
        ("server_url", `String Env_config.Llama.server_url);
        ("model_id", string_opt_to_json model_id);
        ("runtime_pool", string_opt_to_json runtime_pool);
        ("parallelism", `Int parallelism);
        ("rounds", `Int rounds);
        ("total_requests", `Int (List.length samples));
        ("success_count", `Int success_count);
        ("failure_count", `Int failure_count);
        ( "success_rate",
          `Float
            (if samples = [] then 0.0
             else
               float_of_int success_count
               /. float_of_int (List.length samples)) );
        ("p50_latency_ms", int_opt_to_json (pctl 0.50 latencies));
        ("p95_latency_ms", int_opt_to_json (pctl 0.95 latencies));
        ("max_latency_ms", int_opt_to_json (pctl 1.0 latencies));
        ("configured_max_concurrent_models", `Int Inference_utils.max_concurrent_models);
        ("configured_capacity", `Int (Local_runtime_pool.configured_capacity ()));
        ("measured_ceiling", int_opt_to_json (Local_runtime_pool.measured_ceiling ()));
        ("per_runtime_breakdown", `List runtime_breakdown);
        ( "errors",
          `List (errors |> List.map (fun message -> `String message)) );
      ])
