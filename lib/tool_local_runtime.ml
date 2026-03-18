[@@@warning "-32-33-69"]
(** Tool_local_runtime — local LLM runtime management and benchmarking tools. *)

open Types [@@warning "-33"]
include Tool_local_runtime_core


let trim_to_option raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed

let split_http_body_and_status body =
  match String.rindex_opt body '\n' with
  | None -> (body, None)
  | Some idx ->
      let payload = String.sub body 0 idx in
      let status_raw =
        String.sub body (idx + 1) (String.length body - idx - 1) |> String.trim
      in
      (payload, parse_int_opt status_raw)

let http_get_text_with_status ?(timeout_sec = 10) url =
  let status, body =
    Process_eio.run_argv_with_status
      [
        "curl";
        "-sS";
        "--http1.1";
        "--max-time";
        string_of_int (max 1 timeout_sec);
        "-w";
        "\n%{http_code}";
        url;
      ]
  in
  match status with
  | Unix.WEXITED 0 ->
      let payload, http_status = split_http_body_and_status body in
      Ok (http_status, payload)
  | Unix.WEXITED code ->
      Error (Printf.sprintf "curl exit code %d for %s" code url)
  | Unix.WSIGNALED sig_num ->
      Error (Printf.sprintf "curl signal %d for %s" sig_num url)
  | Unix.WSTOPPED sig_num ->
      Error (Printf.sprintf "curl stopped %d for %s" sig_num url)

let http_get_json_with_status ?(timeout_sec = 10) url =
  match http_get_text_with_status ~timeout_sec url with
  | Error _ as err -> err
  | Ok (http_status, payload) -> (
      try Ok (http_status, Yojson.Safe.from_string payload)
      with Yojson.Json_error msg ->
        Error (Printf.sprintf "invalid json from %s: %s" url msg))

let runtime_snapshots_for_pool runtime_pool =
  let snapshots = Local_runtime_pool.snapshots () in
  match Option.bind runtime_pool trim_to_option with
  | None -> snapshots
  | Some pool when String.equal pool Local_runtime_pool.default_pool_label -> snapshots
  | Some pool ->
      let filtered =
        List.filter
          (fun (runtime : Local_runtime_pool.runtime_snapshot) ->
            String.equal runtime.id pool || String.equal runtime.base_url pool)
          snapshots
      in
      if filtered = [] then snapshots else filtered

