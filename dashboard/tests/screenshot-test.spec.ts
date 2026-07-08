import { test } from '@playwright/test';
import * as path from 'path';

const ARTIFACT_DIR = '/Users/dancer/.gemini/antigravity-cli/brain/efa1086d-f862-47cd-88f9-6353ce96a54d';

test('capture screenshots', async ({ page }) => {
  // Set viewport to a nice standard desktop size
  await page.setViewportSize({ width: 1440, height: 2200 });

  // 1. Capture standalone mockup HTML
  console.log('Opening standalone mockup HTML...');
  const htmlUrl = 'file:///Users/dancer/Downloads/Keeper Agent v2 (standalone) (3).html';
  await page.goto(htmlUrl);
  await page.waitForTimeout(1000);

  // Click the "예약" (Schedule) button in NavRail
  console.log('Navigating to Schedule tab in mockup...');
  const scheduleBtnMock = page.locator('.v2-nav button, .nav-item').filter({ hasText: '예약' }).first();
  if (await scheduleBtnMock.count() > 0) {
    await scheduleBtnMock.click();
    await page.waitForTimeout(1500); // Wait for CSS transitions
  } else {
    console.log('Schedule button not found in mockup rail, trying to find by text...');
    const textBtn = page.getByRole('button', { name: '예약' }).first();
    if (await textBtn.count() > 0) {
      await textBtn.click();
      await page.waitForTimeout(1500);
    }
  }

  // Take mockup screenshot
  const mockupPath = path.join(ARTIFACT_DIR, 'mockup_schedule.png');
  await page.screenshot({ path: mockupPath, fullPage: true });
  console.log(`Saved mockup screenshot to ${mockupPath}`);

  // 2. Capture live ported preact dashboard
  console.log('Opening live ported dashboard...');
  const liveUrl = 'http://127.0.0.1:5173/dashboard/#schedule';
  await page.goto(liveUrl);
  await page.waitForTimeout(4000); // Wait for API fetch and rendering

  // Click the demo mode button to enable demo mode (so it shows mockup alignment data)
  const demoBtn = page.getByRole('button', { name: /데모 모드/ });
  if (await demoBtn.count() > 0) {
    console.log('Enabling demo mode...');
    await demoBtn.click();
    await page.waitForTimeout(1000); // Wait for rendering update
  }

  // Take ported screenshot of the full page
  const portedPath = path.join(ARTIFACT_DIR, 'ported_schedule.png');
  await page.screenshot({ path: portedPath, fullPage: true });
  console.log(`Saved ported screenshot to ${portedPath}`);
});
