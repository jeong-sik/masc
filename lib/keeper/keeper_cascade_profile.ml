(** See {!Keeper_cascade_profile} interface for rationale. *)

let default_name = "keeper_unified"

(** SSOT for cascade profiles the repo's [config/cascade.json] may define.
    Adding a new cascade profile requires adding it here AND populating
    [<name>_models] (and optional [_temperature]/[_max_tokens]) in
    cascade.json. Personal/playground-only cascades must live in
    [$MASC_BASE_PATH/.masc/playground/.../cascade.json], not in this list. *)
let known_cascades =
  [ "default"
  ; "keeper_unified"
  ; "sangsu"
  ; "local_only"
  ; "local_recovery"
  ; "tool_rerank"
  ]

let canonicalize (raw : string) : string =
  let trimmed = String.trim raw in
  let lc = String.lowercase_ascii trimmed in
  match lc with
  | "" -> default_name
  | "keeper_unified"
  | "oas-keeper_unified"
  | "coding_first"
  | "oas-coding_first" -> default_name
  (* Historical drift: these were never defined as separate cascade
     profiles; calls always fell through to default. Collapse them to
     [default_name] explicitly so bucket/metric code does not see a
     ghost value. *)
  | "keeper_turn" | "keeper_reply" -> default_name
  | name when List.mem name known_cascades -> trimmed
  | _ -> default_name

let models_key name = canonicalize name ^ "_models"
let temperature_key name = canonicalize name ^ "_temperature"
let max_tokens_key name = canonicalize name ^ "_max_tokens"
