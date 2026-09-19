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

    What it reads is every Keeper conversation on the machine, so what it
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
module Keeper_checkpoint_store = Masc.Keeper_checkpoint_store

let boundary_suffix =
  (* Asked of the module that writes the file instead of spelled out here, so
     renaming the artifact cannot leave this tool scanning for the old name. *)
  Filename.basename
    (Keeper_turn_boundaries.path_for_keepers_dir ~keepers_dir:"." ~keeper_id:"")
;;

let usage =
  "usage: masc-librarian-replay [--base-path DIR] [--keeper NAME]...\n\
  \  --base-path DIR   workspace to read (default: the resolved MASC base path)\n\
  \  --keeper NAME     replay only this keeper; repeatable, default every one\n\
  \                    that has a turn-boundary log\n"
;;

type round =
  { start_atom : int
  ; end_atom : int
  ; lines_seen : int
  }

type outcome =
  | Replayed of
      { rounds : round list
      ; stopped_by : string
      }
  | Skipped of string

(** The trace a round is asked about. The boundary log names it, so the tool
    does not need the keeper's meta record and therefore does not need a
    [Workspace.config] -- which would mean opening a storage backend to read
    files that are already on disk. The last ended turn is the trace the
    checkpoint on disk belongs to. *)
let trace_of_lines lines =
  List.fold_left
    (fun acc (_, decoded) ->
      match decoded with
      | Error _ -> acc
      | Ok (record : Keeper_turn_boundaries.record) ->
        (match record.event with
         | Keeper_turn_boundaries.Turn_ended { turn_ref; _ } ->
           Some (Ids.Turn_ref.trace_id turn_ref)
         | Keeper_turn_boundaries.History_restarted _ -> acc))
    None
    lines
;;

let stop_to_string = function
  | Keeper_librarian_range.Unreadable_line { line; error } ->
    Printf.sprintf
      "unreadable_line:%d:%s"
      line
      (Keeper_turn_boundaries.read_error_to_string error)
  | Keeper_librarian_range.Position_mismatch { atom_count; _ } ->
    Printf.sprintf "position_mismatch:atom_count=%d" atom_count
;;

(** Round after round until the rules say there is nothing left, threading the
    progress each round would have saved.

    The loop ends on its own for every selection but [Read]. For [Read] it ends
    when a round does not reach further than the one before it: that is a fixed
    point, not a budget, so no count has to be chosen here. A round that does
    not advance would repeat forever, and reporting it is the point -- it is
    the shape issue #37061 pins in the model. *)
let replay ~trace_id ~lines ~messages =
  let rec loop ~progress ~reached acc =
    let selection =
      Keeper_librarian_range.select
        ~trace_id
        ~lines
        ~progress
        ~messages
        Keeper_librarian_range.All_unread
    in
    match selection with
    | Keeper_librarian_range.Read { range; boundary_lines_seen } ->
      if range.end_atom <= reached
      then
        Replayed
          { rounds = List.rev acc
          ; stopped_by =
              Printf.sprintf
                "no_advance:end_atom=%d:already_reached=%d"
                range.end_atom
                reached
          }
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
    | Keeper_librarian_range.Baseline { boundary_lines_seen; _ } ->
      let next = Keeper_librarian_range.progress_after ~trace_id selection in
      if next = progress
      then
        Replayed
          { rounds = List.rev acc; stopped_by = "baseline_without_progress" }
      else
        loop
          ~progress:next
          ~reached
          ({ start_atom = 0; end_atom = 0; lines_seen = boundary_lines_seen } :: acc)
    | Keeper_librarian_range.Nothing_to_read ->
      Replayed { rounds = List.rev acc; stopped_by = "nothing_to_read" }
    | Keeper_librarian_range.Position_in_other_trace _ ->
      Replayed { rounds = List.rev acc; stopped_by = "position_in_other_trace" }
    | Keeper_librarian_range.Stop stop ->
      Replayed { rounds = List.rev acc; stopped_by = stop_to_string stop }
  in
  loop ~progress:None ~reached:0 []
;;

let replay_keeper ~base_path ~keepers_dir keeper_id =
  match Keeper_turn_boundaries.read ~keepers_dir ~keeper_id with
  | Error detail -> Skipped ("boundary_log_unreadable:" ^ detail)
  | Ok [] -> Skipped "boundary_log_empty"
  | Ok lines ->
    (match trace_of_lines lines with
     | None -> Skipped "no_ended_turn_in_log"
     | Some trace_id ->
       let session_dir =
         Filename.concat (Filename.concat base_path "traces") trace_id
       in
       (match
          Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:trace_id
        with
        | Error error ->
          Skipped
            ("checkpoint_unreadable:"
             ^ Keeper_checkpoint_store.checkpoint_load_error_to_string error)
        | Ok checkpoint ->
          replay
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
  | Replayed { rounds; stopped_by } ->
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
    `Assoc
      [ "keeper", `String keeper
      ; "rounds", `Int (List.length rounds)
      ; "atoms_carried", `Int atoms
      ; "atoms_distinct", `Int distinct
      ; "atoms_carried_twice", `Int (atoms - distinct)
      ; "stopped_by", `String stopped_by
      ; "round", `List (List.map round_to_json rounds)
      ]
;;

let keepers_with_a_log keepers_dir =
  match Sys.readdir keepers_dir with
  | exception Sys_error detail ->
    prerr_endline ("cannot list " ^ keepers_dir ^ ": " ^ detail);
    []
  | entries ->
    Array.to_list entries
    |> List.filter_map (fun entry ->
      let suffix_at = String.length entry - String.length boundary_suffix in
      if suffix_at > 0 && String.sub entry suffix_at (String.length boundary_suffix) = boundary_suffix
      then Some (String.sub entry 0 suffix_at)
      else None)
    |> List.sort compare
;;

let () =
  let base_path = ref None in
  let wanted = ref [] in
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
      | Some dir -> dir
      | None -> Config_dir_resolver.base_path_or_cwd ()
    in
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path ~base_path
    in
    let keepers =
      match List.rev !wanted with
      | [] -> keepers_with_a_log keepers_dir
      | named -> named
    in
    let results =
      List.map
        (fun keeper ->
          outcome_to_json keeper (replay_keeper ~base_path ~keepers_dir keeper))
        keepers
    in
    print_endline
      (Yojson.Safe.pretty_to_string
         (`Assoc
           [ "keepers_dir", `String keepers_dir
           ; "keeper", `List results
           ]))
;;
