(* See .mli for the high-level shape.

   docs/design/slack-lane.md, task-1418 — the in-process collection lane.
   The app's Event Subscriptions carry no message.channels/message.groups,
   so Socket Mode pushes mentions only; the REST read below needs only
   scopes the bot token already has. What the fiber collects is exactly
   what the bridge poller (jeong-sik/me#1291) proved: plain human-authored
   top-level messages of bound channels, deduped on ts, cursor advancing
   only over messages actually seen. *)

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

(* ── cursor ────────────────────────────────────────────────────── *)
(* { "C…": "1788708947.825569", … } — channel_id → last ts seen.
   Slack ts are fixed-point strings; six fractional digits is the format
   the API round-trips, and comparing them lexicographically preserves
   order, so the cursor never reparses to a float. *)

let cursor_path ~base_dir =
  Filename.concat base_dir ".gate/runtime/slack/poll-cursor.json"

(* An unreadable or corrupt cursor resets every channel to now, skipping
   whatever the old cursor still owed — that loss is real, so it is loud.
   The sibling iMessage cursor holds the same stance. *)
let read_cursors ~path : (string * string) list =
  match Safe_ops.read_file_safe path with
  | Error detail ->
    Log.Server.warn
      "slack-lane: cursor unreadable (%s): %s — every channel restarts from        now and the uncollected window is lost"
      path detail;
    []
  | Ok content ->
    (match Yojson.Safe.from_string content with
     | exception Yojson.Json_error detail ->
       Log.Server.warn
         "slack-lane: cursor corrupt (%s): %s — every channel restarts from           now and the uncollected window is lost"
         path detail;
       []
     | `Assoc fields ->
       List.filter_map
         (fun (channel_id, value) ->
           match value with
           | `String ts when String.trim ts <> "" -> Some (channel_id, ts)
           | _ -> None)
         fields
     | other ->
       Log.Server.warn
         "slack-lane: cursor has an unexpected shape (%s): %s — treating as         empty"
         path (Yojson.Safe.to_string other);
       [])
;;

let write_cursors ~path (cursors : (string * string) list) =
  let dir = Filename.dirname path in
  Fs_compat.mkdir_p dir;
  let json =
    `Assoc (List.map (fun (channel_id, ts) -> (channel_id, `String ts)) cursors)
  in
  (match Fs_compat.save_file_atomic path (Yojson.Safe.to_string json) with
   | Error detail ->
     Log.Server.warn "slack-lane: cursor write failed (%s): %s" path detail
   | Ok () -> ())
;;

