(** Board_moderation — operator-visible moderation queue and action audit trail.

    Single-writer in-memory store.  Callers must not share the global store
    across concurrent fibers without external serialisation. *)

(** {1 Reason codes} *)

type flag_reason =
  | Spam
  | Harassment
  | Off_topic
  | Policy_violation of string
  [@@deriving show]

let flag_reason_to_string = function
  | Spam              -> "spam"
  | Harassment        -> "harassment"
  | Off_topic         -> "off_topic"
  | Policy_violation s -> "policy:" ^ s

let flag_reason_of_string s =
  match s with
  | "spam"        -> Some Spam
  | "harassment"  -> Some Harassment
  | "off_topic"   -> Some Off_topic
  | _ when String.length s > 7 && String.sub s 0 7 = "policy:" ->
      Some (Policy_violation (String.sub s 7 (String.length s - 7)))
  | _ -> None

(** {1 Action kinds} *)

type action_kind =
  | Approve
  | Remove
  | Hide
  | Warn
  [@@deriving show]

let action_kind_to_string = function
  | Approve -> "approve"
  | Remove  -> "remove"
  | Hide    -> "hide"
  | Warn    -> "warn"

let action_kind_of_string = function
  | "approve" -> Some Approve
  | "remove"  -> Some Remove
  | "hide"    -> Some Hide
  | "warn"    -> Some Warn
  | _         -> None

(** {1 Target kinds} *)

type target_kind =
  | Target_post
  | Target_comment
  [@@deriving show]

let target_kind_to_string = function
  | Target_post    -> "post"
  | Target_comment -> "comment"

let target_kind_of_string = function
  | "post"    -> Some Target_post
  | "comment" -> Some Target_comment
  | _         -> None

(** {1 Records} *)

type queue_entry = {
  entry_id    : string;
  target_kind : target_kind;
  target_id   : string;
  reporter    : string;
  reason      : flag_reason;
  flagged_at  : float;
  resolved    : bool;
}

type audit_entry = {
  audit_id    : string;
  target_kind : target_kind;
  target_id   : string;
  actor       : string;
  action      : action_kind;
  reason      : flag_reason option;
  note        : string option;
  acted_at    : float;
}

type target_summary = {
  report_count : int;
  moderation_status : string;
}

(** {1 In-memory store} *)

type store = {
  queue : (string, queue_entry) Hashtbl.t;  (* entry_id -> entry *)
  audit : audit_entry list ref;
  unresolved_by_target : (target_kind * string, string) Hashtbl.t;
  report_count_by_target : (target_kind * string, int) Hashtbl.t;
  latest_action_by_target : (target_kind * string, action_kind * float) Hashtbl.t;
  last_flag_by_reporter : (string, float) Hashtbl.t;
}

let max_note_length = 500

let global_store : store option ref = ref None

let default_flag_rate_limit_sec = 1.0

let sanitize_flag_rate_limit_sec value =
  if Float.is_finite value then Float.max 0.0 value
  else default_flag_rate_limit_sec

let flag_rate_limit_sec () =
  Env_config_core.get_float ~default:default_flag_rate_limit_sec
    "MASC_BOARD_MODERATION_FLAG_RATE_LIMIT_SEC"
  |> sanitize_flag_rate_limit_sec

let make_store () : store =
  {
    queue = Hashtbl.create 64;
    audit = ref [];
    unresolved_by_target = Hashtbl.create 64;
    report_count_by_target = Hashtbl.create 64;
    latest_action_by_target = Hashtbl.create 64;
    last_flag_by_reporter = Hashtbl.create 64;
  }

let target_key target_kind target_id = (target_kind, target_id)

let increment_report_count s target_key =
  let current =
    Hashtbl.find_opt s.report_count_by_target target_key |> Option.value ~default:0
  in
  Hashtbl.replace s.report_count_by_target target_key (current + 1)

let update_latest_action s target_key action acted_at =
  match Hashtbl.find_opt s.latest_action_by_target target_key with
  | Some (_existing_action, existing_at) when Float.compare existing_at acted_at > 0 -> ()
  | _ -> Hashtbl.replace s.latest_action_by_target target_key (action, acted_at)

let retry_after_for_reporter s ~reporter ~now ~window_sec =
  if Float.compare window_sec 0.0 <= 0 then None
  else
    match Hashtbl.find_opt s.last_flag_by_reporter reporter with
    | None -> None
    | Some flagged_at ->
        let flagged_at =
          if Float.compare now flagged_at < 0 then (
            Hashtbl.replace s.last_flag_by_reporter reporter now;
            now)
          else
            flagged_at
        in
        let elapsed = Float.max 0.0 (now -. flagged_at) in
        let remaining = window_sec -. elapsed in
        if Float.compare remaining 0.0 <= 0 then None
        else Some remaining

let store () : store =
  match !global_store with
  | Some s -> s
  | None ->
      let s = make_store () in
      global_store := Some s;
      s

let init () : unit =
  match !global_store with
  | Some _ -> ()
  | None   -> global_store := Some (make_store ())

let reset_for_test () : unit =
  global_store := None

(** {1 Queue operations} *)

