// Load the diff engine only when the operator opens an edit. Its asynchronous
// mode yields during comparison rather than blocking the chat event loop.
export async function editSnapshotDiff(before: string, after: string): Promise<string> {
  const { createTwoFilesPatch } = await import('diff')
  return new Promise(resolve => {
    createTwoFilesPatch('before', 'after', before, after, undefined, undefined, {
      ignoreWhitespace: false,
      stripTrailingCr: false,
      callback: resolve,
    })
  })
}
