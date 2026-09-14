# FanBlast

A menu bar fan switch for Intel Macs (built for a MacBookAir7,2, SMC 2.27f2).
Two modes, one click: **Automatic** (macOS decides) and **Jet Mode**.

> **Requires** the `com.kirtan.friday.fan-helper` root daemon to be installed and
> running — FanBlast is only the UI and holds no privileges of its own. See
> [It needs no password](#it-needs-no-password) for the socket protocol it speaks.

    ./build.sh && cp -R dist/FanBlast.app /Applications/ && open /Applications/FanBlast.app

The menu bar shows the icon alone — outline for Automatic, filled and accent-tinted
for Jet Mode, so the state reads at a glance. Open the menu for live RPM and CPU
temperature, the two modes as buttons side by side, and an "Open at Login" toggle.

## It needs no password

FanBlast never touches the SMC's write path itself. All writes go to the root
daemon that was already installed on this machine — `com.kirtan.friday.fan-helper`,
built from `../Friday` — over its Unix socket:

    /var/run/com.kirtan.friday.fan.sock     (root:admin, so any admin user can talk to it)

    PING              -> OK pong
    STATUS            -> OK actual=6500 floor=1200 stock=1200 max=6500 mode=auto
    MODE auto|max     -> OK mode=max via=minimum

So there is no second privileged helper, nothing setuid, and no install-time
`sudo`. The only privileged code on the machine is the one that was already
there. FanBlast reads RPM and temperature straight from the SMC (`src/smcread.c`) —
SMC *reads* need no privileges, only writes do.

## What "Jet Mode" actually does

It raises the fan's **minimum** (`F0Mn`), leaving the SMC's own thermal curve in
charge. It never writes the manual-override bitmask (`FS!`). Effective fan speed
is `max(minimum, target)`, so a raised floor wins over anything else asking for
less, and the SMC stays free to spin *faster* if the machine gets hot.

**Jet Mode reads 6400 RPM, not 6500.** That is a hardware clamp, not a bug:
the helper writes 6500 and the SMC stores 6400 — this SMC will not let the fan's
minimum equal its maximum. Verified directly:

    write F0Mn=6500 (0x6590)  ->  read back F0Mn=6400 (0x6400),  F0Mx=6500

6400/6500 is 98.5% — inaudible and thermally irrelevant. Reaching a literal 6500
means the override path (`FS!` + `F0Tg`), which is deliberately *not* used here:
Macs Fan Control and FanPilot rewrite those two keys every second, so an override
set by us would be gone within two. The floor mechanism is the one that survives
on this machine, and it can only ever make the fan spin faster.

## Two things that will confuse you

**1. The icon is hidden.** Hidden Bar collapses menu bar icons, and FanBlast
lands in the collapsed section (at x=-4188, next to Macs Fan Control at -4082 and
TypeWhisper at -4116). Click the Hidden Bar chevron to reveal it, or ⌘-drag it
right of the separator to keep it always visible.

**2. Automatic may not slow the fan.** Three fan controllers run on this Mac:

| Process | Mechanism |
|---|---|
| `friday-fan-helper` | `F0Mn` floor — what FanBlast drives |
| `Macs Fan Control` (preset `Predefined:1`) | `FS!` + `F0Tg` override |
| `FanPilotDaemon` | unknown |

While `FS!` is non-zero, something else is pinning the target and macOS never
gets the fan back — Automatic will look like it does nothing. FanBlast detects
this (`FS! != 0`) and says so in the menu. Jet Mode is unaffected. Quit Macs
Fan Control to let Automatic work.

## Also worth knowing

The helper reverts to Auto after **15 minutes with no client contact** — a safety
watchdog so a crashed app can't leave the fan pinned forever. FanBlast polls
`STATUS` every 3 seconds, so Jet Mode holds as long as it is running. Quit it
while in Jet Mode and the fan returns to Auto within 15 minutes. `F0Mn` also
resets on reboot.

## Layout

    src/smcread.c   read-only SMC access (RPM, temperature, FS!) — no privileges
    src/bridge.h    C -> Swift bridging header
    src/main.swift  NSStatusItem menu bar app + socket client
    build.sh        clang + swiftc -> dist/FanBlast.app (ad-hoc signed, LSUIElement)
