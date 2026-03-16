(** Lodge Memory — Agent experience recall & store

    Combines multiple memory sources:
    - Council thread (short-term, per-agent conversation history)
    - Memory Stream (scored retrieval, long-term)

    Self-contained: accesses Council.Conversation and Memory_stream directly
    to avoid circular dependency with Lodge_heartbeat.

    @since 3.0.0
*)

[@@@warning "-32"]

(** {1 Types} *)

type experience = {
  agent_name: string;
  action_type: string;        (** "post" | "comment" | "upvote" | "skip" *)
  content: string;
  context: string;            (** trigger/reason *)
  board_id: string option;
  timestamp: float;
}

(** {1 Utilities} *)

(** Resolve ME_ROOT consistently *)
let me_root () =
  Env_config.me_root ()

(** {1 Council Thread Access (direct, no Lodge_heartbeat dependency)} *)

let agent_thread_config () : Council.Conversation.config =
  { base_path = me_root (); room = "lodge" }

let find_agent_thread ~agent_name : Council.Conversation.thread option =
  let config = agent_thread_config () in
  let threads = Council.Conversation.list_active ~config in
  List.find_opt (fun (th : Council.Conversation.thread) ->
    String.length th.topic >= String.length agent_name &&
    String.sub th.topic 0 (String.length agent_name) = agent_name
  ) threads

let get_or_create_agent_thread ~agent_name : Council.Conversation.thread option =
  match find_agent_thread ~agent_name with
  | Some th -> Some th
  | None ->
      let config = agent_thread_config () in
      let topic = Printf.sprintf "%s 활동 기록" agent_name in
      match Council.Conversation.start ~config ~topic ~initiator:agent_name ~max_turns:100 () with
      | Ok th -> Some th
      | Error _ -> None

(** {1 Read — Recall memories for prompt context} *)

(** Recall from Council thread (short-term memory).
    Reads thread turns directly via Council.Conversation. *)
let recall_from_thread ~agent_name ~limit : (string * float) list =
  match find_agent_thread ~agent_name with
  | None -> []
  | Some thread ->
    let recent =
      thread.turns
      |> List.rev  (* Most recent first *)
      |> (fun lst ->
          let rec take n acc = function
            | [] -> List.rev acc
            | _ when n <= 0 -> List.rev acc
            | x :: xs -> take (n - 1) (x :: acc) xs
          in
          take limit [] lst)
      |> List.rev  (* Back to chronological order *)
    in
    let n = List.length recent in
    List.mapi (fun i (t : Council.Conversation.turn) ->
      let recency = float_of_int (i + 1) /. float_of_int (max n 1) in
      (String.trim t.content, 0.5 +. recency *. 0.3)  (* 0.5 - 0.8 range *)
    ) recent

(** Recall from Memory Stream (scored long-term memory). *)
let recall_from_stream ~agent_name ~query ~limit : (string * float) list =
  let entries = Memory_stream.retrieve ~agent_name ~query ~limit in
  List.map (fun (e : Memory_stream.memory_entry) ->
    (e.content, 0.4 +. float_of_int e.importance *. 0.06)  (* 0.4 - 1.0 range *)
  ) entries

(** Recall relevant memories for an agent.
    Combines thread + Memory Stream. Sorted by relevance. *)
let recall ~agent_name ~query ~limit =
  let thread_memories = recall_from_thread ~agent_name ~limit in
  let stream_memories = recall_from_stream ~agent_name ~query ~limit in
  let all = thread_memories @ stream_memories in
  (* Deduplicate by content prefix (first 50 chars) *)
  let seen = Hashtbl.create 16 in
  let deduped = List.filter (fun (content, _) ->
    let key = String.sub content 0 (min 50 (String.length content)) in
    if Hashtbl.mem seen key then false
    else (Hashtbl.add seen key (); true)
  ) all in
  (* Sort by relevance (descending), take top [limit] *)
  let sorted = List.sort (fun (_, s1) (_, s2) -> compare s2 s1) deduped in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: rest -> x :: take (n - 1) rest
  in
  take limit sorted

(** Format recalled memories for inclusion in LLM prompt *)
let format_for_prompt memories =
  if memories = [] then ""
  else
    let lines = List.map (fun (content, score) ->
      Printf.sprintf "- (%.1f) %s" score content
    ) memories in
    String.concat "\n" lines

(** {1 Write — Store new experiences} *)

(** Record experience to Council thread (short-term) *)
let store_to_thread (exp : experience) =
  match get_or_create_agent_thread ~agent_name:exp.agent_name with
  | None -> ()
  | Some thread ->
      let config = agent_thread_config () in
      let action_prefix = match exp.action_type with
        | "post" -> Printf.sprintf "[POST: %s] " exp.context
        | "comment" ->
            let target = Option.value ~default:"" exp.board_id in
            Printf.sprintf "[COMMENT on: %s] " (String.sub target 0 (min 30 (String.length target)))
        | "upvote" -> "[UPVOTE] "
        | _ -> "[SKIP] "
      in
      let full_content = action_prefix ^ exp.content in
      (try ignore (Council.Conversation.reply ~config ~thread_id:thread.id
                ~speaker:exp.agent_name ~content:full_content ())
       with exn -> Log.Lodge.error "council reply failed: %s" (Printexc.to_string exn))

(** Record experience to Memory Stream (scored long-term) *)
let store_to_stream (exp : experience) =
  let mem_type = match exp.action_type with
    | "post" -> Memory_stream.Action "post"
    | "comment" -> Memory_stream.Action "comment"
    | "upvote" -> Memory_stream.Action "upvote"
    | _ -> Memory_stream.Action "skip"
  in
  Memory_stream.add_memory ~agent_name:exp.agent_name ~content:exp.content ~importance:5 mem_type;
  Memory_stream.rotate_if_needed ~agent_name:exp.agent_name

(** Record an agent's experience to all memory stores *)
let store exp =
  (* Skip empty content (e.g. ActionSkip) for thread/stream to avoid noise *)
  if String.length exp.content > 0 then begin
    store_to_thread exp;
    store_to_stream exp
  end
