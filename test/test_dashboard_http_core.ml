module Types = Masc_domain

let () = Mirage_crypto_rng_unix.use_default ()

module Lib = Masc
module Auth = Auth
module Workspace = Masc.Workspace
module Dashboard_http_keeper = Dashboard_http_keeper

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_http_core" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let invalid_utf8_byte_count s =
  let len = String.length s in
  let rec loop i count =
    if i >= len
    then count
    else (
      let dec = String.get_utf_8_uchar s i in
      let dlen = Uchar.utf_decode_length dec in
      if dlen > 0 && Uchar.utf_decode_is_valid dec
      then loop (i + dlen) count
      else loop (i + 1) (count + 1))
  in
  loop 0 0

let nested_path_string_present_or_null json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `Null -> true
  | value -> (
      match value |> member "path" with
      | `String path -> String.length path > 0
      | _ -> false)

let read_file path =
  let path =
    if Filename.is_relative path then
      match Sys.getenv_opt "DUNE_SOURCEROOT" with
      | Some root -> Filename.concat root path
      | None -> path
    else path
  in
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else begin
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o755
  end

let with_cached_surface_success
      (surface : Server_dashboard_http_cache.cached_surface)
      json
      f
  =
  (* One snapshot is the whole saved state now — the eight-field save and
     restore this used to carry collapsed with the record. *)
  let saved = Server_dashboard_http_cache.snapshot surface in
  Fun.protect
    ~finally:(fun () -> surface.Server_dashboard_http_cache.current <- saved)
    (fun () ->
      Server_dashboard_http_cache.mark_cached_surface_success surface json;
      f ())

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some prev -> Unix.putenv key prev
      | None -> Unix.putenv key "")
    f

let request target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list []) `GET target

let request_with_headers target headers =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET target

let test_keeper_name_extractors_use_shared_grammar () =
  let keeper_name = "release.bot" in
  check bool "dotted keeper name is valid" true
    (Server_dashboard_http_keeper_api.is_valid_keeper_name keeper_name);
  List.iter
    (fun suffix ->
       let path = "/api/v1/keepers/" ^ keeper_name ^ suffix in
       check string (suffix ^ " suffix extraction") keeper_name
         (Server_dashboard_http_keeper_api.extract_keeper_name_for_suffix path suffix);
       check string (suffix ^ " POST extraction") keeper_name
         (Server_dashboard_http_keeper_api.extract_keeper_name_for_post path suffix))
    [ Server_dashboard_http_keeper_api.keeper_suffix_github_identity
    ; Server_dashboard_http_keeper_api.keeper_suffix_github_login
    ];
  List.iter
    (fun reserved ->
       let suffix = Server_dashboard_http_keeper_api.keeper_suffix_github_login in
       let path = "/api/v1/keepers/" ^ reserved ^ suffix in
       check string (reserved ^ " remains reserved") ""
         (Server_dashboard_http_keeper_api.extract_keeper_name_for_suffix path suffix))
    [ "."; ".." ]

let test_keeper_paused_work_route_is_admin_exact () =
  let path = "/api/v1/keepers/fixture-keeper/paused-work" in
  check bool
    "paused-work POST route kind"
    true
    (Server_dashboard_http_keeper_api.classify_keeper_post_route path
     = Server_dashboard_http_keeper_api.Keeper_post_paused_work);
  check bool
    "paused-work GET route kind"
    true
    (Server_dashboard_http_keeper_api.is_keeper_paused_work_get_path path);
  check string
    "paused-work keeper name"
    "fixture-keeper"
    (Server_dashboard_http_keeper_api.extract_keeper_name_for_suffix
       path
       Server_dashboard_http_keeper_api.keeper_suffix_paused_work);
  check bool
    "paused-work route rejects trailing segment"
    false
    (Server_dashboard_http_keeper_api.is_keeper_paused_work_get_path (path ^ "/extra"))

let test_keeper_up_route_classifies_and_extracts () =
  let path = "/api/v1/keepers/fixture-keeper/up" in
  check bool
    "up POST route kind"
    true
    (Server_dashboard_http_keeper_api.classify_keeper_post_route path
     = Server_dashboard_http_keeper_api.Keeper_post_up);
  check string
    "up keeper name"
    "fixture-keeper"
    (Server_dashboard_http_keeper_api.extract_keeper_name_for_post
       path
       Server_dashboard_http_keeper_api.keeper_suffix_up)
;;

let test_keeper_sensitive_get_permissions_are_exact () =
  let permission path =
    Server_dashboard_http_keeper_api.keeper_get_permission path
  in
  List.iter
    (fun suffix ->
       let path = "/api/v1/keepers/fixture-keeper/" ^ suffix in
       check bool (suffix ^ " permission") true
         (permission path = Some Masc_domain.CanAdmin);
       check bool (suffix ^ " trailing segment") true
         (permission (path ^ "/extra") = None))
    (* file-changes returns the exact text a keeper wrote to a file, which is
       part of what raw-trace already holds. Same data, same gate — a lighter
       one here would be a second door onto the first door's content. *)
    [ "raw-traces"; "raw-trace"; "provider-input"; "memory-journal"
    ; "memory-facts"; "file-changes" ];
  check bool "checkpoint permission" true
    (permission "/api/v1/keepers/fixture-keeper/checkpoints" = Some Masc_domain.CanAdmin);
  check bool "turn records require authenticated state read" true
    (permission "/api/v1/keepers/fixture-keeper/turn-records"
     = Some Masc_domain.CanReadState);
  check bool "turn records route rejects trailing segment" true
    (permission "/api/v1/keepers/fixture-keeper/turn-records/extra" = None);
  check bool "ordinary keeper read stays public" true
    (permission "/api/v1/keepers/fixture-keeper/trajectory" = None)

let test_internal_exact_lane_registry_is_admin_only () =
  check bool
    "exact lane registry requires Admin"
    true
    (Server_routes_http_routes_dashboard.For_testing.exact_lane_run_permission
     = Masc_domain.CanAdmin)

let test_runtime_probe_route_owns_read_permission () =
  check bool
    "metadata-only runtime probe remains a read route"
    true
    (Server_routes_http_routes_dashboard.For_testing.runtime_probe_read_permission
     = Masc_domain.CanReadState)

let test_event_queue_operator_routes_are_exact () =
  check (option string) "event operator route is exact" (Some "fixture-keeper")
    (Server_dashboard_http_keeper_event_queue_operator.route
       "/api/v1/keepers/fixture-keeper/events/operator");
  check (option string) "event operator route rejects extra segments" None
    (Server_dashboard_http_keeper_event_queue_operator.route
       "/api/v1/keepers/fixture-keeper/events/operator/extra");
  check bool "Worker cannot mutate pending events" false
    (Masc_domain.has_permission
       Masc_domain.Worker
       Server_dashboard_http_keeper_event_queue_operator.operator_permission);
  check bool "Admin can mutate pending events" true
    (Masc_domain.has_permission
       Masc_domain.Admin
       Server_dashboard_http_keeper_event_queue_operator.operator_permission);
  let source : Keeper_event_queue.stimulus =
    { post_id = "board-post-sensitive"
    ; urgency = Normal
    ; arrived_at = 42.0
    ; payload =
        Board_signal
          { kind = Post_created
          ; author = "operator"
          ; title = "private title"
          ; content = "private title body"
          ; hearth = None
          ; updated_at = None
          }
    }
  in
  let same_post_id_source : Keeper_event_queue.stimulus =
    { source with urgency = Low; payload = Bootstrap }
  in
  let duplicate_post_id_queue =
    Keeper_event_queue.empty
    |> fun queue -> Keeper_event_queue.enqueue queue source
    |> fun queue -> Keeper_event_queue.enqueue queue same_post_id_source
  in
  let duplicate_state =
    Keeper_event_queue_state.empty
    |> Keeper_event_queue_state.with_revision 23L
    |> Keeper_event_queue_state.with_pending duplicate_post_id_queue
  in
  let selections =
    Keeper_event_queue_state.pending_selections duplicate_state
  in
  let refs =
    List.map
      (fun (selection : Keeper_event_queue_state.pending_selection) ->
         Keeper_event_queue_state.source_snapshot_ref selection.source)
      selections
  in
  check int "duplicate post ids retain two exact source refs" 2
    (List.sort_uniq String.compare refs |> List.length);
  let quarantine_path =
    "/api/v1/keepers/fixture-keeper/board-attention/quarantines/ba-root-123/recovery"
  in
  (match
     Server_dashboard_http_keeper_api.classify_keeper_post_route quarantine_path
   with
   | Server_dashboard_http_keeper_api
     .Keeper_post_board_attention_quarantine_recovery route ->
     check string "quarantine route keeper" "fixture-keeper" route.keeper_name;
     check string "quarantine route partition" "ba-root-123" route.partition_id
   | _ -> fail "exact Board quarantine recovery route was not classified");
  check bool "quarantine route rejects extra segments" true
    (Server_dashboard_http_keeper_api.classify_keeper_post_route
       (quarantine_path ^ "/bulk")
     = Server_dashboard_http_keeper_api.Keeper_post_unknown)

let with_test_env f =
  let dir = test_dir () in
	Fun.protect
	  ~finally:(fun () -> cleanup_dir dir)
	  (fun () ->
	    Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Workspace_utils.default_config dir in
      Eio.Switch.run @@ fun sw ->
      Eio_context.with_test_env
        ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env)
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~sw
        (fun () ->
          let request_authority =
            match
              Server_request_authority.of_host_port
                ~host:"localhost"
                ~port:8935
            with
            | Ok authority -> authority
            | Error `Malformed -> fail "test authority must be valid"
          in
          Server_request_authority.with_current request_authority (fun () ->
            f ~env ~sw ~config)))

let test_event_operator_uses_exact_source_refs_across_unrelated_enqueues () =
  with_test_env @@ fun ~env:_ ~sw ~config ->
  let require_ok label = function
    | Ok value -> value
    | Error detail -> failf "%s: %s" label detail
  in
  let require_some label = function
    | Some value -> value
    | None -> fail (label ^ ": missing value")
  in
  let make_meta ~name ~trace_id =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String name
          ; "trace_id", `String trace_id
          ])
    with
    | Error detail -> failf "meta fixture %s: %s" name detail
    | Ok meta -> meta
  in
  let base_path = config.Workspace.base_path in
  let cancel_keeper = "event-source-ref-cancel-source" in
  let orphan_keeper = "event-source-ref-orphan-source" in
  let dormant_keeper = "event-source-ref-dormant-source" in
  let transfer_keeper = "event-source-ref-transfer-source" in
  let target_keeper = "event-source-ref-target" in
  let cancel_meta =
    make_meta ~name:cancel_keeper ~trace_id:"event-source-ref-cancel-trace"
  in
  let transfer_meta =
    make_meta ~name:transfer_keeper ~trace_id:"event-source-ref-transfer-trace"
  in
  let target_meta =
    make_meta ~name:target_keeper ~trace_id:"event-source-ref-target-trace"
  in
  let dormant_meta =
    make_meta ~name:dormant_keeper ~trace_id:"event-source-ref-dormant-trace"
  in
  let stimulus post_id arrived_at : Keeper_event_queue.stimulus =
    { post_id; urgency = Normal; arrived_at; payload = Bootstrap }
  in
  let cancelled_source = stimulus "event-source-ref-cancel" 1.0 in
  let orphan_source = stimulus "event-source-ref-orphan" 1.5 in
  let dormant_source = stimulus "event-source-ref-dormant" 1.75 in
  let transferred_source = stimulus "event-source-ref-transfer" 2.0 in
  let unrelated_source = stimulus "event-source-ref-unrelated" 3.0 in
  let later_unrelated_source = stimulus "event-source-ref-later" 4.0 in
  let load_state keeper_name =
    Keeper_event_queue_persistence.load_state_result ~base_path ~keeper_name
    |> require_ok ("load event queue state for " ^ keeper_name)
  in
  let enqueue keeper_name (source : Keeper_event_queue.stimulus) =
    Keeper_event_queue_persistence.update_result
      ~base_path
      ~keeper_name
      (fun pending -> Keeper_event_queue.enqueue pending source)
    |> require_ok ("enqueue " ^ source.post_id)
  in
  let selection_for (source : Keeper_event_queue.stimulus) state =
    Keeper_event_queue_state.select_when
      ~now:(Unix.gettimeofday ())
      ~ready:(Keeper_event_queue.stimulus_identity_equal source)
      state
    |> require_some ("select " ^ source.post_id)
  in
  let result_status json =
    match Yojson.Safe.Util.member "status" json with
    | `String status -> status
    | _ -> fail "event operator result omitted status"
  in
  let state = Lib.Mcp_server.For_testing.create_state ~base_path in
  let post_event_operator ~keeper_name body =
    let output = Buffer.create 512 in
    let connection =
      Httpun.Server_connection.create (fun reqd ->
        Server_dashboard_http_keeper_event_queue_operator.handle_post
          state
          ~actor:"event-source-ref-test"
          (Httpun.Reqd.request reqd)
          reqd
          ~keeper_name
          body)
    in
    let request =
      Printf.sprintf
        "POST /api/v1/keepers/%s/events/operator HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n%s"
        keeper_name
        (String.length body)
        body
    in
    let input =
      Bigstringaf.of_string ~off:0 ~len:(String.length request) request
    in
    ignore
      (Httpun.Server_connection.read_eof
         connection
         input
         ~off:0
         ~len:(Bigstringaf.length input));
    let rec drain () =
      match Httpun.Server_connection.next_write_operation connection with
      | `Write iovecs ->
        let bytes =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
              Buffer.add_string
                output
                (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
              total + iov.len)
            0
            iovecs
        in
        Httpun.Server_connection.report_write_result connection (`Ok bytes);
        drain ()
      | `Yield | `Close _ -> ()
    in
    drain ();
    let raw = Buffer.contents output in
    let response_body =
      match List.rev (String.split_on_char '\n' raw) with
      | body :: _ -> String.trim body
      | [] -> fail "event operator HTTP response has no body"
    in
    raw, Yojson.Safe.from_string response_body
  in
  let request_body
        action
        (selection : Keeper_event_queue_state.pending_selection)
        fields
    =
    `Assoc
      ([ "schema", `String "keeper_event_queue.operator.request.v2"
       ; "action", `String action
       ; ( "source_incarnation"
         , `String (Int64.to_string selection.admitted_revision) )
       ; ( "source_ref"
         , `String
             (Keeper_event_queue_state.source_snapshot_ref
                selection.source) )
       ]
       @ fields)
    |> Yojson.Safe.to_string
  in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.For_testing.unregister ~base_path cancel_keeper;
      Masc.Keeper_registry.For_testing.unregister ~base_path transfer_keeper;
      Masc.Keeper_registry.For_testing.unregister ~base_path target_keeper)
    (fun () ->
       Masc.Keeper_meta_store.replace_snapshot config cancel_meta
       |> require_ok "persist cancellation source keeper metadata";
       Masc.Keeper_meta_store.replace_snapshot config transfer_meta
       |> require_ok "persist transfer source keeper metadata";
       Masc.Keeper_meta_store.replace_snapshot config target_meta
       |> require_ok "persist target keeper metadata";
       (match
          Masc.Keeper_owner_registry.install_from_store
            ~sw
            ~operation_runner:None
           ~on_turn_slot_released:None
            config
        with
        | Ok _ -> ()
        | Error error ->
          fail (Masc.Keeper_owner_registry.install_error_to_string error));
       ignore
         (Masc.Keeper_registry.For_testing.register
            ~base_path
            cancel_keeper
            cancel_meta);
       ignore
         (Masc.Keeper_registry.For_testing.register
            ~base_path
            transfer_keeper
            transfer_meta);
       enqueue cancel_keeper cancelled_source;
       enqueue transfer_keeper transferred_source;
       let cancel_selection =
         load_state cancel_keeper |> selection_for cancelled_source
       in
       enqueue cancel_keeper unrelated_source;
       let cancel_request =
         request_body
           "cancel"
           cancel_selection
           [ ( "operator_operation_id"
             , `String "event-source-ref-cancel-operation" )
           ; "reason", `String "operator cancelled exact source"
           ]
       in
       let cancel_raw, cancel_response =
         post_event_operator ~keeper_name:cancel_keeper cancel_request
       in
       check bool "cancellation HTTP request succeeds" true
         (String.starts_with ~prefix:"HTTP/1.1 200" cancel_raw);
       check string "cancellation applies once" "applied"
         (cancel_response |> Yojson.Safe.Util.member "result" |> result_status);
       check bool "cancellation removes only the selected source" false
         (Keeper_event_queue_state.pending (load_state cancel_keeper)
          |> Keeper_event_queue.to_list
          |> List.exists (fun source ->
            Keeper_event_queue.stimulus_identity_equal
              cancel_selection.source
              source));
       check bool "unrelated enqueue survives cancellation" true
         (Keeper_event_queue_state.pending (load_state cancel_keeper)
          |> Keeper_event_queue.to_list
          |> List.exists (fun source ->
            Keeper_event_queue.stimulus_identity_equal
              unrelated_source
              source));
       let cancel_replay_raw, cancel_replay_response =
         post_event_operator ~keeper_name:cancel_keeper cancel_request
       in
       check bool "cancellation replay HTTP request succeeds" true
         (String.starts_with ~prefix:"HTTP/1.1 200" cancel_replay_raw);
       check string "cancellation replay uses its durable receipt"
         "already_applied"
         (cancel_replay_response
          |> Yojson.Safe.Util.member "result"
          |> result_status);
       enqueue orphan_keeper orphan_source;
       let orphan_selection =
         load_state orphan_keeper |> selection_for orphan_source
       in
       let orphan_cancel_request =
         request_body
           "cancel"
           orphan_selection
           [ ( "operator_operation_id"
             , `String "event-source-ref-orphan-cancel-operation" )
           ; "reason", `String "source keeper was removed"
           ]
       in
       let orphan_raw, orphan_response =
         post_event_operator
           ~keeper_name:orphan_keeper
           orphan_cancel_request
       in
       check bool "orphan cancellation HTTP request succeeds" true
         (String.starts_with ~prefix:"HTTP/1.1 200" orphan_raw);
       check string "orphan cancellation applies once" "applied"
         (orphan_response |> Yojson.Safe.Util.member "result" |> result_status);
       check int "orphan cancellation removes the exact source" 0
         (Keeper_event_queue_state.pending (load_state orphan_keeper)
          |> Keeper_event_queue.length);
       let orphan_replay_raw, orphan_replay_response =
         post_event_operator
           ~keeper_name:orphan_keeper
           orphan_cancel_request
       in
       check bool "orphan cancellation replay succeeds" true
         (String.starts_with ~prefix:"HTTP/1.1 200" orphan_replay_raw);
       check string "orphan replay uses its durable receipt"
         "already_applied"
         (orphan_replay_response
          |> Yojson.Safe.Util.member "result"
          |> result_status);
       check bool "orphan cancellation releases lifecycle reservation" true
         (Option.is_none
            (Masc.Keeper_lifecycle_reservation.current
               ~base_path
               ~keeper_name:orphan_keeper));
       Masc.Keeper_meta_store.replace_snapshot config dormant_meta
       |> require_ok "persist dormant keeper metadata";
       enqueue dormant_keeper dormant_source;
       let dormant_selection =
         load_state dormant_keeper |> selection_for dormant_source
       in
       let dormant_request =
         request_body
           "cancel"
           dormant_selection
           [ ( "operator_operation_id"
             , `String "event-source-ref-dormant-cancel-operation" )
           ; "reason", `String "must not cancel a dormant keeper"
           ]
       in
       let dormant_raw, _ =
         post_event_operator ~keeper_name:dormant_keeper dormant_request
       in
       check bool "dormant keeper cancellation is rejected" true
         (String.starts_with ~prefix:"HTTP/1.1 409" dormant_raw);
       check int "dormant keeper retains its source" 1
         (Keeper_event_queue_state.pending (load_state dormant_keeper)
          |> Keeper_event_queue.length);
       check bool "rejected cancellation releases lifecycle reservation" true
         (Option.is_none
            (Masc.Keeper_lifecycle_reservation.current
               ~base_path
               ~keeper_name:dormant_keeper));
       let transfer_selection =
         load_state transfer_keeper |> selection_for transferred_source
       in
       enqueue transfer_keeper later_unrelated_source;
       let transfer_request =
         request_body
           "transfer"
           transfer_selection
           [ ( "operator_operation_id"
             , `String "event-source-ref-transfer-operation" )
           ; "target_keeper", `String target_keeper
         ]
       in
       let target_shutdown_operation_id =
         Masc.Keeper_shutdown_types.Operation_id.generate ()
       in
       (match
          Masc.Keeper_owner_registry.begin_shutdown
            ~base_path
            ~keeper_name:target_keeper
            ~operation_id:target_shutdown_operation_id
        with
        | Ok (Masc.Keeper_owner.Shutdown_reserved _) -> ()
        | Ok (Masc.Keeper_owner.Shutdown_already_reserved _) ->
          fail "fresh target shutdown reservation was already owned"
        | Error error ->
          fail (Masc.Keeper_owner_registry.command_error_to_string error));
       let fenced_raw, _fenced_response =
         Fun.protect
           ~finally:(fun () ->
             match
               Masc.Keeper_owner_registry.rollback_shutdown
                 ~base_path
                 ~keeper_name:target_keeper
                 ~operation_id:target_shutdown_operation_id
             with
             | Ok Masc.Keeper_owner.Shutdown_rolled_back -> ()
             | Ok Masc.Keeper_owner.Shutdown_not_reserved
             | Ok (Masc.Keeper_owner.Shutdown_reserved_by_other _)
             | Error _ ->
               fail "target shutdown reservation was not released")
           (fun () ->
              post_event_operator
                ~keeper_name:transfer_keeper
                transfer_request)
       in
       check bool "target-fenced transfer request is rejected" true
         (String.starts_with ~prefix:"HTTP/1.1 409" fenced_raw);
       let fenced_source = load_state transfer_keeper in
       check bool "target fence retains the exact source" true
         (Keeper_event_queue_state.pending fenced_source
          |> Keeper_event_queue.to_list
          |> List.exists (fun source ->
            Keeper_event_queue.stimulus_identity_equal
              transfer_selection.source
              source));
       check int "target fence creates no source outbox" 0
         (Keeper_event_queue_state.transition_outbox fenced_source
          |> List.length);
       check int "target fence creates no target projection" 0
         (Keeper_event_queue_state.pending (load_state target_keeper)
          |> Keeper_event_queue.length);
       let transfer_raw, transfer_response =
         post_event_operator ~keeper_name:transfer_keeper transfer_request
       in
       check bool "transfer HTTP request succeeds" true
         (String.starts_with ~prefix:"HTTP/1.1 200" transfer_raw);
       check string "transfer applies once" "applied"
         (transfer_response
          |> Yojson.Safe.Util.member "result"
          |> result_status);
       let transfer_replay_raw, transfer_replay_response =
         post_event_operator ~keeper_name:transfer_keeper transfer_request
       in
       check bool "transfer replay HTTP request succeeds" true
         (String.starts_with ~prefix:"HTTP/1.1 200" transfer_replay_raw);
       check string "transfer replay uses its durable receipt"
         "already_applied"
         (transfer_replay_response
          |> Yojson.Safe.Util.member "result"
          |> result_status);
       let target_pending =
         load_state target_keeper
         |> Keeper_event_queue_state.pending
         |> Keeper_event_queue.to_list
       in
       check int "transfer replay projects one target source" 1
         (List.length target_pending);
       check bool "target projection contains the exact transfer" true
         (match target_pending with
          | [ source ] ->
            Keeper_event_queue.stimulus_identity_equal
              transferred_source
              source
          | [] | _ :: _ :: _ -> false))

let test_run_dashboard_compute_without_pool_stays_in_current_domain () =
  with_test_env @@ fun ~env ~sw ~config ->
  let caller_domain = Domain.self () in
  let result_domain =
    Server_dashboard_http_core.run_dashboard_compute
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      ~config
      (fun ~config:_ ~sw:_ -> Domain.self ())
  in
  check bool "no pool keeps compute on caller domain" true
    (result_domain = caller_domain)

let test_run_dashboard_compute_with_pool_uses_executor_domain () =
  (* All backends offload to the executor pool when available.
     FileSystem key_index is domain-safe via Stdlib.Mutex; Eio.Mutex
     is domain-safe via Stdlib.Mutex internally.  Offloading isolates
     dashboard compute from keeper turns on the main domain. *)
  with_test_env @@ fun ~env ~sw ~config ->
  let exec_pool =
    Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env)
  in
  Executor_pool_ref.For_testing.with_pool exec_pool @@ fun () ->
  let caller_domain = Domain.self () in
  let result_domain =
    Server_dashboard_http_core.run_dashboard_compute
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      ~config
      (fun ~config:_ ~sw:_ -> Domain.self ())
  in
  check bool "non-PG backend offloads to executor pool domain" true
    (result_domain <> caller_domain)

let test_run_dashboard_compute_nested_cache_does_not_starve () =
  with_test_env @@ fun ~env ~sw ~config ->
  Dashboard_cache.invalidate_all ();
  let clock = Eio.Stdenv.clock env in
  let exec_pool =
    Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env)
  in
  Executor_pool_ref.For_testing.with_pool exec_pool @@ fun () ->
  let result =
    Server_dashboard_http_core.run_dashboard_compute
      ~sw
      ~clock
      ~config
      (fun ~config:_ ~sw:_ ->
         Dashboard_cache.get_or_compute_with_timeout
           "dashboard-runtime-nested-cache"
           ~ttl:60.0
           ~clock
           ~timeout_sec:0.05
           (fun () -> `String "ok"))
  in
  check string "nested cache compute completes on the current worker"
    "ok"
    Yojson.Safe.Util.(result |> to_string)

