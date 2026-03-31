(** Tool_rate_limit - Rate limiting status and configuration handlers *)

type context = {
  config: Room.config;
  agent_name: string;
  registry: Session.registry;
}

(* Handle masc_rate_limit_status *)
let handle_rate_limit_status ctx _args =
  let role = match Auth.load_credential ctx.config.base_path ctx.agent_name with
    | Some cred -> cred.role
    | None -> Types.Worker
  in
  let status = Session.get_rate_limit_status ctx.registry ~agent_name:ctx.agent_name ~role in
  let buf = Buffer.create 512 in
  Buffer.add_string buf "📊 **Rate Limit Status**\n";
  Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
  let open Yojson.Safe.Util in
  Buffer.add_string buf (Printf.sprintf "Agent: %s (Role: %s)\n"
    (status |> member "agent" |> to_string)
    (status |> member "role" |> to_string));
  Buffer.add_string buf (Printf.sprintf "Burst remaining: %d\n\n"
    (status |> member "burst_remaining" |> to_int));
  Buffer.add_string buf "Categories:\n";
  status |> member "categories" |> to_list |> List.iter (fun cat ->
    let cat_name = cat |> member "category" |> to_string in
    let current = cat |> member "current" |> to_int in
    let cat_limit = cat |> member "limit" |> to_int in
    let remaining = cat |> member "remaining" |> to_int in
    Buffer.add_string buf (Printf.sprintf "  • %s: %d/%d (remaining: %d)\n"
      cat_name current cat_limit remaining)
  );
  (true, Buffer.contents buf)

(* Handle masc_rate_limit_config *)
let handle_rate_limit_config ctx _args =
  let cfg = ctx.registry.Session.config in
  let buf = Buffer.create 512 in
  Buffer.add_string buf "⚙️ **Rate Limit Configuration**\n";
  Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
  Buffer.add_string buf (Printf.sprintf "Base limit: %d/min\n" cfg.per_minute);
  Buffer.add_string buf (Printf.sprintf "Burst allowed: %d\n\n" cfg.burst_allowed);
  Buffer.add_string buf "Category limits:\n";
  Buffer.add_string buf (Printf.sprintf "  • Broadcast: %d/min\n" cfg.broadcast_per_minute);
  Buffer.add_string buf (Printf.sprintf "  • Task ops: %d/min\n\n" cfg.task_ops_per_minute);
  Buffer.add_string buf "Role multipliers:\n";
  Buffer.add_string buf (Printf.sprintf "  • Reader: %.1fx\n" cfg.reader_multiplier);
  Buffer.add_string buf (Printf.sprintf "  • Worker: %.1fx\n" cfg.worker_multiplier);
  Buffer.add_string buf (Printf.sprintf "  • Admin: %.1fx\n" cfg.admin_multiplier);
  (true, Buffer.contents buf)

let schemas : Types.tool_schema list = [
  {
    name = "masc_rate_limit_status";
    description = "Get your current rate limit status. Shows remaining requests per category (general, broadcast, task ops, file locks) and burst tokens.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
  {
    name = "masc_rate_limit_config";
    description = "Get or update rate limit configuration (admin only). Shows limits per category and role multipliers.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("per_minute", `Assoc [
          ("type", `String "integer");
          ("description", `String "Base requests per minute (default: 10)");
        ]);
        ("burst_allowed", `Assoc [
          ("type", `String "integer");
          ("description", `String "Burst tokens available (default: 5)");
        ]);
        ("broadcast_per_minute", `Assoc [
          ("type", `String "integer");
          ("description", `String "Broadcast operations per minute (default: 15)");
        ]);
        ("task_ops_per_minute", `Assoc [
          ("type", `String "integer");
          ("description", `String "Task operations per minute (default: 30)");
        ]);
      ]);
    ];
  };
]

(* Dispatch handler *)
let dispatch ctx ~name ~args =
  match name with
  | "masc_rate_limit_status" -> Some (handle_rate_limit_status ctx args)
  | "masc_rate_limit_config" -> Some (handle_rate_limit_config ctx args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_rate_limit
           ~input_schema:s.input_schema
           ()))
    schemas
