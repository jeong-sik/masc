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
  | Failed of
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

(* Which way a question points. [Forward]: the state is a claim, the
   statement is from a memory it absorbs. [Reverse] (RFC-0463 section 2.8):
   the state is the memories a claim tried to absorb, read together, and the
   statement is from the claim. The model reads the question text, so each
   direction names what it is actually handed. *)
type direction =
  | Forward
  | Reverse

let direction_to_string = function
  | Forward -> "forward"
  | Reverse -> "reverse"
;;

let instructions_prefix = function
  | Forward -> "The claim under review conveys this statement, in any wording.\n\nStatement:\n"
  | Reverse ->
    "The memories under review, read together, convey this statement, in any wording.\n\n\
     Statement:\n"
;;

let criteria = function
  | Forward ->
    ( "A reader of the claim alone would learn what the statement says, even if worded differently."
    , "The claim does not say what the statement says, or says only a vaguer version of it." )
  | Reverse ->
    ( "A reader of these memories alone would learn what the statement says, even if worded \
       differently."
    , "The memories do not say what the statement says, or say only a vaguer or partial \
       version of it." )
;;

let question direction statement =
  Typesafeai_types.Noul
    { Typesafeai_types.instructions = instructions_prefix direction ^ statement
    ; criteria = Some (criteria direction)
    }
;;

(* What a statement adds to a request: its question, fixed text included. *)
let question_bytes direction statement =
  let yes, no = criteria direction in
  String.length (instructions_prefix direction)
  + String.length statement
  + String.length yes
  + String.length no
;;

(* [numbered] cut into requests of at most [questions_per_request] questions
   and at most [budget] bytes of questions each. Every question fits alone
   by construction (the caller keeps out the statements that do not). *)
