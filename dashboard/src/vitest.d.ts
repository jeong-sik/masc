import 'vitest'
import 'jest-axe'

// vitest-setup.ts registers the runtime matcher. Vitest 5 uses its own
// matcher interface, so expose jest-axe's assertion there as well.
declare module 'vitest' {
  interface Matchers<R, T> {
    toHaveNoViolations: jest.Matchers<R, T>['toHaveNoViolations']
  }
}
