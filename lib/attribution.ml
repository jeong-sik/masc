(** See [Attribution.mli] for documentation. *)

type origin = Det | NonDet

let string_of_origin = function Det -> "det" | NonDet -> "nondet"

let origin_to_yojson o : Yojson.Safe.t = `String (string_of_origin o)

let origin_of_yojson = function
  | `String "det" -> Ok Det
  | `String "nondet" -> Ok NonDet
  | json ->
    Error
      (Printf.sprintf
         "attribution.origin: expected \"det\" | \"nondet\", got %s"
         (Yojson.Safe.to_string json))

type verdict = Pass | Fail | Partial

let string_of_verdict = function
  | Pass -> "pass"
  | Fail -> "fail"
  | Partial -> "partial"

let verdict_to_yojson v : Yojson.Safe.t = `String (string_of_verdict v)

let verdict_of_yojson = function
  | `String "pass" -> Ok Pass
  | `String "fail" -> Ok Fail
  | `String "partial" -> Ok Partial
  | json ->
    Error
      (Printf.sprintf
         "attribution.verdict: expected \"pass\" | \"fail\" | \"partial\", got %s"
         (Yojson.Safe.to_string json))

type t = {
  origin: origin;
  gate: string;
  verdict: verdict;
  evidence: Yojson.Safe.t;
  blocked_from: string option;
  blocked_to: string option;
  rationale: string option;
}

let to_yojson (t : t) : Yojson.Safe.t =
  let base = [
    ("origin", origin_to_yojson t.origin);
    ("gate", `String t.gate);
    ("verdict", verdict_to_yojson t.verdict);
    ("evidence", t.evidence);
  ] in
  let add_opt key = function
    | None -> []
    | Some v -> [ (key, `String v) ]
  in
  `Assoc
    (base
    @ add_opt "blocked_from" t.blocked_from
    @ add_opt "blocked_to" t.blocked_to
    @ add_opt "rationale" t.rationale)

let ( let* ) = Result.bind

let field_string ~gate_field fields key =
  match List.assoc_opt key fields with
  | Some (`String s) -> Ok s
  | Some other ->
    Error
      (Printf.sprintf "attribution.%s: expected string, got %s"
         gate_field
         (Yojson.Safe.to_string other))
  | None ->
    Error (Printf.sprintf "attribution: missing field %S" key)

let opt_string fields key =
  match List.assoc_opt key fields with
  | None | Some `Null -> Ok None
  | Some (`String s) -> Ok (Some s)
  | Some other ->
    Error
      (Printf.sprintf "attribution.%s: expected string or null, got %s"
         key (Yojson.Safe.to_string other))

let of_yojson = function
  | `Assoc fields ->
    let* origin_j =
      match List.assoc_opt "origin" fields with
      | Some j -> Ok j
      | None -> Error "attribution: missing field \"origin\""
    in
    let* origin = origin_of_yojson origin_j in
    let* gate = field_string ~gate_field:"gate" fields "gate" in
    let* verdict_j =
      match List.assoc_opt "verdict" fields with
      | Some j -> Ok j
      | None -> Error "attribution: missing field \"verdict\""
    in
    let* verdict = verdict_of_yojson verdict_j in
    let evidence =
      match List.assoc_opt "evidence" fields with
      | None | Some `Null -> `Null
      | Some ev -> ev
    in
    let* blocked_from = opt_string fields "blocked_from" in
    let* blocked_to = opt_string fields "blocked_to" in
    let* rationale = opt_string fields "rationale" in
    Ok { origin; gate; verdict; evidence; blocked_from; blocked_to; rationale }
  | json ->
    Error
      (Printf.sprintf "attribution: expected JSON object, got %s"
         (Yojson.Safe.to_string json))

let show (t : t) : string =
  Printf.sprintf "Attribution{origin=%s; gate=%s; verdict=%s}"
    (string_of_origin t.origin) t.gate (string_of_verdict t.verdict)

let pass ~origin ~gate ~evidence =
  {
    origin;
    gate;
    verdict = Pass;
    evidence;
    blocked_from = None;
    blocked_to = None;
    rationale = None;
  }

let fail ~origin ~gate ~evidence ?blocked_from ?blocked_to ?rationale () =
  { origin; gate; verdict = Fail; evidence; blocked_from; blocked_to; rationale }

let partial ~origin ~gate ~evidence ?rationale () =
  {
    origin;
    gate;
    verdict = Partial;
    evidence;
    blocked_from = None;
    blocked_to = None;
    rationale;
  }
