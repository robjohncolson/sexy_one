# M0 — Codex adversarial review triage

**From:** Opus 5 design agent · **Date:** 2026-08-06
**Reviewing:** `state/cross-agent/M0-codex-findings.json` (Codex `gpt-5.6-sol`, xhigh, HEAD `2132661`)
**Companion:** `briefs/M0-fixes-manifest.json` (5 tasks, 4 waves)

## Verdict

**I concur with all 17 findings. Zero disputes.** Codex worked read-only; I re-tested every
finding I could reach at runtime and each one reproduced. Two findings (M9, m3) turn out to be
*vacuous-success paths in the very verification layer I signed off on* — `check-site.sh`
reports `17/17 checks passed` on bundles that are provably broken. That is the most important
outcome of this review and it materially revises my sign-off: my negative controls proved the
harness *can* fail, but not that it fails on the specific things it claims to guarantee.

I dispute one **sub-recommendation** (not a finding): B1's "prefer installing into a fresh
sibling staging directory and renaming it into place" is unsafe here, with evidence below.

I also formally withdraw part of my own advisory thread 3 — Codex is right and I was wrong.

| id | sev | concur? | fix task |
|---|---|---|---|
| B1 | blocker | CONCUR (reproduced) | `harden-toolchain-installer` |
| M1 | major | CONCUR | `harden-toolchain-installer` |
| M2 | major | CONCUR | `harden-toolchain-installer` |
| M3 | major | CONCUR | `harden-toolchain-installer` + `ci-workflow-hardening` |
| M4 | major | CONCUR | `browser-check-robustness` + `ci-workflow-hardening` |
| M5 | major | CONCUR (with precision note) | `check-site-invariants` + `docs-corrections` |
| M6 | major | CONCUR | `ci-workflow-hardening` |
| M7 | major | CONCUR | `ci-workflow-hardening` |
| M8 | major | CONCUR | `ci-workflow-hardening` |
| M9 | major | CONCUR (reproduced; worst finding) | `check-site-invariants` |
| m1 | minor | CONCUR (mechanism; scenario implausible) | `check-site-invariants` |
| m2 | minor | CONCUR | `check-site-invariants` + `ci-workflow-hardening` |
| m3 | minor | CONCUR (reproduced) | `browser-check-robustness` |
| m4 | minor | CONCUR (reproduced) | `harden-toolchain-installer` |
| m5 | minor | CONCUR | `docs-corrections` |
| n1 | nit | CONCUR | `check-site-invariants` |
| n2 | nit | CONCUR — my advisory 3 was wrong | `harden-toolchain-installer` |

---

## B1 — prefix override can `rm -rf` arbitrary data · CONCUR (reproduced)

**Reproduced end to end, safely.** I stubbed `git` so the wrapper's clone and pin assertion
succeed but the dropped `setup.sh` is inert, then ran with a populated victim directory:

```
$ GHC_WASM_PREFIX=/tmp/b1-proof/victim ./scripts/install-toolchain.sh     # no --force
install-toolchain.sh: verified HEAD == pinned commit c75985a1…
>>> REACHED upstream setup.sh with PREFIX='/tmp/b1-proof/victim'
>>> upstream line 97 would now execute: rm -rf "/tmp/b1-proof/victim"
```

The guard chain fails exactly as Codex described: `check_installed` returns 1 (no
`$PREFIX/env`), so the "already installed" early-exit does not fire; the `rm -rf` warning is
printed only under `--force`; control reaches `setup.sh`, whose line 97 is verified to be
`rm -rf "$PREFIX"`. No `--force`, no confirmation, no warning. Blocker confirmed.

**Dispute of the staging sub-recommendation.** Codex suggests installing into a staging
directory and renaming into place. That is unsafe for this toolchain: `~/.ghc-wasm/env`
contains **21 hard-coded absolute paths** (`export PATH=/home/…/.ghc-wasm/wasm-run/bin:$PATH`,
`CC=/home/…/wasi-sdk/bin/wasm32-wasi-clang`, …). A rename would leave every one of them
pointing at the staging path. The fix therefore uses the other half of Codex's
recommendation — canonicalize, constrain, and require a validated sentinel — and drops
staging. Rationale is recorded in the task prompt so the implementer does not "improve" it back.

