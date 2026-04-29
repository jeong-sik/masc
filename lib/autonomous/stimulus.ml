(* Stimulus — Cycle 23 / Tier B6.
   See stimulus.mli for the design rationale. *)

(* ── Source taxonomy ─────────────────────────────────────────────── *)

type source =
  | User_message [@tla.symbol "user_message"]
  | Memory_recall [@tla.symbol "memory_recall"]
  | Discovery_signal [@tla.symbol "discovery_signal"]
  | Resource_alert [@tla.symbol "resource_alert"]
  | Goal_phase_change [@tla.symbol "goal_phase_change"]
  | Priority_shift [@tla.symbol "priority_shift"]
  | External_event [@tla.symbol "external_event"]
[@@deriving tla]

(* ── Stimulus value ──────────────────────────────────────────────── *)

type t = {
  id : string;
  source : source;
  payload : Yojson.Safe.t;
  salience : float;
  timestamp : float;
}

(* ── String projection ───────────────────────────────────────────── *)

let source_to_string = to_tla_symbol

let source_of_string = function
  | "user_message" -> Some User_message
  | "memory_recall" -> Some Memory_recall
  | "discovery_signal" -> Some Discovery_signal
  | "resource_alert" -> Some Resource_alert
  | "goal_phase_change" -> Some Goal_phase_change
  | "priority_shift" -> Some Priority_shift
  | "external_event" -> Some External_event
  | _ -> None

(* ── Construction ────────────────────────────────────────────────── *)

(* Range check excludes NaN: [Float.is_finite] rejects NaN/Inf, and
   the bounds are checked separately. We do not coerce out-of-range
   inputs to a clamped value; that would silently mask emitter bugs
   and violate the "Unknown → Permissive Default" anti-pattern. *)
let validate_salience s =
  if not (Float.is_finite s) then
    invalid_arg
      (Printf.sprintf "Stimulus.make: salience not finite (%f)" s);
  if s < 0.0 || s > 1.0 then
    invalid_arg
      (Printf.sprintf "Stimulus.make: salience out of range [0,1]: %f" s)

let validate_id id =
  if String.length id = 0 then
    invalid_arg "Stimulus.make: id must be non-empty"

let make ~id ~source ~payload ~salience ~timestamp =
  validate_id id;
  validate_salience salience;
  { id; source; payload; salience; timestamp }

(* ── Scoring ─────────────────────────────────────────────────────── *)

let default_decay = 0.01

let score t ~now =
  let age = Float.max 0.0 (now -. t.timestamp) in
  t.salience *. Float.exp (-. default_decay *. age)

(* ── Serialisation ───────────────────────────────────────────────── *)

let to_json t : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String t.id);
      ("source", `String (source_to_string t.source));
      ("payload", t.payload);
      ("salience", `Float t.salience);
      ("timestamp", `Float t.timestamp);
    ]

(* Defensive parsing: no exceptions escape — every malformed input
   maps to [Error msg] with a localised reason. The salience and id
   validations re-use the construction-time invariants. *)
let of_json (j : Yojson.Safe.t) : (t, string) result =
  let ( let* ) = Result.bind in
  match j with
  | `Assoc fields ->
      let lookup k =
        match List.assoc_opt k fields with
        | Some v -> Ok v
        | None -> Error (Printf.sprintf "Stimulus.of_json: missing key %S" k)
      in
      let* id_j = lookup "id" in
      let* id =
        match id_j with
        | `String s -> Ok s
        | _ -> Error "Stimulus.of_json: id must be a string"
      in
      let* source_j = lookup "source" in
      let* source_str =
        match source_j with
        | `String s -> Ok s
        | _ -> Error "Stimulus.of_json: source must be a string"
      in
      let* source =
        match source_of_string source_str with
        | Some s -> Ok s
        | None ->
            Error
              (Printf.sprintf "Stimulus.of_json: unknown source %S"
                 source_str)
      in
      let* payload = lookup "payload" in
      let* salience_j = lookup "salience" in
      let* salience =
        match salience_j with
        | `Float f -> Ok f
        | `Int i -> Ok (float_of_int i)
        | _ -> Error "Stimulus.of_json: salience must be a number"
      in
      let* timestamp_j = lookup "timestamp" in
      let* timestamp =
        match timestamp_j with
        | `Float f -> Ok f
        | `Int i -> Ok (float_of_int i)
        | _ -> Error "Stimulus.of_json: timestamp must be a number"
      in
      (* Re-run construction-time invariants so [of_json |> to_json]
         and [make ...] enforce the same range. *)
      (try Ok (make ~id ~source ~payload ~salience ~timestamp)
       with Invalid_argument msg -> Error msg)
  | _ -> Error "Stimulus.of_json: expected JSON object"
