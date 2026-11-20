let launch_runtime_surface_load (state : Masc_tui_types.state) ~mailbox ~force =
  if Masc_tui_types.server_authority_ready state then begin
    match state.runtime_surface_inflight with
    | Some _ -> if force then state.runtime_surface_force_pending <- true
    | None ->
        state.runtime_surface_generation <- state.runtime_surface_generation + 1;
        let generation = state.runtime_surface_generation in
        state.runtime_surface_inflight <- Some generation;
        let host = Masc_tui_transport.Workspace_admission.server_peer_host in
        let port = state.port in
        Masc_tui_transport.Workspace_admission.launch_guarded_request state
          ~mailbox
          ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
          ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
          ~deliver:(fun result ->
            Masc_tui_async_protocol.Runtime_msg
              (Masc_tui_async_protocol.Runtime_surface_loaded
                 (generation, result)))
          (fun () ->
            Masc_tui_loader.load_runtime_surface ~host ~port ~force
            |> Result.map_error (fun detail ->
                   Masc_tui_types.Request_failed detail))
  end

let launch_repositories_load (state : Masc_tui_types.state) ~mailbox =
  if Masc_tui_types.server_authority_ready state then begin
    let enqueue_async =
      Masc_tui_transport.Workspace_admission.workspace_enqueue state
    in
    if state.repositories_inflight then ()
    else begin
      state.repositories_inflight <- true;
      state.repositories_owed <-
        Masc_tui_owed_read.started state.repositories_owed;
      let host = Masc_tui_transport.Workspace_admission.server_peer_host in
      let port = state.port in
      Masc_tui_transport.Workspace_admission.launch_async_read state ~mailbox
        ~on_not_run:(fun () ->
          state.repositories_inflight <- false;
          state.repositories_owed <-
            Masc_tui_owed_read.abandoned state.repositories_owed)
        ~deliver:(fun result ->
          enqueue_async mailbox
            (Masc_tui_async_protocol.Repository_msg
               (Masc_tui_async_protocol.Repositories_loaded result)))
        (fun () -> Masc_tui_loader.load_repositories ~host ~port)
    end
  end

let launch_memory_input_load (state : Masc_tui_types.state) ~mailbox ~refresh =
  if Masc_tui_types.server_authority_ready state then begin
    if
      state.view = Masc_tui_types.Memory
      && Option.is_none state.memory_facts_keeper
      && Masc_tui_transport.Workspace_admission.same_workspace_identity
           state.server_identity state.server_identity
    then
      match Masc_tui_types.selected_memory_keeper state with
      | None -> ()
      | Some keeper -> (
          let key = keeper.Masc.Tui_decode_memory_health.mkh_keeper_id in
          let current = Masc_tui_fetched.current_key state.memory_input in
          if refresh || current <> Some key then
            match
              Masc_tui_fetched.start ~equal:String.equal state.memory_input ~key
            with
            | Masc_tui_fetched.Already_loading -> ()
            | Masc_tui_fetched.Started (next, request) ->
                state.memory_input <- next;
                state.memory_input_owed <-
                  Masc_tui_owed_read.started state.memory_input_owed;
                let host =
                  Masc_tui_transport.Workspace_admission.server_peer_host
                and port = state.port in
                Masc_tui_transport.Workspace_admission.launch_guarded_request
                  state ~mailbox
                  ~boundary_error:(fun detail ->
                    Masc_tui_types.Request_failed detail)
                  ~withdrawn:(fun refusal ->
                    Masc_tui_types.Request_withdrawn refusal)
                  ~deliver:(fun result ->
                    Masc_tui_async_protocol.Memory_msg
                      (Masc_tui_async_protocol.Memory_input_loaded
                         (request, result)))
                  (fun () ->
                    Masc_tui_http.fetch_keeper_memory_input ~host ~port
                      ~keeper_name:key
                    |> Result.map_error (fun detail ->
                           Masc_tui_types.Request_failed detail)))
  end

(* The newest turns of the Keeper the Story window draws. The window follows
   the cursor, so asking for a Keeper other than the one held starts a read for
   it and the held turns are no longer drawn. The caller asks for none while a
   read for another Keeper is on the wire: see [launch_owed_keeper_story_turns]. *)
