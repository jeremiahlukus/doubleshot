# DoubleShot

A macOS menu bar app that watches what Claude Code costs you and keeps your Mac
awake while it's working.

It combines two smaller projects: [NoDoz](https://github.com/andrewwatson/NoDoz) (a menu
bar sleep-prevention toggle) and `claude_cost` (daily spend visibility and threshold
alerts). The reason to merge them is that they already knew each other's secret: NoDoz
solves "don't fall asleep during a long run," and claude_cost is the thing that can tell
when a long run is happening.

```
┌─ menu bar ──────────────────┐
│  ☕ $13.47/$50              │   green → yellow → orange → red
└─────────────────────────────┘
```

Registered as *DoubleShot for Claude Code*; it presents itself as **DoubleShot**
everywhere in the UI.

## What it does

- **Live spend in the menu bar** — `$13.47/$50`, coloured by how close you are.
- **Auto keep-awake** — holds a power assertion while Claude Code is mid-run and
  releases it when things go quiet. Or force it on/off by hand, with an auto-off timer.
- **A dashboard** — 30/7/90-day history, spend by model, spend by project.
- **An editable limit** — click the limit anywhere it appears and type a new one.
- **Threshold alerts** — a notification the first time you cross 50% / 80% / 100% each day.

Everything is read from the transcripts Claude Code already writes to
`~/.claude/projects`. No network calls, no telemetry.

## Install

