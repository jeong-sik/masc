(* The absorb gate of a librarian pass (RFC-librarian-absorb-gate). See the
   interface for what it decides; this file is how. *)

(* --- Statements --- *)

let min_statement_chars = 20

let is_ascii_space c =
  c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '\012' || c = '\011'
;;

(* Characters, not bytes: the carry rule below counts what a reader sees,
   and the scorer this cut mirrors counted code points. *)
let utf8_length s =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
  !n
;;

let strip s =
  let n = String.length s in
  let i = ref 0 in
  while !i < n && is_ascii_space s.[!i] do
    incr i
  done;
  let j = ref n in
  while !j > !i && is_ascii_space s.[!j - 1] do
    decr j
  done;
  String.sub s !i (!j - !i)
;;

let da_period = "\xEB\x8B\xA4." (* 다. *)
let em_dash = "\xE2\x80\x94" (* — *)

let starts_with_at s i lit =
  let n = String.length lit in
  i + n <= String.length s && String.sub s i n = lit
;;

(* [line] cut at sentence ends. A boundary is: [. ! ?] followed by a run of
   whitespace (the run is dropped); [다.] followed by any whitespace (dropped);
   [;] followed by a run of whitespace (dropped); a run of whitespace, an em
   dash, a run of whitespace (all dropped). Pieces are stripped and empty
   ones left out. *)
let cut_line line =
  let n = String.length line in
  let pieces = ref [] in
  let start = ref 0 in
  let emit stop =
    let piece = strip (String.sub line !start (stop - !start)) in
    if piece <> "" then pieces := piece :: !pieces
  in
  let skip_spaces i =
    let j = ref i in
    while !j < n && is_ascii_space line.[!j] do
      incr j
    done;
    !j
  in
  let i = ref 0 in
  while !i < n do
    let c = line.[!i] in
    if starts_with_at line !i da_period
    then (
      let after = !i + String.length da_period in
      emit after;
      start := skip_spaces after;
      i := !start)
    else if (c = '.' || c = '!' || c = '?' || c = ';')
            && !i + 1 < n
            && is_ascii_space line.[!i + 1]
    then (
      emit (!i + 1);
      start := skip_spaces (!i + 1);
      i := !start)
    else if is_ascii_space c
    then (
      let after_spaces = skip_spaces !i in
      if after_spaces < n
         && starts_with_at line after_spaces em_dash
         && after_spaces + String.length em_dash < n
         && is_ascii_space line.[after_spaces + String.length em_dash]
      then (
        emit !i;
        start := skip_spaces (after_spaces + String.length em_dash);
        i := !start)
      else i := after_spaces)
    else incr i
  done;
  emit n;
  List.rev !pieces
;;

let statements text =
  let pieces = List.concat_map cut_line (String.split_on_char '\n' text) in
  (* A short piece is carried into the next; a short tail joins the last. *)
  let out, carry =
    List.fold_left
      (fun (out, carry) piece ->
         let carry = strip (carry ^ " " ^ piece) in
         if utf8_length carry >= min_statement_chars then carry :: out, "" else out, carry)
      ([], "")
      pieces
  in
  match out, carry with
  | out, "" -> List.rev out
  | last :: rest, tail -> List.rev ((last ^ " " ^ tail) :: rest)
  | [], tail -> [ tail ]
;;

(* --- Judgment --- *)

type evaluate =
  state:Yojson.Safe.t
  -> questions:(string * Typesafeai_types.question) list
  -> (Typesafeai_types.eval_response, string) result

type source_verdict =
  { memory_id : string
  ; into : string
  ; statements : int
  ; not_conveyed : int
  }

type judged =
  { absorbed : Keeper_memory_os_types.absorbed_statement list
  ; left : source_verdict list
  ; conveyed : source_verdict list
  ; unjudged : Keeper_memory_os_types.absorbed_statement list
  ; unjudgeable : Keeper_memory_os_types.absorbed_statement list
  ; requests : int
  }

type outcome =
  | Open of
      { reason : string
      ; absorbed : Keeper_memory_os_types.absorbed_statement list
      ; left : source_verdict list
      ; conveyed : source_verdict list
      ; unjudged : Keeper_memory_os_types.absorbed_statement list
      ; unjudgeable : Keeper_memory_os_types.absorbed_statement list
      }
  | Judged of judged

let conveyed_boundary = 0.5
let questions_per_request = 64

