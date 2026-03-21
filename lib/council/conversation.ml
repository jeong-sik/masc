(** Conversation - Multi-agent persistent conversation system for MASC

    Implements topic-based threaded conversations with turn-taking,
    loop prevention, and dual-stream persistence (file + Neo4j).

    Based on academic research:
    - MAGMA (2026.01): Dual-stream Write pattern
    - A-MEM (NeurIPS 2025): Zettelkasten-style linking
    - SSJ 1974: Turn-taking systematics (Adjacency Pair)
    - Hashgraph: Gossip + Virtual Voting for loop prevention
*)

(** {1 Types} *)

type turn_type =
  | Initiate
  | Respond
  | FollowUp
  | Conclude

type thread_status =
  | Active
  | Concluded
  | Stalled
  | Archived

type turn = {
  id: string;
  seq: int;
  speaker: string;
  content: string;
  turn_type: turn_type;
  created_at: float;
  confidence: float option;
  reply_to: string option;
  mentions: string list;
}

type thread = {
  id: string;
  topic: string;
  room: string;
  status: thread_status;
  turns: turn list;
  participants: string list;
  started_at: float;
  concluded_at: float option;
  conclusion: string option;
  max_turns: int;
  current_turn: int;
  floor_holder: string option;
  source_post_id: string option;  (* Board post that spawned this thread *)
}

type config = {
  base_path: string;
  room: string;
}

(** {1 Helper Functions} *)

let read_file_safe path =
  try
    let ic = open_in path in
    let content =
      Fun.protect ~finally:(fun () -> close_in_noerr ic)
        (fun () -> really_input_string ic (in_channel_length ic))
    in
    Ok content
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

let parse_json_safe content =
  try Ok (Yojson.Safe.from_string content)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

let list_dir_safe dir =
  try Ok (Array.to_list (Sys.readdir dir))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** {1 Directory Management} *)

let masc_dir (config : config) =
  Filename.concat config.base_path ".masc"

let conversations_dir config =
  Filename.concat (masc_dir config) "conversations"

let threads_dir config =
  Filename.concat (conversations_dir config) "threads"

let thread_path config thread_id =
  Filename.concat (threads_dir config) (thread_id ^ ".json")

let rec ensure_dir path =
  if not (Sys.file_exists path) then begin
    ensure_dir (Filename.dirname path);
    (try Sys.mkdir path 0o755 with Sys_error e ->
      Printf.eprintf "[conversation] ensure_dir failed: %s (path=%s)\n%!" e path)
  end

let ensure_dirs config =
  ensure_dir (threads_dir config)

(** {1 ID Generation} *)

let generate_thread_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFFF in
  Printf.sprintf "thread-%d-%06x" ts hash

let generate_turn_id ~thread_id ~seq =
  Printf.sprintf "%s-turn-%04d" thread_id seq

(** {1 JSON Serialization} *)

let turn_type_to_string = function
  | Initiate -> "initiate"
  | Respond -> "respond"
  | FollowUp -> "follow_up"
  | Conclude -> "conclude"

let turn_type_of_string = function
  | "initiate" -> Ok Initiate
  | "respond" -> Ok Respond
  | "follow_up" -> Ok FollowUp
  | "conclude" -> Ok Conclude
  | s -> Error (Printf.sprintf "Unknown turn_type: %s" s)

let thread_status_to_string = function
  | Active -> "active"
  | Concluded -> "concluded"
  | Stalled -> "stalled"
  | Archived -> "archived"

let thread_status_of_string = function
  | "active" -> Ok Active
  | "concluded" -> Ok Concluded
  | "stalled" -> Ok Stalled
  | "archived" -> Ok Archived
  | s -> Error (Printf.sprintf "Unknown thread_status: %s" s)

