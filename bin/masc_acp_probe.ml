(** Live end-to-end ACP v1 multi-runtime verification probe for MASC.

    Exercises real persistent ACP sessions against Antigravity ([agy acp]),
    Kimi Code ([kimi acp]), Mistral Vibe ([vibe-acp], stripping
    [MISTRAL_API_KEY] to enforce the keyring subscription), and Muse Code
    ([muse acp]).

    For each requested driver, this executable:
    1. Starts a loopback [Runtime_official_client_mcp_http] server exposing two
       real MASC tools: [masc_probe_ping] (builtin roundtrip check) and
       [keeper_skill] (backed by the workspace's [.agents/skills] catalog).
    2. Spawns ONE persistent [Runtime_acp_client.t] under a driver-scoped
       [Eio.Switch.t] and completes ACP v1 [initialize] + [session/new].
    3. Executes Turn 1 (cold): invokes [masc_probe_ping] over MCP HTTP and
       verifies the exact nonce roundtrip on both the MCP server and reply.
    4. Executes Turn 2 (warm, reusing the same persistent process and session
       ID): invokes [keeper_skill] to list and read the [ocaml-coding] MASC
       skill and verifies real skill content + warm-turn token/cache telemetry.

    Zero secrets, API keys, or ephemeral Bearer headers are ever printed. *)

let mcp_server_name = "masc"
let default_turn_timeout_s = 120.0
let target_skill_name = "ocaml-coding"
let max_skill_read_chars = 2400
let max_preview_chars = 180

type turn_report =
  { latency_ms : int
  ; stop_reason : string
  ; text_preview : string
  ; usage : Runtime_acp_client.usage
  }

type driver_report =
  { driver : Runtime_acp_client.driver
  ; posture : Runtime_native_tools.posture
  ; passed : bool
  ; init_ms : int
  ; session_id : string option
  ; negotiated_model : string option
  ; negotiated_mode : string option
  ; session_reused : bool
  ; mcp_phase : string
  ; ping_tool_called : bool
  ; ping_reply_verified : bool
  ; skill_tool_called : bool
  ; skill_reply_verified : bool
  ; turn1 : turn_report option
  ; turn2 : turn_report option
  ; error : string option
  }

let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

let truncate_preview text =
  let trimmed = String.trim text in
  let single_line =
    String.map (function '\n' | '\r' | '\t' -> ' ' | c -> c) trimmed
  in
  if String.length single_line <= max_preview_chars
  then single_line
  else String.sub single_line 0 max_preview_chars ^ "..."
;;

let contains_case_insensitive ~needle haystack =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let hlen = String.length h in
  let nlen = String.length n in
  if nlen = 0
  then true
  else if nlen > hlen
  then false
  else (
    let rec loop i =
      if i > hlen - nlen
      then false
      else if String.sub h i nlen = n
      then true
      else loop (i + 1)
    in
    loop 0)
;;

let read_file_prefix ~max_chars path =
  try
    In_channel.with_open_text path (fun ic ->
      let content = In_channel.input_all ic in
      if String.length content <= max_chars
      then Ok content
      else Ok (String.sub content 0 max_chars ^ "\n...[truncated]"))
  with
  | Sys_error msg -> Error msg
;;

let list_skills ~skills_root =
  if not (Sys.file_exists skills_root && Sys.is_directory skills_root)
  then []
  else
    Sys.readdir skills_root
    |> Array.to_list
    |> List.filter (fun entry ->
         let skill_md = Filename.concat (Filename.concat skills_root entry) "SKILL.md" in
         Sys.file_exists skill_md)
    |> List.sort String.compare
;;

let probe_tool_specs () : Yojson.Safe.t list =
  [ `Assoc
      [ "name", `String "masc_probe_ping"
      ; "description", `String "MASC builtin probe tool. Echoes the provided nonce with MASC_PONG:<nonce>."
      ; ( "inputSchema"
        , `Assoc
            [ "type", `String "object"
            ; ( "properties"
              , `Assoc
                  [ ( "nonce"
                    , `Assoc
                        [ "type", `String "string"
                        ; "description", `String "Exact probe nonce to echo."
                        ] )
                  ] )
            ; "required", `List [ `String "nonce" ]
            ] )
      ]
  ; `Assoc
      [ "name", `String "keeper_skill"
      ; "description", `String "Discover or read MASC skills from .agents/skills. Pass action='list' or action='read' with skill_name."
      ; ( "inputSchema"
        , `Assoc
            [ "type", `String "object"
            ; ( "properties"
              , `Assoc
                  [ ( "action"
                    , `Assoc
                        [ "type", `String "string"
                        ; "enum", `List [ `String "list"; `String "read" ]
                        ; "description", `String "Whether to list available skills or read a named skill."
                        ] )
                  ; ( "skill_name"
                    , `Assoc
                        [ "type", `String "string"
                        ; "description", `String "Skill directory name when action='read' (e.g. ocaml-coding)."
                        ] )
                  ] )
            ; "required", `List [ `String "action" ]
            ] )
      ]
  ]
;;

let json_string_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String s) -> Some s
     | Some _ | None -> None)
  | _ -> None