let flag ~target_kind ~target_id ~reporter ~reason =
  let s = store () in
  let now = Time_compat.now () in
  let target_key = target_key target_kind target_id in
  if Hashtbl.mem s.unresolved_by_target target_key then
    Error (Printf.sprintf "target %s is already flagged and pending review" target_id)
  else
    let window_sec = flag_rate_limit_sec () in
    let retry_after = retry_after_for_reporter s ~reporter ~now ~window_sec in
    match retry_after with
    | Some remaining ->
        Error
          (Printf.sprintf
             "reporter %s is rate limited; retry after %.3fs"
             reporter remaining)
    | None ->
        let entry_id = Random_id.prefixed ~prefix:"mq-" ~bytes:16 in
        let entry = {
          entry_id;
          target_kind;
          target_id;
          reporter;
          reason;
          flagged_at = now;
          resolved   = false;
        } in
        Hashtbl.replace s.queue entry_id entry;
        Hashtbl.replace s.unresolved_by_target target_key entry_id;
        increment_report_count s target_key;
        Hashtbl.replace s.last_flag_by_reporter reporter now;
        Ok entry

let get_queue ?resolved () =
  let s = store () in
  let entries =
    Hashtbl.fold (fun _k v acc -> v :: acc) s.queue []
  in
  let filtered =
    match resolved with
    | None       -> entries
    | Some want  -> List.filter (fun e -> e.resolved = want) entries
  in
  List.sort (fun a b -> Float.compare b.flagged_at a.flagged_at) filtered

let resolve_entry ~entry_id =
  let s = store () in
  match Hashtbl.find_opt s.queue entry_id with
  | None -> Error (Printf.sprintf "moderation queue entry not found: %s" entry_id)
  | Some e ->
      if not e.resolved then
        Hashtbl.remove s.unresolved_by_target (target_key e.target_kind e.target_id);
      Hashtbl.replace s.queue entry_id { e with resolved = true };
      Ok ()

(** {1 Audit trail} *)

let record_action ~target_kind ~target_id ~actor ~action ?reason ?note () =
  let s = store () in
  let note_trimmed =
    Option.map
      (fun n ->
         let t = String.trim n in
         if String.length t > max_note_length then
           String.sub t 0 max_note_length
         else t)
      note
  in
  let audit_id = Random_id.prefixed ~prefix:"ma-" ~bytes:16 in
  let acted_at = Time_compat.now () in
  let entry = {
    audit_id;
    target_kind;
    target_id;
    actor;
    action;
    reason;
    note = note_trimmed;
    acted_at;
  } in
  let target_key = target_key target_kind target_id in
  (match Hashtbl.find_opt s.unresolved_by_target target_key with
   | None -> ()
   | Some entry_id ->
       Hashtbl.remove s.unresolved_by_target target_key;
       (match Hashtbl.find_opt s.queue entry_id with
        | Some qe when not qe.resolved ->
            Hashtbl.replace s.queue entry_id { qe with resolved = true }
        | _ -> ()));
  update_latest_action s target_key action acted_at;
  s.audit := entry :: !(s.audit);
  Ok entry

let get_audit_trail ?target_id ?actor ?(limit = 100) () =
  let cap = min limit 500 in
  let s = store () in
  let entries = !(s.audit) in
  let filtered =
    entries
    |> (match target_id with
        | None    -> Fun.id
        | Some id -> List.filter (fun e -> e.target_id = id))
    |> (match actor with
        | None -> Fun.id
        | Some a -> List.filter (fun e -> e.actor = a))
  in
  (* Already newest-first since we prepend on record *)
  let sorted = List.sort (fun a b -> Float.compare b.acted_at a.acted_at) filtered in
  let n = List.length sorted in
  if n <= cap then sorted
  else
    let rec take acc i = function
      | []     -> List.rev acc
      | _ when i >= cap -> List.rev acc
      | x :: xs -> take (x :: acc) (i + 1) xs
    in
    take [] 0 sorted

(** {1 Target projection} *)

let moderation_status_of_action = function
  | Approve -> "approved"
  | Remove  -> "removed"
  | Hide    -> "hidden"
  | Warn    -> "warned"

let target_summary ~target_kind ~target_id =
  let s = store () in
  let target_key = target_key target_kind target_id in
  let report_count =
    Hashtbl.find_opt s.report_count_by_target target_key |> Option.value ~default:0
  in
  let has_unresolved =
    match Hashtbl.find_opt s.unresolved_by_target target_key with
    | None -> false
    | Some entry_id -> (
        match Hashtbl.find_opt s.queue entry_id with
        | Some entry when not entry.resolved -> true
        | _ -> false)
  in
  let moderation_status =
    if has_unresolved then
      "flagged"
    else
      match Hashtbl.find_opt s.latest_action_by_target target_key with
      | None -> "none"
      | Some (action, _acted_at) -> moderation_status_of_action action
  in
  { report_count; moderation_status }

(** {1 JSON projection} *)

let target_kind_json tk = `String (target_kind_to_string tk)

let flag_reason_json r = `String (flag_reason_to_string r)

let action_kind_json a = `String (action_kind_to_string a)

let queue_entry_to_json (e : queue_entry) : Yojson.Safe.t =
  `Assoc [
    ("entry_id",    `String e.entry_id);
    ("target_kind", target_kind_json e.target_kind);
    ("target_id",   `String e.target_id);
    ("reporter",    `String e.reporter);
    ("reason",      flag_reason_json e.reason);
    ("flagged_at",  `Float e.flagged_at);
    ("resolved",    `Bool e.resolved);
  ]

let audit_entry_to_json (e : audit_entry) : Yojson.Safe.t =
  `Assoc ([
    ("audit_id",    `String e.audit_id);
    ("target_kind", target_kind_json e.target_kind);
    ("target_id",   `String e.target_id);
    ("actor",       `String e.actor);
    ("action",      action_kind_json e.action);
    ("acted_at",    `Float e.acted_at);
  ] @ (match e.reason with
       | None   -> []
       | Some r -> [("reason", flag_reason_json r)])
    @ (match e.note with
       | None   -> []
       | Some n -> [("note", `String n)]))