(* The model takes 32k tokens for the state and, per request, 64k at
   TypeSafe but 32k on the OpenRouter route the lane can be pointed at
   (docs/research/2026-09-21-typesafe-jev-public-usage-evidence-record.md
   section 6). The bounds are the smaller numbers in bytes: a token is at
   least one byte, so text under the byte bound is under the token bound
   whatever its tokenizer makes of it (JSON escaping is not tokenized). A
   request refused for its size would open the gate for exactly the memory
   it should keep, so what cannot fit is decided here, before asking.
   Statements are not bounded by the cut -- a memory without sentence ends
   is one statement -- so a statement that does not fit a request beside
   its claim, or a claim over its own bound, cannot be judged; that memory
   stays current.

   The claim and the questions share one request, so the claim's bound is
   half of it: the questions always have the other half (about fifty of
   them at their usual size), and a claim never leaves them nothing. The
   35,874 merged claims of the production replay behind issue #37079 were
   at most 14,127 bytes (p99 5,394, median 611) on 2026-09-21; a claim
   over the bound keeps everything it absorbs current, which is the
   cautious side. *)
let request_bytes_limit = 32_000
let state_bytes_limit = request_bytes_limit / 2

let instructions_prefix =
  "The claim under review conveys this statement, in any wording.\n\nStatement:\n"
;;

let criteria =
  ( "A reader of the claim alone would learn what the statement says, even if worded differently."
  , "The claim does not say what the statement says, or says only a vaguer version of it." )
;;

let question statement =
  Typesafeai_types.Noul
    { Typesafeai_types.instructions = instructions_prefix ^ statement
    ; criteria = Some criteria
    }
;;

(* What a statement adds to a request: its question, fixed text included. *)
let question_bytes statement =
  String.length instructions_prefix
  + String.length statement
  + String.length (fst criteria)
  + String.length (snd criteria)
;;

(* [numbered] cut into requests of at most [questions_per_request] questions
   and at most [budget] bytes of questions each. Every question fits alone
   by construction (the caller keeps out the statements that do not). *)
let chunks ~budget numbered =
  let rec go current_bytes current acc = function
    | [] -> List.rev (if current = [] then acc else List.rev current :: acc)
    | ((_, statement) as item) :: rest ->
      let bytes = question_bytes statement in
      if current <> []
         && (List.length current >= questions_per_request
             || current_bytes + bytes > budget)
      then go bytes [ item ] (List.rev current :: acc) rest
      else go (current_bytes + bytes) (item :: current) acc rest
  in
  go 0 [] [] numbered
;;

(* The answers of one response for [chunk], or why they cannot be read. *)
let decode chunk (response : Typesafeai_types.eval_response) =
  let open Result.Syntax in
  List.fold_left
    (fun acc (id, _) ->
       let* acc = acc in
       match List.assoc_opt id response.Typesafeai_types.answers with
       | Some (Typesafeai_types.Noul_answer { noul }) ->
         if Float.is_nan noul || noul < 0.0 || noul > 1.0
         then Error (Printf.sprintf "answer %s is not a probability: %g" id noul)
         else Ok ((id, noul) :: acc)
       | Some (Typesafeai_types.Choice_answer _ | Typesafeai_types.Score_answer _) ->
         Error (Printf.sprintf "answer %s is not a noul" id)
       | None -> Error (Printf.sprintf "no answer for %s" id))
    (Ok [])
    chunk
;;

(* Every statement of [numbered], asked in requests of at most
   [questions_per_request] questions, answered as a table from question id
   to [noul]. Asking stops at the first request that fails or cannot be
   read; the table holds the answers before it and the reason comes back
   beside it, so a verdict already reached is not lost to a later failure. *)
