(** Offline replay of the Librarian read rules over a live workspace (RFC
    librarian-lifecycle §9).

    {!Keeper_librarian_range.select} and {!Keeper_librarian_range.slice} decide
    what a Librarian round reads. They are pure and unit-tested, and until this
    tool nothing outside those tests called them: the loop that will call them
    in the server is a later step. So the rules have never met a real
    turn-boundary log or a real checkpoint, and the numbers RFC §9 asks for --
    how many rounds a keeper's backlog takes, how many atoms each round
    carries, whether any atom is carried twice -- have never been produced.

    This tool answers exactly those, and only those. The model-dependent
    measures in §9 (output rejection rate, continuity scoring) need a provider
    and an operator's choice of keeper; they are not here.

    It reads the current Keeper trace in the selected workspace cluster, so what it
    prints is counts, atom numbers and digests -- never message text. Adding a
    field that carries text turns a local measurement into a disclosure.

    It writes nothing: no progress file, no boundary line, no checkpoint. The
    progress it threads from round to round lives in memory for the length of
    one keeper. *)

(* [masc] is a wrapped library, so the keeper modules need its prefix. Aliased
   once here rather than spelled out at every use, which would make the reader
   ask whether some of them came from somewhere else. *)
module Keeper_turn_boundaries = Masc.Keeper_turn_boundaries
module Keeper_librarian_range = Masc.Keeper_librarian_range
module Keeper_librarian_progress = Masc.Keeper_librarian_progress
module Keeper_checkpoint_store = Masc.Keeper_checkpoint_store

let boundary_suffix =
  (* Asked of the module that writes the file instead of spelled out here, so
     renaming the artifact cannot leave this tool scanning for the old name. *)
  Filename.basename
    (Keeper_turn_boundaries.path_for_keepers_dir ~keepers_dir:"." ~keeper_id:"")
;;

let usage =
  "usage: masc-librarian-replay [--base-path DIR] [--keeper NAME]... [--extent \
   all|cut-points]\n\
  \  --base-path DIR   workspace to read (default: the resolved MASC base path)\n\
  \  --keeper NAME     replay only this keeper; repeatable, default every one\n\
  \                    that has a turn-boundary log\n\
  \                    Current cluster metadata is required; archived logs\n\
  \                    without it are skipped, never guessed from log order.\n\
  \  --extent all         each round takes the whole backlog (default)\n\
  \  --extent cut-points  each round takes to the first cut point, which is\n\
  \                       what a round takes after one failed on a longer\n\
  \                       range: the worst-case round count for the backlog\n"
;;

type round =
  { start_atom : int
  ; end_atom : int
  ; lines_seen : int
  }

(** Why a replay ended. A closed set, so the output names the case and its
    fields separately: a reader of this JSON never splits a sentence on ':'
    to find out which one it was. *)
type stop_reason =
  | Nothing_to_read
  | Position_in_other_trace
  | Baseline_without_progress
  | No_advance of
      { end_atom : int
      ; already_reached : int
      }
  | Unreadable_line of
      { line : int
      ; error : string
      }
  | Position_mismatch of { atom_count : int }

type outcome =
  | Replayed of
      { rounds : round list
      ; stopped_by : stop_reason
      ; reached : int
      ; atoms_total : (int, string) result
      }
  | Skipped of string

(** Boundary logs may be shared through [MASC_CONFIG_DIR]. The selected
    cluster's typed metadata owns its current trace. This reader neither
    creates directories nor repairs metadata, and opens no storage backend. *)
