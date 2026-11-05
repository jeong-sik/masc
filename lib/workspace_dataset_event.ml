let event_type = "workspace_dataset_changed"

(* The kinds a dataset comes in: a payload-free sum, so the wire name has one
   table and adding a dataset is a match arm the compiler checks. A kind that
   names a subject carries it beside the dataset name on the wire. *)
module Kind = struct
  type t =
    | Repositories
    | Verification_requests
    | Harness_verdicts
    | Keeper_oauth_attempts

  let to_wire = function
    | Repositories -> "repositories"
    | Verification_requests -> "verification_requests"
    | Harness_verdicts -> "harness_verdicts"
    | Keeper_oauth_attempts -> "keeper_oauth_attempts"
  ;;

  let of_wire = function
    | "repositories" -> Some Repositories
    | "verification_requests" -> Some Verification_requests
    | "harness_verdicts" -> Some Harness_verdicts
    | "keeper_oauth_attempts" -> Some Keeper_oauth_attempts
    | _ -> None
  ;;
end

type dataset =
  | Repositories
  | Verification_requests
  | Harness_verdicts
  | Keeper_oauth_attempts of { keeper : string }

let kind = function
  | Repositories -> Kind.Repositories
  | Verification_requests -> Kind.Verification_requests
  | Harness_verdicts -> Kind.Harness_verdicts
  | Keeper_oauth_attempts _ -> Kind.Keeper_oauth_attempts
;;

let dataset_to_wire dataset = Kind.to_wire (kind dataset);;

(* The subject a dataset names beside its own name. A dataset that belongs to
   one Keeper carries its name; the others carry nothing. A later dataset can
   name an instance instead, and joins here. *)
let subject_fields = function
  | Repositories | Verification_requests | Harness_verdicts -> []
  | Keeper_oauth_attempts { keeper } -> [ ("keeper", `String keeper) ]
;;

(* The Keeper a subject-naming event carries. An empty or missing name is an
   error naming the event: the reader cannot tell whose data moved. *)
let keeper_field ~wire fields =
  match List.assoc_opt "keeper" fields with
  | Some (`String keeper) when not (String.equal keeper "") -> Ok keeper
  | Some _ | None -> Error (event_type ^ " " ^ wire ^ " names no keeper")
;;

let of_fields fields =
  match List.assoc_opt "dataset" fields with
  | Some (`String wire) ->
    (match Kind.of_wire wire with
     | Some Kind.Repositories -> Ok Repositories
     | Some Kind.Verification_requests -> Ok Verification_requests
     | Some Kind.Harness_verdicts -> Ok Harness_verdicts
     | Some Kind.Keeper_oauth_attempts ->
       (match keeper_field ~wire fields with
        | Ok keeper -> Ok (Keeper_oauth_attempts { keeper })
        | Error detail -> Error detail)
     | None -> Error (event_type ^ " names an unknown dataset " ^ wire))
  | Some _ | None -> Error (event_type ^ " carries no dataset name")
;;

let announce ~base_path dataset =
  let wire = dataset_to_wire dataset in
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        ([ "type", `String event_type; "dataset", `String wire ]
         @ subject_fields dataset
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
