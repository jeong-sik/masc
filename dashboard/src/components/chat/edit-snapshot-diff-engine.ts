import { createTwoFilesPatch } from 'diff'

export function computeEditSnapshotDiff(before: string, after: string): string {
  return createTwoFilesPatch('before', 'after', before, after, undefined, undefined, {
    ignoreWhitespace: false,
    stripTrailingCr: false,
  })
}