let trace_of_metadata ~runtime_root keeper_id =
  let path =
    Filename.concat
      (Filename.concat runtime_root Common.keepers_runtime_dirname)
      (Masc.Keeper_runtime_root_entry.keeper_basename
         ~keeper_name:keeper_id Masc.Keeper_runtime_root_entry.Metadata)
  in
  match Masc.Keeper_meta_store.read_meta_file_path_read_only
          ~ownership_root:runtime_root path with
  | Error (Masc.Keeper_meta_store.Unreadable detail) ->
    Error ("metadata_unreadable:" ^ detail)
  | Error (Masc.Keeper_meta_store.Not_current detail) ->
    Error ("metadata_not_current:" ^ detail)
  | Ok None -> Error "metadata_absent"
  | Ok (Some meta) ->
    if String.equal meta.name keeper_id
    then Ok (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
    else Error "metadata_identity_mismatch"
;;

let stop_of_selection_stop = function
  | Keeper_librarian_range.Unreadable_line { line; error } ->
    Unreadable_line { line; error = Keeper_turn_boundaries.read_error_to_string error }
  | Keeper_librarian_range.Position_mismatch { atom_count; _ } ->
    Position_mismatch { atom_count }
;;

let stop_reason_to_json = function
  | Nothing_to_read -> `Assoc [ "kind", `String "nothing_to_read" ]
  | Position_in_other_trace -> `Assoc [ "kind", `String "position_in_other_trace" ]
  | Baseline_without_progress ->
    `Assoc [ "kind", `String "baseline_without_progress" ]
  | No_advance { end_atom; already_reached } ->
    `Assoc
      [ "kind", `String "no_advance"
      ; "end_atom", `Int end_atom
      ; "already_reached", `Int already_reached
      ]
  | Unreadable_line { line; error } ->
    `Assoc
      [ "kind", `String "unreadable_line"; "line", `Int line; "error", `String error ]
  | Position_mismatch { atom_count } ->
    `Assoc [ "kind", `String "position_mismatch"; "atom_count", `Int atom_count ]
;;

(** Round after round until the rules say there is nothing left, threading the
    progress each round would have saved.

    The loop ends on its own for every selection but [Read]. For [Read] it ends
    when a round does not reach further than the one before it: a fixed point,
    not a budget, so no count has to be chosen here. That guard is a safety
    net for a shape the rules should not produce, and nothing more -- the
    permanent stop issue #37061 pins arrives as [Stop (Unreadable_line _)],
    which a line that stops one round keeps producing for every later one
    (see {!Keeper_librarian_range.stop}), and that already ends the loop with
    its own reason.

    What no stop reason states on its own is whether anything was left behind.
    [Nothing_to_read] means no cut point lies beyond the start, which is both
    what a finished backlog looks like and what a backlog with atoms past the
    last cut point looks like. So the result carries [reached] and the
    checkpoint's atom count beside the reason, and the two together answer the
    question the spec calls [AtomsUpToLastCutRead].

    [extent] decides what a round takes, and it is what makes the round count
    mean anything. With [All_unread] a clean log has exactly one reading round
    -- the round takes everything and the next one finds no cut point past it
    -- so the round count is one and no atom can be carried twice whatever the
    data says. [To_first_cut_point] is what a round takes after one failed on
    a longer range ({!Keeper_librarian_range.extent}), so replaying every round
    as if it had failed makes the round count the number of cut points in the
    backlog: the worst case for clearing it, counted without a model. *)
let replay ~extent ~trace_id ~lines ~messages =
  (* Counted through [Keeper_turn_boundaries.position_of_messages], which is
     the same [Runtime_model_input_tail_window.annotate] the selection counts
     with. That is deliberate -- the two numbers have to be in one numbering
     for their difference to mean anything -- and it is also the limit: this
     measures coverage inside that numbering and cannot catch a miscount by
     the function both sides share. *)
  let atoms_total =
    match Keeper_turn_boundaries.position_of_messages messages with
    | Ok (Keeper_turn_boundaries.Atom_history { end_atom; _ }) -> Ok end_atom
    | Ok Keeper_turn_boundaries.Empty_atom_history -> Ok 0
    | Ok Keeper_turn_boundaries.No_atom_history -> Error "no_atom_history"
    | Ok Keeper_turn_boundaries.Stale_noop -> Error "stale_noop"
    | Error detail -> Error detail
  in
  let stop ~rounds ~reached stopped_by =
    Replayed { rounds = List.rev rounds; stopped_by; reached; atoms_total }
  in
  let rec loop ~progress ~reached acc =
    let selection =
      Keeper_librarian_range.select
        ~trace_id
        ~lines
        ~progress
        ~messages
        extent
    in
    match selection with
    | Keeper_librarian_range.Read { range; boundary_lines_seen } ->
      if range.end_atom <= reached
      then
        stop
          ~rounds:acc
          ~reached
          (No_advance { end_atom = range.end_atom; already_reached = reached })
      else (
        let round =
          { start_atom = range.start_atom
          ; end_atom = range.end_atom
          ; lines_seen = boundary_lines_seen
          }
        in
        (* Called for its cost and for the contract that a range slices the
           list it was selected from; the messages themselves go nowhere. *)
        let _carried : Agent_core.Types.message list =
          Keeper_librarian_range.slice messages range
        in
        loop
          ~progress:(Keeper_librarian_range.progress_after ~trace_id selection)
          ~reached:range.end_atom
          (round :: acc))
    | Keeper_librarian_range.Baseline { position; boundary_lines_seen } ->
      let next = Keeper_librarian_range.progress_after ~trace_id selection in
      if next = progress
      then stop ~rounds:acc ~reached Baseline_without_progress
      else (
        (* A baseline round reads nothing and moves the position to the
           smallest cut point: the history before it predates the log and is
           deliberately not read (RFC §10 decision 1). Carrying [reached]
           forward unchanged here would count that history as a backlog the
           rules failed to reach, which is the opposite of what happened. *)
        let at = position.Keeper_librarian_progress.end_atom in
        loop
          ~progress:next
          ~reached:(max reached at)
          ({ start_atom = at; end_atom = at; lines_seen = boundary_lines_seen } :: acc))
    | Keeper_librarian_range.Nothing_to_read ->
      stop ~rounds:acc ~reached Nothing_to_read
    | Keeper_librarian_range.Position_in_other_trace _ ->
      stop ~rounds:acc ~reached Position_in_other_trace
    | Keeper_librarian_range.Stop reason ->
      stop ~rounds:acc ~reached (stop_of_selection_stop reason)
  in
  loop ~progress:None ~reached:0 []
;;

let replay_keeper ~extent ~runtime_root ~session_store ~keepers_dir keeper_id =
  match Keeper_turn_boundaries.read ~keepers_dir ~keeper_id with
  | Error detail -> Skipped ("boundary_log_unreadable:" ^ detail)
  | Ok [] -> Skipped "boundary_log_empty"
  | Ok lines ->
    (match trace_of_metadata ~runtime_root keeper_id with
     | Error detail -> Skipped detail
     | Ok trace_id ->
       let session_dir = Filename.concat session_store trace_id in
       (match
          Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:trace_id
        with
        | Error error ->
          Skipped
            ("checkpoint_unreadable:"
             ^ Keeper_checkpoint_store.checkpoint_load_error_to_string error)
        | Ok checkpoint ->
          replay
            ~extent
            ~trace_id
            ~lines
            ~messages:checkpoint.Agent_core.Checkpoint.messages))
;;

let round_to_json r =
  `Assoc
    [ "start_atom", `Int r.start_atom
    ; "end_atom", `Int r.end_atom
    ; "atoms", `Int (r.end_atom - r.start_atom)
    ; "boundary_lines_seen", `Int r.lines_seen
    ]
