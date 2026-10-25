# 실제 coding grader 경계 보충 실측

source `32282146`의 기존 consumer만 실행했습니다. 첫 제공 이미지 `de170b`는 Python 부재로 verify exit 127이었고 이 실패를 보존했습니다. 같은 실행에서 기존 Node oracle 복원과 static symlink 거부 method는 통과했습니다.

이미 설치된 별도 Python 이미지 `a6e34c`에서 Docker method만 다시 실행해 통과했습니다. 실제 Docker exit는 0, 0, 0, 0, 7이며 가운데 verify/regression/build는 같은 frozen snapshot을 사용했습니다. 원본 snapshot을 다시 해시해 세 receipt와 정확히 대조했습니다. 이 fixture의 regression/build는 verify script를 복사한 Python 경계 검사이며 실제 프로젝트 compiler build 성공을 뜻하지 않습니다.

기존 unittest 3종을 선택했고 최초 3회 중 Docker 1회 실패, 나머지 2회 통과, 적합한 이미지에서 Docker method 재실행 1회 통과입니다. 최초 실패를 지운 4/4 성공으로 집계하지 않습니다. Node oracle 원본 비교 4 subprocess는 host consumer 검사로 구분합니다.

실측은 controlled host sentinel/marker, Docker socket, network target, non-root, read-only input, disposable guest workspace와 단계간 frozen input에 한정됩니다. 실제 credential 값은 읽지 않았습니다. microVM·SSH 실행 성공, 전체 coding suite나 production 적용으로 확장하지 않습니다.

정확한 명령의 private rawhash, 실제 stage receipt/stdout/exit와 이미지 cohort는 `actual-coding-boundary.json`에 있습니다. private 원본 전체 해시는 별도 manifest로 보존했습니다.
