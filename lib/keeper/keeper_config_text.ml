(** Keeper_config_text — String/UTF-8 processing, bool parsing, input key
    validation, and goal-horizon text normalization.

    Extracted from [keeper_config.ml] during godfile decomposition.
    These functions have no back-references to keeper_config itself —
    they depend only on external modules (Env_config_core, Re, Uchar,
    Tool_args, Yojson, Log).

    @since God file decomposition *)

open Tool_args

(* ── Bool / string parsing ──────────────────────────────────── *)

let bool_default_true_of_env name =
  match Env_config_core.raw_value_opt name with
  | None -> true
  | Some v ->
      let v = String.trim v |> String.lowercase_ascii in
      not (v = "0" || v = "false" || v = "no" || v = "n")

let bool_of_string raw =
  let v = String.trim raw |> String.lowercase_ascii in
  if v = "1" || v = "true" || v = "yes" || v = "y" || v = "on" then Some true
  else if v = "0" || v = "false" || v = "no" || v = "n" || v = "off" then Some false
  else None

let bool_of_env_default name ~(default : bool) =
  match Env_config_core.raw_value_opt name with
  | None -> default
  | Some raw -> Option.value (bool_of_string raw) ~default

let bool_of_env_opt name =
  match Env_config_core.raw_value_opt name with
  | None -> None
  | Some raw -> bool_of_string raw

(* ── Name validation ────────────────────────────────────────── *)

let validate_name = Safe_identifier.is_portable_name

(* ── Configuration constants ────────────────────────────────── *)

let default_proactive_enabled = true
let default_proactive_idle_sec = 120
let default_proactive_cooldown_sec = 300
let approval_queue_stale_max_wait_sec = 600.0

(* Environment-configurable caps. Defaults were raised from 480/320 to 4096
   because silent truncation in the dashboard made operators think edits were
   not persisting. Operators can lower them via env vars if a deployment needs
   tighter prompt budgets. *)
let default_goal_max_chars =
  match Env_config_core.raw_value_opt "MASC_KEEPER_GOAL_MAX_CHARS" with
  | Some v ->
    (match int_of_string_opt (String.trim v) with
     | Some n when n > 0 -> n
     | _ -> 4096)
  | None -> 4096

let default_drift_max_clauses = 6

let prompt_render_max_bytes =
  match Env_config_core.raw_value_opt "MASC_KEEPER_SELF_MODEL_MAX_BYTES" with
  | Some v ->
    (match int_of_string_opt (String.trim v) with
     | Some n when n > 0 -> n
     | _ -> 4096)
  | None -> 4096

(* ── Removed / rejected keeper input keys ───────────────────── *)

let removed_keeper_input_key_names =
  [
    "models";
    "allowed_models";
    "active_model";
    "trigger_mode";
    "policy_action_budget";
    "initiative_scope";
    "initiative_enabled";
    "initiative_idle_sec";
    "initiative_cooldown_sec";
    "policy_mode";
    "policy_shell_mode";
    "persona_ref";
    "runtime_ref";
  ]

let removed_keeper_sandbox_input_key_names =
  [
    "sandbox_profile";
    "network_mode";
  ]