(* ── filtering ─────────────────────────────────────────────────── *)
(* The bridge poller's contract, stated once more: only plain
   human-authored top-level messages. Mentions stay on the socket path —
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

(* ── one channel, one cycle ────────────────────────────────────── *)

(* A fresh channel starts its cursor at "now" rather than backfilling —
   the same stance as the bridge poller. *)
let six_digit_ts now = Printf.sprintf "%.6f" now
;;

type channel_cycle =
  | Initialized (* first sight: cursor starts now, nothing collected *)
  | Collected of { new_messages : int; advance_ts : string }
  | Nothing_new
  | Fetch_failed of string

(* [truncated] is true when pagination stopped at the page cap (or Slack
   promised more without a cursor) — the window below what was fetched is
   still unseen. The caller must not advance past it blindly. *)
let fetch_pages ~clock ~token ~channel_id ~oldest :
    ((Rest.history_message list * bool), Rest.error) result =
  let rec go ~pages_left ~cursor ~acc =
    if pages_left = 0 then Ok (List.rev acc, true)
    else
      match
        Rest.conversations_history ~clock ~token ~channel_id ~oldest ?cursor ()
      with
      | Error e -> Error e
      | Ok page ->
        let acc = page.Rest.messages @ acc in
        if page.Rest.has_more && page.Rest.next_cursor <> None then
          go ~pages_left:(pages_left - 1) ~cursor:page.Rest.next_cursor ~acc
        else if page.Rest.has_more then Ok (List.rev acc, true)
        else Ok (List.rev acc, false)
  in
  go ~pages_left:max_pages_per_cycle ~cursor:None ~acc:[]
;;

(* The cursor advances to the OLDEST ts actually fetched: everything above
   it was fetched contiguously, and anything below (a truncated backlog)
   stays reachable for the next cycle. Advancing to the newest would
   permanently skip pages the cap never reached. Messages arrive
   newest-first. *)
let cursor_advance_of (messages : Rest.history_message list) : string option
  =
  match List.rev messages with
  | [] -> None
  | oldest :: _ -> Some oldest.Rest.ts
;;

let poll_channel ~clock ~token ~bot_user_id ~now ~capacity ~channel_id
    ~cursor_opt : channel_cycle * string option =
  match cursor_opt with
  | None -> (Initialized, Some (six_digit_ts now))
  | Some oldest -> (
    match fetch_pages ~clock ~token ~channel_id ~oldest with
    | Error e -> (Fetch_failed (error_to_string e), None)
    | Ok (messages, truncated) ->
      let () =
        if truncated then
          Log.Server.warn
            "slack-lane: channel %s window exceeded %d pages; collecting              the newest part, the rest follows next cycle"
            channel_id max_pages_per_cycle
      in
      let kept =
        List.filter (fun m -> pollable ~bot_user_id m) messages
      in
      let push_one (m : Rest.history_message) =
        Lane.push
          ~channel_id
          {
            Lane.channel_id
            ; ts = m.Rest.ts
            ; user_id =
              (match m.Rest.user_id with Some u -> u | None -> "")
            ; text = m.Rest.text
            ; received_unix = now
          }
          ~capacity
      in
      List.iter push_one kept;
      (match cursor_advance_of messages with
       | Some advance ->
         ( Collected { new_messages = List.length kept; advance_ts = advance }
         , Some advance )
       | None -> (Nothing_new, None)))
;;

(* ── the cycle over all bound channels ──────────────────────────── *)

let poll_cycle ~clock ~token ~bot_user_id ~base_dir ~capacity () =
  match Channel_gate_slack_state.read_bindings_result () with
  | Error e ->
    Log.Server.warn "slack-lane: bindings unreadable, cycle skipped: %s"
      (Channel_gate_binding_store.binding_store_error_to_string e)
  | Ok bindings ->
    let path = cursor_path ~base_dir in
    let cursors = read_cursors ~path in
    let now = Unix.gettimeofday () in
    let next =
      (* [channel_id] lives on both binding and audit_event, so the record
         pattern is ambiguous; the annotation names the store's binding. *)
      List.fold_left
        (fun acc (binding : Channel_gate_binding_store.binding) ->
          let channel_id = binding.Channel_gate_binding_store.channel_id in
          let cursor_opt = List.assoc_opt channel_id cursors in
          let outcome, advance =
            poll_channel ~clock ~token ~bot_user_id ~now ~capacity ~channel_id
              ~cursor_opt
          in
          (match outcome with
           | Initialized ->
             Log.Server.info
               "slack-lane: channel %s first sight, collecting from now"
               channel_id
           | Collected { new_messages; advance_ts } ->
             Log.Server.info
               "slack-lane: channel %s +%d message(s), cursor at ts %s"
               channel_id new_messages advance_ts
           | Nothing_new -> ()
           | Fetch_failed detail ->
             Log.Server.warn
               "slack-lane: channel %s fetch failed (cursor held): %s"
               channel_id detail);
          match advance with
          | Some latest ->
            (channel_id, latest) :: List.remove_assoc channel_id acc
          | None -> acc)
        cursors bindings
    in
    write_cursors ~path next
;;

module For_testing = struct
  let pollable = pollable

  let cursor_advance_of = cursor_advance_of
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
