---
name: notify
description: Send Telegram notifications from any claw instance. USE WHEN you need to alert the user about completed operations, important findings, errors, or status updates.
---

# Notify — Telegram Alerts

Send Telegram messages from any claw instance on this machine. Useful for long-running operations, important findings, or status updates that shouldn't wait for the next user session.

---

## Runtime Location

Global skill — available to all claw instances on this machine.

Configuration sourced from environment or claw instance config.

---

## Send a Notification

### Via curl (simplest)

```bash
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
MESSAGE="$1"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": \"${MESSAGE}\", \"parse_mode\": \"Markdown\"}"
```

### Via TypeScript (for richer formatting)

```typescript
const token = process.env.TELEGRAM_BOT_TOKEN
const chatId = process.env.TELEGRAM_CHAT_ID

async function notify(message: string, parseMode: 'Markdown' | 'HTML' = 'Markdown') {
  const res = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      chat_id: chatId,
      text: message,
      parse_mode: parseMode
    })
  })
  if (!res.ok) {
    console.error('Telegram notify failed:', await res.text())
  }
}

await notify('*JobClaw*: Found 3 new platform engineer roles. Check pipeline.')
```

---

## Environment Variables

Each claw instance must have these set in its environment or config:

| Variable | Description |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Bot token from @BotFather |
| `TELEGRAM_CHAT_ID` | Your personal chat ID (get from @userinfobot) |

For jobclaw, these are set during `claw jobclaw channels add --channel telegram --token <TOKEN>`.

---

## When to Notify

Use notifications sparingly — only for events that warrant interrupting the user:

**Good reasons to notify:**
- Batch search completed with N new results
- Packet generated and ready for review
- DB sync completed
- Error that blocked an operation

**Don't notify for:**
- Routine status checks
- Every DB update
- Operations the user triggered synchronously

---

## Message Format

Use consistent prefixes so notifications are scannable:

```
*JobClaw* — <summary>

Details:
- item 1
- item 2

Next: `/jobclaw <action>` to proceed
```
