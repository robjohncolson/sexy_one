# M0 Brief — Miso + GHC WASM toolchain spike

**From:** Fable (planning tier) · **To:** Opus 5 design agent · **Date:** 2026-08-06

## Goal

Prove the project's riskiest assumption: that we can build a Miso application in
Haskell, compile it with the GHC WebAssembly backend, and serve it as pure static
files (GitHub Pages compatible) — reproducibly, on this machine.

Read `PLAN.md` at the repo root first. It defines the project, the pipeline, and the
non-negotiable constraints. M0's definition of done: **a fresh clone builds with one
documented command and produces a working page in a browser** (a trivial Miso app —
a counter or similar — is sufficient; no course features).

## Environment (probed 2026-08-06)

- Linux 6.8, 4 cores, 7.6 GiB RAM (~3.9 available). Check disk space yourself.
- No Haskell tooling at all: ghc/ghcup/cabal/stack/nix all missing.
- Node v24.16.0 + npm available.

Consequences you must design around: prefer prebuilt bindists (ghcup or
ghc-wasm-meta) over anything compiled from source; keep link-time memory modest;
the toolchain install itself must be scripted and documented as part of the build
story, since Sonnet implementers and future fresh clones start from zero.

## Your latitude

Everything not listed in PLAN.md's "Non-negotiable constraints" is yours: GHC
version, ghcup vs ghc-wasm-meta, Miso version and wiring, project layout under
`site/`, build scripts, dev-server story, browser-side JS shim approach. The GHC
WASM + Miso ecosystem has moved fast post-2025 — verify current state with web
research rather than memory before committing to versions.

## Design-only rules

You are the designer, not the implementer. You may probe the machine read-only and
research online. Do not install anything; do not write files outside `briefs/`.

## Deliverables

1. `briefs/M0-plan.md` — your implementation plan: chosen versions, architecture of
   the build, risks you discovered in research, and the fallback you'd recommend if
   the WASM backend proves unworkable on this hardware.
2. `briefs/M0-manifest.json` — machine-readable task manifest for the Sonnet swarm:

```json
{
  "milestone": "M0",
  "tasks": [
    {
      "id": "kebab-case-id",
      "title": "…",
      "prompt": "Fully self-contained instructions for one Sonnet agent that has no other context. Include repo paths, exact versions, and what done looks like.",
      "owned_paths": ["site/…"],
      "depends_on": [],
      "verify_commands": ["…"],
      "acceptance_checks": ["human-readable check the sign-off review will apply"]
    }
  ],
  "milestone_verify_commands": ["commands proving M0's definition of done"]
}
```

Rules: `owned_paths` must be disjoint across tasks (Sonnet agents run in parallel);
tasks with `depends_on` run in later waves; every task needs at least one
verify command a shell can run.

## Sign-off protocol

You will be messaged again after the swarm implements your manifest. You will review
their work against your own acceptance checks, iterate with them if needed (via the
coordinator), and give or withhold sign-off. After your sign-off, Codex runs an
adversarial review; its findings come back through you.