let active_slots_of_json json =
  let open Yojson.Safe.Util in
  let slots =
    match json with
    | `List items -> items
    | `Assoc _ -> (
        match member "slots" json with
        | `List items -> items
        | _ -> (
            match member "data" json with
            | `List items -> items
            | _ -> (
                match member "items" json with `List items -> items | _ -> [])))
    | _ -> []
  in
  let is_active slot =
    let status =
      slot |> member "status" |> to_string_option |> Option.value ~default:""
      |> String.lowercase_ascii
    in
    (slot |> member "is_processing" |> to_bool_option |> Option.value ~default:false)
    || (match slot |> member "state" with
       | `Int value -> value <> 0
       | `Intlit value -> Option.value ~default:0 (parse_int_opt value) <> 0
       | _ -> false)
    || status = "processing" || status = "prompt" || status = "generating"
  in
  List.fold_left (fun acc slot -> if is_active slot then acc + 1 else acc) 0 slots

let int_member json key =
  let open Yojson.Safe.Util in
  match member key json with
  | `Int value -> Some value
  | `Intlit value -> parse_int_opt value
  | _ -> None

let string_member json key =
  let open Yojson.Safe.Util in
  Option.bind (member key json |> to_string_option) trim_to_option

let provider_health_reachable ~status ~body:_ =
  (* Reachability should reflect whether the health endpoint answered
     successfully, not the exact body encoding. Current runtimes return either
     plain text or JSON payloads for /health. *)
  status = Some 200

let classify_runtime_blocker ~provider_reachable ~slot_reachable ~expected_model
    ~actual_model_id ~expected_slots ~actual_slots_total ~expected_ctx ~actual_ctx
    =
  if not provider_reachable || not slot_reachable then
    (Some "provider_unreachable", Some "llama runtime health or slots endpoint failed")
  else if
    match expected_model, actual_model_id with
    | Some expected, Some actual -> not (String.equal expected actual)
    | Some _, None -> true
    | _ -> false
  then
    ( Some "provider_model_mismatch",
      Some
        (Printf.sprintf "expected model %s, got %s"
           (Option.value ~default:"<missing>" expected_model)
           (Option.value ~default:"<mixed-or-missing>" actual_model_id)) )
  else if
    match expected_slots with
    | Some expected -> actual_slots_total < expected
    | None -> false
  then
    ( Some "slot_count_insufficient",
      Some
        (Printf.sprintf "expected at least %d slots, got %d"
           (Option.value ~default:0 expected_slots) actual_slots_total) )
  else if
    match expected_ctx, actual_ctx with
    | Some expected, Some actual -> expected <> actual
    | Some _, None -> true
    | _ -> false
  then
    ( Some "ctx_mismatch",
      Some
        (Printf.sprintf "expected ctx %s, got %s"
           (match expected_ctx with Some value -> string_of_int value | None -> "<none>")
           (match actual_ctx with Some value -> string_of_int value | None -> "<mixed-or-missing>")) )
  else
    (None, None)

let runtime_verify_json ?runtime_pool ?expected_slots ?expected_ctx ?expected_model () =
  let runtimes = runtime_snapshots_for_pool runtime_pool in
  let configured_capacity =
    runtimes
    |> List.fold_left
         (fun acc (runtime : Local_runtime_pool.runtime_snapshot) ->
           acc + runtime.max_concurrency)
         0
  in
  let configured_max_concurrent_llm = Llm.max_concurrent_llm in
  let available_llm_permits = Llm.llm_semaphore_available () in
  let runtime_rows, provider_reachable, slot_reachable, actual_slots_total,
      active_slots_now, actual_ctxs, actual_models =
    List.fold_left
      (fun
        (rows, provider_ok, slot_ok, slots_acc, active_acc, ctxs, models)
        (runtime : Local_runtime_pool.runtime_snapshot)
      ->
        let base_url = String.trim runtime.base_url in
        let provider_url = base_url ^ "/health" in
        let slot_url = base_url ^ "/slots" in
        let props_url = base_url ^ "/props" in
        let models_url = base_url ^ "/v1/models" in
        let provider_status, provider_body, provider_err =
          match http_get_text_with_status provider_url with
          | Ok (status_code, payload) -> (status_code, Some payload, None)
          | Error err -> (None, None, Some err)
        in
        let slot_status, slot_json, slot_err =
          match http_get_json_with_status slot_url with
          | Ok (status_code, payload) -> (status_code, Some payload, None)
          | Error err -> (None, None, Some err)
        in
        let props_status, props_json, props_err =
          match http_get_json_with_status props_url with
          | Ok (status_code, payload) -> (status_code, Some payload, None)
          | Error err -> (None, None, Some err)
        in
        let models_status, models_json, models_err =
          match http_get_json_with_status models_url with
          | Ok (status_code, payload) -> (status_code, Some payload, None)
          | Error err -> (None, None, Some err)
        in
        let provider_ok' =
          provider_ok
          && provider_health_reachable ~status:provider_status ~body:provider_body
        in
        let slot_ok' = slot_ok && slot_status = Some 200 in
        let actual_slots =
          Option.bind props_json (fun json -> int_member json "total_slots")
        in
        let actual_ctx =
          Option.bind props_json (fun json ->
              match Yojson.Safe.Util.member "default_generation_settings" json with
              | `Assoc _ as settings -> int_member settings "n_ctx"
              | _ -> None)
        in
        let actual_model =
          Option.bind models_json (fun json ->
              match Yojson.Safe.Util.member "data" json with
              | `List ((`Assoc _ as first) :: _) -> string_member first "id"
              | `List _ -> None
              | _ -> None)
        in
        let current_active =
          slot_json |> Option.map active_slots_of_json |> Option.value ~default:0
        in
        let row =
          `Assoc
            [
              ("runtime_id", `String runtime.id);
              ("base_url", `String base_url);
              ("provider_base_url", `String base_url);
              ("slot_url", `String base_url);
              ("provider_reachable", `Bool provider_ok');
              ("provider_status_code", int_opt_to_json provider_status);
              ("provider_error", string_opt_to_json provider_err);
              ("slot_reachable", `Bool (slot_status = Some 200));
              ("slot_status_code", int_opt_to_json slot_status);
              ("slot_error", string_opt_to_json slot_err);
              ("props_status_code", int_opt_to_json props_status);
              ("props_error", string_opt_to_json props_err);
              ("models_status_code", int_opt_to_json models_status);
              ("models_error", string_opt_to_json models_err);
              ("expected_model", string_opt_to_json expected_model);
              ("actual_model_id", string_opt_to_json actual_model);
              ("expected_slots", int_opt_to_json expected_slots);
              ("actual_slots", int_opt_to_json actual_slots);
              ("expected_ctx", int_opt_to_json expected_ctx);
              ("actual_ctx", int_opt_to_json actual_ctx);
              ("active_slots_now", `Int current_active);
            ]
        in
        ( row :: rows,
          provider_ok',
          slot_ok',
          slots_acc + Option.value ~default:0 actual_slots,
          active_acc + current_active,
          (match actual_ctx with Some value -> value :: ctxs | None -> ctxs),
          (match actual_model with Some value -> value :: models | None -> models) ))
      ([], true, true, 0, 0, [], []) runtimes
  in
  let actual_ctx =
    match List.sort_uniq compare actual_ctxs with [ value ] -> Some value | _ -> None
  in
  let actual_model_id =
    match List.sort_uniq String.compare actual_models with
    | [ value ] -> Some value
    | _ -> None
  in
  let runtime_blocker, detail =
    classify_runtime_blocker ~provider_reachable ~slot_reachable ~expected_model
      ~actual_model_id ~expected_slots ~actual_slots_total ~expected_ctx ~actual_ctx
  in
  `Assoc
    [
      ("checked_at", `String (Types.now_iso ()));
      ("runtime_pool", string_opt_to_json runtime_pool);
      ("provider_base_url", `String Env_config.Llama.server_url);
      ("slot_url", `String Env_config.Llama.server_url);
      ("provider_reachable", `Bool provider_reachable);
      ("slot_reachable", `Bool slot_reachable);
      ("expected_model", string_opt_to_json expected_model);
      ("actual_model_id", string_opt_to_json actual_model_id);
      ("expected_slots", int_opt_to_json expected_slots);
      ("actual_slots", `Int actual_slots_total);
      ("expected_ctx", int_opt_to_json expected_ctx);
      ("actual_ctx", int_opt_to_json actual_ctx);
      ("active_slots_now", `Int active_slots_now);
      ("peak_hot_slots", `Int active_slots_now);
      ("configured_capacity", `Int configured_capacity);
      ("configured_max_concurrent_llm", `Int configured_max_concurrent_llm);
      ("available_llm_permits", `Int available_llm_permits);
      ("runtime_blocker", string_opt_to_json runtime_blocker);
      ("detail", string_opt_to_json detail);
      ("pass", `Bool (runtime_blocker = None));
      ("runtimes", `List (List.rev runtime_rows));
    ]

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
  with exn ->
    {
      success = false;
      latency_ms =
        int_of_float ((Time_compat.now () -. started) *. 1000.0);
      error = Some (Printexc.to_string exn);
    }

let raw_completion ~model_id ~prompt ~max_tokens ~timeout_sec () =
  raw_completion_at ~server_url:Env_config.Llama.server_url ~model_id ~prompt
    ~max_tokens ~timeout_sec ()

let runtime_snapshot_to_yojson ~include_models
    (snapshot : Local_runtime_pool.runtime_snapshot) =
  let endpoint = String.trim snapshot.base_url ^ "/v1/models" in
  let fetched_models =
    if not include_models then []
    else
      match fetch_models_at snapshot.base_url with
      | Ok (_, models) -> models
      | Error _ -> []
  in
  let base_fields =
    match Local_runtime_pool.snapshot_to_yojson snapshot with
    | `Assoc fields -> fields
    | json -> [ ("snapshot", json) ]
  in
  `Assoc
    (base_fields
    @ [
        ("endpoint", `String endpoint);
        ("models", `List (List.map (fun model -> `String model) fetched_models));
        ("model_count", `Int (List.length fetched_models));
      ])

let runtime_status_json ?(include_models = true) () =
  let runtime_snapshots = Local_runtime_pool.snapshots () in
  let runtime_ports =
    runtime_snapshots
    |> List.filter_map (fun (runtime : Local_runtime_pool.runtime_snapshot) ->
           runtime.port)
  in
  let process_result = discover_processes () in
  let processes =
    match process_result with
    | Ok values -> values
    | Error _ -> []
  in
  let matching_processes =
    List.filter (process_matches_runtime_ports runtime_ports) processes
  in
  let runtime_json =
    runtime_snapshots
    |> List.map (runtime_snapshot_to_yojson ~include_models)
  in
  let models =
    if not include_models then []
    else
      runtime_json
      |> List.concat_map (fun json ->
             match Yojson.Safe.Util.member "models" json with
             | `List items ->
                 List.filter_map
                   (fun item -> Yojson.Safe.Util.to_string_option item)
                   items
             | _ -> [])
      |> unique_preserve_order
  in
  let configured_capacity = Local_runtime_pool.configured_capacity () in
  let allocated_slots = Local_runtime_pool.allocated_slots () in
  let healthy_runtime_count = Local_runtime_pool.healthy_runtime_count () in
  let measured_ceiling = Local_runtime_pool.measured_ceiling () in
  let parse_errors = Local_runtime_pool.parse_errors () in
  let observations =
    []
    |> (fun items ->
         if configured_capacity < 64 then
           Printf.sprintf
             "Configured local llama capacity is %d; local64 needs shard pool capacity >= 64."
             configured_capacity
           :: items
         else items)
    |> (fun items ->
         if matching_processes = [] then
           "No local llama-server process matched the configured runtime pool."
           :: items
         else items)
    |> (fun items ->
         if List.exists (fun (proc : llama_process) -> proc.slots_enabled) matching_processes then
           "Matched llama-server process has --slots enabled."
           :: items
         else items)
    |> (fun items ->
         match parse_errors with
         | [] -> items
         | errors ->
             (Printf.sprintf "Runtime pool config issues: %s"
                (String.concat "; " errors))
             :: items)
    |> List.rev
  in
  `Assoc
    [
      ("server_url", `String Env_config.Llama.server_url);
      ("endpoint", `String (Env_config.Llama.server_url ^ "/v1/models"));
      ("source", `String "llama.cpp runtime");
      ("models", `List (List.map (fun model -> `String model) models));
      ("model_count", `Int (List.length models));
      ("configured_max_concurrent_llm", `Int Llm.max_concurrent_llm);
      ("available_llm_permits", `Int (Llm.llm_semaphore_available ()));
      ("llm_permits_in_use", `Int (Llm.llm_permits_in_use  ()));
      ("target_parallelism", `Int configured_capacity);
      ("managed_gap_to_target", `Int 0);
      ("runtime_count", `Int (List.length runtime_snapshots));
      ("healthy_runtime_count", `Int healthy_runtime_count);
      ("configured_capacity", `Int configured_capacity);
      ("allocated_slots", `Int allocated_slots);
      ("measured_ceiling", int_opt_to_json measured_ceiling);
      ("process_count", `Int (List.length processes));
      ("matching_process_count", `Int (List.length matching_processes));
      ("runtime_config_errors", `List (List.map (fun item -> `String item) parse_errors));
      ("runtimes", `List runtime_json);
      ( "processes",
        `List (List.map process_to_yojson matching_processes) );
      ("observations", `List (List.map (fun item -> `String item) observations));
    ]

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
        ("configured_max_concurrent_llm", `Int Llm.max_concurrent_llm);
        ("configured_capacity", `Int (Local_runtime_pool.configured_capacity ()));
        ("measured_ceiling", int_opt_to_json (Local_runtime_pool.measured_ceiling ()));
        ("per_runtime_breakdown", `List runtime_breakdown);
        ( "errors",
          `List (errors |> List.map (fun message -> `String message)) );
      ])

let handle_models _ctx : result =
  match fetch_models () with
  | Error msg -> (false, json_error msg)
  | Ok (url, models) ->
      ( true,
        json_ok
          [
            ( "result",
              `Assoc
                [
                  ("server_url", `String Env_config.Llama.server_url);
                  ("endpoint", `String url);
                  ("source", `String "llama.cpp /v1/models");
                  ("models", `List (List.map (fun m -> `String m) models));
                  ("model_count", `Int (List.length models));
                ] );
          ] )

let handle_runtime_status _ctx args : result =
  let include_models =
    match Yojson.Safe.Util.member "include_models" args with
    | `Bool flag -> flag
    | _ -> true
  in
  (true, json_ok [ ("result", runtime_status_json ~include_models ()) ])

let handle_runtime_verify _ctx args : result =
  let open Yojson.Safe.Util in
  let runtime_pool = member "runtime_pool" args |> to_string_option in
  let expected_model = member "expected_model" args |> to_string_option in
  let expected_slots =
    match member "expected_slots" args with
    | `Int value -> Some (max 1 value)
    | `Intlit value -> parse_int_opt value
    | _ -> None
  in
  let expected_ctx =
    match member "expected_ctx" args with
    | `Int value -> Some (max 1 value)
    | `Intlit value -> parse_int_opt value
    | _ -> None
  in
  ( true,
    json_ok
      [
        ( "result",
          runtime_verify_json ?runtime_pool ?expected_slots ?expected_ctx
            ?expected_model () );
      ] )

let handle_runtime_bench _ctx args : result =
  let open Yojson.Safe.Util in
  let model_id = member "model" args |> to_string_option in
  let runtime_pool = member "runtime_pool" args |> to_string_option in
  let parallelism =
    match member "parallelism" args with
    | `Int value -> max 1 (min 128 value)
    | `Intlit value -> (
        match parse_int_opt value with
        | Some parsed -> max 1 (min 128 parsed)
        | None -> 8)
    | _ -> 8
  in
  let rounds =
    match member "rounds" args with
    | `Int value -> max 1 (min 8 value)
    | `Intlit value -> (
        match parse_int_opt value with
        | Some parsed -> max 1 (min 8 parsed)
        | None -> 1)
    | _ -> 1
  in
  let max_tokens =
    match member "max_tokens" args with
    | `Int value -> max 1 (min 128 value)
    | `Intlit value -> (
        match parse_int_opt value with
        | Some parsed -> max 1 (min 128 parsed)
        | None -> 16)
    | _ -> 16
  in
  let timeout_sec =
    match member "timeout_sec" args with
    | `Int value -> max 3 (min 120 value)
    | `Intlit value -> (
        match parse_int_opt value with
        | Some parsed -> max 3 (min 120 parsed)
        | None -> 20)
    | _ -> 20
  in
  let prompt =
    match member "prompt" args with
    | `String value when String.trim value <> "" -> String.trim value
    | _ -> "Reply with exactly one short word: ready"
  in
  match
    run_bench ?model_id ?runtime_pool ~parallelism ~rounds ~prompt
      ~max_tokens ~timeout_sec ()
  with
  | Ok json -> (true, json_ok [ ("result", json) ])
  | Error err -> (false, json_error err)

let dispatch ctx ~name ~args : result option =
  match name with
  (* Canonical names *)
  | "masc_local_runtime_models" | "masc_llama_models" ->
      Some (handle_models ctx)
  | "masc_local_runtime_status" | "masc_llama_runtime_status" ->
      Some (handle_runtime_status ctx args)
  | "masc_runtime_verify" ->
      Some (handle_runtime_verify ctx args)
  | "masc_local_runtime_bench" | "masc_llama_runtime_bench" ->
      Some (handle_runtime_bench ctx args)
  | _ -> None

let schemas : tool_schema list =
  [
    {
      name = "masc_local_runtime_models";
      description =
        "Read the local LLM runtime model inventory from /v1/models. Use this before spawning local workers so the leader can choose an explicit model id.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ("properties", `Assoc []);
          ];
    };
    {
      name = "masc_local_runtime_status";
      description =
        "Inspect the local LLM runtime pool used for spawned local workers. Returns runtime inventory, matched server processes, configured capacity, and current MASC LLM permit configuration.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("include_models", `Assoc [ ("type", `String "boolean") ]);
                ] );
          ];
    };
    {
      name = "masc_runtime_verify";
      description =
        "Strictly verify the active provider/runtime contract used for swarm and benchmark runs. Returns reachability, model match, slots, ctx, configured capacity, active slots, and blocker codes such as provider_unreachable, provider_model_mismatch, slot_count_insufficient, or ctx_mismatch.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("runtime_pool", `Assoc [ ("type", `String "string") ]);
                  ("expected_model", `Assoc [ ("type", `String "string") ]);
                  ("expected_slots", `Assoc [ ("type", `String "integer") ]);
                  ("expected_ctx", `Assoc [ ("type", `String "integer") ]);
                ] );
          ];
    };
    {
      name = "masc_local_runtime_bench";
      description =
        "Run a direct concurrency benchmark against the configured local LLM runtime pool to estimate current same-box parallel completion behavior.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("model", `Assoc [ ("type", `String "string") ]);
                  ("runtime_pool", `Assoc [ ("type", `String "string") ]);
                  ("parallelism", `Assoc [ ("type", `String "integer") ]);
                  ("rounds", `Assoc [ ("type", `String "integer") ]);
                  ("prompt", `Assoc [ ("type", `String "string") ]);
                  ("max_tokens", `Assoc [ ("type", `String "integer") ]);
                  ("timeout_sec", `Assoc [ ("type", `String "integer") ]);
                ] );
          ];
    };
  ]
