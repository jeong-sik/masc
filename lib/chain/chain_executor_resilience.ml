(** Chain Executor - Resilience and infrastructure nodes (cache, batch, spawn, chain_exec, retry, fallback, race) *)

include Chain_executor_leaf
open Chain_types

let execute_cache ctx ~sw ~clock ~(exec_fn : exec_fn) ~(execute_node : execute_node_fn) ~tool_exec (node : node)
    ~key_expr ~ttl_seconds (inner : node) : (string, string) result =
  record_start ctx node.id;
  let start = Time_compat.now () in

  (* Generate cache key by resolving the key expression *)
  let cache_key = resolve_single_input ctx key_expr in
  let full_key = Printf.sprintf "%s:%s" inner.id cache_key in

  (* Check cache *)
  let cached = match Hashtbl.find_opt ctx.cache full_key with
    | Some (result, timestamp) ->
        if ttl_seconds = 0 || Time_compat.now () -. timestamp < float_of_int ttl_seconds then
          Some result
        else begin
          (* Expired - remove from cache *)
          Hashtbl.remove ctx.cache full_key;
          None
        end
    | None -> None
  in

  let result = match cached with
    | Some cached_result ->
        (* Cache hit - return cached value *)
        Ok cached_result
    | None ->
        (* Cache miss - execute inner node *)
        let inner_result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec inner in
        (match inner_result with
        | Ok output ->
            (* Store in cache *)
            Hashtbl.replace ctx.cache full_key (output, Time_compat.now ());
            Ok output
        | Error _ as e -> e)
  in

  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  let success = Result.is_ok result in
  record_complete ctx node.id ~duration_ms ~success;
  (match result with
  | Ok output -> store_node_output ctx node output
  | Error msg -> record_error ctx node.id msg);
  result

(** Execute batch node - process list items in batches *)

let execute_batch ctx ~sw ~clock ~(exec_fn : exec_fn) ~(execute_node : execute_node_fn) ~tool_exec (node : node)
    ~batch_size ~parallel ~collect_strategy (inner : node) : (string, string) result =
  record_start ctx node.id;
  let start = Time_compat.now () in

  (* Get input as JSON array *)
  let input_str = resolve_single_input ctx (Printf.sprintf "{{%s}}" node.id) in
  let items = try
    match Yojson.Safe.from_string input_str with
    | `List items -> Ok (List.map Yojson.Safe.to_string items)
    | `String s ->
        (* Try to parse as newline-separated items *)
        Ok (String.split_on_char '\n' s |> List.filter (fun s -> String.trim s <> ""))
    | _ -> Error "Batch input must be a JSON array or newline-separated text"
  with Yojson.Json_error _ ->
    (* Treat as newline-separated *)
    Ok (String.split_on_char '\n' input_str |> List.filter (fun s -> String.trim s <> ""))
  in

  match items with
  | Error msg ->
      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      record_complete ctx node.id ~duration_ms ~success:false;
      record_error ctx node.id msg;
      Error msg
  | Ok item_list ->
      (* Process items in batches - manual chunking *)
      let rec chunk_list n lst =
        if n <= 0 then [[]]
        else match lst with
        | [] -> []
        | _ ->
            let rec take n acc = function
              | [] -> (List.rev acc, [])
              | h :: t -> if n <= 0 then (List.rev acc, h :: t) else take (n - 1) (h :: acc) t
            in
            let (chunk, rest) = take n [] lst in
            chunk :: chunk_list n rest
      in
      let batches = chunk_list batch_size item_list in
      let all_results = ref [] in

      let process_batch batch_list =
        if parallel then begin
          (* Parallel execution within batch *)
          let mutex = Eio.Mutex.create () in
          Eio.Fiber.all (List.mapi (fun i item ->
            fun () ->
              (* Set item as input for inner node *)
              Hashtbl.replace ctx.outputs (Printf.sprintf "%s_item" node.id) item;
              let result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec inner in
              Eio.Mutex.use_rw mutex ~protect:true (fun () ->
                all_results := (i, result) :: !all_results
              )
          ) batch_list)
        end else begin
          (* Sequential execution within batch *)
          List.iteri (fun i item ->
            Hashtbl.replace ctx.outputs (Printf.sprintf "%s_item" node.id) item;
            let result = execute_node ctx ~sw ~clock ~exec_fn ~tool_exec inner in
            all_results := (i, result) :: !all_results
          ) batch_list
        end
      in

      List.iter process_batch batches;

      (* Sort results by index and collect *)
      let sorted_results = List.sort (fun (i1, _) (i2, _) -> compare i1 i2) !all_results in
      let outputs = List.filter_map (fun (_, r) ->
        match r with Ok o -> Some o | Error _ -> None
      ) sorted_results in

      let final_result = match collect_strategy with
        | `List -> Ok (Printf.sprintf "[%s]" (String.concat "," outputs))
        | `Concat -> Ok (String.concat "\n" outputs)
        | `First -> (match outputs with h :: _ -> Ok h | [] -> Error "No successful results")
        | `Last -> (match List.rev outputs with h :: _ -> Ok h | [] -> Error "No successful results")
      in

      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      let success = Result.is_ok final_result in
      record_complete ctx node.id ~duration_ms ~success;
      (match final_result with
      | Ok output -> store_node_output ctx node output
      | Error msg -> record_error ctx node.id msg);
      final_result