let test_dashboard_shell_http_json_includes_paths () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let json = Server_dashboard_http_core.dashboard_shell_http_json config in
  let open Yojson.Safe.Util in
  let fields =
    match json with
    | `Assoc fields -> fields
    | _ -> Alcotest.fail "dashboard shell payload must be an object"
  in
  let paths =
    match List.assoc_opt "paths" fields with
    | Some value -> value
    | None -> Alcotest.fail "paths key missing from dashboard shell payload"
  in
  let config_resolution =
    List.assoc_opt "config_resolution" fields
    |> Option.value ~default:`Null
  in
  let runtime_resolution =
    List.assoc_opt "runtime_resolution" fields
    |> Option.value ~default:`Null
  in
  let effective_base_path = paths |> member "effective_base_path" |> to_string in
  let effective_masc_root = paths |> member "effective_masc_root" |> to_string in
  let expected_masc_root = Unix.realpath (Filename.concat config.base_path Common.masc_dirname) in
  check bool "paths present" true
    (match paths with `Assoc _ -> true | _ -> false);
  check bool "paths key present" true
    (List.mem_assoc "paths" fields);
  check bool "config_resolution key present" true
    (List.mem_assoc "config_resolution" fields);
  check bool "runtime_resolution key present" true
    (List.mem_assoc "runtime_resolution" fields);
  check string "effective_base_path matches config" (Unix.realpath config.base_path)
    effective_base_path;
  check string "effective_masc_root matches config" expected_masc_root
    effective_masc_root;
  check bool "paths include cwd" true
    (match paths |> member "cwd" with
     | `String value -> String.length value > 0
     | _ -> false);
  check bool "paths include strict_mode_requested bool" true
    (match paths |> member "strict_mode_requested" with
     | `Bool _ -> true
     | _ -> false);
  check bool "paths include startup_rejected bool" true
    (match paths |> member "startup_rejected" with
     | `Bool _ -> true
     | _ -> false);
  check bool "shell config resolution is object or null" true
    (match config_resolution with
     | `Assoc _ | `Null -> true
     | _ -> false);
  check bool "shell config root path surfaced when available" true
    (match config_resolution with
     | `Null -> true
     | _ -> nested_path_string_present_or_null config_resolution "config_root");
  check bool "shell runtime authoring path surfaced when available" true
    (match config_resolution with
     | `Null -> true
     | _ ->
       nested_path_string_present_or_null config_resolution "runtime_authoring");
  check bool "shell runtime resolution is object or null" true
    (match runtime_resolution with
     | `Assoc _ | `Null -> true
     | _ -> false);
  check bool "shell runtime data root path surfaced when available" true
    (match runtime_resolution with
     | `Null -> true
     | _ -> nested_path_string_present_or_null runtime_resolution "data_root");
  check bool "shell runtime warnings surfaced as list when available" true
    (match runtime_resolution with
     | `Null -> true
     | _ -> (
         match runtime_resolution |> member "warnings" with
         | `List _ -> true
         | _ -> false));
  let diagnostics = json |> member "projection_diagnostics" in
  check string "shell timing trace finished" "finished"
    (diagnostics |> member "projection_timing_status" |> to_string);
  check bool "shell timing top populated" true
    ((diagnostics |> member "projection_timing_top" |> to_list |> List.length)
     > 0)

let test_dashboard_shell_http_json_prefers_preserved_base_path_input () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let raw_input = Filename.concat config.base_path Common.masc_dirname in
  with_env "MASC_BASE_PATH_INPUT" raw_input @@ fun () ->
  with_env "MASC_BASE_PATH" config.base_path @@ fun () ->
  let json = Server_dashboard_http_core.dashboard_shell_http_json config in
  let open Yojson.Safe.Util in
  check string "runtime base_path preserves raw input" raw_input
    (json |> member "runtime_resolution" |> member "base_path" |> member "path"
   |> to_string)

let test_runtime_resolution_accepts_server_repo_inside_base_path () =
  match Lib.Build_identity.repo_root () with
  | None -> fail "Build_identity.repo_root unavailable; cannot test server/base path relation"
  | Some repo_root ->
    let repo_root =
      try Unix.realpath repo_root with
      | Unix.Unix_error _ -> repo_root
    in
    let config = Workspace.default_config (Filename.dirname repo_root) in
    check bool "runtime accepts nested server repo" false
      (Server_dashboard_http_runtime_info.server_workspace_mismatch_for_tests
         ~server_repo_path:repo_root
         config)

let test_dashboard_shell_http_json_uses_bootstrap_payload_while_prewarming () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let original_warmed = Atomic.get Server_dashboard_http.shell_warmed in
  let original_warming = Atomic.get Server_dashboard_http.shell_warming in
  let original_last_good = Atomic.get Server_dashboard_http.last_good_shell in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Server_dashboard_http.shell_warmed original_warmed;
      Atomic.set Server_dashboard_http.shell_warming original_warming;
      Atomic.set Server_dashboard_http.last_good_shell original_last_good)
    (fun () ->
      Atomic.set Server_dashboard_http.shell_warmed false;
      Atomic.set Server_dashboard_http.shell_warming true;
      Atomic.set Server_dashboard_http.last_good_shell (`Assoc []);
      let json =
        Server_dashboard_http_core.dashboard_shell_http_json
          ~request:(request "/api/v1/dashboard/shell")
          config
      in
      let open Yojson.Safe.Util in
      check string "bootstrap status project" "initializing"
        (json |> member "status" |> member "project" |> to_string);
      check int "bootstrap zero agents" 0
        (json |> member "counts" |> member "agents" |> to_int);
      check string "bootstrap cache state" "initializing"
        (json |> member "projection_diagnostics" |> member "cache_state"
        |> to_string))

let test_dashboard_shell_http_json_prefers_last_good_while_prewarming () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let original_warmed = Atomic.get Server_dashboard_http.shell_warmed in
  let original_warming = Atomic.get Server_dashboard_http.shell_warming in
  let original_last_good = Atomic.get Server_dashboard_http.last_good_shell in
  let last_good =
    `Assoc
      [
        ("generated_at", `String "2026-04-17T00:00:00Z");
        ("status", `Assoc [("project", `String "warm-workspace")]);
        ("counts", `Assoc [("agents", `Int 7); ("tasks", `Int 11); ("keepers", `Int 3)]);
      ]
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Server_dashboard_http.shell_warmed original_warmed;
      Atomic.set Server_dashboard_http.shell_warming original_warming;
      Atomic.set Server_dashboard_http.last_good_shell original_last_good)
    (fun () ->
      Atomic.set Server_dashboard_http.shell_warmed false;
      Atomic.set Server_dashboard_http.shell_warming true;
      Atomic.set Server_dashboard_http.last_good_shell last_good;
      let json =
        Server_dashboard_http_core.dashboard_shell_http_json
          ~request:(request "/api/v1/dashboard/shell")
          config
      in
      let open Yojson.Safe.Util in
      check string "last-good project reused" "warm-workspace"
        (json |> member "status" |> member "project" |> to_string);
      check int "last-good counts reused" 7
        (json |> member "counts" |> member "agents" |> to_int))

let test_dashboard_shell_http_json_records_light_last_good () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let original_light_last_good =
    Atomic.get Server_dashboard_http.last_good_shell_light
  in
  Fun.protect
    ~finally:(fun () ->
      Dashboard_cache.invalidate_all ();
      Atomic.set
        Server_dashboard_http.last_good_shell_light
        original_light_last_good)
    (fun () ->
      Dashboard_cache.invalidate_all ();
      Atomic.set Server_dashboard_http.last_good_shell_light (`Assoc []);
      let json =
        Server_dashboard_http_core.dashboard_shell_http_json ~light:true config
      in
      let cached = Atomic.get Server_dashboard_http.last_good_shell_light in
      let open Yojson.Safe.Util in
      check bool "light last-good populated" true (cached = json);
      check bool "cached payload is light shell" true
        (cached
         |> member "projection_diagnostics"
         |> member "light"
         |> to_bool))

let test_dashboard_shell_http_json_prefers_light_last_good_while_prewarming () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let original_warmed = Atomic.get Server_dashboard_http.shell_warmed in
  let original_warming = Atomic.get Server_dashboard_http.shell_warming in
  let original_last_good = Atomic.get Server_dashboard_http.last_good_shell in
  let original_light_last_good =
    Atomic.get Server_dashboard_http.last_good_shell_light
  in
  let full_last_good =
    `Assoc
      [
        ("status", `Assoc [("project", `String "full-workspace")]);
        ("counts", `Assoc [("agents", `Int 9)]);
      ]
  in
  let light_last_good =
    `Assoc
      [
        ("status", `Assoc [("project", `String "light-workspace")]);
        ("counts", `Assoc [("agents", `Int 2)]);
        ("projection_diagnostics", `Assoc [("light", `Bool true)]);
      ]
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Server_dashboard_http.shell_warmed original_warmed;
      Atomic.set Server_dashboard_http.shell_warming original_warming;
      Atomic.set Server_dashboard_http.last_good_shell original_last_good;
      Atomic.set
        Server_dashboard_http.last_good_shell_light
        original_light_last_good)
    (fun () ->
      Atomic.set Server_dashboard_http.shell_warmed false;
      Atomic.set Server_dashboard_http.shell_warming true;
      Atomic.set Server_dashboard_http.last_good_shell full_last_good;
      Atomic.set Server_dashboard_http.last_good_shell_light light_last_good;
      let json =
        Server_dashboard_http_core.dashboard_shell_http_json
          ~request:(request "/api/v1/dashboard/shell?light=1")
          ~light:true
          config
      in
      let open Yojson.Safe.Util in
      check string "light last-good project reused" "light-workspace"
        (json |> member "status" |> member "project" |> to_string);
      check int "light last-good counts reused" 2
        (json |> member "counts" |> member "agents" |> to_int);
      check bool "light diagnostics preserved" true
        (json
         |> member "projection_diagnostics"
         |> member "light"
         |> to_bool))

let test_operator_snapshot_default_route_hydrates_first_success () =
  with_test_env @@ fun ~env ~sw ~config ->
  Dashboard_cache.invalidate_all ();
  Operator_control.invalidate_snapshot_cache ();
  Dashboard_projection_cache.invalidate_snapshot_json ~config;
  let before =
    Server_dashboard_http_core_operator.operator_snapshot_publication ()
  in
  check bool "invalidation clears the prior successful publication" false
    before.has_success;
  let state =
    Lib.Mcp_server_eio.For_testing.create_state ~base_path:config.base_path ()
  in
  let json =
    Server_dashboard_http_core.operator_snapshot_http_json
      ~state
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      ~broadcast_snapshot:(fun _publication -> ())
      (request "/api/v1/operator")
  in
  let after =
    Server_dashboard_http_core_operator.operator_snapshot_publication ()
  in
  check bool "first default request publishes a successful snapshot" true
    after.has_success;
  check int "first success stays in the invalidated generation"
    before.generation after.generation;
  check string "HTTP returns the canonical first-success publication"
    (Yojson.Safe.to_string
       (Server_dashboard_http_core_operator.operator_snapshot_publication_json
          after))
    (Yojson.Safe.to_string json);
  let open Yojson.Safe.Util in
  check bool "first response is not the initializing placeholder" false
    (json |> member "status" = `String "initializing")

let test_operator_snapshot_publication_rejects_stale_races () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Dashboard_projection_cache.invalidate_snapshot_json ~config;
  let lower =
    Server_dashboard_http_core_operator.begin_operator_snapshot_compute ()
  in
  let higher =
    Server_dashboard_http_core_operator.begin_operator_snapshot_compute ()
  in
  let higher_publication =
    match
      Server_dashboard_http_core_operator.publish_operator_snapshot_if_current
        ~compute:higher
        (`Assoc [ "winner", `String "higher" ])
    with
    | Some publication -> publication
    | None -> fail "higher sequence did not publish"
  in
  check bool "lower success is rejected after higher terminalization" true
    (Option.is_none
       (Server_dashboard_http_core_operator.publish_operator_snapshot_if_current
          ~compute:lower
          (`Assoc [ "winner", `String "lower" ])));
  check bool "lower error is rejected after higher terminalization" true
    (Option.is_none
       (Server_dashboard_http_core_operator.mark_operator_snapshot_error_if_current
          ~compute:lower
          (Failure "late lower error")));
  let canonical =
    Server_dashboard_http_core_operator.operator_snapshot_publication ()
  in
  check int "higher compute remains canonical"
    higher_publication.compute_sequence canonical.compute_sequence;
  let old_generation_compute =
    Server_dashboard_http_core_operator.begin_operator_snapshot_compute ()
  in
  (* This used to swap the process-global broadcaster and count what arrived on
     it. The broadcaster is an argument now (#25927), so the assertion runs
     against the function the observer actually calls: one invalidation yields
     one publication, and a second read of the same generation yields none. *)
  Dashboard_projection_cache.invalidate_snapshot_json ~config;
  let generation = Dashboard_projection_cache.snapshot_invalidation_generation () in
  let invalidation =
    Server_dashboard_http_core_operator
    .publish_operator_snapshot_invalidation_if_current
      ~generation
  in
  (match invalidation with
   | None -> fail "one invalidation must publish once"
   | Some invalidation ->
     let current =
       Server_dashboard_http_core_operator.operator_snapshot_publication ()
     in
     check int "publication is the canonical generation" current.generation
       invalidation.generation;
     check int "publication is the canonical terminal sequence"
       current.terminal_sequence invalidation.terminal_sequence);
  (* Not "twice returns None": the contract says install *or return*, so a
     second read of the current generation hands back the same tombstone. What
     it refuses is a generation that is no longer current.

     Two guards enforce that — the outer current_generation compare and the
     inner publication.generation compare — so removing either one alone still
     passes here. Removing both fails this case. *)
  check bool "a stale generation does not publish" true
    (Option.is_none
       (Server_dashboard_http_core_operator
        .publish_operator_snapshot_invalidation_if_current
          ~generation:(generation - 1)));
  check bool "old-generation completion is rejected" true
    (Option.is_none
       (Server_dashboard_http_core_operator.publish_operator_snapshot_if_current
          ~compute:old_generation_compute
          (`Assoc [ "winner", `String "old-generation" ])))

let test_operator_snapshot_error_clears_previous_success () =
  let success =
    match
      Server_dashboard_http_core_operator.For_testing
      .publish_operator_snapshot_success
        (`Assoc
          [ "pending_confirm_envelope", `Assoc [ "items", `List [] ]
          ; "generated_at", `String "2026-08-08T00:00:00Z"
          ])
    with
    | Some publication -> publication
    | None -> fail "operator snapshot success did not publish"
  in
  check bool "precondition has a successful snapshot" true success.has_success;
  let compute =
    Server_dashboard_http_core_operator.begin_operator_snapshot_compute ()
  in
  let failed =
    match
      Server_dashboard_http_core_operator.mark_operator_snapshot_error_if_current
        ~compute
        (Failure "pending-confirm store unreadable")
    with
    | Some publication -> publication
    | None -> fail "operator snapshot error did not publish"
  in
  check bool "failed publication has no last success" false failed.has_success;
  let open Yojson.Safe.Util in
  check string "failed publication is unavailable" "unavailable"
    (failed.json |> member "status" |> to_string);
  check bool "failed publication does not retain pending rows" true
    (failed.json |> member "pending_confirm_envelope" = `Null)

let test_operator_snapshot_http_rejects_stale_success_after_store_error () =
  with_test_env @@ fun ~env ~sw ~config ->
  let state =
    Lib.Mcp_server_eio.For_testing.create_state ~base_path:config.base_path ()
  in
  let path = Operator_control.pending_confirms_path config in
  (match Workspace_utils.write_json_result config path (`List []) with
   | Ok () -> ()
   | Error reason -> fail reason);
  let stale =
    match
      Server_dashboard_http_core_operator.For_testing
      .publish_operator_snapshot_success
        ~fresh_for_s:(-1.0)
        (`Assoc
          [ "pending_confirm_envelope", `Assoc [ "items", `List [] ]
          ; "generated_at", `String "2026-08-08T00:00:00Z"
          ])
    with
    | Some publication -> publication
    | None -> fail "stale operator snapshot success did not publish"
  in
  check bool "precondition is stale success" true stale.has_success;
  write_file path "{not-json";
  Operator_control.invalidate_snapshot_cache ();
  let json =
    Server_dashboard_http_core.operator_snapshot_http_json
      ~state
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      ~broadcast_snapshot:(fun _publication -> ())
      (request "/api/v1/operator")
  in
  let open Yojson.Safe.Util in
  check string "HTTP returns unavailable publication" "unavailable"
    (json |> member "status" |> to_string);
  check bool "HTTP drops pending rows" true
    (json |> member "pending_confirm_envelope" = `Null)

let test_dashboard_query_cache_segment_normalizes_missing_values () =
  check string "missing none" "missing"
    (Server_dashboard_http_core_cache.dashboard_query_cache_segment None);
  check string "missing blank" "missing"
    (Server_dashboard_http_core_cache.dashboard_query_cache_segment (Some "  "));
  check string "trimmed value" "keeper-a"
    (Server_dashboard_http_core_cache.dashboard_query_cache_segment (Some " keeper-a "))

let test_dashboard_query_cache_key_partitions_route_params () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let session_a =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "default"); ("session", Some "session-a") ]
      in
      let session_b =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "default"); ("session", Some "session-b") ]
      in
      let actor_b =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "keeper-b"); ("session", Some "session-a") ]
      in
      check bool "session_id partitions route cache" true
        (not (String.equal session_a session_b));
      check bool "actor partitions route cache" true
        (not (String.equal session_a actor_b));
      (* The partition is the directory the cached state lives in, so a
         scope switch cannot serve the previous workspace's projection
         (#24504). It used to be the constant "default". *)
      check string "deterministic key shape"
        (Printf.sprintf
           "session:%s:[[\"actor\",\"default\"],[\"session\",\"session-a\"]]"
           (Workspace_utils.masc_root_dir config))
        session_a)

(* Two clusters can share a base path — the store separates them under
   .masc/clusters/<name>. The cache partition was the constant "default", so
   the keys did not, and a scope switch could serve the previous workspace's
   projection (#24504). *)
let test_dashboard_cache_key_partitions_by_cluster () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let other_cluster =
        { config with
          backend_config =
            { config.Workspace_utils.backend_config with
              Backend_types.cluster_name = "cluster-b"
            }
        }
      in
      check bool "the two configs share a base path" true
        (String.equal config.Workspace_utils.base_path
           other_cluster.Workspace_utils.base_path);
      check bool "but their cache keys differ" true
        (not
           (String.equal
              (Server_dashboard_http_core_cache.dashboard_cache_key config
                 "session" "s")
              (Server_dashboard_http_core_cache.dashboard_cache_key
                 other_cluster "session" "s"))))

let test_dashboard_query_cache_key_encodes_delimiter_values () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Workspace_utils.default_config dir in
      let actor_delimiter =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "default:session=session-a")
          ; ("session", Some "session-b")
          ]
      in
      let session_delimiter =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "default")
          ; ("session", Some "session-a:session=session-b")
          ]
      in
      let missing_session =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "default"); ("session", None) ]
      in
      let literal_missing_session =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "default"); ("session", Some "missing") ]
      in
      let missing_actor =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", None); ("session", Some "session-a") ]
      in
      let explicit_default_actor =
        Server_dashboard_http_core_cache.dashboard_query_cache_key config "session"
          [ ("actor", Some "default"); ("session", Some "session-a") ]
      in
      check bool "delimiter-bearing values do not collide" true
        (not (String.equal actor_delimiter session_delimiter));
      check bool "literal missing does not collide with absent value" true
        (not (String.equal missing_session literal_missing_session));
      check bool "missing actor does not collide with explicit default actor" true
        (not (String.equal missing_actor explicit_default_actor)))

