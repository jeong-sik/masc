(* The optional REST collector is independent of the Browser-based Slack TUI.
   Every fetched page is checkpointed before proceeding; completed windows
   publish into the existing bounded recent-message ring before high-water
   advances. See the interface for failure and restart semantics. *)

module Rest = Slack_rest_client
module Lane = Slack_lane

let error_to_string (e : Rest.error) : string =
  Format.asprintf "%a" Rest.pp_error e

let default_poll_interval_sec = 900

(* One cycle on a busy channel rarely exceeds a page; the bound exists so a
   burst after downtime cannot pin the fiber to one channel forever. *)
let max_pages_per_cycle = 4

(* ── configuration ─────────────────────────────────────────────── *)

type poll_config = { interval_sec : float }

type poll_config_load =
  | Poll_disabled
  | Poll_enabled of poll_config

type poll_config_error =
  | Runtime_toml_unreadable of { path : string; detail : string }
  | Runtime_toml_invalid of { path : string; detail : string }
  | Poll_enabled_not_bool of { path : string; expected : string; message : string }
  | Poll_interval_invalid of { path : string; detail : string }

let poll_config_error_to_string = function
  | Runtime_toml_unreadable { path; detail } ->
    Printf.sprintf "cannot read %s: %s" path detail
  | Runtime_toml_invalid { path; detail } ->
    Printf.sprintf "invalid TOML in %s: %s" path detail
  | Poll_enabled_not_bool { path; expected; message } ->
    Printf.sprintf "slack.poll_enabled in %s expected %s: %s" path expected message
  | Poll_interval_invalid { path; detail } ->
    Printf.sprintf "invalid slack.poll_interval_sec in %s: %s" path detail
;;

(* A present-but-invalid value is a typed error, never a silent default —
   the same fail-closed stance [load_trigger_policy_from_toml] applies to
   the sibling gateway knob. The TOML plane is resolved one step per
   function so the nesting stays flat. *)
let poll_interval_of_toml ~path ~toml : (poll_config, poll_config_error) result =
  match
    Field_resolution.resolve_int toml [ "slack"; "poll_interval_sec" ]
  with
  | Field_resolution.Missing ->
    Ok { interval_sec = float default_poll_interval_sec }
  | Field_resolution.Type_mismatch { expected; message } ->
    Error
      (Poll_interval_invalid
         { path; detail = Printf.sprintf "expected %s: %s" expected message })
  | Field_resolution.Present n when n >= 60 -> Ok { interval_sec = float n }
  | Field_resolution.Present n ->
    Error
      (Poll_interval_invalid
         { path
         ; detail = Printf.sprintf "must be an int >= 60 seconds, got %d" n
         })
;;

let poll_config_of_toml ~path ~toml : (poll_config_load, poll_config_error) result =
  match
    Field_resolution.resolve_bool toml [ "slack"; "poll_enabled" ]
  with
  | Field_resolution.Missing -> Ok Poll_disabled
  | Field_resolution.Type_mismatch { expected; message } ->
    Error (Poll_enabled_not_bool { path; expected; message })
  | Field_resolution.Present false -> Ok Poll_disabled
  | Field_resolution.Present true ->
    (match poll_interval_of_toml ~path ~toml with
     | Ok config -> Ok (Poll_enabled config)
     | Error error -> Error error)
;;

let load_poll_config ~path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Poll_disabled
  | exception Unix.Unix_error (code, _, _) ->
    Error (Runtime_toml_unreadable { path; detail = Unix.error_message code })
  | _ ->
    (match Safe_ops.read_file_safe path with
     | Error detail -> Error (Runtime_toml_unreadable { path; detail })
     | Ok content ->
       (match Otoml.Parser.from_string_result content with
        | Error detail -> Error (Runtime_toml_invalid { path; detail })
        | Ok toml -> poll_config_of_toml ~path ~toml))
;;

(* Slack's documented time pagination keeps the lower bound fixed and moves
   latest to the final message's ts. Unlike opaque cursors these boundaries
   remain usable across poll intervals and server restarts. *)
let ( let* ) = Result.bind

type window = {
  oldest : string;
  upper : string;
  before : string;
  newest : string option;
  messages : Rest.history_message list;
}
type checkpoint =
  | Idle of string
  | Scanning of window
  | Ready of { oldest : string; high_water : string; messages : Rest.history_message list }

let high_water = function
  | Idle ts -> ts | Scanning window -> window.oldest | Ready ready -> ready.oldest

