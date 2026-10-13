# Contributing to Keel

Thanks for helping. Keel changes system settings, so the bar for a change is that it is real, reversible and honest.

## Before you start

- Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (how tweaks, the engine and the helper fit together) and
  [docs/STYLE.md](docs/STYLE.md) (how Keel's text is written).
- Run `scripts/test.sh` once to make sure your toolchain builds Keel.

## Adding or changing a tweak

1. **Verify it on a real Mac.** Check the key or command exists on the macOS versions you claim (for example with
   `strings` on the binary that reads it, the man page, or Apple's documentation), and that it has a visible effect.
   Placebos are rejected; see [docs/NOT-INCLUDED.md](docs/NOT-INCLUDED.md).
2. **Make it detectable and reversible.** Detection must be read-only, fast and must never trigger a permission
   prompt. The engine records the original before changing anything; your revert must restore exactly that.
3. **Make it work on every Apple Silicon Mac.** Use `Requirement`s (`.laptop`, `.pmsetCapability`, `.app`, …) and
   values computed from `Machine.profile()`, never values from your own Mac.
4. **Write it plainly.** Fill `summary`, `explanation`, `expectedBenefit`, `tradeoff` and `sources` following STYLE.md.
   Numbers need a source.
5. **Never rename an existing tweak ID.** People have recorded originals under it.
6. Root operations exist only as cases of `PrivOp` in `Sources/KeelShared/PrivOp.swift`, each validated against an
   allow-list. Adding one needs a clear reason and tests in `Keel --validate-ops`.

## Before opening a pull request

```bash
scripts/test.sh            # must pass
scripts/test.sh --live     # recommended if you touched tweaks: applies and restores them on your Mac
```

Describe what you verified and on which macOS version and Mac. If something is inferred rather than observed,
say so in the tweak's text and in the pull request.

## Reporting security problems

Please do not open a public issue for anything involving the privileged helper or privilege escalation. See
[SECURITY.md](SECURITY.md).
