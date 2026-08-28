type filesystem_operation =
  | Open_directory
  | Read_directory
  | Close_directory
  | Stat_entry

type filesystem_error =
  { operation : filesystem_operation
  ; path : string
  ; cause : Unix.error
  }

type gap =
  | Trace_root_unavailable of filesystem_error
  | Trace_root_not_directory of Unix.file_kind
  | Trace_entry_unreadable of filesystem_error
  | Invalid_trace_directory of string
  | Symlink_trace_entry of string
  | Trace_entry_not_directory of
      { trace_id : Keeper_id.Trace_id.t
      ; kind : Unix.file_kind
      }
  | Trace_inventory_changed_during_discovery
  | Trace_root_changed_during_discovery
  | Ledger_changed_during_discovery of Keeper_id.Trace_id.t
  | Ledger_unreadable of
      { trace_id : Keeper_id.Trace_id.t
      ; cause : Keeper_skill_activation_ledger.store_error
      }

type scope =
  | Complete_retained_trace_snapshot
  | Incomplete_retained_trace_snapshot
  | Trace_store_unavailable

type evidence =
  { trace_id : Keeper_id.Trace_id.t
  ; activation : Keeper_skill_activation_ledger.activation
  }

type latest =
  | Not_observed
  | Most_recent_observed of evidence
  | Most_recent_observed_timestamp_tie of evidence list

type t =
  { latest : latest
  ; scope : scope
  ; sessions_inspected : int
  ; ledgers_loaded : int
  ; gaps : gap list
  }

type ordered_evidence =
  { evidence : evidence
  ; activated_at : float
  ; ledger_index : int
  }

let activation_reference
      (activation : Keeper_skill_activation_ledger.activation) =
  Skill_reference.make
    ~identity:activation.identity
    ~content_revision:activation.content_revision
;;

let read_directory path =
  match Unix.opendir path with
  | exception Unix.Unix_error (cause, _, _) ->
    Error { operation = Open_directory; path; cause }
  | handle ->
    let rec loop reversed =
      match Unix.readdir handle with
      | entry -> loop (entry :: reversed)
      | exception End_of_file -> Ok (List.rev reversed)
      | exception Unix.Unix_error (cause, _, _) ->
        Error { operation = Read_directory; path; cause }
    in
    let result = loop [] in
    (match Unix.closedir handle with
     | () -> result
     | exception Unix.Unix_error (cause, _, _) ->
       Error { operation = Close_directory; path; cause })
;;

let latest_in_ledger trace_id reference ledger =
  Keeper_skill_activation_ledger.activations ledger
  |> List.mapi (fun ledger_index activation -> ledger_index, activation)
  |> List.filter_map (fun (ledger_index, activation) ->
       if Skill_reference.equal reference (activation_reference activation)
       then
         match
           Time_codec.parse_rfc3339
             activation.Keeper_skill_activation_ledger.activated_at
         with
         | Ok activated_at ->
           Some { evidence = { trace_id; activation }; activated_at; ledger_index }
         | Error Time_codec.Invalid_rfc3339 ->
           (* The strict ledger decoder and private activation constructor
              already reject this state. *)
           None
       else None)
  |> List.fold_left
       (fun latest candidate ->
          match latest with
          | None -> Some candidate
          | Some current
            when candidate.activated_at > current.activated_at
                 || (Float.equal candidate.activated_at current.activated_at
                     && candidate.ledger_index > current.ledger_index) ->
            Some candidate
          | Some current -> Some current)
       None
;;

