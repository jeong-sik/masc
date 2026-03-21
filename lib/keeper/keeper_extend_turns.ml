(** Keeper_extend_turns — Self-extending turn budget tool for keeper Agent.run.

    Creates an [extend_turns] {!Agent_sdk.Tool.t} that lets the keeper request
    more turns at runtime.  The tool enforces a per-session extension limit
    (10 extensions) and an absolute ceiling on total turns. *)

let make ~agent_ref ~max_turns ?ceiling () : Agent_sdk.Tool.t =
  let ceiling = match ceiling with Some c -> c | None -> max max_turns 200 in
  let budget_current = ref max_turns in
  let budget_extensions = ref 0 in
  let open Agent_sdk in
  Tool.create
    ~name:"extend_turns"
    ~description:"Request additional turns when you need more time. \
                   Guardrails check cost and idle before granting."
    ~parameters:[
      { Types.name = "additional_turns";
        description = "Number of additional turns (1-20)";
        param_type = Types.Integer; required = true };
      { Types.name = "reason";
        description = "Why more turns are needed";
        param_type = Types.String; required = true };
    ]
    (fun input ->
      let additional =
        try Yojson.Safe.Util.(member "additional_turns" input |> to_int)
        with Eio.Cancel.Cancelled _ as e -> raise e | _ -> 5 in
      let reason =
        try Yojson.Safe.Util.(member "reason" input |> to_string)
        with Eio.Cancel.Cancelled _ as e -> raise e | _ -> "unspecified" in
      let additional = max 1 (min additional 20) in
      if !budget_extensions >= 10 then
        Ok { Types.content = Printf.sprintf
          "Denied: extension limit (10) reached. Budget: %d/%d."
          !budget_current ceiling }
      else
        let new_max = min (!budget_current + additional) ceiling in
        let granted = new_max - !budget_current in
        if granted <= 0 then
          Ok { Types.content = Printf.sprintf
            "Denied: at ceiling (%d/%d)." !budget_current ceiling }
        else begin
          budget_current := new_max;
          incr budget_extensions;
          (match !agent_ref with
           | Some agent ->
             let state = Agent_sdk.Agent.state agent in
             Agent_sdk.Agent.set_state agent
               { state with config =
                   { state.config with max_turns = new_max } }
           | None -> ());
          Ok { Types.content = Printf.sprintf
            "Granted %d turns. Budget: %d (ceiling: %d). Extensions: %d/10. Reason: %s"
            granted new_max ceiling !budget_extensions reason }
        end)