let timestamp ts =
  let digits s = s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s in
  match String.split_on_char '.' ts with
  | [seconds; fraction] when digits seconds && digits fraction && String.length fraction = 6 ->
    (match Int64.of_string_opt seconds, Int64.of_string_opt fraction with
     | Some seconds, Some fraction
       when seconds <= Int64.div (Int64.sub Int64.max_int fraction) 1_000_000L ->
       Ok (Int64.add (Int64.mul seconds 1_000_000L) fraction)
     | _ -> Error "Slack timestamp is outside the supported range")
  | _ -> Error "Slack timestamp must contain seconds and six fractional digits"

let field key fields = match List.assoc_opt key fields with
  | Some value -> Ok value | None -> Error ("checkpoint lacks " ^ key)
let string = function `String value -> Ok value | _ -> Error "checkpoint string expected"
let ts_field key fields = let* json = field key fields in let* ts = string json in
  let* _ = timestamp ts in Ok ts
let optional_string = function `Null -> Ok None | `String value -> Ok (Some value)
  | _ -> Error "checkpoint optional string expected"
let rec traverse f = function
  | [] -> Ok [] | value :: rest -> let* value = f value in
    let* rest = traverse f rest in Ok (value :: rest)
let message_json (m : Rest.history_message) =
  let optional value = match value with None -> `Null | Some value -> `String value in
  `Assoc ["ts", `String m.ts; "text", `String m.text; "user", optional m.user_id;
    "bot", optional m.bot_id; "subtype", optional m.subtype; "thread", optional m.thread_ts]
let decode_message = function
  | `Assoc fields ->
    let* ts = ts_field "ts" fields in
    let* text = Result.bind (field "text" fields) string in
    let optional key = Result.bind (field key fields) optional_string in
    let* user_id = optional "user" in let* bot_id = optional "bot" in
    let* subtype = optional "subtype" in let* thread_ts = optional "thread" in
    Ok { Rest.ts; text; user_id; bot_id; subtype; thread_ts }
  | _ -> Error "checkpoint message object expected"
let messages_field fields =
  let* json = field "messages" fields in match json with
  | `List messages -> traverse decode_message messages
  | _ -> Error "checkpoint messages array expected"
let buffer_extents ~oldest messages =
  let* low = timestamp oldest in
  let rec loop previous first = function
    | [] -> Ok (first, previous)
    | (message : Rest.history_message) :: rest ->
      let* current = timestamp message.ts in
      if current <= previous then Error "checkpoint messages are not strictly chronological"
      else loop current (match first with None -> Some current | Some _ -> first) rest
  in loop low None messages

let encode = function
  | Idle high_water -> `Assoc ["kind", `String "idle"; "high_water", `String high_water]
  | Scanning window -> `Assoc ["kind", `String "scanning"; "oldest", `String window.oldest;
      "upper", `String window.upper; "before", `String window.before;
      "newest", (match window.newest with None -> `Null | Some ts -> `String ts);
      "messages", `List (List.map message_json window.messages)]
  | Ready ready -> `Assoc ["kind", `String "ready"; "oldest", `String ready.oldest;
      "high_water", `String ready.high_water;
      "messages", `List (List.map message_json ready.messages)]
let decode = function
  | `Assoc fields ->
    let* kind = field "kind" fields in
    (match kind with
     | `String "idle" -> let* ts = ts_field "high_water" fields in Ok (Idle ts)
     | `String "scanning" ->
       let* oldest = ts_field "oldest" fields in let* upper = ts_field "upper" fields in
       let* before = ts_field "before" fields in
       let* newest = Result.bind (field "newest" fields) optional_string in
       let* () = match newest with None -> Ok () | Some ts -> Result.map (fun _ -> ()) (timestamp ts) in
       let* messages = messages_field fields in
       let* low = timestamp oldest in let* high = timestamp upper in let* next = timestamp before in
       let* first, last = buffer_extents ~oldest messages in
       let* staged = match newest with None -> Ok None | Some ts -> Result.map Option.some (timestamp ts) in
       let consistent = match first, staged with
         | None, None -> next = high
         | Some first, Some newest -> next = first && newest = last && last < high
         | None, Some _ | Some _, None -> false in
       if low < next && next <= high && consistent
       then Ok (Scanning {oldest; upper; before; newest; messages})
       else Error "checkpoint window bounds or staged messages are inconsistent"
     | `String "ready" ->
       let* oldest = ts_field "oldest" fields in let* high_water = ts_field "high_water" fields in
       let* messages = messages_field fields in
       let* low = timestamp oldest in let* high = timestamp high_water in
       let* _, last = buffer_extents ~oldest messages in
       if low <= high && last = high then Ok (Ready {oldest; high_water; messages})
       else Error "checkpoint high-water does not match its completed messages"
     | _ -> Error "unknown Slack checkpoint kind")
  | _ -> Error "Slack checkpoint must be an object"

