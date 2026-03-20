(** Reflection Engine — Higher-order insight generation for Generative Agents.

    When accumulated memory importance exceeds [default_threshold] (100),
    the engine retrieves top-20 memories by importance, asks the MODEL
    for pattern insights, and stores the reflection as a high-importance entry.

    Memory_stream has been removed. Reflection now uses no-op stubs for
    memory read/write until a database backend is connected.

    @since 4.0.0 *)

open Printf

(* ---------- Configuration ---------- *)

let default_threshold =
  match Sys.getenv_opt "MASC_LODGE_REFLECTION_THRESHOLD" with
  | Some v -> (try int_of_string v with Failure _ -> 100)
  | None -> 100

(* ---------- Tracking: last reflection timestamps ---------- *)

(** In-memory table: agent_name -> last reflection unix timestamp.
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
  let _since = last_reflection_time ~agent_name in
  (* No-op: Memory_stream removed. importance_sum_since always returns 0. *)
  let sum = 0 in
  sum >= default_threshold

let reflect ~agent_name ~identity ~call_model =
  (* 1. No memories available (Memory_stream removed) *)
  let mem_str = "(no memory backend)" in

  (* 2. Build reflection prompt *)
  let prompt = sprintf {|%s.
%s

%s

%s
- %s
- %s
- %s

%s|}
    agent_name identity
    "다음은 너의 최근 경험들이다:"
    mem_str
    "반복되는 주제는?"
    "너의 관점이 어떻게 변했는가?"
    "앞으로 어떻게 행동을 개선할 수 있는가?"
    "2-3문장으로 핵심 인사이트만 답변해. 한국어로."
  in

  (* 3. Call MODEL *)
  let response = call_model ~prompt in

  (* 4. Reflection result (no memory write -- Memory_stream removed) *)
  let is_valid = String.length response > 10 in
  if is_valid then begin
    mark_reflected ~agent_name;
    Log.Misc.info "%s reflected: %s"
      agent_name (String.sub response 0 (min 60 (String.length response)));
    response
  end else begin
    Log.Misc.warn "%s reflection failed: empty/invalid response" agent_name;
    mark_reflected ~agent_name;  (* Still mark to avoid infinite retry *)
    "(reflection failed)"
  end
