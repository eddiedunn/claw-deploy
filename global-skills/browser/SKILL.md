---
name: browser
description: Playwright-based web browsing, scraping, and automation. USE WHEN fetching job listings, scraping job descriptions, visiting URLs, verifying links, or interacting with pages that require JavaScript or authentication.
---

# Browser — Playwright Web Automation

Headless browser automation for any claw instance. Handles JavaScript-heavy pages, login-walled content, and sites that block simple HTTP fetches (Indeed, LinkedIn, Upwork, etc.).

---

## Runtime Location

Global skill — available to all claw instances on this machine.

Scripts live at: `<CLAW_HOME>/shared/skills/browser/scripts/`

Playwright is installed in the picoclaw/jobclaw Node environment. Run scripts with `bun run`.

---

## Scripts

### `browse.ts` — General page fetch and screenshot

```bash
# Screenshot a page
bun run <CLAW_HOME>/shared/skills/browser/scripts/browse.ts screenshot "<url>" /tmp/output.png

# Extract visible text
bun run <CLAW_HOME>/shared/skills/browser/scripts/browse.ts text "<url>"

# Extract visible text and save to file
bun run <CLAW_HOME>/shared/skills/browser/scripts/browse.ts text "<url>" /tmp/output.txt
```

### Usage Pattern (TypeScript API)

For more control, use the Playwright API directly in TypeScript scripts:

```typescript
import { chromium } from 'playwright'

const browser = await chromium.launch({ headless: true })
const context = await browser.newContext({
  viewport: { width: 1400, height: 900 },
  userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'
})
const page = await context.newPage()

await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 })
await page.waitForSelector('[data-jk]', { timeout: 10000 })  // for Indeed
const text = await page.innerText('body')

await browser.close()
```

---

## Common Use Cases

### Job board scraping (Indeed)

Use `indeed-search.ts` from the jobclaw workspace skills — it wraps Playwright with Indeed-specific selectors. Do NOT run parallel headless instances against Indeed (rate-limited).

```bash
# From jobclaw workspace
bun run <WORKSPACE>/scripts/indeed-search.ts "platform engineer AI" --pages=2
```

### Job description extraction

```bash
bun run <CLAW_HOME>/shared/skills/browser/scripts/browse.ts text "https://jobs.example.com/post/12345" /tmp/job.txt
```

### LinkedIn job listings (guest API — no browser needed)

LinkedIn's guest API works without a browser for search. Use browser only for detail pages that require auth:

```
https://www.linkedin.com/jobs-guest/jobs/api/seeMoreJobPostings/search?keywords={keyword}&location=United+States&geoId=103644278&start={offset}&f_TPR=r604800&f_WT=2
```

---

## Notes

- Always use `waitForSelector` with a specific element, not `waitForNetworkIdle` (times out on dynamic pages)
- Indeed: use `[data-jk]` for job cards, `#jobDescriptionText` for detail pages
- Rate-limit awareness: Don't run more than one headless browser against the same domain in parallel
- For pages with anti-bot detection, add a realistic `userAgent` string and random delays between actions
- Screenshots save as PNG; use the Read tool to visually inspect them after capture
