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
  let module U = Yojson.Safe.Util in
  Buffer.add_string buf (Printf.sprintf "Agent: %s (Role: %s)\n"
    (status |> U.member "agent" |> U.to_string)
    (status |> U.member "role" |> U.to_string));
  Buffer.add_string buf (Printf.sprintf "Burst remaining: %d\n\n"
    (status |> U.member "burst_remaining" |> U.to_int));
  Buffer.add_string buf "Categories:\n";
  status |> U.member "categories" |> U.to_list |> List.iter (fun cat ->
    let cat_name = cat |> U.member "category" |> U.to_string in
    let current = cat |> U.member "current" |> U.to_int in
    let cat_limit = cat |> U.member "limit" |> U.to_int in
    let remaining = cat |> U.member "remaining" |> U.to_int in
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

(* Dispatch handler *)
let dispatch ctx ~name ~args =
  match name with
  | "masc_rate_limit_status" -> Some (handle_rate_limit_status ctx args)
  | "masc_rate_limit_config" -> Some (handle_rate_limit_config ctx args)
  | _ -> None
