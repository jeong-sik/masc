import { chromium } from '../../../dashboard/node_modules/playwright/index.mjs';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const evidenceDir = path.dirname(new URL(import.meta.url).pathname);
const htmlPath = path.join(evidenceDir, 'evidence-matrix.html');
const outputPath = path.join(evidenceDir, 'evidence-matrix.png');
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 1 });

await page.goto(pathToFileURL(htmlPath).href);
await page.getByRole('heading', { name: 'Official-client Skill delivery → action causality' }).waitFor();
if (await page.locator('#details').isVisible()) throw new Error('exact IDs must start collapsed');
await page.getByRole('button', { name: 'Show exact IDs' }).click();
await page.getByText('trace-1787654779375-00001#295').waitFor();
await page.getByText('1 invocation · 1 delivery · 1 action · 0 invalid').waitFor();
await page.screenshot({ path: outputPath, fullPage: true });
await browser.close();

console.log(`interaction=details-expanded`);
console.log(`assertion=causality-row-visible`);
console.log(`screenshot=${outputPath}`);
