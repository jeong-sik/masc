(** Debate - Multi-agent structured debate system for MASC

    Implements topic-based debates with positions (Support/Oppose/Neutral).
    Storage is file-based under .masc/debates/
*)

(** {1 Types} *)

type position = Support | Oppose | Neutral

type context_ref = {
  board_post_id: string option;
  task_id: string option;
  operation_id: string option;
  team_session_id: string option;
}

type argument = {
  agent: string;
  position: position;
  content: string;
  evidence: string list;
  reply_to: int option;  (** Index of argument this is replying to *)
  mentions: string list; (** Agents mentioned/addressed *)
  archetype: string option; (** MAGI archetype: melchior/balthasar/casper/athena *)
  created_at: float option;
}

type debate_status = Open | Closed | Pending

type debate = {
  id: string;
  topic: string;
  status: debate_status;
  arguments: argument list;
  context: context_ref;
  created_at: float;
  closed_at: float option;
}

(** {1 Helper Functions} *)

let read_file_safe path =
  try Ok (Fs_compat.load_file path)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

let parse_json_safe ~context:_ content =
  try Ok (Yojson.Safe.from_string content)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

let list_dir_safe dir =
  try Ok (Array.to_list (Sys.readdir dir))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** {1 ID Generation} *)

let generate_debate_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFFF in
  Printf.sprintf "debate-%d-%06x" ts hash

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

let empty_context_ref =
  {
    board_post_id = None;
    task_id = None;
    operation_id = None;
    team_session_id = None;
  }

let context_ref_to_yojson (ctx : context_ref) =
  let fields =
    [
      ("board_post_id", ctx.board_post_id);
      ("task_id", ctx.task_id);
      ("operation_id", ctx.operation_id);
      ("team_session_id", ctx.team_session_id);
    ]
    |> List.filter_map (fun (key, value) ->
           match value with
           | Some text when String.trim text <> "" -> Some (key, `String (String.trim text))
           | _ -> None)
  in
  `Assoc fields

let context_ref_of_yojson json =
  let open Yojson.Safe.Util in
  let get_opt key =
    match json |> member key with
    | `String value ->
        let trimmed = String.trim value in
        if trimmed = "" then None else Some trimmed
    | _ -> None
  in
  {
    board_post_id = get_opt "board_post_id";
    task_id = get_opt "task_id";
    operation_id = get_opt "operation_id";
    team_session_id = get_opt "team_session_id";
  }

let argument_to_yojson (a : argument) : Yojson.Safe.t =
  let base = [
    ("agent", `String a.agent);
    ("position", `String (position_to_string a.position));
    ("content", `String a.content);
    ("evidence", `List (List.map (fun e -> `String e) a.evidence));
    ("mentions", `List (List.map (fun m -> `String m) a.mentions));
  ] in
  let with_reply = match a.reply_to with
    | None -> base
    | Some idx -> ("reply_to", `Int idx) :: base
  in
  let with_archetype = match a.archetype with
    | None -> with_reply
    | Some arch -> ("archetype", `String arch) :: with_reply
  in
  let with_timestamp = match a.created_at with
    | Some ts -> ("created_at", `Float ts) :: with_archetype
    | None -> with_archetype
  in
  `Assoc with_timestamp

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
        let reply_to = match json |> member "reply_to" with
          | `Int i -> Some i
          | _ -> None
        in
        let mentions = match json |> member "mentions" with
          | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
          | _ -> []
        in
        let archetype = match json |> member "archetype" with
          | `String s -> Some s
          | _ -> None
        in
        let created_at = match json |> member "created_at" with
          | `Float ts -> Some ts
          | `Int ts -> Some (float_of_int ts)
          | _ -> None
        in
        Ok { agent; position; content; evidence; reply_to; mentions; archetype; created_at }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printf.sprintf "Failed to parse argument: %s" (Printexc.to_string e))

