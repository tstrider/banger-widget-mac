# Banger — operating guide for an AI assistant

You are reading this because you manage someone's daily to-do list and Banger is where that
list lives. This page is self-contained. You do not need to read any other file, any source
code, or any other documentation to use it correctly.

---

## 1. What Banger is, and what you are doing to it

Banger is a checklist that lives as a widget on the user's Mac desktop. Checking a task off
fires a celebration on their screen — confetti, a sound, a thump through the trackpad. The
celebration gets bigger for the last task of the day and for a run of cleared days.

There is one list and it is for **today only**. There are no future dates, no projects and no
due dates. The list empties itself every morning (see §7).

Your job is to **fill the list in each morning** from what the user tells you, and to read it
back when they ask. You should not normally check tasks off for them — the celebration is the
point, and it belongs to the person who did the work. Only check something off if they
explicitly ask you to.

Three things write to this list: the widget on the desktop, the user's terminal, and you.
They all write the same file, and they can all write at the same instant.

---

## 2. THE HARD RULE

**Use the `bangerctl` command. Never redirect into `tasks.json`.**

```sh
# CORRECT
bangerctl add "Book the van" --source iris

# NEVER. NOT EVER. NOT EVEN ONCE.
echo '{...}' >  ~/Library/Application\ Support/Banger/tasks.json
echo '{...}' >> ~/Library/Application\ Support/Banger/tasks.json
```

A `>` redirect truncates the file before it writes, so anyone reading in that gap gets a
broken file — and it takes no lock, so it silently erases whatever the widget or the app
wrote a millisecond earlier.

This is not theoretical. Plain shell redirects into the file while something else reads it
**regularly hand the reader an unusable file.** With every writer going through `bangerctl`,
nothing is lost and no reader is ever handed a file it cannot parse.

The same rule covers every other way of writing the file directly:

| do not | reason |
|---|---|
| `>` or `>>` into `tasks.json` | truncates; no lock |
| `tee`, `sed -i`, `python ... open(path,"w")` | same two problems |
| opening it in an editor while the app runs | your save is based on a stale read |
| `mv` a temp file over it | atomic, but still takes no lock, so it can still erase a completion |

If you genuinely need to replace the whole document in one go, there is a safe command for
exactly that: `bangerctl set-json` (§9). It takes the same lock every other writer takes.

---

## 3. Setup, and checking you are talking to the right file

`bangerctl` lives in `~/.local/bin`. If your shell cannot find it:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Confirm it works and is pointed at the real list:

```sh
bangerctl path --json
```

```json
{
  "container" : "/Users/you/Library/Application Support/Banger",
  "tasks" : "/Users/you/Library/Application Support/Banger/tasks.json",
  "history" : "/Users/you/Library/Application Support/Banger/history.json",
  "existedBeforeResolution" : true,
  "isFallback" : true,
  "source" : "applicationSupportFallback",
  "strayLists" : [

  ],
  "rolloverHour" : 2,
  "rolloverTimeZone" : "America/Chicago",
  "rolloverSetBy" : "default",
  "today" : "2026-09-21",
  "nextRollover" : "2026-09-22T07:00:00Z"
}
```

`"source": "applicationSupportFallback"` is **correct and expected**. It is not a warning and
not a degraded mode. Do not try to "fix" it.

Check two things, once per session, before you write anything:

1. **`tasks` is `~/Library/Application Support/Banger/tasks.json`** (with the home folder
   spelled out). That is the only list the desktop widget can read. If `tasks` is anywhere
   else, stop: do not add anything, and tell the user the exact path you got.
2. **`strayLists` is empty.** Anything in it is a second list, left where an older version
   of `bangerctl` could write — see "A second list" below. Nothing reads it. Never add to it,
   copy from it or delete it yourself; mention it to the user once.

### A second list