;;

let mcp_phase_to_string = function
  | Runtime_official_client_mcp.Awaiting_initialize -> "awaiting_initialize"
  | Runtime_official_client_mcp.Awaiting_initialized -> "awaiting_initialized"
  | Runtime_official_client_mcp.Ready -> "ready"
;;

let default_model_for_driver = function
  | Runtime_acp_client.Antigravity -> Some "gemini-3.8-flash-high"
  | Runtime_acp_client.Kimi_code -> None
  | Runtime_acp_client.Mistral_vibe -> None
  | Runtime_acp_client.Muse_code -> None
;;

let parse_posture raw =
  match String.lowercase_ascii (String.trim raw) with
  | "none" | "native_none" -> Ok Runtime_native_tools.Native_none
  | "read" | "native_read" -> Ok Runtime_native_tools.Native_read
  | "full" | "native_full" -> Ok Runtime_native_tools.Native_full
  | other ->
    Error (Printf.sprintf "unknown posture %S (expected none, read, or full)" other)
;;

(* [none] where the client can enforce it, the [read] floor where it cannot:
   the posture a Keeper on that client resolves to. *)
let default_posture (driver : Runtime_acp_client.driver) =
  Runtime_native_tools.degrade_on_admission
    ~posture:Runtime_native_tools.Native_none
    ~none_supported:
      (Runtime_acp_client.profile_of_driver driver).Runtime_acp_client.enforces_native_none
    ()
;;

