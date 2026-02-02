(** Lodge Cascade — JSON-driven LLM cascade with Claude rotation.

    Reads slot arrays from config/llm_cascade.json.
    Each slot = (tool_name, model, api_key_env).
    Claude slots are rotated round-robin across heartbeat ticks.
    Config file is hot-reloaded by checking mtime every 60s. *)

open Printf

(* ---------- Types ---------- *)

type cascade_slot = {
  tool_name : string;    (* "glm", "ollama", "claude-cli" *)
  model : string;        (* "glm-4.7", "glm-4.7-flash", "claude-sonnet-4-20250514" *)
  key_env : string option; (* env var name for api_key, e.g. "CLAUDE_CODE_OAUTH_TOKEN_anyang" *)
}

(* ---------- Config Cache ---------- *)

(* mtime-based cache: (path -> (mtime, parsed_json)) *)
let config_cache : (string, float * Yojson.Safe.t) Hashtbl.t = Hashtbl.create 4

(* Claude round-robin counter — persists for process lifetime (lock-free) *)
let claude_rr_counter = Atomic.make 0

let load_json_file path =
  let st = Unix.stat path in
  let mtime = st.Unix.st_mtime in
  match Hashtbl.find_opt config_cache path with
  | Some (cached_mtime, json) when Float.equal cached_mtime mtime -> json
  | _ ->
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let n = in_channel_length ic in
      let buf = Bytes.create n in
      really_input ic buf 0 n;
      buf)
    |> fun buf ->
    let json = Yojson.Safe.from_string (Bytes.to_string buf) in
    Hashtbl.replace config_cache path (mtime, json);
    json

(* ---------- Config Parsing ---------- *)

let parse_slot (json : Yojson.Safe.t) : cascade_slot =
  let open Yojson.Safe.Util in
  let tool_name = json |> member "tool" |> to_string in
  let model = json |> member "model" |> to_string in
  let key_env = json |> member "key_env" |> to_string_option in
  { tool_name; model; key_env }

let load_cascade ~config_path ~cascade_name : cascade_slot list =
  try
    let json = load_json_file config_path in
    let open Yojson.Safe.Util in
    let arr = json |> member cascade_name |> to_list in
    List.map parse_slot arr
  with
  | Sys_error msg ->
    eprintf "[cascade] config load failed: %s — using empty cascade\n%!" msg;
    []
  | exn ->
    eprintf "[cascade] config parse error: %s — using empty cascade\n%!" (Printexc.to_string exn);
    []

(* ---------- Slot Reordering (Claude Rotation) ---------- *)

(** Partition slots into non-claude prefix, claude group, non-claude suffix.
    Then rotate the claude group by the round-robin counter. *)
let rotate_claude_slots (slots : cascade_slot list) : cascade_slot list =
  (* Split into three groups: prefix (before first claude), claudes, suffix (after last claude) *)
  let rec split_prefix acc = function
    | [] -> (List.rev acc, [], [])
    | s :: rest when s.tool_name = "claude-cli" ->
      let claudes, suffix = split_claudes [s] rest in
      (List.rev acc, claudes, suffix)
    | s :: rest -> split_prefix (s :: acc) rest
  and split_claudes acc = function
    | [] -> (List.rev acc, [])
    | s :: rest when s.tool_name = "claude-cli" ->
      split_claudes (s :: acc) rest
    | rest -> (List.rev acc, rest)
  in
  let prefix, claudes, suffix = split_prefix [] slots in
  if List.length claudes <= 1 then slots  (* Nothing to rotate *)
  else begin
    let n = List.length claudes in
    let offset = Atomic.fetch_and_add claude_rr_counter 1 mod n in
    (* Rotate: drop first `offset` elements, append them at end *)
    let arr = Array.of_list claudes in
    let rotated = Array.init n (fun i -> arr.((i + offset) mod n)) in
    prefix @ Array.to_list rotated @ suffix
  end

(* ---------- Cascade Execution ---------- *)

(** Resolve env var name to its value at runtime. *)
let resolve_key (key_env : string option) : string option =
  match key_env with
  | None -> None
  | Some env_name -> Sys.getenv_opt env_name

(** Run cascade: try each slot in order until one succeeds.
    @param slots Ordered list of cascade slots
    @param prompt Prompt to send to LLM
    @param timeout_sec Curl --max-time
    @param max_chars Max response chars to keep
    @param call_llm Function that actually invokes llm-mcp
    @param is_valid Predicate to check if response is usable
    @param agent_name For logging *)
let run_cascade
    ~(slots : cascade_slot list)
    ~(prompt : string)
    ~(timeout_sec : int)
    ~(max_chars : int)
    ~(call_llm : tool_name:string -> extra_args:(string * Yojson.Safe.t) list -> prompt:string -> timeout_sec:int -> max_chars:int -> string)
    ~(is_valid : string -> bool)
    ~(agent_name : string)
  : string =
  let rotated = rotate_claude_slots slots in
  let rec try_slots = function
    | [] ->
      printf "   ❌ [%s] All LLMs failed, skipping\n%!" agent_name;
      ""
    | slot :: rest ->
      let extra_args =
        let base = [("model", `String slot.model)] in
        match resolve_key slot.key_env with
        | Some k ->
          printf "   🔑 [%s] api_key resolved for %s (%d chars)\n%!" agent_name
            (Option.value ~default:"?" slot.key_env) (String.length k);
          ("api_key", `String k) :: base
        | None ->
          (match slot.key_env with
           | Some env -> printf "   ⚠️ [%s] env var %s NOT FOUND\n%!" agent_name env
           | None -> ());
          base
      in
      let label = match slot.key_env with
        | Some env -> sprintf "%s(%s)" slot.tool_name (String.sub env (max 0 (String.length env - 8)) (min 8 (String.length env)))
        | None -> slot.tool_name
      in
      printf "   🔍 [%s] trying %s...\n%!" agent_name label;
      let r = call_llm ~tool_name:slot.tool_name ~extra_args ~prompt ~timeout_sec ~max_chars in
      printf "   🔍 [%s] %s returned (%d chars)\n%!" agent_name label (String.length r);
      if is_valid r then begin
        printf "   🧠 [%s] %s: %s\n%!" agent_name label
          (if String.length r > 80 then String.sub r 0 80 ^ "..." else r);
        r
      end else begin
        printf "   ⚠️ [%s] %s failed (%d chars), next...\n%!" agent_name label (String.length r);
        try_slots rest
      end
  in
  try_slots rotated

(* ---------- Convenience: get_cascade (cached load + rotate) ---------- *)

let default_config_path () =
  let me = Sys.getenv_opt "ME_ROOT" |> Option.value ~default:(Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp") in
  Filename.concat (Filename.concat me "workspace/yousleepwhen/masc-mcp") "config/llm_cascade.json"

let get_cascade ?(config_path = "") ~cascade_name () : cascade_slot list =
  let path = if String.length config_path > 0 then config_path else default_config_path () in
  load_cascade ~config_path:path ~cascade_name
