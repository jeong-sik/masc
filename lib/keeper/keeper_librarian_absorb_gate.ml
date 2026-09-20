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

(* Backticks are dropped; nothing else. Emphasis markers stay: a memory about
   code can hold [**] as an operator, and dropping it would judge an altered
   statement. *)
let drop_markup s = String.concat "" (String.split_on_char '`' s)

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
  let text = drop_markup text in
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
      }
  | Judged of judged

let conveyed_boundary = 0.5
let questions_per_request = 64

(* The model takes 64k tokens a request and 32k for the state; a byte bound
   well under both keeps a request from being refused for its size, which
   would open the gate for exactly the memory it should keep. Statements
   are not bounded by the cut -- a memory without sentence ends is one
   statement -- so a statement that does not fit alone, or a claim that does
   not fit, cannot be judged; that memory stays current. *)
let request_bytes_limit = 96_000

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

(* [numbered] cut into requests of at most [questions_per_request] questions
   and at most [budget] bytes of statements each. Every statement fits alone
   by construction (the caller keeps out the ones that do not). *)
let chunks ~budget numbered =
  let rec go current_bytes current acc = function
    | [] -> List.rev (if current = [] then acc else List.rev current :: acc)
    | ((_, statement) as item) :: rest ->
      let bytes = String.length statement in
      if current <> []
         && (List.length current >= questions_per_request
             || current_bytes + bytes > budget)
      then go bytes [ item ] (List.rev current :: acc) rest
      else go (current_bytes + bytes) (item :: current) acc rest
  in
  go 0 [] [] numbered
;;

(* Every statement of [sources], asked in requests of at most
   [questions_per_request], answered as a table from question id to [noul]. *)
let ask ~evaluate ~claim (numbered : (string * string) list) =
  let open Result.Syntax in
  let state = `String claim in
  let budget = request_bytes_limit - String.length claim in
  List.fold_left
    (fun acc chunk ->
       let* table, requests = acc in
       let questions = List.map (fun (id, statement) -> id, question statement) chunk in
       let* response = evaluate ~state ~questions in
       let* answers =
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
       in
       Ok (answers @ table, requests + 1))
    (Ok ([], 0))
    (chunks ~budget numbered)
;;

(* The answer's absorptions into one claim, classified before any request
   is made: what has no claim or no source text passes through unjudged,
   what does not fit a request ({!request_bytes_limit}) cannot be judged
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
       | Some claim when String.length claim >= request_bytes_limit ->
         (* The claim alone fills a request: nothing it absorbs can be judged
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
             (fun (_, sts) -> List.for_all (fun st -> String.length st <= budget) sts)
             judgeable
         in
         { into; claim = Some claim; unjudged; unjudgeable = List.map fst unjudgeable; judgeable })
    by_into
;;

let judge ~evaluate ~facts ~new_claims ~absorbed =
  let groups = classify ~facts ~new_claims ~absorbed in
  let open Result.Syntax in
  let judged =
    List.fold_left
      (fun (acc : (judged, string) result) (group : group) ->
         let* acc = acc in
         let acc =
           { acc with
             absorbed = acc.absorbed @ group.unjudged
           ; unjudged = acc.unjudged @ group.unjudged
           ; unjudgeable = acc.unjudgeable @ group.unjudgeable
           }
         in
         match group.claim, group.judgeable with
         | None, _ | Some _, [] -> Ok acc
         | Some claim, judgeable ->
           let numbered =
             List.concat
               (List.mapi
                  (fun i (_, sts) -> List.mapi (fun k s -> Printf.sprintf "s%d_%d" i k, s) sts)
                  judgeable)
           in
           let* table, requests = ask ~evaluate ~claim numbered in
           let verdicts =
             List.mapi
               (fun i ((statement : Keeper_memory_os_types.absorbed_statement), sts) ->
                  let not_conveyed =
                    List.length
                      (List.filteri
                         (fun k _ ->
                            List.assoc (Printf.sprintf "s%d_%d" i k) table < conveyed_boundary)
                         sts)
                  in
                  ( statement
                  , { memory_id = statement.absorbed
                    ; into = group.into
                    ; statements = List.length sts
                    ; not_conveyed
                    } ))
               judgeable
           in
           let kept, left =
             List.partition (fun (_, verdict) -> verdict.not_conveyed = 0) verdicts
           in
           Ok
             { acc with
               absorbed = acc.absorbed @ List.map fst kept
             ; left = acc.left @ List.map snd left
             ; conveyed = acc.conveyed @ List.map snd kept
             ; requests = acc.requests + requests
             })
      (Ok
         { absorbed = []
         ; left = []
         ; conveyed = []
         ; unjudged = []
         ; unjudgeable = []
         ; requests = 0
         })
      groups
  in
  (* Back in the answer's order, so the store sees the answer's list minus
     what the gate took out. *)
  let in_answer_order through =
    List.filter
      (fun (statement : Keeper_memory_os_types.absorbed_statement) ->
         List.exists
           (fun (kept : Keeper_memory_os_types.absorbed_statement) ->
              String.equal kept.absorbed statement.absorbed
              && String.equal kept.into statement.into)
           through)
      absorbed
  in
  match judged with
  | Ok judged -> Judged { judged with absorbed = in_answer_order judged.absorbed }
  | Error reason ->
    let unjudgeable = List.concat_map (fun (group : group) -> group.unjudgeable) groups in
    Open
      { reason
      ; absorbed =
          List.filter
            (fun (statement : Keeper_memory_os_types.absorbed_statement) ->
               not
                 (List.exists
                    (fun (kept : Keeper_memory_os_types.absorbed_statement) ->
                       String.equal kept.absorbed statement.absorbed
                       && String.equal kept.into statement.into)
                    unjudgeable))
            absorbed
      }
;;

(* --- Entry point --- *)

let run ?clock ~keeper_id ~facts ~new_claims ~absorbed () =
  match absorbed with
  | [] -> absorbed
  | _ :: _ ->
    (match
       if Typesafeai_config.is_absorb_gate_enabled ()
       then Typesafeai_config.api_key ()
       else None
     with
     | None ->
       Log.Keeper.info
         ~keeper_name:keeper_id
         "librarian absorb gate off (no key, or a switch): %d absorption(s) applied as answered"
         (List.length absorbed);
       absorbed
     | Some api_key ->
       (* The sha256 of each request body, as the client computed it, so the
          log names exactly what was sent (the Board gate keeps the same
          value as provenance). *)
       let request_shas = ref [] in
       let evaluate ~state ~questions =
         Typesafeai_client.evaluate ?clock ~api_key ~state ~questions ()
         |> Result.map (fun evaluated ->
           request_shas := evaluated.Typesafeai_client.request_body_sha256 :: !request_shas;
           evaluated.Typesafeai_client.response)
       in
       let shas () = String.concat "," (List.rev !request_shas) in
       (match judge ~evaluate ~facts ~new_claims ~absorbed with
        | Open { reason; absorbed = applied } ->
          Log.Keeper.warn
            ~keeper_name:keeper_id
            "librarian absorb gate open: %s; %d of %d absorption(s) applied as answered (%d too \
             large to judge kept current); requests=%s"
            reason
            (List.length applied)
            (List.length absorbed)
            (List.length absorbed - List.length applied)
            (shas ());
          applied
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
            (shas ());
          judged.absorbed))
;;