let test_operator_snapshot_default_route_exposes_provenance () =
  with_test_env @@ fun ~env ~sw ~config ->
  let state =
    Lib.Mcp_server_eio.For_testing.create_state ~base_path:config.base_path ()
  in
  let seed =
    `Assoc
      [ "available_actions", `List []
      ; "keepers", `List []
      ; "generated_at", `String "2026-05-15T00:00:00Z"
      ]
    |> Server_dashboard_http_core_operator_query.with_operator_snapshot_metadata
         ~config
         ~query:
           (Server_dashboard_http_core_operator_query
            .operator_snapshot_default_query ())
  in
  let publication =
    match
      Server_dashboard_http_core_operator.For_testing
      .publish_operator_snapshot_success
        seed
    with
    | Some publication -> publication
    | None -> fail "canonical operator snapshot test publication was superseded"
  in
  let current, is_fresh =
    Server_dashboard_http_core_operator.operator_snapshot_publication_with_freshness ()
  in
  check bool "canonical publication is fresh" true is_fresh;
  check int
    "canonical publication identity retained"
    publication.compute_sequence
    current.compute_sequence;
  let json =
    Server_dashboard_http_core.operator_snapshot_http_json
      ~state
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      ~broadcast_snapshot:(fun _publication -> ())
      (request "/api/v1/operator")
  in
  check string
    "HTTP serves the canonical publication byte-for-byte"
    (Yojson.Safe.to_string
       (Server_dashboard_http_core_operator.operator_snapshot_publication_json
          publication))
    (Yojson.Safe.to_string json);
  let open Yojson.Safe.Util in
  check string "surface" "/api/v1/operator"
    (json |> member "dashboard_surface" |> to_string);
  check string "source" "operator_snapshot_read_model"
    (json |> member "source" |> to_string);
  check string "generated_at_iso" "2026-05-15T00:00:00Z"
    (json |> member "generated_at_iso" |> to_string);
  check string "retention scope" "operator_snapshot"
    (json |> member "retention" |> member "scope" |> to_string);
  check string "retention store" "process_cache"
    (json |> member "retention" |> member "store_kind" |> to_string);
  check string "query effective actor" "dashboard"
    (json |> member "query" |> member "effective_actor" |> to_string);
  check bool "query default summary" true
    (json |> member "query" |> member "default_summary_request" |> to_bool);
  check bool "query includes keepers" true
    (json |> member "query" |> member "include_keepers" |> to_bool);
  check bool "request cache metadata absent" true
    (json |> member "cache" = `Null);
  let stale_publication =
    match
      Server_dashboard_http_core_operator.For_testing
      .publish_operator_snapshot_success
        ~fresh_for_s:(-1.0)
        seed
    with
    | Some publication -> publication
    | None -> fail "stale canonical operator snapshot test publication was superseded"
  in
  let current, is_fresh =
    Server_dashboard_http_core_operator.operator_snapshot_publication_with_freshness ()
  in
  check bool "expired canonical publication is stale" false is_fresh;
  check int
    "stale publication remains canonical"
    stale_publication.compute_sequence
    current.compute_sequence

let test_operator_digest_default_route_exposes_provenance () =
  with_test_env @@ fun ~env ~sw ~config ->
  let state =
    Lib.Mcp_server_eio.For_testing.create_state ~base_path:config.base_path ()
  in
  let seed =
    `Assoc
      [ "health", `String "ok"
      ; "generated_at", `String "2026-05-15T00:00:01Z"
      ]
  in
  with_cached_surface_success Server_dashboard_http_core_operator.operator_digest_cache seed
  @@ fun () ->
  match
    Server_dashboard_http_core.operator_digest_http_json
      ~state
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      (request "/api/v1/operator/digest")
  with
  | Error _ -> Alcotest.fail "operator digest default route returned error"
  | Ok json ->
    let open Yojson.Safe.Util in
    check string "surface" "/api/v1/operator/digest"
      (json |> member "dashboard_surface" |> to_string);
    check string "source" "operator_digest_read_model"
      (json |> member "source" |> to_string);
    check string "generated_at_iso" "2026-05-15T00:00:01Z"
      (json |> member "generated_at_iso" |> to_string);
    check string "retention scope" "operator_digest"
      (json |> member "retention" |> member "scope" |> to_string);
    check string "retention store" "process_cache"
      (json |> member "retention" |> member "store_kind" |> to_string);
    check string "query effective target" "workspace"
      (json |> member "query" |> member "effective_target_type" |> to_string);
    check bool "query default namespace" true
      (json |> member "query" |> member "default_namespace_request" |> to_bool);
    check string "cache state" "fresh"
      (json |> member "projection_diagnostics" |> member "cache_state" |> to_string)

let test_dashboard_shell_timeout_fallback_reports_timing_context () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let original_warmed = Atomic.get Server_dashboard_http.shell_warmed in
  let original_warming = Atomic.get Server_dashboard_http.shell_warming in
  let original_last_good = Atomic.get Server_dashboard_http.last_good_shell in
  Fun.protect
    ~finally:(fun () ->
      Dashboard_cache.invalidate_all ();
      Atomic.set Server_dashboard_http.shell_warmed original_warmed;
      Atomic.set Server_dashboard_http.shell_warming original_warming;
      Atomic.set Server_dashboard_http.last_good_shell original_last_good)
    (fun () ->
      Dashboard_cache.invalidate_all ();
      Atomic.set Server_dashboard_http.shell_warmed true;
      Atomic.set Server_dashboard_http.shell_warming false;
      Atomic.set Server_dashboard_http.last_good_shell (`Assoc []);
      let cache_key =
        Server_dashboard_http_core.dashboard_shell_cache_key config
      in
      ignore
        (Dashboard_cache.get_or_compute cache_key ~ttl:15.0 (fun () ->
             `Assoc
               [
                 ("error", `String "computation_timeout");
                 ("key", `String cache_key);
               ]));
      let json = Server_dashboard_http_core.dashboard_shell_http_json config in
      let open Yojson.Safe.Util in
      let diagnostics = json |> member "projection_diagnostics" in
      check string "timeout fallback cache state" "timeout_fallback"
        (diagnostics |> member "cache_state" |> to_string);
      check string "timeout fallback source" "bootstrap"
        (diagnostics |> member "fallback_source" |> to_string);
      check string "timeout cache key surfaced" cache_key
        (diagnostics |> member "timeout_cache_key" |> to_string);
      check (float 0.001) "full shell timeout surfaced" 16.0
        (diagnostics |> member "timeout_sec" |> to_float);
      check string "timing absence is explicit" "none"
        (diagnostics |> member "projection_timing_status" |> to_string);
      check int "timing top is empty without an active trace" 0
        (diagnostics |> member "projection_timing_top" |> to_list |> List.length))

(* Both routes below scan a store. Seeding a sentinel under the key the
   projection is supposed to consult, then asserting the projection returns it,
   pins that the cache is actually in the path: without it the call recomputes
   and answers with real data instead of the sentinel.

   Measured before this: scheduled-automation 272 ms cold / 204 ms warm for
   96 KB, agent-activity 105 ms cold / 75 ms warm for 2.2 KB. Neither second
   pass was cheaper than its first, which is what an absent cache looks like
   from outside. *)
let cache_sentinel key = `Assoc [ ("sentinel", `String key) ]

let seed_cache key =
  ignore (Dashboard_cache.get_or_compute key ~ttl:60.0 (fun () -> cache_sentinel key))

let test_scheduled_automation_reads_its_cache_key () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Fun.protect
    ~finally:Dashboard_cache.invalidate_all
    (fun () ->
      Dashboard_cache.invalidate_all ();
      let cache_key =
        Server_dashboard_http_core_cache.dashboard_query_cache_key
          config
          "scheduled_automation"
          []
      in
      seed_cache cache_key;
      check
        (of_pp Yojson.Safe.pp)
        "scheduled-automation is served from its cache key"
        (cache_sentinel cache_key)
        (Server_dashboard_http.dashboard_scheduled_automation_http_json ~config))

(* The exact lookup answers with a closed status, so a blank id is a named
   outcome rather than a not_found that reads like "no such schedule". Pin the
   two the caller can reach without a store: an empty id is invalid_id, and the
   projection stays a function of the clock it is handed. *)
let test_schedule_exact_lookup_rejects_blank_id () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let now = 1_700_000_000.0 in
  let body =
    Server_dashboard_schedule_projection.scheduled_automation_exact_lookup_json
      config
      ~now
      ~schedule_id:"   "
  in
  let field name =
    match body with
    | `Assoc fields ->
      (match List.assoc_opt name fields with Some (`String s) -> Some s | _ -> None)
    | _ -> None
  in
  check (option string) "blank id is named, not not_found" (Some "invalid_id") (field "status");
  check
    (option string)
    "the echoed id is the caller's, untrimmed"
    (Some "   ")
    (field "schedule_id");
  check
    (option string)
    "generated_at uses the same injected projection clock"
    (Some (Masc_domain.iso8601_of_unix_seconds now))
    (field "generated_at")

(* The exact lookup is where a schedule's past is read, because the aggregate
   sends one wake per row and 20 rows of 323. Until this projection carried the
   list, one attempt of the up-to-32 the store keeps was all an operator could
   see. The ceiling travels with the list so a count of three cannot be read as
   "it has only ever woken three times" when the sweep has trimmed. *)
let test_schedule_exact_lookup_carries_the_wake_history () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let schedule_id = "sched-wake-history" in
  let request =
    match
      Schedule_domain.create_request
        ~schedule_id
        ~requested_by:
          { Schedule_domain.id = "requester"
          ; kind = Schedule_domain.Human_operator
          ; display_name = None
          }
        ~scheduled_by:
          { Schedule_domain.id = "scheduler"
          ; kind = Schedule_domain.Human_operator
          ; display_name = None
          }
        ~requested_at:100.0
        ~due_at:200.0
        ~payload:
          (`Assoc
            [ "kind", `String "consumer.note"
            ; "body", `Assoc [ "text", `String "wake history fixture" ]
            ])
        ~source:Schedule_domain.Operator_request
        ~recurrence:(Schedule_domain.Interval { interval_sec = 60 })
        ()
    with
    | Ok request -> request
    | Error msg -> fail msg
  in
  (match Schedule_store.insert_request config request with
   | Ok _ -> ()
   | Error _ -> fail "the fixture schedule could not be inserted");
  let occurrence now =
    (match Schedule_store.refresh_due config ~now with
     | Ok _ -> ()
     | Error _ -> fail "refresh_due refused the fixture");
    (match Schedule_store.start_due_candidate config ~now:(now +. 1.0) ~schedule_id with
     | Ok _ -> ()
     | Error _ -> fail "start_due_candidate refused the fixture");
    match Schedule_store.accept_running config ~now:(now +. 2.0) ~schedule_id () with
    | Ok _ -> ()
    | Error _ -> fail "accept_running refused the fixture"
  in
  occurrence 201.0;
  occurrence 261.0;
  occurrence 321.0;
  let body =
    Server_dashboard_schedule_projection.scheduled_automation_exact_lookup_json
      config
      ~now:400.0
      ~schedule_id
  in
  let open Yojson.Safe.Util in
  check string "the lookup found it" "found" (body |> member "status" |> to_string);
  let wakes = body |> member "wakes" |> to_list in
  check int "every retained occurrence is listed" 3 (List.length wakes);
  let started = List.map (fun w -> w |> member "started_at" |> to_float) wakes in
  check
    (list (float 0.001))
    "newest first"
    (List.sort (fun a b -> Float.compare b a) started)
    started;
  check int "the count states the list it sent" 3
    (body |> member "wake_count" |> to_int);
  check int "and the store's ceiling travels with it"
    Schedule_store.terminal_wakes_retained_per_schedule
    (body |> member "wake_retention_per_schedule" |> to_int)
(* The fleet page caps at 20 rows with active ones first, so a Keeper whose
   schedules are terminal or simply further down is absent from it. The tab
   that filtered that page reported them as non-existent. A target-scoped page
   is what makes them readable, and it must narrow every part of the envelope:
   a scoped page carrying fleet counts would be read as this Keeper's. *)
let test_schedule_page_can_be_scoped_to_one_target () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let actor id =
    { Schedule_domain.id
    ; kind = Schedule_domain.Human_operator
    ; display_name = None
    }
  in
  let insert ~schedule_id ~keeper =
    let payload =
      `Assoc
        [ "kind", `String "masc.keeper_wake"
        ; ( "body"
          , `Assoc
              [ "keeper_name", `String keeper
              ; "message", `String "wake for the scoped page test"
              ] )
        ]
    in
    match
      Schedule_domain.create_request
        ~schedule_id
        ~requested_by:(actor "requester")
        ~scheduled_by:(actor "scheduler")
        ~requested_at:100.0
        ~due_at:200.0
        ~payload
        ~source:Schedule_domain.Operator_request
        ()
    with
    | Ok request ->
      (match Schedule_store.insert_request config request with
       | Ok _ -> ()
       | Error _ -> fail ("could not insert " ^ schedule_id))
    | Error msg -> fail msg
  in
  insert ~schedule_id:"sched-scoped-a" ~keeper:"alpha";
  insert ~schedule_id:"sched-scoped-b" ~keeper:"alpha";
  insert ~schedule_id:"sched-scoped-c" ~keeper:"beta";
  let open Yojson.Safe.Util in
  let scoped =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json
      ~payload_target:"keeper:alpha"
      config
  in
  check int "the scoped page counts only its target" 2
    (scoped |> member "request_count" |> to_int);
  check (list string) "and lists only its target's rows"
    [ "sched-scoped-a"; "sched-scoped-b" ]
    (scoped |> member "requests" |> to_list
     |> List.map (fun row -> row |> member "schedule_id" |> to_string)
     |> List.sort String.compare);
  check (option string) "the response says what it is scoped to"
    (Some "keeper:alpha")
    (scoped |> member "payload_target_selector" |> to_option to_string);
  check int "the scoped limit is its own number"
    Server_dashboard_schedule_projection.schedule_projection_target_request_limit
    (scoped |> member "request_limit" |> to_int);
  let fleet =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json config
  in
  check int "the unscoped page still counts the store" 3
    (fleet |> member "request_count" |> to_int);
  check bool "and does not claim a selector" true
    (fleet |> member "payload_target_selector" = `Null);
  let missing =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json
      ~payload_target:"keeper:nobody"
      config
  in
  (* An empty scoped page is an answer, not a store failure: status stays ok so
     the reader can tell "none for this target" from "could not read". *)
  check string "an empty scope is still a read that succeeded" "ok"
    (missing |> member "status" |> to_string);
  check int "with nothing in it" 0 (missing |> member "request_count" |> to_int)

(* The window selects which rows the scan covers, so two windows must not share
   an entry. Seeding only the 24 h key and asking for 1 h has to miss. *)
let test_agent_activity_keys_on_its_window () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Fun.protect
    ~finally:Dashboard_cache.invalidate_all
    (fun () ->
      Dashboard_cache.invalidate_all ();
      let key_for hours =
        Server_dashboard_http_core_cache.dashboard_query_cache_key
          config
          "agent_activity"
          [ ("hours", Some (string_of_float hours)) ]
      in
      let default_key = key_for 24.0 in
      seed_cache default_key;
      check
        (of_pp Yojson.Safe.pp)
        "the default window is served from its cache key"
        (cache_sentinel default_key)
        (Server_dashboard_http_agent_api.agent_activity_http_json
           ~config ~hours:24.0);
      let other =
        Server_dashboard_http_agent_api.agent_activity_http_json
          ~config ~hours:1.0
      in
      check bool "a different window does not reuse the 24h entry" false
        (Yojson.Safe.equal other (cache_sentinel default_key));
      let open Yojson.Safe.Util in
      check (float 0.001) "the computed window is the one asked for" 1.0
        (other |> member "hours" |> to_float))

let test_dashboard_proof_http_json_surfaces_submission_index () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let module V = Lib.Verification in
  let output =
    `Assoc
      [
        ("evidence_refs", `List [ `String "artifact://proof-route" ]);
        ("task_title", `String "Proof route fixture");
      ]
  in
  (match
     V.create_request
       ~base_path:config.base_path
       ~task_id:"task-proof-route"
       ~output
       ~criteria:[ "proof route must expose verification evidence" ]
       ~worker:"keeper-proof"
       ()
   with
   | Ok _ -> ()
   | Error message -> fail message);
  let json =
    Server_dashboard_http.dashboard_proof_http_json
      ~config
      (request "/api/v1/dashboard/proof?limit=5")
  in
  let open Yojson.Safe.Util in
  check int "verification total" 1
    (json |> member "summary" |> member "verification_total" |> to_int);
  check bool "request status is not synthesized from immutable submissions" true
    (json |> member "summary" |> member "verification_pending" = `Null);
  check bool "rejection status is not synthesized from immutable submissions" true
    (json |> member "summary" |> member "verification_rejected" = `Null);
  check bool "verification requests exposed" true
    (match json |> member "verification" |> member "requests" |> member "requests" with
     | `List [ _ ] -> true
     | _ -> false);
  check bool "proof sources include execution trust route" true
    (json
     |> member "proof_sources"
     |> to_list
     |> List.exists (fun source ->
       String.equal
         (source |> member "route" |> to_string)
         "/api/v1/dashboard/execution-trust"))

let test_dashboard_proof_route_registered_in_http_routers () =
  let http1 = read_file "lib/server/server_routes_http_routes_dashboard.ml" in
  let h2 = read_file "lib/server/server_h2_gateway.ml" in
  check bool "HTTP/1 dashboard proof route registered" true
    (String_util.contains_substring http1 "\"/api/v1/dashboard/proof\"");
  check bool "HTTP/2 dashboard proof route registered" true
    (String_util.contains_substring h2 "\"/api/v1/dashboard/proof\"")

let config_sync_runtime_toml =
  {|[runtime]
default = "test_provider.test_model"
[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"
[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true
[test_provider.test_model]
is-default = true
max-concurrent = 1
max-request-body-bytes = 65536
|}

let execution_trust_keeper_row_keys =
  [ "current_task_id"
  ; "keeper_id"
  ; "name"
  ; "phase"
  ; "pipeline_stage"
  ; "status"
  ; "trace_id"
  ; "trust"
  ]

let test_execution_trust_uses_narrow_keeper_projection () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let runtime_path = Filename.concat config.Workspace.base_path "runtime.toml" in
  write_file runtime_path config_sync_runtime_toml;
  (match Runtime.init_default ~config_path:runtime_path with
   | Ok () -> ()
   | Error error -> failf "runtime init: %s" error);
  let name = "execution-trust-narrow-projection" in
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String name
          ; "trace_id", `String "execution-trust-narrow-trace"
          ])
    with
    | Ok meta -> meta
    | Error error -> failf "meta fixture: %s" error
  in
  (match Masc.Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error error -> failf "write meta: %s" error);
  let json = Dashboard_http_keeper.execution_trust_dashboard_json config in
  let open Yojson.Safe.Util in
  let row =
    match json |> member "keepers" |> to_list with
    | [ row ] -> row
    | rows -> failf "expected one execution-trust row, got %d" (List.length rows)
  in
  let full_row =
    match
      Dashboard_http_keeper.keepers_dashboard_json ~compact:true config
      |> member "keepers"
      |> to_list
    with
    | [ full_row ] -> full_row
    | rows -> failf "expected one full Keeper row, got %d" (List.length rows)
  in
  let full_row_field key =
    Option.value ~default:`Null (Json_util.assoc_member_opt key full_row)
  in
  let expected_row =
    `Assoc
      (List.map
         (fun key -> key, full_row_field key)
         [ "name"
         ; "keeper_id"
         ; "phase"
         ; "pipeline_stage"
         ; "status"
         ; "trace_id"
         ; "current_task_id"
         ; "trust"
         ])
  in
  check bool "narrow row preserves the full projection wire values" true
    (Yojson.Safe.equal expected_row row);
  let keys =
    match row with
    | `Assoc fields -> List.map fst fields |> List.sort String.compare
    | _ -> fail "execution-trust keeper row must be an object"
  in
  check (list string) "wire field set remains exact"
    execution_trust_keeper_row_keys keys;
  check string "name" name (row |> member "name" |> to_string);
  check string "trace id" "execution-trust-narrow-trace"
    (row |> member "trace_id" |> to_string);
  check bool "trust summary remains populated" true
    (match row |> member "trust" with `Assoc _ -> true | _ -> false)

