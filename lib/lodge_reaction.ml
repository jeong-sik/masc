(** Lodge Reaction — Emergent Identity through Reaction History

    Core principle: Identity is not defined by static traits, but emerges from
    reaction patterns. "내가 누군지 알기보다 거울 덕분에 내가 뭔지 알게 되는 것"

    This module implements:
    - Reaction storage (JSONL)
    - Agent signature computation from history
    - Trait fade mechanism (50 reactions → 0% traits weight)
    - Topic affinity calculation
    - Batch reaction generation

    @since 4.0.0 (Lodge Emergent Identity System)
*)

open Printf

(** {1 Types} *)

(** Reaction types for posts *)
type reaction_type =
  | Upvote        (** Positive engagement — executed immediately *)
  | Pass          (** Neutral — no strong feeling either way *)
  | CommentIntent (** Want to say something about this *)
  | Skip          (** Actively choose not to engage *)
[@@deriving show, eq]

(** Single reaction record *)
type reaction_record = {
  agent_name: string;
  post_id: string;
  post_author: string;
  post_topics: string list;  (** Extracted keywords from post content *)
  reaction: reaction_type;
  confidence: float;         (** 0.0-1.0 — how sure the agent is *)
  reason: string option;     (** Brief reasoning for the reaction *)
  timestamp: float;
}
[@@deriving show, eq]

(** Computed agent signature from reaction history *)
type agent_signature = {
  agent_name: string;
  reaction_patterns: (string * float) list;  (** topic -> affinity (0.0-1.0) *)
  upvote_ratio: float;                       (** Proportion of upvotes *)
  comment_tendency: float;                   (** Proportion of comment intents *)
  recent_reactions: reaction_record list;    (** Last N for prompt context *)
  generated_self_summary: string option;     (** Periodic LLM reflection *)
  total_reactions: int;                      (** Total reaction count *)
  last_updated: float;
}
[@@deriving show, eq]

(** Batch reaction result from LLM *)
type batch_reaction = {
  post_id: string;
  reaction: reaction_type;
  confidence: float;
  reason: string option;
}
[@@deriving show, eq]

(** {1 Constants} *)

(** Number of reactions after which static traits weight becomes 0 *)
let trait_fade_threshold = 50

(** Number of recent reactions to include in prompts *)
let history_window = 10

(** Default batch size for reaction generation *)
let default_batch_size = 5

(** Maximum topics to track per agent *)
let max_tracked_topics = 50

(** Decay factor for old reactions (power law) *)
let reaction_decay_factor = 0.95

(** {1 Storage} *)

(** Resolve ME_ROOT consistently *)
let me_root () =
  Sys.getenv_opt "ME_ROOT" |> Option.value ~default:"/Users/dancer/me"

(** Path to reaction history JSONL file *)
let reaction_history_path () =
  Filename.concat (me_root ()) ".masc/reaction_history.jsonl"

(** Path to agent signatures JSON file *)
let signatures_path () =
  Filename.concat (me_root ()) ".masc/agent_signatures.json"

(** {1 JSON Serialization} *)

let reaction_type_to_string = function
  | Upvote -> "upvote"
  | Pass -> "pass"
  | CommentIntent -> "comment_intent"
  | Skip -> "skip"

let reaction_type_of_string = function
  | "upvote" -> Ok Upvote
  | "pass" -> Ok Pass
  | "comment_intent" -> Ok CommentIntent
  | "skip" -> Ok Skip
  | s -> Error (sprintf "Unknown reaction type: %s" s)

(** Unsafe version that raises on invalid input — for backward compatibility *)
let reaction_type_of_string_exn s =
  match reaction_type_of_string s with
  | Ok r -> r
  | Error msg -> failwith msg

