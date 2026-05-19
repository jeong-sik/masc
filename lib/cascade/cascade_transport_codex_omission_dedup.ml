(** Codex CLI tool-omission warning dedup.

    Extracted from [cascade_transport.ml] (lines 48-122) as part of the
    godfile decomp campaign. Owns the per-(agent, tool-fingerprint)
    dedup state that suppresses repeated WARN logs when the codex CLI
    omits the same set of keeper-bound runtime MCP tools across
    consecutive calls, while still incrementing the Prometheus counter
    [masc_provider_mcp_tool_omission_total] for every omission.

    Thread-safety: the dedup state is a single [Hashtbl] guarded by a
    [Stdlib.Mutex]. Lookups during module initialisation use only
    [Stdlib.Mutex] (no Eio dependency).

    Public surface is reserved for the legacy [cascade_transport.mli]
    aliases and the dedicated unit test. *)

let codex_omission_state_mu = Stdlib.Mutex.create ()
let codex_omission_state : (string, string) Hashtbl.t = Hashtbl.create 16

let codex_cli_omission_fingerprint (tools : string list) : string =
  tools |> List.sort String.compare |> String.concat ","
;;

let codex_omission_agent_key = function
  | Some agent_name ->
    let agent_name = String.trim agent_name in
    if String.equal agent_name "" then "<no_agent>" else agent_name
  | None -> "<no_agent>"
;;

let codex_omission_should_log ~agent_name ~tool_fingerprint =
  Stdlib.Mutex.lock codex_omission_state_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock codex_omission_state_mu)
    (fun () ->
       match Hashtbl.find_opt codex_omission_state agent_name with
       | Some prev when String.equal prev tool_fingerprint -> false
       | _ ->
         Hashtbl.replace codex_omission_state agent_name tool_fingerprint;
         true)
;;

let codex_cli_omission_fingerprint_seen fingerprint =
  not (codex_omission_should_log ~agent_name:"<no_agent>" ~tool_fingerprint:fingerprint)
;;

(* For tests: reset the dedup state so each test starts clean. *)
let reset_codex_cli_omission_dedup_for_tests () =
  Stdlib.Mutex.lock codex_omission_state_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock codex_omission_state_mu)
    (fun () -> Hashtbl.clear codex_omission_state)
;;

let record_codex_cli_omission_for_agent
      ~(agent_name : string option)
      ~(tools : string list)
  : unit
  =
  let provider_label =
    Llm_provider.Provider_config.string_of_provider_kind
      Llm_provider.Provider_config.Codex_cli
  in
  match tools with
  | [] -> ()
  | _ ->
    List.iter
      (fun tool ->
         Prometheus.inc_counter
           Prometheus.metric_provider_mcp_tool_omission
           ~labels:[ "provider", provider_label; "tool", tool ]
           ())
      tools;
    let tool_fingerprint = codex_cli_omission_fingerprint tools in
    let agent_name_key = codex_omission_agent_key agent_name in
    if codex_omission_should_log ~agent_name:agent_name_key ~tool_fingerprint
    then
      Log.warn
        ~ctx:"oas_worker_exec"
        "codex_cli omitting keeper-bound runtime MCP tool(s) that require request-scoped \
         auth headers: %s (no per-keeper bearer-token lane available for %s; subsequent \
         omissions of this same set are counted in \
         masc_provider_mcp_tool_omission_total{provider=\"%s\"} and not re-logged)"
        (String.concat ", " (List.sort String.compare tools))
        agent_name_key
        provider_label
;;

let record_codex_cli_omission ~(tools : string list) : unit =
  record_codex_cli_omission_for_agent ~agent_name:None ~tools
;;
