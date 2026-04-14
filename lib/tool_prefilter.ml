module StringMap = Map.Make (String)
module StringSet = Set.Make (String)

(** Tool_prefilter — TF-IDF cosine similarity for tool relevance scoring.

    Pure-functional, stateless module. No external dependencies beyond stdlib.
    Index is built per-call from the provided tool list — for 20-50 tools
    this is <1ms and does not warrant caching.

    Zero-result contract: returns [] when query and tools have no token overlap.

    @since 2.170.0 — #4574 *)

(* ================================================================ *)
(* Synonym dictionary (private, immutable)                          *)
(* ================================================================ *)

(** Fixed synonym table. Maps tool name to additional keywords that users
    might use but don't appear in the tool's name or description.
    Derived from Python benchmark data (data/tool-calling-benchmark). *)
let synonyms : (string * string list) list =
  [
    ("masc_dashboard",
     [ "happening"; "activity"; "overview"; "summary"; "monitor"; "big picture" ]);
    ("masc_broadcast",
     [ "notify"; "announce"; "tell"; "inform"; "alert"; "everyone"; "let know" ]);
    ("masc_heartbeat_start",
     [ "automatic"; "recurring"; "periodic"; "auto"; "keep alive"; "start pinging" ]);
    ("masc_heartbeat_stop",
     [ "stop pinging"; "cancel heartbeat"; "end ping"; "halt" ]);
    ("masc_claim_next",
     [ "pick up"; "grab"; "assign me"; "next task"; "give me work"; "take task" ]);
    ("masc_add_task",
     [ "create task"; "new task"; "make task"; "register task" ]);
    ("masc_leave",
     [ "disconnect"; "go offline"; "exit room"; "sign off" ]);
    ("masc_messages",
     [ "chat"; "conversation"; "history"; "log"; "what was said" ]);
    ("masc_agents",
     [ "who is working"; "team members"; "workers"; "collaborators" ]);
    ("masc_status",
     [ "how are things"; "state"; "health"; "situation" ]);
    ("keeper_fs_read",
     [ "contents"; "file contents"; "read file"; "file read"; "source code";
       "open file"; "show file"; "cat file"; "view file"; "file content" ]);
    ("keeper_fs_edit",
     [ "write file"; "create file"; "edit file"; "save file"; "new file";
       "make file"; "update file"; "overwrite"; "append to file" ]);
    ("keeper_shell",
     [ "run command"; "shell read only"; "safe command"; "grep"; "rg search";
       "list files"; "directory listing"; "git status"; "find file" ]);
    ("keeper_bash",
     [ "run shell"; "execute command"; "build"; "test"; "compile"; "dune build";
       "npm"; "cargo"; "shell command"; "bash command" ]);
    ("keeper_github",
     [ "pull request"; "issue"; "pr"; "github"; "gh cli"; "create pr";
       "open issue"; "ci status"; "repository"; "git hub" ]);
    ("keeper_board_get",
     [ "read post"; "view post"; "get post"; "board post detail";
       "show post"; "inspect post" ]);
    ("keeper_board_post",
     [ "create post"; "new post"; "share finding"; "write post";
       "publish post"; "board write" ]);
    ("keeper_board_list",
     [ "list posts"; "browse board"; "recent posts"; "forum"; "feed";
       "board posts"; "discussion list" ]);
    ("keeper_board_comment",
     [ "reply"; "add comment"; "respond"; "comment on post"; "feedback" ]);
    ("keeper_board_vote",
     [ "upvote"; "downvote"; "rate"; "like"; "agree disagree"; "vote on" ]);
    ("keeper_board_search",
     [ "search board"; "find post"; "search discussion"; "keyword search board" ]);
    ("keeper_board_delete",
     [ "delete post"; "remove post"; "trash post" ]);
    ("keeper_board_stats",
     [ "board statistics"; "activity stats"; "engagement"; "post count" ]);
    ("keeper_tasks_list",
     [ "backlog"; "todo list"; "task list"; "available tasks"; "task board";
       "work items"; "assignee" ]);
    ("keeper_task_create",
     [ "create task"; "new task"; "add task"; "make task"; "propose work";
       "found work"; "needs doing"; "backlog item"; "discovered issue" ]);
    ("keeper_task_claim",
     [ "claim task"; "pick up task"; "assign me task"; "take task";
       "next task"; "give me work" ]);
    ("keeper_task_done",
     [ "complete task"; "finish task"; "mark done"; "task completed";
       "task finished"; "done with task" ]);
    ("keeper_task_force_release",
     [ "release task"; "unassign task"; "free task"; "orphaned task";
       "stuck task"; "unclaim task" ]);
    ("keeper_task_force_done",
     [ "force complete"; "mark task done by force"; "force finish task" ]);
    ("keeper_memory_search",
     [ "remember"; "recall"; "memory"; "past conversation"; "what was said";
       "search memory"; "find memory"; "previous discussion" ]);
    ("keeper_library_search",
     [ "knowledge library"; "docs"; "documentation"; "lookup docs";
       "search docs"; "reference"; "knowledge base"; "wiki" ]);
    ("keeper_library_read",
     [ "read document"; "read docs"; "library topic"; "full document";
       "knowledge article" ]);
    ("keeper_tools_list",
     [ "what can you do"; "capabilities"; "available tools"; "my tools";
       "list capabilities"; "tool list"; "discover tools" ]);
    ("keeper_context_status",
     [ "context window"; "token usage"; "how much space"; "remaining context";
       "context usage"; "memory status"; "session state" ]);
    ("keeper_time_now",
     [ "current time"; "what time"; "timestamp"; "date now"; "clock";
       "server time"; "time now" ]);
    ("keeper_broadcast",
     [ "broadcast"; "announce to all"; "tell everyone"; "notify all";
       "send message all" ]);
    ("keeper_voice_speak",
     [ "speak"; "say out loud"; "talk"; "voice output"; "text to speech";
       "tts"; "say something" ]);
    ("keeper_voice_listen",
     [ "listen"; "microphone"; "speech to text"; "transcribe"; "hear";
       "voice input"; "record speech" ]);
    ("keeper_pr_workflow",
     [ "create pr"; "new pull request"; "open draft pr"; "one shot pr";
       "push and pr"; "submit pr" ]);
    ("keeper_tool_search",
     [ "find tool"; "discover tool"; "search tools"; "what tool";
       "tool for"; "which tool" ]);
    ("keeper_stay_silent",
     [ "do nothing"; "skip turn"; "no action"; "stay quiet"; "no response";
       "silent"; "침묵"; "대기"; "아무것도 안함" ]);
    ("keeper_tasks_audit",
     [ "audit tasks"; "orphaned tasks"; "stale tasks"; "zombie tasks";
       "task cleanup"; "find abandoned"; "고아 태스크"; "방치 태스크"; "태스크 감사" ]);
    ("keeper_voice_agent",
     [ "voice settings"; "speech config"; "tts config"; "voice configure";
       "음성 설정"; "보이스 구성"; "TTS 설정" ]);
    ("keeper_voice_session_start",
     [ "start voice session"; "begin voice call"; "open voice channel";
       "음성 세션 시작"; "보이스 통화 시작" ]);
    ("keeper_voice_session_end",
     [ "end voice session"; "close voice call"; "stop voice channel";
       "음성 세션 종료"; "보이스 통화 종료" ]);
    ("keeper_voice_sessions",
     [ "list voice sessions"; "voice session history"; "active calls";
       "음성 세션 목록"; "보이스 세션" ]);
    ("keeper_write",
     [ "write file"; "create file"; "save file"; "new file";
       "파일 작성"; "파일 저장"; "새 파일" ]);
    (* masc_code_* — code manipulation tools *)
    ("masc_code_search",
     [ "search code"; "find code"; "code lookup"; "grep code"; "find symbol";
       "search source"; "codebase search"; "code query" ]);
    ("masc_code_read",
     [ "read code"; "view code"; "source file"; "open source"; "code contents";
       "read source"; "show code" ]);
    ("masc_code_edit",
     [ "edit code"; "modify code"; "change code"; "update code"; "patch code";
       "code change" ]);
    ("masc_code_write",
     [ "write code"; "create code"; "new file code"; "generate code";
       "code creation" ]);
    ("masc_code_symbols",
     [ "code symbols"; "function list"; "class definitions"; "symbol overview";
       "navigate code"; "code structure" ]);
    ("masc_code_shell",
     [ "code shell"; "run code command"; "execute in code"; "code exec" ]);
    ("masc_code_git",
     [ "code git"; "git in code"; "code commit"; "code branch"; "code log" ]);
    (* masc_governance_* — policy and rules *)
    ("masc_governance_status",
     [ "governance status"; "policy status"; "rules check"; "compliance check" ]);
    ("masc_governance_feed",
     [ "governance feed"; "policy events"; "rule changes"; "governance log" ]);
    ("masc_governance_set",
     [ "set governance"; "change policy"; "update rules"; "configure governance" ]);
    (* masc_autoresearch_* — automated research *)
    ("masc_autoresearch_start",
     [ "start research"; "begin research"; "auto research"; "autoresearch start" ]);
    ("masc_autoresearch_status",
     [ "research status"; "autoresearch status"; "research progress" ]);
    ("masc_autoresearch_stop",
     [ "stop research"; "cancel research"; "end autoresearch" ]);
    ("masc_autoresearch_cycle",
     [ "research cycle"; "run cycle"; "autoresearch cycle"; "execute research" ]);
    (* masc_plan_* — project planning *)
    ("masc_plan_get",
     [ "get plan"; "view plan"; "show plan"; "current plan"; "roadmap" ]);
    ("masc_plan_init",
     [ "init plan"; "create plan"; "new plan"; "setup plan"; "plan setup" ]);
    ("masc_plan_update",
     [ "update plan"; "modify plan"; "change plan"; "edit plan"; "revise plan" ]);
    ("masc_plan_set_task",
     [ "set task in plan"; "assign plan task"; "plan task set"; "current task plan" ]);
    ("masc_plan_get_task",
     [ "get task from plan"; "plan task"; "current plan task" ]);
    ("masc_plan_clear_task",
     [ "clear plan task"; "remove plan task"; "unassign plan task" ]);
    (* masc_worktree_* — git worktree management *)
    ("masc_worktree_create",
     [ "create worktree"; "new worktree"; "isolated branch"; "git worktree add" ]);
    ("masc_worktree_list",
     [ "list worktrees"; "show worktrees"; "worktree status" ]);
    ("masc_worktree_remove",
     [ "remove worktree"; "delete worktree"; "cleanup worktree" ]);
    (* masc_agent_* — agent management *)
    ("masc_agent_card",
     [ "agent card"; "agent profile"; "agent info"; "who is agent" ]);
    ("masc_agent_update",
     [ "update agent"; "change agent"; "agent modify"; "agent settings" ]);
    ("masc_agent_fitness",
     [ "agent fitness"; "agent evaluation"; "agent score"; "rate agent" ]);
    (* masc auth *)
    ("masc_auth_status",
     [ "auth status"; "authentication"; "token status"; "credentials" ]);
    ("masc_auth_refresh",
     [ "refresh token"; "renew auth"; "auth refresh"; "token refresh" ]);
    (* masc web search *)
    ("masc_web_search",
     [ "web search"; "search internet"; "search online"; "google" ]);
    (* masc keeper management — tools available via BM25 but missing from TF-IDF *)
    ("masc_keeper_up",
     [ "start keeper"; "launch keeper"; "spawn keeper"; "keeper create" ]);
    ("masc_keeper_down",
     [ "stop keeper"; "shutdown keeper"; "kill keeper"; "keeper terminate" ]);
    ("masc_keeper_list",
     [ "list keepers"; "show keepers"; "keeper status all"; "active keepers" ]);
    ("masc_keeper_msg",
     [ "send keeper message"; "talk to keeper"; "message keeper"; "keeper chat" ]);
    ("masc_keeper_status",
     [ "keeper health"; "keeper state"; "keeper check"; "keeper info" ]);
    ("masc_keeper_compact",
     [ "compact keeper"; "shrink context"; "reduce context"; "context overflow fix" ]);
    ("masc_keeper_clear",
     [ "clear keeper"; "reset keeper context"; "wipe keeper history"; "emergency clear" ]);
    (* masc heartbeat — lifecycle tools *)
    ("masc_heartbeat_start",
     [ "start heartbeat"; "begin pinging"; "auto ping"; "keep alive" ]);
    ("masc_heartbeat_stop",
     [ "stop heartbeat"; "end ping"; "cancel heartbeat"; "halt ping" ]);
    (* masc core — room operations *)
    ("masc_claim_next",
     [ "claim next task"; "pick up task"; "assign me"; "next task"; "give me work"; "take task" ]);
    ("masc_leave",
     [ "disconnect"; "go offline"; "exit room"; "sign off"; "leave room" ]);
    ("masc_dashboard",
     [ "happening"; "activity"; "overview"; "summary"; "monitor"; "big picture" ]);
    ("masc_broadcast",
     [ "notify"; "announce"; "tell"; "inform"; "alert"; "everyone"; "let know" ]);
    ("masc_messages",
     [ "chat"; "conversation"; "history"; "log"; "what was said" ]);
    (* masc plan — clear task *)
    ("masc_plan_clear_task",
     [ "clear plan task"; "remove plan task"; "unassign plan task" ]);
    (* masc agent fitness *)
    ("masc_agent_fitness",
     [ "agent fitness"; "agent evaluation"; "agent score"; "rate agent" ]);
    (* keeper voice listen *)
    ("keeper_voice_listen",
     [ "listen"; "microphone"; "speech to text"; "transcribe"; "hear"; "voice input"; "record speech" ]);
    (* keeper stay silent *)
    ("keeper_stay_silent",
     [ "do nothing"; "skip turn"; "no action"; "stay quiet"; "no response"; "silent" ]);
    (* keeper write *)
    ("keeper_write",
     [ "write file"; "create file"; "save file"; "new file" ]);
    (* keeper board search/delete/stats *)
    ("keeper_board_search",
     [ "search board"; "find post"; "search discussion"; "keyword search board" ]);
    ("keeper_board_delete",
     [ "delete post"; "remove post"; "trash post" ]);
    ("keeper_board_stats",
     [ "board statistics"; "activity stats"; "engagement"; "post count" ]);
    (* keeper tool search *)
    ("keeper_tool_search",
     [ "find tool"; "discover tool"; "search tools"; "what tool"; "tool for"; "which tool" ]);
  ]

let synonym_lookup : string list StringMap.t =
  List.fold_left (fun m (name, kws) -> StringMap.add name kws m) StringMap.empty synonyms

let synonym_text name =
  match StringMap.find_opt name synonym_lookup with
  | Some kws -> String.concat " " kws
  | None -> ""

(* ================================================================ *)
(* Tokenizer                                                        *)
(* ================================================================ *)

let is_alnum c =
  (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')

(** Tokenize text into lowercase alphanumeric words. *)
let tokenize (text : string) : string list =
  let s = String.lowercase_ascii text in
  let len = String.length s in
  let buf = Buffer.create 32 in
  let tokens = ref [] in
  for i = 0 to len - 1 do
    let c = String.get s i in
    if is_alnum c then
      Buffer.add_char buf c
    else begin
      if Buffer.length buf > 0 then begin
        tokens := Buffer.contents buf :: !tokens;
        Buffer.clear buf
      end
    end
  done;
  if Buffer.length buf > 0 then
    tokens := Buffer.contents buf :: !tokens;
  List.rev !tokens

(* ================================================================ *)
(* TF-IDF engine                                                    *)
(* ================================================================ *)

(** Sparse vector: (term, weight) list. *)
type sparse_vec = (string * float) list

(** Build a document (token list) for a tool schema. *)
let build_document (schema : Types.tool_schema) : string list =
  let name_words =
    schema.name
    |> String.split_on_char '_'
    |> List.filter (fun w -> w <> "masc" && w <> "")
  in
  let desc_tokens = tokenize schema.description in
  let param_tokens =
    match schema.input_schema with
    | `Assoc fields ->
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc props) ->
         List.concat_map (fun (key, value) ->
           let key_parts = String.split_on_char '_' key in
           let desc_parts =
             match value with
             | `Assoc vf ->
               (match List.assoc_opt "description" vf with
                | Some (`String d) -> tokenize d
                | _ -> [])
             | _ -> []
           in
           key_parts @ desc_parts
         ) props
       | _ -> [])
    | _ -> []
  in
  let syn_tokens =
    match StringMap.find_opt schema.name synonym_lookup with
    | Some phrases -> List.concat_map tokenize phrases
    | None -> []
  in
  name_words @ desc_tokens @ param_tokens @ syn_tokens

(** Count term frequency in a token list. *)
let term_freq (tokens : string list) : int StringMap.t =
  List.fold_left (fun m t ->
    let prev = match StringMap.find_opt t m with Some n -> n | None -> 0 in
    StringMap.add t (prev + 1) m
  ) StringMap.empty tokens

(** Compute IDF values from a collection of documents. *)
let compute_idf (docs : string list list) : float StringMap.t =
  let n = List.length docs in
  let df = List.fold_left (fun df doc ->
    let seen = List.fold_left (fun seen t ->
      if not (StringSet.mem t seen) then
        StringSet.add t seen
      else
        seen
    ) StringSet.empty doc in
    StringSet.fold (fun t acc ->
      let prev = match StringMap.find_opt t acc with Some v -> v | None -> 0 in
      StringMap.add t (prev + 1) acc
    ) seen df
  ) StringMap.empty docs in
  StringMap.map (fun doc_freq ->
    log (float_of_int (n + 1) /. float_of_int (doc_freq + 1)) +. 1.0
  ) df

(** Build TF-IDF sparse vector for a document given IDF table. *)
let tfidf_vector (tokens : string list) (idf : float StringMap.t) : sparse_vec =
  let tf = term_freq tokens in
  let doc_len = max (List.length tokens) 1 in
  StringMap.fold (fun term count acc ->
    let tf_val = float_of_int count /. float_of_int doc_len in
    let idf_val = match StringMap.find_opt term idf with Some v -> v | None -> 1.0 in
    (term, tf_val *. idf_val) :: acc
  ) tf []

(** Cosine similarity between two sparse vectors. *)
let cosine (a : sparse_vec) (b : sparse_vec) : float =
  let b_tbl = List.fold_left (fun m (t, w) -> StringMap.add t w m) StringMap.empty b in
  let dot = List.fold_left (fun acc (t, wa) ->
    match StringMap.find_opt t b_tbl with
    | Some wb -> acc +. (wa *. wb)
    | None -> acc
  ) 0.0 a in
  if dot = 0.0 then 0.0
  else
    let norm v = sqrt (List.fold_left (fun acc (_, w) -> acc +. (w *. w)) 0.0 v) in
    let na = norm a in
    let nb = norm b in
    if na = 0.0 || nb = 0.0 then 0.0
    else dot /. (na *. nb)

(* ================================================================ *)
(* Public API                                                       *)
(* ================================================================ *)

let filter_with_scores ~(tools : Types.tool_schema list) ~(query : string)
    ~(k : int) : (Types.tool_schema * float) list =
  let query_tokens = tokenize query in
  if query_tokens = [] then []
  else
    let docs = List.map build_document tools in
    let idf = compute_idf (query_tokens :: docs) in
    let query_vec = tfidf_vector query_tokens idf in
    let tool_vecs = List.map (fun doc -> tfidf_vector doc idf) docs in
    let scored = List.map2 (fun schema vec ->
      let score = cosine query_vec vec in
      (schema, score)
    ) tools tool_vecs in
    (* Filter zero-score results *)
    let nonzero = List.filter (fun (_, s) -> s > 0.0) scored in
    if nonzero = [] then []
    else
      let sorted = List.sort (fun (_, a) (_, b) -> Float.compare b a) nonzero in
      let rec take n = function
        | [] -> []
        | x :: rest -> if n <= 0 then [] else x :: take (n - 1) rest
      in
      take k sorted

let filter ~(tools : Types.tool_schema list) ~(query : string) ~(k : int)
    : Types.tool_schema list =
  filter_with_scores ~tools ~query ~k
  |> List.map fst