;;

let outcome_to_json keeper = function
  | Skipped reason -> `Assoc [ "keeper", `String keeper; "skipped", `String reason ]
  | Replayed { rounds; stopped_by; reached; atoms_total } ->
    let atoms = List.fold_left (fun n r -> n + (r.end_atom - r.start_atom)) 0 rounds in
    (* Every atom the replay carried, counted once per round it appeared in.
       The rules are meant to hand each atom to exactly one round, so this
       number differing from [atoms] is the measurement, not a detail. *)
    let distinct =
      List.fold_left
        (fun seen r ->
          List.init (r.end_atom - r.start_atom) (fun i -> r.start_atom + i) @ seen)
        []
        rounds
      |> List.sort_uniq compare
      |> List.length
    in
    (* The stop reason does not say whether anything was left behind:
       [nothing_to_read] is both a finished backlog and one whose remaining
       atoms have no cut point. These three say which. *)
    let left_behind =
      match atoms_total with
      | Ok total -> [ "atoms_in_checkpoint", `Int total; "atoms_left", `Int (total - reached) ]
      | Error detail -> [ "atoms_in_checkpoint", `String detail ]
    in
    (* Ordered by what the data actually changes. A replay that ends in a
       [Stop] is a keeper the rules cannot get past, and atoms_left is the
       backlog nothing reached: those two are the answer. The round and atom
       counts below them only vary under To_first_cut_point -- All_unread
       takes the whole backlog in one round, so there the count is one and
       nothing can be carried twice whatever the log holds. *)
    `Assoc
      ([ "keeper", `String keeper; "stopped_by", stop_reason_to_json stopped_by ]
       @ left_behind
       @ [ "reached_atom", `Int reached
         ; "rounds", `Int (List.length rounds)
         ; "atoms_carried", `Int atoms
         ; "atoms_distinct", `Int distinct
         ; "atoms_carried_twice", `Int (atoms - distinct)
         ; "round", `List (List.map round_to_json rounds)
         ])