(** Execute spawn node - clean context execution for isolation

    When clean=true, creates a fresh context without prior outputs or conversation.
    This prevents "context contamination" where previous results pollute new analysis.

    Use cases:
    - Vision analysis: Ensure MODEL sees only the image, not prior HTML/text
    - Multi-iteration loops: Each iteration starts fresh
    - Parallel independent tasks: No cross-contamination

    pass_vars allows selective passing of specific variables even when clean=true.
*)

let execute_spawn ctx ~sw ~clock ~(exec_fn : exec_fn) ~(execute_node : execute_node_fn) ~tool_exec (node : node)
    ~clean ~pass_vars ~inherit_cache (inner : node) : (string, string) result =
  record_start ctx node.id;
  let start = Time_compat.now () in

  match Chain_spawn_registry.try_start ~label:node.id with
  | Error msg ->
      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      record_complete ctx node.id ~duration_ms ~success:false;
      record_error ctx node.id msg;
      Error msg
  | Ok spawn_id ->
      (* Create spawned context based on clean flag *)
      let spawn_ctx = if clean then begin
        (* Clean context - fresh start *)
        let new_ctx = make_context
          ~start_time:ctx.start_time
          ~trace_enabled:ctx.trace_enabled
          ~timeout:ctx.timeout
          ~chain_id:ctx.chain_id
          ()
        in
        (* Optionally inherit cache *)
        if inherit_cache then
          Hashtbl.iter (fun k v -> Hashtbl.replace new_ctx.cache k v) ctx.cache;
        (* Pass only specified variables *)
        List.iter (fun var_name ->
          match Hashtbl.find_opt ctx.outputs var_name with
          | Some value -> Hashtbl.replace new_ctx.outputs var_name value
          | None -> ()  (* Variable not found - silently skip *)
        ) pass_vars;
        new_ctx
      end else begin
        (* Non-clean: inherit everything (basically just grouping) *)
        ctx
      end in

      (* Execute inner node in spawned context *)
      let result =
        try execute_node spawn_ctx ~sw ~clock ~exec_fn ~tool_exec inner
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Error (Printf.sprintf "Spawn execution failed: %s" (Printexc.to_string exn))
      in

      (* Copy result back to parent context (for downstream nodes) *)
      (match result with
      | Ok output ->
          store_node_output ctx inner output;
          store_node_output ctx node output
      | Error msg ->
          Log.Chain.error "spawn failed for node %s: %s" node.id msg;
          store_node_output ctx node ("<spawn_error: " ^ msg ^ ">"));

      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      let success = Result.is_ok result in
      let error_msg =
        match result with
        | Ok _ -> None
        | Error msg -> Some msg
      in
      Chain_spawn_registry.finish ~id:spawn_id ~ok:success ~error:error_msg;
      record_complete ctx node.id ~duration_ms ~success;
      (match result with
      | Ok _ -> ()
      | Error msg -> record_error ctx node.id msg);
      result

(** Execute a dynamically generated chain (ChainExec node)

    Context Injection allows parent chain to pass data to generated chain:
    - pass_outputs: if true, all parent outputs are available as {{parent.node_id}}
    - context_inject: explicit mapping [(child_var, parent_source)] for {{var}} in child

    Depth tracking uses __chain_depth in outputs hashtable.
*)

