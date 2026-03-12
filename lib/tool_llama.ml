open Types

type context = {
  config : Room.config;
  agent_name : string;
}

type result = bool * string

type llama_process = {
  pid : int option;
  command : string;
  port : int option;
  host : string option;
  alias : string option;
  model_path : string option;
  ctx_size : int option;
  batch_size : int option;
  ubatch_size : int option;
  slots_enabled : bool;
}

type bench_sample = {
  success : bool;
  latency_ms : int;
  error : string option;
}

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let int_opt_to_json = function Some value -> `Int value | None -> `Null
let string_opt_to_json = function Some value -> `String value | None -> `Null
let float_opt_to_json = function Some value -> `Float value | None -> `Null

let parse_int_opt value =
  try Some (int_of_string (String.trim value)) with Failure _ -> None

let unique_preserve_order items =
  let rec loop seen = function
    | [] -> List.rev seen
    | x :: xs ->
        if List.mem x seen then loop seen xs else loop (x :: seen) xs
  in
  loop [] items

let split_ws text =
  text
  |> String.split_on_char ' '
  |> List.map String.trim
  |> List.filter (fun item -> item <> "")

let string_contains_substring text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  if needle_len = 0 then
    true
  else if needle_len > text_len then
    false
  else
    let rec loop idx =
      if idx + needle_len > text_len then
        false
      else if String.sub text idx needle_len = needle then
        true
      else
        loop (idx + 1)
    in
    loop 0

let parse_pid_and_command line =
  let trimmed = String.trim line in
  if trimmed = "" then
    (None, "")
  else
    match String.index_opt trimmed ' ' with
    | None -> (parse_int_opt trimmed, "")
    | Some idx ->
        let pid = String.sub trimmed 0 idx |> parse_int_opt in
        let command =
          String.sub trimmed (idx + 1) (String.length trimmed - idx - 1)
          |> String.trim
        in
        (pid, command)

let find_flag_value tokens flag =
  let rec loop = function
    | [] | [ _ ] -> None
    | key :: value :: rest ->
        if String.equal key flag then
          Some value
        else
          loop (value :: rest)
  in
  loop tokens

let has_flag tokens flag = List.exists (String.equal flag) tokens

let server_port_of_url url =
  let trimmed = String.trim url in
  match String.rindex_opt trimmed ':' with
  | None -> None
  | Some idx ->
      let port =
        String.sub trimmed (idx + 1) (String.length trimmed - idx - 1)
      in
      parse_int_opt port

let process_to_yojson (process : llama_process) =
  `Assoc
    [
      ("pid", int_opt_to_json process.pid);
      ("command", `String process.command);
      ("port", int_opt_to_json process.port);
      ("host", string_opt_to_json process.host);
      ("alias", string_opt_to_json process.alias);
      ("model_path", string_opt_to_json process.model_path);
      ("ctx_size", int_opt_to_json process.ctx_size);
      ("batch_size", int_opt_to_json process.batch_size);
      ("ubatch_size", int_opt_to_json process.ubatch_size);
      ("slots_enabled", `Bool process.slots_enabled);
    ]

let process_matches_runtime_ports ports (process : llama_process) =
  match process.port with
  | Some port -> List.mem port ports
  | None -> false

let discover_processes () =
  let status, body =
    Process_eio.run_argv_with_status ~timeout_sec:5.0
      [ "ps"; "-ax"; "-o"; "pid=,command=" ]
  in
  match status with
  | Unix.WEXITED 0 ->
      let processes =
        body
        |> String.split_on_char '\n'
        |> List.filter_map (fun line ->
               let pid, command = parse_pid_and_command line in
               if command = "" || not (string_contains_substring command "llama-server") then
                 None
               else
                 let tokens = split_ws command in
                 if not (List.exists (fun token -> String.ends_with ~suffix:"llama-server" token) tokens)
                 then None
                 else
                   Some
                     {
                       pid;
                       command;
                       port =
                         Option.bind
                           (find_flag_value tokens "--port")
                           parse_int_opt;
                       host = find_flag_value tokens "--host";
                       alias = find_flag_value tokens "--alias";
                       model_path = find_flag_value tokens "-m";
                       ctx_size =
                         Option.bind
                           (find_flag_value tokens "-c")
                           parse_int_opt;
                       batch_size =
                         Option.bind
                           (find_flag_value tokens "--batch-size")
                           parse_int_opt;
                       ubatch_size =
                         Option.bind
                           (find_flag_value tokens "--ubatch-size")
                           parse_int_opt;
                       slots_enabled = has_flag tokens "--slots";
                     }
               )
      in
      Ok processes
  | Unix.WEXITED code ->
      Error (Printf.sprintf "ps failed with exit code %d" code)
  | Unix.WSIGNALED sig_num ->
      Error (Printf.sprintf "ps killed by signal %d" sig_num)
  | Unix.WSTOPPED sig_num ->
      Error (Printf.sprintf "ps stopped by signal %d" sig_num)

let fetch_models_at base_url =
  let url = String.trim base_url ^ "/v1/models" in
  let status, body =
    Process_eio.run_argv_with_status ~timeout_sec:15.0
      [ "curl"; "-sS"; "--max-time"; "10"; url ]
  in
  match status with
  | Unix.WEXITED 0 -> (
      try
        let json = Yojson.Safe.from_string body in
        let open Yojson.Safe.Util in
        let models =
          match member "data" json with
          | `List items ->
              items
              |> List.filter_map (fun item ->
                     item |> member "id" |> to_string_option)
          | _ -> []
        in
        Ok (url, models)
      with Yojson.Json_error msg -> Error ("invalid llama models response: " ^ msg))
  | Unix.WEXITED code ->
      Error
        (Printf.sprintf "llama models request failed with exit code %d" code)
  | Unix.WSIGNALED sig_num ->
      Error (Printf.sprintf "llama models request killed by signal %d" sig_num)
  | Unix.WSTOPPED sig_num ->
      Error (Printf.sprintf "llama models request stopped by signal %d" sig_num)

let fetch_models () = fetch_models_at Env_config.Llama.server_url

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
      ("configured_max_concurrent_llm", `Int Llm_client.max_concurrent_llm);
      ("available_llm_permits", `Int (Llm_client.llm_semaphore_available ()));
      ("target_parallelism", `Int 64);
      ("managed_gap_to_target", `Int (max 0 (64 - configured_capacity)));
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
        ("configured_max_concurrent_llm", `Int Llm_client.max_concurrent_llm);
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
  | "masc_llama_models" -> Some (handle_models ctx)
  | "masc_llama_runtime_status" -> Some (handle_runtime_status ctx args)
  | "masc_llama_runtime_bench" -> Some (handle_runtime_bench ctx args)
  | _ -> None

let schemas : tool_schema list =
  [
    {
      name = "masc_llama_models";
      description =
        "Read the llama.cpp model inventory from /v1/models. Use this before spawning llama workers so the leader can choose an explicit model id.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ("properties", `Assoc []);
          ];
    };
    {
      name = "masc_llama_runtime_status";
      description =
        "Inspect the local llama.cpp runtime pool used for spawned local workers. Returns runtime inventory, matched llama-server processes, configured capacity, and current MASC LLM permit configuration.";
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
      name = "masc_llama_runtime_bench";
      description =
        "Run a direct concurrency benchmark against the configured local llama.cpp runtime pool to estimate current same-box parallel completion behavior.";
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