let test_execution_trust_does_not_call_full_keeper_projection () =
  let source = read_file "lib/dashboard/dashboard_http_keeper.ml" in
  check bool
    "execution-trust refresh cannot reintroduce the full compact projection"
    false
    (String_util.contains_substring
       source
       "keepers_dashboard_json ~compact:true")

(* A refusal the keeper cannot read is a refusal it cannot answer. The
   dashboard used to fill an omitted reason with the constant "dashboard
   rejected approval", so a rejected keeper had nothing to act on: polisher
   re-sent `echo ok` for 20+ turns against that string. RFC-0305 already
   forbids defaulting an omitted [decision] to approve; a rejection's reason
   is the same class of field. *)
let test_gate_resolve_requires_reason_on_reject () =
  let attempt reason_field =
    let fields =
      [ "id", `String "appr_regression_reject_reason"
      ; "decision", `String "reject"
      ]
      @ reason_field
    in
    Server_dashboard_http.dashboard_gate_resolve_http_json
      ~base_path:"/nonexistent/base/path"
      ~created_by:"regression-test"
      ~args:(`Assoc fields)
  in
  let expect_bad_request label result =
    match result with
    | Error (Server_dashboard_http.Bad_request msg) ->
      Alcotest.(check string)
        label
        "reason is required when decision is 'reject'"
        msg
    | Error other ->
      Alcotest.failf
        "%s: expected Bad_request, got %s"
        label
        (Server_dashboard_http.approval_resolve_http_error_to_string other)
    | Ok _ -> Alcotest.failf "%s: reject without a reason must not resolve" label
  in
  expect_bad_request "omitted reason" (attempt []);
  expect_bad_request "empty reason" (attempt [ "reason", `String "" ]);
  expect_bad_request "blank reason" (attempt [ "reason", `String "   " ]);
  (* A supplied reason clears parsing and reaches the queue, where this
     synthetic id has nothing to resolve. Any error other than Bad_request
     proves the reason was accepted. *)
  match attempt [ "reason", `String "clone target is unverified" ] with
  | Error (Server_dashboard_http.Bad_request msg) ->
    Alcotest.failf "a supplied reason must parse, got Bad_request: %s" msg
  | Error _ | Ok _ -> ()
;;

let test_gate_mode_change_json_separates_saved_mode_from_recovery () =
  let open Yojson.Safe.Util in
  let change : Masc.Keeper_gate_mode.change =
    { previous = Some Masc.Keeper_gate_mode.Manual
    ; current = Masc.Keeper_gate_mode.Auto_judge
    ; actor = "operator"
    ; changed_at = "2026-07-16T00:00:00Z"
    ; replaced_read_error = None
    }
  in
  let json recovery =
    Server_routes_http_routes_dashboard.For_testing.gate_mode_change_json
      change
      recovery
  in
  let completed =
    json
      (Server_routes_http_routes_dashboard.For_testing.Recovery_completed
         { Masc.Keeper_gate.started_ids = [ "approval-1" ]
         ; queued = 1
         ; failures = []
         })
  in
  check string "completed status" "completed"
    (completed |> member "recovery_status" |> to_string);
  check bool "completed error is null" true
    (completed |> member "recovery_error" = `Null);
  check int "completed started" 1 (completed |> member "started" |> to_int);
  check int "completed queued" 1 (completed |> member "queued" |> to_int);
  check int "completed failures" 0
    (completed |> member "recovery_failure_count" |> to_int);
  let partial =
    json
      (Server_routes_http_routes_dashboard.For_testing.Recovery_completed
         { Masc.Keeper_gate.started_ids = [ "approval-2" ]
         ; queued = 1
         ; failures =
             [ { keeper_name = "keeper-a"
               ; approval_id = Some "approval-1"
               ; operator_detail = "worker unavailable"
               }
             ]
         })
  in
  check string "partial status" "partial"
    (partial |> member "recovery_status" |> to_string);
  check int "partial started" 1 (partial |> member "started" |> to_int);
  check int "partial failures" 1
    (partial |> member "recovery_failure_count" |> to_int);
  check string "partial failure owner" "keeper-a"
    (partial
     |> member "recovery_failures"
     |> index 0
     |> member "keeper_name"
     |> to_string);
  let failed =
    json
      (Server_routes_http_routes_dashboard.For_testing.Recovery_failed
         "judge worker unavailable")
  in
  check string "failed status" "failed"
    (failed |> member "recovery_status" |> to_string);
  check string "failed detail" "judge worker unavailable"
    (failed |> member "recovery_error" |> to_string);
  check int "failed started" 0 (failed |> member "started" |> to_int);
  check int "failed queued" 0 (failed |> member "queued" |> to_int);
  let not_requested =
    json Server_routes_http_routes_dashboard.For_testing.Recovery_not_requested
  in
  check string "not requested status" "not_requested"
    (not_requested |> member "recovery_status" |> to_string);
  check bool "not requested error is null" true
    (not_requested |> member "recovery_error" = `Null);
  check int "not requested started" 0
    (not_requested |> member "started" |> to_int);
  check int "not requested queued" 0
    (not_requested |> member "queued" |> to_int)


let test_dashboard_planning_http_json_keeps_utf8_valid_after_truncation () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Lib.Workspace.init config ~agent_name:(Some "dashboard"));
  let hangul_ga = "\234\176\128" in
  let title = String.concat "" (List.init 40 (fun _ -> hangul_ga)) in
  (match Goal_store.upsert_goal config ~title ~metric:"m" ~target_value:"1" () with
   | Ok _ -> ()
   | Error msg -> fail msg);
  let json = Server_dashboard_http.dashboard_planning_http_json ~config in
  let serialized = Yojson.Safe.to_string json in
  check int "planning json remains valid utf8" 0 (invalid_utf8_byte_count serialized)

let test_dashboard_shell_auth_json_canonicalizes_token_owner () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let cfg =
    { Masc_domain.default_auth_config with enabled = true; require_token = true }
  in
  Auth.save_auth_config config.base_path cfg;
  match Auth.create_token config.base_path ~agent_name:"codex" ~role:Masc_domain.Worker with
  | Error e -> fail (Masc_domain.masc_error_to_string e)
  | Ok (raw_token, _) ->
      let json =
        Server_dashboard_http_core.dashboard_shell_http_json
          ~request:
            (request_with_headers "/api/v1/dashboard/shell"
               [
                 ("authorization", "Bearer " ^ raw_token);
                 ("x-masc-agent", "dashboard");
               ])
          config
      in
      let open Yojson.Safe.Util in
      let auth = json |> member "auth" in
      check bool "token_valid true" true (auth |> member "token_valid" |> to_bool);
      check string "requested actor surfaced" "dashboard"
        (auth |> member "requested_agent" |> to_string);
      check string "token owner surfaced" "codex"
        (auth |> member "token_agent" |> to_string);
      check string "effective actor canonicalized to token owner" "codex"
        (auth |> member "effective_agent" |> to_string);
      check bool "auth error cleared after canonicalization" true
        (match auth |> member "auth_error_code" with `Null -> true | _ -> false);
      check bool "keeper message allowed for canonicalized worker" true
        (auth |> member "can_keeper_msg" |> to_bool)

let test_dashboard_shell_auth_json_reports_missing_token () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let cfg =
    { Masc_domain.default_auth_config with enabled = true; require_token = true }
  in
  Auth.save_auth_config config.base_path cfg;
  let request =
    request_with_headers "/api/v1/dashboard/shell"
      [
        ("origin", "http://localhost:5173");
        ("host", "localhost:5173");
      ]
  in
  let request_authority =
    let trust_policy =
      match
        Server_request_authority.make_trust_policy
          ~bind_host:"127.0.0.1"
          ~bind_port:5173
          ~explicit_base_url:None
      with
      | Ok policy -> policy
      | Error error ->
        fail (Server_request_authority.trust_policy_error_to_string error)
    in
    match
      Server_request_authority.classify_http1_request ~trust_policy request
    with
    | Server_request_authority.Single authority -> authority
    | ( Server_request_authority.Missing
      | Server_request_authority.Multiple
      | Server_request_authority.Malformed
      | Server_request_authority.Untrusted ) ->
      fail "expected valid authority"
  in
  let json =
    Server_request_authority.with_current request_authority (fun () ->
      Server_dashboard_http_core.dashboard_shell_http_json
        ~request
        config)
  in
  let open Yojson.Safe.Util in
  let auth = json |> member "auth" in
  check bool "token_valid false" false (auth |> member "token_valid" |> to_bool);
  check string "missing token code surfaced" "missing_token"
    (auth |> member "auth_error_code" |> to_string)

let test_dashboard_shell_auth_json_rejects_stale_token_actor_hint () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let cfg =
    { Masc_domain.default_auth_config with enabled = true; require_token = true }
  in
  Auth.save_auth_config config.base_path cfg;
  let json =
    Server_dashboard_http_core.dashboard_shell_http_json
      ~request:
        (request_with_headers "/api/v1/dashboard/shell"
           [
             ("authorization", "Bearer stale-dashboard-token");
             ("x-masc-agent", "dashboard");
           ])
      config
  in
  let open Yojson.Safe.Util in
  let auth = json |> member "auth" in
  check bool "token_valid false" false (auth |> member "token_valid" |> to_bool);
  check string "requested actor surfaced for diagnosis" "dashboard"
    (auth |> member "requested_agent" |> to_string);
  check bool "effective actor not recovered from request hint" true
    (match auth |> member "effective_agent" with `Null -> true | _ -> false);
  check bool "effective role unavailable" true
    (match auth |> member "effective_role" with `Null -> true | _ -> false);
  check string "invalid token code surfaced" "invalid_token"
    (auth |> member "auth_error_code" |> to_string);
  check bool "keeper message blocked" false
    (auth |> member "can_keeper_msg" |> to_bool)

let test_dashboard_shell_auth_json_rejects_malformed_credential () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let cfg =
    { Masc_domain.default_auth_config with enabled = true; require_token = false }
  in
  Auth.save_auth_config config.base_path cfg;
  let json =
    Server_dashboard_http_core.dashboard_shell_http_json
      ~request:
        (request_with_headers "/api/v1/dashboard/shell"
           [ ("authorization", "Basic malformed")
           ; ("x-masc-agent", "forged-dashboard")
           ])
      config
  in
  let open Yojson.Safe.Util in
  let auth = json |> member "auth" in
  check bool "credential presence retained" true
    (auth |> member "token_present" |> to_bool);
  check bool "malformed credential invalid" false
    (auth |> member "token_valid" |> to_bool);
  check bool "effective actor unavailable" true
    (match auth |> member "effective_agent" with `Null -> true | _ -> false);
  check bool "effective role unavailable" true
    (match auth |> member "effective_role" with `Null -> true | _ -> false);
  check string "malformed credential code surfaced" "missing_token"
    (auth |> member "auth_error_code" |> to_string);
  check bool "keeper message blocked" false
    (auth |> member "can_keeper_msg" |> to_bool)

let test_dashboard_shell_snapshot_selector_injects_auth () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Dashboard_snapshot.reset_for_test ();
  Fun.protect
    ~finally:Dashboard_snapshot.reset_for_test
    (fun () ->
       let snapshot =
         Dashboard_snapshot.make_for_test
           ~shell:
             (`Assoc
                [
                  ("status", `Assoc [ ("project", `String "snapshot") ]);
                  ("paths", `Assoc []);
                ])
           ~tools:`Null
           ~namespace_truth:`Null
           ~telemetry_summary:`Null ()
       in
       Dashboard_snapshot.publish_for_test snapshot;
       let json =
         Server_dashboard_snapshot_select.select_shell_json
           ~request:(request "/api/v1/dashboard/shell")
           config
       in
       let open Yojson.Safe.Util in
       check string "snapshot payload preserved" "snapshot"
         (json |> member "status" |> member "project" |> to_string);
       check bool "snapshot selector injects auth" true
         (match json |> member "auth" with
          | `Assoc _ -> true
          | _ -> false))

let test_execution_actor_for_request_canonicalizes_token_owner () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let cfg =
    { Masc_domain.default_auth_config with enabled = true; require_token = true }
  in
  Auth.save_auth_config config.base_path cfg;
  match Auth.create_token config.base_path ~agent_name:"codex" ~role:Masc_domain.Worker with
  | Error e -> fail (Masc_domain.masc_error_to_string e)
  | Ok (raw_token, _) ->
      let actor =
        Server_dashboard_http_execution_surfaces.execution_actor_for_request
          ~base_path:config.base_path
          (request_with_headers "/api/v1/dashboard/execution"
             [
               ("authorization", "Bearer " ^ raw_token);
               ("x-masc-agent", "dashboard");
             ])
      in
      check (option string) "execution actor canonicalized to token owner"
        (Some "codex") actor

let test_dashboard_execution_force_refresh_bypasses_default_cache () =
  with_test_env @@ fun ~env ~sw ~config ->
  let state =
    Lib.Mcp_server_eio.For_testing.create_state ~base_path:config.base_path ()
  in
  let seed =
    `Assoc
      [ "force_marker", `String "cached"
      ; "generated_at", `String "2026-05-15T00:00:02Z"
      ]
  in
  with_cached_surface_success
    Server_dashboard_http_execution_surfaces.execution_cache
    seed
  @@ fun () ->
  let json =
    Server_dashboard_http_execution_surfaces.dashboard_execution_http_json
      ~state
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      (request "/api/v1/dashboard/execution?force=1")
  in
  let open Yojson.Safe.Util in
  check bool "force query surfaced" true
    (json |> member "query" |> member "force" |> to_bool);
  check bool "force is not the default cached light request" false
    (json |> member "query" |> member "default_light_request" |> to_bool);
  check bool "seed marker bypassed" true
    (match json |> member "force_marker" with
     | `Null -> true
     | _ -> false);
  check string "cache key" "execution:default:light"
    (json |> member "cache" |> member "request_cache_key" |> to_string);
  check string "cache state" "fresh"
    (json |> member "cache" |> member "cache_state" |> to_string)

let test_dashboard_execution_trust_default_route_uses_cached_surface () =
  with_test_env @@ fun ~env ~sw ~config ->
  let state =
    Lib.Mcp_server_eio.For_testing.create_state ~base_path:config.base_path ()
  in
  let seed =
    `Assoc
      [ "source", `String "execution_receipt"
      ; "producer", `String "keeper_agent_run.execution_receipt"
      ; "dashboard_surface", `String "/api/v1/dashboard/execution-trust"
      ; "generated_at", `String "2026-05-15T00:00:03Z"
      ; "freshness_slo_s", `Float 900.0
      ; "entry_count", `Int 2
      ; "exists", `Bool true
      ; "keepers", `List []
      ; "total", `Int 1
      ; "coverage_gaps", `List []
      ; "coverage_gap_count", `Int 0
      ; "health", `String "ok"
      ]
  in
  with_cached_surface_success
    Server_dashboard_http_execution_surfaces.execution_trust_cache
    seed
  @@ fun () ->
  let json =
    Server_dashboard_http_execution_surfaces.dashboard_execution_trust_http_json
      ~state
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      (request "/api/v1/dashboard/execution-trust")
  in
  let open Yojson.Safe.Util in
  check int "cached entry count" 2 (json |> member "entry_count" |> to_int);
  check string "surface" "/api/v1/dashboard/execution-trust"
    (json |> member "dashboard_surface" |> to_string);
  check string "projection cache state" "fresh"
    (json |> member "projection_diagnostics" |> member "cache_state" |> to_string);
  check string "envelope cache state" "fresh"
    (json |> member "dashboard_surface_envelope" |> member "cache" |> member "state"
     |> to_string);
  check string "envelope cache key" "execution-trust:default"
    (json |> member "dashboard_surface_envelope" |> member "cache" |> member "key"
     |> to_string)

let test_dashboard_message_json_surfaces_temporal_fields () =
  let message : Types.message =
    {
      request_id = "wmsg-dashboard-test";
      seq = 7;
      from_agent = "operator";
      msg_type = "broadcast";
      content = "hello";
      mention = None;
      mention_delivery = Types.Mention_passive;
      timestamp = "2026-05-07T00:00:00Z";
      trace_context = Some "traceparent";
      expires_at = Some 1_714_067_200.0;
    }
  in
  let json = Server_dashboard_http_core.dashboard_message_json message in
  let open Yojson.Safe.Util in
  check string "type" "broadcast" (json |> member "type" |> to_string);
  check string "trace_context" "traceparent"
    (json |> member "trace_context" |> to_string);
  check (float 0.001) "expires_at" 1_714_067_200.0
    (json |> member "expires_at" |> to_float)

(* RFC-0138 Phase 3 Step 1 — /shell snapshot wire tests.

   These exercise [Server_dashboard_snapshot_select.select_shell_json]
   directly, which is what the /api/v1/dashboard/shell handler now
   calls.  Three cases cover the full selector matrix:

   1. snapshot published + light=false  -> return [snap.shell]
   2. snapshot empty + light=false      -> fall back to compute path
   3. snapshot published + light=true   -> return [snap.shell_light]
                                           (RFC-0204 section 8.3 "A") *)

let test_shell_snapshot_wire_returns_snapshot_when_published () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Dashboard_snapshot.reset_for_test ();
  let marker = `Assoc [ "wire_marker", `String "snapshot-path" ] in
  Dashboard_snapshot.publish_for_test
    (Dashboard_snapshot.make_for_test
       ~shell:marker ~tools:`Null
       ~namespace_truth:`Null ~telemetry_summary:`Null ());
  let timing = Server_timing.create () in
  let json =
    Server_dashboard_snapshot_select.select_shell_json
      ~timing config
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "snapshot path returns published marker"
    "snapshot-path"
    (json |> member "wire_marker" |> to_string);
  let header = Server_timing.to_header_value timing in
  Alcotest.(check bool)
    "Server-Timing header records snapshot_read phase on hit"
    true
    (let re = Re.compile (Re.Perl.re "snapshot_read") in
     Re.execp re header);
  Dashboard_snapshot.reset_for_test ()

let test_shell_snapshot_wire_falls_back_when_empty () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Dashboard_snapshot.reset_for_test ();
  let timing = Server_timing.create () in
  let snapshot_json =
    Server_dashboard_snapshot_select.select_shell_json
      ~timing config
  in
  let direct_json =
    Server_dashboard_http_core.dashboard_shell_http_json
      ~light:false config
  in
  let open Yojson.Safe.Util in
  let paths_of j = j |> member "paths" in
  Alcotest.(check bool)
    "fallback path produces compute-equivalent paths key"
    true
    (paths_of snapshot_json <> `Null
     && paths_of snapshot_json = paths_of direct_json)

let test_shell_snapshot_wire_light_reads_shell_light () =
  (* RFC-0204 section 8.3 ("A"): light=true now serves the published light
     projection [snap.shell_light], not the full [snap.shell] and not a
     recompute. *)
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Dashboard_snapshot.reset_for_test ();
  let full = `Assoc [ "wire_marker", `String "full-shell" ] in
  let light = `Assoc [ "wire_marker", `String "light-shell" ] in
  Dashboard_snapshot.publish_for_test
    (Dashboard_snapshot.make_for_test
       ~shell:full ~shell_light:light ~tools:`Null
       ~namespace_truth:`Null ~telemetry_summary:`Null ());
  let timing = Server_timing.create () in
  let json =
    Server_dashboard_snapshot_select.select_shell_json
      ~timing ~light:true config
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "light=true returns the published shell_light projection"
    "light-shell"
    (json |> member "wire_marker" |> to_string);
  let header = Server_timing.to_header_value timing in
  Alcotest.(check bool)
    "Server-Timing records snapshot_read on light hit"
    true
    (let re = Re.compile (Re.Perl.re "snapshot_read") in Re.execp re header);
  Dashboard_snapshot.reset_for_test ()

let test_dashboard_shell_light_includes_runtime_health_ssot () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let json =
    Server_dashboard_http_core.dashboard_shell_http_json ~light:true config
  in
  let open Yojson.Safe.Util in
  let runtime_resolution = json |> member "runtime_resolution" in
  let keeper_fibers = runtime_resolution |> member "keeper_fibers" |> to_int in
  Alcotest.(check bool)
    "light shell exposes runtime_resolution object"
    true
    (match runtime_resolution with
     | `Assoc _ -> true
     | _ -> false);
  Alcotest.(check int)
    "light shell keeper count follows runtime health keeper_fibers"
    keeper_fibers
    (json |> member "counts" |> member "keepers" |> to_int);
  Alcotest.(check bool)
    "light shell exposes fleet safety"
    true
    (match runtime_resolution |> member "keeper_fleet_safety" with
     | `Assoc _ -> true
     | _ -> false);
  Alcotest.(check bool)
    "light shell exposes fd accountant"
    true
    (match runtime_resolution |> member "fd_accountant" with
     | `Assoc _ -> true
     | _ -> false)