let cursor_path ~base_dir = Filename.concat base_dir ".gate/runtime/slack/poll-cursor.json"
let read_checkpoints ~path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
  | exception Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)
  | _ ->
    let* content = Safe_ops.read_file_safe path in
    match Yojson.Safe.from_string content with
    | exception Yojson.Json_error detail -> Error detail
    | `Assoc fields ->
      if List.length (List.sort_uniq String.compare (List.map fst fields)) <> List.length fields
      then Error "duplicate Slack channel checkpoint"
      else traverse (fun (channel, json) -> let* state = decode json in Ok (channel, state)) fields
    | _ -> Error "Slack checkpoint store must be an object"
let write_checkpoints ~path checkpoints =
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file_atomic_strict path
    (Yojson.Safe.to_string (`Assoc (List.map (fun (channel, state) -> channel, encode state) checkpoints)))

let next_page window (page : Rest.conversations_history_ok) =
  let* oldest = timestamp window.oldest in
  let* before = timestamp window.before in
  let rec validate previous = function
    | [] -> Ok ()
    | (message : Rest.history_message) :: rest ->
      let* ts = timestamp message.ts in
      if oldest < ts && ts < previous then validate ts rest
      else Error "Slack page is not descending within the requested time window"
  in
  let* () = validate before page.messages in
  let newest = match window.newest, page.messages with
    | Some ts, _ -> Some ts | None, message :: _ -> Some message.Rest.ts | None, [] -> None in
  let messages = List.rev_append page.messages window.messages in
  if page.has_more || Option.is_some page.next_cursor then
    match List.rev page.messages with
    | [] -> Error "Slack promised another page without a timestamp boundary"
    | last :: _ -> Ok (Scanning {window with before = last.Rest.ts; newest; messages})
  else
    Ok (Ready {oldest = window.oldest;
      high_water = Option.value ~default:window.oldest newest; messages})

type collect_error = Fetch_failed of string | Checkpoint_failed of string | Page_invalid of string

let collect ~now ~cursor ~fetch ~save ~publish =
  let save state = Result.map_error (fun detail -> Checkpoint_failed detail) (save state) in
  let parse result = Result.map_error (fun detail -> Page_invalid detail) result in
  let rec run pages_left = function
    | Ready ready ->
      (* A failed publish or idle checkpoint leaves Ready durable for replay.
         Slack_lane dedupes ts; its capacity remains recent-view retention. *)
      publish ready.messages;
      save (Idle ready.high_water)
    | Scanning _ when pages_left = 0 -> Ok ()
    | Scanning window ->
      let* page = fetch ~oldest:window.oldest ~latest:window.before
        |> Result.map_error (fun detail -> Fetch_failed detail) in
      let* next = parse (next_page window page) in
      let* () = save next in
      run (pages_left - 1) next
    | Idle oldest ->
      let upper = Printf.sprintf "%.6f" now in
      let* low = parse (timestamp oldest) in let* high = parse (timestamp upper) in
      if high <= low then Ok ()
      else
        let pending = Scanning {oldest; upper; before = upper; newest = None; messages = []} in
        let* () = save pending in
        run pages_left pending
  in
  match cursor with
  | None -> save (Idle (Printf.sprintf "%.6f" now))
  | Some state -> run max_pages_per_cycle state

(* ── filtering ─────────────────────────────────────────────────── *)
(* Collect plain human-authored messages. Mentions stay on the socket path —
   app_mention is the subscribed event, and re-collecting a mention here
   would double it. *)

let text_contains needle haystack =
  let len = String.length needle in
  let hay_len = String.length haystack in
  let rec loop i =
    if i + len > hay_len then false
    else if String.sub haystack i len = needle then true
    else loop (i + 1)
  in
  loop 0
;;

let pollable ~bot_user_id (m : Rest.history_message) : bool =
  m.Rest.subtype = None
  && m.Rest.bot_id = None
  && (match m.Rest.user_id with Some _ -> true | None -> false)
  &&
  (match bot_user_id with
   | Some bot ->
     (* No trailing ">": the legacy rendered form [<@id|label>] shares the
        [<@id] prefix and must be excluded the same as [<@id>]. *)
     not (text_contains ("<@" ^ bot) m.Rest.text)
   | None -> true)
;;

(* Each page commits before the next fetch. A failed checkpoint write ends
   this cycle, so an uncertain disk state is reread before any further change. *)
