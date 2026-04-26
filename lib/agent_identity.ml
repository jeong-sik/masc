(** Agent Identity - Unified Agent Identification across MCP sessions

    OpenClaw-inspired session tracking for multi-agent environments.
    Provides consistent agent identification across:
    - MCP tool calls
    - Coord coordination
    - Task assignments
    - Federation/portal messages

    @since 0.5.0
*)

(* UUID / random generation.  [Random.State.t] is NOT fiber-safe —
   concurrent [Random.State.int] or [Uuidm.v4_gen] calls against a
   shared state can produce duplicate values or corrupt internal
   state.  The previous doc comment claiming "Fiber-safe" was
   incorrect.  Guard the shared state with an [Eio.Mutex] and route
   every RNG access through [with_identity_rng].  Same discipline
   used by [Lib.A2a_tools] ([a2a_rng] / [a2a_rng_mutex]). *)

module StringMap = Map.Make (String)

let identity_rng = Random.State.make_self_init ()
let identity_rng_mutex = Eio.Mutex.create ()
let with_identity_rng f =
  Eio.Mutex.use_ro identity_rng_mutex (fun () -> f identity_rng)

(** {1 Core Types} *)

(** Connection surface known to core.
    External platform names stay opaque so core does not depend on connector vendors. *)
type channel =
  | Api
  | Internal
  | External of string

(** {1 Channel Parsing} *)

let normalize_channel_label s =
  let normalized = String.trim s |> String.lowercase_ascii in
  if normalized = "" then "unknown" else normalized

let channel_of_string s =
  match normalize_channel_label s with
  | "api" -> Api
  | "internal" -> Internal
  | "unknown" -> External "unknown"
  | other -> External other

let string_of_channel = function
  | Api -> "api"
  | Internal -> "internal"
  | External s -> normalize_channel_label s

let channel_to_yojson = function
  | Api -> `String "Api"
  | Internal -> `String "Internal"
  | External s ->
      `List [ `String "External"; `String (normalize_channel_label s) ]

let channel_of_yojson = function
  | `String "Api" | `String "api" -> Ok Api
  | `String "Internal" | `String "internal" -> Ok Internal
  | `String "Telegram" | `String "telegram" ->
      Ok (External "telegram")
  | `String "Discord" | `String "discord" ->
      Ok (External "discord")
  | `String "Slack" | `String "slack" -> Ok (External "slack")
  | `String "Signal" | `String "signal" -> Ok (External "signal")
  | `String "Webchat" | `String "webchat" ->
      Ok (External "webchat")
  | `String s -> Ok (channel_of_string s)
  | `List [ `String "External"; `String s ] ->
      Ok (External (normalize_channel_label s))
  | `List [ `String "Unknown"; `String s ] ->
      Ok (External (normalize_channel_label s))
  | _ -> Error "channel_of_yojson: expected string or tagged external variant"

(** Agent identity - extracted from session/request context *)
type t = {
  uuid : string;                  (** Permanent unique identifier (UUIDv4 or hash) *)
  session_key : string;           (** Unique session identifier *)
  agent_name : string;            (** Display name (e.g., "claude-agent-001") *)
  channel : channel option;       (** Source channel if known *)
  user_id : string option;        (** User ID from channel (e.g., telegram user id) *)
  room_id : string option;        (** Current room if joined *)
  capabilities : string list;     (** Declared agent capabilities *)
  registered_at : float;          (** Unix timestamp *)
  mutable last_seen : float;      (** Last activity timestamp *)
  metadata : (string * string) list;  (** Additional metadata *)
}
[@@deriving to_yojson]

(** Generate a unique agent UUID from name + timestamp hash *)
let generate_uuid ~agent_name =
  let timestamp = Time_compat.now () in
  let random_part = with_identity_rng (fun rng -> Random.State.int rng 0xFFFFFF) in
  let input = Printf.sprintf "%s-%f-%d" agent_name timestamp random_part in
  (* Simple hash-based UUID: first 8 chars of hex digest *)
  let hash = Digest.string input |> Digest.to_hex in
  Printf.sprintf "agent-%s" (String.sub hash 0 12)

(** {1 Identity Creation} *)

(** Generate a unique session key *)
let generate_session_key () =
  let uuid = with_identity_rng (fun rng -> Uuidm.v4_gen rng ()) in
  Uuidm.to_string uuid

