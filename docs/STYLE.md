# Writing style for Keel

Keel's text has to be trusted by people who know Macs well and understood by people who don't.

## Voice

- Neutral and professional. Write like Apple's support articles or a good man page, not like a product launch.
- Technical terms are fine when they are the real names (pmset, AWDL, DerivedData, LaunchAgent). Explain each one in the same sentence the first time, in plain words.
- Say what happens, not how it feels. "The Dock appears as soon as the pointer reaches the edge" beats "Enjoy a snappier Dock".
- Be specific. Name the setting, the file or key, the app, the number. If a figure was measured, say where and on what.
- Be honest about size. If the effect is small, say it is small. If it is cosmetic, say so. If nobody has measured it, say "not measured".
- Never invent numbers, sources or behaviour. If something is inferred from a binary string rather than observed, say that.

## Banned

Marketing and filler words: seamless, supercharge, unlock (as a verb), boost your, game-changer, leverage, delve, elevate,
effortless, blazing, ultimate, revolutionary, harness, empower, cutting-edge, next-level, turbocharge, unleash, magic,
lightning-fast, a breeze, "in today's", "it's worth noting". No exclamation marks. At most two em dashes in a tweak's text;
prefer full stops. No rhetorical questions. No "simply" or "just" in instructions.

## Fields

| Field | What goes in it | Length |
|---|---|---|
| `name` | The setting, in sentence case. "Click wallpaper to reveal desktop: off" or "Dock appears instantly". | ≤ 48 chars |
| `summary` | One sentence on what changes for the user. Shown on the card. | ≤ 120 chars |
| `explanation` | First sentence: what it does, in plain words, for someone who has never heard of it. Then: how it works (key, file, command), when it helps, caveats, what macOS version it was verified on. | 2–6 sentences |
| `expectedBenefit` | "What you'll notice." Concrete and observable. | 1–2 sentences |
| `tradeoff` | "What you give up." Write "Nothing noticeable." only when that is true. | 1–2 sentences |
| `sources` | Apple documentation, man pages, vendor docs, or "Local check: …" describing what was verified on which macOS build. | ≥ 1 |

## Examples

Good: "Finder stops writing .DS_Store files on network shares. These hidden files store each folder's view settings;
on SMB servers, reading them for every folder slows browsing. Apple documents the key in support article 102064."

Bad: "Supercharge your network browsing with this hidden gem that unlocks blazing-fast Finder performance!"
