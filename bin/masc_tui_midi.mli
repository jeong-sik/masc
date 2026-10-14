(** SMF(Standard MIDI File) 바이트를 읽어 화면에 보일 정보를 만든다.

    읽는 범위: 헤더 청크 [MThd](format 0·1·2, 트랙 수, PPQ division)와
    [MTrk] 트랙 청크의 이벤트 스트림 — 델타타임 가변 길이 값, running
    status, 메타 이벤트([0x03] 트랙명, [0x51] 템포, [0x58] 박자, 그 외
    길이-접두 메타는 내용 없이 경계만 소모), SysEx([0xF0]/[0xF7] 길이만큼
    걸러 읽기), 채널 이벤트(상태별 데이터 바이트 수만큼 소모).

    SMPTE division(상위 비트)과 format 3은 명시 variant로 실패한다. 템포
    이벤트가 없으면 BPM·길이는 [None] — 기본값을 만들어 내지 않는다. 이
    모듈은 순수하고(네트워크·파일 없음) fetch는 호출자가 둔다. *)

type info = {
  format : int;  (** 0, 1 또는 2 *)
  track_count : int;
  track_names : string option list;  (** 트랙 순서의 [0x03] 이름 *)
  division_ppq : int;  (** 틱/4분음표 *)
  initial_bpm : int option;  (** 가장 이른 tick의 템포 이벤트; 없으면 [None] *)
  tempo_changes : (int * int) list;  (** [(tick, bpm)] 오름차순 *)
  time_signatures : (int * int * int) list;  (** [(tick, 분자, 분모)] *)
  duration_sec : float option;  (** 템포 맵으로 환산한 재생 길이; 템포 이벤트가 없으면 [None] *)

}

type failure =
  | Not_midi  (** [MThd]로 시작하지 않음 *)
  | Truncated  (** 구조 도중 바이트가 끝남 *)
  | Bad_varlen  (** 가변 길이 값이 4바이트를 넘음 *)
  | Unsupported_division  (** 0 또는 SMPTE 시간 표기; 양수 PPQ만 지원 *)
  | Unsupported_format of int  (** 0~2 바깥의 포맷 번호 *)
  | Running_status_without_status  (** 상태 바이트 없이 데이터 바이트 *)
  | Bad_status of int  (** 트랙 이벤트가 아닌 상태 바이트 *)
  | Meta_truncated  (** 메타 이벤트가 중간에서 잘림 *)

val read : string -> (info, failure) result
(** 바이트 전체를 읽는다. 읽는 범위 밖의 입력은 명시 variant로 실패한다. *)

val failure_text : failure -> string
(** 실패를 화면 한 줄로 낼 문장. *)

val summary : info -> string
(** 한 줄 요약: 있는 것만 [ · ]로 연결한다.
    예: ["3 tracks · 96 BPM · 4/4 · 2:31"]. 길이는 m:ss(반올림). *)
