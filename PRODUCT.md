# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

(Recorded as `web` because no value fits a desktop app better. BoxWallet is a desktop application: a Zig TUI plus an optional Slint GUI on Linux, Windows and Apple-Silicon macOS. No iOS/Android guidance applies.)

## Stack

Existing codebase: Zig 0.17, ZigZag (TUI), Slint (`gui/app.slint`, driven over the C ABI in `src/capi.zig`). No web frontend.

## Users

Self-hosters who are not developers. They want to run their own coin nodes and keep their own keys without terminal work, often on low-spec machines (single-board computers, old hardware, low-RAM VPSes). Many already run a node or another wallet app against the same data directory.

## Product Purpose

Install, start, stop, monitor and manage the wallets of many coins from one app, with the daemons running locally. Success is a user who gets a synced node and a wallet they control, without losing funds or breaking an existing node.

## Positioning

Multi-coin self-custody over real local nodes: no browser, no cloud, nobody else holding the funds. It shares each daemon's standard data directory, so an existing node and wallet are picked up rather than re-synced.

## Operating Context

Runs on the user's own machine. Daemons and wallet RPC bind to 127.0.0.1 only. Two front-ends over one core: the TUI and the Slint GUI.

## Capabilities and Constraints

- Security is first-class: secrets live in bounded buffers and are wiped, never logged, never on a command line. New credentials are confirmed twice. Wallets are never created or unlocked silently.
- Data already on disk belongs to another app: share it, never rewrite or discard it. Destructive changes (such as pruning) are confirmed with their real consequence.
- Memory is first-class: stream, don't buffer.
- Cross-platform: Linux, Windows, macOS.
- Failures surface the real reason, not a generic "failed".
- Front-ends hold presentation only; shared logic lives in shared modules.

## Brand Commitments

- Dark UI with the BoxWallet brand green.
- Each coin keeps its own logo and two-tone wordmark.
- Plain, honest tone: copy states real consequences about funds and shared data, with no hype.

## Evidence on Hand

Coin logos in `gui/coin-logos/`, icons in `gui/icons/`, fonts in `gui/fonts/`. No testimonials, user counts or benchmarks exist; do not invent them.

## Product Principles

1. Never put the user's funds or an existing node at risk for convenience.
2. Show the true state and the real reason; never a vague failure.
3. One core, two front-ends: neither re-implements the other.
4. Stay light: bounded memory, small footprint, works on weak hardware.
5. Plain language for non-developers, with consequences stated before irreversible actions.

## Accessibility & Inclusion

No product-specific standard established.
