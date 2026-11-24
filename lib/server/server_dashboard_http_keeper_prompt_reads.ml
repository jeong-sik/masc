(* See server_dashboard_http_keeper_prompt_reads.mli. *)

module Http = Http_server_eio
module Types = Server_dashboard_http_keeper_api_types

(* Bounded process-local cache for expensive per-turn reads whose persisted
   result for one [(masc_dir, keeper, turn_ref)] is validated against the
   latest day-file stat of its backing store(s). Kept separate from
   [Dashboard_cache] so per-turn keys cannot evict shared fleet/dashboard hot
   keys. *)
module Bounded_turn_cache = struct
  type entry =
    { stamp : string
    ; json : Yojson.Safe.t
    ; expires_at : float
    ; seq : int
    }

  type t =
    { mu : Stdlib.Mutex.t
    ; max_entries : int
    ; ttl_s : float
    ; next_seq : int ref
    ; entries : (string, entry) Hashtbl.t
    ; order : (string * int) Queue.t
    }

  let create ~max_entries ~ttl_s =
    { mu = Stdlib.Mutex.create ()
    ; max_entries
    ; ttl_s
    ; next_seq = ref 0
    ; entries = Hashtbl.create max_entries
    ; order = Queue.create ()
    }
  ;;

  let with_lock t f =
    Stdlib.Mutex.lock t.mu;
    Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock t.mu) f
  ;;

  let rec prune_order_head t ~now =
    match Queue.peek_opt t.order with
    | None -> ()
    | Some (key, expected_seq) ->
      (match Hashtbl.find_opt t.entries key with
       | Some { seq; expires_at; _ } when seq = expected_seq && now <= expires_at -> ()
       | Some { seq; _ } when seq = expected_seq ->
         ignore (Queue.take_opt t.order);
         Hashtbl.remove t.entries key;
         prune_order_head t ~now
       | Some _ | None ->
         ignore (Queue.take_opt t.order);
         prune_order_head t ~now)
  ;;

  let compact_order_if_needed t ~now =
    if Queue.length t.order > t.max_entries * 2
    then (
      let live = Queue.create () in
      Queue.iter
        (fun ((key, expected_seq) as item) ->
          match Hashtbl.find_opt t.entries key with
          | Some { seq; expires_at; _ } when seq = expected_seq && now <= expires_at ->
            Queue.add item live
          | Some { seq; _ } when seq = expected_seq ->
            Hashtbl.remove t.entries key
          | Some _ | None -> ())
        t.order;
      Queue.clear t.order;
      Queue.transfer live t.order)
  ;;

  let rec evict_to_capacity t =
    if Hashtbl.length t.entries >= t.max_entries
    then (
      match Queue.take_opt t.order with
      | None -> ()
      | Some (oldest, expected_seq) ->
        (match Hashtbl.find_opt t.entries oldest with
         | Some { seq; _ } when seq = expected_seq -> Hashtbl.remove t.entries oldest
         | Some _ | None -> ());
        evict_to_capacity t)
  ;;

  let get t ~key ~stamp =
    let now = Time_compat.now () in
    with_lock t (fun () ->
      match Hashtbl.find_opt t.entries key with
      | Some { stamp = cached_stamp; json; expires_at; _ }
        when now <= expires_at && String.equal cached_stamp stamp ->
        Some json
      | Some _ ->
        Hashtbl.remove t.entries key;
        None
      | None -> None)
  ;;

  let set t ~key ~stamp json =
    let now = Time_compat.now () in
    let expires_at = now +. t.ttl_s in
    with_lock t (fun () ->
      prune_order_head t ~now;
      if not (Hashtbl.mem t.entries key) then evict_to_capacity t;
      incr t.next_seq;
      let seq = !(t.next_seq) in
      Queue.add (key, seq) t.order;
      Hashtbl.replace t.entries key { stamp; json; expires_at; seq };
      compact_order_if_needed t ~now)
  ;;
end

