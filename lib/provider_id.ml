(** See provider_id.mli. *)

type t = string

(* The named accessors mirror [Provider_adapter.cn_*].  We keep the
   string literal here (a single SSOT replicates the cn_* values)
   rather than importing Provider_adapter, which would create a
   dependency cycle for any module Provider_adapter depends on that
   wants to use Provider_id.  The [test_provider_id_ssot] test
   guards drift between this list and the cn_* exports. *)

let ollama = "ollama"
let llama = "llama"
let claude = "claude"
let claude_api = "claude-api"
let codex = "codex"
let codex_api = "codex-api"
let gemini = "gemini"
let gemini_api = "gemini-api"
let kimi = "kimi"
let kimi_api = "kimi-api"
let kimi_coding = "kimi-coding"
let glm = "glm-api"
let glm_coding_plan = "glm-coding-plan"
let openrouter = "openrouter"
let custom = "custom"

let all_canonical =
  [ ollama; llama; claude; claude_api; codex; codex_api;
    gemini; gemini_api; kimi; kimi_api; kimi_coding;
    glm; glm_coding_plan; openrouter; custom ]

let of_canonical s =
  if List.exists (String.equal s) all_canonical then Some s else None

let of_canonical_exn s =
  match of_canonical s with
  | Some t -> t
  | None ->
    invalid_arg
      (Printf.sprintf "Provider_id.of_canonical_exn: %S not in canonical set" s)

let equal = String.equal
let compare = String.compare
let to_string t = t
let matches_string t s = String.equal t s
