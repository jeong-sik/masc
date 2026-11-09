---
rfc: "admission-forest-closure"
title: "모든 후보의 커밋과 ACK가 끝난 admission forest를 함께 닫는다"
status: Draft
created: 2026-11-10
updated: 2026-11-10
author: codex
related: ["librarian-history-settles-finished-originals", "0500"]
---

# 모든 후보의 커밋과 ACK가 끝난 admission forest를 함께 닫는다

설계 논의: [#50709](https://github.com/jeong-sik/masc/issues/50709).
기준 소스는 `79d8ef2e38626807f8c85b82aaffbc52356f4959`다.
이 문서는 제안이며, 구현·배포·설치 시간 개선의 증거가 아니다.

## 문제와 기존 경계

정상 `Commit.settle`은 Memory disposition과 candidate ACK를 처리하고
original을 남긴다. install의 저장소 검사는 남은 original을 다시 읽는다.
history settle RFC의 Q2가 이 admission 수명을 별도 과제로 남겼다.

`Finished`는 accepted subset의 커밋이다. 원래 batch 전체가 소비됐다는 뜻이
아니다. `Parts.runnable`은 게시 중인 partition의 부모를 반환하지 않으므로
빈 실행 목록도 전체 종료의 증거가 아니다. supersession과 partition은 이전
part·execution·gate를 참조한다. 종료 execution만 옮기면 다음 discovery가 깨진다.

`Owner.settle`은 record를 보관 위치로 옮긴 뒤 body를 제거한다. body 백업이
아니다. `Owner.settled`는 동기화된 marker 존재 관측이며 그 내용의 일치,
body 제거 완료, candidate 커밋 또는 ACK를 입증하지 않는다.

## 최초 처리 범위

기존 workspace lease, Memory lane과 purge fence 안에서 현재 owner의 완전한
4개 scope(part, partition, execution, gate)를 엄격히 발견한다. 다음을 모두
만족할 때 그 forest 전체를 한 단위로 닫는다.

1. 원래 physical owner, Memory epoch와 queue generation이 현재와 같다.
2. 모든 partition은 정확한 두 자식의 게시 ACK가 끝났다. 활성 root와 leaf가
   비어 있지 않고 모든 root의 전체 후보가 그 leaf들로 정확히 덮인다.
3. 모든 활성 leaf는 실제 host·gate 증거까지 검증된 정상 `Finished`다.
4. 과거 root·partition을 포함한 모든 원래 candidate ID에 실제 Current의
   committed receipt가 정확히 일치하며, 같은 ID가 pending queue에 없다.
   accepted subset, sequence만 비교한 결과나 journal marker로 대체하지 않는다.
5. 새 tail은 다른 candidate로 남을 수 있다. 후보 하나라도 미처리이거나
   unknown/cut, 게시 대기, 누락·손상된 증거가 있으면 그 forest를 남긴다.

현재 strict discovery가 거부하는 과거 conflict/receipt 조합을 closure가
허용하지 않는다. 그런 상태의 별도 복구는 이 제안의 범위 밖이다.

## 이동을 복구하는 original

part의 `progress=[]` 계약은 유지한다. owner별 closure scope에 하나의 host
original을 retain한다. 그 불변 manifest는 다음을 고정한다.

- 전체 member의 scope, request ID, installation/package/tool, body digest,
  summary와 전체 progress. 다른 record가 같은 body를 참조하지 않음도 확인한다.
- part·partition·gate의 원문. 큰 execution snapshot은 복제하지 않는다.
- 전체 원래 candidate ID와 closure ID에서 유도한 UTC 보관 날짜.

새 provider나 domain write를 도입하지 않는다. 기존 partition과 같은 host
Progress 전이를 사용한다. 최초 세 이벤트를 `Owner.advance_events`로 한 번
게시한다: `Dispatch_intended`, typed manifest의 `Judgment_retained`, 정확한
member 집합의 `Commit_intended`. `Commit_observed`는 모든 member 이동이
확인된 뒤에만 기록한다. Captured manifest만 있으면 이동하지 않는다.

이동 순서는 모든 gate, 모든 execution, partition·part, closure original이다.
gate를 읽는 동안 부모 execution은 live다. 남은 execution의 부모 part와 gate
payload는 manifest의 고정된 원문으로 검증할 수 있다. 마지막 closure 이동
전까지 복구 자료를 유지한다.

## 중단과 읽기 전용 검사

다음 pass는 일반 strict discovery 전에 closure original을 확인한다. 현재
owner와 전체 candidate receipts 및 ACK 부재를 다시 확인하고, 각 member가
동일한 live record이거나 원래 날짜의 정확한 archived record인지 확인한다.
양쪽 모두 없음, 변경, 추가 member, 잘못된 scope나 보관 날짜는 오류다.
`settled=true`만으로 누락을 허용하지 않는다. archive metadata를 읽는 port도
기존 owned-descriptor 및 동기화 경계를 따라야 한다.

복구는 같은 member 이동만 재개한다. provider call, Memory commit이나 queue
ACK는 수행하지 않는다. 이동 실패·취소의 결과를 부재로 추정하지 않는다.

preflight는 현재 live closure와 manifest를 읽어 part·partition·gate의 명시적
read-through를 제공한다. 남은 live body의 digest·schema·owner·parent 검사는
기존 순수 decoder로 수행한다. closing manifest의 일치 확인 없이 missing
parent를 완료로 해석하지 않는다. 이 검사는 이동이나 완료 판정 권한이 없다.

archive sweep은 closure manifest가 가리키는 marker를 보호한다. closure가
끝난 뒤의 archive 정책은 기존 sweep을 따른다. live backlog의 임의 삭제,
나이 기준 삭제, 검사 생략 옵션과 수동 bulk cleanup은 추가하지 않는다.

마지막 anchor의 record 이동과 body 제거 사이에 중단되면, 다른 기존 settle과
같이 참조 없는 anchor body가 남을 수 있다. 이 제안은 archive 전체를 다시
검색하거나 그 body를 추정 삭제하지 않는다. 이후 실행을 막거나 원래 후보를
재실행시키지는 않지만, startup의 body inventory에는 비용이 남을 수 있다.
member의 큰 execution body는 anchor를 닫기 전에 모두 제거·동기화한다.

기존 active part/execution 형식은 바꾸지 않아 별도 hard cut이 필요하지 않다.
다만 live closure를 모르는 구버전은 그 scope의 검사에서 멈춘다. 부분 이동
중인 상태를 구버전으로 복구할 수 있다고 주장하지 않는다.

## 검증과 비교

모델 없는 fixture에서 전체 커밋, subset만 커밋, ACK 미완료, 새 tail,
게시 중/한 자식만 있는 partition, 분할·supersession 연결을 확인한다.
각 이동 직후와 record 이동/body 제거 사이 중단을 재현하고, read-only
preflight 및 restart가 같은 member로 재개하는지 검사한다. marker의 누락·
변경, epoch/generation 변화, 예상 밖 member는 거부돼야 한다. 재개 전후
provider 호출 수, Memory revision/receipts와 pending queue는 그대로여야 한다.

같은 고정 fixture의 남은 active record/body 바이트와 전체 preflight 시간을
비교한다. 최초 closure 비용과 다음 검사의 비용을 따로 남긴다. fixture
결과를 전체 설치나 live backlog 개선으로 환산하지 않는다.

기존 history/Curator settle은 재사용할 저장 경계의 선례다. 도메인별 종료
조건은 복사하지 않는다. [SQLite multi-file commit](https://www.sqlite.org/atomiccommit.html#_multi_file_commit)은
여러 파일 변경 전에 durable membership을 고정하고 복구 자료를 보존하는
비교 사례다. 여기서는 rollback journal을 이식하거나 ACID 전체를 주장하지 않는다.