let launch_keeper_story_turns_load (state : Masc_tui_types.state) ~mailbox
    ~keeper_name ~refresh =
  if Masc_tui_types.server_authority_ready state then begin
    let current = Masc_tui_fetched.current_key state.keeper_story_turns in
    if refresh || current <> Some keeper_name then
      match
        Masc_tui_fetched.start ~equal:String.equal state.keeper_story_turns
          ~key:keeper_name
      with
      | Masc_tui_fetched.Already_loading -> ()
      | Masc_tui_fetched.Started (next, request) ->
          state.keeper_story_turns <- next;
          state.keeper_story_turns_owed <-
            Masc_tui_owed_read.started state.keeper_story_turns_owed;
          let host = Masc_tui_transport.Workspace_admission.server_peer_host
          and port = state.port in
          Masc_tui_transport.Workspace_admission.launch_guarded_request state
            ~mailbox
            ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
            ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
            ~deliver:(fun result ->
              Masc_tui_async_protocol.Keeper_msg
                (Masc_tui_async_protocol.Keeper_story_turns_loaded
                   (request, result)))
            (fun () ->
              Masc_tui_http.fetch_keeper_story_turns ~host ~port ~keeper_name
              |> Result.map_error (fun detail ->
                     Masc_tui_types.Request_failed detail))
  end

(* Independent Memory dock sources deliver without waiting for one another. *)
let launch_memory_activity_read state ~mailbox ~keeper_name ~refresh source owed
    ~set_source ~set_owed ~deliver read =
  if
    Masc_tui_types.server_authority_ready state
    && (refresh || Masc_tui_fetched.current_key source <> Some keeper_name)
  then
    match Masc_tui_fetched.start ~equal:String.equal source ~key:keeper_name with
    | Masc_tui_fetched.Already_loading -> ()
    | Masc_tui_fetched.Started (next, request) ->
        set_source next;
        set_owed (Masc_tui_owed_read.started owed);
        Masc_tui_transport.Workspace_admission.launch_json_read state ~mailbox
          ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
          ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
          ~deliver:(fun result ->
            Masc_tui_async_protocol.Keeper_msg (deliver request result))
          (fun () ->
            Result.map_error
              (fun detail -> Masc_tui_types.Request_failed detail)
              (read ()))

let launch_memory_health_load (state : Masc_tui_types.state) ~mailbox =
  if Masc_tui_types.server_authority_ready state then begin
    if
      state.memory_health_inflight
      || not
           (Masc_tui_transport.Workspace_admission.same_workspace_identity
              state.server_identity state.server_identity)
    then ()
    else begin
      state.memory_health_inflight <- true;
      state.memory_health_owed <-
        Masc_tui_owed_read.started state.memory_health_owed;
      (* The rows owed stay owed through this read: the server may answer the
         fleet from a cache older than their writes, and an answer older than
         the one held is not applied. Reading them after it costs one row each. *)
      let host = Masc_tui_transport.Workspace_admission.server_peer_host in
      let port = state.port in
      Masc_tui_transport.Workspace_admission.launch_guarded_request state
        ~mailbox
        ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
        ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
        ~deliver:(fun result ->
          Masc_tui_async_protocol.Memory_msg
            (Masc_tui_async_protocol.Memory_loaded
               (Masc_tui_async_protocol.Fleet_health_read result)))
        (fun () ->
          Masc_tui_loader.load_memory_health ~host ~port
          |> Result.map_error (fun detail ->
                 Masc_tui_types.Request_failed detail))
    end
  end

(* The oldest Keeper a push named, read as its own row. It shares
   the in-flight mark with the fleet read: one memory health read at a time.
   The Keeper leaves the list only when its read starts, so a read that
   cannot start yet keeps it owed. *)
