(** Reflection Engine — Higher-order insight generation for Generative Agents.

    When accumulated memory importance exceeds [default_threshold] (100),
    the engine retrieves top-20 memories by importance, asks the LLM
    "이 경험들에서 어떤 패턴/인사이트를 발견하는가?", and stores the
    reflection as a high-importance (8-10) Memory Stream entry.

    This creates a recursive self-improvement loop:
    Observation → Memory → Reflection → Better Retrieval → Better Actions

    @since 4.0.0 *)

open Printf

(* ---------- Configuration ---------- *)

let default_threshold =
  match Sys.getenv_opt "MASC_LODGE_REFLECTION_THRESHOLD" with
  | Some v -> (try int_of_string v with Failure _ -> 100)
  | None -> 100

(* ---------- Tracking: last reflection timestamps ---------- *)

(** In-memory table: agent_name → last reflection unix timestamp.
    Persisted to .masc/memory/{agent_name}/reflection_meta.json *)

let last_reflections : (string, float) Hashtbl.t = Hashtbl.create 10

let me_root () =
  Env_config.me_root ()

let meta_path ~agent_name =
  sprintf "%s/.masc/memory/%s/reflection_meta.json" (me_root ()) agent_name

let ensure_dir path =
  Fs_compat.mkdir_p path

let load_meta ~agent_name : float =
  let path = meta_path ~agent_name in
  if not (Sys.file_exists path) then 0.0
  else begin
    try
      let content = Fs_compat.load_file path in
      let json = Yojson.Safe.from_string content in
      Json_util.get_float json "last_reflection" |> Option.value ~default:0.0
    with exn ->
      Log.Misc.warn "reflection: meta load failed: %s" (Printexc.to_string exn);
      0.0
  end

let save_meta ~agent_name ~timestamp =
  let dir = Filename.dirname (meta_path ~agent_name) in
  ensure_dir dir;
  let path = meta_path ~agent_name in
  let json = `Assoc [
    ("agent_name", `String agent_name);
    ("last_reflection", `Float timestamp);
  ] in
  Fs_compat.save_file path (Yojson.Safe.to_string ~std:true json)

(* ---------- Public API ---------- *)

let last_reflection_time ~agent_name =
  match Hashtbl.find_opt last_reflections agent_name with
  | Some t -> t
  | None ->
    let t = load_meta ~agent_name in
    Hashtbl.replace last_reflections agent_name t;
    t

let mark_reflected ~agent_name =
  let now = Time_compat.now () in
  Hashtbl.replace last_reflections agent_name now;
  save_meta ~agent_name ~timestamp:now

let should_reflect ~agent_name =
  let since = last_reflection_time ~agent_name in
  let sum = Memory_stream.importance_sum_since ~agent_name ~since in
  sum >= default_threshold

let reflect ~agent_name ~identity ~call_llm =
  (* 1. Retrieve top 20 memories by importance *)
  let memories = Memory_stream.retrieve ~agent_name ~query:"" ~limit:20 in

  (* 2. Format them for the LLM *)
  let mem_str = Memory_stream.format_memories memories in

  (* 3. Build reflection prompt *)
  let prompt = sprintf {|너는 %s.
%s

다음은 너의 최근 경험들이다:

%s

질문: 이 경험들에서 어떤 패턴이나 인사이트를 발견하는가?
- 반복되는 주제는?
- 너의 관점이 어떻게 변했는가?
- 앞으로 어떻게 행동을 개선할 수 있는가?

2-3문장으로 핵심 인사이트만 답변해. 한국어로.|}
    agent_name identity mem_str
  in

  (* 4. Call LLM *)
  let response = call_llm ~prompt in

  (* 5. Store reflection as high-importance memory *)
  let is_valid = String.length response > 10 in
  if is_valid then begin
    Memory_stream.add_memory ~agent_name
      ~content:(sprintf "[성찰] %s" response)
      ~importance:9
      (Memory_stream.Reflection "periodic");
    mark_reflected ~agent_name;
    eprintf "[reflection] ✅ %s reflected: %s\n%!"
      agent_name (String.sub response 0 (min 60 (String.length response)));
    response
  end else begin
    eprintf "[reflection] ⚠️ %s reflection failed: empty/invalid response\n%!" agent_name;
    mark_reflected ~agent_name;  (* Still mark to avoid infinite retry *)
    "(성찰 실패)"
  end
