(* 화면 변화 판정의 순수 코어 — 머신도 ROM 도 없는 CI 테스트로 증명한다
   (절약 도구의 판별 근거는 재현 가능해야 한다). 지문은 screen_view 의
   아스키 문자열 그대로: 셀 차이 개수로 "같은 화면인가"를 정량화한다.
   깜빡이는 커서 한두 줄의 차이는 진행이 아니므로 임계 이하는 같은
   화면으로 본다. *)

type config = {
  interval : int;  (** frames between fingerprints *)
  stable_needed : int;  (** consecutive equal fingerprints that mean "settled" *)
  cell_threshold : int;  (** differing cells at or below this count as "equal" *)
}

(* 6 프레임(0.1 s) 간격, 2 회 연속 안정(0.2 s 정지), 커서·반전 수준의
   8 셀까지는 같은 화면 — 삼국지2 타이틀과 메시지창에서 잰 값이다. *)
let default = { interval = 6; stable_needed = 2; cell_threshold = 8 }

(* 두 지문에서 다른 셀 수. 길이가 다르면 아예 다른 화면이다. *)
let differing_cells a b =
  if String.length a <> String.length b then max_int
  else begin
    let n = ref 0 in
    String.iteri (fun i c -> if c <> b.[i] then incr n) a;
    !n
  end
;;

type fold = { last : string; stable_run : int; saw_change : bool }

let initial fingerprint = { last = fingerprint; stable_run = 0; saw_change = false }

(* 직전 지문과의 셀 차이만 본다: 임계 초과는 이동(안정 리셋), 이하는
   같은 화면(안정 +1). 이동했음은 saw_change 로 남긴다 — 시작 화면으로
   도로 돌아온 플래시가 "정지"로 위장되지 않게 changed 는 시작-끝
   비교로 따로 판정한다. *)
let feed config state fingerprint =
  if differing_cells state.last fingerprint > config.cell_threshold then
    { last = fingerprint; stable_run = 0; saw_change = true }
  else { state with last = fingerprint; stable_run = state.stable_run + 1 }
;;

let settled config state = state.stable_run >= config.stable_needed

(* 시작 지문과 마지막 지문이 다르면 변화. saw_change 는 판정에 넣지
   않는다 — 갔다 돌아온 화면은 "그대로"이고, 그 사실이 키 대기 장면
   후보 판별의 핵심이다. *)
let changed config start_fingerprint state =
  differing_cells start_fingerprint state.last > config.cell_threshold
;;

let replay config fingerprints =
  match fingerprints with
  | [] -> invalid_arg "screen_change.replay: needs the start fingerprint"
  | first :: rest ->
      List.fold_left (feed config) (initial first) rest
;;