let execute_chain_exec ctx ~sw ~clock ~(exec_fn : exec_fn) ~(execute_node : execute_node_fn) ~tool_exec (node : node)
    ~chain_source ~validate ~max_depth
    ~context_inject ~pass_outputs : (string, string) result =
  (* Check depth limit - stored in outputs table *)
  let current_depth = try
    int_of_string (Hashtbl.find ctx.outputs "__chain_depth")
  with Not_found | Failure _ -> 0
  in
  if current_depth >= max_depth then
    Error (Printf.sprintf "ChainExec depth limit exceeded: %d >= %d" current_depth max_depth)
  else begin
    (* Get chain JSON from source *)
    let chain_json_str = resolve_single_input ctx chain_source in
    if chain_json_str = "" then
      Error (Printf.sprintf "ChainExec: empty chain source from '%s'" chain_source)
    else
      (* Parse the chain JSON *)
      let chain_json = try
        Ok (Yojson.Safe.from_string chain_json_str)
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Error (Printf.sprintf "ChainExec: invalid JSON from '%s': %s" chain_source (Printexc.to_string exn))
      in
      match chain_json with
      | Error msg -> Error msg
      | Ok json ->
          (* Parse chain *)
          (match Chain_parser.parse_chain json with
          | Error msg ->
              Error (Printf.sprintf "ChainExec: parse error: %s" msg)
          | Ok generated_chain ->
              (* Validate if required *)
              let validation = if validate then Chain_parser.validate_chain generated_chain else Ok () in
              (match validation with
              | Error msg -> Error (Printf.sprintf "ChainExec: validation error: %s" msg)
              | Ok () ->
                  (* Create new outputs table for child chain with incremented depth *)
                  let new_outputs = Hashtbl.create 16 in
                  Hashtbl.replace new_outputs "__chain_depth" (string_of_int (current_depth + 1));

                  (* Context Injection: pass_outputs - copy parent outputs with "parent." prefix *)
                  if pass_outputs then
                    Hashtbl.iter (fun k v ->
                      if not (String.equal k "__chain_depth") then
                        Hashtbl.replace new_outputs ("parent." ^ k) v
                    ) ctx.outputs;

                  (* Context Injection: explicit mappings - resolve and inject *)
                  List.iter (fun (child_var, parent_source) ->
                    let resolved = resolve_single_input ctx parent_source in
                    Hashtbl.replace new_outputs child_var resolved
                  ) context_inject;

                  let new_ctx = { ctx with outputs = new_outputs } in
                  (* Compile and execute the generated chain *)
                  (match Chain_compiler.compile generated_chain with
                  | Error msg -> Error (Printf.sprintf "ChainExec: compile error: %s" msg)
                  | Ok plan ->
                      (* Execute nodes in order using compiled plan *)
                      let rec exec_nodes = function
                        | [] ->
                            (* Get final output *)
                            (match Hashtbl.find_opt new_ctx.outputs generated_chain.Chain_types.output with
                            | Some output ->
                                store_node_output ctx node output;
                                Ok output
                            | None ->
                                Error (Printf.sprintf "ChainExec: output node '%s' not found" generated_chain.Chain_types.output))
                        | node_id :: rest ->
                            (match Chain_compiler.get_node generated_chain node_id with
                            | None -> Error (Printf.sprintf "ChainExec: node '%s' not found" node_id)
                            | Some child_node ->
                                (match execute_node new_ctx ~sw ~clock ~exec_fn ~tool_exec child_node with
                                | Ok _ -> exec_nodes rest
                                | Error msg -> Error msg))
                      in
                      exec_nodes plan.Chain_types.execution_order)))
  end

(** Execute nodes in sequence (internal helper, no output storage) *)

let execute_retry ctx ~sw ~clock ~(exec_fn : exec_fn) ~(execute_node : execute_node_fn) ~tool_exec (parent : node)
    ~inner_node ~max_attempts ~backoff ~retry_on : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in
  let rec attempt n last_error =
    if n > max_attempts then begin
      let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
      record_complete ctx parent.id ~duration_ms ~success:false;
      record_error ctx parent.id (Printf.sprintf "Max retries (%d) exceeded: %s" max_attempts last_error);
      Error (Printf.sprintf "Max retries (%d) exceeded: %s" max_attempts last_error)
    end else begin
      if n > 1 then Eio.Time.sleep clock (calculate_backoff_delay backoff (n - 2));
      match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec inner_node with
      | Ok output ->
          let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
          record_complete ctx parent.id ~duration_ms ~success:true;
          store_node_output ctx parent output;
          Ok output
      | Error msg ->
          if should_retry retry_on msg then attempt (n + 1) msg
          else begin
            let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
            record_complete ctx parent.id ~duration_ms ~success:false;
            record_error ctx parent.id msg;
            Error msg
          end
    end
  in
  attempt 1 ""