let launch_owed_memory_health_row (state : Masc_tui_types.state) ~mailbox =
  match state.memory_health_rows_owed with
  | [] -> ()
  | keeper :: rest ->
      if
        Masc_tui_types.server_authority_ready state
        && (not state.memory_health_inflight)
        && Masc_tui_transport.Workspace_admission.same_workspace_identity
             state.server_identity state.server_identity
      then begin
        state.memory_health_rows_owed <- rest;
        state.memory_health_inflight <- true;
        let host = Masc_tui_transport.Workspace_admission.server_peer_host in
        let port = state.port in
        Masc_tui_transport.Workspace_admission.launch_guarded_request state
          ~mailbox
          ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
          ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
          ~deliver:(fun result ->
            Masc_tui_async_protocol.Memory_msg
              (Masc_tui_async_protocol.Memory_loaded
                 (Masc_tui_async_protocol.Row_health_read { keeper; result })))
          (fun () ->
            Masc_tui_loader.load_memory_health_row ~host ~port ~keeper
            |> Result.map_error (fun detail ->
                   Masc_tui_types.Request_failed detail))
      end

(* Ask for [key]'s facts and run [read] for them, unless that read is already
   in flight. *)
let launch_memory_facts_read (state : Masc_tui_types.state) ~mailbox ~key read =
  if Masc_tui_types.server_authority_ready state then begin
    match Masc_tui_fetched.start ~equal:String.equal state.memory_facts ~key with
    | Masc_tui_fetched.Already_loading -> ()
    | Masc_tui_fetched.Started (memory_facts, request) ->
        state.memory_facts <- memory_facts;
        (* The read's answer belongs to the workspace authority that asked for
           it. A same-port identity change withdraws this browser's owner and
           with it this request; an unscoped delivery would let workspace A's
           held facts land in workspace B's browser because the request key
           names a Keeper, not a workspace (#41163). *)
        state.memory_facts_owed <-
          Masc_tui_owed_read.started state.memory_facts_owed;
        Masc_tui_transport.Workspace_admission.launch_json_read state ~mailbox
          ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
          ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
          ~deliver:(fun result ->
            Masc_tui_async_protocol.Memory_msg
              (Masc_tui_async_protocol.Memory_facts_loaded (request, result)))
          (fun () ->
            Result.map_error
              (fun detail -> Masc_tui_types.Request_failed detail)
              (read ()))
  end

let launch_memory_facts_load (state : Masc_tui_types.state) ~mailbox ~keeper_name
    =
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.port in
  launch_memory_facts_read state ~mailbox ~key:keeper_name (fun () ->
      Result.map
        (fun snapshot -> snapshot, None)
        (Masc_tui_loader.load_memory_facts ~host ~port ~keeper_name))

let launch_all_memory_facts_load (state : Masc_tui_types.state) ~mailbox =
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.port in
  launch_memory_facts_read state ~mailbox ~key:"*" (fun () ->
      match state.memory_health with
      | None ->
          (* Without the health read there is no keeper list to merge. An empty
             "all keepers" view would read as memory that is empty. *)
          Error "keeper list not read yet (memory health has not loaded)"
      | Some (health : Masc.Tui_decode_memory_health.memory_health_snapshot) ->
          let loads =
            List.map
              (fun (k : Masc.Tui_decode_memory_health.memory_keeper_health) ->
                let keeper_name = k.mkh_keeper_id in
                ( keeper_name
                , try Masc_tui_loader.load_memory_facts ~host ~port ~keeper_name
                  with
                  | Eio.Cancel.Cancelled _ as exn -> raise exn
                  | exn -> Error (Printexc.to_string exn) ))
              health.mhs_keepers
          in
          (* One answer: the merged facts and the keepers missing from them
             travel together, so the handler never has to keep one answer across
             another. *)
          Ok
            (Masc.Tui_decode_memory_facts.merge_keeper_memory_facts
               ~refused:health.mhs_refused_keepers loads))

let open_all_fleet_memory (state : Masc_tui_types.state) ~mailbox =
  state.memory_page <- Masc_tui_types.Memory_facts;
  state.memory_facts_keeper <- Some "*";
  state.memory_facts <- Masc_tui_fetched.clear state.memory_facts;
  state.memory_facts_cursor <- 0;
  state.memory_facts_scroll <- 0;
  state.memory_facts_category <- Masc_tui_types.Category_all;
  launch_all_memory_facts_load state ~mailbox
