(** External agent: CLI subprocess manager for heterogeneous fleet orchestration.
    Wraps CLI tools (Claude Code, Codex, Gemini CLI) as fleet members
    via Eio.Process subprocess management. *)

type cli_kind =
  | Claude_code
  | Codex
  | Gemini_cli
  | Custom of string

type cli_config = {
  kind : cli_kind;
  name : string;
  binary : string;
  args : string list;
  env : (string * string) list;
  timeout_s : float;
}

let claude_code ?(name = "claude-code") () =
  { kind = Claude_code; name; binary = "claude";
    args = ["--print"]; env = []; timeout_s = 120.0 }

let codex ?(name = "codex") () =
  { kind = Codex; name; binary = "codex";
    args = ["--quiet"; "--full-auto"]; env = []; timeout_s = 120.0 }

let gemini_cli ?(name = "gemini-cli") () =
  { kind = Gemini_cli; name; binary = "gemini";
    args = ["-p"]; env = []; timeout_s = 120.0 }

let build_env extras =
  let parent = Unix.environment () |> Array.to_list in
  let extra = List.map (fun (k, v) -> k ^ "=" ^ v) extras in
  Array.of_list (parent @ extra)

let run_cli ~sw:_ ~proc_mgr ~clock config ~prompt =
  let cmd = config.binary :: (config.args @ [prompt]) in
  try
    Eio.Fiber.first
      (fun () ->
        let out = match config.env with
          | [] ->
            Eio.Process.parse_out proc_mgr Eio.Buf_read.take_all cmd
          | _ ->
            let env = build_env config.env in
            Eio.Process.parse_out proc_mgr Eio.Buf_read.take_all ~env cmd
        in
        Ok out)
      (fun () ->
        Eio.Time.sleep clock config.timeout_s;
        Error (Printf.sprintf "Timeout after %.0fs for %s"
          config.timeout_s config.name))
  with
  | Eio.Cancel.Cancelled _ as ex -> raise ex
  | Eio.Io _ as ex ->
    Error (Printf.sprintf "%s process error: %s"
      config.name (Printexc.to_string ex))
  | ex ->
    Error (Printf.sprintf "%s unexpected error: %s"
      config.name (Printexc.to_string ex))

let run_with_masc ~sw ~proc_mgr ~clock ~net ~masc_url config ~goal =
  try
    let client = Agent_swarm_client.create_managed ~base_url:masc_url
      ~agent_name:config.name ~net in
    let _joined = Agent_swarm_client.join ~sw client in
    Fun.protect ~finally:(fun () ->
      (try match Agent_swarm_client.leave ~sw client with
        | Ok _ -> ()
        | Error msg -> Log.Misc.error "[swarm] leave failed: %s" msg
      with exn -> Log.Misc.error "[swarm] leave error: %s" (Printexc.to_string exn))
    ) (fun () ->
      (match Agent_swarm_client.broadcast ~sw client
        ~message:(Printf.sprintf "Starting: %s" goal) with
       | Ok _ -> () | Error msg -> Log.Misc.error "[swarm] broadcast failed: %s" msg);
      let result = run_cli ~sw ~proc_mgr ~clock config ~prompt:goal in
      let summary = match result with
        | Ok out ->
          if String.length out > 200 then String.sub out 0 200 ^ "..."
          else out
        | Error e -> "Error: " ^ e
      in
      (match Agent_swarm_client.broadcast ~sw client
        ~message:(Printf.sprintf "Done: %s" summary) with
       | Ok _ -> () | Error msg -> Log.Misc.error "[swarm] broadcast failed: %s" msg);
      result
    )
  with
  | Eio.Cancel.Cancelled _ as ex -> raise ex
  | ex ->
    Error (Printf.sprintf "%s MASC error: %s"
      config.name (Printexc.to_string ex))
