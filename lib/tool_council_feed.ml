(** Tool_council_feed — Governance feed, runtime params, and set_param
    handlers extracted from Tool_council.

    These handlers are peripheral to the core governance petition/case/ruling
    flow and operate independently on Board, Runtime_params, and
    Governance_registry modules.

    @since 2.122.0 *)

open Tool_args
open Tool_council_json

module GV2 = Council.Governance_v2

type context = Tool_council_helpers.context = {
  base_path : string;
  agent_name : string;
  room_config : Room.config option;
}

type result = Tool_council_helpers.result

let handle_governance_feed ctx args =
  let filter = get_string args "filter" "decisions" |> String.lowercase_ascii in
  let limit = get_int args "limit" 20 in
  let items = ref [] in
  (* Parameter change audit trail *)
  if filter = "decisions" || filter = "all" then begin
    let audit = Runtime_params.recent_audit ~base_path:ctx.base_path limit in
    List.iter (fun entry ->
      items := `Assoc [ ("kind", `String "param_change"); ("data", entry) ] :: !items
    ) audit
  end;
  (* Active governance cases *)
  if filter = "decisions" || filter = "all" then begin
    let cases = GV2.list_cases ctx.base_path in
    let active = List.filter (fun (c : GV2.case_record) ->
      match c.status with GV2.Closed -> false | _ -> true) cases in
    List.iter (fun c ->
      items := `Assoc [ ("kind", `String "case"); ("data", case_json c) ] :: !items
    ) active
  end;
  (* Human board posts *)
  if filter = "human_only" || filter = "all" then begin
    let posts = Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent ~limit () in
    let human = List.filter (fun (p : Board.post) ->
      Board.classify_post_kind p = Board.Human_post) posts in
    List.iter (fun p ->
      items := `Assoc [
        ("kind", `String "human_post");
        ("data", Board.post_to_yojson p);
      ] :: !items
    ) human
  end;
  (* Reverse to restore source order (cons reverses each batch) then take *)
  let all = List.rev !items in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: rest -> x :: take (n - 1) rest
  in
  let result = take limit all in
  (true, Yojson.Safe.pretty_to_string (`List result))

let handle_runtime_params _ctx _args =
  let params = Runtime_params.registry () in
  let meta_to_json = function
    | None -> `Null
    | Some (m : Runtime_params.param_meta) ->
        `Assoc ([
          ("description", `String m.description);
          ("value_type", `String m.value_type);
        ]
        @ (match m.min_value with Some v -> [("min_value", v)] | None -> [])
        @ (match m.max_value with Some v -> [("max_value", v)] | None -> []))
  in
  let items =
    List.map
      (fun (key, current, default, has_override, meta) ->
        `Assoc
          [
            ("key", `String key);
            ("current", current);
            ("default", default);
            ("has_override", `Bool has_override);
            ("meta", meta_to_json meta);
          ])
      params
  in
  let surfaces = Governance_registry.surfaces_json () in
  let json =
    `Assoc
      [
        ("parameters", `List items);
        ("surfaces", surfaces);
      ]
  in
  (true, Yojson.Safe.pretty_to_string json)

