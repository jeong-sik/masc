(* Event Bus sourcing for Cognitive Gravity's Memory OS decay.

   Phase4: Bridges workspace activity (Board posts, Task transitions,
   Git events) to Cognitive_gravity.decay_trigger values for use in
   Memory OS stale-fact reconciliation via apply_decay. *)

(** [read_tail ~n path] reads the last [n] lines from a JSONL file.
    In-phase4 wiring this reads the GC event log for recent triggers. *)
let read_tail ~n path =
  try
    let ic = open_in path in
    let rec read_all acc =
      match try Some (input_line ic) with End_of_file -> None with
      | Some line -> read_all (line :: acc)
      | None -> List.rev acc
    in
    let lines = read_all [] in
    close_in ic;
    let len = List.length lines in
    if len <= n then lines
    else
      let skip = len - n in
      let rec drop i = function
        | _ :: xs when i > 0 -> drop (i - 1) xs
        | rest -> rest
      in
      drop skip lines
  with _ -> []

(** [parse_jsonl_field ~kind ~id_field ~status_field lines] filters
    JSONL lines matching [kind] and extracts fields. *)
let parse_jsonl_field ~kind ~id_field ~status_field lines =
  List.filter_map (fun line ->
    try
      let json = Yojson.Safe.from_string line in
      match json with
      | `Assoc items ->
        let line_kind = List.assoc "kind" items |> function
          | `String s -> s | _ -> ""
        in
        if String.equal line_kind kind then
          let id = List.assoc id_field items |> function
            | `String s -> s | _ -> ""
          in
          if String.equal status_field "" then Some id
          else
            let st = List.assoc status_field items |> function
              | `String s -> s | _ -> ""
            in
            Some (id, st)
        else None
      | _ -> None
    with _ -> None
  ) lines

(** [source_board ~limit ()] converts recent Board posts into
    [BoardPost] triggers. Reads from Memory OS GC event log
    as a fallback when the Board runtime is inaccessible. *)
let source_board ?(limit = 10) () =
  let event_path = Keeper_memory_os_io.events_path "default" in
  let lines = read_tail ~n:limit event_path in
  List.map (fun id -> Cognitive_gravity.BoardPost id)
    (parse_jsonl_field ~kind:"board_post" ~id_field:"fact_id" ~status_field:"" lines)

(** [source_tasks ~since_ids ()] converts task status transitions into
    [TaskTransition] triggers. Reads from GC event log. *)
let source_tasks ?(since_ids = []) () =
  let _ = since_ids in
  let event_path = Keeper_memory_os_io.events_path "default" in
  let lines = read_tail ~n:20 event_path in
  let pairs = parse_jsonl_field ~kind:"task_transition" ~id_field:"fact_id" ~status_field:"status" lines in
  List.map (fun (tid, st) -> Cognitive_gravity.TaskTransition (tid, st)) pairs

(** [source_git ()] returns [GitEvent] triggers. Phase4 stub until
    git integration layer is wired. *)
let source_git ?(since_ref:_ = "HEAD~5") () =
  let _ = since_ref in
  []

(** [poll_all ()] collects triggers from all three sources and feeds
    them through [Cognitive_gravity.apply_decay]. Returns decay results
    as (fact_id, decay_factor) pairs from the cognitive gravity engine. *)
let poll_all () =
  let triggers = List.concat [
    source_board ();
    source_tasks ();
    source_git ();
  ] in
  Cognitive_gravity.apply_decay triggers ~query:[]