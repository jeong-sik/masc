(** Keeper_extend_turns — Self-extending turn budget tool for keeper Agent.run.

    Creates an [extend_turns] {!Agent_sdk.Tool.t} that lets the keeper request
    more turns at runtime.  The tool enforces a per-session extension limit
    and an absolute ceiling on total turns. *)

(** Default absolute ceiling on total turns.
    Keepers typically run 50-100 turns per session. 200 is ~2x the worst-case
    observed session length, providing headroom while preventing runaway loops.
    Above 200 turns, the keeper is likely stuck or in a degenerate retry pattern.
    This value is the fallback when no explicit ceiling is provided by the caller. *)
let default_ceiling = 200

(** Maximum turns that can be requested in a single [extend_turns] call.
    Typical extension requests are 3-5 turns. 20 is generous enough for
    burst work (e.g., processing multiple board posts in sequence) while
    preventing a single request from consuming a large fraction of the ceiling. *)
let max_per_request = 20

(** Maximum number of extension requests per session.
    Combined with [max_per_request], this caps total extensions at 10 * 20 = 200
    turns, which aligns with [default_ceiling]. This prevents infinite
    self-extension while allowing gradual budget growth as the keeper discovers
    more work. Each extension also requires a [reason], creating an audit trail. *)
let max_extensions_per_session = 10

let make ~agent_ref ~max_turns ?ceiling () : Agent_sdk.Tool.t =
  let ceiling = match ceiling with Some c -> c | None -> max max_turns default_ceiling in
  let budget_current = ref max_turns in
  let budget_extensions = ref 0 in
  let open Agent_sdk in
  Tool.create
    ~name:"extend_turns"
    ~description:"Request additional turns when you need more time. \
                   Guardrails check cost and idle before granting."
    ~parameters:[
      { Types.name = "additional_turns";
        description = Printf.sprintf "Number of additional turns (1-%d)" max_per_request;
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
      let additional = max 1 (min additional max_per_request) in
      if !budget_extensions >= max_extensions_per_session then
        Ok { Types.content = Printf.sprintf
          "Denied: extension limit (%d) reached. Budget: %d/%d."
          max_extensions_per_session !budget_current ceiling }
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
            "Granted %d turns. Budget: %d (ceiling: %d). Extensions: %d/%d. Reason: %s"
            granted new_max ceiling !budget_extensions max_extensions_per_session reason }
        end)
