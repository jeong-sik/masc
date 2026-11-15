### Fixed

- When the fleet waiting read fails, the Plain Keepers header now names why
  each source could not be read, as the server put it (for example
  `운영자 확인 기한 관측 불가`), right after `대기 원본을 읽지 못했습니다`.
  Before, it drew only that fixed sentence and dropped the server's reasons.
  A source with no sentence shows the next action the server named, and one
  with neither says so. The header line stays one line and a narrow frame
  cuts its closing note first. The axis views read the reasons from the same
  choice, so a store read failure there shows the server's sentence instead
  of the store name alone (#51764, #PENDING).
