type read_verb =
  [ `Select | `Show | `Explain | `With | `Values | `Table ]

type mutating_verb =
  [ `Insert | `Update | `Create | `Alter | `Grant | `Revoke | `Comment
  | `Set | `Begin | `Commit | `Rollback | `Copy | `Vacuum | `Analyze
  | `Other ]

type destructive_verb =
  [ `Drop | `Truncate | `Delete ]

type t =
  | Read of read_verb
  | Mutating of mutating_verb
  | Destructive of destructive_verb

let is_destructive = function
  | Destructive _ -> true
  | Read _ | Mutating _ -> false
;;

(* Drop the leading whitespace and SQL comments ([-- … EOL], [/* … */]) of [s]
   from [pos], returning the index of the first significant character. Repeats
   so chains like "  -- c\n  /* d */ DROP" land on the verb. *)
let rec skip_lead s pos =
  let n = String.length s in
  if pos >= n
  then pos
  else (
    match s.[pos] with
    | ' ' | '\t' | '\n' | '\r' -> skip_lead s (pos + 1)
    | '-' when pos + 1 < n && s.[pos + 1] = '-' ->
      (* line comment to end of line *)
      let rec to_eol i = if i >= n || s.[i] = '\n' then i else to_eol (i + 1) in
      skip_lead s (to_eol (pos + 2))
    | '/' when pos + 1 < n && s.[pos + 1] = '*' ->
      (* block comment to closing "*/" (or EOF if unterminated) *)
      let rec to_close i =
        if i + 1 >= n then n
        else if s.[i] = '*' && s.[i + 1] = '/' then i + 2
        else to_close (i + 1)
      in
      skip_lead s (to_close (pos + 2))
    | _ -> pos)
;;

let is_word_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_'
;;

(* Leading keyword (uppercased) of a single statement, or [None] if the
   statement is blank/comment-only. *)
let leading_keyword stmt =
  let n = String.length stmt in
  let start = skip_lead stmt 0 in
  if start >= n
  then None
  else (
    let rec word_end i = if i < n && is_word_char stmt.[i] then word_end (i + 1) else i in
    let stop = word_end start in
    if stop = start then None else Some (String.uppercase_ascii (String.sub stmt start (stop - start))))
;;

(* One classified statement, or [Error] for an unrecognized leading keyword. *)
let classify_statement stmt : (t, [ `Empty | `Unknown_verb of string ]) result =
  match leading_keyword stmt with
  | None -> Error `Empty
  | Some kw ->
    (match kw with
     | "DROP" -> Ok (Destructive `Drop)
     | "TRUNCATE" -> Ok (Destructive `Truncate)
     | "DELETE" -> Ok (Destructive `Delete)
     | "SELECT" -> Ok (Read `Select)
     | "SHOW" -> Ok (Read `Show)
     | "EXPLAIN" -> Ok (Read `Explain)
     | "WITH" -> Ok (Read `With)
     | "VALUES" -> Ok (Read `Values)
     | "TABLE" -> Ok (Read `Table)
     | "INSERT" -> Ok (Mutating `Insert)
     | "UPDATE" -> Ok (Mutating `Update)
     | "CREATE" -> Ok (Mutating `Create)
     | "ALTER" -> Ok (Mutating `Alter)
     | "GRANT" -> Ok (Mutating `Grant)
     | "REVOKE" -> Ok (Mutating `Revoke)
     | "COMMENT" -> Ok (Mutating `Comment)
     | "SET" -> Ok (Mutating `Set)
     | "BEGIN" | "START" -> Ok (Mutating `Begin)
     | "COMMIT" | "END" -> Ok (Mutating `Commit)
     | "ROLLBACK" -> Ok (Mutating `Rollback)
     | "COPY" -> Ok (Mutating `Copy)
     | "VACUUM" -> Ok (Mutating `Vacuum)
     | "ANALYZE" -> Ok (Mutating `Analyze)
     | other -> Error (`Unknown_verb (String.lowercase_ascii other)))
;;

(* Split on top-level [;].  Quote-aware so a ';' inside a string literal does
   not split a statement (e.g. INSERT … VALUES ('a;b')).  Good enough for the
   leading-verb classifier; it does not need full lexing. *)
let split_statements sql =
  let n = String.length sql in
  let buf = Buffer.create 32 in
  let out = ref [] in
  let i = ref 0 in
  let in_squote = ref false in
  let in_dquote = ref false in
  while !i < n do
    let c = sql.[!i] in
    (match c with
     | '\'' when not !in_dquote -> in_squote := not !in_squote; Buffer.add_char buf c
     | '"' when not !in_squote -> in_dquote := not !in_dquote; Buffer.add_char buf c
     | ';' when not !in_squote && not !in_dquote ->
       out := Buffer.contents buf :: !out;
       Buffer.clear buf
     | _ -> Buffer.add_char buf c);
    incr i
  done;
  out := Buffer.contents buf :: !out;
  List.rev !out
;;

(* Tier severity, strictest highest, for picking the dominating statement. *)
let tier_rank = function
  | Destructive _ -> 3
  | Mutating _ -> 2
  | Read _ -> 1
;;

let stricter a b = if tier_rank b > tier_rank a then b else a

let of_command sql : (t, [ `Empty | `Unknown_verb of string ]) result =
  let classified = List.map classify_statement (split_statements sql) in
  (* Strictest statement wins: Destructive > Mutating > Read.  An unrecognized
     leading verb floors nothing (only confirmed-destructive verbs are floored),
     so [Unknown_verb] surfaces only when nothing classifiable was seen. *)
  let strictest =
    List.fold_left
      (fun acc r ->
         match r with
         | Ok t ->
           (match acc with
            | None -> Some t
            | Some best -> Some (stricter best t))
         | Error _ -> acc)
      None
      classified
  in
  match strictest with
  | Some t -> Ok t
  | None ->
    (* Nothing classifiable: report the first statement's failure. *)
    let first_error =
      List.fold_left
        (fun acc r ->
           match acc, r with
           | Some _, _ -> acc
           | None, Error e -> Some e
           | None, Ok _ -> None)
        None
        classified
    in
    (match first_error with
     | Some (`Unknown_verb _ as e) -> Error e
     | Some `Empty | None -> Error `Empty)
;;

let pp fmt = function
  | Read _ -> Format.fprintf fmt "db:read"
  | Mutating _ -> Format.fprintf fmt "db:mutating"
  | Destructive `Drop -> Format.fprintf fmt "db:destructive(drop)"
  | Destructive `Truncate -> Format.fprintf fmt "db:destructive(truncate)"
  | Destructive `Delete -> Format.fprintf fmt "db:destructive(delete)"
;;