let test_dashboard_fleet_composite_envelope_is_cached () =
  (* [dashboard_fleet_composite_json] caches the fleet envelope so a second poll
     inside the TTL returns the cached compute (identical generated_at) rather
     than re-running the sequential N-keeper read path. Each keeper reaches
     [Keeper_secret_projection.dashboard_status_json] (a synchronous disk
     read), so an uncached poll costs N reads. This guards that regression. *)
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let json1 = Server_dashboard_http.dashboard_fleet_composite_json ~config () in
  let json2 = Server_dashboard_http.dashboard_fleet_composite_json ~config () in
  let open Yojson.Safe.Util in
  let gen1 = json1 |> member "generated_at" |> to_float in
  let gen2 = json2 |> member "generated_at" |> to_float in
  Alcotest.(check bool)
    "second fleet-composite poll hits cache (identical generated_at)"
    true (gen1 = gen2)

let test_offline_keeper_composite_exposes_secret_projection () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let keeper_name = "offline-secret-keeper" in
  let sentinel = "ghs_offline_secret_projection_regression" in
  (match
     Masc.Keeper_secret_projection.set_env_entry
       ~base_path:config.base_path
       ~keeper_name
       ~scope:Masc.Keeper_secret_projection.Shared_secret
       ~name:"GH_TOKEN"
       ~value:sentinel
   with
   | Ok () -> ()
   | Error err -> Alcotest.failf "set shared secret failed: %s" err);
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
           [ "name", `String keeper_name
           ; "trace_id", `String "offline-secret-trace"
           ])
    with
    | Ok meta -> { meta with Masc.Keeper_meta_contract.paused = true }
    | Error err -> Alcotest.failf "meta fixture failed: %s" err
  in
  let json =
    Server_dashboard_http_keeper_api.offline_keeper_composite_json
      ~config
      keeper_name
      meta
  in
  let open Yojson.Safe.Util in
  let projection = json |> member "secret_projection" in
  Alcotest.(check string)
    "offline composite includes ready secret projection"
    "ready"
    (projection |> member "status" |> to_string);
  Alcotest.(check (list string))
    "offline composite reports projected env names"
    [ "GH_TOKEN" ]
    (projection |> member "env_names" |> to_list |> List.map to_string);
  Alcotest.(check bool)
    "offline composite redacts secret values"
    false
    (String_util.contains_substring (Yojson.Safe.to_string json) sentinel)

let keeper_state_diagram_meta ?last_runtime_attempt_provider name =
  let runtime_attempt_fields =
    match last_runtime_attempt_provider with
    | None -> []
    | Some provider_id ->
      [ ( "last_runtime_attempt"
        , `Assoc
            [ "provider_id", `String provider_id
            ; "http_status", `Int 200
            ; "outcome", `Assoc [ "kind", `String "success" ]
            ; "timestamp", `Float 1_720_000_000.0
            ] )
      ]
  in
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         ([ "name", `String name
          ; "trace_id", `String ("trace-" ^ name)
          ]
          @ runtime_attempt_fields))
  with
  | Ok meta -> meta
  | Error err -> Alcotest.failf "state diagram meta fixture failed: %s" err

let test_state_diagram_runtime_projection_redacts_live_runtime_evidence () =
  let raw_provider = "openai:gpt-5-secret" in
  let projection =
    Server_dashboard_http_keeper_api.state_diagram_runtime_projection
      (Some
         (keeper_state_diagram_meta
            ~last_runtime_attempt_provider:raw_provider
            "state-diagram-runtime"))
  in
  Alcotest.(check (list string))
    "runtime model labels are public redaction labels"
    [ "runtime" ]
    projection.runtime_models;
  Alcotest.(check (option string))
    "last provider result is redacted to the public runtime label"
    (Some "runtime")
    projection.last_provider_result;
  Alcotest.(check string)
    "runtime model source records keeper meta provenance"
    "keeper_meta.runtime.last_runtime_attempt"
    projection.runtime_models_source;
  Alcotest.(check string)
    "last provider source records keeper meta provenance"
    "keeper_meta.runtime.last_runtime_attempt"
    projection.last_provider_result_source;
  let json =
    Server_dashboard_http_keeper_api.state_diagram_runtime_projection_json
      projection
    |> Yojson.Safe.to_string
  in
  Alcotest.(check bool)
    "projection JSON does not leak raw provider id"
    false
    (String_util.contains_substring json raw_provider);
  let mermaid =
    Server_dashboard_http_keeper_api.state_diagram_runtime_fsm_mermaid
      projection
  in
  Alcotest.(check bool)
    "runtime FSM contains the redacted runtime node"
    true
    (String_util.contains_substring mermaid {|state "runtime" as P0|});
  Alcotest.(check bool)
    "runtime FSM no longer renders fake candidate node"
    false
    (String_util.contains_substring mermaid "candidate");
  Alcotest.(check bool)
    "runtime FSM does not leak raw provider id"
    false
    (String_util.contains_substring mermaid raw_provider)

let test_state_diagram_runtime_projection_missing_meta_stays_empty () =
  let projection =
    Server_dashboard_http_keeper_api.state_diagram_runtime_projection None
  in
  Alcotest.(check (list string))
    "missing meta exposes no runtime model labels"
    []
    projection.runtime_models;
  Alcotest.(check (option string))
    "missing meta has no last provider result"
    None
    projection.last_provider_result;
  Alcotest.(check string)
    "missing meta source is explicit"
    "missing_keeper_meta"
    projection.runtime_models_source;
  let mermaid =
    Server_dashboard_http_keeper_api.state_diagram_runtime_fsm_mermaid
      projection
  in
  Alcotest.(check bool)
    "missing meta FSM reports zero models"
    true
    (String_util.contains_substring mermaid "Models: 0");
  Alcotest.(check bool)
    "missing meta FSM has no fake candidate node"
    false
    (String_util.contains_substring mermaid "candidate")

let test_dashboard_shell_separates_configured_and_persisted_keeper_counts () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let config_root =
    Filename.concat
      (Filename.concat config.base_path Common.masc_dirname)
      "config"
  in
  let keepers_dir = Filename.concat config_root "keepers" in
  mkdir_p keepers_dir;
  write_file
    (Filename.concat keepers_dir "base.toml")
    "[keeper]\nautoboot_enabled = false\ninstructions = \"Keeper base\"\n";
  write_file
    (Filename.concat keepers_dir "alpha.toml")
    "[keeper]\nautoboot_enabled = true\n";
  write_file
    (Filename.concat keepers_dir "beta.toml")
    "[keeper]\nautoboot_enabled = true\n";
  with_env "MASC_CONFIG_DIR" config_root @@ fun () ->
  Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () -> Config_dir_resolver.reset ())
    (fun () ->
      let expected_configured_names = [ "alpha"; "base"; "beta" ] in
      let configured_names =
        Masc.Keeper_meta_store.configured_keeper_names config
        |> List.sort String.compare
      in
      Alcotest.(check (list string))
        "configured Keeper inventory includes every declarative TOML"
        expected_configured_names
        configured_names;
      let json =
        Server_dashboard_http_core.dashboard_shell_payload_json ~light:true config
      in
      let open Yojson.Safe.Util in
      Alcotest.(check int)
        "configured_keepers follows declarative runtime keeper TOML"
        (List.length configured_names)
        (json |> member "configured_keepers" |> to_int);
      Alcotest.(check int)
        "persisted_keepers exposes durable meta count separately"
        0
        (json |> member "persisted_keepers" |> to_int);
      Alcotest.(check int)
        "counts.persisted_keepers mirrors top-level persisted_keepers"
        0
        (json |> member "counts" |> member "persisted_keepers" |> to_int);
      write_file
        (Filename.concat keepers_dir "base.toml")
        "[keeper]\nautoboot_enabled = true\n";
      Config_dir_resolver.reset ();
      let configured_names_after_autoboot_change =
        Masc.Keeper_meta_store.configured_keeper_names config
        |> List.sort String.compare
      in
      Alcotest.(check (list string))
        "autoboot policy does not change configured inventory"
        expected_configured_names
        configured_names_after_autoboot_change;
      let json =
        Server_dashboard_http_core.dashboard_shell_payload_json ~light:true config
      in
      Alcotest.(check int)
        "configured_keepers remains the TOML inventory after autoboot change"
        (List.length configured_names_after_autoboot_change)
        (json |> member "configured_keepers" |> to_int))

let test_dashboard_shell_light_counts_agents_from_summary_fields () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let write_agent ~name ~agent_type ~status =
    let path =
      Filename.concat (Workspace.agents_dir config) (Workspace.safe_filename name ^ ".json")
    in
    Workspace.write_json
      config
      path
      (`Assoc
        [ "name", `String name
        ; "agent_type", `String agent_type
        ; "status", `String status
        ; "capabilities", `List []
        ; "session_bound_at", `String "2026-05-20T00:00:00Z"
        ; "last_seen", `String "2026-05-20T00:00:00Z"
        ])
  in
  write_agent ~name:"codex-active" ~agent_type:"codex" ~status:"active";
  write_agent ~name:"keeper-active" ~agent_type:"keeper" ~status:"busy";
  write_agent ~name:"codex-inactive" ~agent_type:"codex" ~status:"inactive";
  let json =
    Server_dashboard_http_core.dashboard_shell_http_json ~light:true config
  in
  let open Yojson.Safe.Util in
  Alcotest.(check int)
    "light shell counts active non-keeper agents from summary fields"
    1
    (json |> member "counts" |> member "agents" |> to_int)

(* RFC-0138 Phase 3 Step 2 — /tools and /telemetry/summary wire tests.

   Cover the new selector matrix on
   [Server_dashboard_snapshot_select.select_tools_json] and
   [..._telemetry_summary_json]. *)

let test_tools_snapshot_wire_returns_snapshot_when_actor_omitted () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Dashboard_snapshot.reset_for_test ();
  let marker = `Assoc [ "tools_marker", `String "from-snapshot" ] in
  Dashboard_snapshot.publish_for_test
    (Dashboard_snapshot.make_for_test
       ~shell:`Null ~tools:marker
       ~namespace_truth:`Null ~telemetry_summary:`Null ());
  let timing = Server_timing.create () in
  let json =
    Server_dashboard_snapshot_select.select_tools_json
      ~timing config
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "actor-less snapshot path returns published marker"
    "from-snapshot"
    (json |> member "tools_marker" |> to_string);
  Alcotest.(check bool)
    "Server-Timing header records snapshot_read phase on hit"
    true
    (let header = Server_timing.to_header_value timing in
     let re = Re.compile (Re.Perl.re "snapshot_read") in
     Re.execp re header);
  Dashboard_snapshot.reset_for_test ()

(* [test_tools_snapshot_wire_bypasses_snapshot_when_actor_given]
   intentionally omitted from the unit suite.  The selector's
   actor=Some branch routes to
   [Server_dashboard_http_runtime_info.dashboard_tools_http_json] which
   requires a full Eio scheduler + runtime probe wiring not present
   in [with_test_env].  Integration coverage of the actor-filter
   bypass belongs in [test_dashboard_tools.ml] (which already runs
   inside the live HTTP harness).  See RFC-0138 §3.3 Step 2 retire
   criterion: snapshot grows an [Actor_filter] arm. *)

let test_telemetry_summary_snapshot_wire_returns_snapshot () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Dashboard_snapshot.reset_for_test ();
  let marker = `Assoc [ "tele_marker", `String "from-snapshot" ] in
  Dashboard_snapshot.publish_for_test
    (Dashboard_snapshot.make_for_test
       ~shell:`Null ~tools:`Null
       ~namespace_truth:`Null ~telemetry_summary:marker ());
  let timing = Server_timing.create () in
  let json =
    Server_dashboard_snapshot_select.select_telemetry_summary_json
      ~timing config
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "telemetry_summary snapshot path returns published marker"
    "from-snapshot"
    (json |> member "tele_marker" |> to_string);
  Dashboard_snapshot.reset_for_test ()

let test_telemetry_summary_snapshot_wire_falls_back_when_empty () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  Dashboard_snapshot.reset_for_test ();
  let timing = Server_timing.create () in
  let json =
    Server_dashboard_snapshot_select.select_telemetry_summary_json
      ~timing config
  in
  Alcotest.(check bool)
    "fallback path produces a non-null JSON object"
    true
    (match json with `Assoc _ -> true | _ -> false)

(* RFC-0138 Phase 3 Step 3 — /project-snapshot wire test.

   We can only unit-test the snapshot-hit branch.  The fallback branch
   calls [dashboard_namespace_truth_http_json] which requires a full
   server_state + Eio scheduler + 6 timeout env knobs ([with_test_env]
   does not synthesise these).  The fallback path lives in
   [test_dashboard_namespace_truth.ml] integration coverage. *)

