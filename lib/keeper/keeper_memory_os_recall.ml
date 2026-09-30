(** Render the exact LLM-selected current Memory OS snapshot and its availability. *)


type unavailable_reason =
  | Read_error

let unavailable_reason_to_label = function
  | Read_error -> "read_error"
;;

let record_unavailable reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string MemoryOsRecallUnavailable)
    ~labels:[ "reason", unavailable_reason_to_label reason ]
    ()
;;

type 'a current_state =
  | Absent
  | Available of 'a
  | Unavailable

let read_ordinary ~keepers_dir ~keeper_id =
  match Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id with
  | Ok None -> Absent
  | Ok (Some snapshot) -> Available snapshot
  | Error message ->
    Log.Keeper.warn "memory os recall unavailable keeper=%s: %s" keeper_id message;
    record_unavailable Read_error;
    Unavailable
;;

let ordinary_text = function
  | Absent ->
    "Ordinary memory snapshot is absent. No ordinary facts are current; earlier ordinary Recall facts are historical."
  | Unavailable ->
    "Ordinary memory is unavailable. Earlier ordinary Recall facts are unverified; this does not establish that they were deleted."
  | Available (snapshot : Keeper_memory_os_current.t) ->
    let state = match snapshot.facts with
      | [] -> "No ordinary facts are current; earlier ordinary Recall facts are historical."
      | facts -> "This snapshot replaces earlier ordinary Recall facts.\n"
          ^ Keeper_memory_os_render.render_facts facts in
    "Current ordinary memory.\n" ^ state
;;

let block sections = "--- Memory OS Recall ---\n" ^ String.concat "\n\n" sections

let render_context ~keepers_dir ~keeper_id () =
  block [ordinary_text (read_ordinary ~keepers_dir ~keeper_id)]
;;

let source_text = function
  | Absent ->
    "Source-bound memory snapshot is absent. No source-bound facts are current; earlier source-bound Recall facts are historical."
  | Unavailable ->
    "Source-bound memory is unavailable. Earlier source-bound Recall facts are unverified; this does not establish that they were deleted."
  | Available (projection : Keeper_memory_source_current.projection) ->
    let rows =
      List.map
        (fun (fact : Keeper_memory_source_current.fact) ->
           Keeper_memory_source_current.render_fact
             ~verified:(not (List.mem fact.source.path projection.unverified_paths)) fact)
        projection.facts
      @ List.map Keeper_memory_source_current.render_invalidation projection.invalidations in
    let state = match projection.facts with
      | [] -> "No source-bound facts are current; earlier source-bound Recall facts are historical."
      | _ :: _ -> "This projection replaces earlier source-bound Recall facts; verification is stated per fact." in
    "Current source-bound memory after revalidation.\n" ^ state ^ "\n"
    ^ String.concat "\n" rows
;;

let render_with_source_revalidation ~config ~meta ~keepers_dir ~keeper_id ~now =
  let source_state =
    match Keeper_memory_source_current.revalidate ~config ~meta ~keepers_dir ~now () with
    | Error message ->
      Log.Keeper.warn "source-bound memory recall unavailable keeper=%s: %s" keeper_id message;
      record_unavailable Read_error;
      Unavailable
    | Ok { snapshot = None; _ } -> Absent
    | Ok projection -> Available projection in
  (* [now] drives source revalidation only. Stable stored state and readability
     produce stable text; a recovery changes the state back even when the facts
     are byte-identical to those delivered before an unavailable turn. *)
  block [ordinary_text (read_ordinary ~keepers_dir ~keeper_id); source_text source_state]
;;

let enabled () = Env_config.KeeperMemoryOs.recall_enabled ()

let render_if_enabled ~config ~meta ~keepers_dir ~keeper_id ~now () =
  if not (enabled ())
  then Some (block ["Recall is disabled. Earlier Recall facts are historical and have not been refreshed; disabling does not establish deletion."])
  else
    Some
      (try render_with_source_revalidation ~config ~meta ~keepers_dir ~keeper_id ~now with
       | Eio.Cancel.Cancelled _ as error -> raise error
       | exn ->
         Log.Keeper.warn "memory os recall unavailable keeper=%s: %s"
           keeper_id (Printexc.to_string exn);
         record_unavailable Read_error;
         block [ordinary_text Unavailable; source_text Unavailable])
;;
