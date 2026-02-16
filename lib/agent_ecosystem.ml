(** Agent Ecosystem - Extended Agent Identity for Second Brain

    This module extends Agent_identity with:
    - Agent types: Resident (daemon), Visitor (session), Ephemeral (task)
    - Profile: name, role, traits, avatar for community presence
    - Lineage: DNA-based generational tracking with mutations
    - Hash: 12-char hex for concise display (derived from session_key)

    Design principle: Composition over modification - we wrap Agent_identity.t
    rather than modifying it, ensuring backward compatibility.

    @since 0.6.0
*)

(** {1 Agent Ecosystem Types} *)

(** Agent lifecycle type - how long the agent persists *)
type agent_type =
  | Resident   (** 🏛️ Daemon - always running (pandora, archivist) *)
  | Visitor    (** 🚶 Session-based - interactive CLI session *)
  | Ephemeral  (** ⚡ Task-based - spawned for single task, then gone *)
[@@deriving yojson, show, eq]

(** Agent profile - public identity for community presence *)
type agent_profile = {
  name : string;              (** Display name (e.g., "Pandora") *)
  role : string;              (** Primary role (e.g., "idea_generator") *)
  traits : string list;       (** Personality traits (e.g., ["curious"; "creative"]) *)
  avatar : string option;     (** Emoji or URL for avatar *)
}
[@@deriving yojson, show, eq]