Older versions of `bangerctl` chose their folder by trying the app group container
(`~/Library/Group Containers/group.com.bangerwidget.banger`) first. The desktop widget can never
read that folder. Most processes could not open it either, so they fell through to the real
one — but a shell whose host app had been given wider file access could, and then
`bangerctl` quietly kept its own list there. Everything added that way looked successful
and never reached the widget. `bangerctl path --json` said `"source": "appGroup"` when it
happened.

Current builds have no choice to get wrong: every Banger process uses
`~/Library/Application Support/Banger`. If you ever see `"source"` other than
`"applicationSupportFallback"` without having set `BANGER_CONTAINER` yourself, you are
running an old copy of `bangerctl`. Use `~/.local/bin/bangerctl`, and tell the user.

The last five fields are the day boundary (§7). `today` is the answer to "what day does
Banger think it is", and it is the field to check first if a list looks like it cleared at
a surprising moment.

Every command accepts `--json`. Use `--json` for everything you do — the human-readable output
is for people and its wording is not a contract.

---

## 4. Adding tasks — the morning fill-in

One task:

```sh
bangerctl add "Book the van" --source iris --json
```

```json
{
  "id" : "972utf",
  "index" : 1,
  "ok" : true,
  "source" : "iris",
  "text" : "Book the van"
}
```

Keep the `id`. It is six characters, lowercase, and contains no `l`, `i`, `o`, `0` or `1`, so
it survives being read aloud or retyped.

**Always pass `--source iris`.** Without it the task is recorded as the user's own. `source`
is the only way to tell later which tasks came from you, and the widget shows it on the row.
Valid values are free strings; use exactly `iris` for everything you add.

A whole morning's list, with the ids captured:

```sh
#!/bin/sh
set -eu
export PATH="$HOME/.local/bin:$PATH"

add() {
  bangerctl add "$1" --source iris --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
}

add "Call the realtor"
add "Export authenticator codes"
add "Book the van"
```

Run the adds **one at a time, sequentially**, as above. They are safe concurrently — the tool
takes a cross-process lock — but sequential is simpler to check and there is no speed to win:
each call is near-instant.

Rules for the text itself:

- One outcome per task. "Call the realtor" not "sort out the house stuff".
- Short. The widget row is narrow; anything past roughly 40 characters is truncated on the
  desktop. The full text is kept in the file and shown by `bangerctl list`, and the user
  can click a row's words to read all of it — but they should rarely need to.
- Any characters are fine, including quotes, emoji and newlines — the tool takes the text as a
  single argument and JSON-encodes it. Quote the argument in your shell.
- **Do not put anything in a task that you would not want on a screen.** The list is rendered
  on the desktop where anyone walking past can read it. No passwords, no account numbers, no
  medical details, no third-party private information.
- Do not add the same task twice. Read the list first (§5) if you are unsure.

### Do not invent ids

`bangerctl add` picks an id that does not collide. If you ever write your own (only possible
via `set-json`), it must be unique within the day, or a completion will hit the wrong row.

---

## 5. Reading the current state

```sh
bangerctl list --json
```

```json
{
  "date" : "2026-09-21",
  "done" : 1,
  "open" : 2,
  "fullyCleared" : false,
  "streakDays" : 4,
  "lastClearedDate" : "2026-09-20",
  "tasks" : [
    { "index" : 1, "id" : "a4nz9p", "text" : "Call the realtor", "done" : true,
      "source" : "me", "completedAt" : "2026-09-21T14:22:10Z" },
    { "index" : 2, "id" : "972utf", "text" : "Book the van", "done" : false,
      "source" : "iris" }
  ]
}
```

| field | meaning |
|---|---|
| `date` | the Banger day this list belongs to, `yyyy-MM-dd`. See §7 — it is **not** simply today's calendar date between midnight and 2am. |
| `done` / `open` | counts |
| `fullyCleared` | the list had tasks and every one is done |
| `streakDays` | consecutive days **before today** that ended fully cleared |
| `lastClearedDate` | the last day that ended with everything done; absent if never |
| `tasks[].index` | 1-based position, as a human would say it. Not stable across edits. |
| `tasks[].id` | stable within the day. **Use this, never the index, in scripts.** |
| `tasks[].completedAt` | ISO 8601 UTC, present only when `done` is true |