let handle_set_param ~submit_petition ctx args =
  let param_key = get_string args "param_key" "" |> String.trim in
  let value_json =
    match Yojson.Safe.Util.member "value" args with
    | `Null -> None
    | v -> Some v
  in
  let reason = get_string args "reason" "" in
  if param_key = "" then (false, "param_key is required")
  else
    match value_json with
    | None -> (false, "value is required")
    | Some value ->
        let risk =
          Governance_registry.surfaces
          |> List.find_opt (fun (s : Governance_registry.surface) ->
               List.mem param_key s.param_keys)
          |> Option.map (fun (s : Governance_registry.surface) -> s.risk)
          |> Option.value ~default:"low"
        in
        if risk = "high" then
          let title =
            Printf.sprintf "Set %s = %s%s" param_key
              (Yojson.Safe.to_string value)
              (if reason <> "" then " (" ^ reason ^ ")" else "")
          in
          let petition_args =
            `Assoc
              [
                ("title", `String title);
                ("origin", `String "agent");
                ("subject_type", `String "param_change");
                ("risk_class", `String "high");
                ( "requested_action",
                  `Assoc
                    [
                      ("action_type", `String "set_param");
                      ( "payload",
                        `Assoc
                          [
                            ("param_key", `String param_key);
                            ("value", value);
                          ] );
                    ] );
                ("source_refs", `List [ `String param_key ]);
              ]
          in
          let (ok, msg) = submit_petition ctx petition_args in
          if ok then
            (true, Printf.sprintf "High-risk parameter. Governance petition created.\n%s" msg)
          else
            (false, Printf.sprintf "Failed to create governance petition: %s" msg)
        else begin
          let old_value =
            match Runtime_params.registry ()
                  |> List.find_opt (fun (k, _, _, _, _) -> k = param_key) with
            | Some (_, current, _, _, _) -> current
            | None -> `Null
          in
          match Runtime_params.set_by_key param_key value with
          | Error msg -> (false, Printf.sprintf "set_param failed: %s" msg)
          | Ok () ->
              Runtime_params.persist ~base_path:ctx.base_path;
              Runtime_params.record_audit ~base_path:ctx.base_path
                ~key:param_key ~old_value ~new_value:value
                ~actor:ctx.agent_name ();
              Sse.broadcast
                (`Assoc
                   [
                     ("type", `String "governance_param_changed");
                     ("param_key", `String param_key);
                     ("old_value", old_value);
                     ("new_value", value);
                     ("actor", `String ctx.agent_name);
                   ]);
              (true,
               Printf.sprintf "Set %s = %s (low-risk, applied immediately)"
                 param_key (Yojson.Safe.to_string value))
        end

let handle_clear_param ~submit_petition ctx args =
  let param_key = get_string args "param_key" "" |> String.trim in
  let reason = get_string args "reason" "" in
  if param_key = "" then (false, "param_key is required")
  else
    let risk =
      Governance_registry.surfaces
      |> List.find_opt (fun (s : Governance_registry.surface) ->
           List.mem param_key s.param_keys)
      |> Option.map (fun (s : Governance_registry.surface) -> s.risk)
      |> Option.value ~default:"low"
    in
    if risk = "high" then
      let title =
        Printf.sprintf "Clear %s to default%s" param_key
          (if reason <> "" then " (" ^ reason ^ ")" else "")
      in
      let petition_args =
        `Assoc [
          ("title", `String title);
          ("origin", `String "agent");
          ("subject_type", `String "param_change");
          ("risk_class", `String "high");
          ("requested_action", `Assoc [
            ("action_type", `String "clear_param");
            ("payload", `Assoc [("param_key", `String param_key)]);
          ]);
          ("source_refs", `List [`String param_key]);
        ]
      in
      let (ok, msg) = submit_petition ctx petition_args in
      if ok then
        (true, Printf.sprintf "High-risk parameter. Governance petition created.\n%s" msg)
      else
        (false, Printf.sprintf "Failed to create governance petition: %s" msg)
    else begin
      let old_value =
        match Runtime_params.registry ()
              |> List.find_opt (fun (k, _, _, _, _) -> k = param_key) with
        | Some (_, current, _, _, _) -> current
        | None -> `Null
      in
      match Runtime_params.clear_by_key param_key with
      | Error msg -> (false, Printf.sprintf "clear_param failed: %s" msg)
      | Ok () ->
          let new_value =
            match Runtime_params.registry ()
                  |> List.find_opt (fun (k, _, _, _, _) -> k = param_key) with
            | Some (_, _, default, _, _) -> default
            | None -> `Null
          in
          Runtime_params.persist ~base_path:ctx.base_path;
          Runtime_params.record_audit ~base_path:ctx.base_path
            ~key:param_key ~old_value ~new_value ~actor:ctx.agent_name ();
          Sse.broadcast
            (`Assoc [
              ("type", `String "governance_param_changed");
              ("param_key", `String param_key);
              ("old_value", old_value);
              ("new_value", new_value);
              ("actor", `String ctx.agent_name);
            ]);
          (true, Printf.sprintf "Cleared %s to default (low-risk, applied immediately)" param_key)
    end

let handle_prompt_override ctx args =
  let key = get_string args "key" "" |> String.trim in
  let action = get_string args "action" "set" in
  if key = "" then (false, "key is required")
  else
    match action with
    | "clear" ->
      Prompt_registry.clear_prompt_override key;
      (try Prompt_registry.persist_overrides ctx.base_path
       with exn ->
         Log.Pages.warn "prompt override persist (clear) failed: %s"
           (Printexc.to_string exn));
      (true, Printf.sprintf "Prompt override cleared for %s" key)
    | "set" | _ ->
      let value = get_string args "value" "" in
      if value = "" then (false, "value is required when action is 'set'")
      else
        match Prompt_registry.set_override key value with
        | Error msg -> (false, msg)
        | Ok () ->
          (try Prompt_registry.persist_overrides ctx.base_path
           with exn ->
             Log.Pages.warn "prompt override persist (set) failed: %s"
               (Printexc.to_string exn));
          (true, Printf.sprintf "Prompt override set for %s" key)
