type evidence_status =
  | Recorded
  | Pending
  | Absent

type evidence =
  { status : evidence_status
  ; post : Board.post option
  }

type detail =
  { run : Fusion_run_registry.run
  ; evidence : evidence
  }

type lookup =
  | Found of detail
  | Run_not_found

let detail_prefix = "/api/v1/dashboard/fusion-runs/"

let evidence_status_to_string = function
  | Recorded -> "recorded"
  | Pending -> "pending"
  | Absent -> "absent"
;;

let has_exact_fusion_origin ~run_id (post : Board.post) =
  match post.origin with
  | Some { source = Some source; fusion_run_id = Some origin_run_id; _ } ->
    String.equal source "fusion" && String.equal origin_run_id run_id
  | Some _ | None -> false
;;

let find ~registry ~run_id =
  match Fusion_run_registry.get registry ~run_id with
  | None -> Run_not_found
  | Some run ->
    let post =
      match Board_dispatch.find_post_by_run_id ~run_id with
      | Some post when has_exact_fusion_origin ~run_id post -> Some post
      | Some _ | None -> None
    in
    let status =
      match post, run.status with
      | Some _, _ -> Recorded
      | None, Fusion_run_registry.Running -> Pending
      | None, Fusion_run_registry.Completed _ -> Absent
    in
    Found { run; evidence = { status; post } }
;;

let evidence_to_yojson evidence =
  `Assoc
    [ "status", `String (evidence_status_to_string evidence.status)
    ; ( "post"
      , match evidence.post with
        | Some post -> Board.post_to_yojson post
        | None -> `Null )
    ]
;;

let to_yojson ~generated_at detail =
  `Assoc
    [ "generated_at", `String generated_at
    ; "run", Fusion_run_registry.run_to_yojson detail.run
    ; "evidence", evidence_to_yojson detail.evidence
    ]
;;

let historical_reference (post : Board.post) run_id =
  `Assoc
    [ "run_id", `String run_id
    ; "post_id", `String (Board.Post_id.to_string post.id)
    ; "title", `String post.title
    ; "created_at", `Float post.created_at
    ]
;;

module Run_ids = Set.Make (String)

let historical_evidence ~runs =
  let retained = Run_ids.of_list
      (List.map (fun (run : Fusion_run_registry.run) -> run.run_id) runs) in
  Board_dispatch.list_posts_by_run_origin ()
  |> List.filter_map (fun (post : Board.post) ->
       match post.origin with
       | Some { source = Some "fusion"; fusion_run_id = Some run_id; _ }
         when not (Run_ids.mem run_id retained) ->
         Some (historical_reference post run_id)
       | Some _ | None -> None)
;;

let replay_to_yojson = function
  | Run_registry_core.Not_replayed -> `Assoc ["status", `String "not_replayed"]
  | Run_registry_core.Log_absent -> `Assoc ["status", `String "absent"]
  | Run_registry_core.Replayed report ->
      `Assoc
        [ "status", `String (if report.reached_end then "complete" else "incomplete")
        ; "lines_read", `Int report.lines_read
        ; "malformed_lines", `Int report.malformed_lines
        ; "dropped_running", `Int report.dropped_running
        ]
;;

let list_response ~generated_at ~registry =
  let runs = Fusion_run_registry.list_runs registry in
  `Assoc
    [ "generated_at", `String generated_at
    ; "replay", replay_to_yojson (Fusion_run_registry.replay_status registry)
    ; "historical_evidence", `List (historical_evidence ~runs)
    ; "count", `Int (List.length runs)
    ; "runs", `List (List.map Fusion_run_registry.run_to_yojson runs)
    ]
;;

let detail_response ~generated_at ~registry ~path =
  match Server_utils.extract_path_param ~prefix:detail_prefix path with
  | None -> `Bad_request, `Assoc [ "error", `String "run_id is required" ]
  | Some encoded_run_id ->
    let run_id = Uri.pct_decode encoded_run_id in
    if String.equal (String.trim run_id) ""
    then `Bad_request, `Assoc [ "error", `String "run_id is required" ]
    else
      match find ~registry ~run_id with
      | Run_not_found ->
        ( `Not_found
        , `Assoc
            [ "error", `String ("no retained fusion run named " ^ run_id)
            ; "historical_evidence",
                (match Board_dispatch.find_post_by_run_id ~run_id with
                 | Some post when has_exact_fusion_origin ~run_id post ->
                     historical_reference post run_id
                 | Some _ | None -> `Null)
            ] )
      | Found detail -> `OK, to_yojson ~generated_at detail
;;