let probe_one_driver ~env ~cwd ~timeout_s ~model_override ~posture (driver : Runtime_acp_client.driver)
  : driver_report
  =
  let driver_name = Runtime_acp_client.driver_to_string driver in
  let nonce = Printf.sprintf "masc-acp-%s-ok" driver_name in
  let expected_pong = "MASC_PONG:" ^ nonce in
  let skills_root = Filename.concat cwd ".agents/skills" in
  let ping_called = Atomic.make false in
  let ping_nonce_matched = Atomic.make false in
  let skill_called = Atomic.make false in
  let handle_tool ~name ~call_id:_ ~arguments =
    match name with
    | "masc_probe_ping" ->
      Atomic.set ping_called true;
      let received = Option.value (json_string_field "nonce" arguments) ~default:"" in
      if String.equal (String.trim received) nonce
      then Atomic.set ping_nonce_matched true;
      let reply = "MASC_PONG:" ^ received in
      Some
        { Runtime_official_client_mcp_http.outcome =
            { Runtime_official_client_mcp.success = true
            ; content = reply
            ; content_blocks = None
            }
        ; after_response_sent = ignore
        ; stop = None
        }
    | "keeper_skill" ->
      Atomic.set skill_called true;
      let action = Option.value (json_string_field "action" arguments) ~default:"list" in
      let outcome =
        match action with
        | "list" ->
          let skills = list_skills ~skills_root in
          { Runtime_official_client_mcp.success = true
          ; content = Printf.sprintf "Available MASC skills: %s" (String.concat ", " skills)
          ; content_blocks = None
          }
        | "read" ->
          let skill_name =
            Option.value (json_string_field "skill_name" arguments) ~default:target_skill_name
          in
          let skill_path =
            Filename.concat (Filename.concat skills_root skill_name) "SKILL.md"
          in
          (match read_file_prefix ~max_chars:max_skill_read_chars skill_path with
           | Ok body ->
             { Runtime_official_client_mcp.success = true
             ; content = body
             ; content_blocks = None
             }
           | Error msg ->
             { Runtime_official_client_mcp.success = false
             ; content = "Failed to read skill: " ^ msg
             ; content_blocks = None
             })
        | other ->
          { Runtime_official_client_mcp.success = false
          ; content = "Unknown action: " ^ other
          ; content_blocks = None
          }
      in
      Some
        { Runtime_official_client_mcp_http.outcome
        ; after_response_sent = ignore
        ; stop = None
        }
    | _ -> None
  in
  let tool_execution_mode ~name ~arguments:_ =
    match name with
    | "masc_probe_ping" | "keeper_skill" -> Some Agent_core.Tool_contract.Concurrent
    | _ -> None
  in
  try
    Eio.Switch.run (fun sw ->
      let bridge =
        Runtime_official_client_mcp_http.start
          ~sw
          ~net:(Eio.Stdenv.net env)
          ~secure_random:(Eio.Stdenv.secure_random env)
          ~server_name:mcp_server_name
          ~tool_specs:probe_tool_specs
          ~tool_execution_mode
          ~call_tool:handle_tool
          ()
      in
      let { Runtime_official_client_mcp_http.url; headers } =
        Runtime_official_client_mcp_http.endpoint bridge
      in
      let mcp_server : Runtime_acp_client.mcp_http_server =
        { name = mcp_server_name; url; headers }
      in
      let acp_cwd_result =
        match posture with
        | Runtime_native_tools.Native_none ->
          Runtime_acp_client.create_isolated_workspace ~sw ~prefix:"probe" ()
        | Runtime_native_tools.Native_read | Runtime_native_tools.Native_full -> Ok cwd
      in
      let start_result =
        match acp_cwd_result with
        | Error err -> Error err
        | Ok acp_cwd ->
          let base_cfg = Runtime_acp_client.default_config ~driver ~cwd:acp_cwd in
          let skills_dirs =
            match posture with
            | Runtime_native_tools.Native_none -> []
            | Runtime_native_tools.Native_read | Runtime_native_tools.Native_full ->
              if Sys.file_exists skills_root && Sys.is_directory skills_root
              then [ skills_root ]
              else []
          in
          let config : Runtime_acp_client.config =
            { base_cfg with
              skills_dirs
            ; dangerously_skip_permissions = (posture = Runtime_native_tools.Native_full)
            }
          in
          let proc_mgr =
            Runtime_acp_client.foreground_process_mgr
              ~clock:(Eio.Stdenv.clock env)
              ~grace_seconds:5.0
              ()
          in
          Runtime_acp_client.start
            ~sw
            ~proc_mgr
            ~clock:(Eio.Stdenv.clock env)
            ~fs:(Eio.Stdenv.fs env)
            ~config
            ~mcp_server
            ~native_posture:posture
            ()
          |> Result.map (fun client -> client, acp_cwd)
      in
      match start_result with
      | Error err ->
        { driver
        ; posture
        ; passed = false
        ; init_ms = 0
        ; session_id = None
        ; negotiated_model = None
        ; negotiated_mode = None
        ; session_reused = false
        ; mcp_phase = mcp_phase_to_string (Runtime_official_client_mcp_http.client_phase bridge)
        ; ping_tool_called = false
        ; ping_reply_verified = false
        ; skill_tool_called = false
        ; skill_reply_verified = false
        ; turn1 = None
        ; turn2 = None
        ; error = Some (Runtime_acp_client.error_to_string err)
        }
      | Ok (client, acp_cwd) ->
        let init_ms = Runtime_acp_client.init_latency_ms client in
        let profile = Runtime_acp_client.profile_of_driver driver in
        let system_prompt_append =
          match profile.system_prompt_channel with
          | Runtime_acp_client.Meta_antigravity_append ->
            Some
              "You are a MASC Keeper running a live ACP verification probe. Follow instructions concisely and call requested MCP tools directly."
          | Runtime_acp_client.Framed_in_first_prompt -> None
        in
        let model =
          (match model_override with
           | Some _ as m -> m
           | None -> default_model_for_driver driver)
          |> Option.map Runtime_acp_client.model_selection_of_string
        in
        let mode = Runtime_acp_client.mode_of_posture driver posture in
        match
          Runtime_acp_client.new_session
            client
            ~cwd:acp_cwd
            ?system_prompt_append
            ~mcp_server
            ~mode
            ?model
            ()
        with
        | Error err ->
          Runtime_acp_client.close client;
          { driver
          ; posture
          ; passed = false
          ; init_ms
          ; session_id = None
          ; negotiated_model = None
          ; negotiated_mode = None
          ; session_reused = false
          ; mcp_phase =
              mcp_phase_to_string (Runtime_official_client_mcp_http.client_phase bridge)
          ; ping_tool_called = false
          ; ping_reply_verified = false
          ; skill_tool_called = false
          ; skill_reply_verified = false
          ; turn1 = None
          ; turn2 = None
          ; error = Some (Runtime_acp_client.error_to_string err)
          }
        | Ok session ->
          let session_id = session.session_id in
          let negotiated_model = session.current_model_id in
          let negotiated_mode = session.current_mode_id in
          let permission_policy =
            Runtime_acp_client.permission_policy_of_posture
              ~mcp_server_name
              ~allowed_tool_names:[ "masc_probe_ping"; "keeper_skill" ]
              posture
          in
          let turn1_prompt =
            Printf.sprintf
              "Call the MCP tool `masc_probe_ping` (from the `masc` MCP server) with argument {\"nonce\": %S}. After receiving the tool result, reply with ONLY that exact tool result string and nothing else."
              nonce
          in
          let t1_start = now_ms () in
          let turn1_res =
            Runtime_acp_client.prompt
              client
              ~session_id
              ~blocks:[ Runtime_acp_client.Text_block turn1_prompt ]
              ~timeout_s:(Some timeout_s)
              ~permission_policy
              ()
          in
          let t1_ms = max 0 (now_ms () - t1_start) in
          (match turn1_res with
           | Error err ->
             Runtime_acp_client.close client;
             { driver
             ; posture
             ; passed = false
             ; init_ms
             ; session_id = Some session_id
             ; negotiated_model
             ; negotiated_mode
             ; session_reused = false
             ; mcp_phase =
                 mcp_phase_to_string (Runtime_official_client_mcp_http.client_phase bridge)
             ; ping_tool_called = Atomic.get ping_called && Atomic.get ping_nonce_matched
             ; ping_reply_verified = false
             ; skill_tool_called = false
             ; skill_reply_verified = false
             ; turn1 = None
             ; turn2 = None
             ; error = Some ("turn1: " ^ Runtime_acp_client.error_to_string err)
             }
           | Ok r1 ->
             let turn1_report : turn_report =
               { latency_ms = t1_ms
               ; stop_reason = Runtime_acp_client.stop_reason_to_string r1.stop_reason
               ; text_preview = truncate_preview r1.text
               ; usage = r1.usage
               }
             in
             let ping_reply_verified =
               contains_case_insensitive ~needle:expected_pong r1.text
             in
             (* Turn 2 on the SAME persistent process and SAME session_id *)
             let turn2_prompt =
               Printf.sprintf
                 "In this same session, call the MCP tool `keeper_skill` (from the `masc` MCP server) with {\"action\": \"read\", \"skill_name\": %S}. Then reply in one short line containing the skill name %S and the exact OCaml version mentioned in that skill."
                 target_skill_name
                 target_skill_name
             in
             let t2_start = now_ms () in
             let turn2_res =
               Runtime_acp_client.prompt
                 client
                 ~session_id
                 ~blocks:[ Runtime_acp_client.Text_block turn2_prompt ]
                 ~timeout_s:(Some timeout_s)
                 ~permission_policy
                 ()
             in
             let t2_ms = max 0 (now_ms () - t2_start) in
             let mcp_phase =
               mcp_phase_to_string (Runtime_official_client_mcp_http.client_phase bridge)
             in
             Runtime_acp_client.close client;
             (match turn2_res with
              | Error err ->
                { driver
                ; posture
                ; passed = false
                ; init_ms
                ; session_id = Some session_id
                ; negotiated_model
                ; negotiated_mode
                ; session_reused = false
                ; mcp_phase
                ; ping_tool_called = Atomic.get ping_called && Atomic.get ping_nonce_matched
                ; ping_reply_verified
                ; skill_tool_called = Atomic.get skill_called
                ; skill_reply_verified = false
                ; turn1 = Some turn1_report
                ; turn2 = None
                ; error = Some ("turn2: " ^ Runtime_acp_client.error_to_string err)
                }
              | Ok r2 ->
                let turn2_report : turn_report =
                  { latency_ms = t2_ms
                  ; stop_reason = Runtime_acp_client.stop_reason_to_string r2.stop_reason
                  ; text_preview = truncate_preview r2.text
                  ; usage = r2.usage
                  }
                in
                let skill_reply_verified =
                  contains_case_insensitive ~needle:"ocaml-coding" r2.text
                  && contains_case_insensitive ~needle:"5.5" r2.text
                in
                let ping_ok =
                  Atomic.get ping_called
                  && Atomic.get ping_nonce_matched
                  && ping_reply_verified
                in
                let skill_ok = Atomic.get skill_called && skill_reply_verified in
                let session_reused = String.equal r1.session_id r2.session_id in
                { driver
                ; posture
                ; passed = ping_ok && skill_ok && session_reused
                ; init_ms
                ; session_id = Some session_id
                ; negotiated_model
                ; negotiated_mode
                ; session_reused
                ; mcp_phase
                ; ping_tool_called = Atomic.get ping_called && Atomic.get ping_nonce_matched
                ; ping_reply_verified
                ; skill_tool_called = Atomic.get skill_called
                ; skill_reply_verified
                ; turn1 = Some turn1_report
                ; turn2 = Some turn2_report
                ; error = None
                })))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    { driver
    ; posture
    ; passed = false
    ; init_ms = 0
    ; session_id = None
    ; negotiated_model = None
    ; negotiated_mode = None
    ; session_reused = false
    ; mcp_phase = "error"
    ; ping_tool_called = Atomic.get ping_called && Atomic.get ping_nonce_matched
    ; ping_reply_verified = false
    ; skill_tool_called = Atomic.get skill_called
    ; skill_reply_verified = false
    ; turn1 = None
    ; turn2 = None
    ; error = Some (Printexc.to_string exn)
    }