let latest_across_traces candidates =
  let maximal =
    List.fold_left
      (fun maximal candidate ->
         match maximal with
         | [] -> [ candidate ]
         | current :: _ when candidate.activated_at > current.activated_at ->
           [ candidate ]
         | current :: _ when Float.equal candidate.activated_at current.activated_at ->
           candidate :: maximal
         | _ -> maximal)
      []
      candidates
  in
  match maximal with
  | [] -> Not_observed
  | [ candidate ] -> Most_recent_observed candidate.evidence
  | candidates ->
    candidates
    |> List.sort (fun left right ->
         String.compare
           (Keeper_id.Trace_id.to_string left.evidence.trace_id)
           (Keeper_id.Trace_id.to_string right.evidence.trace_id))
    |> List.map (fun candidate -> candidate.evidence)
    |> fun evidence -> Most_recent_observed_timestamp_tie evidence
;;

let empty =
  { latest = Not_observed
  ; scope = Complete_retained_trace_snapshot
  ; sessions_inspected = 0
  ; ledgers_loaded = 0
  ; gaps = []
  }
;;

let revision_option = function
  | None -> None
  | Some ledger ->
    Some
      (Keeper_skill_activation_ledger.revision ledger
       |> Keeper_skill_activation_ledger.ledger_revision_to_string)
;;

let revalidate_ledgers ~ownership_root observations gaps =
  List.fold_left
    (fun gaps (trace_id, observed_revision) ->
       match
         Keeper_skill_activation_ledger.load_existing_read_only_from_root
           ~ownership_root
           ~trace_id
       with
       | Error cause -> Ledger_unreadable { trace_id; cause } :: gaps
       | Ok ledger when revision_option ledger = observed_revision -> gaps
       | Ok _ -> Ledger_changed_during_discovery trace_id :: gaps)
    gaps
    observations
;;

let same_directory_identity left right =
  left.Unix.st_kind = Unix.S_DIR
  && right.Unix.st_kind = Unix.S_DIR
  && left.Unix.st_dev = right.Unix.st_dev
  && left.Unix.st_ino = right.Unix.st_ino
;;

