(** Debate - Multi-agent structured debate system for MASC

    Implements topic-based debates with positions (Support/Oppose/Neutral).
    Storage is file-based under .masc/debates/
*)

(** {1 Types} *)

type position = Support | Oppose | Neutral

type argument = {
  agent: string;
  position: position;
  content: string;
  evidence: string list;
}

type debate_status = Open | Closed | Pending

type debate = {
  id: string;
  topic: string;
  status: debate_status;
  arguments: argument list;
  created_at: float;
}

(** {1 ID Generation} *)

(* Fiber-safe random state for debate ID generation *)
let debate_rng = Random.State.make_self_init ()

let generate_debate_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let rand = Random.State.int debate_rng 1_000_000 in
  Printf.sprintf "debate-%d-%06d" ts rand

(** {1 JSON Serialization} *)

let position_to_string = function
  | Support -> "support"
  | Oppose -> "oppose"
  | Neutral -> "neutral"

let position_of_string = function
  | "support" -> Ok Support
  | "oppose" -> Ok Oppose
  | "neutral" -> Ok Neutral
  | s -> Error (Printf.sprintf "Unknown position: %s" s)

let status_to_string = function
  | Open -> "open"
  | Closed -> "closed"
  | Pending -> "pending"

let status_of_string = function
  | "open" -> Ok Open
  | "closed" -> Ok Closed
  | "pending" -> Ok Pending
  | s -> Error (Printf.sprintf "Unknown status: %s" s)

let argument_to_yojson (a : argument) : Yojson.Safe.t =
  `Assoc [
    ("agent", `String a.agent);
    ("position", `String (position_to_string a.position));
    ("content", `String a.content);
    ("evidence", `List (List.map (fun e -> `String e) a.evidence));
  ]

let argument_of_yojson (json : Yojson.Safe.t) : (argument, string) result =
  let open Yojson.Safe.Util in
  try
    let agent = json |> member "agent" |> to_string in
    let pos_str = json |> member "position" |> to_string in
    match position_of_string pos_str with
    | Error e -> Error e
    | Ok position ->
        let content = json |> member "content" |> to_string in
        let evidence = json |> member "evidence" |> to_list |> List.map to_string in
        Ok { agent; position; content; evidence }
  with e ->
    Error (Printf.sprintf "Failed to parse argument: %s" (Printexc.to_string e))

let debate_to_yojson (d : debate) : Yojson.Safe.t =
  `Assoc [
    ("id", `String d.id);
    ("topic", `String d.topic);
    ("status", `String (status_to_string d.status));
    ("arguments", `List (List.map argument_to_yojson d.arguments));
    ("created_at", `Float d.created_at);
  ]

let debate_of_yojson (json : Yojson.Safe.t) : (debate, string) result =
  let open Yojson.Safe.Util in
  try
    let id = json |> member "id" |> to_string in
    let topic = json |> member "topic" |> to_string in
    let status_str = json |> member "status" |> to_string in
    match status_of_string status_str with
    | Error e -> Error e
    | Ok status ->
        let args_json = json |> member "arguments" |> to_list in
        let args_results = List.map argument_of_yojson args_json in
        let rec collect_args acc = function
          | [] -> Ok (List.rev acc)
          | Ok arg :: rest -> collect_args (arg :: acc) rest
          | Error e :: _ -> Error e
        in
        (match collect_args [] args_results with
         | Error e -> Error e
         | Ok arguments ->
             let created_at = json |> member "created_at" |> to_float in
             Ok { id; topic; status; arguments; created_at })
  with e ->
    Error (Printf.sprintf "Failed to parse debate: %s" (Printexc.to_string e))

(** {1 Storage Operations} *)

let masc_dir config =
  Room_utils.masc_dir config

let debates_dir config =
  Filename.concat (masc_dir config) "debates"

let rec ensure_dir path =
  if not (Sys.file_exists path) then begin
    let parent = Filename.dirname path in
    if parent <> path && not (Sys.file_exists parent) then
      ensure_dir parent;
    try Unix.mkdir path 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let ensure_dirs config =
  ensure_dir (debates_dir config)

let debate_path config debate_id =
  Filename.concat (debates_dir config) (debate_id ^ ".json")

