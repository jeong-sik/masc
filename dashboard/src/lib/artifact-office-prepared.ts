// An ephemeral projection of the HTML source, built with the Word blocks.
// HWPX consumes the same nested structure; integer twips cannot carry every
// integer HWPUNIT width. No geometry is recovered from a table's flat index.
export type PreparedOfficeBlock = { readonly kind: 'paragraph' } | PreparedOfficeTable
export type PreparedOfficeCell = {
  readonly column: number;
  readonly columns: number;
  readonly rows: number;
  readonly width: number | null;
  readonly children: readonly PreparedOfficeBlock[];
}
export type PreparedOfficeTable = {
  readonly kind: 'table';
  readonly columns: number;
  readonly width: number | null;
  readonly rows: readonly (readonly PreparedOfficeCell[])[];
}

// Round boundaries, rather than independent columns, so every merged width
// equals the sum of its grid columns and the table equals the rounded total.
export function officeTableTwips(widths: readonly number[]): number[] {
  let boundary = 0, previous = 0
  return widths.map(width => {
    if (!Number.isSafeInteger(width) || width <= 0 || !Number.isSafeInteger(boundary + width)) {
      throw new Error('표의 명시적 열 너비를 읽을 수 없습니다.')
    }
    boundary += width
    const next = Math.round(boundary / 5), twips = next - previous
    if (twips <= 0) throw new Error('표의 열 너비가 DOCX에서 표현할 수 있는 단위보다 작습니다.')
    previous = next
    return twips
  })
}
