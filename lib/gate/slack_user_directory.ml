(* Slack_user_directory — inbound identity rendering for Slack user ids
   (issue #28376).

   Maps [U…]/[W…] ids to display labels via an injected [users.info] fetch,
   with a TTL cache so one lookup serves a conversation instead of one call
   per message. Failures are cached too, on a shorter TTL: a permanently
   failing id (e.g. the bot token lacks the [users:read] scope) would
   otherwise refetch on every inbound message without changing the outcome,
   while the shorter TTL still picks a scope fix up promptly. The raw id is
   never replaced as an identity key anywhere — this module only renders.

   The fetch and the clock are injected so cache behavior is deterministic
   under test. Cache sections are short [Stdlib.Mutex] holds (cross-domain
   safe, mirroring [Subsystem_health]); the fetch itself runs outside the
   lock, so two concurrent misses may fetch twice — idempotent and rarer
   than a lock held across HTTP. *)

type entry =
  | Label of string
  | Fetch_failed

type t =
  { fetch :
      user_id:string ->
      (Slack_rest_client.user_info_ok, Slack_rest_client.error) result
  ; now : unit -> float
  ; success_ttl_sec : float
  ; failure_ttl_sec : float
  ; mu : Mutex.t
  ; cache : (string, entry * float) Hashtbl.t
  }

let default_success_ttl_sec = 3600.0
let default_failure_ttl_sec = 300.0

let create ?(success_ttl_sec = default_success_ttl_sec)
    ?(failure_ttl_sec = default_failure_ttl_sec) ~fetch ~now () =
  { fetch
  ; now
  ; success_ttl_sec
  ; failure_ttl_sec
  ; mu = Mutex.create ()
  ; cache = Hashtbl.create 32
  }

(* Slack's documented display precedence: the user-chosen display name, then
   the profile real name, then the legacy handle. A profile with no usable
   name resolves to [None] (rendered as the raw id by callers). *)
let label_of_user_info (info : Slack_rest_client.user_info_ok) =
  match info.display_name, info.real_name, info.name with
  | Some label, _, _ | None, Some label, _ | None, None, Some label ->
    Some label
  | None, None, None -> None

let live_entry t ~user_id =
  Mutex.lock t.mu;
  let found = Hashtbl.find_opt t.cache user_id in
  Mutex.unlock t.mu;
  match found with
  | None -> None
  | Some (entry, fetched_at) ->
    let ttl =
      match entry with
      | Label _ -> t.success_ttl_sec
      | Fetch_failed -> t.failure_ttl_sec
    in
    if t.now () -. fetched_at < ttl then Some entry else None

let store_entry t ~user_id entry =
  let stamped = (entry, t.now ()) in
  Mutex.lock t.mu;
  Hashtbl.replace t.cache user_id stamped;
  Mutex.unlock t.mu

let display_label t ~user_id =
  (* Slack omits [user] on bot and system events, so an empty id reaches here.
     It can never resolve -- users.info answers user_not_found -- and letting it
     through spends an API call, a WARN naming no one, and a failure-cache entry
     keyed on "" to learn that. Answer it here instead (#28402). *)
  if String.equal user_id ""
  then None
  else
    match live_entry t ~user_id with
  | Some (Label label) -> Some label
  | Some Fetch_failed -> None
  | None ->
    let entry =
      match t.fetch ~user_id with
      | Ok info ->
        (match label_of_user_info info with
         | Some label -> Label label
         | None -> Fetch_failed)
      | Error error ->
        Log.Server.warn
          "slack users.info failed for %s (raw id will render until retry \
           in %.0fs): %s"
          user_id t.failure_ttl_sec
          (Format.asprintf "%a" Slack_rest_client.pp_error error);
        Fetch_failed
    in
    store_entry t ~user_id entry;
    (match entry with Label label -> Some label | Fetch_failed -> None)

(* Rewrite Slack mention escapes into plain [@label] text before a message
   reaches keeper prompts and durable transcripts. Only the user-mention
   escape is touched; channel ([<#…>]), special ([<!…>]) and link
   ([<http…>]) escapes pass through unchanged. An unresolvable mention keeps
   its exact wire form — lossless, never a guessed name.
   Wire format:
   https://api.slack.com/reference/surfaces/formatting#mentioning-users *)
let rewrite_mentions t text =
  let len = String.length text in
  let buf = Buffer.create len in
  let is_id_char c = (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') in
  let rec loop i =
    if i >= len then ()
    else if
      i + 2 < len
      && text.[i] = '<'
      && text.[i + 1] = '@'
      && (text.[i + 2] = 'U' || text.[i + 2] = 'W')
    then begin
      let id_end = ref (i + 2) in
      while !id_end < len && is_id_char text.[!id_end] do incr id_end done;
      let id_end = !id_end in
      let user_id = String.sub text (i + 2) (id_end - (i + 2)) in
      if id_end < len && text.[id_end] = '>' && String.length user_id >= 2
      then begin
        (match display_label t ~user_id with
         | Some label -> Buffer.add_string buf ("@" ^ label)
         | None -> Buffer.add_string buf (String.sub text i (id_end + 1 - i)));
        loop (id_end + 1)
      end
      else if id_end < len && text.[id_end] = '|' then begin
        (* <@U…|label>: Slack already supplied the label; no fetch needed. *)
        match String.index_from_opt text id_end '>' with
        | Some close when close > id_end + 1
                          && String.trim
                               (String.sub text (id_end + 1)
                                  (close - id_end - 1))
                             <> "" ->
          Buffer.add_string buf
            ("@" ^ String.sub text (id_end + 1) (close - id_end - 1));
          loop (close + 1)
        | Some _ | None ->
          Buffer.add_char buf text.[i];
          loop (i + 1)
      end
      else begin
        Buffer.add_char buf text.[i];
        loop (i + 1)
      end
    end
    else begin
      Buffer.add_char buf text.[i];
      loop (i + 1)
    end
  in
  loop 0;
  Buffer.contents buf
