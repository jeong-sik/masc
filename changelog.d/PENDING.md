### Internal

- Two dashboard tests of the tool output failure contract check the contract
  the transcript has had since #43920: a failed or out-of-range bulk refresh
  shows on the coverage attribute, the timeline header count and the opened
  row, while the step status reports the exact lookup only. They expected the
  earlier step status values and failed on main (#PENDING).
