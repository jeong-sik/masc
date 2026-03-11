(** Llm_direct — Direct LLM API calls without llm-mcp dependency.

    @deprecated Use {!Llm_client.run_prompt_cascade} with
    {!Lodge_cascade.get_cascade} instead. This module will be removed
    in a future release.

    Provides call_glm, call_claude_cli, call_ollama, call_llama,
    and a unified dispatch.
    Removes the SPOF on llm-mcp (port 8932) for Lodge heartbeat. *)

open Printf

(* ---------- Helpers ---------- *)

let env_set (env : string array) (k : string) (v : string) : string array =
  let prefix = k ^ "=" in
  let rest =
    env
    |> Array.to_list
    |> List.filter (fun kv -> not (String.starts_with ~prefix kv))
  in
  Array.of_list ((prefix ^ v) :: rest)
(** Strip [Extra] metadata and hook outputs from LLM responses. *)
let strip_extra s =
  let s = match String.index_opt s '[' with
    | Some idx when idx > 0 && String.length s > idx + 6
                   && String.sub s idx 7 = "[Extra]" ->
        String.trim (String.sub s 0 idx)
    | _ -> s
  in
  (* Strip Gemini/Claude CLI hook leaks *)
  let lines = String.split_on_char '\n' s in
  let hook_patterns = [
    "Created execution plan for";
    "Expanding hook command:";
    "Hook execution for";
  ] in
  let is_hook_line line =
    List.exists (fun pat ->
      let plen = String.length pat in
      String.length line >= plen &&
      (try String.sub line 0 plen = pat with Invalid_argument _ -> false)
    ) hook_patterns
  in
  let filtered = List.filter (fun l -> not (is_hook_line l)) lines in
  String.trim (String.concat "\n" filtered)
(* ---------- GLM (Z.ai) ---------- *)

