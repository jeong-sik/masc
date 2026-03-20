(** Agent Planner — Daily plan generation for Generative Agents.

    Once per day, each agent generates a 24-hour plan via MODEL.
    Each hour has an activity description and priority (0.0-1.0).
    The heartbeat tick queries [current_block] to decide who acts.

    Storage: .masc/plans/{agent_name}/{YYYY-MM-DD}.json

    @since 4.0.0 *)

open Printf

(* ---------- Types ---------- *)

type block = {
  hour: int;
  activity: string;
  priority: float;
}

type daily_plan = {
  agent_name: string;
  date: string;
  goals: string list;
  hourly_blocks: block list;
  created_at: float;
}

let act_threshold = 0.3

(* ---------- Paths ---------- *)

let me_root () =
  Env_config.me_root ()

let plans_dir ~agent_name =
  sprintf "%s/.masc/plans/%s" (me_root ()) agent_name

let plan_path ~agent_name ~date =
  sprintf "%s/%s.json" (plans_dir ~agent_name) date

let ensure_dir path =
  Fs_compat.mkdir_p path

(* ---------- Date helpers ---------- *)

let today_kst () =
  let now = Time_compat.now () in
  let tm = Unix.gmtime (now +. 9.0 *. 3600.0) in
  sprintf "%04d-%02d-%02d" (1900 + tm.Unix.tm_year) (1 + tm.Unix.tm_mon) tm.Unix.tm_mday

let current_hour_kst () =
  let now = Time_compat.now () in
  let tm = Unix.gmtime now in
  (tm.Unix.tm_hour + 9) mod 24

(* ---------- JSON serialization ---------- *)

let block_to_json (b : block) : Yojson.Safe.t =
  `Assoc [
    ("hour", `Int b.hour);
    ("activity", `String b.activity);
    ("priority", `Float b.priority);
  ]

let block_of_json (json : Yojson.Safe.t) : block =
  let open Yojson.Safe.Util in
  {
    hour = json |> member "hour" |> to_int;
    activity = json |> member "activity" |> to_string;
    priority = json |> member "priority" |> to_float;
  }