let poll_cycle ~clock ~token ~bot_user_id ~base_dir ~capacity () =
  let path = cursor_path ~base_dir in
  let result =
    let* bindings = Channel_gate_slack_state.read_bindings_result ()
      |> Result.map_error Channel_gate_binding_store.binding_store_error_to_string in
    let* checkpoints = read_checkpoints ~path in
    let committed = ref checkpoints in
    let rec channels = function
      | [] -> Ok ()
      | (binding : Channel_gate_binding_store.binding) :: rest ->
        let channel_id = binding.Channel_gate_binding_store.channel_id in
        let save state =
          let next = (channel_id, state) :: List.remove_assoc channel_id !committed in
          let* () = write_checkpoints ~path next in
          committed := next;
          Ok () in
        let fetch ~oldest ~latest =
          Rest.conversations_history ~clock ~token ~channel_id ~oldest ~latest ()
          |> Result.map_error error_to_string in
        let publish messages =
          let kept = List.filter (pollable ~bot_user_id) messages in
          List.iter (fun (message : Rest.history_message) ->
            match message.user_id with
            | None -> ()
            | Some user_id -> Lane.push ~channel_id ~capacity
                { Lane.channel_id; ts=message.ts; user_id; text=message.text;
                  received_unix=Unix.gettimeofday () }) kept;
          Log.Server.info "slack-lane: channel %s completed window, published %d message(s) (recent buffer capacity %d)"
            channel_id (List.length kept) capacity in
        (match collect ~now:(Unix.gettimeofday ())
          ~cursor:(List.assoc_opt channel_id !committed) ~fetch ~save ~publish with
         | Ok () -> channels rest
         | Error (Checkpoint_failed detail) -> Error ("channel " ^ channel_id ^ ": " ^ detail)
         | Error (Fetch_failed detail | Page_invalid detail) ->
           Log.Server.warn "slack-lane: channel %s held for replay: %s" channel_id detail;
           channels rest)
    in channels bindings
  in
  match result with
  | Ok () -> ()
  | Error detail -> Log.Server.warn "slack-lane: cycle stopped; durable checkpoint held for replay: %s" detail
;;

module For_testing = struct
  let pollable = pollable
  type nonrec checkpoint = checkpoint
  type nonrec collect_error = collect_error =
    Fetch_failed of string | Checkpoint_failed of string | Page_invalid of string
  let idle ts = Idle ts
  let high_water = high_water
  let encode = encode
  let decode = decode
  let read_checkpoints = read_checkpoints
  let collect = collect
end

(* ── start ─────────────────────────────────────────────────────── *)

let start ~sw ~env ~state =
  match Env_config_slack.bot_token_opt () with
  | None ->
    Log.Server.warn
      "slack-lane: SLACK_BOT_TOKEN is unset; poll lane not started"
  | Some token -> (
    let resolution = Config_dir_resolver.resolve () in
    let toml_path =
      Filename.concat resolution.Config_dir_resolver.config_root.path
        Config_dir_resolver.runtime_toml_filename
    in
    match load_poll_config ~path:toml_path with
    | Error error ->
      Log.Server.error
        "slack-lane: poll configuration rejected; lane not started (%s)"
        (poll_config_error_to_string error)
    | Ok Poll_disabled ->
      Log.Server.info
        "slack-lane: poll disabled (slack.poll_enabled absent or false)"
    | Ok (Poll_enabled config) ->
      let clock = Eio.Stdenv.clock env in
      let base_dir = (Mcp_server.workspace_config state).base_path in
      (* Without the bot identity the mention filter is unenforceable, and
         collecting mentions here doubles them against the socket path.
         Fail closed: the lane does not start. *)
      (match Rest.auth_test ~clock ~token () with
       | Error e ->
         Log.Server.error
           "slack-lane: auth.test failed, poll lane not started (%s)"
           (error_to_string e)
       | Ok { Rest.user_id; _ } ->
        let bot_user_id = Some user_id in
        Log.Server.info
          "slack-lane: starting poll fiber (interval %.0fs, capacity %d/channel)"
          config.interval_sec Lane.default_capacity_per_channel;
        Eio.Fiber.fork ~sw (fun () ->
            try
              let rec loop () =
                (try
                   poll_cycle ~clock ~token ~bot_user_id ~base_dir
                     ~capacity:Lane.default_capacity_per_channel ()
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                   Log.Server.error "slack-lane: poll cycle crashed: %s"
                     (Printexc.to_string exn));
                Eio.Time.sleep clock config.interval_sec;
                loop ()
              in
              loop ()
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              Log.Server.error "slack-lane: poll fiber crashed: %s"
                (Printexc.to_string exn))))
;;
