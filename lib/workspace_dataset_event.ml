let event_type = "workspace_dataset_changed"

type dataset =
  | Repositories
  | Verification_requests

let dataset_to_wire = function
  | Repositories -> "repositories"
  | Verification_requests -> "verification_requests"
;;

let dataset_of_wire = function
  | "repositories" -> Some Repositories
  | "verification_requests" -> Some Verification_requests
  | _ -> None
;;

let announce ~base_path dataset =
  let wire = dataset_to_wire dataset in
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        [ "type", `String event_type
        ; "dataset", `String wire
        ; "ts_unix", `Float (Time_compat.now ())
        ])
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
