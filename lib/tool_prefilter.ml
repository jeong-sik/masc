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
  ]

let synonym_lookup =
  let tbl = Hashtbl.create 32 in
  List.iter (fun (name, kws) -> Hashtbl.replace tbl name kws) synonyms;
  tbl

let synonym_text name =
  match Hashtbl.find_opt synonym_lookup name with
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
    match Hashtbl.find_opt synonym_lookup schema.name with
    | Some phrases -> List.concat_map tokenize phrases
    | None -> []
  in
  name_words @ desc_tokens @ param_tokens @ syn_tokens

(** Count term frequency in a token list. *)
let term_freq (tokens : string list) : (string, int) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  List.iter (fun t ->
    let prev = match Hashtbl.find_opt tbl t with Some n -> n | None -> 0 in
    Hashtbl.replace tbl t (prev + 1)
  ) tokens;
  tbl

(** Compute IDF values from a collection of documents. *)
let compute_idf (docs : string list list) : (string, float) Hashtbl.t =
  let n = List.length docs in
  let df = Hashtbl.create 64 in
  List.iter (fun doc ->
    let seen = Hashtbl.create 16 in
    List.iter (fun t ->
      if not (Hashtbl.mem seen t) then begin
        Hashtbl.replace seen t ();
        let prev = match Hashtbl.find_opt df t with Some v -> v | None -> 0 in
        Hashtbl.replace df t (prev + 1)
      end
    ) doc
  ) docs;
  let idf = Hashtbl.create 64 in
  Hashtbl.iter (fun term doc_freq ->
    let value = log (float_of_int (n + 1) /. float_of_int (doc_freq + 1)) +. 1.0 in
    Hashtbl.replace idf term value
  ) df;
  idf

(** Build TF-IDF sparse vector for a document given IDF table. *)
let tfidf_vector (tokens : string list) (idf : (string, float) Hashtbl.t) : sparse_vec =
  let tf = term_freq tokens in
  let doc_len = max (List.length tokens) 1 in
  Hashtbl.fold (fun term count acc ->
    let tf_val = float_of_int count /. float_of_int doc_len in
    let idf_val = match Hashtbl.find_opt idf term with Some v -> v | None -> 1.0 in
    (term, tf_val *. idf_val) :: acc
  ) tf []

(** Cosine similarity between two sparse vectors. *)
let cosine (a : sparse_vec) (b : sparse_vec) : float =
  let b_tbl = Hashtbl.create 16 in
  List.iter (fun (t, w) -> Hashtbl.replace b_tbl t w) b;
  let dot = List.fold_left (fun acc (t, wa) ->
    match Hashtbl.find_opt b_tbl t with
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
