(** Chain Conversation - Conversational Mode Helpers

    Provides multi-turn conversation management with:
    - Token estimation and summarization
    - Model rotation across providers
    - Context window management
*)

(** {1 Types} *)

(** A single message in conversation history *)
type conv_message = {
  role: string;       (** "user" | "assistant" | "system" *)
  content: string;    (** Message content *)
  model: string;      (** Model that generated this (for assistant messages) *)
  iteration: int;     (** Which iteration this belongs to *)
}

(** Conversation context for maintaining history across iterations *)
type conversation_ctx = {
  mutable history: conv_message list;   (** Accumulated messages (newest first) *)
  mutable current_model: string;        (** Currently active model *)
  mutable model_index: int;             (** Index in model rotation *)
  models: string list;                  (** Available models for rotation *)
  token_threshold: int;                 (** Threshold to trigger summarization *)
  window_size: int;                     (** Keep last N messages without summarizing *)
  mutable total_tokens: int;            (** Estimated total tokens used *)
  mutable summaries: string list;       (** Previous conversation summaries *)
}

(** {1 Token Estimation} *)

(** Estimate token count from string (rough: ~4 chars per token) *)
let estimate_tokens (s : string) : int = (String.length s + 3) / 4

(** Estimate total tokens in conversation *)
let estimate_conversation_tokens (conv : conversation_ctx) : int =
  List.fold_left (fun acc msg -> acc + estimate_tokens msg.content) 0 conv.history
  + List.fold_left (fun acc s -> acc + estimate_tokens s) 0 conv.summaries

(** {1 Context Management} *)

(** Create default conversation context *)
let make ?(models=["gemini"; "claude"; "codex"])
         ?(token_threshold=6000)
         ?(window_size=10) () : conversation_ctx = {
  history = [];
  current_model = (match models with m :: _ -> m | [] -> "gemini");
  model_index = 0;
  models;
  token_threshold;
  window_size;
  total_tokens = 0;
  summaries = [];
}

(** Add a message to conversation history *)
let add_message (conv : conversation_ctx) ~role ~content ~iteration ~model : unit =
  let msg = { role; content; model; iteration } in
  conv.history <- msg :: conv.history;
  conv.total_tokens <- conv.total_tokens + estimate_tokens content

(** Rotate to next model in the list *)
let rotate_model (conv : conversation_ctx) : unit =
  if List.length conv.models > 1 then begin
    conv.model_index <- (conv.model_index + 1) mod List.length conv.models;
    match Chain_utils.list_nth_opt conv.models conv.model_index with
    | Some m -> conv.current_model <- m
    | None -> ()  (* Should never happen due to mod *)
  end

(** Check if summarization is needed *)
let needs_summarization (conv : conversation_ctx) : bool =
  conv.total_tokens > conv.token_threshold &&
  List.length conv.history > conv.window_size

(** Build context prompt from conversation history *)
let build_context_prompt (conv : conversation_ctx) : string =
  let summary_section = match conv.summaries with
    | [] -> ""
    | sums -> "## Previous Context Summary\n" ^ String.concat "\n---\n" sums ^ "\n\n"
  in
  let history_section =
    match List.rev conv.history with
    | [] -> ""
    | recent ->
        "## Recent History\n" ^
        String.concat "\n" (List.map (fun msg ->
          Printf.sprintf "[%s (%s, iter %d)]: %s"
            msg.role msg.model msg.iteration msg.content
        ) recent)
  in
  String.trim (summary_section ^ history_section)

(** {1 Summarization} *)

(** Type of LLM execution function for summarization *)
type exec_fn = model:string -> ?system:string -> prompt:string -> ?tools:Yojson.Safe.t -> ?thinking:bool -> unit -> (string, string) result

(** Summarize history using LLM and compress context *)
let summarize_history ~(exec_fn : exec_fn) (conv : conversation_ctx) : string =
  (* Keep only recent messages for window *)
  let to_summarize, to_keep =
    let rec split n acc = function
      | [] -> (List.rev acc, [])
      | rest when n <= 0 -> (List.rev acc, rest)
      | h :: t -> split (n - 1) (h :: acc) t
    in
    split (List.length conv.history - conv.window_size) [] (List.rev conv.history)
  in
  let history_text = String.concat "\n" (List.map (fun msg ->
    Printf.sprintf "[%s]: %s" msg.role msg.content
  ) to_summarize) in

  let summary_prompt = Printf.sprintf
    "Summarize this conversation context concisely, preserving key decisions, progress, and important information:\n\n%s\n\nProvide a brief summary (under 500 words):"
    history_text
  in
  (* Use current model for summarization *)
  let summary = match exec_fn ~model:conv.current_model ?system:None ~prompt:summary_prompt ?tools:None ?thinking:None () with
    | Ok s -> s
    | Error _ -> "Previous context (summarization failed)"
  in
  (* Update conversation state *)
  conv.summaries <- conv.summaries @ [summary];
  conv.history <- to_keep;
  conv.total_tokens <- estimate_conversation_tokens conv;
  summary

(** Maybe summarize and rotate model if needed *)
let maybe_summarize_and_rotate ~(exec_fn : exec_fn) (conv : conversation_ctx) : unit =
  if needs_summarization conv then begin
    let _ = summarize_history ~exec_fn conv in
    rotate_model conv
  end
