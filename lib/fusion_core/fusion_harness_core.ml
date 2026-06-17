(* Fusion 하네스 — self-consistency 다수결 집계 (구현).
   계약/문서: fusion_harness_core.mli, docs/rfc/RFC-0255 §11.

   채점·전략 우열은 judge(LLM 판단)가 한다. 결정론 string 매칭 채점은 표현 변이를
   못 잡고 심의 가치를 단답 정답률로 환원하는 어거지라 두지 않는다. 판단이 불필요한
   self-consistency 다수결만 결정론으로 제공한다. *)

(* trim + lowercase + 내부 공백(스페이스/탭/개행)을 1칸으로 축약. 선행/후행 공백 제거.
   다수결 키를 표기 차이에 무관하게 묶는다(채점이 아니라 집계 키 정규화). *)
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
