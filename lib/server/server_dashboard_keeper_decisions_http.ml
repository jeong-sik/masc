type read_error =
  | Roster_unavailable of string
  | Metadata_unavailable of { keeper : string; detail : string }
  | Decision_log_unavailable of {
      keeper : string;
      cause : Keeper_memory_recall_exn_class.t;
    }

let read_current ~config ~limit =
  Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
    match Keeper_meta_store.keeper_names_result config with
    | Error detail -> Error (Roster_unavailable detail)
    | Ok names ->
        let rec collect reversed = function
          | [] -> Ok (List.rev reversed)
          | name :: rest ->
              (match Keeper_meta_store.read_meta_presence config name with
               | Ok (Meta_present meta) -> collect (meta :: reversed) rest
               | Ok Meta_absent -> collect reversed rest
               | Ok (Meta_not_current detail) | Error detail ->
                   Error (Metadata_unavailable {keeper = name; detail})) in
        match collect [] names with
        | Error error -> Error error
        | Ok keepers ->
            let observation = Dashboard_http_keeper_feeds.keeper_decisions_observation
                ~config ~keepers ~limit () in
            match observation.read_errors with
            | [] -> Ok observation.json
            | error :: _ -> Error (Decision_log_unavailable {keeper = error.keeper; cause = error.cause}))

let read_error_to_string = function
  | Roster_unavailable detail -> "Keeper Decisions roster: " ^ detail
  | Metadata_unavailable {keeper; detail} ->
      Printf.sprintf "Keeper Decisions metadata %s: %s" keeper detail
  | Decision_log_unavailable {keeper; cause} ->
      Printf.sprintf "Keeper Decisions log %s: %s" keeper
        (Keeper_memory_recall_exn_class.to_label cause)

let read_error_to_json error =
  let metadata = match error with
    | Roster_unavailable _ -> ["reason", `String "keeper_roster_unavailable"]
    | Metadata_unavailable {keeper; detail = _} ->
        ["reason", `String "keeper_metadata_unavailable"; "keeper_name", `String keeper]
    | Decision_log_unavailable {keeper; cause} ->
        ["reason", `String "keeper_decision_log_unavailable"; "keeper_name", `String keeper;
          "read_error_class", `String (Keeper_memory_recall_exn_class.to_label cause)] in
  `Assoc (("error", `String "keeper_decisions_unavailable") :: metadata)
