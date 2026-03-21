(** Tool_local_runtime_verify -- runtime contract verification. *)

include Tool_local_runtime_http

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

let provider_health_reachable ~status ~body:_ =
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
  let configured_max_concurrent_models = Inference_utils.max_concurrent_models in
  let available_model_permits = Inference_utils.model_permits_available () in
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
      ("configured_max_concurrent_models", `Int configured_max_concurrent_models);
      ("available_model_permits", `Int available_model_permits);
      ("runtime_blocker", string_opt_to_json runtime_blocker);
      ("detail", string_opt_to_json detail);
      ("pass", `Bool (runtime_blocker = None));
      ("runtimes", `List (List.rev runtime_rows));
    ]