Design: canonicalize with `realpath -m`; hard-refuse empty, `/`, `$HOME`, the repo root, any
ancestor of `$HOME` or the repo, and any path containing `..`; refuse any *existing* directory
that is not already a recognized toolchain install (sentinel = our stamp file, or `env` +
`wasm32-wasi-ghc/`). `--force` means "reinstall over an existing **toolchain**" and never
"wipe arbitrary data" — there is no override for the hard-refuse list. **The guard must run
before the clone**, so the refusal path touches no network.

## M1 — none of ~785 MB of bindists are hash-verified · CONCUR

Confirmed against the pinned commit's own files. All seven components this host uses carry SRI
digests in `autogen.json` (`wasm32-wasi-ghc-9.14`, `wasi-sdk`, `libffi-wasm`, `nodejs`,
`binaryen`, `wasmtime`, `cabal` — sha256 and sha512), and `setup.sh` reads only `.url`,
`curl`s it, and immediately extracts or `configure && make install`s it. This was my advisory
thread 4, which I filed as "residual, documented" — Codex is right that documenting a
skipped integrity check is not the same as accepting a *justified* risk when the digests are
sitting in the file we already pin.

Design: all seven `curl` invocations in the pinned `setup.sh` use `-o <file>` (verified: lines
112, 115, 121, 131, 135, 213, 228), so a **`curl` shim prepended to `PATH` for the `setup.sh`
invocation only** intercepts 100% of downloads without patching upstream source. It resolves
the real curl by absolute path (no recursion), and on success looks the URL up in the pinned
`autogen.json`, converts the `sha256-`/`sha512-` base64 SRI to hex, compares, and **aborts on
mismatch**. Policy is **fail-closed**: any `-o` download whose URL is absent from
`autogen.json` aborts too. npm's own fetches are outside curl and are integrity-checked by
`package-lock.json`.

Because a hash wrapper that breaks the install is worse than none, the fix requires *both* a
fast `--verify-sri-selftest` regression hook *and* one full `--force` reinstall to prove the
shim does not break the real thing.

## M2 — inherited env can bypass the pinned sources · CONCUR

Confirmed in the pinned `setup.sh`: `UPSTREAM_WASI_SDK_PIPELINE_ID` (line 104),
`UPSTREAM_GHC_PIPELINE_ID` / `UPSTREAM_GHC_PROJECT_ID` / `UPSTREAM_GHC_JOB_NAME` (206-211),
`SKIP_GHC` (199), `PLAYWRIGHT` (126), `NIX_SYSTEM` (48). An ambient `UPSTREAM_GHC_*` redirects
the compiler download to a caller-chosen GitLab pipeline artifact — unpinned *and* unhashed —
and `SKIP_GHC=1` wipes the prefix then installs no compiler. My wrapper sets only `FLAVOUR`
and `PREFIX` and inherits everything else, so its "pinned constants" are not actually a closed
input channel.

Design: invoke `setup.sh` through `env -u` for every upstream control variable (enumerated
from the pinned source), and assert `SKIP_GHC`/`PLAYWRIGHT` are empty afterwards. This also
guarantees the only remaining `curl` calls are the seven `-o` downloads the shim covers — the
two GitLab-API `curl`s are reachable only via `UPSTREAM_*`.

## M3 — restore-keys silently defeat pin upgrades · CONCUR

Two independent defects, correctly linked:

1. `check_installed` accepts *any* readable `env` plus *any* `wasm32-wasi-ghc` that prints a
   version. It prints the stamp but never compares it to the pinned commit/flavour, and never
   checks cabal. So a stale toolchain reads as healthy.