;;

let usage_to_yojson (u : Runtime_acp_client.usage) : Yojson.Safe.t =
  `Assoc
    [ "input_tokens", `Int u.input_tokens
    ; "output_tokens", `Int u.output_tokens
    ; "cached_read_tokens", `Int u.cached_read_tokens
    ; "cached_write_tokens", `Int u.cached_write_tokens
    ; "thought_tokens", `Int u.thought_tokens
    ; "total_tokens", `Int u.total_tokens
    ; ( "context_used"
      , match u.context_used with Some n -> `Int n | None -> `Null )
    ; ( "context_size"
      , match u.context_size with Some n -> `Int n | None -> `Null )
    ]
;;

let normalized_usage_to_yojson (u : Runtime_acp_client.normalized_usage) : Yojson.Safe.t =
  `Assoc
    [ "input_tokens", `Int u.input_tokens
    ; "output_tokens", `Int u.output_tokens
    ; "cache_creation_input_tokens", `Int u.cache_creation_input_tokens
    ; "cache_read_input_tokens", `Int u.cache_read_input_tokens
    ]
;;

let turn_report_to_yojson ~driver (t : turn_report) : Yojson.Safe.t =
  `Assoc
    [ "latency_ms", `Int t.latency_ms
    ; "stop_reason", `String t.stop_reason
    ; "text_preview", `String t.text_preview
    ; "usage", usage_to_yojson t.usage
    ; ( "normalized_usage"
      , normalized_usage_to_yojson (Runtime_acp_client.normalize_usage driver t.usage) )
    ]