let test_project_snapshot_wire_returns_snapshot_when_populated () =
  with_test_env @@ fun ~env ~sw ~config ->
  Dashboard_snapshot.reset_for_test ();
  let marker =
    `Assoc [ "namespace_truth_marker", `String "from-snapshot" ]
  in
  Dashboard_snapshot.publish_for_test
    (Dashboard_snapshot.make_for_test
       ~shell:`Null ~tools:`Null
       ~namespace_truth:marker ~telemetry_summary:`Null ());
  let clock = Eio.Stdenv.clock env in
  let state =
    Lib.Mcp_server.For_testing.create_state ~base_path:config.base_path
  in
  let req = request "/api/v1/dashboard/project-snapshot" in
  let timing = Server_timing.create () in
  let json =
    Server_dashboard_snapshot_select.select_project_snapshot_json
      ~state ~sw ~clock ~timing req
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "populated snapshot path returns published marker"
    "from-snapshot"
    (json |> member "namespace_truth_marker" |> to_string);
  Alcotest.(check bool)
    "Server-Timing header records snapshot_read phase on hit"
    true
    (let header = Server_timing.to_header_value timing in
     let re = Re.compile (Re.Perl.re "snapshot_read") in
     Re.execp re header);
  Dashboard_snapshot.reset_for_test ()

let assoc_has key = function
  | `Assoc fields -> List.mem_assoc key fields
  | _ -> false

let test_dashboard_bootstrap_omits_eager_goal_tree () =
  with_test_env @@ fun ~env ~sw ~config ->
  let state = Lib.Mcp_server.For_testing.create_state ~base_path:config.base_path in
  let clock = Eio.Stdenv.clock env in
  let req = request "/api/v1/dashboard/bootstrap" in
  let json = Server_dashboard_http.dashboard_bootstrap_http_json ~state ~sw ~clock req in
  Alcotest.(check bool) "bootstrap includes shell" true (assoc_has "shell" json);
  Alcotest.(check bool) "bootstrap includes execution" true
    (assoc_has "execution" json);
  Alcotest.(check bool) "bootstrap includes planning" true
    (assoc_has "planning" json);
  Alcotest.(check bool) "bootstrap includes namespace truth" true
    (assoc_has "namespace_truth" json);
  Alcotest.(check bool) "bootstrap omits eager goal tree" false
    (assoc_has "goals" json)

(* Freeze guard: /api/v1/dashboard/telemetry must never default to an
   unbounded read. Observatory polls with since_ms/until_ms and no [n];
   before this fix the windowed default was n=0 (unbounded), letting one
   poll Yojson-parse up to the read clamp (#20659: 50k) per source across
   all sources and peg the single Eio domain -> keeper-fleet freeze. *)
let test_telemetry_n_default_is_bounded () =
  let resolve ~has_time_window ~n_param =
    Telemetry_unified.read_limit_to_int
      (Server_routes_http_routes_dashboard_setup.resolve_telemetry_limit
         ~has_time_window ~n_param)
  in
  Alcotest.(check int)
    "windowed + no n -> bounded default, never 0"
    2000 (resolve ~has_time_window:true ~n_param:None);
  Alcotest.(check int)
    "no window + no n -> small default"
    100 (resolve ~has_time_window:false ~n_param:None);
  Alcotest.(check int)
    "unparseable n -> bounded default, never 0"
    2000 (resolve ~has_time_window:true ~n_param:(Some "garbage"));
  (* RFC-0372 replaces the #20659 all-in-window opt-out. Explicit n=0 used to
     pass 0 through as "unbounded"; it now resolves to a positive limit like
     any other input, and a window larger than that limit is reported via
     [truncated] instead of scanning every store to its own cap. *)
  Alcotest.(check int)
    "explicit n=0 is bounded, not unbounded"
    Telemetry_unified.default_read_entries
    (resolve ~has_time_window:true ~n_param:(Some "0"));
  Alcotest.(check bool)
    "no input resolves to a non-positive limit"
    true
    (List.for_all
       (fun raw -> resolve ~has_time_window:true ~n_param:(Some raw) > 0)
       [ "0"; "-1"; "-99999"; "garbage"; "" ]);
  Alcotest.(check int)
    "a request above the ceiling is clamped"
    Telemetry_unified.max_read_entries
    (resolve ~has_time_window:true
       ~n_param:(Some (string_of_int (Telemetry_unified.max_read_entries + 1))));
  Alcotest.(check int)
    "explicit positive n honoured"
    500 (resolve ~has_time_window:true ~n_param:(Some "500"))

(* Issue #22071: lifecycle event classification was reverse-mapped by a raw
   string whitelist that bypassed compiler exhaustiveness, and the module
   docstrings cited coverage tests ([lifecycle_events_ssot] /
   [lifecycle_event_cache_patcher_coverage]) in a test/test_types.ml that does
   not exist. These are the real guards. *)
let current_lifecycle_events =
  List.map
    (fun verb ->
      Keeper_lifecycle_events.Custom_event { verb; phase = None })
    Keeper_lifecycle_events.all_custom_events
  @ List.map
      (fun phase -> Keeper_lifecycle_events.Phase_event phase)
      [
        Keeper_state_machine.Running;
        Keeper_state_machine.Stopped;
        Keeper_state_machine.Crashed;
      ]

let test_lifecycle_event_wire_roundtrip () =
  List.iter
    (fun event ->
      let event_name =
        Keeper_lifecycle_events.lifecycle_event_to_string event
      in
      let phase =
        Keeper_lifecycle_events.lifecycle_event_phase event
        |> Option.map Keeper_state_machine.phase_to_string
      in
      check bool
        ("lifecycle wire round-trips " ^ event_name)
        true
        (Keeper_lifecycle_events.lifecycle_event_of_wire
           ~event:event_name
           ~phase
         = Some event))
    current_lifecycle_events;
  check bool "unknown lifecycle wire event is rejected" true
    (Option.is_none
       (Keeper_lifecycle_events.lifecycle_event_of_wire
          ~event:"no_such_lifecycle_event"
          ~phase:None));
  check bool "inconsistent phase event is rejected" true
    (Option.is_none
       (Keeper_lifecycle_events.lifecycle_event_of_wire
          ~event:"running"
          ~phase:(Some "stopped")))

let test_lifecycle_event_cache_patcher_coverage () =
  (* Every name in the SSOT vocabulary must be classified ([Some]) by all four
     dashboard cache patchers — the coverage the phantom test only promised. The
     custom-event subset is also compiler-enforced via [display_of_custom_event]. *)
  List.iter
    (fun event ->
      let name =
        Keeper_lifecycle_events.lifecycle_event_to_string event
      in
      check bool
        ("keepalive_running classifies " ^ name)
        true
        (Option.is_some
           (Server_dashboard_http_execution_surfaces.keepalive_running_of_lifecycle_event
              event));
      check bool
        ("phase classifies " ^ name)
        true
        (Option.is_some
           (Server_dashboard_http_execution_surfaces.phase_of_lifecycle_event event));
      check bool
        ("pipeline_stage classifies " ^ name)
        true
        (Option.is_some
           (Server_dashboard_http_execution_surfaces.pipeline_stage_of_lifecycle_event
              event));
      check bool
        ("paused classifies " ^ name)
        (not
           (event
            = Keeper_lifecycle_events.Phase_event
                Keeper_state_machine.Stopped))
        (Option.is_some
           (Server_dashboard_http_execution_surfaces.paused_of_lifecycle_event event)))
    current_lifecycle_events

let test_lifecycle_event_display_values () =
  (* Pin the exact typed transition projection. *)
  let cases =
    [
      ( Keeper_lifecycle_events.Custom_event
          { verb = Keeper_lifecycle_events.Started; phase = None },
        true, "running", "idle", Some false );
      ( Keeper_lifecycle_events.Phase_event Keeper_state_machine.Paused,
        true, "paused", "paused", Some true );
      ( Keeper_lifecycle_events.Phase_event Keeper_state_machine.Stopped,
        false, "stopped", "offline", None );
      ( Keeper_lifecycle_events.Phase_event Keeper_state_machine.Crashed,
        false, "crashed", "crashed", Some false );
    ]
  in
  List.iter
    (fun (event, keepalive, phase, pipeline, paused) ->
      let name =
        Keeper_lifecycle_events.lifecycle_event_to_string event
      in
      check (option bool)
        ("keepalive_running value for " ^ name)
        (Some keepalive)
        (Server_dashboard_http_execution_surfaces.keepalive_running_of_lifecycle_event
           event);
      check (option string)
        ("phase value for " ^ name)
        (Some phase)
        (Server_dashboard_http_execution_surfaces.phase_of_lifecycle_event event);
      check (option string)
        ("pipeline_stage value for " ^ name)
        (Some pipeline)
        (Server_dashboard_http_execution_surfaces.pipeline_stage_of_lifecycle_event
           event);
      check (option bool)
        ("paused value for " ^ name)
        paused
        (Server_dashboard_http_execution_surfaces.paused_of_lifecycle_event event))
    cases

(* The [paused] lifecycle event patches with [keepalive_running = true], so the
   row goes through the keepalive branch of the status patcher. That branch used
   to classify against the surface vocabulary alone, where "paused" is not a
   member, and fell through to "idle" — producing a row that said [status =
   "idle"] and [paused = true] at the same time. [rebuild_continuity_briefs]
   then read the row as live. *)
let test_paused_lifecycle_event_keeps_paused_status () =
  let patched =
    Server_dashboard_http_execution_surfaces.patch_keeper_row
      ~keeper_name:"pause-target"
      ~event:
        (Keeper_lifecycle_events.Phase_event Keeper_state_machine.Paused)
      ~keepalive_running:true
      (`Assoc [ ("name", `String "pause-target"); ("status", `String "paused") ])
  in
  check string "status survives the patch" "paused"
    Yojson.Safe.Util.(patched |> member "status" |> to_string);
  check bool "paused flag is set" true
    Yojson.Safe.Util.(patched |> member "paused" |> to_bool)

let test_reconciled_lifecycle_event_preserves_durable_pause () =
  let patched =
    Server_dashboard_http_execution_surfaces.patch_keeper_row
      ~keeper_name:"paused-reconcile-target"
      ~event:
        (Keeper_lifecycle_events.Custom_event
           { verb = Keeper_lifecycle_events.Reconciled; phase = None })
      ~keepalive_running:true
      (`Assoc
        [ ("name", `String "paused-reconcile-target")
        ; ("status", `String "paused")
        ; ("paused", `Bool true)
        ; ("phase", `String "paused")
        ; ("pipeline_stage", `String "paused")
        ])
  in
  let open Yojson.Safe.Util in
  check string "reconciliation preserves paused status" "paused"
    (patched |> member "status" |> to_string);
  check bool "reconciliation preserves durable pause flag" true
    (patched |> member "paused" |> to_bool);
  check string "reconciliation preserves paused phase" "paused"
    (patched |> member "phase" |> to_string);
  check string "reconciliation preserves paused pipeline" "paused"
    (patched |> member "pipeline_stage" |> to_string)

let test_stopped_lifecycle_event_stays_offline () =
  let patched =
    Server_dashboard_http_execution_surfaces.patch_keeper_row
      ~keeper_name:"stop-target"
      ~event:
        (Keeper_lifecycle_events.Phase_event Keeper_state_machine.Stopped)
      ~keepalive_running:false
      (`Assoc
        [ ("name", `String "stop-target")
        ; ("status", `String "active")
        ; ("paused", `Bool false)
        ])
  in
  check string "stopped status is offline" "offline"
    Yojson.Safe.Util.(patched |> member "status" |> to_string);
  check bool "stopped event does not manufacture a pause" false
    Yojson.Safe.Util.(patched |> member "paused" |> to_bool)

let test_stopped_lifecycle_event_preserves_durable_pause () =
  let patched =
    Server_dashboard_http_execution_surfaces.patch_keeper_row
      ~keeper_name:"paused-stop-target"
      ~event:
        (Keeper_lifecycle_events.Phase_event Keeper_state_machine.Stopped)
      ~keepalive_running:false
      (`Assoc
        [ ("name", `String "paused-stop-target")
        ; ("status", `String "paused")
        ; ("paused", `Bool true)
        ])
  in
  check string "terminal stop preserves paused status" "paused"
    Yojson.Safe.Util.(patched |> member "status" |> to_string);
  check bool "terminal stop preserves durable pause flag" true
    Yojson.Safe.Util.(patched |> member "paused" |> to_bool)

let test_lifecycle_cache_patch_rejects_missing_or_unknown_status () =
  let patch row =
    Server_dashboard_http_execution_surfaces.patch_keeper_row
      ~keeper_name:"drift-target"
      ~event:
        (Keeper_lifecycle_events.Custom_event
           { verb = Keeper_lifecycle_events.Reconciled; phase = None })
      ~keepalive_running:true
      row
    |> ignore
  in
  check_raises
    "missing status stays fail-loud"
    (Invalid_argument
       "dashboard execution cache: keeper row has no current status")
    (fun () ->
      patch (`Assoc [ "name", `String "drift-target" ]));
  check_raises
    "unknown status stays fail-loud"
    (Invalid_argument
       "dashboard execution cache: unknown current keeper status \"suspended\"")
    (fun () ->
      patch
        (`Assoc
          [ "name", `String "drift-target"
          ; "status", `String "suspended"
          ]))

let test_running_keeper_reconciliation_rebuilds_continuity_brief () =
  let dir = test_dir () in
  let config = Workspace.default_config dir in
  let keeper_name = "continuity-reconcile-fixture" in
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String keeper_name
          ; "trace_id", `String "continuity-reconcile-trace"
          ])
    with
    | Ok meta -> meta
    | Error error -> fail ("meta fixture: " ^ error)
  in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.For_testing.unregister
        ~base_path:config.base_path
        keeper_name;
      cleanup_dir dir)
    (fun () ->
       (match Masc.Keeper_meta_store.replace_snapshot config meta with
        | Ok () -> ()
        | Error error -> fail ("write meta: " ^ error));
       ignore
         (Masc.Keeper_registry.For_testing.register
            ~base_path:config.base_path
            keeper_name
            meta);
       let now = Masc_domain.now_iso () in
       let keeper_row =
         `Assoc
           [ "name", `String keeper_name
           ; "keeper_id", `String ("k-" ^ keeper_name)
           ; "status", `String "active"
             (* #30084 moved [continuity_row_of_keeper] off the folded [status]
                word onto two fields this row never carried: [health_state] and
                the last action time. An absent diagnostic reads as health "",
                which the builder refuses by design -- and the refusal took the
                whole continuity list down with it, because it is raised inside
                the [filter_map] that builds every brief.

                The row now says in the new vocabulary what it always meant in
                the old one: a live keeper that has taken its turn. Both fields
                are ones the live producer always writes
                ([keeper_status_runtime.ml] stamps [health_state] on every
                diagnostic), so this is the fixture catching up, not the
                builder being loosened. *)
           ; ( "diagnostic"
             , `Assoc [ "health_state", `String "healthy" ] )
           ; "keepalive_running", `Bool false
           ; "turn_count", `Int 1
           ; "updated_at", `String now
             (* [tool_audit_at] is where the builder reads "has this keeper
                acted"; empty means never, and never is [Lc_idle]. The row
                claims [turn_count = 1], so it has. *)
           ; "tool_audit_at", `String now
           ; "recent_tool_names", `List []
           ; "latest_tool_names", `List []
           ]
       in
       let stale_brief =
         `Assoc
           [ "name", `String keeper_name
           ; "status", `String "offline"
           ; "state", `String "critical"
           ; "lifecycle", `String "offline"
           ]
       in
       let patched =
         Server_dashboard_http_execution_surfaces.patch_surface_json_for_running_keepers
           config
           (`Assoc
             [ "keepers", `List [ keeper_row ]
             ; "continuity_briefs", `List [ stale_brief ]
             ])
       in
       let open Yojson.Safe.Util in
       let patched_keeper = patched |> member "keepers" |> to_list |> List.hd in
       let patched_brief =
         patched |> member "continuity_briefs" |> to_list |> List.hd
       in
       check string
         "keeper status falls back to the top-level typed status"
         "active"
         (patched_keeper |> member "status" |> to_string);
       check bool
         "keeper keepalive uses reconciled registry state"
         true
         (patched_keeper |> member "keepalive_running" |> to_bool);
       check string
         "brief status is rebuilt from patched keeper"
         "active"
         (patched_brief |> member "status" |> to_string);
       check string
         "brief lifecycle is rebuilt from patched keeper"
         "active"
         (patched_brief |> member "lifecycle" |> to_string);
       check string
         "brief state is rebuilt from patched keeper"
         "healthy"
         (patched_brief |> member "state" |> to_string);
       let unrelated_surface =
         `Assoc
           [ ( "keepers"
             , `List
                 [ `Assoc
                     [ "name", `String "fixture-only-keeper"
                     ; "status", `String "offline"
                     ] ] )
           ; "continuity_briefs", `List [ stale_brief ]
           ]
       in
       check
         bool
         "unrelated running keeper leaves fixture surface byte-stable"
         true
         (unrelated_surface
          =
          Server_dashboard_http_execution_surfaces.patch_surface_json_for_running_keepers
            config
            unrelated_surface))

let test_composite_blocked_uses_terminal_contract_not_observational_metadata () =
  let execution ~terminal_reason_code ~operator_disposition_reason =
    `Assoc
      [ "terminal_reason_code", `String terminal_reason_code
      ; "operator_disposition", `String "pass"
      ; "operator_disposition_reason", `String operator_disposition_reason
      ; "error", `Null
      ]
  in
  let blocked = Server_dashboard_http_composite_claims.composite_execution_blocked in
  check bool
    "observation metadata does not block a successful execution"
    false
    (blocked
       (execution
          ~terminal_reason_code:"success"
          ~operator_disposition_reason:"trace_observation_present"));
  check bool
    "unknown terminal wire follows the generic failure path"
    true
    (blocked
       (execution
          ~terminal_reason_code:"opaque_terminal_failure"
          ~operator_disposition_reason:"success"))

(* Context-window shrink guard (#25062/#25268): reducing max_context_override
   must be detected so the config POST can require an explicit
   confirm_context_shrink, instead of silently applying a window smaller than the
   live context and triggering a reactive Provider_overflow on the next turn. *)
module Keeper_config_post = Server_dashboard_http_keeper_api_post

let test_keeper_github_login_stream_headers_include_cors () =
  let origin = "http://localhost:5173" in
  let headers =
    Keeper_config_post.For_testing.github_login_stream_headers origin
  in
  Alcotest.(check (option string)) "CORS origin is reflected" (Some origin)
    (Httpun.Headers.get headers "access-control-allow-origin");
  Alcotest.(check (option string)) "credentials are allowed" (Some "true")
    (Httpun.Headers.get headers "access-control-allow-credentials")
;;

let test_keeper_github_login_stream_flushes_each_event () =
  let actions = ref [] in
  Keeper_config_post.For_testing.github_login_stream_send_with
    ~write:(fun frame -> actions := !actions @ [ "write:" ^ frame ])
    ~flush:(fun () -> actions := !actions @ [ "flush" ])
    "device_code"
    (`Assoc [ "code", `String "ABCD-EFGH" ]);
  Alcotest.(check (list string)) "frame is written before it is flushed"
    [ "write:event: device_code\ndata: {\"code\":\"ABCD-EFGH\"}\n\n"; "flush" ]
    !actions
;;

let shrink_base_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ ("name", `String "shrink-fixture"); ("trace_id", `String "shrink-t") ])
  with
  | Ok m -> m
  | Error e -> Alcotest.fail ("shrink meta fixture: " ^ e)

let with_max_override meta o =
  { meta with Masc.Keeper_meta_contract.max_context_override = o }

let shrink_result = Alcotest.(option (pair string int))

let test_context_shrink_detection () =
  let base = shrink_base_meta () in
  let shrink meta fields = Keeper_config_post.context_shrink_of_patch ~meta fields in
  check shrink_result "cap introduced where there was none is a shrink"
    (Some ("unset (full model window)", 1000))
    (shrink (with_max_override base None) [ ("max_context_override", `Int 1000) ]);
  check shrink_result "lowering an existing cap is a shrink"
    (Some ("2000", 1000))
    (shrink (with_max_override base (Some 2000)) [ ("max_context_override", `Int 1000) ]);
  check shrink_result "raising the cap is not a shrink"
    None
    (shrink (with_max_override base (Some 1000)) [ ("max_context_override", `Int 2000) ]);
  check shrink_result "removing the cap (Null) is not a shrink"
    None
    (shrink (with_max_override base (Some 1000)) [ ("max_context_override", `Null) ]);
  check shrink_result "a patch without the field is not a shrink"
    None
    (shrink (with_max_override base (Some 1000)) [ ("name", `String "shrink-fixture") ])
;;

let test_config_patch_accepts_typed_skills () =
  let meta = shrink_base_meta () in
  let validate fields =
    Keeper_config_post.validate_dashboard_config_patch ~meta fields
  in
  let check_ok label fields =
    match validate fields with
    | Ok () -> ()
    | Error error -> Alcotest.failf "%s: %s" label error
  in
  let check_error label fields =
    match validate fields with
    | Error _ -> ()
    | Ok () -> Alcotest.failf "%s unexpectedly accepted" label
  in
  check_ok "empty object selects all" [ "skills", `Assoc [] ];
  check_ok "empty names select none"
    [ "skills", `Assoc [ "names", `List [] ] ];
  check_ok "exact names are accepted"
    [ ( "skills"
      , `Assoc
          [ "names", `List [ `String "ocaml-coding"; `String "proof-harness" ] ]
      )
    ];
  check_error "skills must be an object" [ "skills", `List [] ]
;;

let prepare_config_sync_keeper ~sw config name =
  let runtime_path =
    Config_dir_resolver.runtime_toml_path_for_base_path
      ~base_path:config.Workspace.base_path
  in
  mkdir_p (Filename.dirname runtime_path);
  write_file runtime_path config_sync_runtime_toml;
  (match Runtime.init_default ~config_path:runtime_path with
   | Ok () -> ()
   | Error error -> fail ("runtime init: " ^ error));
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String name
          ; "trace_id", `String (name ^ "-trace")
          ])
    with
    | Error error -> fail ("meta fixture: " ^ error)
    | Ok meta ->
      { meta with
        Masc.Keeper_meta_contract.autoboot_enabled = true
      ; proactive = { enabled = false }
        (* keeper_turn_up_config_persistence.persist requires instructions
           from somewhere -- explicit instructions_arg, an existing
           keeper.toml -- before it will materialize a keeper.
           None of the three config-sync fixtures below supply the first
           two, so this stands in for "keeper already has instructions
           from its meta / prior lifecycle" the way a real config-sync
           target would. *)
      ; instructions = name ^ " config-sync fixture instructions"
      }
  in
  (match Masc.Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error error -> fail ("write meta: " ^ error));
  match Masc.Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
  | Ok _ -> ()
  | Error error ->
    fail (Masc.Keeper_owner_registry.install_error_to_string error)

let write_config_sync_toml config name =
  let dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path
  in
  mkdir_p dir;
  let path = Filename.concat dir (name ^ ".toml") in
  write_file path
    (Printf.sprintf
       "[keeper]\nsandbox_profile = \"local\"\ninstructions = \"%s config-sync fixture instructions\"\nautoboot_enabled = false\nproactive_enabled = false\n"
       name);
  path

let post_config ?(inject_revision = true) ~sw ~clock ~state ~name body =
  let body =
    match Yojson.Safe.from_string body with
    | `Assoc fields
      when inject_revision
           && not (List.mem_assoc "expected_config_revision" fields) ->
      let config = Lib.Mcp_server.workspace_config state in
      let revision =
        match
          Masc.Keeper_turn_up_config_persistence.current_config_revision
            ~config
            ~keeper_name:name
        with
        | Ok revision ->
          Masc.Keeper_turn_up_config_persistence.config_revision_to_yojson revision
        | Error detail -> failf "read manifest revision: %s" detail
      in
      Yojson.Safe.to_string
        (`Assoc (("expected_config_revision", revision) :: fields))
    | json -> Yojson.Safe.to_string json
  in
  let output = Buffer.create 512 in
  let connection =
    Httpun.Server_connection.create (fun reqd ->
      Keeper_config_post.handle_keeper_config_post
        ~sw ~clock state "dashboard-test" (Httpun.Reqd.request reqd) reqd body)
  in
  let request =
    Printf.sprintf "POST /api/v1/keepers/%s/config HTTP/1.1\r\nHost: x\r\n\r\n" name
  in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
  let rec drain () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let bytes =
        List.fold_left
          (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
            Buffer.add_string output
              (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
            total + iov.len)
          0 iovecs
      in
      Httpun.Server_connection.report_write_result connection (`Ok bytes);
      drain ()
    | `Yield | `Close _ -> ()
  in
  drain ();
  let raw = Buffer.contents output in
  let body =
    match List.rev (String.split_on_char '\n' raw) with
    | body :: _ -> String.trim body
    | [] -> fail "HTTP response has no body"
  in
  raw, Yojson.Safe.from_string body

let post_runtime_assignment ?set_assignment ~state body =
  let output = Buffer.create 512 in
  let connection =
    Httpun.Server_connection.create (fun reqd ->
      match set_assignment with
      | None ->
        Server_routes_http_routes_dashboard.For_testing.handle_runtime_assignment_post
          state "dashboard-test" (Httpun.Reqd.request reqd) reqd body
      | Some set_assignment ->
        Server_routes_http_routes_dashboard.For_testing
        .handle_runtime_assignment_post_with
          ~set_assignment state "dashboard-test" (Httpun.Reqd.request reqd) reqd body)
  in
  let request =
    "POST /api/v1/runtime/config/assignment HTTP/1.1\r\nHost: x\r\n\r\n"
  in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
  ignore
    (Httpun.Server_connection.read_eof connection input ~off:0
       ~len:(Bigstringaf.length input));
  let rec drain () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let bytes =
        List.fold_left
          (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
            Buffer.add_string output
              (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
            total + iov.len)
          0 iovecs
      in
      Httpun.Server_connection.report_write_result connection (`Ok bytes);
      drain ()
    | `Yield | `Close _ -> ()
  in
  drain ();
  let raw = Buffer.contents output in
  let body =
    match List.rev (String.split_on_char '\n' raw) with
    | body :: _ -> String.trim body
    | [] -> fail "HTTP response has no body"
  in
  raw, Yojson.Safe.from_string body

let expect_http_status label status raw =
  let prefix = Printf.sprintf "HTTP/1.1 %d" status in
  if not (String.starts_with ~prefix raw)
  then failf "%s: expected %s, got %s" label prefix raw

let config_reconciliation_response ~name error =
  let output = Buffer.create 512 in
  let connection =
    Httpun.Server_connection.create (fun reqd ->
      Keeper_config_post.For_testing.respond_config_reconciliation
        ~request:(Httpun.Reqd.request reqd) reqd ~name ~error)
  in
  let request = "POST /api/v1/keepers/test/config HTTP/1.1\r\nHost: x\r\n\r\n" in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
  ignore
    (Httpun.Server_connection.read_eof connection input ~off:0
       ~len:(Bigstringaf.length input));
  let rec drain () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let bytes =
        List.fold_left
          (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
            Buffer.add_string output
              (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
            total + iov.len)
          0 iovecs
      in
      Httpun.Server_connection.report_write_result connection (`Ok bytes);
      drain ()
    | `Yield | `Close _ -> ()
  in
  drain ();
  let raw = Buffer.contents output in
  let body =
    match List.rev (String.split_on_char '\n' raw) with
    | body :: _ -> String.trim body
    | [] -> fail "HTTP response has no body"
  in
  raw, Yojson.Safe.from_string body

let test_composite_reconciliation_response_preserves_both_authorities () =
  let manifest : Masc.Keeper_turn_up_config_persistence.reconciliation =
    { path = "/workspace/.masc/config/keepers/alpha.toml"
    ; detail = "manifest restore failed"
    ; observed =
        Masc.Keeper_turn_up_config_persistence.Observed_revision
          Masc.Keeper_turn_up_config_persistence.Missing
    }
  in
  let runtime_assignment :
      Masc.Keeper_turn_up_config_persistence.runtime_reconciliation =
    { path = Some "/workspace/.masc/config/runtime.toml"
    ; detail = "runtime restore durability unconfirmed"
    }
  in
  let error =
    Masc.Keeper_turn_up_update.For_testing.composite_reconciliation_required_data
      { manifest = Some manifest; runtime_assignment = Some runtime_assignment }
  in
  let result =
    Masc.Keeper_types_profile.tool_result_error_data
      ~class_:Tool_result.Runtime_failure error
  in
  let projected =
    match Masc.Keeper_turn_up_update.config_reconciliation_required_of_result result with
    | Some projected -> projected
    | None -> fail "composite reconciliation was not classified"
  in
  let raw, json = config_reconciliation_response ~name:"alpha" projected in
  expect_http_status "composite reconciliation" 503 raw;
  let open Yojson.Safe.Util in
  check string "typed composite reconciliation code"
    "keeper_config_composite_reconciliation_required"
    (json |> member "error" |> member "code" |> to_string);
  check string "config application is closed indeterminate state" "indeterminate"
    (json |> member "config_application" |> member "state" |> to_string);
  check bool "old config_applied boolean is absent" true
    (json |> member "config_applied" = `Null);
  check string "manifest authority detail survives"
    "manifest restore failed"
    (json |> member "error" |> member "manifest" |> member "detail" |> to_string);
  check string "runtime authority detail survives"
    "runtime restore durability unconfirmed"
    (json |> member "error" |> member "runtime_assignment"
     |> member "detail" |> to_string)

let test_config_post_requires_expected_revision () =
  with_test_env @@ fun ~env ~sw ~config ->
  let name = "config-sync-revision-required" in
  prepare_config_sync_keeper ~sw config name;
  ignore (write_config_sync_toml config name);
  let raw, _ =
    post_config ~inject_revision:false ~sw ~clock:(Eio.Stdenv.clock env)
      ~state:(Lib.Mcp_server.For_testing.create_state ~base_path:config.base_path)
      ~name {|{"proactive_enabled":true}|}
  in
  check bool "missing revision HTTP 400" true
    (String.starts_with ~prefix:"HTTP/1.1 400" raw);
  ignore
    (Masc.Keeper_keepalive.stop_keepalive_and_await
       ~base_path:config.base_path name)

let test_direct_assignment_route_rejects_stale_revision_without_write () =
  with_test_env @@ fun ~env:_ ~sw ~config ->
  let name = "direct-assignment-cas" in
  prepare_config_sync_keeper ~sw config name;
  let runtime_path =
    Config_dir_resolver.runtime_toml_path_for_base_path
      ~base_path:config.base_path
  in
  let expected =
    match Runtime.observe_keeper_assignment ~runtime_config_path:runtime_path
            ~keeper_name:name () with
    | Ok receipt -> receipt.value
    | Error detail -> fail detail
  in
  let body =
    `Assoc
      [ "keeper_name", `String name
      ; "runtime_id", `String "test_provider.test_model"
      ; "expected_assignment_revision", Runtime.keeper_assignment_revision_to_yojson expected
      ]
    |> Yojson.Safe.to_string
  in
  let state = Lib.Mcp_server.For_testing.create_state ~base_path:config.base_path in
  let winner_raw, _ = post_runtime_assignment ~state body in
  expect_http_status "direct assignment winner" 200 winner_raw;
  let after_winner = read_file runtime_path in
  let loser_raw, loser_json = post_runtime_assignment ~state body in
  expect_http_status "direct assignment stale writer" 409 loser_raw;
  let open Yojson.Safe.Util in
  check string "direct conflict is typed"
    "runtime_assignment_revision_conflict"
    (loser_json |> member "error" |> member "code" |> to_string);
  check string "stale direct write changed no bytes"
    after_winner (read_file runtime_path);
  ignore
    (Masc.Keeper_keepalive.stop_keepalive_and_await
       ~base_path:config.base_path name)

let test_direct_assignment_intervening_write_fences_keeper_config_post () =
  with_test_env @@ fun ~env ~sw ~config ->
  let name = "direct-assignment-fences-config" in
  prepare_config_sync_keeper ~sw config name;
  ignore (write_config_sync_toml config name);
  let expected_config =
    match
      Masc.Keeper_turn_up_config_persistence.current_config_revision
        ~config ~keeper_name:name
    with
    | Ok revision -> revision
    | Error detail -> fail detail
  in
  let state = Lib.Mcp_server.For_testing.create_state ~base_path:config.base_path in
  let direct_body =
    `Assoc
      [ "keeper_name", `String name
      ; "runtime_id", `String "test_provider.test_model"
      ; ( "expected_assignment_revision"
        , Runtime.keeper_assignment_revision_to_yojson
            expected_config.runtime_assignment )
      ]
    |> Yojson.Safe.to_string
  in
  let direct_raw, _ = post_runtime_assignment ~state direct_body in
  expect_http_status "intervening direct assignment committed" 200 direct_raw;
  let keeper_body =
    `Assoc
      [ ( "expected_config_revision"
        , Masc.Keeper_turn_up_config_persistence.config_revision_to_yojson
            expected_config )
      ; "proactive_enabled", `Bool true
      ]
    |> Yojson.Safe.to_string
  in
  let keeper_raw, keeper_json =
    post_config ~inject_revision:false ~sw ~clock:(Eio.Stdenv.clock env)
      ~state ~name keeper_body
  in
  check bool "stale Keeper config POST HTTP 409" true
    (String.starts_with ~prefix:"HTTP/1.1 409" keeper_raw);
  let open Yojson.Safe.Util in
  check string "Keeper POST observes composite conflict"
    "keeper_config_revision_conflict"
    (keeper_json |> member "error" |> member "code" |> to_string);
  ignore
    (Masc.Keeper_keepalive.stop_keepalive_and_await
       ~base_path:config.base_path name)

let test_direct_assignment_route_surfaces_runtime_lock_release_warning () =
  with_test_env @@ fun ~env:_ ~sw ~config ->
  let name = "direct-assignment-release-warning" in
  prepare_config_sync_keeper ~sw config name;
  let runtime_path =
    Config_dir_resolver.runtime_toml_path_for_base_path
      ~base_path:config.base_path
  in
  let expected =
    match Runtime.observe_keeper_assignment ~runtime_config_path:runtime_path
            ~keeper_name:name () with
    | Ok receipt -> receipt.value
    | Error detail -> fail detail
  in
  let lock_path = runtime_path ^ ".lock" in
  let release_failure =
    { File_lock_eio.lock_path
    ; phase = File_lock_eio.Release_process_lock
    ; cause =
        { File_lock_eio.error = Unix.EIO
        ; operation = "injected_route_release_after_commit"
        ; argument = lock_path
        }
    ; cleanup_failure = None
    }
  in
  let set_assignment ~runtime_config_path ~keeper_name ~runtime_id ~expected () =
    Runtime.Assignment_for_testing.set_with_release_failure
      ~release_failure ~runtime_config_path ~keeper_name ~runtime_id ~expected ()
  in
  let body =
    `Assoc
      [ "keeper_name", `String name
      ; "runtime_id", `String "test_provider.test_model"
      ; "expected_assignment_revision", Runtime.keeper_assignment_revision_to_yojson expected
      ]
    |> Yojson.Safe.to_string
  in
  let state = Lib.Mcp_server.For_testing.create_state ~base_path:config.base_path in
  let raw, json = post_runtime_assignment ~set_assignment ~state body in
  expect_http_status "committed warning response" 200 raw;
  let open Yojson.Safe.Util in
  check string "route preserves typed release warning"
    "runtime_config_lock_release_unconfirmed"
    (json |> member "commit" |> member "warnings" |> index 0
     |> member "code" |> to_string);
  ignore
    (Masc.Keeper_keepalive.stop_keepalive_and_await
       ~base_path:config.base_path name)

let test_config_post_rejects_second_writer_with_same_revision () =
  with_test_env @@ fun ~env ~sw ~config ->
  let name = "config-sync-cas" in
  prepare_config_sync_keeper ~sw config name;
  let toml_path = write_config_sync_toml config name in
  let initial_revision =
    match
      Masc.Keeper_turn_up_config_persistence.current_config_revision
        ~config
        ~keeper_name:name
    with
    | Ok revision -> revision
    | Error detail -> failf "initial revision: %s" detail
  in
  let body proactive_enabled =
    `Assoc
      [ ( "expected_config_revision"
        , Masc.Keeper_turn_up_config_persistence.config_revision_to_yojson
            initial_revision )
      ; "proactive_enabled", `Bool proactive_enabled
      ]
    |> Yojson.Safe.to_string
  in
  let state =
    Lib.Mcp_server.For_testing.create_state ~base_path:config.base_path
  in
  let winner_raw, _ =
    post_config ~sw ~clock:(Eio.Stdenv.clock env) ~state ~name (body true)
  in
  check bool "winner HTTP 200" true
    (String.starts_with ~prefix:"HTTP/1.1 200" winner_raw);
  let loser_raw, loser_json =
    post_config ~sw ~clock:(Eio.Stdenv.clock env) ~state ~name (body false)
  in
  check bool "loser HTTP 409" true
    (String.starts_with ~prefix:"HTTP/1.1 409" loser_raw);
  let open Yojson.Safe.Util in
  check string "typed conflict code" "keeper_config_revision_conflict"
    (loser_json |> member "error" |> member "code" |> to_string);
  check string "typed expected revision state" "sha256"
    (loser_json
     |> member "error"
     |> member "expected"
     |> member "manifest"
     |> member "state"
     |> to_string);
  check string "typed observed revision state" "sha256"
    (loser_json
     |> member "error"
     |> member "observed"
     |> member "manifest"
     |> member "state"
     |> to_string);
  check bool "loser did not apply config" false
    (loser_json |> member "config_applied" |> to_bool);
  let doc =
    match
      Keeper_toml_loader.parse_toml
        (In_channel.with_open_bin toml_path In_channel.input_all)
    with
    | Ok doc -> doc
    | Error error -> fail error
  in
  check (option bool) "winner remains durable" (Some true)
    (Keeper_toml_loader.toml_bool_opt doc "keeper.proactive_enabled");
  ignore
    (Masc.Keeper_keepalive.stop_keepalive_and_await
       ~base_path:config.base_path name)

let test_config_post_restarts_from_atomic_toml () =
  with_test_env @@ fun ~env ~sw ~config ->
  let name = "config-sync-success" in
  prepare_config_sync_keeper ~sw config name;
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Masc.Keeper_keepalive.stop_keepalive_and_await
           ~base_path:config.base_path name))
    (fun () ->
      let toml_path = write_config_sync_toml config name in
      let _, response =
        post_config ~sw ~clock:(Eio.Stdenv.clock env)
           ~state:(Lib.Mcp_server.For_testing.create_state ~base_path:config.base_path)
           ~name {|{"autoboot_enabled":true,"proactive_enabled":true}|}
      in
      check string "readback carries manifest SHA-256 revision" "sha256"
        Yojson.Safe.Util.
          (response |> member "config_revision" |> member "manifest"
           |> member "state" |> to_string);
      check bool "write receipt says config applied" true
        Yojson.Safe.Util.
          (response |> member "config_write" |> member "applied" |> to_bool);
      check string "write receipt carries exact revision" "sha256"
        Yojson.Safe.Util.
          (response |> member "config_write" |> member "revision"
           |> member "manifest" |> member "state" |> to_string);
      let parsed =
        Keeper_toml_loader.parse_toml
          (In_channel.with_open_bin toml_path In_channel.input_all)
      in
      (match parsed with
       | Error error -> fail error
       | Ok doc ->
         check (option bool) "autoboot committed" (Some true)
           (Keeper_toml_loader.toml_bool_opt doc "keeper.autoboot_enabled");
         check (option bool) "proactive committed" (Some true)
           (Keeper_toml_loader.toml_bool_opt doc "keeper.proactive_enabled"));
      check bool "running projection converged" true
        (match Masc.Keeper_registry.get ~base_path:config.base_path name with
         | Some entry -> entry.meta.proactive.enabled
         | None -> false))

let test_config_post_materializes_missing_toml () =
  with_test_env @@ fun ~env ~sw ~config ->
  let name = "config-sync-no-toml" in
  prepare_config_sync_keeper ~sw config name;
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Masc.Keeper_keepalive.stop_keepalive_and_await
           ~base_path:config.base_path
           name))
    (fun () ->
      let raw, json =
        post_config ~sw ~clock:(Eio.Stdenv.clock env)
          ~state:(Lib.Mcp_server.For_testing.create_state ~base_path:config.base_path)
          ~name {|{"proactive_enabled":true}|}
      in
      check bool "HTTP 200" true (String.starts_with ~prefix:"HTTP/1.1 200" raw);
      let open Yojson.Safe.Util in
      check bool "runtime projection applied proactive config" true
        (json |> member "proactive" |> member "enabled" |> to_bool);
      let path =
        Config_dir_resolver.keepers_dir_for_base_path
          ~base_path:config.Workspace.base_path
        |> fun dir -> Filename.concat dir (name ^ ".toml")
      in
      check bool "missing declarative TOML was materialized" true
        (Sys.file_exists path);
      let parsed =
        Keeper_toml_loader.parse_toml
          (In_channel.with_open_bin path In_channel.input_all)
      in
      match parsed with
      | Error error -> fail error
      | Ok doc ->
        check (option bool) "materialized proactive config" (Some true)
          (Keeper_toml_loader.toml_bool_opt doc "keeper.proactive_enabled"))

let test_config_post_rolls_back_missing_runtime_assignment () =
  with_test_env @@ fun ~env ~sw ~config ->
  let name = "config-sync-partial" in
  prepare_config_sync_keeper ~sw config name;
  let toml_path = write_config_sync_toml config name in
  let runtime_path =
    Config_dir_resolver.runtime_toml_path_for_base_path
      ~base_path:config.base_path
  in
  Sys.remove runtime_path;
  let raw, json =
    post_config ~sw ~clock:(Eio.Stdenv.clock env)
      ~state:(Lib.Mcp_server.For_testing.create_state ~base_path:config.base_path)
      ~name {|{"proactive_enabled":true,"runtime_id":"missing.runtime"}|}
  in
  check bool "HTTP 503" true (String.starts_with ~prefix:"HTTP/1.1 503" raw);
  let open Yojson.Safe.Util in
  check bool "TOML rolled back" false (json |> member "config_applied" |> to_bool);
  check bool "runtime not synced" false (json |> member "runtime_sync" |> to_bool);
  check string "typed failure" "keeper_config_publication_rolled_back"
    (json |> member "error" |> member "code" |> to_string);
  check bool "runtime failure preserves rolled-back write receipt" false
    (json |> member "config_write" |> member "applied" |> to_bool);
  let doc =
    match
      Keeper_toml_loader.parse_toml
        (In_channel.with_open_bin toml_path In_channel.input_all)
    with
    | Ok doc -> doc
    | Error error -> fail error
  in
  check (option bool) "TOML is rolled back" (Some false)
    (Keeper_toml_loader.toml_bool_opt doc "keeper.proactive_enabled")

let test_config_post_prevalidates_mixed_request () =
  with_test_env @@ fun ~env ~sw ~config ->
  let name = "config-sync-invalid-mixed" in
  prepare_config_sync_keeper ~sw config name;
  let toml_path = write_config_sync_toml config name in
  let raw, _ =
    post_config ~sw ~clock:(Eio.Stdenv.clock env)
      ~state:(Lib.Mcp_server.For_testing.create_state ~base_path:config.base_path)
      ~name {|{"proactive_enabled":true,"allowed_paths":["*"]}|}
  in
  check bool "HTTP 400" true (String.starts_with ~prefix:"HTTP/1.1 400" raw);
  let doc =
    match
      Keeper_toml_loader.parse_toml
        (In_channel.with_open_bin toml_path In_channel.input_all)
    with
    | Ok doc -> doc
    | Error error -> fail error
  in
  check (option bool) "activation was not committed" (Some false)
    (Keeper_toml_loader.toml_bool_opt doc "keeper.proactive_enabled")

let test_config_post_round_trips_typed_tools_patch () =
  with_test_env @@ fun ~env ~sw ~config ->
  let name = "config-sync-tools" in
  prepare_config_sync_keeper ~sw config name;
  let toml_path = write_config_sync_toml config name in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_tool_approval_mode.set
        (Masc.Keeper_tool_approval_mode.shared ())
        ~keeper_name:name
        Masc.Keeper_tool_approval_mode.Auto;
      ignore
        (Masc.Keeper_keepalive.stop_keepalive_and_await
           ~base_path:config.base_path
           name))
    (fun () ->
       let raw, json =
         post_config
           ~sw
           ~clock:(Eio.Stdenv.clock env)
           ~state:
             (Lib.Mcp_server.For_testing.create_state
                ~base_path:config.base_path)
           ~name
           {|{"tools":{"native":"full"}}|}
       in
       check bool "HTTP 200" true (String.starts_with ~prefix:"HTTP/1.1 200" raw);
       let open Yojson.Safe.Util in
       check string "readback native" "full"
         (json |> member "tools" |> member "native" |> to_string);
       check string "Auto rejects full preview" "rejected"
         (json
          |> member "tools"
          |> member "full_native_admission"
          |> member "status"
          |> to_string);
       let doc =
         match
           Keeper_toml_loader.parse_toml
             (In_channel.with_open_bin toml_path In_channel.input_all)
         with
         | Ok doc -> doc
         | Error error -> fail error
       in
       check (option string) "TOML native" (Some "full")
         (Keeper_toml_loader.toml_string_opt doc "keeper.tools.native");
       (* The POST above restarts this keeper's keepalive lane, and that lane
          takes the turn slot once it runs. A second POST arriving after it
          does gets keeper_turn_in_flight instead of 200 -- the handler
          behaving correctly, and this assertion racing it. CI logged exactly
          that refusal on the line before this check, and the same commit
          passed at 19:02 and failed at 19:10.

          The race does not reproduce locally: the suite passes eight runs in
          a row both with and without this call, and sleeping a second in its
          place does not lose it either. So this is the mechanism CI named,
          not a mechanism reproduced here. What the call does buy regardless
          is that the second POST starts from the state the first one found,
          instead of from whatever the lane reached in between. *)
       ignore
         (Masc.Keeper_keepalive.stop_keepalive_and_await
            ~base_path:config.base_path
            name);
       Masc.Keeper_tool_approval_mode.set
         (Masc.Keeper_tool_approval_mode.shared ())
         ~keeper_name:name
         Masc.Keeper_tool_approval_mode.Yolo;
       let yolo_raw, yolo_json =
         post_config
           ~sw
           ~clock:(Eio.Stdenv.clock env)
           ~state:
             (Lib.Mcp_server.For_testing.create_state
                ~base_path:config.base_path)
           ~name
           {|{"tools":{"native":"full"}}|}
       in
       check bool "Yolo preview HTTP 200" true
         (String.starts_with ~prefix:"HTTP/1.1 200" yolo_raw);
       check string "Yolo allows full preview" "allowed"
         Yojson.Safe.Util.(
           yolo_json
           |> member "tools"
           |> member "full_native_admission"
           |> member "status"
           |> to_string);
       Masc.Keeper_tool_approval_mode.set
         (Masc.Keeper_tool_approval_mode.shared ())
         ~keeper_name:name
         Masc.Keeper_tool_approval_mode.Auto;
       let invalid_raw, _ =
         post_config
           ~sw
           ~clock:(Eio.Stdenv.clock env)
           ~state:
             (Lib.Mcp_server.For_testing.create_state
                ~base_path:config.base_path)
           ~name
           {|{"tools":{"native":"yolo"}}|}
       in
       check bool "invalid native is HTTP 400" true
         (String.starts_with ~prefix:"HTTP/1.1 400" invalid_raw))
;;

let test_config_post_round_trips_typed_skills_patch () =
  with_test_env @@ fun ~env ~sw ~config ->
  let name = "config-sync-skills" in
  prepare_config_sync_keeper ~sw config name;
  let toml_path = write_config_sync_toml config name in
  let initial_content =
    In_channel.with_open_bin toml_path In_channel.input_all
    ^ "\n[keeper.skills]\n"
    ^ "names = [\"initial-skill\"]\n"
    ^ "\n[keeper.tools]\n"
    ^ "native = \"read\"\n"
  in
  write_file toml_path initial_content;
  let parse_toml label =
    match
      Keeper_toml_loader.parse_toml
        (In_channel.with_open_bin toml_path In_channel.input_all)
    with
    | Ok doc -> doc
    | Error error -> failf "%s: %s" label error
  in
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Masc.Keeper_keepalive.stop_keepalive_and_await
           ~base_path:config.base_path
           name))
    (fun () ->
       let open Yojson.Safe.Util in
       let exact_raw, exact_json =
         post_config
           ~sw
           ~clock:(Eio.Stdenv.clock env)
           ~state:
             (Lib.Mcp_server.For_testing.create_state
                ~base_path:config.base_path)
           ~name
           {|{"skills":{"names":["ocaml-coding","proof-harness"]}}|}
       in
       check bool "exact selection HTTP 200" true
         (String.starts_with ~prefix:"HTTP/1.1 200" exact_raw);
       check (list string) "exact selection reads back"
         [ "ocaml-coding"; "proof-harness" ]
         (exact_json
          |> member "skills"
          |> member "names"
          |> to_list
          |> List.map to_string);
       let exact_doc = parse_toml "parse exact selection TOML" in
       check (list string) "exact selection persisted"
         [ "ocaml-coding"; "proof-harness" ]
         (Keeper_toml_loader.toml_string_list
            exact_doc
            "keeper.skills.names");
       ignore
         (Masc.Keeper_keepalive.stop_keepalive_and_await
            ~base_path:config.base_path
            name);
       let none_raw, none_json =
         post_config
           ~sw
           ~clock:(Eio.Stdenv.clock env)
           ~state:
             (Lib.Mcp_server.For_testing.create_state
                ~base_path:config.base_path)
           ~name
           {|{"skills":{"names":[]}}|}
       in
       check bool "empty selection HTTP 200" true
         (String.starts_with ~prefix:"HTTP/1.1 200" none_raw);
       check (list string) "empty selection reads back" []
         (none_json
          |> member "skills"
          |> member "names"
          |> to_list
          |> List.map to_string);
       let none_doc = parse_toml "parse empty selection TOML" in
       check (list string) "empty selection persisted" []
         (Keeper_toml_loader.toml_string_list
            none_doc
            "keeper.skills.names");
       check (option string) "nested native posture survives exact and none"
         (Some "read")
         (Keeper_toml_loader.toml_string_opt
            none_doc
            "keeper.tools.native");
       ignore
         (Masc.Keeper_keepalive.stop_keepalive_and_await
            ~base_path:config.base_path
            name);
       let all_raw, all_json =
         post_config
           ~sw
           ~clock:(Eio.Stdenv.clock env)
           ~state:
             (Lib.Mcp_server.For_testing.create_state
                ~base_path:config.base_path)
           ~name
           {|{"skills":{}}|}
       in
       check bool "all selection HTTP 200" true
         (String.starts_with ~prefix:"HTTP/1.1 200" all_raw);
       check bool "all selection reads back as null" true
         (all_json |> member "skills" |> member "names" = `Null);
       let all_doc = parse_toml "parse all selection TOML" in
       check bool "nested Skill key removed" true
         (List.assoc_opt "keeper.skills.names" all_doc = None);
       check (option string) "nested native posture survives key removal"
         (Some "read")
         (Keeper_toml_loader.toml_string_opt
            all_doc
            "keeper.tools.native"))
;;

(* #10710 regression: [keepers_dashboard_json] must aggregate every persisted
   keeper through the bounded fiber pool. Before the fiber-batch change the
   per-keeper enrich ran as an unbounded fan-out; this pins that all registered
   keepers still surface in the envelope (and that the pool cap stays a sane
   positive bound). *)
let test_keepers_dashboard_json_fiber_batch_collects_all_keepers () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  ignore (Workspace.init config ~agent_name:None);
  let names = [ "fiber-a"; "fiber-b"; "fiber-c" ] in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun name ->
          Masc.Keeper_registry.For_testing.unregister
            ~base_path:config.base_path
            name)
        names)
    (fun () ->
      List.iter
        (fun name ->
          let meta =
            match
              Masc_test_deps.meta_of_json_fixture
                (`Assoc
                  [ "name", `String name
                  ; "trace_id", `String (name ^ "-trace")
                  ])
            with
            | Ok meta -> meta
            | Error error -> fail ("meta fixture: " ^ error)
          in
          (match Masc.Keeper_meta_store.replace_snapshot config meta with
           | Ok () -> ()
           | Error error -> fail ("write meta: " ^ error));
          ignore
            (Masc.Keeper_registry.For_testing.register
               ~base_path:config.base_path
               name
               meta))
        names;
      let json = Dashboard_http_keeper.keepers_dashboard_json config in
      let open Yojson.Safe.Util in
      let keeper_rows = json |> member "keepers" |> to_list in
      let row_names =
        keeper_rows
        |> List.map (fun row -> row |> member "name" |> to_string)
        |> List.sort String.compare
      in
      check (list string) "fiber pool collects every registered keeper"
        (List.sort String.compare names)
        row_names;
      check int "total mirrors collected keeper count"
        (List.length names)
        (json |> member "total" |> to_int))


(* The `.mli` calls the error clear on success a deliberate contract, and
   nothing tested it. It is also exactly what a snapshot swap could drop,
   since the fields now have to be named in the record update rather than
   simply assigned. *)
let test_cached_surface_success_clears_the_previous_error () =
  let module Cache = Server_dashboard_http_cache in
  let surface = Cache.create_cached_surface (`Assoc [ "seed", `Bool true ]) in
  Cache.mark_cached_surface_error surface (Failure "compute blew up");
  let errored = Cache.snapshot surface in
  check bool "the error is recorded" true (Option.is_some errored.Cache.last_error);
  check bool "the error is stamped" true (Option.is_some errored.Cache.last_error_at);
  check bool "the error has a unix stamp" true
    (Option.is_some errored.Cache.last_error_unix);
  Cache.mark_cached_surface_success surface (`Assoc [ "fresh", `Bool true ]);
  let succeeded = Cache.snapshot surface in
  check bool "success clears the error" true
    (Option.is_none succeeded.Cache.last_error);
  check bool "success clears the error stamp" true
    (Option.is_none succeeded.Cache.last_error_at);
  check bool "success clears the error unix stamp" true
    (Option.is_none succeeded.Cache.last_error_unix);
  check bool "success records its own stamp" true
    (Option.is_some succeeded.Cache.last_success_unix);
  check
    string
    "success installs the new payload"
    (Yojson.Safe.to_string (`Assoc [ "fresh", `Bool true ]))
    (Yojson.Safe.to_string succeeded.Cache.json)
;;

let test_tool_call_fleet_cache_tracks_durable_revision () =
  let base_path = test_dir () in
  Fun.protect
    ~finally:(fun () ->
      Dashboard_cache.invalidate_all ();
      Masc.Keeper_tool_call_log.reset_for_testing ();
      cleanup_dir base_path)
    (fun () ->
       Masc.Keeper_tool_call_log.reset_for_testing ();
       Masc.Keeper_tool_call_log.init ~base_path ();
       let masc_root =
         match Masc.Keeper_tool_call_log.configured_masc_root () with
         | Some value -> value
         | None -> fail "tool-call log did not retain its MASC root"
       in
       let key =
         Server_dashboard_http_keeper_api.tool_calls_fleet_cache_key ~masc_root
       in
       ignore
         (Dashboard_cache.get_or_compute key ~ttl:30.0 (fun () -> `List []));
       check bool "fleet cache is seeded" true (Option.is_some (Dashboard_cache.peek key));
       Masc.Keeper_tool_call_log.log_call
         ~keeper_name:"delta"
         ~tool_name:"keeper_time_now"
         ~input:(`Assoc [])
         ~output_text:"ok"
         ~success:true
         ~duration_ms:1.0
         ();
       check int "durable append advances revision" 1
         (Masc.Keeper_tool_call_log.committed_revision ());
       let same_key =
         Server_dashboard_http_keeper_api.tool_calls_fleet_cache_key ~masc_root
       in
       check string "cache identity remains bounded" key same_key;
       check bool "revision change invalidates stale fleet rows" true
         (Option.is_none (Dashboard_cache.peek key)))
;;

let test_skill_evidence_joins_activation_and_composition () =
  let source_id =
    match Skill_source_config.source_id_of_string "workspace" with
    | Ok value -> value
    | Error detail -> fail detail
  in
  let package_id =
    match Skill_catalog_snapshot.package_id_of_directory "release-checklist" with
    | Ok value -> value
    | Error _ -> fail "invalid Skill package fixture"
  in
  let content_revision =
    match Skill_reference.content_revision_of_string (String.make 64 'a') with
    | Ok value -> value
    | Error _ -> fail "invalid content revision fixture"
  in
  let snapshot_revision =
    match Skill_catalog_snapshot.snapshot_revision_of_string (String.make 64 'b') with
    | Ok value -> value
    | Error _ -> fail "invalid snapshot revision fixture"
  in
  let identity =
    Skill_reference.make_identity
      ~source_id
      ~package_id
      ~name:"release-checklist"
  in
  let reference = Skill_reference.make ~identity ~content_revision in
  let activation =
    match
      Lib.Keeper_skill_activation_ledger.make_activation
        ~identity
        ~content_revision
        ~snapshot_revision
        ~turn_ref:(Ids.Turn_ref.make ~trace_id:"trace-evidence" ~absolute_turn:1)
        ~runtime_id:"codex.default"
        ~skill_tool_use_id:"skill-call-1"
        ~agent_core_turn:1
        ~invocation:
          (Lib.Keeper_skill_activation_ledger.Instruction_invocation
             { origin = Session_instruction
             ; served_content = Skill_body { bytes = 4; sha256 = String.make 64 'c' }
             })
        ~activated_at:"2026-08-28T03:00:00Z"
    with
    | Ok value -> value
    | Error _ -> fail "invalid Skill activation fixture"
  in
  let run_id = "composition-run-1" in
  let node =
    `Assoc
      [ "record_kind", `String "tool_call"
      ; "composition_run_id", `String run_id
      ; "tool_name", `String "keeper_time_now"
      ]
  in
  let json =
    let composition =
      `Assoc
        [ "schema", `String "masc.skill-composition-evidence/v1"
        ; "reference", Skill_reference.to_yojson reference
        ; "composition_run_id", `String run_id
        ; "parent_tool_use_id", `String "skill-call-1"
        ; "parent_turn", `Int 1
        ; "parent_planned_index", `Int 0
        ; "request_id", `Null
        ; "keeper", `String "delta"
        ; "composition_tool", `String "keeper_compose_release-checklist"
        ; "composition_execution", `String "inline"
        ; "executor_settlements", `List [ node ]
        ; ( "result"
          , `Assoc
              [ "disposition", `String "completed"
              ; "tool_name", `String "keeper_compose_release-checklist"
              ; "duration_ms", `Float 1.0
              ; "data", `Assoc [ "actions", `List [ node ] ]
              ] )
        ; "recorded_at", `Float 1.0
        ]
    in
    let activation =
      `Assoc
        [ "selection", `String "most_recent_observed"
        ; ( "evidence"
          , `Assoc
              [ "trace_id", `String "trace-evidence"
              ; ( "owner"
                , `Assoc
                    [ "status", `String "known"
                    ; ( "claims"
                      , `List
                          [ `Assoc
                              [ "keeper", `String "delta"
                              ; "source", `String "current_meta"
                              ]
                          ] )
                    ; "gaps", `List []
                    ] )
              ; ( "activation"
                , Lib.Keeper_skill_activation_ledger.activation_to_yojson
                    activation )
              ] )
        ]
    in
    Server_skill_evidence.For_testing.to_yojson
      ~reference
      ~composition:(Some composition)
      ~composition_records_read:1
      ~composition_scope:`Exact_reference_latest_completed
      ~composition_unavailable:[]
      ~activation:(Some activation)
      ~activation_scope:Incomplete_retained_trace_snapshot
      ~activation_sessions_inspected:187
      ~activation_ledgers_loaded:10
      ~activation_gaps:[]
      ~activation_owner_gap_count:0
  in
  let open Yojson.Safe.Util in
  check string "evidence schema" "masc.skill-evidence/v5"
    (json |> member "schema" |> to_string);
  check string "observed status" "observed" (json |> member "status" |> to_string);
  check string "activation keeper" "delta"
    (json |> member "activation" |> member "evidence" |> member "owner"
     |> member "claims" |> index 0 |> member "keeper" |> to_string);
  check int "composition node count" 1
    (json |> member "composition" |> member "executor_settlements" |> to_list
     |> List.length);
  check int "activation ledger coverage" 10
    (json |> member "coverage" |> member "activation_ledgers_loaded" |> to_int);
  check bool "bounded evidence coverage is incomplete" false
    (json |> member "coverage" |> member "coverage_complete" |> to_bool);
  check string
    "composition scan covers the exact-reference index"
    "exact_reference_latest_completed"
    (json |> member "coverage" |> member "composition_scope" |> to_string);
  check int "activation sessions inspected" 187
    (json |> member "coverage" |> member "activation_sessions_inspected"
     |> to_int);
  let not_observed =
    Server_skill_evidence.For_testing.to_yojson
      ~reference
      ~composition:None
      ~composition_records_read:0
      ~composition_scope:`Exact_reference_latest_completed
      ~composition_unavailable:[]
      ~activation:None
      ~activation_scope:Complete_retained_trace_snapshot
      ~activation_sessions_inspected:0
      ~activation_ledgers_loaded:0
      ~activation_gaps:[]
      ~activation_owner_gap_count:0
  in
  check string "bounded absence is not proof of never"
    "not_observed_in_retained_coverage"
    (not_observed |> member "status" |> to_string)
;;

let () =
  run "dashboard_http_core"
    [
      ( "executor_pool",
        [
          test_case "no pool stays on caller domain" `Quick
            test_run_dashboard_compute_without_pool_stays_in_current_domain;
          test_case "pool uses executor domain" `Quick
            test_run_dashboard_compute_with_pool_uses_executor_domain;
          test_case "pool worker runs nested cache inline" `Quick
            test_run_dashboard_compute_nested_cache_does_not_starve;
          test_case "shell payload includes paths diagnostics" `Quick
            test_dashboard_shell_http_json_includes_paths;
          test_case "shell runtime base_path prefers preserved input" `Quick
            test_dashboard_shell_http_json_prefers_preserved_base_path_input;
          test_case "runtime resolution accepts server repo under base path" `Quick
            test_runtime_resolution_accepts_server_repo_inside_base_path;
          test_case "shell bootstrap payload while prewarming" `Quick
            test_dashboard_shell_http_json_uses_bootstrap_payload_while_prewarming;
          test_case "shell reuses last good payload while prewarming" `Quick
            test_dashboard_shell_http_json_prefers_last_good_while_prewarming;
          test_case "shell records light last good payload" `Quick
            test_dashboard_shell_http_json_records_light_last_good;
          test_case "shell reuses light last good payload while prewarming" `Quick
            test_dashboard_shell_http_json_prefers_light_last_good_while_prewarming;
          test_case "operator snapshot hydrates on first default request" `Quick
            test_operator_snapshot_default_route_hydrates_first_success;
          test_case "tool-call fleet cache follows durable revision" `Quick
            test_tool_call_fleet_cache_tracks_durable_revision;
          test_case "dashboard query cache segment normalizes missing values" `Quick
            test_dashboard_query_cache_segment_normalizes_missing_values;
          test_case "dashboard query cache key partitions route params" `Quick
            test_dashboard_query_cache_key_partitions_route_params;
          test_case "dashboard query cache key encodes delimiter values" `Quick
            test_dashboard_query_cache_key_encodes_delimiter_values;
          test_case "cache key partitions by cluster" `Quick
            test_dashboard_cache_key_partitions_by_cluster;
          test_case "operator snapshot default route exposes provenance" `Quick
            test_operator_snapshot_default_route_exposes_provenance;
          test_case "operator digest default route exposes provenance" `Quick
            test_operator_digest_default_route_exposes_provenance;
          test_case "shell timeout fallback reports timing context" `Quick
            test_dashboard_shell_timeout_fallback_reports_timing_context;
          test_case "proof route registered in HTTP routers" `Quick
            test_dashboard_proof_route_registered_in_http_routers;
          test_case "Gate mode save reports recovery independently" `Quick
            test_gate_mode_change_json_separates_saved_mode_from_recovery;
          test_case "bootstrap omits eager goal tree" `Quick
            test_dashboard_bootstrap_omits_eager_goal_tree;
          test_case "planning payload keeps UTF-8 valid after truncation" `Quick
            test_dashboard_planning_http_json_keeps_utf8_valid_after_truncation;
          test_case "shell auth canonicalizes token owner" `Quick
            test_dashboard_shell_auth_json_canonicalizes_token_owner;
          test_case "shell auth reports missing token" `Quick
            test_dashboard_shell_auth_json_reports_missing_token;
          test_case "shell auth rejects stale token actor hint" `Quick
            test_dashboard_shell_auth_json_rejects_stale_token_actor_hint;
          test_case "shell auth rejects malformed credential" `Quick
            test_dashboard_shell_auth_json_rejects_malformed_credential;
          test_case "shell snapshot selector injects auth" `Quick
            test_dashboard_shell_snapshot_selector_injects_auth;
          test_case "execution actor canonicalizes token owner" `Quick
            test_execution_actor_for_request_canonicalizes_token_owner;
          test_case "execution force refresh bypasses default cache" `Quick
            test_dashboard_execution_force_refresh_bypasses_default_cache;
          test_case "execution trust default route uses cached surface" `Quick
            test_dashboard_execution_trust_default_route_uses_cached_surface;
          test_case "message JSON exposes temporal decay fields" `Quick
            test_dashboard_message_json_surfaces_temporal_fields;
          test_case "RFC-0138 shell wire returns snapshot when published" `Quick
            test_shell_snapshot_wire_returns_snapshot_when_published;
          test_case "RFC-0138 shell wire falls back when snapshot empty" `Quick
            test_shell_snapshot_wire_falls_back_when_empty;
          test_case "RFC-0204 shell wire light reads shell_light" `Quick
            test_shell_snapshot_wire_light_reads_shell_light;
          test_case "light shell carries runtime health SSOT" `Quick
            test_dashboard_shell_light_includes_runtime_health_ssot;
          test_case "shell separates configured and persisted keeper counts" `Quick
            test_dashboard_shell_separates_configured_and_persisted_keeper_counts;
          test_case "light shell counts agents from summary fields" `Quick
            test_dashboard_shell_light_counts_agents_from_summary_fields;
          test_case "RFC-0138 tools wire returns snapshot when actor omitted" `Quick
            test_tools_snapshot_wire_returns_snapshot_when_actor_omitted;
          test_case "RFC-0138 telemetry_summary wire returns snapshot" `Quick
            test_telemetry_summary_snapshot_wire_returns_snapshot;
          test_case "RFC-0138 telemetry_summary wire falls back when empty" `Quick
            test_telemetry_summary_snapshot_wire_falls_back_when_empty;
          test_case "RFC-0138 project-snapshot wire returns snapshot when populated" `Quick
            test_project_snapshot_wire_returns_snapshot_when_populated;
          test_case "telemetry n default is bounded (freeze guard)" `Quick
            test_telemetry_n_default_is_bounded;
          test_case "fleet-composite envelope is cached across polls" `Quick
            test_dashboard_fleet_composite_envelope_is_cached;
          test_case "state diagram runtime projection stays empty without meta" `Quick
            test_state_diagram_runtime_projection_missing_meta_stays_empty;
          test_case "keeper path extraction uses shared name grammar" `Quick
            test_keeper_name_extractors_use_shared_grammar;
          test_case "keeper paused-work route is exact" `Quick
            test_keeper_paused_work_route_is_admin_exact;
          test_case "keeper up route classifies and extracts" `Quick
            test_keeper_up_route_classifies_and_extracts;
          test_case "keeper sensitive GET permissions are exact" `Quick
            test_keeper_sensitive_get_permissions_are_exact;
          test_case "internal exact lane registry is Admin-only" `Quick
            test_internal_exact_lane_registry_is_admin_only;
          test_case "runtime probe route owns read permission" `Quick
            test_runtime_probe_route_owns_read_permission;
          test_case "event queue operator routes are exact" `Quick
            test_event_queue_operator_routes_are_exact;
          test_case "event operator keeps exact source refs across queue changes" `Quick
            test_event_operator_uses_exact_source_refs_across_unrelated_enqueues;
          test_case "observation metadata does not override terminal contract" `Quick
            test_composite_blocked_uses_terminal_contract_not_observational_metadata;
        ] );
      ( "dashboard behavior contracts",
        [ test_case "Skill evidence joins activation and composition" `Quick
            test_skill_evidence_joins_activation_and_composition;
          test_case "GitHub login stream includes CORS" `Quick
            test_keeper_github_login_stream_headers_include_cors;
          test_case "GitHub login stream flushes each event" `Quick
            test_keeper_github_login_stream_flushes_each_event;
          test_case "operator snapshot rejects stale publication races" `Quick
            test_operator_snapshot_publication_rejects_stale_races;
          test_case "operator snapshot error clears previous success" `Quick
            test_operator_snapshot_error_clears_previous_success;
          test_case
            "operator snapshot HTTP rejects stale success after store error"
            `Quick
            test_operator_snapshot_http_rejects_stale_success_after_store_error;
          test_case "proof payload exposes submission index" `Quick
            test_dashboard_proof_http_json_surfaces_submission_index;
          test_case "scheduled-automation reads its cache key" `Quick
            test_scheduled_automation_reads_its_cache_key;
          test_case "schedule exact lookup carries the wake history" `Quick
            test_schedule_exact_lookup_carries_the_wake_history;
          test_case "schedule page can be scoped to one target" `Quick
            test_schedule_page_can_be_scoped_to_one_target;
          test_case "schedule exact lookup names a blank id" `Quick
            test_schedule_exact_lookup_rejects_blank_id;
          test_case "agent-activity keys on its window" `Quick
            test_agent_activity_keys_on_its_window;
          test_case "execution trust uses narrow Keeper projection" `Quick
            test_execution_trust_uses_narrow_keeper_projection;
          test_case "execution trust cannot call full Keeper projection" `Quick
            test_execution_trust_does_not_call_full_keeper_projection;
          test_case "offline keeper composite exposes secret projection" `Quick
            test_offline_keeper_composite_exposes_secret_projection;
          test_case "state diagram runtime projection redacts live evidence" `Quick
            test_state_diagram_runtime_projection_redacts_live_runtime_evidence;
          test_case "activation config materializes missing TOML" `Quick
            test_config_post_materializes_missing_toml;
          test_case "reject without a reason is a bad request" `Quick
            test_gate_resolve_requires_reason_on_reject;
        ] );
      ( "lifecycle event classification (#22071)",
        [ test_case "typed wire lifecycle round-trips" `Quick
            test_lifecycle_event_wire_roundtrip;
          test_case "cache patchers cover the SSOT vocabulary" `Quick
            test_lifecycle_event_cache_patcher_coverage;
          test_case "cache patchers pin byte-identical values" `Quick
            test_lifecycle_event_display_values;
          test_case "paused lifecycle event keeps the paused status" `Quick
            test_paused_lifecycle_event_keeps_paused_status;
          test_case "reconciled lifecycle event preserves durable pause" `Quick
            test_reconciled_lifecycle_event_preserves_durable_pause;
          test_case "stopped lifecycle event stays offline" `Quick
            test_stopped_lifecycle_event_stays_offline;
          test_case "stopped lifecycle event preserves durable pause" `Quick
            test_stopped_lifecycle_event_preserves_durable_pause;
          test_case "cache patch rejects missing or unknown status" `Quick
            test_lifecycle_cache_patch_rejects_missing_or_unknown_status;
          test_case "running keeper reconciliation rebuilds continuity brief" `Quick
            test_running_keeper_reconciliation_rebuilds_continuity_brief;
        ] );
      ( "context-window shrink guard (#25062/#25268)",
        [ test_case "success clears the previous error" `Quick
            test_cached_surface_success_clears_the_previous_error;
          test_case "shrink of max_context_override is detected" `Quick
            test_context_shrink_detection;
          test_case "config patch accepts typed Skills" `Quick
            test_config_patch_accepts_typed_skills;
          test_case "config POST atomically restarts runtime" `Quick
            test_config_post_restarts_from_atomic_toml;
          test_case "config POST requires expected revision" `Quick
            test_config_post_requires_expected_revision;
          test_case "stale config POST loses with typed 409" `Quick
            test_config_post_rejects_second_writer_with_same_revision;
          test_case "direct assignment stale writer loses without a write" `Quick
            test_direct_assignment_route_rejects_stale_revision_without_write;
          test_case "direct assignment fences stale Keeper config POST" `Quick
            test_direct_assignment_intervening_write_fences_keeper_config_post;
          test_case "direct assignment response preserves lock warning" `Quick
            test_direct_assignment_route_surfaces_runtime_lock_release_warning;
          test_case "composite reconciliation preserves both authorities" `Quick
            test_composite_reconciliation_response_preserves_both_authorities;
          test_case "missing runtime assignment rolls config back" `Quick
            test_config_post_rolls_back_missing_runtime_assignment;
          test_case "mixed invalid request commits nothing" `Quick
            test_config_post_prevalidates_mixed_request;
          test_case "typed tools patch round-trips and previews admission" `Quick
            test_config_post_round_trips_typed_tools_patch;
          test_case "typed Skills patch preserves all, exact and none" `Quick
            test_config_post_round_trips_typed_skills_patch;
        ] );
    ]