(** Agent lineage - DNA-based generational tracking *)
type lineage = {
  generation : int;              (** Division count from origin (0 = first) *)
  parent_hash : string option;   (** Parent agent's hash if spawned *)
  ancestors : string list;       (** [parent; grandparent; ...] up to 10 *)
  mutations : string list;       (** Learning/changes (e.g., ["learned:ocaml"; "trait:verbose"]) *)
}
[@@deriving yojson, show, eq]

(** Extended agent identity - wraps Agent_identity.t with ecosystem data *)
type extended = {
  base : Agent_identity.t;        (** Core identity *)
  hash : string;                  (** 12-char hex hash for display *)
  agent_type : agent_type;        (** Lifecycle type *)
  profile : agent_profile;        (** Public identity for community *)
  lineage : lineage;              (** DNA-based generational tracking *)
}
[@@deriving yojson]

(** {1 Defaults} *)

(** Default profile for agents without explicit profile *)
let default_profile name = {
  name;
  role = "general";
  traits = [];
  avatar = None;
}

(** Default lineage for first-generation agents *)
let default_lineage = {
  generation = 0;
  parent_hash = None;
  ancestors = [];
  mutations = [];
}

(** {1 Hash Generation} *)

(** Generate 12-char hex hash from session_key
    Uses first 12 chars of SHA256 for compact display *)
let hash_of_session_key session_key =
  let digest = Digestif.SHA256.digest_string session_key in
  let hex = Digestif.SHA256.to_hex digest in
  String.sub hex 0 12

(** {1 Agent Type Utilities} *)

let agent_type_of_string = function
  | "resident" | "daemon" -> Resident
  | "visitor" | "session" -> Visitor
  | "ephemeral" | "task" -> Ephemeral
  | _ -> Visitor  (* default to Visitor for backward compatibility *)

let string_of_agent_type = function
  | Resident -> "resident"
  | Visitor -> "visitor"
  | Ephemeral -> "ephemeral"

let agent_type_emoji = function
  | Resident -> "🏛️"
  | Visitor -> "🚶"
  | Ephemeral -> "⚡"

(** {1 Extended Identity Creation} *)

(** Extend a base identity with ecosystem data *)
let extend ?(agent_type=Visitor) ?(profile=None) ?(lineage=None) (base : Agent_identity.t) =
  let hash = hash_of_session_key base.session_key in
  let profile = match profile with
    | Some p -> p
    | None -> default_profile base.agent_name
  in
  let lineage = match lineage with
    | Some l -> l
    | None -> default_lineage
  in
  { base; hash; agent_type; profile; lineage }

(** Create extended identity from MCP request params *)
let from_mcp_params params =
  let module U = Yojson.Safe.Util in
  let get_opt key =
    try Some (params |> U.member key |> U.to_string)
    with U.Type_error _ | Not_found -> None
  in
  let get_list key =
    try params |> U.member key |> U.to_list |> List.map U.to_string
    with U.Type_error _ | Not_found -> []
  in
  let base = Agent_identity.from_mcp_params params in
  let hash = hash_of_session_key base.session_key in
  let agent_type = match get_opt "_agent_type" with
    | Some t -> agent_type_of_string t
    | None -> Visitor
  in
  let profile = {
    name = Option.value (get_opt "_agent_display_name") ~default:base.agent_name;
    role = Option.value (get_opt "_agent_role") ~default:"general";
    traits = get_list "_agent_traits";
    avatar = get_opt "_agent_avatar";
  } in
  let lineage = {
    generation = (try params |> U.member "_generation" |> U.to_int with U.Type_error _ | Not_found -> 0);
    parent_hash = get_opt "_parent_hash";
    ancestors = get_list "_ancestors";
    mutations = get_list "_mutations";
  } in
  { base; hash; agent_type; profile; lineage }

(** Create extended identity from agent_name *)
let from_agent_name ?(agent_type=Visitor) ?(role="general") agent_name =
  let base = Agent_identity.from_agent_name agent_name in
  let hash = hash_of_session_key base.session_key in
  let profile = { (default_profile agent_name) with role } in
  { base; hash; agent_type; profile; lineage = default_lineage }

(** Create anonymous extended identity *)
let anonymous () =
  let base = Agent_identity.anonymous () in
  let hash = hash_of_session_key base.session_key in
  {
    base;
    hash;
    agent_type = Ephemeral;
    profile = default_profile base.agent_name;
    lineage = default_lineage;
  }

(** Create a child identity from parent (for mitosis/spawning) *)
let spawn_child ~parent ~child_name ~role =
  let child_base = Agent_identity.from_agent_name child_name in
  let hash = hash_of_session_key child_base.session_key in
  let ancestors =
    (* Keep last 10 ancestors *)
    let new_ancestors = parent.hash :: parent.lineage.ancestors in
    if List.length new_ancestors > 10 then
      List.filteri (fun i _ -> i < 10) new_ancestors
    else
      new_ancestors
  in
  {
    base = { child_base with
      channel = parent.base.channel;
      room_id = parent.base.room_id;
      capabilities = parent.base.capabilities;
      metadata = parent.base.metadata;
    };
    hash;
    agent_type = Ephemeral;  (* Children are typically ephemeral *)
    profile = { parent.profile with name = child_name; role };
    lineage = {
      generation = parent.lineage.generation + 1;
      parent_hash = Some parent.hash;
      ancestors;
      mutations = [];  (* Start fresh, mutations added during life *)
    };
  }

(** Add a mutation to identity's lineage *)
let add_mutation ext mutation =
  let new_mutations = mutation :: ext.lineage.mutations in
  { ext with lineage = { ext.lineage with mutations = new_mutations } }

(** {1 Utilities} *)

(** Get display string for logging *)
let to_display_string ext =
  let type_emoji = agent_type_emoji ext.agent_type in
  let channel_str = match ext.base.channel with
    | Some c -> Printf.sprintf " via %s" (Agent_identity.string_of_channel c)
    | None -> ""
  in
  let room_str = match ext.base.room_id with
    | Some r -> Printf.sprintf " in %s" r
    | None -> ""
  in
  let gen_str = if ext.lineage.generation > 0 then
    Printf.sprintf " [gen:%d]" ext.lineage.generation
  else ""
  in
  Printf.sprintf "%s %s (%s)%s%s%s"
    type_emoji
    ext.profile.name
    ext.hash
    channel_str
    room_str
    gen_str

(** Get detailed identity card for display *)
let to_identity_card ext =
  let type_str = string_of_agent_type ext.agent_type in
  let emoji = agent_type_emoji ext.agent_type in
  let lineage_str = match ext.lineage.parent_hash with
    | Some parent -> Printf.sprintf "  Parent: %s\n  Generation: %d" parent ext.lineage.generation
    | None -> Printf.sprintf "  Generation: %d (origin)" ext.lineage.generation
  in
  let traits_str = match ext.profile.traits with
    | [] -> "none"
    | ts -> String.concat ", " ts
  in
  Printf.sprintf {|
🎫 **Agent Identity Card**
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  %s Name: %s
  Hash: %s
  Type: %s (%s)
  Role: %s
  Traits: %s
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📜 **Lineage**
%s
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
|} emoji ext.profile.name ext.hash emoji type_str ext.profile.role traits_str lineage_str

(** Check if two extended identities refer to the same agent *)
let same_agent a b =
  a.hash = b.hash ||
  a.base.session_key = b.base.session_key ||
  a.base.agent_name = b.base.agent_name

(** {1 Metadata-based Storage} *)

(** Store ecosystem data in base identity's metadata *)
let to_base_with_metadata ext =
  let metadata =
    [ ("_hash", ext.hash);
      ("_agent_type", string_of_agent_type ext.agent_type);
      ("_agent_display_name", ext.profile.name);
      ("_agent_role", ext.profile.role);
      ("_generation", string_of_int ext.lineage.generation);
    ]
    @ (match ext.lineage.parent_hash with
       | Some h -> [("_parent_hash", h)]
       | None -> [])
    @ (match ext.profile.avatar with
       | Some a -> [("_avatar", a)]
       | None -> [])
    @ (List.mapi (fun i t -> (Printf.sprintf "_trait_%d" i, t)) ext.profile.traits)
    @ (List.mapi (fun i m -> (Printf.sprintf "_mutation_%d" i, m)) ext.lineage.mutations)
    @ (List.mapi (fun i a -> (Printf.sprintf "_ancestor_%d" i, a)) ext.lineage.ancestors)
    @ ext.base.metadata
  in
  { ext.base with metadata }

(** Restore extended identity from base identity's metadata *)
let from_base_with_metadata (base : Agent_identity.t) =
  let get key = List.assoc_opt key base.metadata in
  let get_indexed prefix =
    let rec collect i acc =
      match get (Printf.sprintf "%s_%d" prefix i) with
      | Some v -> collect (i + 1) (v :: acc)
      | None -> List.rev acc
    in
    collect 0 []
  in
  let hash = match get "_hash" with
    | Some h -> h
    | None -> hash_of_session_key base.session_key
  in
  let agent_type = match get "_agent_type" with
    | Some t -> agent_type_of_string t
    | None -> Visitor
  in
  let profile = {
    name = Option.value (get "_agent_display_name") ~default:base.agent_name;
    role = Option.value (get "_agent_role") ~default:"general";
    traits = get_indexed "_trait";
    avatar = get "_avatar";
  } in
  let lineage = {
    generation = (match get "_generation" with
      | Some g -> (try int_of_string g with Failure _ -> 0)
      | None -> 0);
    parent_hash = get "_parent_hash";
    ancestors = get_indexed "_ancestor";
    mutations = get_indexed "_mutation";
  } in
  { base; hash; agent_type; profile; lineage }

(** {1 Registry for Extended Identities} *)

module Registry = struct
  type t = {
    identities : (string, extended) Hashtbl.t;  (** hash -> extended *)
    by_session : (string, string) Hashtbl.t;    (** session_key -> hash *)
    by_name : (string, string) Hashtbl.t;       (** agent_name -> hash *)
    lock : Eio.Mutex.t;
  }

  let create () = {
    identities = Hashtbl.create 64;
    by_session = Hashtbl.create 64;
    by_name = Hashtbl.create 64;
    lock = Eio.Mutex.create ();
  }

  let with_lock reg f =
    Eio.Mutex.use_rw ~protect:true reg.lock (fun () -> f ())

  let register reg ext =
    with_lock reg (fun () ->
      Hashtbl.replace reg.identities ext.hash ext;
      Hashtbl.replace reg.by_session ext.base.session_key ext.hash;
      Hashtbl.replace reg.by_name ext.base.agent_name ext.hash;
      ext
    )

  let find_by_hash reg hash =
    with_lock reg (fun () ->
      Hashtbl.find_opt reg.identities hash
    )

  let find_by_session reg session_key =
    with_lock reg (fun () ->
      match Hashtbl.find_opt reg.by_session session_key with
      | Some hash -> Hashtbl.find_opt reg.identities hash
      | None -> None
    )

  let find_by_name reg agent_name =
    with_lock reg (fun () ->
      match Hashtbl.find_opt reg.by_name agent_name with
      | Some hash -> Hashtbl.find_opt reg.identities hash
      | None -> None
    )

  let touch reg hash =
    with_lock reg (fun () ->
      match Hashtbl.find_opt reg.identities hash with
      | Some ext ->
          ext.base.last_seen <- Time_compat.now ();
      | None -> ()
    )

  let unregister reg hash =
    with_lock reg (fun () ->
      match Hashtbl.find_opt reg.identities hash with
      | Some ext ->
          Hashtbl.remove reg.identities hash;
          Hashtbl.remove reg.by_session ext.base.session_key;
          Hashtbl.remove reg.by_name ext.base.agent_name
      | None -> ()
    )

  let list_by_type reg agent_type =
    with_lock reg (fun () ->
      Hashtbl.to_seq_values reg.identities
      |> Seq.filter (fun ext -> ext.agent_type = agent_type)
      |> List.of_seq
    )

  let list_active reg ~within_seconds =
    with_lock reg (fun () ->
      let cutoff = Time_compat.now () -. within_seconds in
      Hashtbl.to_seq_values reg.identities
      |> Seq.filter (fun ext -> ext.base.last_seen > cutoff)
      |> List.of_seq
    )

  let count reg =
    with_lock reg (fun () ->
      Hashtbl.length reg.identities
    )

  let count_by_type reg agent_type =
    with_lock reg (fun () ->
      Hashtbl.to_seq_values reg.identities
      |> Seq.filter (fun ext -> ext.agent_type = agent_type)
      |> Seq.length
    )
end