;;

let driver_report_to_yojson (r : driver_report) : Yojson.Safe.t =
  `Assoc
    [ "driver", `String (Runtime_acp_client.driver_to_string r.driver)
    ; "posture", `String (Runtime_native_tools.to_string r.posture)
    ; "passed", `Bool r.passed
    ; "init_ms", `Int r.init_ms
    ; "session_id", (match r.session_id with Some s -> `String s | None -> `Null)
    ; "negotiated_model", (match r.negotiated_model with Some s -> `String s | None -> `Null)
    ; "negotiated_mode", (match r.negotiated_mode with Some s -> `String s | None -> `Null)
    ; "session_reused", `Bool r.session_reused
    ; "mcp_phase", `String r.mcp_phase
    ; "ping_tool_called", `Bool r.ping_tool_called
    ; "ping_reply_verified", `Bool r.ping_reply_verified
    ; "skill_tool_called", `Bool r.skill_tool_called
    ; "skill_reply_verified", `Bool r.skill_reply_verified
    ; ( "turn1"
      , match r.turn1 with
        | Some t -> turn_report_to_yojson ~driver:r.driver t
        | None -> `Null )
    ; ( "turn2"
      , match r.turn2 with
        | Some t -> turn_report_to_yojson ~driver:r.driver t
        | None -> `Null )
    ; "error", (match r.error with Some e -> `String e | None -> `Null)
    ]
;;

let driver_names =
  List.map Runtime_acp_client.driver_to_string Runtime_acp_client.all_drivers
;;

let parse_drivers raw =
  let parts =
    String.split_on_char ',' raw
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      (match Runtime_acp_client.driver_of_string item with
       | Some d -> go (d :: acc) rest
       | None ->
         Error
           (Printf.sprintf
              "unknown ACP driver %S (expected one of %s)"
              item
              (String.concat ", " driver_names)))
  in
  go [] parts
;;

let () =
  let drivers_arg = ref (String.concat "," driver_names) in
  let cwd_arg = ref (Sys.getcwd ()) in
  let timeout_s_arg = ref default_turn_timeout_s in
  let model_arg = ref "" in
  let posture_arg = ref "" in
  let json_only = ref false in
  let specs =
    [ ( "--drivers"
      , Arg.Set_string drivers_arg
      , "Comma-separated ACP drivers (default: every driver)" )
    ; "--cwd", Arg.Set_string cwd_arg, "Working directory with .agents/skills (default: cwd)"
    ; "--timeout-s", Arg.Set_float timeout_s_arg, "Per-turn idle timeout in seconds (default: 120)"
    ; "--model", Arg.Set_string model_arg, "Optional model override for all selected drivers"
    ; ( "--posture"
      , Arg.Set_string posture_arg
      , "Native tool posture: none, read, or full (default: none, or read for a driver \
         that cannot enforce none)" )
    ; "--json", Arg.Set json_only, "Emit JSON report only"
    ]
  in
  Arg.parse specs (fun _ -> ()) "masc-acp-probe [OPTIONS]";
  let posture_override =
    if String.trim !posture_arg = ""
    then None
    else (
      match parse_posture !posture_arg with
      | Ok p -> Some p
      | Error msg ->
        Printf.eprintf "masc-acp-probe: %s\n" msg;
        exit 2)
  in
  let drivers =
    match parse_drivers !drivers_arg with
    | Ok (_ :: _ as ds) -> ds
    | Ok [] ->
      Printf.eprintf "masc-acp-probe: at least one driver is required\n";
      exit 2
    | Error msg ->
      Printf.eprintf "masc-acp-probe: %s\n" msg;
      exit 2
  in
  let model_override =
    let m = String.trim !model_arg in
    if m = "" then None else Some m
  in
  let reports =
    Eio_main.run (fun env ->
      List.map
        (fun driver ->
           let posture =
             match posture_override with
             | Some p -> p
             | None -> default_posture driver
           in
           if not !json_only
           then
             Printf.eprintf
               "[masc-acp-probe] running live 2-turn probe for %s (posture=%s)...\n%!"
               (Runtime_acp_client.driver_to_string driver)
               (Runtime_native_tools.to_string posture);
           probe_one_driver
             ~env
             ~cwd:!cwd_arg
             ~timeout_s:!timeout_s_arg
             ~model_override
             ~posture
             driver)
        drivers)
  in
  let all_passed = List.for_all (fun (r : driver_report) -> r.passed) reports in
  let json_payload =
    `Assoc
      [ "all_passed", `Bool all_passed
      ; "drivers", `List (List.map driver_report_to_yojson reports)
      ]
  in
  print_endline (Yojson.Safe.pretty_to_string json_payload);
  if not all_passed then exit 1
;;