(** Write JSON to file atomically (temp file + rename) *)
let write_json path json =
  let content = Yojson.Safe.pretty_to_string json in
  let dir = Filename.dirname path in
  let base = Filename.basename path in
  let tmp_path = Filename.concat dir (Printf.sprintf ".%s.tmp.%d" base (Unix.getpid ())) in
  let oc = open_out tmp_path in
  let closed = ref false in
  Common.protect ~module_name:"debate" ~finally_label:"finalizer" ~finally:(fun () ->
    if not !closed then (try close_out oc with exn ->
      Log.Misc.error "[debate] close_out failed: %s" (Printexc.to_string exn));
    if Sys.file_exists tmp_path then
      Safe_ops.remove_file_logged ~context:"debate" tmp_path
  ) (fun () ->
    output_string oc content;
    flush oc;
    close_out oc;
    closed := true;
    Sys.rename tmp_path path
  )

(** Read JSON from file *)
let read_json path =
  match Safe_ops.read_file_safe path with
  | Ok content ->
      (match Safe_ops.parse_json_safe ~context:path content with
       | Ok json -> Some json
       | Error _ -> None)
  | Error _ -> None

(** {1 Debate Operations} *)

(** Start a new debate on a topic.
    Notifies relevant agents via the notify callback. *)
let start_debate config ~topic ?(notify_agents=[]) ~notify_fn () : (debate, string) result =
  ensure_dirs config;
  let id = generate_debate_id () in
  let debate : debate = {
    id;
    topic;
    status = Open;
    arguments = [];
    created_at = Time_compat.now ();
  } in
  let path = debate_path config id in
  try
    write_json path (debate_to_yojson debate);
    (* Notify relevant agents about the new debate *)
    List.iter (fun agent ->
      let msg = Printf.sprintf "New debate started: [%s] %s" id topic in
      notify_fn ~agent ~message:msg
    ) notify_agents;
    Ok debate
  with e ->
    Error (Printf.sprintf "Failed to start debate: %s" (Printexc.to_string e))

(** Get a debate by ID *)
let get_debate config ~debate_id : (debate, string) result =
  let path = debate_path config debate_id in
  match read_json path with
  | Some json -> debate_of_yojson json
  | None -> Error (Printf.sprintf "Debate not found: %s" debate_id)

(** Save a debate *)
let save_debate config (debate : debate) : unit =
  let path = debate_path config debate.id in
  write_json path (debate_to_yojson debate)

(** Add an argument to a debate *)
let add_argument config ~debate_id ~agent ~position ~content ?(evidence=[]) () : (debate, string) result =
  match get_debate config ~debate_id with
  | Error e -> Error e
  | Ok debate ->
      if debate.status <> Open then
        Error (Printf.sprintf "Cannot add argument: debate %s is not open" debate_id)
      else begin
        let arg : argument = { agent; position; content; evidence } in
        let updated = { debate with arguments = debate.arguments @ [arg] } in
        try
          save_debate config updated;
          Ok updated
        with e ->
          Error (Printf.sprintf "Failed to add argument: %s" (Printexc.to_string e))
      end

(** Get the current status of a debate with summary *)
type debate_summary = {
  debate: debate;
  support_count: int;
  oppose_count: int;
  neutral_count: int;
  total_arguments: int;
}

let get_debate_status config ~debate_id : (debate_summary, string) result =
  match get_debate config ~debate_id with
  | Error e -> Error e
  | Ok debate ->
      let count_position pos =
        List.length (List.filter (fun (a : argument) -> a.position = pos) debate.arguments)
      in
      Ok {
        debate;
        support_count = count_position Support;
        oppose_count = count_position Oppose;
        neutral_count = count_position Neutral;
        total_arguments = List.length debate.arguments;
      }

(** Close a debate *)
let close_debate config ~debate_id : (debate, string) result =
  match get_debate config ~debate_id with
  | Error e -> Error e
  | Ok debate ->
      if debate.status = Closed then
        Error (Printf.sprintf "Debate %s is already closed" debate_id)
      else begin
        let updated = { debate with status = Closed } in
        try
          save_debate config updated;
          Ok updated
        with e ->
          Error (Printf.sprintf "Failed to close debate: %s" (Printexc.to_string e))
      end