let chunks ~direction ~budget numbered =
  let rec go current_bytes current acc = function
    | [] -> List.rev (if current = [] then acc else List.rev current :: acc)
    | ((_, statement) as item) :: rest ->
      let bytes = question_bytes direction statement in
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
let ask ~direction ~evaluate ~claim (numbered : (string * string) list) =
  let state = `String claim in
  let budget = request_bytes_limit - String.length claim in
  let rec go table requests = function
    | [] -> table, requests, None
    | chunk :: rest ->
      let questions =
        List.map (fun (id, statement) -> id, question direction statement) chunk
      in
      (match evaluate ~state ~questions with
       | Error reason -> table, requests, Some reason
       | Ok response ->
         (match decode chunk response with
          | Error reason -> table, requests + 1, Some reason
          | Ok answers -> go (answers @ table) (requests + 1) rest))
  in
  go [] 0 (chunks ~direction ~budget numbered)
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
  (* An absorbing claim is a new one, or a current memory the answer wrote
     again as it stands: that memory is the claim, so its text is the one
     the absorbed memories are judged against. *)
  let claim_of_into into =
    match claim_of into new_claims with
    | Some _ as claim -> claim
    | None -> claim_of into facts
  in
  List.map
    (fun (into, members) ->
       match claim_of_into into with
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
             (fun (_, sts) ->
                List.for_all (fun st -> question_bytes Forward st <= budget) sts)
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
         let table, requests, failure = ask ~direction:Forward ~evaluate ~claim numbered in
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
    (* Only complete positive verdicts authorize removing a source. A
       failed request leaves unanswered statements and unvisited groups
       current, without blocking the new claims or completed judgments. *)
    let unjudgeable = List.concat_map (fun (group : group) -> group.unjudgeable) groups in
    let unjudged = List.concat_map (fun (group : group) -> group.unjudged) groups in
    Failed
      { reason
      ; absorbed = List.filter (fun (statement : Keeper_memory_os_types.absorbed_statement) ->
          List.exists (fun (verdict : source_verdict) ->
            String.equal statement.absorbed verdict.memory_id
            && String.equal statement.into verdict.into) acc.conveyed) absorbed
      ; left = acc.left
      ; conveyed = acc.conveyed
      ; unjudged
      ; unjudgeable
      }
;;

(* --- The reverse question (RFC-0463 section 2.8) --- *)

type copy_not_judged =
  | Gate_judgment_failed
  | Continues_a_dropped_memory
  | No_source_fits_the_state
  | Statement_too_large
  | No_statement
  | Request_failed of string

type copy_verdict =
  | Copy of { statements : string list }
  | Carries_new_statement of
      { statements : int
      ; not_conveyed : int
      }
  | Not_judged of copy_not_judged

type copy_check =
  { claim_id : string
  ; sources : string list
  ; verdict : copy_verdict
  ; requests : int
  }

(* A new claim that named memories in [absorbs] and had none of them
   applied, with the memories it named, in the answer's order. A claim with
   one absorption applied is doing what it was written for; a claim that
   named none never tried to fold anything. *)
let copy_candidates ~new_claims ~absorbed ~applied =
  let into claim_id (statement : Keeper_memory_os_types.absorbed_statement) =
    String.equal statement.into claim_id
  in
  List.filter_map
    (fun (claim : Keeper_memory_os_types.fact) ->
       let claim_id = Keeper_memory_os_types.memory_id claim in
       match
         List.filter (into claim_id) absorbed, List.exists (into claim_id) applied
       with
       | [], (true | false) | _ :: _, true -> None
       | (_ :: _ as tried), false ->
         Some
           ( claim
           , List.map
               (fun (statement : Keeper_memory_os_types.absorbed_statement) ->
                  statement.absorbed)
               tried ))
    new_claims
;;

let not_judged_checks candidates reason =
  List.map
    (fun ((claim : Keeper_memory_os_types.fact), sources) ->
       { claim_id = Keeper_memory_os_types.memory_id claim
       ; sources
       ; verdict = Not_judged reason
       ; requests = 0
       })
    candidates
;;

(* The sources' texts, joined in order into states of at most
   {!state_bytes_limit} bytes: the bound the forward question puts on the
   claim it sends as the state. A source over the bound on its own is left
   out; leaving a source out can only make a statement look unconveyed,
   which applies the claim, the side today already takes. *)
let source_states texts =
  let separator = "\n\n" in
  let rec go current acc = function
    | [] ->
      List.rev
        (match current with
         | None -> acc
         | Some state -> state :: acc)
    | text :: rest when String.length text > state_bytes_limit -> go current acc rest
    | text :: rest ->
      (match current with
       | None -> go (Some text) acc rest
       | Some state
         when String.length state + String.length separator + String.length text
              <= state_bytes_limit -> go (Some (state ^ separator ^ text)) acc rest
       | Some state -> go (Some text) (state :: acc) rest)
  in
  go None [] texts
;;

(* Every statement of [claim] asked of the sources' states in turn, the
   statements already conveyed by an earlier state not asked again. A
   statement is conveyed when one state conveys it; statements split across
   two states therefore look unconveyed, which applies the claim. *)
let judge_copy ~evaluate ~facts ((claim : Keeper_memory_os_types.fact), sources) =
  let claim_id = Keeper_memory_os_types.memory_id claim in
  let check verdict requests = { claim_id; sources; verdict; requests } in
  let texts =
    List.filter_map
      (fun source ->
         List.find_map
           (fun (fact : Keeper_memory_os_types.fact) ->
              if String.equal (Keeper_memory_os_types.memory_id fact) source
              then Some fact.claim
              else None)
           facts)
      sources
  in
  let claim_statements = statements claim.claim in
  let numbered = List.mapi (fun k statement -> Printf.sprintf "c%d" k, statement) claim_statements in
  let rec go ~remaining ~asked ~requests states =
    match remaining, states with
    | [], ([] | _ :: _) -> check (Copy { statements = claim_statements }) requests
    | _ :: _, [] ->
      if List.exists (fun (id, _) -> List.exists (String.equal id) asked) remaining
      then
        check
          (Carries_new_statement
             { statements = List.length claim_statements
             ; not_conveyed = List.length remaining
             })
          requests
      else check (Not_judged Statement_too_large) requests
    | _ :: _, state :: rest ->
      let budget = request_bytes_limit - String.length state in
      let askable =
        List.filter
          (fun (_, statement) -> question_bytes Reverse statement <= budget)
          remaining
      in
      let table, made, failure = ask ~direction:Reverse ~evaluate ~claim:state askable in
      (match failure with
       | Some reason -> check (Not_judged (Request_failed reason)) (requests + made)
       | None ->
         (* A tie goes the other way from the forward question. There a
            tie absorbs a source, and the source's text survives in the
            claim; here a tie would drop the claim, and a statement only it
            holds would be gone. So the reverse question needs strictly
            more than the boundary. *)
         let conveyed (id, _) =
           match List.assoc_opt id table with
           | Some noul -> noul > conveyed_boundary
           | None -> false
         in
         go
           ~remaining:(List.filter (fun item -> not (conveyed item)) remaining)
           ~asked:(List.map fst askable @ asked)
           ~requests:(requests + made)
           rest)
  in
  match numbered, source_states texts with
  | [], ([] | _ :: _) ->
    (* Nothing to ask: a claim without a statement is not shown to be a copy. *)
    check (Not_judged No_statement) 0
  | _ :: _, [] -> check (Not_judged No_source_fits_the_state) 0
  | _ :: _, (_ :: _ as states) -> go ~remaining:numbered ~asked:[] ~requests:0 states
;;

let judge_copies ~evaluate ~facts ~new_claims ~superseding ~absorbed ~applied =
  List.map
    (fun (((claim : Keeper_memory_os_types.fact), sources) as candidate) ->
       let claim_id = Keeper_memory_os_types.memory_id claim in
       if List.exists (String.equal claim_id) superseding
       then { claim_id; sources; verdict = Not_judged Continues_a_dropped_memory; requests = 0 }
       else judge_copy ~evaluate ~facts candidate)
    (copy_candidates ~new_claims ~absorbed ~applied)
;;

(* --- Entry point --- *)

type skip_reason = No_absorptions | Unavailable of Typesafeai_config.unavailable_reason

type evaluation =
  { direction : direction
  ; destinations : Typesafeai_client.destination_id list
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
      ; copy_checks : copy_check list
      ; evaluations : evaluation list
      }

type observation =
  | Incomplete of evaluation list
  | Complete of run_result

let absorbed_of_run = function
  | Skipped { absorbed; _ }
  | Evaluated { outcome = Failed { absorbed; _ }; _ }
  | Evaluated { outcome = Judged { absorbed; _ }; _ } -> absorbed
;;

let without_copies result claims =
  let copies =
    match result with
    | Skipped _ -> []
    | Evaluated { copy_checks; _ } ->
      List.filter_map
        (fun check ->
           match check.verdict with
           | Copy _ -> Some check.claim_id
           | Carries_new_statement _ | Not_judged _ -> None)
        copy_checks
  in
  List.filter
    (fun claim ->
       not
         (List.exists (String.equal (Keeper_memory_os_types.memory_id claim)) copies))
    claims
;;

let copy_not_judged_to_string = function
  | Gate_judgment_failed -> "gate_judgment_failed"
  | Continues_a_dropped_memory -> "continues_a_dropped_memory"
  | No_source_fits_the_state -> "no_source_fits_the_state"
  | Statement_too_large -> "statement_too_large"
  | No_statement -> "no_statement"
  | Request_failed _ -> "request_failed"
;;

let copy_check_to_yojson { claim_id; sources; verdict; requests } =
  let verdict_fields =
    match verdict with
    | Copy { statements } ->
      [ "verdict", `String "copy"
      ; "conveyed_statements", `List (List.map (fun statement -> `String statement) statements)
      ]
    | Carries_new_statement { statements; not_conveyed } ->
      [ "verdict", `String "carries_new_statement"
      ; "statements", `Int statements
      ; "not_conveyed", `Int not_conveyed
      ]
    | Not_judged reason ->
      [ "verdict", `String "not_judged"
      ; "reason", `String (copy_not_judged_to_string reason)
      ]
      @ (match reason with
         | Request_failed detail -> [ "detail", `String detail ]
         | Gate_judgment_failed
         | Continues_a_dropped_memory
         | No_source_fits_the_state
         | Statement_too_large
         | No_statement -> [])
  in
  `Assoc
    ([ "claim_id", `String claim_id
     ; "sources", `List (List.map (fun source -> `String source) sources)
     ]
     @ verdict_fields
     @ [ "requests", `Int requests ])
;;

let evaluation_to_yojson { direction; destinations; state; questions; result } =
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
        ; "destination_uri", `String evaluated.destination.destination_uri
        ; "requested_model", `String evaluated.destination.model
        ; "passed_over", `List (List.map Typesafeai_client.attempt_to_yojson evaluated.passed_over)
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
    @ [ "direction", `String (direction_to_string direction)
      ; "request", `Assoc
          [ "destinations", `List (List.map Typesafeai_client.destination_id_to_yojson destinations)
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
    | Evaluated { outcome; copy_checks; evaluations } ->
      let status, disposition =
        match outcome with
        | Failed { reason; absorbed; left; conveyed; unjudged; unjudgeable } ->
          ([ "status", `String "failed"; "reason", `String reason ],
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
      @ [ "copy_checks", `List (List.map copy_check_to_yojson copy_checks)
        ; "evaluations", `List (List.map evaluation_to_yojson evaluations) ]
  in
  `Assoc fields
;;

let observation_to_yojson = function
  | Incomplete evaluations ->
    `Assoc
      [ "status", `String "incomplete"
      ; "evaluations", `List (List.map evaluation_to_yojson evaluations)
      ]
  | Complete result -> run_result_to_yojson result
;;

(* One line for the reverse question, then one per claim it keeps out of
   the store, with the statements the sources were found to convey, so a
   person can read the discarded claims back (RFC-0463 section 6). *)
let log_copy_checks ~keeper_id checks =
  match checks with
  | [] -> ()
  | _ :: _ ->
    let count predicate = List.length (List.filter predicate checks) in
    let is_copy check =
      match check.verdict with
      | Copy _ -> true
      | Carries_new_statement _ | Not_judged _ -> false
    in
    let carries check =
      match check.verdict with
      | Carries_new_statement _ -> true
      | Copy _ | Not_judged _ -> false
    in
    let not_judged check =
      match check.verdict with
      | Not_judged _ -> true
      | Copy _ | Carries_new_statement _ -> false
    in
    Log.Keeper.info
      ~keeper_name:keeper_id
      "librarian absorb gate reverse: %d claim(s) absorbed nothing; %d copy (not applied), \
       %d carry a new statement, %d not judged (applied); %d request(s)"
      (List.length checks)
      (count is_copy)
      (count carries)
      (count not_judged)
      (List.fold_left (fun n check -> n + check.requests) 0 checks);
    List.iter
      (fun check ->
         match check.verdict with
         | Copy { statements } ->
           Log.Keeper.info
             ~keeper_name:keeper_id
             "librarian absorb gate reverse: claim %s not applied, sources %s convey \
              every statement: %s"
             check.claim_id
             (String.concat "," check.sources)
             (String.concat " | " statements)
         | Not_judged (Request_failed detail) ->
           Log.Keeper.warn
             ~keeper_name:keeper_id
             "librarian absorb gate reverse: claim %s applied unjudged, request failed: %s"
             check.claim_id
             detail
         | Not_judged
             ((Gate_judgment_failed
              | Continues_a_dropped_memory
              | No_source_fits_the_state
              | Statement_too_large
              | No_statement) as reason) ->
           Log.Keeper.info
             ~keeper_name:keeper_id
             "librarian absorb gate reverse: claim %s applied unjudged (%s)"
             check.claim_id
             (copy_not_judged_to_string reason)
         | Carries_new_statement _ -> ())
      checks
;;

let run ?observe ?clock ~keeper_id ~facts ~new_claims ~superseding ~absorbed () =
  let publish observation = Option.iter (fun notify -> notify observation) observe in
  let complete result = publish (Complete result); result in
  match absorbed with
  | [] -> complete (Skipped { reason = No_absorptions; absorbed })
  | _ :: _ ->
    (match Typesafeai_config.absorb_gate_destinations ~keeper_id with
     | Error
         ((Typesafeai_config.Absorb_gate_disabled | Typesafeai_config.Keeper_excluded) as reason)
       ->
       (* Declared off: the operator chose not to ask, and the answer applies
          as it came, as it did before the gate existed. *)
       Log.Keeper.info
         ~keeper_name:keeper_id
         "librarian absorb gate off (%s): %d absorption(s) applied as answered"
         (Typesafeai_config.unavailable_reason_to_string reason)
         (List.length absorbed);
       complete (Skipped { reason = Unavailable reason; absorbed })
     | Error
         ((Typesafeai_config.Lane_disabled | Typesafeai_config.No_armed_destination) as reason)
       ->
       (* Declared on and cannot be asked: the operator meant every absorption
          to be judged, so none is; the sources stay current and the new
          claims still apply. Applying the answer here would remove memories
          from the current snapshot on the strength of a judgment that never
          ran, which is the one direction this gate exists to close. *)
       Log.Keeper.warn
         ~keeper_name:keeper_id
         "librarian absorb gate declared on but unavailable (%s): %d absorption(s) kept current"
         (Typesafeai_config.unavailable_reason_to_string reason)
         (List.length absorbed);
       complete (Skipped { reason = Unavailable reason; absorbed = [] })
     | Error
         ((Typesafeai_config.Board_attention_disabled
          | Typesafeai_config.Context_review_disabled
          | Typesafeai_config.Skill_applicability_disabled) as reason)
       ->
       (* Another gate's switch: [absorb_gate_destinations] does not produce
          these. Named rather than caught so a new reason has to be placed;
          the safe direction is the same as above. *)
       Log.Keeper.warn
         ~keeper_name:keeper_id
         "librarian absorb gate reported another gate's switch (%s): %d absorption(s) kept current"
         (Typesafeai_config.unavailable_reason_to_string reason)
         (List.length absorbed);
       complete (Skipped { reason = Unavailable reason; absorbed = [] })
     | Ok ((first, rest) as armed) ->
       let destinations = List.map Typesafeai_client.identify (first :: rest) in
       (* The sha256 of each request body, as the client computed it, so the
          log names exactly what was sent (the Board gate keeps the same
          value as provenance). *)
       let evaluations = ref [] in
       let evaluate direction ~state ~questions =
         let result = Typesafeai_client.evaluate ?clock ~destinations:armed ~state ~questions () in
         evaluations := { direction; destinations; state; questions; result } :: !evaluations;
         publish (Incomplete (List.rev !evaluations));
         Result.map (fun evaluated -> evaluated.Typesafeai_client.response) result
         |> Result.map_error Typesafeai_client.failure_to_string
       in
       let outcome = judge ~evaluate:(evaluate Forward) ~facts ~new_claims ~absorbed in
       (* The reverse question goes to the same judge through the same
          [evaluate], so its requests are in [evaluations] beside the
          forward ones. A forward judgment that failed leaves the lane in
          doubt; the claims it would ask about are applied as today. *)
       let copy_checks =
         match outcome with
         | Judged judged ->
           judge_copies ~evaluate:(evaluate Reverse) ~facts ~new_claims ~superseding ~absorbed
             ~applied:judged.absorbed
         | Failed { absorbed = applied; _ } ->
           not_judged_checks
             (copy_candidates ~new_claims ~absorbed ~applied)
             Gate_judgment_failed
       in
       let evaluations = List.rev !evaluations in
       let shas () = String.concat ","
         (List.filter_map (fun evaluation -> match evaluation.result with
           | Ok evaluated -> Some evaluated.Typesafeai_client.request_body_sha256
           | Error _ -> None) evaluations) in
       (match outcome with
        | Failed { reason; absorbed = applied; left; unjudgeable; _ } ->
          Log.Keeper.warn
            ~keeper_name:keeper_id
            "librarian absorb judgment failed: %s; %d of %d absorption(s) confirmed (%d \
             kept current, including unconfirmed sources: %d too large to judge, %d not conveyed); \
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
       log_copy_checks ~keeper_id copy_checks;
       complete (Evaluated { outcome; copy_checks; evaluations }))
;;
