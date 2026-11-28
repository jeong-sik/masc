/** The server's ask-answer refusal while a shutdown holds the Keeper's
    intake: HTTP 503 with `state: "keeper_shutting_down"`. */
export function isAskAnswerRefusedForShutdown(
  status: number | null | undefined,
  body: unknown,
): boolean {
  if (status !== 503 || typeof body !== 'object' || body === null || Array.isArray(body)) {
    return false
  }
  return (body as Record<string, unknown>)['state'] === 'keeper_shutting_down'
}