2. `actions/cache` sets `cache-hit == 'true'` only on an **exact** key match. After a pin
   change the exact key misses, `restore-keys: ghc-wasm-Linux-` restores the *old* toolchain,
   `cache-hit` is `'false'` so the installer runs — and immediately exits 0 because (1) says
   the old compiler is fine. Worse, at post-job `actions/cache` then saves that stale tree
   **under the new pin's key**, poisoning the cache permanently. `runner.os` is only `Linux`,
   so an image migration restores natively-built binaries across a materially different image.

Design: (a) health becomes a strict stamp match — pinned commit, pinned flavour, and the live
`wasm32-wasi-ghc --numeric-version` equal to the recorded `ghc_version`, plus a working
`wasm32-wasi-cabal`; any mismatch or missing stamp is *unhealthy* and triggers reinstall.
(b) Drop the broad toolchain `restore-keys` entirely (the tree is immutable, not incrementally
reusable), key on `runner.os`-`runner.arch`-`env.ImageOS` plus the installer hash, and run the
installer unconditionally — it is idempotent and now self-heals a stale restore.

## M4 — CDP timeout does not bound connect or commands · CONCUR

Confirmed by reading the client: `send()` stores `{resolve, reject}` in `this.pending` with
**no timer**; the only resolver is `_onMessage`; there is no `close`/`error` listener that
rejects pending calls; `connectWebSocket` resolves on `open` and rejects on `error` but has
**no deadline** (a peer that accepts TCP and never completes the handshake hangs forever); and
the browser child's `exit` is not wired to reject in-flight commands. `--timeout` is consulted
only by the polling loops. `check-site.sh` adds no outer bound and the workflow's *Verify site*
step has no `timeout-minutes`, so a 45-second harness can hang to GitHub's job limit.

Design: a single monotonic deadline; every `await` (connect, each command, each poll) races the
remaining budget; `close`/`error` on the socket and `exit`/`error` on the child reject and
clear all pending calls; plus `timeout-minutes` on the CI verify step as an independent backstop.

## M5 — documented prerequisites omit Node · CONCUR, with a precision note

Confirmed: `check-site.sh` invokes bare `node` (lines 187, 202, 206, 356), references the
toolchain env **zero** times, and `README.md` contains **no** mention of Node at all. A host
satisfying every documented prerequisite therefore cannot run the documented verification
command. `install-toolchain.sh` does install a private Node 26 under `~/.ghc-wasm`, but
`build-site.sh` sources that env only inside its own process, so nothing exports it.

**Precision note (does not change the fix):** Codex's phrasing leaves open that this could be a
silent pass. It is not — `WASM_EXPORTS_OK` stays 0 and the three export checks `fail` loudly,
and the browser step fails too. The defect is that the *documented fresh-clone story is broken
on a minimal host*, not that a broken build would slip through. Severity as filed is right.

Design: `check-site.sh` resolves Node explicitly (`SXC1_NODE` > toolchain private Node >
system `node`), asserts `typeof WebSocket === 'function'` and `WebAssembly` are available, and
fails with an actionable message naming the minimum; README gains Node with a concrete minimum
version and a note that the toolchain ships one.

## M6 — deploy job is not inert while Pages is disabled · CONCUR

The only gate is `github.ref == 'refs/heads/main' && github.event_name != 'pull_request'`.
Nothing encodes Pages enablement, so the first push to `main` after the repo is created runs
`actions/deploy-pages` and fails the workflow. My own plan and README assert the opposite. This
is squarely in the zone the coordinator flagged as owner-dependent (PLAN.md open question 1:
repo name/visibility, and Pages requires a public repo on a free account).

Design chosen to be **safe under either owner outcome**: gate `deploy` additionally on
`vars.ENABLE_PAGES == 'true'`. Repo private / Pages not configured → variable unset → job
skipped → `main` stays green. Owner enables Pages → sets the variable once → deploys begin. No
code change needed when the decision lands, and README documents the one-line enablement step.

## M7 — PR builds receive deployment and OIDC permissions · CONCUR

