(* Fusion 하네스 코어 (구현) — 순수 집계·채점·delta.
   계약/문서: fusion_harness_core.mli, docs/rfc/RFC-0252 §11. *)

type strategy =
  | Single
  | Self_consistency
  | Self_moa
  | Fusion

let strategy_label = function
  | Single -> "single"
  | Self_consistency -> "self_consistency"
  | Self_moa -> "self_moa"
  | Fusion -> "fusion"

type eval_case =
  { question : string
  ; reference : string
  }
[@@deriving yojson]

type run_result =
  { strategy : strategy
  ; answer : string
  ; correct : bool
  ; usage : Fusion_types.usage
  }

type comparison =
  { score : (strategy * float) list
  ; cost_ratio : (strategy * float) list
  ; cost_matched_delta : float
  ; single_delta : float
  }

(* trim + lowercase + 내부 공백(스페이스/탭/개행)을 1칸으로 축약. 선행/후행 공백 제거.
   정답 매칭과 다수결 키를 같은 정규화로 묶어 표기 차이를 흡수한다. *)
let normalize (s : string) : string =
  let buf = Buffer.create (String.length s) in
  let prev_space = ref true (* 선행 공백 제거: 시작을 공백 직후로 취급 *) in
  String.iter
    (fun c ->
      let lc = Char.lowercase_ascii c in
      match lc with
      | ' ' | '\t' | '\n' | '\r' ->
        if not !prev_space then begin
          Buffer.add_char buf ' ';
          prev_space := true
        end
      | _ ->
        Buffer.add_char buf lc;
        prev_space := false)
    s;
  let r = Buffer.contents buf in
  (* 후행 공백 1칸 제거 (내부가 단일 공백이라 최대 1칸). *)
  let n = String.length r in
  if n > 0 && r.[n - 1] = ' ' then String.sub r 0 (n - 1) else r

let score_answer ~reference ~answer =
  String.equal (normalize reference) (normalize answer)

let majority_vote (samples : string list) : string =
  match samples with
  | [] -> invalid_arg "majority_vote: empty sample list"
  | _ ->
    (* 정규화 키 -> (첫 등장 원문, 카운트). order는 첫 등장 순서(역순 누적). *)
    let tbl : (string, string * int) Hashtbl.t = Hashtbl.create 8 in
    let order = ref [] in
    List.iter
      (fun s ->
        let key = normalize s in
        match Hashtbl.find_opt tbl key with
        | None ->
          Hashtbl.replace tbl key (s, 1);
          order := key :: !order
        | Some (rep, n) -> Hashtbl.replace tbl key (rep, n + 1))
      samples;
    let ordered_keys = List.rev !order in
    (* 최대 카운트, 동률은 첫 등장 순(ordered_keys가 등장 순이라 > 만 갱신). *)
    let best =
      List.fold_left
        (fun acc key ->
          let rep, n = Hashtbl.find tbl key in
          match acc with
          | Some (_, best_n) when n <= best_n -> acc
          | _ -> Some (rep, n))
        None ordered_keys
    in
    (match best with
     | Some (rep, _) -> rep
     | None -> invalid_arg "majority_vote: empty sample list")

let compare (results : run_result list) : comparison =
  let strategies = [ Single; Self_consistency; Self_moa; Fusion ] in
  let for_strategy st = List.filter (fun r -> r.strategy = st) results in
  let score_of st =
    match for_strategy st with
    | [] -> 0.0
    | rs ->
      let correct = List.length (List.filter (fun r -> r.correct) rs) in
      float_of_int correct /. float_of_int (List.length rs)
  in
  let tokens_of st =
    for_strategy st
    |> List.fold_left
         (fun acc r ->
           acc + r.usage.Fusion_types.input_tokens + r.usage.Fusion_types.output_tokens)
         0
  in
  let score = List.map (fun st -> (st, score_of st)) strategies in
  let single_tokens = tokens_of Single in
  let cost_ratio =
    List.map
      (fun st ->
        let t = tokens_of st in
        let ratio =
          if single_tokens = 0 then 0.0 else float_of_int t /. float_of_int single_tokens
        in
        (st, ratio))
      strategies
  in
  let get st = List.assoc st score in
  let fusion_score = get Fusion in
  let cost_matched_delta =
    fusion_score -. Float.max (get Self_consistency) (get Self_moa)
  in
  let single_delta = fusion_score -. get Single in
  { score; cost_ratio; cost_matched_delta; single_delta }
