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

type cache_capacity =
  | Unbounded
  | Max_entries of int

type config =
  { success_ttl_sec : float
  ; failure_ttl_sec : float
  ; capacity : cache_capacity
  }

type cache_slot =
  { entry : entry
  ; fetched_at : float
  ; mutable last_used_seq : int
  }

type t =
  { fetch :
      user_id:string ->
      (Slack_rest_client.user_info_ok, Slack_rest_client.error) result
  ; now : unit -> float
  ; config : config
  ; mu : Mutex.t
  ; cache : (string, cache_slot) Hashtbl.t
  ; mutable next_seq : int
  }

let default_success_ttl_sec = 3600.0
let default_failure_ttl_sec = 300.0

let validate_config config =
  (match config.capacity with
   | Unbounded -> ()
   | Max_entries n when n > 0 -> ()
   | Max_entries _ ->
     invalid_arg "Slack_user_directory.create: Max_entries must be positive");
  config

let create_with_config ~config ~fetch ~now () =
  let config = validate_config config in
  { fetch
  ; now
  ; config
  ; mu = Mutex.create ()
  ; cache = Hashtbl.create 32
  ; next_seq = 0
  }

let create ?(success_ttl_sec = default_success_ttl_sec)
    ?(failure_ttl_sec = default_failure_ttl_sec)
    ?(capacity = Unbounded)
    ~fetch ~now () =
  create_with_config
    ~config:{ success_ttl_sec; failure_ttl_sec; capacity }
    ~fetch ~now ()

let config t = t.config

let with_mu t f = Mutex.protect t.mu f

let cache_size t = with_mu t (fun () -> Hashtbl.length t.cache)

let entry_ttl t = function
  | Label _ -> t.config.success_ttl_sec
  | Fetch_failed -> t.config.failure_ttl_sec

(* Slack's documented display precedence: the user-chosen display name, then
   the profile real name, then the legacy handle. A profile with no usable
   name resolves to [None] (rendered as the raw id by callers). *)
let label_of_user_info (info : Slack_rest_client.user_info_ok) =
  match info.display_name, info.real_name, info.name with
  | Some label, _, _ | None, Some label, _ | None, None, Some label ->
    Some label
  | None, None, None -> None

let live_entry t ~user_id =
  let found = with_mu t (fun () -> Hashtbl.find_opt t.cache user_id) in
  match found with
  | None -> None
  | Some slot ->
    let now = t.now () in
    if now -. slot.fetched_at < entry_ttl t slot.entry
    then (
      with_mu t (fun () ->
        match Hashtbl.find_opt t.cache user_id with
        | Some current when Float.equal current.fetched_at slot.fetched_at ->
          t.next_seq <- t.next_seq + 1;
          current.last_used_seq <- t.next_seq
        | Some _ | None -> ());
      Some slot.entry)
    else (
      with_mu t (fun () ->
        match Hashtbl.find_opt t.cache user_id with
        | Some current when Float.equal current.fetched_at slot.fetched_at ->
          Hashtbl.remove t.cache user_id
        | Some _ | None -> ());
      None)

let prune_expired_locked t ~now =
  let expired_keys =
    Hashtbl.fold
      (fun user_id slot acc ->
         if now -. slot.fetched_at < entry_ttl t slot.entry
         then acc
         else user_id :: acc)
      t.cache
      []
  in
  List.iter (Hashtbl.remove t.cache) expired_keys

let evict_lru_one_locked t =
  let victim =
    Hashtbl.fold
      (fun key slot best ->
         match best with
         | None -> Some (key, slot.last_used_seq)
         | Some (best_key, best_seq) ->
           if slot.last_used_seq < best_seq
              || (slot.last_used_seq = best_seq && String.compare key best_key < 0)
           then Some (key, slot.last_used_seq)
           else best)
      t.cache
      None
  in
  match victim with
  | Some (key, _) -> Hashtbl.remove t.cache key
  | None -> ()

let store_entry t ~user_id entry =
  let now = t.now () in
  with_mu t (fun () ->
    prune_expired_locked t ~now;
    (match t.config.capacity with
     | Unbounded -> ()
     | Max_entries max_entries ->
       if not (Hashtbl.mem t.cache user_id)
       then
         while Hashtbl.length t.cache >= max_entries do
           evict_lru_one_locked t
         done);
    t.next_seq <- t.next_seq + 1;
    Hashtbl.replace t.cache user_id
      { entry; fetched_at = now; last_used_seq = t.next_seq })

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
          user_id t.config.failure_ttl_sec
          (Format.asprintf "%a" Slack_rest_client.pp_error error);
        Fetch_failed
    in
    store_entry t ~user_id entry;
    (match entry with Label label -> Some label | Fetch_failed -> None)

type self = Connector_self_mention.t =
  | Bot_user_id_unknown
  | Bound_keeper of { bot_user_id : string; keeper_name : string }

(* Rewrite Slack mention escapes into plain [@label] text before a message
   reaches keeper prompts and durable transcripts. Only the user-mention
   escape is touched; channel ([<#…>]), special ([<!…>]) and link
   ([<http…>]) escapes pass through unchanged. An unresolvable mention keeps
   its exact wire form — lossless, never a guessed name.
   Wire format:
   https://api.slack.com/reference/surfaces/formatting#mentioning-users *)
let rewrite_mentions t ~self text =
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
        let label =
          match Connector_self_mention.label self ~user_id with
          | Some _ as keeper_name -> keeper_name
          | None -> display_label t ~user_id
        in
        (match label with
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
          let label =
            match Connector_self_mention.label self ~user_id with
            | Some keeper_name -> keeper_name
            | None -> String.sub text (id_end + 1) (close - id_end - 1)
          in
          Buffer.add_string buf ("@" ^ label);
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