(* Non-public keeper input keys: accepted for external-client
   compatibility but with no runtime effect (#7447, #9752). Empty since the
   social_model purge (RFC-0276) removed its only member; kept as the typed
   extension point so a future such key warns rather than errors. *)
let non_public_keeper_input_key_names : string list = []

let removed_keeper_msg_input_key_names =
  [
    "goal";
    "short_goal";
    "mid_goal";
    "long_goal";
    "instructions";
    "require_existing";
    "new_goal";
    "new_short_goal";
    "new_mid_goal";
    "new_long_goal";
    "new_instructions";

    (* Tool-task coupling purged (#19806): keeper turns no longer accept
       per-message tool forcing hints; reject them so older harnesses fail
       loud rather than have the keys silently ignored. *)
    "required_tools";
    "required_tool_names";
  ]

let present_json_keys (keys : string list) (json : Yojson.Safe.t) : string list =
  match json with
  | `Assoc fields ->
      keys
      |> List.filter (fun key -> List.mem_assoc key fields)
  | _ -> []

let reject_removed_keeper_input_keys ?(allow_sandbox_fields = false) ~tool_name
    (args : Yojson.Safe.t) =
  let non_public = present_json_keys non_public_keeper_input_key_names args in
  (match non_public with
   | _ :: _ as fields ->
       Log.Keeper.warn
         "%s: ignoring non-public keeper args %s (see #7447, #9752 — \
          accepted for external-client compatibility, no runtime effect)"
         tool_name (String.concat ", " fields)
   | [] -> ());
  let present = present_json_keys removed_keeper_input_key_names args in
  if present <> []
  then
    Error
      (Printf.sprintf
         "removed keeper args for %s: %s. Keepers are always-on by definition."
         tool_name
         (String.concat ", " present))
  else
    if allow_sandbox_fields then Ok ()
    else
      let sandbox_fields =
        present_json_keys removed_keeper_sandbox_input_key_names args
      in
      if sandbox_fields = []
      then Ok ()
      else
        Error
          (Printf.sprintf
             "removed keeper sandbox args for %s: %s. Configure sandbox posture \
              in keeper TOML/profile defaults; keeper runtime contracts do not \
              carry backend details."
             tool_name
             (String.concat ", " sandbox_fields))

let reject_removed_keeper_msg_input_keys ~tool_name (args : Yojson.Safe.t) =
  let present = present_json_keys removed_keeper_msg_input_key_names args in
  match present with
  | [] -> Ok ()
  | fields ->
      Error
        (Printf.sprintf
           "removed keeper message args for %s: %s. Use masc_keeper_up for keeper creation or persisted updates."
           tool_name
           (String.concat ", " fields))

(* ── UTF-8 string processing ────────────────────────────────── *)


let utf8_repair_string (s : string) : string =
  let len = String.length s in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len then ()
    else
      let dec = String.get_utf_8_uchar s i in
      let dlen = Uchar.utf_decode_length dec in
      if dlen > 0 && Uchar.utf_decode_is_valid dec then (
        Buffer.add_substring buf s i dlen;
        loop (i + dlen))
      else (
        Buffer.add_string buf "\xEF\xBF\xBD";
        loop (i + 1))
  in
  loop 0;
  Buffer.contents buf

(* ── Self-model / goal-horizon text normalization ───────────── *)

(* #10552: trim BOTH before and after [String_util.utf8_prefix].  The
   pre-fix sequence was [trim → prefix], but [String_util.utf8_prefix]
   can cut at a position that leaves trailing ASCII whitespace
   (e.g. nick0cave's 322-byte desires field ends with [...는 것.] —
   the prefix at max_bytes=320 backs up to byte 318, ending at the
   space before [것]).  That makes [normalize_self_model_text]
   non-idempotent: applying it once produces a 318-byte string ending
   in a space; applying it AGAIN trims the space to 317 bytes.
   [personality_text_equal] then sees [normalize meta_318 = 317] and
   [normalize raw_322 = 318] — unequal — and re-sync fires every
   reconcile tick.  Trimming after prefix makes the function
   idempotent: [normalize(normalize(x)) = normalize(x)]. *)
let normalize_self_model_text ~(max_bytes : int) (raw : string) : string =
  let s = String.trim raw in
  if s = "" then ""
  else
    let cut = String_util.utf8_prefix ~max_bytes s in
    String.trim cut

let normalize_goal_text ?(max_len = default_goal_max_chars) (raw : string) : string =
  let s = String.trim raw in
  if s = "" then ""
  else String_util.utf8_prefix ~max_bytes:max_len s

let split_semicolon_clauses (raw : string) : string list =
  raw
  |> String.split_on_char ';'
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")

let take_last = List_util.take_last

let compact_self_model_text
    ?(max_clauses = default_drift_max_clauses)
    ~(max_bytes : int)
    (raw : string) : string =
  raw
  |> split_semicolon_clauses
  |> take_last max_clauses
  |> String.concat "; "
  |> normalize_self_model_text ~max_bytes

let parse_self_model_opt args key : string option =
  match get_string_opt args key with
  | None -> None
  | Some raw ->
    Some (normalize_self_model_text ~max_bytes:prompt_render_max_bytes raw)
