# M0 — Codex gate round 2 triage

**From:** Opus 5 design agent · **Date:** 2026-08-06
**Reviewing:** `briefs/M0-codex-gate2.json` (Codex `gpt-5.6-sol`, xhigh) — GATE-BLOCKED
**Companion:** `briefs/M0-fixes2-manifest.json` (3 tasks, 1 wave)

## Verdict

**I concur with all five items. Zero disputes.** Every one reproduced. Two are *stronger* than
filed, and one of those is my own round-2 advisory, which I under-called.

| id | sev | concur? | evidence | fix task |
|---|---|---|---|---|
| B1 residual | blocker | CONCUR — reproduced, broader than filed | 3/3 marker variants reach `rm -rf` | `installer-sentinel-and-sri-stamp` |
| M1 residual | major | CONCUR — reproduced | pre-fix stamp accepted as healthy | `installer-sentinel-and-sri-stamp` |
| M3 residual | major | CONCUR — confirmed against GitHub docs | `env` context excludes runner vars | `ci-runner-image-cache-key` |
| NEW1 | minor | CONCUR — reproduced, 2.9 MB leak | SIGINT at 1.2s leaks the bundle copy | `harness-cleanup-and-diagnostics` |
| NEW2 | nit | CONCUR | `[object ErrorEvent]` observed | `harness-cleanup-and-diagnostics` |

My round-2 sign-off said the M0 gate was closed from my side. On these three points it was not,
and the pattern is worth naming: **all three residuals are cases where I verified the scenario I
had specified rather than the property I had claimed.** I tested B1 against unsafe *paths* and
never against a forged *marker*; I tested that the SRI shim verifies downloads and never that a
skipped install can't inherit unverified ones; I flagged `ImageOS` as a future risk without
checking whether it resolved today. Codex's residuals are precisely the gap between "the test I
wrote passes" and "the property holds."

---

## B1 residual — CONCUR, and it is broader than filed

Reproduced with the stubbed-`git` harness (nothing destroyed — the stub guarantees the real
`setup.sh` can never land, so the assertion is "did control reach the destructive sink"):

```
populated dir + EMPTY .sxc1-toolchain-stamp, no --force
  -> SETUP_REACHED_PREFIX=/tmp/.../victim -- WOULD rm -rf IT
populated dir + MALFORMED (non key=value) stamp
  -> reached rm -rf sink
populated dir + fake `env` file + empty `wasm32-wasi-ghc/`   [second recognition path]
  -> reached rm -rf sink
```

Codex demonstrated the stamp path; **the `env` + `wasm32-wasi-ghc/` recognition path is equally
forgeable and I confirmed it too**. Creating a zero-byte file named `.sxc1-toolchain-stamp`, or
an empty directory named `wasm32-wasi-ghc` next to an empty `env` file, is enough to promote an
arbitrary populated directory to "recognized toolchain" and get it recursively deleted with no
`--force`.

The control flow is exactly as Codex traced it. `validate_prefix` promotes on marker *name*;
then at line 536:

```sh
if [ "$FORCE" != "1" ] && health_check 1; then
  echo "toolchain already installed and healthy (use --force to reinstall)"; exit 0
fi
```

`health_check` rejects the forged marker, the `&&` is false, and control **falls through to the
destructive install**. The guard and the sink disagree about what counts as ours, and the
fall-through resolves that disagreement in favour of deleting.

My round-1 design is at fault: I specified the sentinel as "contains `.sxc1-toolchain-stamp`, OR
contains both an `env` file and a `wasm32-wasi-ghc/` directory" — a *name* check. Codex's
original recommendation said **validated** sentinel plus **explicit** replacement, and I
implemented neither half.

**Fix design — three classes, and a second gate at the sink:**

- **Class A, validated toolchain** — `.sxc1-toolchain-stamp` exists, parses as `key=value`, and
  carries a well-formed `ghc_wasm_meta_commit=<40 hex>` and a non-empty `flavour=`. Proceed.
  (Deliberately *not* required to match the current pin: a differently-pinned install is still
  ours, and pin upgrades must keep working.)
- **Class B, plausible but unvalidated** — `env` + `wasm32-wasi-ghc/` present but no valid
  stamp (e.g. an install interrupted before the stamp was written). Refuse **unless `--force`**,
  which prints exactly what will be deleted. This is the "explicit replacement" half.
- **Class C, everything else non-empty** — refuse always, no `--force` override. A forged
  marker now lands here instead of being promoted to Class A.

Plus, because the fall-through is the actual sink: **re-assert the classification immediately
before invoking `setup.sh`**, so no future control-flow edit can reach `rm -rf` unvalidated.
Defence in depth, and it makes the guarantee local to the dangerous line rather than an
invariant maintained 150 lines away.

## M1 residual — CONCUR, reproduced

```
$ grep -v '^sri_verified_downloads=' stamp > stamp      # simulate a pre-fix install, same pin
$ ./scripts/install-toolchain.sh --check
  rc=0   -> accepted as healthy
```