let ask ~evaluate ~claim (numbered : (string * string) list) =
  let state = `String claim in
  let budget = request_bytes_limit - String.length claim in
  let rec go table requests = function
    | [] -> table, requests, None
    | chunk :: rest ->
      let questions = List.map (fun (id, statement) -> id, question statement) chunk in
      (match evaluate ~state ~questions with
       | Error reason -> table, requests, Some reason
       | Ok response ->
         (match decode chunk response with
          | Error reason -> table, requests + 1, Some reason
          | Ok answers -> go (answers @ table) (requests + 1) rest))
  in
  go [] 0 (chunks ~budget numbered)
;;

(* The answer's absorptions into one claim, classified before any request
   is made: what has no claim or no source text passes through unjudged,
   what does not fit a request ({!state_bytes_limit}, {!request_bytes_limit}) cannot be judged
   and stays current, the rest is asked. Classifying first is what lets a
   request that fails for another reason leave the unjudgeable alone. *)
type group =
  { into : string
  ; claim : string option
  ; unjudged : Keeper_memory_os_types.absorbed_statement list
  ; unjudgeable : Keeper_memory_os_types.absorbed_statement list
  ; judgeable : (Keeper_memory_os_types.absorbed_statement * string list) list
  }

let classify ~facts ~new_claims ~absorbed =
  let claim_of id =
    List.find_map
      (fun (fact : Keeper_memory_os_types.fact) ->
         if String.equal (Keeper_memory_os_types.memory_id fact) id
         then Some fact.claim
         else None)
  in
  (* By absorbing claim, in the answer's order. *)
  let by_into =
    List.fold_left
      (fun groups (statement : Keeper_memory_os_types.absorbed_statement) ->
         match List.assoc_opt statement.into groups with
         | Some members -> (statement.into, statement :: members) :: List.remove_assoc statement.into groups
         | None -> (statement.into, [ statement ]) :: groups)
      []
      absorbed
    |> List.rev_map (fun (into, members) -> into, List.rev members)
  in
  List.map
    (fun (into, members) ->
       match claim_of into new_claims with
       | None -> { into; claim = None; unjudged = members; unjudgeable = []; judgeable = [] }
       | Some claim when String.length claim > state_bytes_limit ->
         (* The claim does not fit the state: nothing it absorbs can be judged
            against it, and nothing it absorbs is absorbed. *)
         { into; claim = Some claim; unjudged = []; unjudgeable = members; judgeable = [] }
       | Some claim ->
         let judgeable, unjudged =
           List.partition_map
             (fun (statement : Keeper_memory_os_types.absorbed_statement) ->
                match claim_of statement.absorbed facts with
                | Some text -> Either.Left (statement, statements text)
                | None -> Either.Right statement)
             members
         in
         let budget = request_bytes_limit - String.length claim in
         let judgeable, unjudgeable =
           List.partition
             (fun (_, sts) -> List.for_all (fun st -> question_bytes st <= budget) sts)
             judgeable
         in
         { into; claim = Some claim; unjudged; unjudgeable = List.map fst unjudgeable; judgeable })
    by_into
;;

let judge ~evaluate ~facts ~new_claims ~absorbed =
  let groups = classify ~facts ~new_claims ~absorbed in
  let same
        (a : Keeper_memory_os_types.absorbed_statement)
        (b : Keeper_memory_os_types.absorbed_statement)
    =
    String.equal a.absorbed b.absorbed && String.equal a.into b.into
  in
  (* [absorbed] in the answer's order, so the store sees the answer's list
     minus what the gate took out. *)
  let answer_without out =
    List.filter
      (fun (statement : Keeper_memory_os_types.absorbed_statement) ->
         not (List.exists (same statement) out))
      absorbed
  in
  let of_verdict (verdict : source_verdict) : Keeper_memory_os_types.absorbed_statement =
    { Keeper_memory_os_types.absorbed = verdict.memory_id; into = verdict.into }
  in
  let rec go (acc : judged) = function
    | [] -> Ok acc
    | (group : group) :: rest ->
      let acc =
        { acc with
          absorbed = acc.absorbed @ group.unjudged
        ; unjudged = acc.unjudged @ group.unjudged
        ; unjudgeable = acc.unjudgeable @ group.unjudgeable
        }
      in
      (match group.claim, group.judgeable with
       | None, _ | Some _, [] -> go acc rest
       | Some claim, judgeable ->
         let numbered =
           List.concat
             (List.mapi
                (fun i (_, sts) -> List.mapi (fun k s -> Printf.sprintf "s%d_%d" i k, s) sts)
                judgeable)
         in
         let table, requests, failure = ask ~evaluate ~claim numbered in
         (* A source over the statements answered so far: one not conveyed
            keeps it current; all conveyed absorbs it once every statement
            was answered. *)
         let verdicts =
           List.mapi
             (fun i ((statement : Keeper_memory_os_types.absorbed_statement), sts) ->
                let answered, not_conveyed =
                  List.fold_left
                    (fun (answered, not_conveyed) k ->
                       match List.assoc_opt (Printf.sprintf "s%d_%d" i k) table with
                       | None -> answered, not_conveyed
                       | Some noul ->
                         ( answered + 1
                         , if noul < conveyed_boundary then not_conveyed + 1 else not_conveyed ))
                    (0, 0)
                    (List.init (List.length sts) Fun.id)
                in
                ( statement
                , answered
                , { memory_id = statement.absorbed
                  ; into = group.into
                  ; statements = List.length sts
                  ; not_conveyed
                  } ))
             judgeable
         in
         let left =
           List.filter_map
             (fun (statement, _, verdict) ->
                if verdict.not_conveyed > 0 then Some (statement, verdict) else None)
             verdicts
         in
         let kept =
           List.filter_map
             (fun (statement, answered, verdict) ->
                if verdict.not_conveyed = 0 && answered = verdict.statements
                then Some (statement, verdict)
                else None)
             verdicts
         in
         let acc =
           { acc with
             absorbed = acc.absorbed @ List.map fst kept
           ; left = acc.left @ List.map snd left
           ; conveyed = acc.conveyed @ List.map snd kept
           ; requests = acc.requests + requests
           }
         in
         (match failure with
          | None -> go acc rest
          | Some reason -> Error (reason, acc)))
  in
  let init =
    { absorbed = []; left = []; conveyed = []; unjudged = []; unjudgeable = []; requests = 0 }
  in
  match go init groups with
  | Ok judged ->
    Judged
      { judged with
        absorbed =
          List.filter
            (fun (statement : Keeper_memory_os_types.absorbed_statement) ->
               List.exists (same statement) judged.absorbed)
            absorbed
      }
  | Error (reason, acc) ->
    (* What the gate had decided stays decided: the unjudgeable of every
       group, and the sources a completed answer showed not conveyed. The
       rest is applied as answered. *)
    let unjudgeable = List.concat_map (fun (group : group) -> group.unjudgeable) groups in
    let unjudged = List.concat_map (fun (group : group) -> group.unjudged) groups in
    Open
      { reason
      ; absorbed = answer_without (unjudgeable @ List.map of_verdict acc.left)
      ; left = acc.left
      ; conveyed = acc.conveyed
      ; unjudged
      ; unjudgeable
      }
;;

(* --- Entry point --- *)

type skip_reason = No_absorptions | Unavailable of Typesafeai_config.unavailable_reason

type evaluation =
  { endpoint : string
  ; model : string
  ; state : Yojson.Safe.t
  ; questions : (string * Typesafeai_types.question) list
  ; result : (Typesafeai_client.evaluated, Typesafeai_client.failure) result
  }

type run_result =
  | Skipped of
      { reason : skip_reason
      ; absorbed : Keeper_memory_os_types.absorbed_statement list
      }
  | Evaluated of
      { outcome : outcome
      ; evaluations : evaluation list
      }

let absorbed_of_run = function
  | Skipped { absorbed; _ }
  | Evaluated { outcome = Open { absorbed; _ }; _ }
  | Evaluated { outcome = Judged { absorbed; _ }; _ } -> absorbed
;;

let evaluation_to_yojson { endpoint; model; state; questions; result } =
  let response =
    match result with
    | Error failure ->
      [ "status", `String "failed"
      ; "reason", `String (Typesafeai_client.failure_to_string failure)
      ; "failure", Typesafeai_client.failure_to_yojson failure
      ]
    | Ok evaluated ->
      let answers =
        match decode questions evaluated.Typesafeai_client.response with
        | Ok answers ->
          [ "status", `String "answered"
          ; "model", `String evaluated.response.model
          ; "answers", `Assoc (List.rev_map (fun (id, noul) -> id, `Float noul) answers)
          ]
        | Error reason ->
          [ "status", `String "invalid_answer"
          ; "model", `String evaluated.response.model
          ; "reason", `String reason
          ; "returned_answers", `Assoc
              (List.map (fun (id, answer) -> id, Typesafeai_types.answer_to_yojson answer)
                 evaluated.response.answers)
          ]
      in
      answers
      @ [ "request_body_sha256", `String evaluated.request_body_sha256
        ; "destination_uri", `String evaluated.destination_uri
        ; "usage",
          (match evaluated.response.usage with
           | None -> `Null
           | Some usage -> `Assoc
               [ "input_tokens", `Int usage.input_tokens
               ; "output_tokens", `Int usage.output_tokens
               ])
        ]
  in
  (* Question IDs are reused across requests. Keep their state and wording in
     this durable report so each answer remains interpretable; the outbound
     body hash identifies bytes but cannot recover that context. *)
  `Assoc (response
    @ [ "request", `Assoc
          [ "endpoint", `String endpoint
          ; "model", `String model
          ; "state", state
          ; "questions", `Assoc
              (List.map (fun (id, question) -> id, Typesafeai_types.question_to_yojson question)
                 questions)
          ] ])
;;

let run_result_to_yojson result =
  let absorptions values =
    `List (List.map (fun (value : Keeper_memory_os_types.absorbed_statement) ->
      `Assoc [ "absorbed", `String value.absorbed; "into", `String value.into ]) values)
  in
  let verdicts values =
    `List (List.map (fun (value : source_verdict) ->
      `Assoc [ "memory_id", `String value.memory_id; "into", `String value.into
             ; "statements", `Int value.statements; "not_conveyed", `Int value.not_conveyed ]) values)
  in
  let fields =
    match result with
    | Skipped { reason; absorbed } ->
      [ "status", `String "skipped"
      ; "reason", `String (match reason with
          | No_absorptions -> "no_absorptions"
          | Unavailable reason -> Typesafeai_config.unavailable_reason_to_string reason)
      ; "applied_absorptions", absorptions absorbed
      ]
    | Evaluated { outcome; evaluations } ->
      let status, disposition =
        match outcome with
        | Open { reason; absorbed; left; conveyed; unjudged; unjudgeable } ->
          ([ "status", `String "open"; "reason", `String reason ],
           [ "applied_absorptions", absorptions absorbed
           ; "left", verdicts left; "conveyed", verdicts conveyed
           ; "unjudged", absorptions unjudged
           ; "unjudgeable", absorptions unjudgeable ])
        | Judged judged ->
          ([ "status", `String "judged" ],
           [ "applied_absorptions", absorptions judged.absorbed
           ; "left", verdicts judged.left; "conveyed", verdicts judged.conveyed
           ; "unjudged", absorptions judged.unjudged
           ; "unjudgeable", absorptions judged.unjudgeable
           ; "requests", `Int judged.requests ])
      in
      status @ [ "conveyed_boundary", `Float conveyed_boundary ] @ disposition
      @ [ "evaluations", `List (List.map evaluation_to_yojson evaluations) ]
  in
  `Assoc fields
;;

let run ?clock ~keeper_id ~facts ~new_claims ~absorbed () =
  match absorbed with
  | [] -> Skipped { reason = No_absorptions; absorbed }
  | _ :: _ ->
    (match Typesafeai_config.absorb_gate_api_key () with
     | Error reason ->
       Log.Keeper.info
         ~keeper_name:keeper_id
         "librarian absorb gate off (%s): %d absorption(s) applied as answered"
         (Typesafeai_config.unavailable_reason_to_string reason)
         (List.length absorbed);
       Skipped { reason = Unavailable reason; absorbed }
     | Ok api_key ->
       let endpoint = Typesafeai_config.endpoint () in
       let model = Typesafeai_config.model () in
       (* The sha256 of each request body, as the client computed it, so the
          log names exactly what was sent (the Board gate keeps the same
          value as provenance). *)
       let evaluations = ref [] in
       let evaluate ~state ~questions =
         let result = Typesafeai_client.evaluate ?clock ~endpoint ~model ~api_key ~state ~questions () in
         let endpoint = Typesafeai_client.endpoint_for_observation endpoint in
         evaluations := { endpoint; model; state; questions; result } :: !evaluations;
         Result.map (fun evaluated -> evaluated.Typesafeai_client.response) result
         |> Result.map_error Typesafeai_client.failure_to_string
       in
       let outcome = judge ~evaluate ~facts ~new_claims ~absorbed in
       let evaluations = List.rev !evaluations in
       let shas () = String.concat ","
         (List.filter_map (fun evaluation -> match evaluation.result with
           | Ok evaluated -> Some evaluated.Typesafeai_client.request_body_sha256
           | Error _ -> None) evaluations) in
       (match outcome with
        | Open { reason; absorbed = applied; left; unjudgeable; _ } ->
          Log.Keeper.warn
            ~keeper_name:keeper_id
            "librarian absorb gate open: %s; %d of %d absorption(s) applied as answered (%d \
             kept current: %d too large to judge, %d not conveyed before the failure); \
             requests=%s"
            reason
            (List.length applied)
            (List.length absorbed)
            (List.length absorbed - List.length applied)
            (List.length unjudgeable)
            (List.length left)
            (shas ())
        | Judged judged ->
          let not_conveyed =
            List.fold_left (fun n verdict -> n + verdict.not_conveyed) 0 judged.left
          in
          Log.Keeper.info
            ~keeper_name:keeper_id
            "librarian absorb gate: %d absorbed, %d kept current (%d statement(s) not \
             conveyed), %d unjudged, %d too large to judge (kept current), %d request(s) %s"
            (List.length judged.conveyed)
            (List.length judged.left)
            not_conveyed
            (List.length judged.unjudged)
            (List.length judged.unjudgeable)
            judged.requests
            (shas ()));
       Evaluated { outcome; evaluations })
;;
