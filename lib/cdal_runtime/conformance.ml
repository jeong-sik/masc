type check =
  { code : string
  ; name : string
  ; passed : bool
  ; detail : string option
  }
[@@deriving yojson]

type summary =
  { session_id : string
  ; generated_at : float
  ; worker_run_count : int
  ; raw_trace_run_count : int
  ; validated_worker_run_count : int
  ; latest_accepted_worker_run_id : string option
  ; latest_ready_worker_run_id : string option
  ; latest_running_worker_run_id : string option
  ; latest_worker_run_id : string option
  ; latest_completed_worker_run_id : string option
  ; latest_worker_agent_name : string option
  ; latest_worker_status : string option
  ; latest_worker_role : string option
  ; latest_worker_aliases : string list
  ; latest_worker_validated : bool option
  ; latest_failed_worker_run_id : string option
  ; latest_failure_reason : string option
  ; latest_resolved_provider : string option
  ; latest_resolved_model : string option
  ; hook_event_count : int
  ; tool_catalog_count : int
  ; trace_capabilities : Sessions.trace_capability list
  }
[@@deriving yojson]

type report =
  { ok : bool
  ; summary : summary
  ; checks : check list
  }
[@@deriving yojson]

open Result_syntax

let unique_trace_capabilities worker_runs =
  worker_runs
  |> List.fold_left
       (fun acc (worker : Sessions.worker_run) ->
          if List.exists (( = ) worker.trace_capability) acc
          then acc
          else acc @ [ worker.trace_capability ])
       []
;;

let latest_by predicate worker_runs =
  worker_runs
  |> List.filter predicate
  |> List.rev
  |> function
  | worker :: _ -> Some worker
  | [] -> None
;;

let lifecycle_monotonic (worker : Sessions.worker_run) =
  let ordered a b =
    match a, b with
    | Some x, Some y -> x <= y
    | _ -> true
  in
  ordered worker.started_at worker.last_progress_at
  && ordered worker.started_at worker.finished_at
;;

let worker_ids worker_runs =
  worker_runs |> List.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
;;

let raw_run_ids raw_runs =
  raw_runs |> List.map (fun (run : Sessions.raw_trace_run) -> run.worker_run_id)
;;

let is_runtime_resolved (worker : Sessions.worker_run) =
  worker.resolved_provider <> None && worker.resolved_model <> None
;;

let identity_is_consistent (worker : Sessions.worker_run) =
  let alias_ok =
    match worker.primary_alias with
    | None -> true
    | Some alias -> List.exists (String.equal alias) worker.aliases
  in
  worker.worker_id <> None && worker.runtime_actor <> None && alias_ok
;;

let worker_status_name = function
  | Sessions.Planned -> "planned"
  | Sessions.Accepted -> "accepted"
  | Sessions.Ready -> "ready"
  | Sessions.Running -> "running"
  | Sessions.Completed -> "completed"
  | Sessions.Failed -> "failed"
;;