(** Create identity from MCP request params *)
let from_mcp_params params =
  let module U = Yojson.Safe.Util in
  (* #9788: normalize null/non-object payloads to empty assoc so U.member
     below cannot raise Type_error and crash tools/call dispatch. *)
  let params = match params with `Assoc _ -> params | _ -> `Assoc [] in
  let get_opt key =
    match U.member key params with
    | `String s -> Some s
    | _ -> None
  in
  let session_key_prefix session_key =
    let prefix_len = min 8 (String.length session_key) in
    if prefix_len = 0 then "unknown"
    else String.sub session_key 0 prefix_len
  in
  let fallback_agent_name session_key =
    let prefix = session_key_prefix session_key in
    let prefix = if prefix = "unknown" then "anon" else prefix in
    Printf.sprintf "agent-%s" prefix
  in
  let session_key = match get_opt "_session_key" with
    | Some k ->
        let k = String.trim k in
        if k = "" then generate_session_key () else k
    | None -> generate_session_key ()
  in
  let agent_name = match get_opt "_agent_name", get_opt "agent_name" with
    | Some n, _ | _, Some n -> n
    | None, None -> fallback_agent_name session_key
  in
  let channel = match get_opt "_channel" with
    | Some c -> Some (channel_of_string c)
    | None -> None
  in
  let user_id = get_opt "_user_id" in
  let room_id = get_opt "room" in
  let capabilities =
    match U.member "_capabilities" params with
    | `List l -> List.filter_map (fun v -> match v with `String s -> Some s | _ -> None) l
    | _ -> []
  in
  let now = Time_compat.now () in
  {
    uuid = generate_uuid ~agent_name;
    session_key;
    agent_name;
    channel;
    user_id;
    room_id;
    capabilities;
    registered_at = now;
    last_seen = now;
    metadata = [];
  }

(** Create identity from agent_name (legacy support) *)
let from_agent_name agent_name =
  let now = Time_compat.now () in
  {
    uuid = generate_uuid ~agent_name;
    session_key = generate_session_key ();
    agent_name;
    channel = None;
    user_id = None;
    room_id = None;
    capabilities = [];
    registered_at = now;
    last_seen = now;
    metadata = [];
  }

(** Create anonymous/unknown identity *)
let anonymous () =
  let now = Time_compat.now () in
  let key = generate_session_key () in
  let name = Printf.sprintf "anon-%s" (String.sub key 0 8) in
  {
    uuid = generate_uuid ~agent_name:name;
    session_key = key;
    agent_name = name;
    channel = None;
    user_id = None;
    room_id = None;
    capabilities = [];
    registered_at = now;
    last_seen = now;
    metadata = [];
  }

(** {1 Identity Registry} *)

module Registry = struct
  type registry = {
    identities : t StringMap.t ref;  (** session_key -> identity *)
    by_agent_name : string StringMap.t ref;  (** agent_name -> session_key *)
    lock : Eio.Mutex.t;
  }

  let create () = {
    identities = ref StringMap.empty;
    by_agent_name = ref StringMap.empty;
    lock = Eio.Mutex.create ();
  }

  let with_lock reg f =
    Eio_guard.with_mutex reg.lock f

  (** Register or update identity *)
  let register reg identity =
    with_lock reg (fun () ->
      reg.identities := StringMap.add identity.session_key identity !(reg.identities);
      reg.by_agent_name := StringMap.add identity.agent_name identity.session_key !(reg.by_agent_name);
      identity
    )

  (** Find by session key *)
  let find_by_session reg session_key =
    with_lock reg (fun () ->
      StringMap.find_opt session_key !(reg.identities)
    )

  (** Find by agent name *)
  let find_by_name reg agent_name =
    with_lock reg (fun () ->
      match StringMap.find_opt agent_name !(reg.by_agent_name) with
      | Some session_key -> StringMap.find_opt session_key !(reg.identities)
      | None -> None
    )

  (** Update last_seen and optionally room *)
  let touch reg session_key ?room_id () =
    with_lock reg (fun () ->
      match StringMap.find_opt session_key !(reg.identities) with
      | Some identity ->
          identity.last_seen <- Time_compat.now ();
          (match room_id with
           | Some rid -> 
               let updated = { identity with room_id = Some rid } in
               reg.identities := StringMap.add session_key updated !(reg.identities)
           | None -> ())
      | None -> ()
    )

  (** Remove identity *)
  let unregister reg session_key =
    with_lock reg (fun () ->
      match StringMap.find_opt session_key !(reg.identities) with
      | Some identity ->
          reg.identities := StringMap.remove session_key !(reg.identities);
          reg.by_agent_name := StringMap.remove identity.agent_name !(reg.by_agent_name)
      | None -> ()
    )

  (** List all active identities (active within last N seconds) *)
  let list_active reg ~within_seconds =
    with_lock reg (fun () ->
      let cutoff = Time_compat.now () -. within_seconds in
      !(reg.identities)
      |> StringMap.bindings
      |> List.filter_map (fun (_, id) ->
        if id.last_seen > cutoff then Some id else None)
    )

  (** Get identity count *)
  let count reg =
    with_lock reg (fun () ->
      StringMap.cardinal !(reg.identities)
    )
end

(** {1 Utilities} *)

(** Check if identity has a specific capability *)
let has_capability identity cap =
  List.mem cap identity.capabilities

(** Get display string for logging *)
let to_display_string identity =
  let session_key_prefix session_key =
    let prefix_len = min 8 (String.length session_key) in
    if prefix_len = 0 then "unknown"
    else String.sub session_key 0 prefix_len
  in
  let channel_str = match identity.channel with
    | Some c -> Printf.sprintf " via %s" (string_of_channel c)
    | None -> ""
  in
  let room_str = match identity.room_id with
    | Some r -> Printf.sprintf " in %s" r
    | None -> ""
  in
  Printf.sprintf "%s (%s)%s%s"
    identity.agent_name
    (session_key_prefix identity.session_key)
    channel_str
    room_str

(** Check if two identities refer to the same agent *)
let same_agent a b =
  a.session_key = b.session_key || a.agent_name = b.agent_name

(** {1 MAGI Archetype System} *)

(** MAGI archetypes for agent specialization *)
type archetype =
  | Melchior   (** 🔬 Scientist - technical analysis, implementation *)
  | Balthasar  (** 🪞 Mirror - ethics, value alignment, review *)
  | Casper     (** ♟️ Strategist - planning, coordination *)
  | Athena     (** 🧠 Reasoner - logic, math, deep thinking *)
  | Generalist (** 🌐 No specialization *)

let archetype_to_string = function
  | Melchior -> "melchior"
  | Balthasar -> "balthasar"
  | Casper -> "casper"
  | Athena -> "athena"
  | Generalist -> "generalist"

(** Issue #8691: strict parser. The previous catch-all silently
    collapsed any unknown wire string into [Generalist] AND the
    canonical ["generalist"] label was matched only via that catch-all
    (round-trip relied on the default). Same SSOT pattern as
    #8615/#8670/#8682/#8687. *)
let archetype_of_string_opt = function
  | "melchior" | "scientist" | "tech" -> Some Melchior
  | "balthasar" | "mirror" | "ethics" -> Some Balthasar
  | "casper" | "strategist" | "planner" -> Some Casper
  | "athena" | "reasoner" | "logic" -> Some Athena
  | "generalist" | "" -> Some Generalist
  | _ -> None

(** Back-compat wrapper: callers that have no other recovery still
    fall back to [Generalist] but a warning is logged so the typo /
    drift becomes operator-visible. *)
let archetype_of_string s =
  match archetype_of_string_opt s with
  | Some v -> v
  | None ->
      Log.Misc.warn
        "archetype_of_string: unknown wire string %S → Generalist fallback (#8691)" s;
      Generalist

let archetype_emoji = function
  | Melchior -> "🔬"
  | Balthasar -> "🪞"
  | Casper -> "♟️"
  | Athena -> "🧠"
  | Generalist -> "🌐"

(** Get archetype from identity metadata *)
let get_archetype identity =
  match List.assoc_opt "archetype" identity.metadata with
  | Some s -> archetype_of_string s
  | None -> Generalist

(** Set archetype in identity metadata *)
let set_archetype identity archetype =
  let filtered = List.filter (fun (k, _) -> k <> "archetype") identity.metadata in
  { identity with metadata = ("archetype", archetype_to_string archetype) :: filtered }

(** Voting weight modifier based on archetype and topic *)
let archetype_weight archetype topic_category =
  match archetype, topic_category with
  | Melchior, "technical" -> 1.5
  | Melchior, "implementation" -> 1.5
  | Balthasar, "ethics" -> 1.5
  | Balthasar, "review" -> 1.5
  | Casper, "strategy" -> 1.5
  | Casper, "planning" -> 1.5
  | Athena, "reasoning" -> 1.5
  | Athena, "math" -> 1.5
  | _, _ -> 1.0