Streak only:

```sh
bangerctl streak --json
```

```json
{ "date": "2026-09-21", "done": 0, "open": 2, "fullyCleared": false,
  "streakDays": 0, "projectedStreakDays": 0 }
```

`projectedStreakDays` is what the streak would be if the day ended right now.

`bangerctl list` is cheap but it takes the read side of a lock. **Do not
poll it in a loop.** Once a second is the most you should ever need; once per user turn is
normal.

---

## 6. The file on disk

You should not write this file. You should be able to read it, so here it is.

```
~/Library/Application Support/Banger/tasks.json
```

```json
{
  "date": "2026-09-21",
  "streakDays": 4,
  "lastClearedDate": "2026-09-20",
  "tasks": [
    {
      "id": "a4nz9p",
      "text": "Call the realtor",
      "done": true,
      "source": "me",
      "completedAt": "2026-09-21T14:22:10Z"
    },
    {
      "id": "972utf",
      "text": "Book the van",
      "done": false,
      "source": "iris"
    }
  ]
}
```

Notes that matter:

- `completedAt` is absent, not null, when a task is not done.
- `lastClearedDate` is absent, not null, when there has never been a cleared day.
- **Unknown keys are preserved.** Anything you add that Banger does not recognise — at the top
  level or on a task — is read into an overflow bag and written back out untouched. So a
  `"project"` or a `"due"` key survives; it just is not displayed anywhere.
- There is a key called `"escalation"` at the top level. That is the celebration engine's own
  bookkeeping. **Do not touch it, do not copy it between days, do not reconstruct it.** If you
  strip it, the user gets duplicate celebrations for tasks they already completed.

Beside it:

| file | what it is |
|---|---|
| `history.json` | finished days, archived at the boundary |
| `archive/<day>.json` | one immutable copy of each finished day, written *before* the day resets. `archive/pending/` holds a day that is safe but not yet in `history.json`; the next read folds it in. |
| `history.corrupt-*.json`, `tasks.corrupt-*.json`, `tasks.empty-*.json` | a damaged file, moved aside instead of overwritten. Recover from it by hand if needed. |
| `.tasks.lock` | always empty; exists only so processes can lock it |
| `celebrated.json` | which tasks have already paid out today |
| `widget-read-receipt.json` | diagnostic, written by the desktop widget only while `widget-receipts-enabled` exists in this folder (off by default). Nothing depends on it. |
| `widget-scroll.json` | how far the user has scrolled the desktop widget's list, written by its arrows and ignored five minutes later. No task text. Leave it alone. |

---

## 7. The day boundary — 2am America/Chicago

**A Banger day runs from 02:00 to 02:00, in America/Chicago, always.** Not local midnight, not
the machine's time zone, not UTC.

So:

- At 13:00 on the 21st, `date` is `2026-09-21`.
- At **01:00 on the 22nd**, `date` is still `2026-09-21`. The night counts as part of the day
  that is ending.
- At 02:00 on the 22nd, `date` becomes `2026-09-22` and the list is empty.

**A task completed at 1am counts for the day that is ending.** That is the whole reason the
boundary is at 2am rather than midnight: finishing the last thing at 00:40 clears *that* day
and extends the streak, instead of starting a new day with one task on it and breaking a
streak that was never broken.

What happens at the boundary, in order:

1. Yesterday's document is appended to `history.json` — only if it had any tasks on it.
2. `tasks` becomes empty.
3. The streak moves: if yesterday had tasks and **every one** was done, `streakDays` goes up
   by one and `lastClearedDate` becomes yesterday. If yesterday had tasks and any were still
   open, `streakDays` goes to **0**. A day with nothing on it at all is not a failure and
   leaves the streak untouched.