let reaction_record_to_json (r : reaction_record) : Yojson.Safe.t =
  `Assoc [
    ("agent_name", `String r.agent_name);
    ("post_id", `String r.post_id);
    ("post_author", `String r.post_author);
    ("post_topics", `List (List.map (fun t -> `String t) r.post_topics));
    ("reaction", `String (reaction_type_to_string r.reaction));
    ("confidence", `Float r.confidence);
    ("reason", match r.reason with Some s -> `String s | None -> `Null);
    ("timestamp", `Float r.timestamp);
  ]

let reaction_record_of_json (json : Yojson.Safe.t) : (reaction_record, string) result =
  let open Yojson.Safe.Util in
  match json |> member "reaction" |> to_string |> reaction_type_of_string with
  | Error msg -> Error msg
  | Ok reaction -> Ok {
      agent_name = json |> member "agent_name" |> to_string;
      post_id = json |> member "post_id" |> to_string;
      post_author = json |> member "post_author" |> to_string;
      post_topics = json |> member "post_topics" |> to_list |> List.map to_string;
      reaction;
      confidence = json |> member "confidence" |> to_float;
      reason = json |> member "reason" |> to_string_option;
      timestamp = json |> member "timestamp" |> to_float;
    }

let agent_signature_to_json (s : agent_signature) : Yojson.Safe.t =
  `Assoc [
    ("agent_name", `String s.agent_name);
    ("reaction_patterns", `Assoc (List.map (fun (t, a) -> (t, `Float a)) s.reaction_patterns));
    ("upvote_ratio", `Float s.upvote_ratio);
    ("comment_tendency", `Float s.comment_tendency);
    ("recent_reactions", `List (List.map reaction_record_to_json s.recent_reactions));
    ("generated_self_summary", match s.generated_self_summary with Some s -> `String s | None -> `Null);
    ("total_reactions", `Int s.total_reactions);
    ("last_updated", `Float s.last_updated);
  ]

let agent_signature_of_json (json : Yojson.Safe.t) : (agent_signature, string) result =
  let open Yojson.Safe.Util in
  let recent_jsons = json |> member "recent_reactions" |> to_list in
  match List.filter_map (fun j ->
    match reaction_record_of_json j with
    | Ok r -> Some r
    | Error _ -> None
  ) recent_jsons with
  | recent_reactions -> Ok {
      agent_name = json |> member "agent_name" |> to_string;
      reaction_patterns = json |> member "reaction_patterns" |> to_assoc
        |> List.map (fun (k, v) -> (k, to_float v));
      upvote_ratio = json |> member "upvote_ratio" |> to_float;
      comment_tendency = json |> member "comment_tendency" |> to_float;
      recent_reactions;
      generated_self_summary = json |> member "generated_self_summary" |> to_string_option;
      total_reactions = json |> member "total_reactions" |> to_int;
      last_updated = json |> member "last_updated" |> to_float;
    }

(** {1 Storage Operations} *)

(** Append a reaction record to history.
    Uses Fs_compat for Eio-native I/O when available. *)
let append_reaction (record : reaction_record) : unit =
  let path = reaction_history_path () in
  Fs_compat.append_jsonl path (reaction_record_to_json record)

(** Load all reactions for an agent.
    Uses Fs_compat for Eio-native I/O when available. *)
let load_reactions ~agent_name : reaction_record list =
  let path = reaction_history_path () in
  Fs_compat.load_jsonl path
  |> List.filter_map (fun json ->
      match reaction_record_of_json json with
      | Ok record when record.agent_name = agent_name -> Some record
      | _ -> None)

(** Load recent reactions for an agent *)
let load_recent_reactions ~agent_name ~limit : reaction_record list =
  let all = load_reactions ~agent_name in
  (* Sort by timestamp descending, take limit *)
  all
  |> List.sort (fun a b -> Float.compare b.timestamp a.timestamp)
  |> (fun lst ->
      let rec take n acc = function
        | [] -> List.rev acc
        | _ when n <= 0 -> List.rev acc
        | x :: xs -> take (n - 1) (x :: acc) xs
      in take limit [] lst)

(** {1 Signature Computation} *)

(** Compute trait fade weight based on reaction count.
    0 reactions: 100% traits weight
    50+ reactions: 0% traits weight (identity fully emergent) *)
let trait_weight ~reaction_count : float =
  Float.max 0.0 (1.0 -. (Float.of_int reaction_count /. Float.of_int trait_fade_threshold))

(** Compute topic affinity from reaction history.
    Upvotes boost affinity, Passes are neutral, Skips reduce it.
    Recent reactions weighted more heavily (power law decay). *)
let compute_topic_affinities (reactions : reaction_record list) : (string * float) list =
  let topic_scores : (string, float * float) Hashtbl.t = Hashtbl.create 64 in

  (* Process reactions from oldest to newest, applying decay *)
  let sorted = List.sort (fun a b -> Float.compare a.timestamp b.timestamp) reactions in
  let total = List.length sorted in

  List.iteri (fun idx (record : reaction_record) ->
    let decay = reaction_decay_factor ** Float.of_int (total - idx - 1) in
    let score_delta = match record.reaction with
      | Upvote -> 1.0 *. record.confidence *. decay
      | CommentIntent -> 0.5 *. record.confidence *. decay
      | Pass -> 0.0
      | Skip -> -0.3 *. record.confidence *. decay
    in
    List.iter (fun topic ->
      let (sum, count) = Hashtbl.find_opt topic_scores topic
        |> Option.value ~default:(0.0, 0.0) in
      Hashtbl.replace topic_scores topic (sum +. score_delta, count +. decay)
    ) record.post_topics
  ) sorted;

  (* Normalize to 0.0-1.0 range *)
  Hashtbl.fold (fun topic (sum, count) acc ->
    if count > 0.0 then
      let raw = sum /. count in
      let normalized = (raw +. 1.0) /. 2.0 in  (* Map [-1, 1] to [0, 1] *)
      (topic, Float.max 0.0 (Float.min 1.0 normalized)) :: acc
    else acc
  ) topic_scores []
  |> List.sort (fun (_, a) (_, b) -> Float.compare b a)
  |> (fun lst ->
      let rec take n acc = function
        | [] -> List.rev acc
        | _ when n <= 0 -> List.rev acc
        | x :: xs -> take (n - 1) (x :: acc) xs
      in take max_tracked_topics [] lst)

(** Compute agent signature from reaction history *)
let compute_signature ~agent_name : agent_signature =
  let reactions = load_reactions ~agent_name in
  let recent = load_recent_reactions ~agent_name ~limit:history_window in
  let total = List.length reactions in

  let upvote_count = List.length (List.filter (fun (r : reaction_record) -> r.reaction = Upvote) reactions) in
  let comment_count = List.length (List.filter (fun (r : reaction_record) -> r.reaction = CommentIntent) reactions) in

  {
    agent_name;
    reaction_patterns = compute_topic_affinities reactions;
    upvote_ratio = if total > 0 then Float.of_int upvote_count /. Float.of_int total else 0.0;
    comment_tendency = if total > 0 then Float.of_int comment_count /. Float.of_int total else 0.0;
    recent_reactions = recent;
    generated_self_summary = None;  (* Set by periodic reflection *)
    total_reactions = total;
    last_updated = Time_compat.now ();
  }

(** {1 Signature Persistence} *)

(** Load all agent signatures.
    Uses Fs_compat for Eio-native I/O when available. *)
let load_all_signatures () : agent_signature list =
  let path = signatures_path () in
  if not (Fs_compat.file_exists path) then []
  else begin
    try
      let content = Fs_compat.load_file path in
      let json = Yojson.Safe.from_string content in
      Yojson.Safe.Util.to_list json
      |> List.filter_map (fun j ->
          match agent_signature_of_json j with
          | Ok sig_ -> Some sig_
          | Error _ -> None)
    with _ -> []
  end

(** Save agent signature (upsert).
    Uses Fs_compat for Eio-native I/O when available. *)
let save_signature (sig_ : agent_signature) : unit =
  let path = signatures_path () in
  let dir = Filename.dirname path in
  Fs_compat.mkdir_p dir;

  let existing = load_all_signatures () in
  let updated = sig_ :: List.filter (fun s -> s.agent_name <> sig_.agent_name) existing in

  let json = `List (List.map agent_signature_to_json updated) in
  Fs_compat.save_file path (Yojson.Safe.to_string json)

(** Load or compute signature for an agent *)
let get_or_compute_signature ~agent_name : agent_signature =
  let existing = load_all_signatures () in
  match List.find_opt (fun s -> s.agent_name = agent_name) existing with
  | Some sig_ -> sig_
  | None -> compute_signature ~agent_name

(** {1 Topic Extraction} *)

(** Extract topics from post content.
    Simple keyword extraction — can be enhanced with NLP later. *)
let extract_topics (content : string) : string list =
  (* Common tech/domain keywords to look for *)
  let keywords = [
    "ocaml"; "eio"; "graphql"; "neo4j"; "rust"; "typescript"; "react";
    "agent"; "mcp"; "llm"; "ai"; "ml"; "api"; "webrtc"; "grpc";
    "postgresql"; "sqlite"; "redis"; "vector";
    "test"; "debug"; "deploy"; "ci"; "docker"; "kubernetes";
    "architecture"; "design"; "pattern"; "refactor";
    "performance"; "memory"; "concurrency"; "async";
  ] in

  let lower = String.lowercase_ascii content in
  List.filter (fun kw ->
    let pattern = Str.regexp_string kw in
    try ignore (Str.search_forward pattern lower 0); true
    with Not_found -> false
  ) keywords

(** {1 Prompt Generation} *)

(** Generate history-based identity prompt section.
    Replaces static "[네 상태] 성격: dreamer, traits: ..." *)
let generate_identity_prompt (sig_ : agent_signature) ~(static_traits : string list) : string =
  let trait_w = trait_weight ~reaction_count:sig_.total_reactions in

  let top_topics =
    sig_.reaction_patterns
    |> List.filter (fun (_, a) -> a > 0.6)
    |> (fun lst -> let rec take n acc = function
        | [] -> List.rev acc
        | _ when n <= 0 -> List.rev acc
        | x :: xs -> take (n - 1) (x :: acc) xs
      in take 5 [] lst)
    |> List.map (fun (t, a) -> sprintf "%s (%.0f%%)" t (a *. 100.0))
  in

  let recent_summary =
    sig_.recent_reactions
    |> List.map (fun (r : reaction_record) ->
        let action = reaction_type_to_string r.reaction in
        let ago = (Time_compat.now () -. r.timestamp) /. 3600.0 in
        sprintf "- %.0fh ago: %s %s's post%s (%.2f confidence)"
          ago action r.post_author
          (match r.reason with Some s -> sprintf " — %s" s | None -> "")
          r.confidence
      )
    |> String.concat "\n"
  in

  let buf = Buffer.create 512 in

  Buffer.add_string buf "[당신의 정체성 — 행동에서 드러남]\n";

  (* Static traits with fade *)
  if trait_w > 0.01 && static_traits <> [] then begin
    Buffer.add_string buf (sprintf "기존 특성 (%.0f%% 영향): %s\n"
      (trait_w *. 100.0) (String.concat ", " static_traits))
  end;

  (* Emergent patterns *)
  if sig_.total_reactions > 0 then begin
    Buffer.add_string buf (sprintf "반응 기반 관심사: %s\n"
      (if top_topics = [] then "(아직 패턴 형성 중)" else String.concat ", " top_topics));
    Buffer.add_string buf (sprintf "반응 스타일: %.0f%% upvote, %.0f%% comment\n"
      (sig_.upvote_ratio *. 100.0) (sig_.comment_tendency *. 100.0));

    (* Self-summary if available *)
    begin match sig_.generated_self_summary with
    | Some summary -> Buffer.add_string buf (sprintf "자기 인식: \"%s\"\n" summary)
    | None -> ()
    end;

    Buffer.add_string buf "\n[최근 반응]\n";
    Buffer.add_string buf recent_summary;
  end else begin
    Buffer.add_string buf "(첫 활동 — 반응 패턴이 당신의 정체성을 형성합니다)\n"
  end;

  Buffer.add_string buf "\n[이전 행동과 일관되게 행동하세요]\n";

  Buffer.contents buf

(** {1 Batch Reaction Prompt} *)

(** Generate prompt for batch reaction generation.
    Used in READ_PHASE of two-phase heartbeat. *)
let batch_reaction_prompt ~agent_name ~(posts : (string * string * string) list)
    ~(signature : agent_signature) ~(static_traits : string list)
    ~(extra_context : string option) : string =
  let posts_section =
    posts
    |> List.mapi (fun i (id, author, content) ->
        sprintf "[Post %d] id=%s by=%s\n%s" (i + 1) id author
          (if String.length content > 300 then String.sub content 0 300 ^ "..." else content)
      )
    |> String.concat "\n\n"
  in

  let identity = generate_identity_prompt signature ~static_traits in
  let extra_context =
    match extra_context with
    | Some text when String.trim text <> "" -> "\n\n[추가 맥락]\n" ^ text
    | _ -> ""
  in

  sprintf {|당신은 Lodge 커뮤니티의 %s입니다.

%s

아래 포스트들에 대해 각각 반응하세요.
반응 종류: upvote (좋아요), pass (중립), comment_intent (댓글 의도), skip (무시)

각 포스트에 대해 한 줄씩 응답:
POST_ID | REACTION | CONFIDENCE(0.0-1.0) | REASON(선택, 10자 이내)

예시:
abc123 | upvote | 0.85 | 실용적인 팁
def456 | pass | 0.6 |
ghi789 | comment_intent | 0.9 | 질문있음

---

%s

%s

---

응답:|}
  agent_name identity posts_section extra_context

(** Parse batch reaction response from LLM *)
let parse_batch_reactions (response : string) : batch_reaction list =
  String.split_on_char '\n' response
  |> List.filter_map (fun line ->
      let line = String.trim line in
      if line = "" || String.length line < 5 then None
      else
        try
          let parts = String.split_on_char '|' line |> List.map String.trim in
          match parts with
          | [post_id; reaction_str; conf_str] ->
            (match reaction_type_of_string (String.lowercase_ascii reaction_str) with
             | Ok reaction -> Some {
                 post_id;
                 reaction;
                 confidence = Float.of_string conf_str;
                 reason = None;
               }
             | Error _ -> None)
          | [post_id; reaction_str; conf_str; reason] ->
            (match reaction_type_of_string (String.lowercase_ascii reaction_str) with
             | Ok reaction -> Some {
                 post_id;
                 reaction;
                 confidence = Float.of_string conf_str;
                 reason = if reason = "" then None else Some reason;
               }
             | Error _ -> None)
          | _ -> None
        with _ -> None
    )

(** {1 Cold Start} *)

(** Generate founding reaction prompt for new agents.
    This seeds the agent's identity with a single reaction. *)
let founding_reaction_prompt ~agent_name ~(post : string * string * string) : string =
  let (_id, author, content) = post in
  sprintf {|당신은 Lodge 커뮤니티에 처음 참여하는 %s입니다.
이것이 당신의 첫 번째 반응입니다. 이 반응이 당신의 정체성의 시작점이 됩니다.

[포스트]
작성자: %s
내용: %s

이 포스트에 대해 어떻게 반응하시겠습니까?
신중하게 선택하세요 — 이 반응이 당신이 누구인지를 정의하기 시작합니다.

응답 형식:
REACTION: upvote|pass|comment_intent|skip
CONFIDENCE: 0.0-1.0
REASON: (왜 이렇게 반응했는지, 1-2문장)
SELF_REFLECTION: (이 반응이 나에 대해 무엇을 말해주는지, 1문장)|}
  agent_name author
  (if String.length content > 500 then String.sub content 0 500 ^ "..." else content)

(** {1 Self-Reflection} *)

(** Generate self-reflection prompt.
    Called every N reactions to update self-summary. *)
let self_reflection_prompt ~(signature : agent_signature) : string =
  let recent =
    signature.recent_reactions
    |> List.map (fun (r : reaction_record) ->
        sprintf "- %s %s's post about [%s] (%.2f confidence)%s"
          (reaction_type_to_string r.reaction)
          r.post_author
          (String.concat ", " r.post_topics)
          r.confidence
          (match r.reason with Some s -> sprintf " — %s" s | None -> "")
      )
    |> String.concat "\n"
  in

  let top_topics =
    signature.reaction_patterns
    |> List.filter (fun (_, a) -> a > 0.5)
    |> List.map fst
    |> String.concat ", "
  in

  sprintf {|당신의 최근 반응 패턴을 분석하고, 자기 자신에 대한 인식을 업데이트하세요.

[반응 통계]
총 반응 수: %d
업보트 비율: %.0f%%
댓글 의향 비율: %.0f%%
관심 주제: %s

[최근 반응]
%s

위 패턴을 바탕으로, 당신이 어떤 존재인지 한 문장으로 표현하세요.
"나는..." 으로 시작하는 형식으로 응답하세요.
구체적이고 행동 기반으로 서술하세요. 추상적인 특성(예: "창의적인")보다는
관찰 가능한 패턴(예: "실용적인 OCaml 코드에 더 많이 반응하는")을 사용하세요.|}
  signature.total_reactions
  (signature.upvote_ratio *. 100.0)
  (signature.comment_tendency *. 100.0)
  (if top_topics = "" then "(아직 없음)" else top_topics)
  (if recent = "" then "(최근 반응 없음)" else recent)

(** {1 Diversity Tracking} *)

(** Helper: Get affinity for a topic from reaction_patterns.
    Returns 0.0 if topic not found. *)
let get_topic_affinity (patterns : (string * float) list) (topic : string) : float =
  match List.find_opt (fun (t, _) -> t = topic) patterns with
  | Some (_, aff) -> aff
  | None -> 0.0

(** Helper: Collect all unique topics from two signatures *)
let collect_all_topics (a : agent_signature) (b : agent_signature) : string list =
  let a_topics = List.map fst a.reaction_patterns in
  let b_topics = List.map fst b.reaction_patterns in
  List.sort_uniq String.compare (a_topics @ b_topics)

(** Helper: Dot product of two float lists *)
let dot_product (v1 : float list) (v2 : float list) : float =
  List.fold_left2 (fun acc x y -> acc +. (x *. y)) 0.0 v1 v2

(** Helper: Magnitude (L2 norm) of a float list *)
let magnitude (v : float list) : float =
  sqrt (List.fold_left (fun acc x -> acc +. (x *. x)) 0.0 v)

(** Compute similarity between two agent signatures using Cosine Similarity.
    Returns 0.0 (completely different) to 1.0 (identical).

    v2.0 Enhancement: Uses affinity-aware cosine similarity instead of Jaccard.
    This captures not just topic overlap, but how strongly each agent
    is interested in shared topics.

    Reference: EMNLP 2025 Diversity paper *)
let signature_similarity (a : agent_signature) (b : agent_signature) : float =
  if a.total_reactions < 5 || b.total_reactions < 5 then
    0.0  (* Not enough data to compare *)
  else
    (* Build affinity vectors over all topics *)
    let all_topics = collect_all_topics a b in
    let vec_a = List.map (get_topic_affinity a.reaction_patterns) all_topics in
    let vec_b = List.map (get_topic_affinity b.reaction_patterns) all_topics in

    (* Cosine similarity on affinity vectors *)
    let dot = dot_product vec_a vec_b in
    let mag_a = magnitude vec_a in
    let mag_b = magnitude vec_b in
    let topic_sim =
      if mag_a < 1e-9 || mag_b < 1e-9 then 0.0
      else dot /. (mag_a *. mag_b)
    in

    (* Ratio similarity (behavioral patterns) *)
    let ratio_sim = 1.0 -. (Float.abs (a.upvote_ratio -. b.upvote_ratio) +.
                           Float.abs (a.comment_tendency -. b.comment_tendency)) /. 2.0 in

    (* Combined: 70% topic affinity, 30% behavioral patterns *)
    (topic_sim *. 0.7) +. (ratio_sim *. 0.3)

(** Find pairs of agents with high similarity (potential convergence) *)
let find_similar_pairs ~(threshold : float) : (string * string * float) list =
  let sigs = load_all_signatures () in
  let pairs = ref [] in

  let rec check = function
    | [] -> ()
    | x :: rest ->
      List.iter (fun y ->
        let sim = signature_similarity x y in
        if sim >= threshold then
          pairs := (x.agent_name, y.agent_name, sim) :: !pairs
      ) rest;
      check rest
  in
  check sigs;
  !pairs

(** {1 Utilities} *)

(** Check if agent needs self-reflection (every N reactions) *)
let needs_reflection ~agent_name ~(interval : int) : bool =
  let sig_ = get_or_compute_signature ~agent_name in
  sig_.total_reactions > 0 &&
  sig_.total_reactions mod interval = 0 &&
  sig_.generated_self_summary = None

(** Update signature with new self-summary *)
let update_self_summary ~agent_name ~summary : unit =
  let sig_ = get_or_compute_signature ~agent_name in
  let updated = { sig_ with
    generated_self_summary = Some summary;
    last_updated = Time_compat.now ();
  } in
  save_signature updated

(** Record a reaction and update signature *)
let record_reaction ~agent_name ~post_id ~post_author ~post_content
    ~reaction ~confidence ?reason () : unit =
  let topics = extract_topics post_content in
  let record = {
    agent_name;
    post_id;
    post_author;
    post_topics = topics;
    reaction;
    confidence;
    reason;
    timestamp = Time_compat.now ();
  } in
  append_reaction record;

  (* Recompute and save signature *)
  let sig_ = compute_signature ~agent_name in
  save_signature sig_

(** {1 v2.0: Confidence Calibration}

    Track predicted confidence vs actual outcomes to measure
    how well-calibrated an agent's confidence estimates are.

    Reference: A-MEM (arXiv:2502.12110) — confidence scores on memories
*)

(** Calibration record *)
type confidence_calibration = {
  agent_name: string;
  post_id: string;
  predicted_confidence: float;  (** LLM's predicted confidence *)
  actual_outcome: float;        (** Actual outcome (e.g., vote ratio) *)
  error: float;                 (** |predicted - actual| *)
  timestamp: float;
}
[@@deriving show, eq]

(** Path to calibration history *)
let calibration_history_path () =
  Filename.concat (me_root ()) ".masc/calibration_history.jsonl"

let calibration_to_json (c : confidence_calibration) : Yojson.Safe.t =
  `Assoc [
    ("agent_name", `String c.agent_name);
    ("post_id", `String c.post_id);
    ("predicted_confidence", `Float c.predicted_confidence);
    ("actual_outcome", `Float c.actual_outcome);
    ("error", `Float c.error);
    ("timestamp", `Float c.timestamp);
  ]

let calibration_of_json (json : Yojson.Safe.t) : confidence_calibration =
  let open Yojson.Safe.Util in
  {
    agent_name = json |> member "agent_name" |> to_string;
    post_id = json |> member "post_id" |> to_string;
    predicted_confidence = json |> member "predicted_confidence" |> to_float;
    actual_outcome = json |> member "actual_outcome" |> to_float;
    error = json |> member "error" |> to_float;
    timestamp = json |> member "timestamp" |> to_float;
  }

(** Record a calibration data point *)
let record_calibration ~agent_name ~post_id ~predicted ~actual : unit =
  let path = calibration_history_path () in
  let error = Float.abs (predicted -. actual) in
  let record = {
    agent_name;
    post_id;
    predicted_confidence = predicted;
    actual_outcome = actual;
    error;
    timestamp = Time_compat.now ();
  } in
  Fs_compat.append_jsonl path (calibration_to_json record)

(** Load all calibration records for an agent.
    Uses Fs_compat for Eio-native I/O when available. *)
let load_calibration ~agent_name : confidence_calibration list =
  let path = calibration_history_path () in
  Fs_compat.load_jsonl path
  |> List.filter_map (fun json ->
      try
        let record = calibration_of_json json in
        if record.agent_name = agent_name then Some record else None
      with _ -> None)

(** Compute average calibration error for an agent.
    Returns 0.5 (neutral) if no calibration data exists. *)
let avg_calibration_error ~agent_name : float =
  let records = load_calibration ~agent_name in
  match records with
  | [] -> 0.5  (* No data → assume moderate uncertainty *)
  | _ ->
    let total_error = List.fold_left (fun acc r -> acc +. r.error) 0.0 records in
    total_error /. Float.of_int (List.length records)

(** {1 v2.0: Temporal Decay}

    Recent reactions matter more than old ones.
    Half-life of ~10 days means 10-day-old reactions have 50% weight.

    Formula: weight = 1.0 / (1.0 + 0.1 * age_days)
*)

(** Half-life for reaction weight decay *)
let decay_half_life_days = 10.0

(** Compute weight for a reaction based on age.
    Recent reactions have higher weight.

    Examples:
    - 0 days old: weight = 1.0
    - 1 day old: weight ≈ 0.91
    - 10 days old: weight = 0.50
    - 30 days old: weight ≈ 0.25 *)
let reaction_weight ~timestamp : float =
  let now = Time_compat.now () in
  let age_days = (now -. timestamp) /. 86400.0 in
  1.0 /. (1.0 +. (1.0 /. decay_half_life_days) *. age_days)

(** {1 v2.0: Dynamic Thresholds}

    Agents with poor calibration should be more conservative.
    Higher error → higher threshold → fewer false positives.

    Reference: A-MEM — self-efficacy monitoring
*)

(** Compute calibrated threshold based on agent's track record.
    Poor calibration (high avg_error) → higher threshold → more conservative.

    Formula: threshold = base_threshold + (avg_error * 0.5)

    Examples:
    - avg_error = 0.0 (perfect): threshold = base
    - avg_error = 0.2: threshold = base + 0.1
    - avg_error = 0.5 (poor): threshold = base + 0.25 *)
let calibrated_threshold ~agent_name ~base_threshold : float =
  let avg_error = avg_calibration_error ~agent_name in
  (* Cap adjustment at 0.25 to prevent overly conservative behavior *)
  let adjustment = Float.min 0.25 (avg_error *. 0.5) in
  base_threshold +. adjustment

(** {1 v2.0: Diversity Alerts} *)

(** Print warning if agent signatures are converging *)
let warn_if_converging ~threshold : unit =
  let pairs = find_similar_pairs ~threshold in
  if pairs <> [] then begin
    eprintf "[Lodge] Warning: Agent convergence detected:\n";
    List.iter (fun (a, b, sim) ->
      eprintf "  - %s <-> %s: %.2f similarity\n" a b sim
    ) pairs
  end
