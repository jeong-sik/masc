(** Hat tools - Agent role management *)

open Tool_args

type context = {
  config: Room.config;
  agent_name: string;
}

type result = bool * string

let handle_hat_wear ctx args =
  let hat_str = get_string args "hat" "builder" in
  let hat = Hat.of_string hat_str in
  let result = Hat.wear ~agent_name:ctx.agent_name hat in
  let _ = Room.broadcast ctx.config ~from_agent:ctx.agent_name
    ~content:(Printf.sprintf "%s %s" (Hat.to_emoji hat) result) in
  (true, result)

let handle_hat_status _ctx _args =
  let agents = Hat.list_all () in
  if agents = [] then
    (true, "🎩 No agents have worn hats yet")
  else begin
    let buf = Buffer.create 256 in
    Buffer.add_string buf "🎩 **Current Hats**\n";
    List.iter (fun (agent : Hat.hatted_agent) ->
      Buffer.add_string buf (Printf.sprintf "  %s %s: %s\n"
        (Hat.to_emoji agent.current_hat) agent.agent_name (Hat.to_string agent.current_hat))
    ) agents;
    (true, Buffer.contents buf)
  end

let schemas : Types.tool_schema list = [
  {
    name = "masc_hat_status";
    description = "Show current hat status for all agents. Displays which role each agent is currently using.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent requesting status");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };

  (* masc_hat_wear *)
  {
    name = "masc_hat_wear";
    description = "Assign a role hat (builder, reviewer, researcher, tester, architect, debugger, documenter) to specialize your behavior. \
Use when switching focus, e.g., from coding to reviewing. \
Pair with masc_hat_status to see all agents' current hats.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("hat", `Assoc [
          ("type", `String "string");
          ("description", `String "Hat to wear");
          ("enum", `List [
            `String "builder"; `String "reviewer"; `String "researcher";
            `String "tester"; `String "architect"; `String "debugger"; `String "documenter"
          ]);
          ("default", `String "builder");
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent wearing the hat");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };

]

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_hat_wear" -> Some (handle_hat_wear ctx args)
  | "masc_hat_status" -> Some (handle_hat_status ctx args)
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
           ~module_tag:Tool_dispatch.Mod_hat
           ~input_schema:s.input_schema
           ()))
    schemas
