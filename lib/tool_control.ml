(** Tool_control - Flow control operations

    Handles: pause, pause_status, resume, switch_mode, get_config
*)

open Tool_args

type result = bool * string

type context = {
  config: Room.config;
  agent_name: string;
}

(* Handlers *)

let handle_pause ctx args =
  let reason = get_string args "reason" "Manual pause" in
  Room.pause ctx.config ~by:ctx.agent_name ~reason;
  (true, Printf.sprintf "⏸️ Room paused by %s: %s" ctx.agent_name reason)

let handle_resume ctx _args =
  match Room.resume ctx.config ~by:ctx.agent_name with
  | `Resumed -> (true, Printf.sprintf "▶️ Room resumed by %s" ctx.agent_name)
  | `Already_running -> (true, "Room is not paused")

let handle_pause_status ctx args =
  let requested_room = get_string args "room_id" "" |> String.trim in
  let current_room =
    Room.read_current_room ctx.config |> Option.value ~default:"default"
  in
  let room_id = if requested_room = "" then current_room else requested_room in
  let payload =
    match Room.pause_info ctx.config with
    | Some (by, reason, at) ->
        `Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("status", `String "paused");
            ("paused", `Bool true);
            ("paused_by", (match by with Some s -> `String s | None -> `Null));
            ( "pause_reason",
              match reason with Some s -> `String s | None -> `Null );
            ("paused_at", (match at with Some s -> `String s | None -> `Null));
            ("message", `String "⏸️ Room is paused");
          ]
    | None ->
        `Assoc
          [
            ("ok", `Bool true);
            ("room_id", `String room_id);
            ("status", `String "running");
            ("paused", `Bool false);
            ("paused_by", `Null);
            ("pause_reason", `Null);
            ("paused_at", `Null);
            ("message", `String "▶️ Room is running (not paused)");
          ]
  in
  (true, Yojson.Safe.to_string payload)

let handle_switch_mode ctx args =
  let mode_str = get_string args "mode" "" |> String.trim |> String.lowercase_ascii in
  if mode_str = "" then
    (false, "mode is required (minimal|standard|parallel|coding|full|solo|custom)")
  else
    match Mode.mode_of_string mode_str with
    | None ->
        (false, Printf.sprintf "invalid mode: %s (minimal|standard|parallel|coding|full|solo|custom)" mode_str)
    | Some mode ->
        let room_path = Room.masc_dir ctx.config in
        let switched =
          match mode with
          | Mode.Custom ->
              let category_names = get_string_list args "categories" in
              if category_names = [] then
                Error "custom mode requires non-empty categories"
              else
                let parsed =
                  List.map
                    (fun name ->
                      match Mode.category_of_string name with
                      | Some cat -> Ok cat
                      | None -> Error name)
                    category_names
                in
                let invalid =
                  List.filter_map
                    (function Error name -> Some name | Ok _ -> None)
                    parsed
                in
                if invalid <> [] then
                  Error
                    (Printf.sprintf "invalid categories: %s"
                       (String.concat ", " invalid))
                else
                  let categories =
                    parsed
                    |> List.filter_map (function Ok cat -> Some cat | Error _ -> None)
                    |> List.sort_uniq Stdlib.compare
                  in
                  ignore
                    (Config.set_categories ~actor:ctx.agent_name
                       ~source:"masc_switch_mode:custom" room_path categories);
                  Ok ()
          | _ ->
              ignore
                (Config.switch_mode ~actor:ctx.agent_name
                   ~source:"masc_switch_mode" room_path mode);
              Ok ()
        in
        (match switched with
         | Error msg -> (false, msg)
         | Ok () ->
             let summary = Config.get_config_summary room_path in
             (true, Yojson.Safe.pretty_to_string summary))

let handle_get_config ctx _args =
  let room_path = Room.masc_dir ctx.config in
  let summary = Config.get_config_summary room_path in
  (true, Yojson.Safe.pretty_to_string summary)

let tools_in_category cat =
  Config.raw_all_tool_schemas
  |> List.filter (fun (s : Types.tool_schema) -> Mode.tool_category s.name = cat)
  |> List.map (fun (s : Types.tool_schema) -> s.name)

let handle_tool_enable _ctx args =
  let tools = get_string_list args "tools" in
  let tool = get_string args "tool" "" |> String.trim in
  let category = get_string args "category" "" |> String.trim |> String.lowercase_ascii in
  let category_tools =
    if category = "" then []
    else match Mode.category_of_string category with
    | Some cat -> tools_in_category cat
    | None -> []
  in
  let all_tools =
    (if tool <> "" then [tool] else []) @ tools @ category_tools
    |> List.filter (fun t -> String.trim t <> "")
    |> List.sort_uniq String.compare
  in
  if all_tools = [] then
    (false, Printf.sprintf "tool, tools, or category is required. Available categories: %s"
       (String.concat ", " (List.map Mode.category_to_string
          [Mode.Ecosystem; Discovery; Code; Board; Portal; Worktree;
           Consensus; Voting; Encryption; Auth; Cost; Health])))
  else begin
    List.iter Mode.tool_enable all_tools;
    let enabled = Mode.tool_enable_list () in
    let json = `Assoc ([
      ("enabled", `List (List.map (fun t -> `String t) all_tools));
      ("extra_enabled_total", `Int (List.length enabled));
    ] @ (if category <> "" then
           [("category", `String category);
            ("category_tool_count", `Int (List.length category_tools))]
         else [])) in
    (true, Yojson.Safe.pretty_to_string json)
  end

let handle_tool_disable _ctx args =
  let tools = get_string_list args "tools" in
  let tool = get_string args "tool" "" |> String.trim in
  let clear = get_bool args "clear" false in
  if clear then begin
    Mode.tool_enable_clear ();
    (true, "All extra-enabled tools cleared.")
  end
  else begin
    let all_tools =
      (if tool <> "" then [tool] else []) @ tools
      |> List.filter (fun t -> String.trim t <> "")
    in
    if all_tools = [] then
      (false, "tool, tools, or clear=true is required")
    else begin
      List.iter Mode.tool_disable all_tools;
      let enabled = Mode.tool_enable_list () in
      let json = `Assoc [
        ("disabled", `List (List.map (fun t -> `String t) all_tools));
        ("extra_enabled_total", `Int (List.length enabled));
      ] in
      (true, Yojson.Safe.pretty_to_string json)
    end
  end

(* Dispatch function *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_pause" -> Some (handle_pause ctx args)
  | "masc_resume" -> Some (handle_resume ctx args)
  | "masc_pause_status" -> Some (handle_pause_status ctx args)
  | "masc_switch_mode" -> Some (handle_switch_mode ctx args)
  | "masc_get_config" -> Some (handle_get_config ctx args)
  | "masc_tool_enable" -> Some (handle_tool_enable ctx args)
  | "masc_tool_disable" -> Some (handle_tool_disable ctx args)
  | _ -> None
