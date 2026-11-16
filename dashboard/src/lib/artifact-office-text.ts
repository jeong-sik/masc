/** XML 1.0 Char, shared by Office input, chart data and package metadata. */
export function officeXmlCharacter(code: number): boolean {
  return code === 9 || code === 10 || code === 13 || (code >= 0x20 && code <= 0xD7FF)
    || (code >= 0xE000 && code <= 0xFFFD) || (code >= 0x10000 && code <= 0x10FFFF)
}

export function checkOfficeText(text: string): void {
  for (const character of text) if (!officeXmlCharacter(character.codePointAt(0)!)) {
    throw new Error('문서에 XML에서 표현할 수 없는 문자가 있습니다.')
  }
}

export function officeHtmlText(text: string): string {
  return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;')
}

export function officeXmlText(text: string): string {
  checkOfficeText(text)
  return officeHtmlText(text)
}