(** Call GLM API directly via curl.
    Endpoint: https://api.z.ai/api/coding/paas/v4/chat/completions *)
let call_glm ?(api_key="") ~model ~prompt ~timeout_sec ~max_chars () =
  let key = if api_key = "" then
    Sys.getenv_opt "ZAI_API_KEY" |> Option.value ~default:""
  else api_key in
  if key = "" then begin
    eprintf "[llm_direct] ZAI_API_KEY not set, GLM call skipped\n%!";
    ""
  end else begin
    let body = Yojson.Safe.to_string (`Assoc [
      ("model", `String model);
      ("messages", `List [
        `Assoc [("role", `String "user"); ("content", `String prompt)]
      ]);
      ("stream", `Bool false);
    ]) in
    (* Use argv + stdin: no shell, no API key in process list *)
    let raw = Process_eio.run_argv_with_stdin
      ~timeout_sec:(Float.of_int timeout_sec +. 5.0)
      ~stdin_content:body
      ["curl"; "-s"; "--max-time"; string_of_int timeout_sec;
       "-X"; "POST"; "https://api.z.ai/api/coding/paas/v4/chat/completions";
       "-H"; "Content-Type: application/json";
       "-H"; sprintf "Authorization: Bearer %s" key;
       "-d"; "@-"] in
    (* Extract .choices[0].message.content in OCaml instead of piping to jq *)
    let result = try
      let json = Yojson.Safe.from_string raw in
      json |> Yojson.Safe.Util.member "choices"
           |> Yojson.Safe.Util.index 0
           |> Yojson.Safe.Util.member "message"
           |> Yojson.Safe.Util.member "content"
           |> Yojson.Safe.Util.to_string
    with Yojson.Json_error _ | Yojson.Safe.Util.Type_error (_, _) -> raw in
    let truncated = if String.length result > max_chars
      then String.sub result 0 max_chars else result in
    strip_extra truncated
  end
(* ---------- Claude CLI ---------- *)

(** Call Claude CLI as subprocess.
    Uses CLAUDE_CODE_OAUTH_TOKEN env var for auth. *)
let call_claude_cli ?(api_key="") ~model ~prompt ~timeout_sec ~max_chars () =
  let env =
    let env = Unix.environment () in
    let env = env_set env "TMPDIR" "/tmp/claude-safe" in
    if api_key = "" then env else env_set env "CLAUDE_CODE_OAUTH_TOKEN" api_key
  in
  let raw =
    Process_eio.run_argv_with_stdin
      ~timeout_sec:(Float.of_int timeout_sec +. 5.0)
      ~env
      ~stdin_content:prompt
      ["claude"; "-p"; "--model"; model; "--max-turns"; "1"]
  in
  let truncated =
    if String.length raw > max_chars then String.sub raw 0 max_chars else raw
  in
  strip_extra truncated
(* ---------- Ollama ---------- *)

(** Call Ollama API directly.
    Endpoint: http://127.0.0.1:11434/api/generate *)
let call_ollama ~model ~prompt ~timeout_sec ~max_chars () =
  let body = Yojson.Safe.to_string (`Assoc [
    ("model", `String model);
    ("prompt", `String prompt);
    ("stream", `Bool false);
  ]) in
  (* Use argv + stdin: no shell *)
  let raw = Process_eio.run_argv_with_stdin
    ~timeout_sec:(Float.of_int timeout_sec +. 5.0)
    ~stdin_content:body
    ["curl"; "-s"; "--max-time"; string_of_int timeout_sec;
     "-X"; "POST"; "http://127.0.0.1:11434/api/generate";
     "-H"; "Content-Type: application/json";
     "-d"; "@-"] in
  (* Extract .response in OCaml instead of piping to jq *)
  let result = try
    let json = Yojson.Safe.from_string raw in
    json |> Yojson.Safe.Util.member "response"
         |> Yojson.Safe.Util.to_string
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error (_, _) -> raw in
  let truncated = if String.length result > max_chars
    then String.sub result 0 max_chars else result in
  strip_extra truncated
(* ---------- Llama (llama.cpp / llama-server) ---------- *)

(** Call llama-server via OpenAI-compatible API.
    Endpoint: LLAMA_SERVER_URL/v1/chat/completions (default http://127.0.0.1:8085) *)
let call_llama ~model ~prompt ~timeout_sec ~max_chars () =
  let url = Env_config.Llama.server_url in
  let body = Yojson.Safe.to_string (`Assoc [
    ("model", `String model);
    ("messages", `List [
      `Assoc [("role", `String "user"); ("content", `String prompt)]
    ]);
    ("max_tokens", `Int max_chars);
    ("temperature", `Float 0.7);
  ]) in
  let raw = Process_eio.run_argv_with_stdin
    ~timeout_sec:(Float.of_int timeout_sec +. 5.0)
    ~stdin_content:body
    ["curl"; "-s"; "--max-time"; string_of_int timeout_sec;
     "-X"; "POST"; url ^ "/v1/chat/completions";
     "-H"; "Content-Type: application/json";
     "-d"; "@-"] in
  let result = try
    let json = Yojson.Safe.from_string raw in
    json |> Yojson.Safe.Util.member "choices"
         |> Yojson.Safe.Util.index 0
         |> Yojson.Safe.Util.member "message"
         |> Yojson.Safe.Util.member "content"
         |> Yojson.Safe.Util.to_string
  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error (_, _) -> raw in
  let truncated = if String.length result > max_chars
    then String.sub result 0 max_chars else result in
  strip_extra truncated
(* ---------- Dispatch ---------- *)

(** Unified dispatcher: routes by tool_name to the appropriate backend.
    Compatible with Lodge_cascade.run_cascade ~call_llm callback signature. *)
let dispatch ~tool_name ?(api_key="") ~model ~prompt ~timeout_sec ~max_chars () =
  printf "[llm_direct] dispatch: tool=%s model=%s timeout=%ds\n%!" tool_name model timeout_sec;
  match tool_name with
  | "glm" ->
      call_glm ~api_key ~model ~prompt ~timeout_sec ~max_chars ()
  | "claude-cli" ->
      call_claude_cli ~api_key ~model ~prompt ~timeout_sec ~max_chars ()
  | "ollama" ->
      call_ollama ~model ~prompt ~timeout_sec ~max_chars ()
  | "llama" | "llama.cpp" | "llamacpp" ->
      call_llama ~model ~prompt ~timeout_sec ~max_chars ()
  | other ->
      eprintf "[llm_direct] unknown tool_name: %s, trying GLM fallback\n%!" other;
      call_glm ~api_key ~model ~prompt ~timeout_sec ~max_chars ()