4. `date` becomes the new day.

Consequences for you:

- **A task you added yesterday is gone today.** It is in `history.json`, not on the list. If
  something needs to survive the night, add it again after the boundary.
- **Do not add tomorrow's tasks tonight.** There is no future list. Anything you add at 23:00
  lands on the day that is ending and will be swept away at 02:00 with everything else
  undone — which also breaks the streak. Wait until after 02:00 Central.
- If you are filling the list in the morning, any time after 02:00 Central is the new day, and
  you do not need to do anything special.
- The boundary is handled for you. Do not try to trigger it, and never write `date` yourself.

**Daylight saving.** The zone is the named zone `America/Chicago`, so it follows US Central
DST automatically.

- On the spring-forward date, 02:00 CST does not exist — the clock jumps from 01:59:59 CST to
  03:00:00 CDT. The boundary is that jump instant. No day is skipped and no day is doubled.
- On the fall-back date, the clock goes from 01:59:59 CDT back to 01:00:00 CST, so **1am
  happens twice and 2am happens once**. Both passes of 1am belong to the day that is ending,
  which is what you would want. That day is 25 hours long.

---

## 8. Checking a task off (only when asked)

```sh
bangerctl done 972utf --json      # by id — what a script should always use
bangerctl done 2 --json           # by the position `list` printed — for a human
```

```json
{
  "ok" : true,
  "celebrated" : true,
  "message" : "Banger. \"Book the van\" — 1 left today.",
  "payload" : {
    "taskID" : "972utf", "taskText" : "Book the van", "taskIndex" : 0,
    "taskCount" : 2, "remaining" : 1, "fullyCleared" : false,
    "streakDays" : 0, "source" : "iris", "date" : "2026-09-21",
    "seed" : 15509140818978817976
  }
}
```

`"celebrated": true` means this call is the one that fired the confetti. Completing a task
that is already done returns `"celebrated": false` with `"ok": true` and fires nothing:

```json
{ "ok" : true, "celebrated" : false,
  "message" : "\"Book the van\" was already done. Nothing fired." }
```

So a retry is safe. Any number of processes completing the same task at the same instant
produce exactly one celebration.

The rest:

```sh
bangerctl undone 972utf --json    # un-check it; no celebration
bangerctl rm 972utf --json        # delete it
bangerctl clear --json            # empty today's list; the streak is untouched
```

`clear` is destructive and there is no undo. Only run it if the user says so in the current
turn, in words that mean "empty the list".

---

## 9. Replacing the whole list safely

Rewriting ten tasks at once, restoring a backup, importing a day from somewhere else:

```sh
bangerctl set-json < today.json
```

It reads the document from standard input, **refuses it unless it parses as a task document**,
takes the same lock every other writer takes, and lands it with an atomic rename. Nothing ever
sees a partial file.

Round trip:

```sh
bangerctl list --json > /tmp/before.json    # note: `list` output is NOT the file format
cp ~/Library/Application\ Support/Banger/tasks.json /tmp/banger-backup.json

python3 - /tmp/banger-backup.json <<'PY' | bangerctl set-json
import json, sys
doc = json.load(open(sys.argv[1]))
doc["tasks"].append({"id": "iris01", "text": "Book the van",
                     "done": False, "source": "iris"})
print(json.dumps(doc))
PY
```

Two warnings:

- **`set-json` replaces everything** — `tasks`, `streakDays`, `lastClearedDate`, `date`, the
  `escalation` bag, all of it. It does not merge. Start from the current file, not from
  scratch, or you will destroy the streak and the celebration bookkeeping.
- **It is last-writer-wins.** If the user might be ticking boxes at the same moment, use `add`
  and `done` instead; those are read-modify-write inside the lock, so they compose.

Note that `bangerctl list --json` output is **not** the file format — it adds `index`, `done`,
`open` and `fullyCleared`. Do not feed it back into `set-json`. Copy the real file.

