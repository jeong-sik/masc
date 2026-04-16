(** See {!Keeper_cascade_profile} interface for rationale. *)

(** SSOT variant. Adding a new cascade profile is a compile-time event:
    add a variant here, then exhaustive [match] sites flag every consumer
    that needs to handle it. Personal/playground-only cascades must NOT
    be added here — they live in
    [$MASC_BASE_PATH/.masc/playground/.../cascade.json] only. *)
type t =
  | Default
  | Keeper_unified
  | Sangsu
  | Local_only
  | Local_recovery
  | Tool_rerank

let to_string = function
  | Default -> "default"
  | Keeper_unified -> "keeper_unified"
  | Sangsu -> "sangsu"
  | Local_only -> "local_only"
  | Local_recovery -> "local_recovery"
  | Tool_rerank -> "tool_rerank"

let all = [ Default; Keeper_unified; Sangsu; Local_only; Local_recovery; Tool_rerank ]

(** All known cascade profile names, derived from the variant. Consumers
    that still operate on strings can use this list; new code should
    take {!t} directly. *)
let known_cascades = List.map to_string all

let default = Keeper_unified
let default_name = to_string default

let of_string_opt (raw : string) : t option =
  match String.trim raw |> String.lowercase_ascii with
  | "" -> Some default
  | "default" -> Some Default
  | "keeper_unified"
  | "oas-keeper_unified"
  | "coding_first"
  | "oas-coding_first" -> Some Keeper_unified
  (* Historical drift: never defined as separate profiles, always fell
     through to default. Collapsed here so bucket/metric code does not
     see a ghost value. *)
  | "keeper_turn" | "keeper_reply" -> Some default
  | "sangsu" -> Some Sangsu
  | "local_only" -> Some Local_only
  | "local_recovery" -> Some Local_recovery
  | "tool_rerank" -> Some Tool_rerank
  | _ -> None

let canonical (raw : string) : t =
  match of_string_opt raw with
  | Some t -> t
  | None -> default

let canonicalize (raw : string) : string = to_string (canonical raw)

let models_key_t t = to_string t ^ "_models"
let temperature_key_t t = to_string t ^ "_temperature"
let max_tokens_key_t t = to_string t ^ "_max_tokens"

let models_key name = models_key_t (canonical name)
let temperature_key name = temperature_key_t (canonical name)
let max_tokens_key name = max_tokens_key_t (canonical name)