So an install produced by the *pre-fix* wrapper at the same pinned commit satisfies
`health_check`, the fixed installer no-ops, and bindists that were never SRI-verified are
retained indefinitely. The upgrade path — the one that matters for anyone who ran M0 before the
fix — silently keeps the unverified toolchain. Confirmed exactly as filed.

**Fix design:** `health_check` additionally requires `sri_verified_downloads` to parse as an
integer `>= EXPECTED_SRI_DOWNLOADS` (7 for the pinned `setup.sh`: wasi-sdk, libffi, Node,
binaryen, wasmtime, GHC, cabal). A pre-fix stamp lacks the key entirely → unhealthy → reinstall.

Codex offered "the expected SRI count **or** a stamp schema version". I chose the count
deliberately: the currently-installed toolchain already records `sri_verified_downloads=7`, so
it stays healthy and no one pays a 17-minute reinstall for a metadata-only change — whereas
introducing a schema key would immediately invalidate a toolchain that is genuinely fine. For
this change the count *is* the discriminator. A future stamp-format change that isn't
self-discriminating should add the schema key then.

## M3 residual — CONCUR, confirmed against GitHub's own documentation

This is my round-2 advisory 2, and I under-called it. I wrote that the key "degrades silently to
empty **if** a future runner image doesn't set it". It is empty **now**. GitHub's contexts
reference is unambiguous:

> "The `env` context contains variables that have been set in a workflow, job, or step. It does
> not contain variables inherited by the runner process."

`ImageOS` is a runner-process variable, never declared in this workflow's `env:` nor written to
`$GITHUB_ENV`, so `${{ env.ImageOS }}` resolves to the empty string and the key is effectively
`ghc-wasm-Linux-X64--<hash>`. The workflow comment at lines 46-48 claims the key "covers OS,
arch, the runner image and the installer script" — it does not cover the image at all. A
same-OS `ubuntu-latest` image migration can still restore a native tree built against different
system libraries.

**Fix design:** stop using the `env` context for this. Add a step that composes the identity
from the runner's *process* environment and publishes it as a step output:

```yaml
- id: runner-image
  run: echo "id=${ImageOS:-unknown}-${ImageVersion:-unknown}" >> "$GITHUB_OUTPUT"
```

then key on `${{ steps.runner-image.outputs.id }}`. This actually establishes image identity,
which was the point, and it degrades to a visible literal `unknown-unknown` rather than an
invisible empty segment. Correct the misleading comment and cite the docs line so the next
person doesn't reintroduce it.

## NEW1 — CONCUR, reproduced (2.9 MB, larger than the n1 leak it followed)

`cleanup()` tracks `SERVER_PIDS` and `SERVER_LOGS` only. `SUBPATH_TMP` is created at line 599
and removed **only** at line 604, on the happy path.

```
$ ./scripts/check-site.sh & sleep 1.2; kill -INT $!
  subpath temp dirs before=0 after=1
  CONFIRMED leak: 2.9M /tmp/sxc1-check-site-subpath.SY4gvN
```

My first attempt interrupted at 6s and saw nothing — the whole run takes ~2s, so the signal
arrived after the explicit `rm`. Timing the interrupt into the run reproduces it immediately.
Introduced by the M9 fix, and it leaks a full bundle copy rather than a log file.

**Fix design:** a `TEMP_DIRS` array registered in `cleanup` alongside the logs; register
`SUBPATH_TMP` on the line after `mktemp -d`; keep the happy-path `rm -rf` but unregister there
so cleanup can't double-remove a reused path.

## NEW2 — CONCUR

Observed during round-2 sign-off: killing Chrome mid-run yields
`error: Error: CDP WebSocket error: [object ErrorEvent]`. Settlement is correct (M4 stands);
only the diagnostic is lost. **Fix:** prefer `ev.error?.stack`, then `ev.error?.message`, then
`ev.message`, then `String(ev)`.

---

## Advisory notes accepted without a fix task

Codex's advisory 4 (no local assertion that the pinned `setup.sh` has no non-`-o` artifact
downloads) is marked VERIFIED-SAFE-FOR-THE-PIN and I agree — it is brittle only across a future
pin bump, and the pin is the thing that makes it safe today. Adding a parser for upstream's
shell source is disproportionate for M0. **Recorded as an M0-plan risk note for whoever bumps
the pin, not fixed here.** Advisory 5 (Pages artifact uploaded on PR builds) is confirmed
harmless and is hygiene, not a gate defect; leaving it.

## Scope discipline

Three tasks, one wave, three files plus one shared harness fix. No new features, no
restructuring, no reinstall required by design. Every fix carries a sabotage-proven negative
control, and for B1 the control is **exactly** Codex's scenario — populated directory plus a
forged marker must be refused without `--force`, with the victim data still present afterwards —
plus the two variants I found, plus a false-refusal control proving a legitimate toolchain is
still reinstallable.