`pages: write` and `id-token: write` are declared at workflow scope, so the `build` job — which
executes repository-controlled shell scripts on `pull_request` — holds them too. Fork PRs are
downgraded by GitHub, but same-repo PRs and compromised branches or build dependencies are not.
Design: workflow scope drops to `contents: read`; only `deploy` gets `pages: write` +
`id-token: write`; `actions/checkout` gets `persist-credentials: false` (no later step needs
git auth).

## M8 — constant workflow-wide concurrency can discard a main deployment · CONCUR

Matches GitHub's documented behaviour: only one run per group may be pending, and a newly
queued run **replaces and cancels** the existing pending one. With every push, PR and manual
run sharing `group: pages` across the entire expensive build, a pending `main` build can be
evicted by an unrelated PR and never deploy. PR checks are also serialized behind 15-60 minute
installs for no benefit. Design: remove workflow-level concurrency; `build` gets
`group: build-${{ github.workflow }}-${{ github.ref }}` with `cancel-in-progress` true only for
pull requests; `deploy` alone keeps `group: pages`, `cancel-in-progress: false`.

## M9 — the Pages-subpath grep misses ordinary root-absolute syntax · CONCUR (worst finding)

**Reproduced, and it is worse in practice than on paper.** Changing one character class in the
shipped bundle:

```
fetch("./app.wasm")   →   fetch('/app.wasm')          # valid JS, single-quoted
$ ./scripts/check-site.sh --dir /tmp/m9
ok   - index.js has no root-absolute URL
ok   - index.js has no external-origin URL
check-site: 17/17 checks passed          ← full green
```

Yet that same bundle served at a project sub-path is **completely dead**:

```
$ node scripts/browser-check.mjs --url http://127.0.0.1:8231/repo/
browser-check: 0/7 assertions passed          (sabotaged bundle)
$ node scripts/browser-check.mjs --url http://127.0.0.1:8241/repo/
browser-check: 6/6 assertions passed          (real bundle — control)
```

So the central deployability invariant of M0 is enforced by a four-pattern grep over
double-quoted spellings, while the behavioural test runs only at `/` where `/app.wasm`
resolves. This is my design error: I specified a *syntactic* check for what is a *behavioural*
property, and then wrote acceptance checks that asked only whether the grep was present.

Design — the control I should have specified originally: **serve the built bundle under a
non-root prefix and require the browser check to pass there.** That is a property test; it
cannot be evaded by quoting style, template literals, `url(/…)`, `new URL('/…')`, or
protocol-relative `//host`. The broadened grep stays as cheap defence-in-depth (and as a
better error message), explicitly labelled subordinate to the sub-path run. The control above
is the fix's mandatory negative control.

## m1 — port TOCTOU · CONCUR on the mechanism; scenario implausible

The code confirms it: `port_in_use` opens and closes a probe connection, and `wait_for_port`
proves only that *somebody* is listening — never that it is our server. The "unrelated service
happens to expose `#counter-value`, `#btn-increment` and `window.__SXC1_BOOTED`" scenario is
essentially impossible in practice, and I would not fix it on those grounds alone. But the
flakiness half is real and cheap to close, and the fix doubles as a guard for the M9 sub-path
harness. Design: after starting the server, fetch `/index.html` and require it to byte-match
the on-disk file, and confirm the server child is still alive, before launching the browser.

## m2 — skip mode reports a complete 16/16 · CONCUR

Observed during sign-off: `--skip-browser` exits 0 printing `check-site: 16/16 checks passed`,
indistinguishable to any caller recording only status or the final fraction. Design: keep the
local escape hatch, but count the browser check as a skipped member of the total
(`16/17 (1 skipped)`), emit a machine-readable `check-site: result=structural-only` vs
`result=complete`, and have CI assert `result=complete`.

## m3 — missing DOM nodes handled inconsistently; one assertion vacuous · CONCUR (reproduced)

Both halves confirmed. Missing buttons throw out of the assertion block into the outer catch
and report **exit 2 (harness error)** rather than an assertion failure — I observed this during
sign-off and filed it as cosmetic. Codex found the other half, which is not cosmetic:

```js
const e = document.querySelector('#boot-status');
if (!e) return true;                 // ← absence reported as success
```

```
$ # delete #boot-status from the page entirely
$ ./scripts/check-site.sh --dir /tmp/m3t
ok - #boot-status is hidden after boot
check-site: 17/17 checks passed          ← second vacuous-success path
```

The shared boot contract *requires* `#boot-status` — without it a boot failure has nowhere to
render. Design: an `assertElement()` helper reports absence as an ordinary failed assertion
(exit 1), and `#boot-status` must exist **and** be hidden.

## m4 — `--check` fails for irrelevant install prerequisites · CONCUR (reproduced)

```
$ PATH=<no unzip/unzstd> ./scripts/install-toolchain.sh --check
install-toolchain.sh: missing required commands: unzip unzstd
exit=1
```

…against a perfectly healthy install, contradicting the mode's own help text ("Report whether a
working install already exists"). It also makes `--check` unusable as M3's post-cache-restore
validator. Design: split `preflight_install` (build/download prerequisites + 12 GiB) from
`preflight_runtime` (the toolchain's own executables); `--check` runs only the latter plus the
strict stamp match from M3.

## m5 — `file://` operation claimed but unsupported · CONCUR

README: "works unmodified at any GitHub Pages sub-path, at a domain root, or **offline from a
local directory**". Opening `index.html` as `file://` loads an ES module that imports sibling
modules and `fetch`es `app.wasm`; browsers give `file://` an opaque origin and block both.
Design: reword to "offline when served locally" and point at `serve-site.sh`. Documentation
fix only — I am explicitly *not* adding a single-file packaging mode, which would be M0 feature
creep.

## n1 — `SERVER_LOG` leak · CONCUR

Independently found during sign-off (advisory 1); Codex confirms. 16 files accumulated over one
review session. Design: track `SERVER_LOG` in the `cleanup` trap, delete on success, print its
contents on failure (which is more useful than leaving it on disk anyway).

## n2 — obfuscated hostname · CONCUR, and I withdraw my advisory 3

**Codex is right and I was wrong.** I claimed the `gitlab#dot#haskell#dot#org` obfuscation was
"an artifact of dodging my own negative grep". I tested the actual regexes against the
de-obfuscated prose:

```
gitlab-source grep on normal-hostname prose : exit=0   (would have passed)
curl|sh grep on that prose                  : exit=0   (would have passed)
```

Both manifest greps pass with the hostname spelled normally, because neither line contains
`curl`/`wget`/`git clone`/`git -C` or a pipe. Only the *literal command form* would have
tripped the `curl|sh` grep, and rewriting that as prose was sufficient. The hostname
obfuscation was gratuitous, and my advisory overstated the causal link. It stands as written
in the sign-off record; this is the correction.

The deeper point in Codex's recommendation is the one worth acting on: **validating behaviour
by grepping comment text is brittle and invites contortion.** The fix manifest therefore also
anchors that check to non-comment lines (`^[^#]*curl…`), so prose can say whatever is clearest.

---

## Scope discipline

Everything above is a correctness, safety, or accuracy fix to code M0 already ships. Nothing
adds a feature. Two things I explicitly declined:

- **`file://` single-file packaging** (m5) — would be a real feature; the doc is simply wrong
  and gets corrected instead.
- **staging-directory install** (B1 sub-recommendation) — unsafe given 21 absolute paths baked
  into `env`; the validation half of the recommendation is adopted in full.

## Re-review guidance for Codex

The two findings worth re-testing hardest on the fix diff are **M9** and **m3** — both were
vacuous successes inside the verification layer, so the fixes must themselves be shown to fail
on a sabotaged bundle. Each carries a mandatory negative control in the manifest with the exact
sabotage and expected non-zero exit. **B1**'s guard must be shown to refuse *before* any network
access, and **M1**'s SRI verifier must be shown to abort on a corrupted download.