---

## 10. When a command fails

Every command exits `0` on success, `1` on failure, and `2` on a usage mistake. **Errors go to
stderr as plain text, never as JSON, even with `--json`.** On failure stdout is empty. So:

```sh
if out=$(bangerctl add "$TEXT" --source iris --json 2>/tmp/banger.err); then
  id=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
else
  echo "banger failed: $(cat /tmp/banger.err)" >&2
fi
```

Check the exit code. Do not try to parse stderr as JSON, and do not assume stdout is JSON when
the exit code is non-zero.

| what you see | what it means | what to do |
|---|---|---|
| `command not found: bangerctl` | not on PATH | `export PATH="$HOME/.local/bin:$PATH"` and retry once. If it still fails, the app is not installed — tell the user, do not try to install it. |
| exit 1, `No task matching "xyz"` | the id or index is gone — the day rolled over, or someone deleted it | re-read with `bangerctl list --json` and use the id you get back. Never guess. |
| exit 1, `tasks.json is not readable: ... fix or move that file by hand` | the file is corrupt or is not a task document | **stop.** Do not overwrite it and do not "repair" it. Tell the user the exact message and the path. There may be a good copy in `history.json`. |
| exit 1, `Cannot reach the Banger container` | the folder is missing or not writable | stop and tell the user. Do not create directories or change permissions. |
| exit 1, `could not take ... within 5000 ms — another writer is wedged` | something is holding the lock | wait five seconds and retry **once**. If it fails again, stop and tell the user. |
| exit 2, usage text printed | you got the command or a flag wrong | fix the command. Do not retry the same thing. |
| exit 1, `the JSON handed to set-json is not a task document` | your document is malformed | nothing was written. Fix the JSON and retry. |

**Never retry more than once**, and never retry a `clear`, an `rm` or a `set-json`
automatically — a "failure" that actually landed would do the damage twice.

**Never work around a failure by writing the file directly.** If `bangerctl` will not do it,
the answer is to tell the user, not to reach past it.

---

## 11. Does the user see it?

Three different answers, and the difference matters.

- **The celebration is immediate.** Any correct write to the file fires it — you do not need to
  notify anything. The overlay is on screen a moment after the write.
- **`bangerctl list --json` is the source of truth and it is instant.**
- **The widget on the desktop is not immediate and cannot be.** macOS decides when to redraw a
  widget, on a budget of roughly 40–70 redraws a day. Expect seconds, sometimes minutes.
  **Never treat the widget as confirmation that your write landed.** If the user says "I don't
  see it", read the list back and tell them what it says; the corner will catch up.

One more: the celebration only happens if the background app is running.

```sh
pgrep -x Banger >/dev/null && echo "agent running" || echo "agent NOT running"
```

If it is not running, tasks and the list still work perfectly — only the confetti is missing.
Tell the user; the fix is `open -a /Applications/Banger.app` and it is theirs to run.

---

## 12. Quick reference

```sh
export PATH="$HOME/.local/bin:$PATH"

bangerctl path   --json                      # where the list actually lives
bangerctl list   --json                      # today, the source of truth
bangerctl streak --json                      # streak and progress
bangerctl add "text" --source iris --json    # add  — ALWAYS --source iris
bangerctl done   <id> --json                 # check off — CELEBRATES
bangerctl undone <id> --json                 # un-check
bangerctl rm     <id> --json                 # delete
bangerctl clear  --json                      # empty today's list
bangerctl set-json < doc.json                # replace the whole document, safely
```

Six rules, in order of how much damage breaking them does:

1. Never write `tasks.json` with `>`, an editor, or anything but `bangerctl`.
2. Always pass `--source iris`.
3. Use `id`, never `index`, in anything scripted.
4. Check the exit code; stderr is plain text, not JSON.
5. Retry at most once, and never retry a destructive command.
6. The day turns at 02:00 America/Chicago — a task finished at 1am belongs to yesterday.