let file_stat_stamp path =
  try
    let st = Unix.stat path in
    match st.Unix.st_kind with
    | Unix.S_REG ->
      Printf.sprintf "%s:%d:%d:%d:%h:%h"
        path st.st_dev st.st_ino st.st_size st.st_mtime st.st_ctime
    | Unix.(S_DIR | S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK) -> path ^ ":non-reg"
  with Unix.Unix_error _ -> path ^ ":absent"
;;

let latest_store_file_stamp store =
  match Dated_jsonl.month_dir_paths_newest_first_result store with
  | Error _ -> None
  | Ok [] -> Some "empty"
  | Ok (month_dir :: _) ->
    (match Dated_jsonl.day_file_paths_newest_first_result month_dir with
     | Error _ -> None
     | Ok [] -> Some (month_dir ^ ":empty")
     | Ok (day_path :: _) -> Some (file_stat_stamp day_path))
;;

let turn_cache_key ~config ~keeper ~turn_ref =
  String.concat "\000"
    [ Workspace.masc_dir config; keeper; Ids.Turn_ref.to_string turn_ref ]
;;

let provider_input_manifest_cache =
  Bounded_turn_cache.create ~max_entries:64 ~ttl_s:60.0
;;

let cache_outcome_cache =
  Bounded_turn_cache.create ~max_entries:64 ~ttl_s:15.0
;;

let idle_is_config_independent = function
  | Keeper_cache_outcome_reading.Start_unrecorded -> true
  | Keeper_cache_outcome_reading.Idle { lifetime; _ } ->
    (match lifetime with
     | Keeper_cache_outcome_reading.Lifetime_declared _
     | Keeper_cache_outcome_reading.Lifetime_unrecorded -> true
     | Keeper_cache_outcome_reading.Provider_default_unknown _ -> false)
;;

let cache_outcome_is_settled (reading : Keeper_cache_outcome_reading.reading) =
  match reading.outcome with
  | Keeper_cache_outcome_reading.Not_per_request _ -> true
  | Keeper_cache_outcome_reading.First_request
      { earlier =
          Keeper_cache_outcome_reading.Earlier
            { idle; prefix = Keeper_cache_outcome_reading.Compared _; _ }
      ; _
      } -> idle_is_config_independent idle
  | Keeper_cache_outcome_reading.Turn_not_in_ledger
  | Keeper_cache_outcome_reading.Ledger_row_unreadable _
  | Keeper_cache_outcome_reading.First_request
      { earlier = Keeper_cache_outcome_reading.No_earlier_request _; _ }
  | Keeper_cache_outcome_reading.First_request
      { earlier =
          Keeper_cache_outcome_reading.Earlier
            { prefix = Keeper_cache_outcome_reading.Not_compared _; _ }
      ; _
      } -> false
;;

(* The doors onto one exact turn of one Keeper. Each runs its read on the
   pool: finding a turn decodes store rows newest first, and a live
   provider-input store holds 79-231 MB of them. *)
let handle_turn_get state req reqd ~name ~surface ~read ~error_status ~error_to_string =
  let bad_request detail =
    Http.Response.json_value
      ~status:`Bad_request
      (`Assoc [ "error", `String detail ])
      reqd
  in
  if not (Keeper_config.validate_name name)
  then bad_request (Printf.sprintf "invalid keeper name: %s" name)
  else
    match Server_utils.query_param req "turn_ref" with
    | None -> bad_request "turn_ref query parameter is required"
    | Some raw_turn_ref ->
      (match Ids.Turn_ref.of_string raw_turn_ref with
       | None -> bad_request (Printf.sprintf "invalid turn_ref: %s" raw_turn_ref)
       | Some turn_ref ->
         (match
            read ~config:(Mcp_server.workspace_config state) ~keeper:name ~turn_ref
          with
          | Error detail -> bad_request detail
          | Ok job ->
            let with_surface = function
              | `Assoc fields ->
                `Assoc (("dashboard_surface", `String surface) :: fields)
              | json -> json
            in
            (match
               Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
                 Result.map with_surface (job ()))
             with
             | Ok json ->
               Http.Response.json_value_on_cpu ~compress:true ~request:req json reqd
             | Error error ->
               Http.Response.json_value
                 ~status:(error_status error)
                 (`Assoc [ "error", `String (error_to_string error) ])
                 reqd)))
