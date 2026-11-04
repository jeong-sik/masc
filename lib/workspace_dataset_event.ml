let event_type = "workspace_dataset_changed"

type dataset =
  | Repositories
  | Verification_requests
  | Harness_verdicts
  | Keeper_oauth_attempts of { keeper : string }

let dataset_to_wire = function
  | Repositories -> "repositories"
  | Verification_requests -> "verification_requests"
  | Harness_verdicts -> "harness_verdicts"
  | Keeper_oauth_attempts _ -> "keeper_oauth_attempts"
;;

(* The wire decoder reads the whole field list: a dataset that names a Keeper
   carries it beside the dataset name, so [dataset_of_wire]'s single string
   cannot express it. *)
let of_fields fields =
  match List.assoc_opt "dataset" fields with
  | Some (`String name) when String.equal name "repositories" -> Ok Repositories
  | Some (`String name) when String.equal name "verification_requests" ->
    Ok Verification_requests
  | Some (`String name) when String.equal name "harness_verdicts" -> Ok Harness_verdicts
  | Some (`String name) when String.equal name "keeper_oauth_attempts" ->
    (match List.assoc_opt "keeper" fields with
     | Some (`String keeper) when not (String.equal keeper "") ->
         Ok (Keeper_oauth_attempts { keeper })
     | Some _ | None -> Error (event_type ^ " " ^ name ^ " names no keeper"))
  | Some (`String name) -> Error (event_type ^ " names an unknown dataset " ^ name)
  | Some _ | None -> Error (event_type ^ " carries no dataset name")
;;

let keeper_field = function
  | Repositories | Verification_requests | Harness_verdicts -> []
  | Keeper_oauth_attempts { keeper } -> [ "keeper", `String keeper ]
;;

let announce ~base_path dataset =
  let wire = dataset_to_wire dataset in
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        ([ "type", `String event_type; "dataset", `String wire ]
         @ keeper_field dataset
         @ [ "ts_unix", `Float (Time_compat.now ()) ]))
  with
  | () -> ()
  | exception exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "site", event_type ^ ":" ^ wire ]
      ();
    Log.Keeper.warn "workspace_dataset_event: %s %s failed: %s" event_type wire
      (Printexc.to_string exn)
;;

let install_store_observers () =
  Repo_store.install_written_observer (fun ~base_path -> announce ~base_path Repositories)
;;