Grab the latest **DoubleShot.dmg** from
[Releases](https://github.com/jeremiahlukus/doubleshot/releases), open it, and drag the app
to Applications.

It's signed with a Developer ID certificate and notarized by Apple, so it opens normally —
no right-click → Open, no "unidentified developer" warning. Verify that yourself if you
like:

```bash
spctl -a -vvv -t exec /Applications/DoubleShot.app
# accepted
# source=Notarized Developer ID
# origin=Developer ID Application: Jeremiah Parrack (YWNTFJ7ZP3)
```

There's no Dock icon — look in the menu bar. Enable **Launch at Login** from the panel if
you want it to stick around.

> Distributed directly rather than through the Mac App Store, which isn't an option here:
> the App Store requires the App Sandbox, and a sandboxed app can't read
> `~/.claude/projects`, can't shell out to `pmset`, and can't install the sudoers rule that
> makes lid-closed mode work. Those three things are the app.

## Requirements

- macOS 13.0+
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the project from `project.yml`

## Building from source

```bash
xcodegen generate           # brew install xcodegen, if needed
open DoubleShot.xcodeproj   # then ⌘R
```

Or from the command line:

```bash
xcodebuild -project DoubleShot.xcodeproj -scheme DoubleShot -configuration Release build
cp -R ~/Library/Developer/Xcode/DerivedData/DoubleShot-*/Build/Products/Release/DoubleShot.app /Applications/
open /Applications/DoubleShot.app
```

There's no Dock icon — look in the menu bar. Turn on **Launch at Login** from the panel
if you want it always there.

Renaming the app is one field: change `name:` in `project.yml` (plus
`PRODUCT_BUNDLE_IDENTIFIER`) and regenerate.

## Setting your limit

Click the limit in the menu bar panel — or the dashboard header — and type a number.
Presets are there for $25/$50/$100/$200.

The limit lives in `~/.claude/usage-budget.json`, **deliberately the same file the
claude_cost statusline reads**, so changing it in either place moves both:

```json
{ "daily_limit": 100.0, "thresholds": [50, 80, 100] }
```

Set it to something you'd actually react to. If it fires every morning you'll learn to
ignore it; if it never fires it isn't telling you anything. Open the dashboard, look at
your median day, and put the limit somewhere you'd want to be interrupted.

## Keep-awake modes

| Mode | Behaviour |
|---|---|
| **Off** | Never holds anything. |
| **On** | Holds until you turn it off, or until the auto-off timer expires (30m / 60m / 2h). |
| **Auto** | Holds while Claude is mid-turn; releases the moment it's waiting on you. |

This tracks **Claude's** activity, not the computer's. Nothing in the decision looks at
your keyboard, mouse, or system idle time — you can type in another app all day and Auto
still releases, or walk away entirely while Claude works and it keeps holding.

Auto reads Claude's actual state off the tail of the live transcripts rather than guessing
from a timer, because a timer can't tell a 40-minute build from a finished turn:

| Last meaningful record | State | Behaviour |
|---|---|---|
| assistant, `stop_reason: tool_use` | working | hold — a tool is running right now |
| a tool result | working | hold — Claude is about to act on it |
| assistant, `stop_reason: null` | working | hold — turn still in flight |
| a human message | working | hold — Claude is about to start |
| assistant, `stop_reason: end_turn` | waiting | release immediately |
| nothing stateful in the tail | unknown | fall back to the 10-minute timeout |

Consequences worth knowing:

- **A long tool call keeps holding.** Elapsed silence says nothing while a tool runs, so
  only the 45-minute backstop applies. That cap exists because "hold while working" would
  otherwise keep the machine awake forever on a hung command.
- **It releases the instant a turn ends**, rather than waiting out a grace period.
  Releasing doesn't put the Mac to sleep — it just stops overriding the normal idle rules,
  which still respect your keyboard and mouse.
- **A finished subagent doesn't count as idle.** Subagent transcripts finish with
  `end_turn` while their parent is still working, so every transcript written within 120s
  of the newest is considered and "working" wins.
- **Ambiguity errs towards working.** A false "waiting" drops the assertion mid-run, which
  is the exact failure this design removes; a false "working" costs at most the backstop.
- **Detection is global across every Claude Code session**, not scoped to one project.
  Any session working anywhere under `~/.claude/projects` counts, which is right for the
  purpose — but it means a session you've forgotten about in another project will hold
  your machine awake, and with lid mode on, hold it awake in a bag. That is what the
  2-hour cap is for. `Off` is the override.

Both assertions (`NoIdleSleep` and `NoDisplaySleep`) are released when the app quits.

## Working with the lid closed

Power assertions **cannot** keep a MacBook running with the lid shut. `NoIdleSleep` and
`NoDisplaySleep` only defer *idle* sleep; lid close is a separate forced path in macOS,
and `caffeinate` doesn't stop it either. The only thing that does is
`pmset -a disablesleep 1`, which requires root.

So it's opt-in and needs a one-time setup:

```bash
sudo ./scripts/enable-lid-mode.sh     # installs /etc/sudoers.d/doubleshot
```

That grants exactly two commands passwordless and nothing else:

```
pmset -a disablesleep 1     # stop sleeping on lid close
pmset -a disablesleep 0     # restore normal behaviour
```

The script validates the file with `visudo -c` before installing it and rolls back if
`/etc/sudoers` fails to parse afterwards — a malformed sudoers file can lock you out of
`sudo` entirely. Undo with `sudo ./scripts/disable-lid-mode.sh`.

Then tick **Keep running with lid closed** in the panel. Give Claude a task, close the
lid, and it keeps working; lid sleep is restored the moment Claude goes idle.

### Why this gets more care than an assertion

An assertion dies with the process. `disablesleep` is **global system state** that
outlives the app, so:

- **A marker file is written before arming.** If the app is killed while armed, your Mac
  would otherwise never sleep on lid close again. The next launch sees the marker and
  restores lid sleep immediately.
- **A 2-hour hard cap** disarms regardless of what Claude appears to be doing, so a hung
  tool call can't hold a closed laptop awake in a bag all night. Separate from the
  45-minute keep-awake cap — this one is about heat and battery, not run length.
- **The menu bar shows a ⚠️** whenever lid sleep is disabled. Global state should never
  change without something visible saying so.
- **`sudo -n`** is used so a missing rule fails in ~60ms instead of hanging an accessory
  app on a password prompt it has no window to display.

### Read this before relying on it

- **Heat.** A closed MacBook under sustained load has much worse airflow — the lid and
  keyboard deck are part of the cooling path. Apple's clamshell mode assumes an external
  display and power for a reason.
- **Battery.** This does not require AC power by design, so closing the lid on battery and
  putting the machine in a bag will drain it and warm it. That's the case the 2-hour cap
  exists for.
### Verified end-to-end

Confirmed with a real 5-minute closed-lid run on a MacBookPro18,1 on AC power, with a
logger writing a timestamp every 5 seconds:

- **218 samples, no gaps** across the closed window, each recording `SleepDisabled=1`.
- **No sleep event in `pmset -g log`** during the window — while the same log shows
  `Entering Sleep state due to 'Clamshell Sleep'` repeatedly earlier the same day on the
  same machine and power source. That contrast is the actual proof.
- **A real Claude session kept working the whole time.** A separate session in another
  project ran continuously from 10:41:18 to 10:46:05 with the lid shut, including a
  ~2-minute tool call that both started and finished while closed.

The same run validated both directions of the activity detection against wall-clock
reality: it disarmed 15s after a session went `end_turn`, and re-armed 16s after another
session resumed.

To re-test after changing anything here:

```bash
# in one shell
while :; do echo "$(date '+%H:%M:%S') SleepDisabled=$(pmset -g | awk '/SleepDisabled/{print $2}')"; sleep 5; done | tee /tmp/lid-test.log
# set Keep awake to On (not Auto — Auto disarms when Claude goes idle, which a
# closed lid guarantees), confirm the menu bar warning, close the lid, reopen
pmset -g log | grep -iE "Entering Sleep|Wake from" | tail
```

Gaps in the log, or a `Clamshell Sleep` entry during the window, mean it didn't hold.

Sizing came from measuring 288,984 real gaps between transcript writes, classified by
whether Claude was working or waiting when the gap ended. For gaps where it was genuinely
working: p99 = 54s, p99.9 = 5.2 min. The 10-minute fallback therefore covers 99.94% of
mid-run quiet stretches; pushing it higher has sharply diminishing returns because the
remaining tail is resumed sessions (the longest "gap" is 15 days), not long tool calls.

## What actually drives the number

Most people are surprised by this, so in rough order of impact:

| Driver | Effect |
|---|---|
| **Model tier** | Opus input/output is 2.5×/2.5× Sonnet and 5×/5× Haiku. This dominates everything else. |
| **Effort level** | `xhigh`/`max` spend materially more thinking tokens than `medium`. |
| **Context window** | A `[1m]` model that fills its context re-sends a large prefix every turn. Cache reads are cheap (0.1×) but not free. |
| **Cache hit rate** | Cache *writes* cost 1.25× (5-min TTL) or 2× (1-hour). Invalidate your prefix every turn and you pay the write premium repeatedly without ever collecting the read discount. |
| **Session length** | Cost per turn grows with history. Ten focused sessions are much cheaper than one enormous one. |
| **Subagents / workflows** | Each agent carries its own context. Fanning out 12 agents is roughly 12 conversations. |

An alarming day is usually one of: a long agentic run on Opus at high effort, a workflow
that fanned out, or a session that grew to fill a 1M context and then kept going.

## Caveats — read these before quoting a number at anyone

- **These are API-rate equivalents, not an invoice.** Public list prices applied to local
  token counts. If your org has negotiated rates, real cost differs. It's a consistent
  yardstick for comparing *your own* days and habits, not a bill.
- **`/usage` is authoritative** for plan limits, org buckets, and actual credit consumption.
- **Local transcripts only.** Usage from other machines, Claude Code on web, or the
  desktop app isn't in `~/.claude/projects`, so it isn't counted.
- **Alerts, not enforcement.** Nothing here can stop a request. Crossing 100% gets you a
  notification, not a blocked prompt.
- **Prices drift.** See below.

## Updating prices

Rates are in `PricingTable.builtin`. Rather than rebuild when something is repriced, drop
a JSON file at `~/Library/Application Support/DoubleShot/pricing.json` — it's merged over
the built-ins at launch. Values are dollars per million tokens, `[input, output]`, with an
optional third value for models whose cache reads aren't the usual 0.1× input:

```json
{
  "standard": { "claude-opus-5": [5.0, 25.0], "claude-opus-5-5": [4.0, 20.0, 0.2] },
  "fast":     { "claude-opus-5": [10.0, 50.0] }
}
```

## How it works

| File | Role |
|---|---|
| `Cost/TranscriptScanner.swift` | Walks `~/.claude/projects`, prices each assistant response, aggregates by local day. |
| `Cost/PricingTable.swift` | Rates, model-id normalisation, cache multipliers. |
| `Cost/UsageModels.swift` | Transcript decoding and aggregation types. |
| `Cost/UsageStore.swift` | Scan loop, budget edits, menu bar rendering. |
| `Cost/Budget.swift` | Reads/writes `~/.claude/usage-budget.json`, preserving unknown keys. |
| `Cost/BudgetNotifier.swift` | Fires each threshold once per day. |
| `Power/KeepAwakeManager.swift` | Power assertions and the off/on/auto decision. |
| `Power/LidSleepController.swift` | Lid-close sleep via `pmset`, with the marker, cap and guards. |
| `UI/StatusBarIcon.swift` | Draws the menu bar label — template or coloured pill. |
| `UI/LimitEditor.swift` | The editable daily limit and presets. |
| `UI/PanelView.swift` | The menu bar dropdown. |
| `UI/DashboardView.swift` | The window. |
| `scripts/release.sh` | Signs, notarizes and staples a distributable DMG. |
| `scripts/make-icon.sh` | Renders the AppIcon set from one square PNG. |
| `scripts/enable-lid-mode.sh` | Installs the narrow sudoers rule for lid-closed mode. |

### Accuracy details

These are the difference between a useful number and a wrong one:

- **Subagent transcripts are counted.** They live one level deeper, at
  `<project>/<session>/subagents/agent-*.jsonl`, so the scan recurses. A `*/*.jsonl`
  glob misses them entirely and silently drops all subagent fan-out — which is exactly
  the kind of day you most want to see. (claude_cost has this bug; on this machine it
  was hiding 6,206 responses.) Verified as a real gap, not a double-count: there is zero
  dedup-key overlap between subagent and session transcripts.
- **Cache writes are split by TTL** — `ephemeral_5m_input_tokens` at 1.25× input,
  `ephemeral_1h_input_tokens` at 2×. Lumping them together misprices cache-heavy work.
- **Cache reads** bill at 0.1× input.
- **`input_tokens` is the uncached remainder only**, so total prompt size is
  `input_tokens + cache_creation + cache_read`. Reading only `input_tokens` undercounts badly.
- **Fast mode** (`speed: "fast"`) bills at premium Opus rates and is priced separately.
- **Responses are deduplicated** by `(requestId, model, output_tokens)` — the same API
  response appears in several transcripts after resumed sessions, sidechains and
  compaction rewrites. A record with no id at all is never deduped away.
- **`<synthetic>` messages are excluded** rather than reported as unpriced, so interrupts
  don't show up as coverage gaps.
- **Days are local calendar days**; transcript stamps are UTC and get converted.

### Scanning cost

Transcripts are append-only, so after the first pass each refresh parses only the bytes
appended since last time. A file that *shrank* was rewritten by compaction and is re-read
from the top. On a 1.4 GB `~/.claude/projects`, the first scan took ~12.7s and steady-state
rescans ~80ms. Refresh runs every 20 seconds on a background queue.

Memory needs one `autoreleasepool` per *chunk*, inside the read loop — not per file.
`FileHandle.read` returns an autoreleased `Data`, so a pool spanning a whole file retains
every chunk of it; against a single 1 GB transcript that was ~1 GB of peak RSS on its own.
Per-chunk pools took peak from 1.50 GB to 82 MB with no change in speed or output.

### Menu bar colour

`NSImage.isTemplate` is all-or-nothing — a template image is flattened to an alpha mask,
so you can't mix system-adapted text with a coloured accent in one image. And the menu bar
background is your *wallpaper*: macOS picks menu bar contrast from its luminance, which an
app can't reliably read. A hand-picked "dark green for light mode" is illegible the moment
a mid-tone wallpaper sits behind the menu bar.

So each label is either fully template or fully self-coloured, and colour only appears
inside a filled pill, where the background is ours and contrast is guaranteed:

| Style | Behaviour |
|---|---|
| **Adaptive** (default) | Template monochrome below 80%, coloured pill at 80% and above. |
| **Always colour** | Always a pill. |
| **Monochrome** | Never coloured. |

### Verification

The engine was ported from `claude_cost`'s `usage_cost.py` and checked against it over a
30-day window: 22 of 24 active days matched to the cent. The two that didn't were the days
with subagent activity, and the total difference equalled the subagent spend exactly —
the only intended divergence.

## Cutting a release

```bash
./scripts/release.sh        # archive → sign → notarize → staple → verify
```

Produces `build/DoubleShot.dmg`, signed with Developer ID, notarized by Apple, and
stapled. Attach it to a GitHub release. Needs two one-time setup steps, both documented
at the top of the script: a `Developer ID Application` certificate, and a stored
notarization credential (`xcrun notarytool store-credentials`).

Two things the script encodes because they're easy to get wrong:

- **Archive with automatic signing, and re-sign during export.** Passing
  `CODE_SIGN_IDENTITY="Developer ID Application"` to `xcodebuild archive` collides with
  automatic signing and fails outright with *"conflicting provisioning settings"*. The
  Developer ID signature is applied by `-exportArchive` with `method: developer-id`.
- **The app and the DMG are notarized and stapled separately.** Stapling only the DMG
  leaves the app with no local ticket once someone drags it out, so Gatekeeper has to ask
  Apple over the network — which fails offline or behind a restrictive proxy. And the DMG
  needs its own `codesign`: notarizing an unsigned container still gets you
  `spctl: rejected — no usable signature`.

Certificate types are a maze, so for reference — `Developer ID Application` signs the
`.app` for direct download, and it's the only one of the five that matters here.
`Apple Distribution` and `Mac Installer Distribution` are App Store certs, and
`Apple Development` only works on your own machines.

## App icon

The repo ships without one. Generate the icon set from a single square PNG
(1024×1024 recommended):

```bash
./scripts/make-icon.sh ~/Downloads/doubleshot-icon.png
xcodegen generate
```

## Credits

The menu bar keep-awake half of this began as [NoDoz](https://github.com/andrewwatson/NoDoz)
by Andy Watson — a small `MenuBarExtra` app that toggles sleep prevention. DoubleShot's
`KeepAwakeManager` follows the same `IOPMAssertion` approach. The cost half began as
`claude_cost`, and its `usage_cost.py` is the reference this Swift engine was ported from
and validated against.

No code or assets from NoDoz are redistributed here; it carries no license.

## License

MIT — see [LICENSE](LICENSE).