;;

let keepers_with_a_log keepers_dir =
  match Sys.readdir keepers_dir with
  | exception Sys_error detail -> Error detail
  | entries ->
    Ok
      (Array.to_list entries
       |> List.filter_map (fun entry ->
         let suffix_at = String.length entry - String.length boundary_suffix in
         if suffix_at > 0
            && String.sub entry suffix_at (String.length boundary_suffix) = boundary_suffix
         then Some (String.sub entry 0 suffix_at)
         else None)
       |> List.sort compare)
;;

let () =
  let base_path = ref None in
  let wanted = ref [] in
  let extent = ref Keeper_librarian_range.All_unread in
  let rec parse = function
    | [] -> Ok ()
    | "--help" :: _ | "-h" :: _ ->
      print_string usage;
      exit 0
    | "--base-path" :: dir :: rest ->
      base_path := Some dir;
      parse rest
    | "--keeper" :: name :: rest ->
      wanted := name :: !wanted;
      parse rest
    | "--extent" :: "all" :: rest ->
      extent := Keeper_librarian_range.All_unread;
      parse rest
    | "--extent" :: "cut-points" :: rest ->
      extent := Keeper_librarian_range.To_first_cut_point;
      parse rest
    | "--extent" :: other :: _ ->
      Error ("--extent takes all or cut-points, not: " ^ other)
    | arg :: _ -> Error ("unexpected argument: " ^ arg)
  in
  match parse (List.tl (Array.to_list Sys.argv)) with
  | Error detail ->
    prerr_endline detail;
    prerr_string usage;
    exit 2
  | Ok () ->
    let base_path =
      match !base_path with
      | Some dir ->
        dir
        |> Config_dir_resolver.absolute_path
        |> Masc.Workspace.runtime_base_path_for_request
      | None ->
        Config_dir_resolver.base_path_or_cwd ()
        |> Masc.Workspace.runtime_base_path_for
    in
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path ~base_path
    in
    (* Use the writer's cluster resolution without opening a storage backend. *)
    let runtime_root = (Masc.Workspace.backend_config_for base_path).base_path in
    let session_store = Masc.Keeper_fs.session_store_path_for_base_path base_path in
    let keepers_with_logs =
      match keepers_with_a_log keepers_dir with
      | Ok keepers -> keepers
      | Error detail ->
        prerr_endline ("cannot list " ^ keepers_dir ^ ": " ^ detail);
        exit 2
    in
    let keepers =
      match List.rev !wanted with
      | [] -> keepers_with_logs
      | named -> named
    in
    let results =
      List.map
        (fun keeper ->
          outcome_to_json
            keeper
            (replay_keeper
               ~extent:!extent ~runtime_root ~session_store ~keepers_dir keeper))
        keepers
    in
    print_endline
      (Yojson.Safe.pretty_to_string
         (`Assoc
           [ "keepers_dir", `String keepers_dir
           ; ( "extent"
             , `String
                 (match !extent with
                  | Keeper_librarian_range.All_unread -> "all"
                  | Keeper_librarian_range.To_first_cut_point -> "cut-points") )
           ; "keeper", `List results
           ]))
;;