let plan_to_json (p : daily_plan) : Yojson.Safe.t =
  `Assoc [
    ("agent_name", `String p.agent_name);
    ("date", `String p.date);
    ("goals", `List (List.map (fun s -> `String s) p.goals));
    ("hourly_blocks", `List (List.map block_to_json p.hourly_blocks));
    ("created_at", `Float p.created_at);
  ]

let plan_of_json (json : Yojson.Safe.t) : daily_plan option =
  try
    let open Yojson.Safe.Util in
    Some {
      agent_name = json |> member "agent_name" |> to_string;
      date = json |> member "date" |> to_string;
      goals = json |> member "goals" |> to_list |> List.map to_string;
      hourly_blocks = json |> member "hourly_blocks" |> to_list |> List.map block_of_json;
      created_at = json |> member "created_at" |> to_float;
    }
  with Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> None

(* ---------- File I/O ---------- *)

let load_plan ~agent_name ~date : daily_plan option =
  let path = plan_path ~agent_name ~date in
  if not (Sys.file_exists path) then None
  else begin
    try
      let content = Fs_compat.load_file path in
      Yojson.Safe.from_string content |> plan_of_json
    with exn ->
      Log.Misc.warn "agent_planner: plan load failed: %s" (Printexc.to_string exn);
      None
  end

let save_plan (plan : daily_plan) =
  let dir = plans_dir ~agent_name:plan.agent_name in
  ensure_dir dir;
  let path = plan_path ~agent_name:plan.agent_name ~date:plan.date in
  let json_str = Yojson.Safe.to_string ~std:true (plan_to_json plan) in
  Fs_compat.save_file path json_str

(* ---------- Fallback plan ---------- *)

let fallback_plan ~agent_name =
  let date = today_kst () in
  let blocks = List.init 24 (fun h ->
    let activity, priority =
      if h >= 1 && h < 6 then ("휴식", 0.1)         (* quiet hours *)
      else if h >= 9 && h < 12 then ("활동", 0.6)    (* morning active *)
      else if h >= 14 && h < 17 then ("활동", 0.6)   (* afternoon active *)
      else if h >= 20 && h < 23 then ("활동", 0.5)   (* evening *)
      else ("대기", 0.3)
    in
    { hour = h; activity; priority }
  ) in
  {
    agent_name;
    date;
    goals = ["게시판 참여"; "동료 의견에 반응"];
    hourly_blocks = blocks;
    created_at = Time_compat.now ();
  }

(* ---------- MODEL plan generation ---------- *)

(** Build the prompt that asks the MODEL to create a daily plan. *)
let build_plan_prompt ~agent_name ~identity ~memories =
  let memory_str =
    if List.length memories = 0 then "(기억 없음)"
    else Memory_stream.format_memories memories
  in
  let date = today_kst () in
  let hour = current_hour_kst () in
  sprintf {|너는 Lodge의 %s.
%s

오늘 날짜: %s, 현재 시각: %02d:00 KST

[최근 기억]
%s

오늘 하루 계획을 세워줘.
JSON 형식으로만 답변:

```json
{
  "goals": ["목표1", "목표2"],
  "blocks": [
    {"hour": 0, "activity": "휴식", "priority": 0.1},
    {"hour": 9, "activity": "게시판 탐색", "priority": 0.7},
    ...24개 시간 블록...
  ]
}
```

규칙:
- goals는 2-3개, 구체적으로
- priority: 0.0(안 함) ~ 1.0(반드시 함)
- 새벽 1-6시는 priority 0.1 이하
- 너의 성격에 맞는 활동을 배치해
- JSON만 출력, 설명 없이|}
    agent_name identity date hour memory_str

(** Parse MODEL response into a daily_plan. *)
let parse_plan_response ~agent_name ~response : daily_plan option =
  try
    (* Extract JSON from response (may be wrapped in ```json ... ```) *)
    let json_str =
      let s = String.trim response in
      if String.length s > 7 && String.sub s 0 7 = "```json" then
        let start = 7 in
        let end_pos = match String.rindex_opt s '`' with
          | Some i -> i - 2  (* before ``` *)
          | None -> String.length s
        in
        String.trim (String.sub s start (end_pos - start))
      else if String.length s > 3 && String.sub s 0 3 = "```" then
        let start = 3 in
        let end_pos = match String.rindex_opt s '`' with
          | Some i -> i - 2
          | None -> String.length s
        in
        String.trim (String.sub s start (end_pos - start))
      else s
    in
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let goals = json |> member "goals" |> to_list |> List.map to_string in
    let blocks = json |> member "blocks" |> to_list |> List.map (fun b ->
      {
        hour = b |> member "hour" |> to_int;
        activity = b |> member "activity" |> to_string;
        priority = b |> member "priority" |> to_float;
      }
    ) in
    let date = today_kst () in
    Some {
      agent_name;
      date;
      goals;
      hourly_blocks = blocks;
      created_at = Time_compat.now ();
    }
  with e ->
    eprintf "[planner] Failed to parse plan for %s: %s\n%!" agent_name (Printexc.to_string e);
    None

(* ---------- Public API ---------- *)

let get_or_create_plan ~agent_name ~identity ~memories ~call_model =
  let date = today_kst () in
  match load_plan ~agent_name ~date with
  | Some plan -> plan
  | None ->
    let prompt = build_plan_prompt ~agent_name ~identity ~memories in
    let response = call_model ~prompt in
    let plan = match parse_plan_response ~agent_name ~response with
      | Some p ->
        (* Record plan creation as a memory *)
        let goals_str = String.concat ", " p.goals in
        Memory_stream.add_memory ~agent_name
          ~content:(sprintf "오늘 계획: %s" goals_str)
          ~importance:6
          (Memory_stream.Plan "daily");
        save_plan p;
        eprintf "[planner] ✅ Created plan for %s: %d goals, %d blocks\n%!"
          agent_name (List.length p.goals) (List.length p.hourly_blocks);
        p
      | None ->
        eprintf "[planner] ⚠️ MODEL plan failed for %s, using fallback\n%!" agent_name;
        let fb = fallback_plan ~agent_name in
        save_plan fb;
        fb
    in
    plan

let current_block plan =
  let hour = current_hour_kst () in
  List.find_opt (fun b -> b.hour = hour) plan.hourly_blocks

let should_act block =
  block.priority > act_threshold

(* ---------- Formatting ---------- *)

let plan_to_string plan =
  let goals_str = String.concat "; " plan.goals in
  let top_blocks = plan.hourly_blocks
    |> List.filter (fun b -> b.priority > 0.3)
    |> List.sort (fun a b -> Float.compare b.priority a.priority)
    |> (fun lst -> let rec take n acc = function
        | [] -> List.rev acc
        | _ when n <= 0 -> List.rev acc
        | x :: xs -> take (n - 1) (x :: acc) xs
      in take 5 [] lst)
    |> List.map (fun b -> sprintf "  %02d시: %s (%.1f)" b.hour b.activity b.priority)
    |> String.concat "\n"
  in
  sprintf "[%s 계획 %s]\n목표: %s\n주요 활동:\n%s"
    plan.agent_name plan.date goals_str top_blocks