let discover_with_after_first_pass ~after_first_pass config reference =
  let root = Keeper_fs.session_store_path config in
  match Unix.lstat root with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> empty
  | exception Unix.Unix_error (cause, _, _) ->
    { empty with
      scope = Trace_store_unavailable
    ; gaps =
        [ Trace_root_unavailable
            { operation = Stat_entry; path = root; cause }
        ]
    }
  | ({ Unix.st_kind = Unix.S_DIR; _ } as initial_root_stat) ->
    (match Unix.realpath root with
     | exception Unix.Unix_error (cause, _, _) ->
       { empty with
         scope = Trace_store_unavailable
       ; gaps =
           [ Trace_root_unavailable
               { operation = Stat_entry; path = root; cause }
           ]
       }
     | ownership_root ->
       (match Unix.lstat ownership_root with
        | canonical_root_stat
          when same_directory_identity initial_root_stat canonical_root_stat ->
    (match read_directory ownership_root with
     | Error error ->
       { empty with
         scope = Trace_store_unavailable
       ; gaps = [ Trace_root_unavailable error ]
       }
     | Ok entries ->
       let candidates, sessions_inspected, ledgers_loaded, observations, gaps =
         List.fold_left
           (fun
             (candidates, sessions_inspected, ledgers_loaded, observations, gaps)
             entry ->
              if String.equal entry "." || String.equal entry ".."
              then
                candidates, sessions_inspected, ledgers_loaded, observations, gaps
              else
                let path = Filename.concat ownership_root entry in
                match Unix.lstat path with
                | exception Unix.Unix_error (cause, _, _) ->
                  ( candidates
                  , sessions_inspected
                  , ledgers_loaded
                  , observations
                  , Trace_entry_unreadable
                      { operation = Stat_entry; path; cause }
                    :: gaps )
                | { Unix.st_kind = Unix.S_LNK; _ } ->
                  (match Keeper_id.Trace_id.of_string entry with
                   | Ok _ ->
                     ( candidates
                     , sessions_inspected
                     , ledgers_loaded
                     , observations
                     , Symlink_trace_entry entry :: gaps )
                   | Error _ ->
                     ( candidates
                     , sessions_inspected
                     , ledgers_loaded
                     , observations
                     , gaps ))
                | { Unix.st_kind = Unix.S_DIR; _ } ->
                  (match Keeper_id.Trace_id.of_string entry with
                   | Error _ ->
                     ( candidates
                     , sessions_inspected
                     , ledgers_loaded
                     , observations
                     , Invalid_trace_directory entry :: gaps )
                   | Ok trace_id ->
                     let sessions_inspected = sessions_inspected + 1 in
                     (match
                        Keeper_skill_activation_ledger.load_existing_read_only_from_root
                          ~ownership_root
                          ~trace_id
                      with
                      | Error cause ->
                        ( candidates
                        , sessions_inspected
                        , ledgers_loaded
                        , observations
                        , Ledger_unreadable { trace_id; cause } :: gaps )
                      | Ok None ->
                        ( candidates
                        , sessions_inspected
                        , ledgers_loaded
                        , (trace_id, None) :: observations
                        , gaps )
                      | Ok (Some ledger) ->
                        let candidates =
                          match latest_in_ledger trace_id reference ledger with
                          | None -> candidates
                          | Some evidence -> evidence :: candidates
                        in
                        ( candidates
                        , sessions_inspected
                        , ledgers_loaded + 1
                        , (trace_id, revision_option (Some ledger)) :: observations
                        , gaps )))
                | { Unix.st_kind; _ } ->
                  (match Keeper_id.Trace_id.of_string entry with
                   | Error _ ->
                     ( candidates
                     , sessions_inspected
                     , ledgers_loaded
                     , observations
                     , gaps )
                   | Ok trace_id ->
                     ( candidates
                     , sessions_inspected
                     , ledgers_loaded
                     , observations
                     , Trace_entry_not_directory { trace_id; kind = st_kind }
                       :: gaps )))
           ([], 0, 0, [], [])
           entries
       in
       after_first_pass ();
       let gaps = revalidate_ledgers ~ownership_root observations gaps in
       let gaps =
         match read_directory ownership_root with
         | Ok current_entries
           when List.sort String.compare current_entries
                = List.sort String.compare entries ->
           gaps
         | Ok _ -> Trace_inventory_changed_during_discovery :: gaps
         | Error error -> Trace_root_unavailable error :: gaps
       in
       let gaps, root_changed =
         match Unix.lstat root, Unix.lstat ownership_root with
         | current_root, current_canonical
           when same_directory_identity initial_root_stat current_root
                && same_directory_identity initial_root_stat current_canonical ->
           gaps, false
         | _ -> Trace_root_changed_during_discovery :: gaps, true
         | exception Unix.Unix_error (cause, _, _) ->
           ( Trace_root_unavailable
               { operation = Stat_entry; path = root; cause }
             :: gaps
           , true )
       in
       let gaps = List.rev gaps in
       { latest =
           (if root_changed then Not_observed else latest_across_traces candidates)
       ; scope =
           (match gaps with
            | [] -> Complete_retained_trace_snapshot
            | _ -> Incomplete_retained_trace_snapshot)
       ; sessions_inspected
       ; ledgers_loaded
       ; gaps
       })
        | _ ->
          { empty with
            scope = Incomplete_retained_trace_snapshot
          ; gaps = [ Trace_root_changed_during_discovery ]
          }
        | exception Unix.Unix_error (cause, _, _) ->
          { empty with
            scope = Trace_store_unavailable
          ; gaps =
              [ Trace_root_unavailable
                  { operation = Stat_entry; path = ownership_root; cause }
              ]
          }))
  | { Unix.st_kind; _ } ->
    { empty with
      scope = Trace_store_unavailable
    ; gaps = [ Trace_root_not_directory st_kind ]
    }
;;

let discover config reference =
  discover_with_after_first_pass ~after_first_pass:(fun () -> ()) config reference
;;

module For_testing = struct
  let discover = discover_with_after_first_pass
end
