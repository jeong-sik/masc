(** 보드 첨부 하나를 여는 동작: 저장, 재생, 외부 앱 열기.

    순수 결정(kind별 동작, 플레이어 선택, 경로)은 테스트로, 네트워크와
    프로세스가 필요한 [run]은 호출부가 주입한 [fetch]와 로컬 프로세스로
    처리한다. 재생은 한 번에 하나 — 새 재생이 시작되면 이전 프로세스를
    끝낸다. *)

type action =
  | Play_local
  | Play_midi
  | Open_external
  | Save_only

val action_of : Masc_tui_types.board_attachment_kind -> action
(** [Ak_audio]는 로컬 재생, [Ak_midi]는 fluidsynth 재생,
    [Ak_image | Ak_video | Ak_youtube | Ak_external_link]는 외부 앱 열기
    (단, 내려받은 파일은 [allows_external_open]을 통과할 때만),
    [Ak_file | Ak_score | Ak_unknown _]는 저장만 하고 경로를 보여 준다([Save_only]). *)

val allows_external_open : name:string -> bool
(** 내려받은 파일을 OS 기본 앱([open]/[xdg-open])에 넘겨도 안전한 확장자만
    허용한다(이미지·영상·PDF·평문). [.terminal], [.jar], [.pkg], [.dmg],
    [.webloc], [.workflow] 등 실행·설치 핸들러로 이어질 수 있는 확장자는 거절한다. *)

val cache_dir : unit -> string
(** [Filename.get_temp_dir_name ()/masc_attachments]; 없으면 만든다. *)

val target_path : name:string option -> sha256:string -> string
(** [cache_dir/<sha>/<이름|attachment>]. *)

val player_argvs : ?path_value:string -> path:string -> unit -> string list list
(** 로컬 오디오 플레이어 후보(선례: voice_bridge_core.local_playback_argvs):
    [afplay], [ffplay -nodisp -autoexit -loglevel error], [mpg123 -q],
    [play -q]. PATH에 있는 것만, 이 순서. *)

val midi_argv :
  ?path_value:string ->
  path:string ->
  soundfont:string option ->
  unit ->
  (string list, string) result
(** [fluidsynth -i <sf> <file>]. fluidsynth가 없거나 사운드폰트가
    설정돼 있지 않거나/없으면 그 사유로 실패 — 호출부는 저장된 경로와
    MIDI 요약을 보여 준다. *)

type result_kind =
  | Played
  | Opened
  | Saved of string  (** 저장 경로; 외부 앱 열기가 안 될 때도 파일은 남는다 *)
  | Failed of string

type outcome = {
  name : string;
  result : result_kind;
  midi_summary : string option;  (** MIDI이고 파싱에 성공했을 때만 [Some] *)
}

val describe_outcome : outcome -> string
(** 상태 줄 한 줄: [playing <name>], [opened <name>], [saved <name> · <path>],
    [failed <name> · <reason>]. MIDI 요약이 있으면 뒤에 [ · <요약>]. *)

type prepared
(** Acquired bytes and saved file, without starting a player or external app. *)

val prepare :
  fetch:(sha256:string -> (string, string) result) ->
  Masc_tui_types.board_attachment ->
  (prepared, outcome) result
(** Fetch, validate the served-byte boundary, atomically publish the rebuilt
    cache file under its full digest, and parse MIDI metadata.
    Run outside the input loop. Failure never starts a process. *)

val perform : prepared -> midi_soundfont:string option -> outcome
(** Start the prepared action only after the caller admits its original owner.
    Does not fetch, write or parse attachment bytes. *)

val run :
  fetch:(sha256:string -> (string, string) result) ->
  Masc_tui_types.board_attachment ->
  midi_soundfont:string option ->
  outcome
(** URL 첨부는 바로 연다. artifact 첨부는 [fetch]로 바이트를 받아 캐시에
    저장한 뒤 kind별 동작을 한다. 업로드·HTTP 읽기와 같은
    [Tool_blob_store.max_served_bytes]까지 허용하며, 이를 넘으면 파일을 쓰지
    않고 거절한다. 저장·fetch 실패는 [Failed]의 사유가 된다. *)
