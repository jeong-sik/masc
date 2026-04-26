(** Mention_inbox — JSONL-based persistent mention inbox

    Stores @mention events in `.masc/mention_inbox.jsonl`.
    Each mention is an append-only record with read/unread tracking.

    @since Phase 3A — Keeper Deliberation Engine
*)

type mention_record =
  { id : string
  ; target_agent : string
  ; source_agent : string
  ; source_kind : string
  ; source_id : string
  ; content_preview : string
  ; created_at : float
  ; read_at : float
  }

(** {1 ID Generation} *)

(* RNG for mention-id generation.  [Random.State.t] is NOT fiber-safe —
   the previous doc comment claiming otherwise was incorrect.  Guard
   the shared state with an [Eio.Mutex] and route every RNG access
   through [with_mention_rng].  Same discipline as [Lib.A2a_tools]
   ([a2a_rng] / [a2a_rng_mutex]). *)
let mention_rng = Random.State.make_self_init ()
let mention_rng_mutex = Eio.Mutex.create ()
let with_mention_rng f = Eio.Mutex.use_ro mention_rng_mutex (fun () -> f mention_rng)

let generate_mention_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let rand = with_mention_rng (fun rng -> Random.State.int rng 10000) in
  Printf.sprintf "m-%d-%04d" ts rand
;;

(** {1 JSON Serialization} *)

let mention_record_to_json (r : mention_record) : Yojson.Safe.t =
  `Assoc
    [ "id", `String r.id
    ; "target_agent", `String r.target_agent
    ; "source_agent", `String r.source_agent
    ; "source_kind", `String r.source_kind
    ; "source_id", `String r.source_id
    ; "content_preview", `String r.content_preview
    ; "created_at", `Float r.created_at
    ; "read_at", `Float r.read_at
    ]
;;

let mention_record_of_json (json : Yojson.Safe.t) : mention_record option =
  try
    let id = Safe_ops.json_string ~default:"" "id" json in
    let target_agent = Safe_ops.json_string ~default:"" "target_agent" json in
    let source_agent = Safe_ops.json_string ~default:"" "source_agent" json in
    let source_kind = Safe_ops.json_string ~default:"" "source_kind" json in
    let source_id = Safe_ops.json_string ~default:"" "source_id" json in
    let content_preview = Safe_ops.json_string ~default:"" "content_preview" json in
    let created_at = Safe_ops.json_float ~default:0.0 "created_at" json in
    let read_at = Safe_ops.json_float ~default:0.0 "read_at" json in
    if id = "" || target_agent = ""
    then None
    else
      Some
        { id
        ; target_agent
        ; source_agent
        ; source_kind
        ; source_id
        ; content_preview
        ; created_at
        ; read_at
        }
  with
  | Yojson.Safe.Util.Type_error _ -> None
  | exn ->
    Log.Mention.warn "mention_record_of_json unexpected: %s" (Printexc.to_string exn);
    None
;;

(** {1 Path Resolution} *)

let inbox_path (config : Coord.config) : string =
  Filename.concat (Coord.masc_dir config) "mention_inbox.jsonl"
;;

(** {1 JSONL I/O} *)

let append_mention (config : Coord.config) (record : mention_record) : unit =
  let path = inbox_path config in
  let json = mention_record_to_json record in
  Fs_compat.append_jsonl path json
;;

let load_all_mentions (config : Coord.config) : mention_record list =
  let path = inbox_path config in
  if not (Sys.file_exists path)
  then []
  else (
    match Safe_ops.read_file_safe path with
    | Error _ -> []
    | Ok content ->
      String.split_on_char '\n' content
      |> List.filter (fun line -> String.length (String.trim line) > 0)
      |> List.filter_map (fun line ->
        try
          let json = Yojson.Safe.from_string line in
          mention_record_of_json json
        with
        | Yojson.Json_error _ -> None))
;;

let read_mentions (config : Coord.config) ~(target_agent : string) ~(limit : int)
  : mention_record list
  =
  load_all_mentions config
  |> List.filter (fun r -> r.target_agent = target_agent)
  |> List.sort (fun a b -> compare b.created_at a.created_at)
  |> fun xs ->
  let rec take n acc = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | x :: rest -> take (n - 1) (x :: acc) rest
  in
  take limit [] xs
;;

let unread_count (config : Coord.config) ~(target_agent : string) : int =
  load_all_mentions config
  |> List.filter (fun r -> r.target_agent = target_agent && r.read_at = 0.0)
  |> List.length
;;

let mark_read (config : Coord.config) ~(mention_id : string) : unit =
  let path = inbox_path config in
  let all = load_all_mentions config in
  let now = Time_compat.now () in
  let updated =
    List.map
      (fun r ->
         if r.id = mention_id && r.read_at = 0.0 then { r with read_at = now } else r)
      all
  in
  (* Rewrite entire file with updated records *)
  let content =
    updated
    |> List.map (fun r -> Yojson.Safe.to_string (mention_record_to_json r))
    |> String.concat "\n"
  in
  let content = if content = "" then "" else content ^ "\n" in
  Fs_compat.save_file path content
;;