let turn_to_yojson (t : turn) : Yojson.Safe.t =
  let base = [
    ("id", `String t.id);
    ("seq", `Int t.seq);
    ("speaker", `String t.speaker);
    ("content", `String t.content);
    ("turn_type", `String (turn_type_to_string t.turn_type));
    ("created_at", `Float t.created_at);
    ("mentions", `List (List.map (fun m -> `String m) t.mentions));
  ] in
  let with_confidence = match t.confidence with
    | None -> base
    | Some c -> ("confidence", `Float c) :: base
  in
  let with_reply_to = match t.reply_to with
    | None -> with_confidence
    | Some r -> ("reply_to", `String r) :: with_confidence
  in
  `Assoc with_reply_to

let turn_of_yojson (json : Yojson.Safe.t) : (turn, string) result =
  let open Yojson.Safe.Util in
  try
    let id = json |> member "id" |> to_string in
    let seq = json |> member "seq" |> to_int in
    let speaker = json |> member "speaker" |> to_string in
    let content = json |> member "content" |> to_string in
    let turn_type_str = json |> member "turn_type" |> to_string in
    let created_at = json |> member "created_at" |> to_float in
    let confidence = json |> member "confidence" |> to_float_option in
    let reply_to = json |> member "reply_to" |> to_string_option in
    let mentions = json |> member "mentions" |> to_list |> List.map to_string in
    match turn_type_of_string turn_type_str with
    | Ok turn_type ->
        Ok { id; seq; speaker; content; turn_type; created_at; confidence; reply_to; mentions }
    | Error e -> Error e
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Error (Printf.sprintf "Failed to parse turn: %s" (Printexc.to_string e))

let thread_to_yojson (th : thread) : Yojson.Safe.t =
  let base = [
    ("id", `String th.id);
    ("topic", `String th.topic);
    ("room", `String th.room);
    ("status", `String (thread_status_to_string th.status));
    ("turns", `List (List.map turn_to_yojson th.turns));
    ("participants", `List (List.map (fun p -> `String p) th.participants));
    ("started_at", `Float th.started_at);
    ("max_turns", `Int th.max_turns);
    ("current_turn", `Int th.current_turn);
  ] in
  let with_concluded_at = match th.concluded_at with
    | None -> base
    | Some t -> ("concluded_at", `Float t) :: base
  in
  let with_conclusion = match th.conclusion with
    | None -> with_concluded_at
    | Some c -> ("conclusion", `String c) :: with_concluded_at
  in
  let with_floor = match th.floor_holder with
    | None -> with_conclusion
    | Some f -> ("floor_holder", `String f) :: with_conclusion
  in
  let with_source = match th.source_post_id with
    | None -> with_floor
    | Some pid -> ("source_post_id", `String pid) :: with_floor
  in
  `Assoc with_source

let thread_of_yojson (json : Yojson.Safe.t) : (thread, string) result =
  let open Yojson.Safe.Util in
  try
    let id = json |> member "id" |> to_string in
    let topic = json |> member "topic" |> to_string in
    let room = json |> member "room" |> to_string in
    let status_str = json |> member "status" |> to_string in
    let turns_json = json |> member "turns" |> to_list in
    let participants = json |> member "participants" |> to_list |> List.map to_string in
    let started_at = json |> member "started_at" |> to_float in
    let concluded_at = json |> member "concluded_at" |> to_float_option in
    let conclusion = json |> member "conclusion" |> to_string_option in
    let max_turns = json |> member "max_turns" |> to_int in
    let current_turn = json |> member "current_turn" |> to_int in
    let floor_holder = json |> member "floor_holder" |> to_string_option in
    let source_post_id = json |> member "source_post_id" |> to_string_option in

    match thread_status_of_string status_str with
    | Error e -> Error e
    | Ok status ->
        let turns_result =
          List.fold_left (fun acc j ->
            match acc with
            | Error _ -> acc
            | Ok lst ->
                match turn_of_yojson j with
                | Ok t -> Ok (lst @ [t])
                | Error e -> Error e
          ) (Ok []) turns_json
        in
        match turns_result with
        | Error e -> Error e
        | Ok turns ->
            Ok { id; topic; room; status; turns; participants; started_at;
                 concluded_at; conclusion; max_turns; current_turn; floor_holder; source_post_id }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Error (Printf.sprintf "Failed to parse thread: %s" (Printexc.to_string e))

(** {1 File I/O - Atomic writes} *)

(** Write JSON to file atomically (temp file + rename) *)
let write_json path json =
  let content = Yojson.Safe.pretty_to_string json in
  let dir = Filename.dirname path in
  let base = Filename.basename path in
  let tmp_path = Filename.concat dir (Printf.sprintf ".%s.tmp.%d" base (Unix.getpid ())) in
  let oc = open_out tmp_path in
  let closed = ref false in
  Fun.protect ~finally:(fun () ->
    if not !closed then (try close_out oc with Sys_error _ -> ());
    if Sys.file_exists tmp_path then
      try Sys.remove tmp_path with Sys_error _ -> ()
  ) (fun () ->
    output_string oc content;
    flush oc;
    close_out oc;
    closed := true;
    Sys.rename tmp_path path
  )

(** Read JSON from file *)
let read_json path =
  match read_file_safe path with
  | Ok content ->
      (match parse_json_safe content with
       | Ok json -> Some json
       | Error _ -> None)
  | Error _ -> None

(** {1 Thread State Helpers} *)

let can_reply (th : thread) : bool =
  th.status = Active && th.current_turn < th.max_turns

let last_turn (th : thread) : turn option =
  match List.rev th.turns with
  | [] -> None
  | t :: _ -> Some t

let count_turns_by (th : thread) ~speaker : int =
  List.length (List.filter (fun t -> t.speaker = speaker) th.turns)

(** {1 Core Operations} *)

let save_thread config (th : thread) : unit =
  ensure_dirs config;
  let path = thread_path config th.id in
  write_json path (thread_to_yojson th)

let start ~config ~topic ~initiator ?(max_turns = 50) ?(initial_content = "")
    ?(mentions : string list = []) ?source_post_id ()
    : (thread, string) result =
  ignore mentions;
  ensure_dirs config;
  let id = generate_thread_id () in
  let now = Time_compat.now () in

  (* Create initial turn if content provided *)
  let turns, current_turn =
    if String.length initial_content > 0 then
      (* Extract @mentions from initial_content using simple regex *)
      let mentions =
        try
          let re = Str.regexp "@\\([a-zA-Z0-9_-]+\\)" in
          let rec collect pos acc =
            try
              let _ = Str.search_forward re initial_content pos in
              let target = Str.matched_group 1 initial_content in
              let next_pos = Str.match_end () in
              collect next_pos (target :: acc)
            with Not_found -> List.rev acc
          in
          collect 0 []
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Printf.eprintf "[Council] mention extraction failed: %s\n%!"
            (Printexc.to_string exn);
          []
      in
      let turn = {
        id = generate_turn_id ~thread_id:id ~seq:0;
        seq = 0;
        speaker = initiator;
        content = initial_content;
        turn_type = Initiate;
        created_at = now;
        confidence = None;
        reply_to = None;
        mentions;
      } in
      ([turn], 1)
    else
      ([], 0)
  in

  let th : thread = {
    id;
    topic;
    room = config.room;
    status = Active;
    turns;
    participants = [initiator];
    started_at = now;
    concluded_at = None;
    conclusion = None;
    max_turns;
    current_turn;
    floor_holder = Some initiator;
    source_post_id;
  } in

  try
    save_thread config th;
    Ok th
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Error (Printf.sprintf "Failed to start thread: %s" (Printexc.to_string e))

let get ~config ~thread_id : thread option =
  let path = thread_path config thread_id in
  match read_json path with
  | Some json ->
      (match thread_of_yojson json with
       | Ok th -> Some th
       | Error _ -> None)
  | None -> None

let reply ~config ~thread_id ~speaker ~content
    ?(confidence : float option) ?(reply_to : string option) ?(mentions = []) ()
    : (thread, string) result =
  match get ~config ~thread_id with
  | None -> Error (Printf.sprintf "Thread not found: %s" thread_id)
  | Some th ->
      if not (can_reply th) then
        Error (Printf.sprintf "Cannot reply: thread %s is %s (turn %d/%d)"
          thread_id (thread_status_to_string th.status) th.current_turn th.max_turns)
      else begin
        let now = Time_compat.now () in
        let turn = {
          id = generate_turn_id ~thread_id ~seq:th.current_turn;
          seq = th.current_turn;
          speaker;
          content;
          turn_type = (if th.current_turn = 0 then Initiate else Respond);
          created_at = now;
          confidence;
          reply_to;
          mentions;
        } in

        let participants =
          if List.mem speaker th.participants then th.participants
          else th.participants @ [speaker]
        in

        let updated = {
          th with
          turns = th.turns @ [turn];
          participants;
          current_turn = th.current_turn + 1;
          floor_holder = Some speaker;
        } in

        try
          save_thread config updated;
          Ok updated
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | e ->
          Error (Printf.sprintf "Failed to save reply: %s" (Printexc.to_string e))
      end

let conclude ~config ~thread_id ~concluder ~conclusion () : (thread, string) result =
  match get ~config ~thread_id with
  | None -> Error (Printf.sprintf "Thread not found: %s" thread_id)
  | Some th ->
      if th.status <> Active then
        Error (Printf.sprintf "Cannot conclude: thread %s is already %s"
          thread_id (thread_status_to_string th.status))
      else begin
        let now = Time_compat.now () in

        (* Add concluding turn *)
        let turn = {
          id = generate_turn_id ~thread_id ~seq:th.current_turn;
          seq = th.current_turn;
          speaker = concluder;
          content = conclusion;
          turn_type = Conclude;
          created_at = now;
          confidence = None;
          reply_to = None;
          mentions = [];
        } in

        let participants =
          if List.mem concluder th.participants then th.participants
          else th.participants @ [concluder]
        in

        let updated = {
          th with
          turns = th.turns @ [turn];
          participants;
          current_turn = th.current_turn + 1;
          status = Concluded;
          concluded_at = Some now;
          conclusion = Some conclusion;
          floor_holder = None;
        } in

        try
          save_thread config updated;
          Ok updated
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | e ->
          Error (Printf.sprintf "Failed to conclude thread: %s" (Printexc.to_string e))
      end

let list_all ~config : thread list =
  ensure_dirs config;
  let dir = threads_dir config in
  match list_dir_safe dir with
  | Error _ -> []
  | Ok files ->
      files
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.filter_map (fun f ->
          let thread_id = Filename.chop_suffix f ".json" in
          get ~config ~thread_id)

(** BUG-018: 7-day TTL for conversations — threads older than 7 days are excluded *)
let list_active ~config : thread list =
  let now = Time_compat.now () in
  let ttl_7d = 7.0 *. 24.0 *. 3600.0 in
  list_all ~config
  |> List.filter (fun th ->
    th.status = Active && (now -. th.started_at) < ttl_7d)