let debate_to_yojson (d : debate) : Yojson.Safe.t =
  let base =
    [
      ("id", `String d.id);
      ("topic", `String d.topic);
      ("status", `String (status_to_string d.status));
      ("arguments", `List (List.map argument_to_yojson d.arguments));
      ("created_at", `Float d.created_at);
    ]
  in
  let with_context =
    match context_ref_to_yojson d.context with
    | `Assoc [] -> base
    | json -> ("context", json) :: base
  in
  let with_closed_at =
    match d.closed_at with
    | Some ts -> ("closed_at", `Float ts) :: with_context
    | None -> with_context
  in
  `Assoc with_closed_at

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
             let context =
               match json |> member "context" with
               | `Assoc _ as ctx -> context_ref_of_yojson ctx
               | _ -> empty_context_ref
             in
             let closed_at = match json |> member "closed_at" with
               | `Float ts -> Some ts
               | `Int ts -> Some (float_of_int ts)
               | _ -> None
             in
             Ok { id; topic; status; arguments; context; created_at; closed_at })
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printf.sprintf "Failed to parse debate: %s" (Printexc.to_string e))

(** {1 Storage Operations} *)

let masc_dir _config =
  Sys.getcwd () ^ "/.masc"

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
  match
    Fs_compat.save_file tmp_path content;
    Sys.rename tmp_path path
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as e) ->
      (try Sys.remove tmp_path with Sys_error _ -> ());
      raise e
  | exception exn ->
      (try Sys.remove tmp_path with Sys_error _ -> ());
      raise exn

(** Read JSON from file *)
let read_json path =
  match read_file_safe path with
  | Ok content ->
      (match parse_json_safe ~context:path content with
       | Ok json -> Some json
       | Error _ -> None)
  | Error _ -> None

(** {1 Debate Operations} *)

(** Start a new debate on a topic.
    Notifies relevant agents via the notify callback. *)
let start_debate config ~topic ?(context = empty_context_ref) ?(notify_agents=[]) ~notify_fn ()
    : (debate, string) result =
  ensure_dirs config;
  let id = generate_debate_id () in
  let debate : debate = {
    id;
    topic;
    status = Open;
    arguments = [];
    context;
    created_at = Time_compat.now ();
    closed_at = None;
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
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printf.sprintf "Failed to start debate: %s" (Printexc.to_string e))

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
let add_argument config ~debate_id ~agent ~position ~content 
    ?(evidence=[]) ?(reply_to=None) ?(mentions=[]) ?(archetype=None) ?(notify_fn=None) () 
    : (debate, string) result =
  match get_debate config ~debate_id with
  | Error e -> Error e
  | Ok debate ->
      if debate.status <> Open then
        Error (Printf.sprintf "Cannot add argument: debate %s is not open" debate_id)
      else begin
        let arg : argument =
          {
            agent;
            position;
            content;
            evidence;
            reply_to;
            mentions;
            archetype;
            created_at = Some (Time_compat.now ());
          }
        in
        let arg_idx = List.length debate.arguments in
        let updated = { debate with arguments = debate.arguments @ [arg] } in
        try
          save_debate config updated;
          (* Notify mentioned agents and reply target *)
          (match notify_fn with
           | None -> ()
           | Some fn ->
             (* Notify agents mentioned *)
             List.iter (fun mentioned ->
               let msg = Printf.sprintf "@%s mentioned you in debate [%s]: %s" 
                 agent debate_id (String.sub content 0 (min 50 (String.length content))) in
               fn ~agent:mentioned ~message:msg
             ) mentions;
             (* Notify agent being replied to *)
             (match reply_to with
              | None -> ()
              | Some idx when idx < List.length debate.arguments ->
                let target_arg = List.nth debate.arguments idx in
                let msg = Printf.sprintf "@%s replied to your argument (#%d) in debate [%s]" 
                  agent idx debate_id in
                fn ~agent:target_arg.agent ~message:msg
              | Some _ -> ()));
          (* Return with arg index for reference *)
          Log.Misc.info "Debate: argument #%d added by %s" arg_idx agent;
          Ok updated
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | e -> Error (Printf.sprintf "Failed to add argument: %s" (Printexc.to_string e))
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
        let updated = { debate with status = Closed; closed_at = Some (Time_compat.now ()) } in
        try
          save_debate config updated;
          Ok updated
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | e -> Error (Printf.sprintf "Failed to close debate: %s" (Printexc.to_string e))
      end

(** List all debates *)
let list_debates config ?(status_filter=None) ?(limit=50) () : debate list =
  ensure_dirs config;
  let dir = debates_dir config in
  match list_dir_safe dir with
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