(** Execute fallback node - try primary, then fallbacks in order *)

let execute_fallback ctx ~sw ~clock ~(exec_fn : exec_fn) ~(execute_node : execute_node_fn) ~tool_exec (parent : node)
    ~primary ~fallbacks : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in
  let rec try_nodes nodes errors =
    match nodes with
    | [] ->
        let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
        let msg = Printf.sprintf "All fallbacks failed: %s" (String.concat "; " (List.rev errors)) in
        record_complete ctx parent.id ~duration_ms ~success:false;
        record_error ctx parent.id msg;
        Error msg
    | node :: rest ->
        match execute_node ctx ~sw ~clock ~exec_fn ~tool_exec node with
        | Ok output ->
            let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
            record_complete ctx parent.id ~duration_ms ~success:true;
            store_node_output ctx parent output;
            Ok output
        | Error msg ->
            try_nodes rest ((node.id ^ ": " ^ msg) :: errors)
  in
  try_nodes (primary :: fallbacks) []

(** Exception used to signal race completion and cancel non-winning fibers. *)
exception Race_done

(** Execute race node - run all in parallel, first result wins (with timeout).
    Uses a sub-switch to cancel non-winning fibers on resolution. *)

let execute_race ctx ~sw:_ ~clock ~(exec_fn : exec_fn) ~(execute_node : execute_node_fn) ~tool_exec (parent : node)
    ~nodes ~timeout : (string, string) result =
  record_start ctx parent.id;
  let start = Time_compat.now () in
  let winner = ref None in
  let winner_mutex = Eio.Mutex.create () in
  let all_errors = ref [] in
  let finished_count = ref 0 in
  let total_nodes = List.length nodes in
  let timeout_sec = match timeout with Some t -> t | None -> 300.0 in
  let timed_out = ref false in
  let resolved = ref false in

  (* Run all racers inside a sub-switch so non-winning fibers get cancelled.
     A single Race_done exception is used to terminate the switch.
     The [resolved] flag prevents multiple Switch.fail calls. *)
  (try
    Eio.Switch.run (fun race_sw ->
      let signal_done () =
        if not !resolved then begin
          resolved := true;
          Eio.Switch.fail race_sw Race_done
        end
      in
      (* Timeout fiber: sleep then signal if no resolution yet *)
      Eio.Fiber.fork ~sw:race_sw (fun () ->
        (try Eio.Time.sleep clock timeout_sec
         with Eio.Cancel.Cancelled _ -> ());
        if not !resolved then begin
          timed_out := true;
          signal_done ()
        end);
      (* Racer fibers *)
      List.iter (fun (node : node) ->
        Eio.Fiber.fork ~sw:race_sw (fun () ->
          let already_won = Eio.Mutex.use_rw winner_mutex ~protect:true
            (fun () -> Option.is_some !winner) in
          if not already_won then
            match execute_node ctx ~sw:race_sw ~clock ~exec_fn ~tool_exec node with
            | Ok output ->
                Eio.Mutex.use_rw winner_mutex ~protect:true (fun () ->
                  if Option.is_none !winner then
                    winner := Some (node.id, output);
                  incr finished_count);
                signal_done ()
            | Error msg ->
                Eio.Mutex.use_rw winner_mutex ~protect:true (fun () ->
                  all_errors := (node.id ^ ": " ^ msg) :: !all_errors;
                  incr finished_count);
                if !finished_count = total_nodes then
                  signal_done ()
            | exception Eio.Cancel.Cancelled _ -> ()
        )
      ) nodes)
  with Race_done -> ());

  let duration_ms = int_of_float ((Time_compat.now () -. start) *. 1000.0) in
  if !timed_out then begin
    let msg = Printf.sprintf "Race timeout after %.1fs" timeout_sec in
    record_complete ctx parent.id ~duration_ms ~success:false;
    record_error ctx parent.id msg;
    Error msg
  end else
    match !winner with
    | Some (winner_id, output) ->
        record_complete ctx parent.id ~duration_ms ~success:true;
        store_node_output ctx parent (Printf.sprintf "[winner: %s] %s" winner_id output);
        Ok output
    | None ->
        let msg = Printf.sprintf "All racers failed: %s" (String.concat "; " !all_errors) in
        record_complete ctx parent.id ~duration_ms ~success:false;
        record_error ctx parent.id msg;
        Error msg

(** Execute StreamMerge node - process results progressively as they arrive *)

