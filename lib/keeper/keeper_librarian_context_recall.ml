module Context = Keeper_librarian_context

let ( let* ) = Result.bind

type index =
  { generation : string
  ; revision : int
  ; pocket_count : int
  ; source_count : int
  ; artifact : Tool_output.artifact_ref
  }

let filename_suffix = ".working-context-recall.json"

let path ~keepers_dir ~keeper_name =
  Filename.concat keepers_dir (keeper_name ^ filename_suffix)

let index_json index =
  `Assoc
    [ "generation", `String index.generation
    ; "revision", `Int index.revision
    ; "pocket_count", `Int index.pocket_count
    ; "source_count", `Int index.source_count
    ; "artifact", Tool_output.normalized_artifact_ref_to_json index.artifact
    ]

let index_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)
      = ["artifact"; "generation"; "pocket_count"; "revision"; "source_count"] ->
    (match List.assoc "generation" fields, List.assoc "revision" fields,
       List.assoc "pocket_count" fields,
       List.assoc "source_count" fields,
       Tool_output.normalized_artifact_ref_of_json (List.assoc "artifact" fields) with
     | `String generation, `Int revision, `Int pocket_count, `Int source_count,
       Tool_output.Decoded_normalized_artifact_ref artifact
       when String.trim generation <> "" && String.equal generation (String.trim generation)
            && revision > 0 && pocket_count >= 0 && source_count >= 0 ->
       Ok { generation; revision; pocket_count; source_count; artifact }
     | _, _, _, _,
       ( Tool_output.Not_normalized_artifact_ref
       | Tool_output.Invalid_normalized_artifact_ref _
       | Tool_output.Decoded_normalized_artifact_ref _ ) ->
       Error "invalid working context recall index fields")
  | _ -> Error "invalid working context recall index"

let read file =
  if not (Sys.file_exists file) then Ok None
  else try Result.map Option.some (index_of_json (Yojson.Safe.from_file file)) with
    | Sys_error detail | Yojson.Json_error detail -> Error detail

let with_current ~keepers_dir ~keeper_name (snapshot : Context.snapshot) publish =
  File_lock_eio.with_lock (Context.path ~keepers_dir ~keeper_id:keeper_name) (fun () ->
    match Context.read ~keepers_dir ~keeper_id:keeper_name with
    | Error detail -> Error detail
    | Ok None -> Error "working context no longer exists"
    | Ok (Some current) when Context.version current <> Context.version snapshot ->
      Error "working context version changed before publication"
    | Ok (Some _) -> publish ())

let require_readable_board_sources ~base_path ~keeper_name (snapshot : Context.snapshot) =
  let meta = ref None in
  let reader_meta () =
    match !meta with
    | Some result -> result
    | None ->
      let result = Keeper_meta_store.read_effective_meta
        (Workspace.default_config base_path) keeper_name in
      meta := Some result;
      result in
  let rec check = function
    | [] -> Ok ()
    | (source : Context.source) :: rest ->
      if not (String.starts_with ~prefix:"event:" source.reference) then check rest
      else match Keeper_event_queue.stimulus_of_yojson source.content with
        | Error _ -> Error "retained event source unavailable"
        | Ok stimulus ->
          (match stimulus.payload with
           | Keeper_event_queue.Board_routing_pending _ ->
             Error "retained Board routing is unresolved"
           | Keeper_event_queue.Board_signal _ | Board_attention _ ->
             (match reader_meta () with
              | Ok (Some meta) when Keeper_board_audience.can_project_queued_stimulus ~meta stimulus -> check rest
              | Ok None | Ok (Some _) | Error _ -> Error "retained Board source readership unavailable")
           | Keeper_event_queue.Bootstrap | Fusion_completed _ | Schedule_due _
           | Connector_attention _ | Hitl_resolved _ | Ask_answered _
           | Completion_authority_rejected _ | Task_outcome _ | Task_cancelled _
           | Workspace_message _ | Delegate_completed _ | Composition_completed _
           | Tool_result_ready _ | Owned_job_completed _ -> check rest)
  in
  check snapshot.sources

let publish ~base_path ~keepers_dir ~keeper_name (snapshot : Context.snapshot) =
  let* () = require_readable_board_sources ~base_path ~keeper_name snapshot in
  let file = path ~keepers_dir ~keeper_name in
  (* Unobserved sources cannot authorize next steps. The live Keeper receives
     admitted original inputs separately; this artifact supplies context only. *)
  let input = { Context.empty with previous = Some snapshot } in
  let* rendered = Context.render input in
  let* body = match rendered with
    | Some body -> Ok body
    | None ->
      Prompt_registry.render_prompt_template Prompt_names.keeper_context_librarian_empty_artifact []
      |> Result.map String.trim in
  try
    let artifact = Tool_blob_store.put_durable_reuse
        (Tool_blob_store.create ~base_path) ~bytes:body ~mime:"text/plain" in
    let index = { generation = snapshot.generation; revision = snapshot.revision;
      pocket_count = List.length snapshot.pockets;
      source_count = List.length snapshot.sources; artifact } in
    (* Validate against the committed generation as well as revision. A late
       publisher from before recovery/deletion must not replace a new index. *)
    with_current ~keepers_dir ~keeper_name snapshot (fun () ->
        File_lock_eio.with_lock file (fun () ->
          (* The authoritative committed snapshot repairs a corrupt projection. *)
          Result.bind
            (Keeper_recall_artifact.retain ~config:(Workspace.default_config base_path)
               ~keeper_id:keeper_name ~kind:Librarian ~now:(Time_compat.now ()) artifact)
            (fun () -> Fs_compat.save_file_atomic_strict file
              (Yojson.Safe.to_string (index_json index) ^ "\n"))))
  with Sys_error detail -> Error detail

let notice key =
  Prompt_registry.render_prompt_template key []
  |> Result.map (fun text -> Some (String.trim text))


let render_with ~before_retain ?(before_retire = fun () -> ())
    ?(artifact_reader_available = true) ~base_path ~keepers_dir ~keeper_name () =
  let unavailable detail =
    Log.Keeper.warn ~keeper_name
      "working context recall unavailable; original intake continues: %s" detail;
    notice Prompt_names.keeper_context_librarian_unavailable
  in
  (* Consult the authority first: an old or corrupt derived index cannot turn
     confirmed empty state into an unavailable state, nor authorize its pointer. *)
  if not artifact_reader_available then notice Prompt_names.keeper_context_librarian_unavailable
  else try
  let config = Workspace.default_config base_path in
  let observed_pin =
    Keeper_recall_artifact.observe_current ~config ~keeper_id:keeper_name ~kind:Librarian
  in
  let empty () =
    before_retire ();
    let retirement =
      try Result.bind observed_pin (fun observed ->
        Keeper_recall_artifact.retire_current ~config ~keeper_id:keeper_name
          ~kind:Librarian observed) with
      | Eio.Cancel.Cancelled _ as error -> raise error
      | Sys_error detail -> Error detail
      | Unix.Unix_error (code, fn, arg) ->
        Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))
    in
    (match retirement with
     | Ok () -> ()
     | Error detail -> Log.Keeper.warn ~keeper_name
         "working context recall pin retirement failed: %s" detail);
    notice Prompt_names.keeper_context_librarian_empty
  in
  match Context.read ~keepers_dir ~keeper_id:keeper_name with
  | Ok None -> empty ()
  | Error detail -> unavailable detail
  | Ok (Some current) ->
    match require_readable_board_sources ~base_path ~keeper_name current with
    | Error detail -> unavailable detail
    | Ok () ->
    match current.pockets with
    | [] -> empty ()
    | _ :: _ ->
      let repair () =
        (* The index is a projection, not authority. Repair it without a new
           model pass, even when pending inputs have not changed. Publication
           rechecks generation/revision under the owner lock. *)
        Result.bind (publish ~base_path ~keepers_dir ~keeper_name current) (fun () ->
          match read (path ~keepers_dir ~keeper_name) with
          | Ok (Some repaired) when Context.version current = (repaired.generation, repaired.revision) -> Ok repaired
          | Ok _ -> Error "working context changed during artifact repair"
          | Error detail -> Error detail)
      in
      let current_index = match read (path ~keepers_dir ~keeper_name) with
        | Ok (Some index) when Context.version current = (index.generation, index.revision) -> Ok index
        | Ok None | Ok (Some _) | Error _ -> repair ()
      in
      match current_index with
      | Error detail -> unavailable detail
      | Ok index ->
        before_retain ();
        let store = Tool_blob_store.create ~base_path in
        let readable = match Tool_blob_store.fetch store ~sha256:index.artifact.sha256 with
          | Ok (Some _) ->
            (* Refresh history ownership only while this exact index is current. *)
            Result.map (fun () -> index)
              (with_current ~keepers_dir ~keeper_name current (fun () ->
                let file = path ~keepers_dir ~keeper_name in
                File_lock_eio.with_lock file (fun () ->
                  match read file with
                  | Ok (Some observed) when observed = index ->
                    Keeper_recall_artifact.retain ~config:(Workspace.default_config base_path)
                      ~keeper_id:keeper_name ~kind:Librarian ~now:(Time_compat.now ()) index.artifact
                  | Ok _ -> Error "working context index changed before retention"
                  | Error detail -> Error detail)))
          | Ok None | Error _ ->
            repair () in
        (match readable with
         | Error detail -> unavailable detail
         | Ok index ->
           let* guidance = Prompt_registry.render_prompt_template
               Prompt_names.keeper_context_librarian_recall
               ["revision", string_of_int index.revision;
                "pocket_count", string_of_int index.pocket_count;
                "source_count", string_of_int index.source_count;
                "sha256", index.artifact.sha256] in
           let* preview = Prompt_registry.render_prompt_template
               Prompt_names.keeper_context_librarian_preview [] in
           Ok (Some (String.trim guidance ^ "\n" ^
             Tool_output.encode_for_agent_core
               (Tool_output.Stored (Tool_output.with_preview index.artifact (String.trim preview))))))

  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | Sys_error detail -> unavailable detail
  | Unix.Unix_error (code, fn, arg) ->
    unavailable (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))

let render = render_with ~before_retain:(fun () -> ()) ~before_retire:(fun () -> ())

module For_testing = struct
  let render = render_with
end