let check bundle =
  let expected_latest_worker =
    match List.rev bundle.Sessions.worker_runs with
    | worker :: _ -> Some worker
    | [] -> None
  in
  let expected_latest_validated =
    latest_by (fun (worker : Sessions.worker_run) -> worker.validated) bundle.worker_runs
  in
  let expected_latest_accepted =
    latest_by
      (fun (worker : Sessions.worker_run) -> worker.status = Sessions.Accepted)
      bundle.worker_runs
  in
  let expected_latest_ready =
    latest_by
      (fun (worker : Sessions.worker_run) -> worker.status = Sessions.Ready)
      bundle.worker_runs
  in
  let expected_latest_running =
    latest_by
      (fun (worker : Sessions.worker_run) -> worker.status = Sessions.Running)
      bundle.worker_runs
  in
  let expected_latest_completed =
    latest_by
      (fun (worker : Sessions.worker_run) -> worker.status = Sessions.Completed)
      bundle.worker_runs
  in
  let expected_latest_failed =
    latest_by
      (fun (worker : Sessions.worker_run) -> worker.status = Sessions.Failed)
      bundle.worker_runs
  in
  let validated_worker_runs =
    bundle.worker_runs
    |> List.filter (fun (worker : Sessions.worker_run) -> worker.validated)
  in
  let expected_trace_capabilities = unique_trace_capabilities bundle.worker_runs in
  let raw_ids = raw_run_ids bundle.raw_trace_runs in
  let worker_ids = worker_ids bundle.worker_runs in
  [ { code = "proof_bundle_available"
    ; name = "proof_bundle_capability"
    ; passed = bundle.capabilities.proof_bundle
    ; detail = Some (Printf.sprintf "proof_bundle=%b" bundle.capabilities.proof_bundle)
    }
  ; { code = "direct_evidence_incomplete"
    ; name = "direct_evidence_complete_when_raw_capable"
    ; passed =
        bundle.worker_runs
        |> List.for_all (fun (worker : Sessions.worker_run) ->
          match worker.trace_capability with
          | Sessions.Raw ->
            List.exists
              (fun (run : Sessions.raw_trace_run) ->
                 String.equal run.worker_run_id worker.worker_run_id)
              bundle.raw_trace_runs
          | Sessions.Summary_only | Sessions.No_trace -> true)
    ; detail =
        Some
          (Printf.sprintf
             "worker_runs=%d raw_runs=%d"
             (List.length bundle.worker_runs)
             (List.length bundle.raw_trace_runs))
    }
  ; { code =
        (if bundle.raw_trace_runs = []
         then "missing_raw_trace"
         else "raw_trace_shape_mismatch")
    ; name = "raw_trace_shapes_consistent"
    ; passed =
        bundle.raw_trace_run_count = List.length bundle.raw_trace_runs
        && bundle.raw_trace_run_count = List.length bundle.raw_trace_summaries
        && bundle.raw_trace_run_count = List.length bundle.raw_trace_validations
    ; detail =
        Some
          (Printf.sprintf
             "runs=%d summaries=%d validations=%d counted=%d"
             (List.length bundle.raw_trace_runs)
             (List.length bundle.raw_trace_summaries)
             (List.length bundle.raw_trace_validations)
             bundle.raw_trace_run_count)
    }
  ; { code = "validated_count_mismatch"
    ; name = "validated_worker_counts_consistent"
    ; passed =
        bundle.validated_worker_run_count = List.length bundle.validated_worker_runs
        && bundle.validated_worker_run_count = List.length validated_worker_runs
    ; detail =
        Some
          (Printf.sprintf
             "validated_count=%d bundle_list=%d worker_scan=%d"
             bundle.validated_worker_run_count
             (List.length bundle.validated_worker_runs)
             (List.length validated_worker_runs))
    }
  ; { code = "latest_accepted_inconsistent"
    ; name = "latest_accepted_worker_consistent"
    ; passed =
        Option.map
          (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
          bundle.latest_accepted_worker_run
        = Option.map
            (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
            expected_latest_accepted
    ; detail =
        Some
          (Printf.sprintf
             "bundle=%s expected=%s"
             (bundle.latest_accepted_worker_run
              |> Option.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
              |> Option.value ~default:"")
             (expected_latest_accepted
              |> Option.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
              |> Option.value ~default:""))
    }
  ; { code = "latest_ready_inconsistent"
    ; name = "latest_ready_worker_consistent"
    ; passed =
        Option.map
          (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
          bundle.latest_ready_worker_run
        = Option.map
            (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
            expected_latest_ready
    ; detail =
        Some
          (Printf.sprintf
             "bundle=%s expected=%s"
             (bundle.latest_ready_worker_run
              |> Option.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
              |> Option.value ~default:"")
             (expected_latest_ready
              |> Option.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
              |> Option.value ~default:""))
    }
  ; { code = "latest_running_inconsistent"
    ; name = "latest_running_worker_consistent"
    ; passed =
        Option.map
          (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
          bundle.latest_running_worker_run
        = Option.map
            (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
            expected_latest_running
    ; detail =
        Some
          (Printf.sprintf
             "bundle=%s expected=%s"
             (bundle.latest_running_worker_run
              |> Option.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
              |> Option.value ~default:"")
             (expected_latest_running
              |> Option.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
              |> Option.value ~default:""))
    }
  ; { code = "latest_worker_inconsistent"
    ; name = "latest_worker_consistent"
    ; passed =
        Option.map
          (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
          bundle.latest_worker_run
        = Option.map
            (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
            expected_latest_worker
    ; detail =
        Some
          (Printf.sprintf
             "bundle=%s expected=%s"
             (bundle.latest_worker_run
              |> Option.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
              |> Option.value ~default:"")
             (expected_latest_worker
              |> Option.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
              |> Option.value ~default:""))
    }
  ; { code = "latest_completed_inconsistent"
    ; name = "latest_completed_worker_consistent"
    ; passed =
        Option.map
          (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
          bundle.latest_completed_worker_run
        = Option.map
            (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
            expected_latest_completed
    ; detail =
        Some
          (Printf.sprintf
             "bundle=%s expected=%s"
             (bundle.latest_completed_worker_run
              |> Option.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
              |> Option.value ~default:"")
             (expected_latest_completed
              |> Option.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
              |> Option.value ~default:""))
    }
  ; { code = "latest_validated_inconsistent"
    ; name = "latest_validated_worker_consistent"
    ; passed =
        Option.map
          (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
          bundle.latest_validated_worker_run
        = Option.map
            (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
            expected_latest_validated
    ; detail =
        Some
          (Printf.sprintf
             "bundle=%s expected=%s"
             (bundle.latest_validated_worker_run
              |> Option.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
              |> Option.value ~default:"")
             (expected_latest_validated
              |> Option.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
              |> Option.value ~default:""))
    }
  ; { code = "latest_failed_inconsistent"
    ; name = "latest_failed_worker_consistent"
    ; passed =
        Option.map
          (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
          bundle.latest_failed_worker_run
        = Option.map
            (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
            expected_latest_failed
    ; detail =
        Some
          (Printf.sprintf
             "bundle=%s expected=%s"
             (bundle.latest_failed_worker_run
              |> Option.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
              |> Option.value ~default:"")
             (expected_latest_failed
              |> Option.map (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
              |> Option.value ~default:""))
    }
  ; { code = "trace_capabilities_inconsistent"
    ; name = "trace_capabilities_consistent"
    ; passed = bundle.trace_capabilities = expected_trace_capabilities
    ; detail =
        Some
          (Printf.sprintf
             "bundle=%d expected=%d"
             (List.length bundle.trace_capabilities)
             (List.length expected_trace_capabilities))
    }
  ; { code = "identity_alias_mismatch"
    ; name = "worker_identity_alias_consistent"
    ; passed = List.for_all identity_is_consistent bundle.worker_runs
    ; detail = Some (Printf.sprintf "workers=%d" (List.length bundle.worker_runs))
    }
  ; { code = "failed_worker_reason_missing"
    ; name = "failed_workers_have_reason"
    ; passed =
        bundle.worker_runs
        |> List.for_all (fun (worker : Sessions.worker_run) ->
          if worker.error = None && worker.failure_reason = None
          then true
          else worker.error <> None || worker.failure_reason <> None)
    ; detail =
        Some
          (Printf.sprintf
             "failed_workers=%d"
             (bundle.worker_runs
              |> List.filter (fun (worker : Sessions.worker_run) ->
                worker.error <> None || worker.failure_reason <> None)
              |> List.length))
    }
  ; { code = "lifecycle_non_monotonic"
    ; name = "lifecycle_state_monotonic"
    ; passed = List.for_all lifecycle_monotonic bundle.worker_runs
    ; detail = Some (Printf.sprintf "workers=%d" (List.length bundle.worker_runs))
    }
  ; { code = "resolved_runtime_missing"
    ; name = "resolved_runtime_presence_consistent"
    ; passed =
        bundle.worker_runs
        |> List.for_all (fun (worker : Sessions.worker_run) ->
          match worker.status with
          | Sessions.Planned -> true
          | Sessions.Accepted
          | Sessions.Ready
          | Sessions.Running
          | Sessions.Completed
          | Sessions.Failed -> is_runtime_resolved worker)
    ; detail = Some (Printf.sprintf "workers=%d" (List.length bundle.worker_runs))
    }
  ; { code = "validated_worker_not_raw_capable"
    ; name = "validated_workers_are_raw_capable"
    ; passed =
        validated_worker_runs
        |> List.for_all (fun (worker : Sessions.worker_run) ->
          worker.trace_capability = Sessions.Raw)
    ; detail =
        Some (Printf.sprintf "validated_workers=%d" (List.length validated_worker_runs))
    }
  ; { code = "raw_trace_not_addressable"
    ; name = "raw_trace_runs_are_addressable"
    ; passed =
        raw_ids
        |> List.for_all (fun raw_id -> List.exists (String.equal raw_id) worker_ids)
    ; detail =
        Some
          (Printf.sprintf
             "raw_runs=%d worker_runs=%d"
             (List.length raw_ids)
             (List.length worker_ids))
    }
  ]
;;

let report bundle =
  let checks = check bundle in
  let ok = List.for_all (fun (check : check) -> check.passed) checks in
  let latest_worker = bundle.latest_worker_run in
  let latest_failed = bundle.latest_failed_worker_run in
  { ok
  ; summary =
      { session_id = bundle.session.session_id
      ; generated_at = Unix.gettimeofday ()
      ; worker_run_count = List.length bundle.worker_runs
      ; raw_trace_run_count = bundle.raw_trace_run_count
      ; validated_worker_run_count = bundle.validated_worker_run_count
      ; latest_accepted_worker_run_id =
          Option.map
            (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
            bundle.latest_accepted_worker_run
      ; latest_ready_worker_run_id =
          Option.map
            (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
            bundle.latest_ready_worker_run
      ; latest_running_worker_run_id =
          Option.map
            (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
            bundle.latest_running_worker_run
      ; latest_worker_run_id =
          Option.map
            (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
            latest_worker
      ; latest_completed_worker_run_id =
          Option.map
            (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
            bundle.latest_completed_worker_run
      ; latest_worker_agent_name =
          Option.map
            (fun (worker : Sessions.worker_run) -> worker.agent_name)
            latest_worker
      ; latest_worker_status =
          Option.map
            (fun (worker : Sessions.worker_run) -> worker_status_name worker.status)
            latest_worker
      ; latest_worker_role =
          Option.bind latest_worker (fun (worker : Sessions.worker_run) -> worker.role)
      ; latest_worker_aliases =
          Option.bind latest_worker (fun (worker : Sessions.worker_run) ->
            Some worker.aliases)
          |> Option.value ~default:[]
      ; latest_worker_validated =
          Option.map
            (fun (worker : Sessions.worker_run) -> worker.validated)
            latest_worker
      ; latest_failed_worker_run_id =
          Option.map
            (fun (worker : Sessions.worker_run) -> worker.worker_run_id)
            latest_failed
      ; latest_failure_reason =
          Option.bind latest_failed (fun (worker : Sessions.worker_run) ->
            match worker.failure_reason with
            | Some _ as value -> value
            | None -> worker.error)
      ; latest_resolved_provider =
          Option.bind latest_worker (fun (worker : Sessions.worker_run) ->
            worker.resolved_provider)
      ; latest_resolved_model =
          Option.bind latest_worker (fun (worker : Sessions.worker_run) ->
            worker.resolved_model)
      ; hook_event_count =
          List.fold_left (fun acc item -> acc + item.Sessions.count) 0 bundle.hook_summary
      ; tool_catalog_count = List.length bundle.tool_catalog
      ; trace_capabilities = bundle.trace_capabilities
      }
  ; checks
  }
;;

let run ?session_root ~session_id () =
  let* bundle = Sessions.get_proof_bundle ?session_root ~session_id () in
  Ok (report bundle)
;;

[@@@coverage off]
(* === Inline tests === *)

let make_worker
      ?(worker_run_id = "w1")
      ?(worker_id = Some "wid")
      ?(agent_name = "agent")
      ?(runtime_actor = Some "actor")
      ?(role = None)
      ?(aliases = [])
      ?(primary_alias = None)
      ?(provider = None)
      ?(model = None)
      ?(requested_provider = None)
      ?(requested_model = None)
      ?(requested_policy = None)
      ?(resolved_provider = Some "llama")
      ?(resolved_model = Some "qwen")
      ?(status = Sessions.Completed)
      ?(trace_capability = Sessions.Raw)
      ?(validated = true)
      ?(tool_names = [])
      ?(final_text = None)
      ?(stop_reason = None)
      ?(error = None)
      ?(failure_reason = None)
      ?(accepted_at = None)
      ?(ready_at = None)
      ?(first_progress_at = None)
      ?(started_at = Some 1.0)
      ?(finished_at = Some 2.0)
      ?(last_progress_at = Some 1.5)
      ?(policy_snapshot = None)
      ?(paired_tool_result_count = 0)
      ?(has_file_write = false)
      ?(verification_pass_after_file_write = false)
      ()
  : Sessions.worker_run
  =
  { worker_run_id
  ; worker_id
  ; agent_name
  ; runtime_actor
  ; role
  ; aliases
  ; primary_alias
  ; provider
  ; model
  ; requested_provider
  ; requested_model
  ; requested_policy
  ; resolved_provider
  ; resolved_model
  ; status
  ; trace_capability
  ; validated
  ; tool_names
  ; final_text
  ; stop_reason
  ; error
  ; failure_reason
  ; accepted_at
  ; ready_at
  ; first_progress_at
  ; started_at
  ; finished_at
  ; last_progress_at
  ; policy_snapshot
  ; paired_tool_result_count
  ; has_file_write
  ; verification_pass_after_file_write
  }
;;

let%test "unique_trace_capabilities deduplicates" =
  let w1 = make_worker ~trace_capability:Sessions.Raw () in
  let w2 = make_worker ~trace_capability:Sessions.Raw () in
  let w3 = make_worker ~trace_capability:Sessions.Summary_only () in
  let result = unique_trace_capabilities [ w1; w2; w3 ] in
  List.length result = 2
;;

let%test "unique_trace_capabilities empty list" = unique_trace_capabilities [] = []

let%test "unique_trace_capabilities preserves order" =
  let w1 = make_worker ~trace_capability:Sessions.Summary_only () in
  let w2 = make_worker ~trace_capability:Sessions.Raw () in
  let result = unique_trace_capabilities [ w1; w2 ] in
  result = [ Sessions.Summary_only; Sessions.Raw ]
;;

let%test "latest_by returns last matching element" =
  let w1 = make_worker ~worker_run_id:"w1" ~status:Sessions.Completed () in
  let w2 = make_worker ~worker_run_id:"w2" ~status:Sessions.Running () in
  let w3 = make_worker ~worker_run_id:"w3" ~status:Sessions.Completed () in
  match
    latest_by
      (fun (w : Sessions.worker_run) -> w.status = Sessions.Completed)
      [ w1; w2; w3 ]
  with
  | Some w -> w.worker_run_id = "w3"
  | None -> false
;;

let%test "latest_by returns None when no match" =
  let w1 = make_worker ~status:Sessions.Running () in
  latest_by (fun (w : Sessions.worker_run) -> w.status = Sessions.Failed) [ w1 ] = None
;;

let%test "latest_by empty list" = latest_by (fun _ -> true) [] = None

let%test "lifecycle_monotonic all timestamps ordered" =
  let w =
    make_worker
      ~started_at:(Some 1.0)
      ~last_progress_at:(Some 2.0)
      ~finished_at:(Some 3.0)
      ()
  in
  lifecycle_monotonic w = true
;;

let%test "lifecycle_monotonic None timestamps always pass" =
  let w = make_worker ~started_at:None ~last_progress_at:None ~finished_at:None () in
  lifecycle_monotonic w = true
;;

let%test "lifecycle_monotonic mixed None passes" =
  let w =
    make_worker ~started_at:(Some 1.0) ~last_progress_at:None ~finished_at:(Some 3.0) ()
  in
  lifecycle_monotonic w = true
;;

let%test "lifecycle_monotonic started > finished fails" =
  let w =
    make_worker ~started_at:(Some 5.0) ~last_progress_at:None ~finished_at:(Some 1.0) ()
  in
  lifecycle_monotonic w = false
;;

let%test "is_runtime_resolved both present" =
  let w = make_worker ~resolved_provider:(Some "p") ~resolved_model:(Some "m") () in
  is_runtime_resolved w = true
;;

let%test "is_runtime_resolved provider missing" =
  let w = make_worker ~resolved_provider:None ~resolved_model:(Some "m") () in
  is_runtime_resolved w = false
;;

let%test "is_runtime_resolved model missing" =
  let w = make_worker ~resolved_provider:(Some "p") ~resolved_model:None () in
  is_runtime_resolved w = false
;;

let%test "identity_is_consistent all present and matching" =
  let w =
    make_worker
      ~worker_id:(Some "wid")
      ~runtime_actor:(Some "actor")
      ~primary_alias:(Some "a1")
      ~aliases:[ "a1"; "a2" ]
      ()
  in
  identity_is_consistent w = true
;;

let%test "identity_is_consistent primary_alias not in aliases fails" =
  let w =
    make_worker
      ~worker_id:(Some "wid")
      ~runtime_actor:(Some "actor")
      ~primary_alias:(Some "missing")
      ~aliases:[ "a1"; "a2" ]
      ()
  in
  identity_is_consistent w = false
;;

let%test "identity_is_consistent no primary_alias is ok" =
  let w =
    make_worker
      ~worker_id:(Some "wid")
      ~runtime_actor:(Some "actor")
      ~primary_alias:None
      ~aliases:[]
      ()
  in
  identity_is_consistent w = true
;;

let%test "identity_is_consistent missing worker_id fails" =
  let w = make_worker ~worker_id:None ~runtime_actor:(Some "actor") () in
  identity_is_consistent w = false
;;

let%test "identity_is_consistent missing runtime_actor fails" =
  let w = make_worker ~worker_id:(Some "wid") ~runtime_actor:None () in
  identity_is_consistent w = false
;;

let%test "worker_status_name all variants" =
  worker_status_name Sessions.Planned = "planned"
  && worker_status_name Sessions.Accepted = "accepted"
  && worker_status_name Sessions.Ready = "ready"
  && worker_status_name Sessions.Running = "running"
  && worker_status_name Sessions.Completed = "completed"
  && worker_status_name Sessions.Failed = "failed"
;;

let%test "worker_ids extracts ids" =
  let w1 = make_worker ~worker_run_id:"id1" () in
  let w2 = make_worker ~worker_run_id:"id2" () in
  worker_ids [ w1; w2 ] = [ "id1"; "id2" ]
;;

let%test "raw_run_ids extracts ids" =
  let r1 : Sessions.raw_trace_run =
    { worker_run_id = "r1"
    ; path = "/tmp/a"
    ; start_seq = 0
    ; end_seq = 10
    ; agent_name = "a"
    ; session_id = None
    }
  in
  let r2 : Sessions.raw_trace_run =
    { worker_run_id = "r2"
    ; path = "/tmp/b"
    ; start_seq = 0
    ; end_seq = 5
    ; agent_name = "b"
    ; session_id = None
    }
  in
  raw_run_ids [ r1; r2 ] = [ "r1"; "r2" ]
;;