(** {1 Resolution} *)

type resolution = {
  winning_position: position;
  support_count: int;
  oppose_count: int;
  neutral_count: int;
  summary: string;
}

let resolution_to_json (r : resolution) : Yojson.Safe.t =
  `Assoc [
    ("winning_position", `String (position_to_string r.winning_position));
    ("support_count", `Int r.support_count);
    ("oppose_count", `Int r.oppose_count);
    ("neutral_count", `Int r.neutral_count);
    ("summary", `String r.summary);
  ]

let determine_resolution (debate : debate) : resolution =
  let count_pos pos =
    List.length (List.filter (fun (a : argument) -> a.position = pos) debate.arguments)
  in
  let sc = count_pos Support in
  let oc = count_pos Oppose in
  let nc = count_pos Neutral in
  let winning_position =
    if sc > oc && sc > nc then Support
    else if oc > sc && oc > nc then Oppose
    else Neutral
  in
  let summary =
    Printf.sprintf "Debate '%s' resolved: %s (%d support, %d oppose, %d neutral)"
      debate.topic (position_to_string winning_position) sc oc nc
  in
  { winning_position; support_count = sc; oppose_count = oc;
    neutral_count = nc; summary }

(** Close a debate with resolution and optionally create a task from the outcome. *)
let close_with_resolution config ~debate_id ~create_task :
    (debate * resolution * string option, string) result =
  match get_debate config ~debate_id with
  | Error e -> Error e
  | Ok debate ->
      if debate.status = Closed then
        Error (Printf.sprintf "Debate %s is already closed" debate_id)
      else
        let resolution = determine_resolution debate in
        let updated = { debate with status = Closed } in
        (try save_debate config updated
         with e ->
           Log.Council.error "save failed: %s" (Printexc.to_string e));
        let task_id =
          if create_task && resolution.winning_position = Support then
            (try
               let task_title =
                 Printf.sprintf "[Debate Resolution] %s" debate.topic
               in
               let task_desc =
                 Printf.sprintf "Auto-created from debate %s. %s"
                   debate.id resolution.summary
               in
               let _task =
                 Room.add_task config ~title:task_title ~priority:3
                   ~description:task_desc
               in
               Some (Printf.sprintf "task created: %s" task_title)
             with e ->
               Log.Council.error "task creation failed: %s"
                 (Printexc.to_string e);
               None)
          else None
        in
        Ok (updated, resolution, task_id)

(** List all debates *)
let list_debates config ?(status_filter=None) ?(limit=50) () : debate list =
  ensure_dirs config;
  let dir = debates_dir config in
  match Safe_ops.list_dir_safe dir with
  | Error _ -> []
  | Ok files ->
      let json_files = List.filter (fun f -> Filename.check_suffix f ".json") files in
      let debates : debate list = List.filter_map (fun f ->
        let path = Filename.concat dir f in
        match read_json path with
        | Some json ->
            (match debate_of_yojson json with
             | Ok d -> Some d
             | Error _ -> None)
        | None -> None
      ) json_files in
      (* Filter by status if specified *)
      let filtered = match status_filter with
        | None -> debates
        | Some s -> List.filter (fun (d : debate) -> d.status = s) debates
      in
      (* Sort by created_at desc *)
      let sorted = List.sort (fun (a : debate) (b : debate) ->
        compare b.created_at a.created_at
      ) filtered in
      (* Apply limit *)
      let rec take n lst = match n, lst with
        | 0, _ -> []
        | _, [] -> []
        | n, x :: xs -> x :: take (n-1) xs
      in
      take limit sorted

(** Render debate summary as string *)
let render_summary (summary : debate_summary) : string =
  let d = summary.debate in
  let status_str = status_to_string d.status in
  Printf.sprintf
    "Debate: %s\nTopic: %s\nStatus: %s\n\nPositions:\n  Support: %d\n  Oppose: %d\n  Neutral: %d\nTotal arguments: %d"
    d.id d.topic status_str
    summary.support_count summary.oppose_count summary.neutral_count
    summary.total_arguments