;;

let snapshot_error_status = function
  | Keeper_provider_input_snapshot.Snapshot_not_found _
  | Keeper_provider_input_snapshot.Part_not_found _ -> `Not_found
  | Keeper_provider_input_snapshot.Unknown_keeper _
  | Keeper_provider_input_snapshot.Store_read_failed _
  | Keeper_provider_input_snapshot.Malformed_snapshot _
  | Keeper_provider_input_snapshot.Invalid_artifact_reference _
  | Keeper_provider_input_snapshot.Artifact_read_failed _
  | Keeper_provider_input_snapshot.Artifact_missing _
  | Keeper_provider_input_snapshot.Artifact_length_mismatch _ -> `Service_unavailable
;;

(* The provider-input doors: the parts of one turn's request, one of those
   parts, and the turn's continuity record. *)
let handle_provider_input_get state req reqd ~name ~surface ~read =
  handle_turn_get
    state
    req
    reqd
    ~name
    ~surface
    ~read
    ~error_status:snapshot_error_status
    ~error_to_string:Keeper_provider_input_snapshot.read_error_to_string
;;

let handle_last_prompt_get state req reqd name =
  (* What this keeper was actually told, as text. The turn record keeps each
     block's bytes and digest — how much, never what. The blocks are stable
     turn to turn, so the last assembly is also the preview of the next. *)
  (match
     Keeper_prompt_capture.read ~config:(Mcp_server.workspace_config state) ~keeper:name
   with
   | Ok capture ->
     Http.Response.json_value ~compress:true ~request:req
       (match Keeper_prompt_capture.to_json capture with
        | `Assoc fields ->
          `Assoc
            (("keeper", `String name)
             :: ("dashboard_surface", `String "/api/v1/keepers/:name/last-prompt")
             :: fields)
        | json -> json)
       reqd
   | Error (Keeper_prompt_capture.Not_captured as error) ->
     Http.Response.json_value ~status:`Not_found
       (`Assoc
          [ "error", `String (Keeper_prompt_capture.read_error_to_string error) ])
       reqd
   | Error
       ((Keeper_prompt_capture.Unknown_keeper _
        | Keeper_prompt_capture.Malformed _) as error) ->
     Http.Response.json_value ~status:`Bad_request
       (`Assoc
          [ "error", `String (Keeper_prompt_capture.read_error_to_string error) ])
       reqd)
;;

let handle_provider_input_part_get state req reqd name =
  handle_provider_input_get
    state
    req
    reqd
    ~name
    ~surface:"/api/v1/keepers/:name/provider-input/part"
    ~read:(fun ~config ~keeper ~turn_ref ->
      match Server_utils.query_param req "index" with
      | None -> Error "index query parameter is required"
      | Some raw_index ->
        (match int_of_string_opt raw_index with
         | Some index when index >= 0 ->
           Ok
             (fun () ->
               Keeper_provider_input_snapshot.read_part
                 ~config
                 ~keeper
                 ~turn_ref
                 ~index
               |> Result.map Keeper_provider_input_snapshot.part_content_to_json)
         | Some _ | None ->
           Error (Printf.sprintf "invalid index: %s" raw_index)))
;;

let handle_provider_input_manifest_get state req reqd name =
  handle_provider_input_get
    state
    req
    reqd
    ~name
    ~surface:"/api/v1/keepers/:name/provider-input"
    ~read:(fun ~config ~keeper ~turn_ref ->
      Ok
        (fun () ->
          let key = turn_cache_key ~config ~keeper ~turn_ref in
          let store = Keeper_types_support.keeper_provider_input_store config keeper in
          let stamp_opt = latest_store_file_stamp store in
          match Option.bind stamp_opt (fun stamp ->
            Bounded_turn_cache.get provider_input_manifest_cache ~key ~stamp) with
          | Some json -> Ok json
          | None ->
            (match
               Keeper_provider_input_snapshot.read_manifest
                 ~config
                 ~keeper
                 ~turn_ref
             with
             | Ok manifest ->
               let json = Keeper_provider_input_snapshot.manifest_to_json manifest in
               (match stamp_opt, latest_store_file_stamp store with
                | Some before, Some after when String.equal before after ->
                  Bounded_turn_cache.set provider_input_manifest_cache ~key ~stamp:before json
                | Some _, Some _ | Some _, None | None, _ -> ());
               Ok json
             | Error _ as err -> err)))
;;

(* No cost row of a Keeper is older than the Keeper, so the ledger walk opens
   no day file before its creation. *)
let keeper_born_at ~config ~keeper =
  match Keeper_meta_store.read_meta_presence config keeper with
  | Error detail -> Error detail
  | Ok Keeper_meta_store.Meta_absent -> Error (Printf.sprintf "unknown keeper: %s" keeper)
  | Ok (Keeper_meta_store.Meta_not_current detail) -> Error detail
  | Ok (Keeper_meta_store.Meta_present meta) ->
    let created_at = meta.Keeper_meta_contract.created_at in
    (match Workspace_resilience.Time.parse_iso8601_opt created_at with
     | Some born_at -> Ok born_at
     | None ->
       Error
         (Printf.sprintf
            "keeper %s: created_at %S is not an ISO 8601 time"
            keeper
            created_at))
;;

(* The default lifetime of the provider that answers [runtime_id] in the
   running configuration. A runtime the configuration no longer holds names no
   provider, which is not the same as a provider that declares nothing. *)
let provider_default_cache_ttl_s runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | None -> Error Keeper_cache_outcome_reading.Runtime_inactive
  | Some runtime ->
    (match
       Llm_provider.Catalog_snapshot.default_cache_ttl_s
         (Llm_provider.Catalog_snapshot.current ())
         ~provider_id:(Runtime_schema.catalog_provider_id runtime.Runtime_instance.provider)
     with
     | Some lifetime_s -> Ok lifetime_s
     | None -> Error Keeper_cache_outcome_reading.Default_undeclared)
;;

let handle_cache_outcome_get state req reqd name =
  handle_turn_get
    state
    req
    reqd
    ~name
    ~surface:("/api/v1/keepers/:name" ^ Types.keeper_suffix_cache_outcome)
    ~read:(fun ~config ~keeper ~turn_ref ->
      Result.map
        (fun born_at () ->
          let key = turn_cache_key ~config ~keeper ~turn_ref in
          let pi_store = Keeper_types_support.keeper_provider_input_store config keeper in
          let cost_store =
            Cost_ledger.store_of_base_path ~base_path:config.Workspace.base_path
          in
          let current_stamp () =
            match latest_store_file_stamp pi_store, latest_store_file_stamp cost_store with
            | Some pi_s, Some cost_s -> Some (pi_s ^ "\000" ^ cost_s)
            | None, _ | Some _, None -> None
          in
          let stamp_opt = current_stamp () in
          match Option.bind stamp_opt (fun stamp ->
            Bounded_turn_cache.get cache_outcome_cache ~key ~stamp) with
          | Some json -> Ok json
          | None ->
            (match
               Keeper_cache_outcome.read
                 ~config
                 ~keeper
                 ~turn_ref
                 ~born_at
                 ~provider_default_s:provider_default_cache_ttl_s
             with
             | Ok reading ->
               let json = Keeper_cache_outcome_reading.to_json reading in
               if cache_outcome_is_settled reading
               then (
                 match stamp_opt, current_stamp () with
                 | Some before, Some after when String.equal before after ->
                   Bounded_turn_cache.set cache_outcome_cache ~key ~stamp:before json
                 | Some _, Some _ | Some _, None | None, _ -> ());
               Ok json
             | Error _ as err -> err))
        (keeper_born_at ~config ~keeper))
    ~error_status:(fun (Keeper_cache_outcome.Ledger_unreadable _) -> `Service_unavailable)
    ~error_to_string:Keeper_cache_outcome.read_error_to_string
;;
