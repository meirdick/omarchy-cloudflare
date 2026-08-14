# Cloudflare widget for Omarchy

A bar icon and a keyboard-driven panel for a Cloudflare account: what is
deployed, what it is using, where every resource lives, and one keypress to the
dashboard pages that mint API tokens.

Built for Omarchy 4 (`shell/plugins`, `manifest.json`, `~/.config/omarchy/plugins/`).

## Install

```bash
omarchy plugin add https://github.com/meirdick/omarchy-cloudflare.git
omarchy plugin enable mdick.cloudflare
omarchy bar move mdick.cloudflare      # optional, to place it
```

Plugins land disabled so you can read the code first. Removal is
`omarchy plugin remove mdick.cloudflare` — the plugin is a plain git checkout
and installs nothing outside its own directory: no hooks, no sudo, no files
elsewhere on the system.

## Requirements

- `wrangler`, logged in (`wrangler login`). Nothing else to configure — the
  plugin finds wrangler's OAuth token itself and never asks for a separate API
  token. It watches both `~/.wrangler/config/default.toml` and
  `$XDG_CONFIG_HOME/.wrangler/config/default.toml` and uses whichever holds the
  token that expires latest, because wrangler does not always write to the same
  one. Override with the `wranglerConfigPath` setting if yours lives elsewhere.
- `curl`, `jq` is not needed, `wl-copy` for the copy actions.

The `account:read` scope that `wrangler login` grants also covers the GraphQL
Analytics API, which is where the usage figures come from.

## What the panel shows

It opens on an overview, not a list of everything. Every resource as one
flat scroll was a data dump; the account only has a handful of things worth
seeing at a glance, and the rest is one keypress away.

**Overview**

| Section | Contents |
|---|---|
| Needs attention | Workers over the error threshold, failed Pages builds, inactive zones — by name, because a count of broken things is not actionable |
| Recent activity | the three most recent deploys |
| Usage | Worker requests and errors (24h), R2 storage, D1 rows read, zone traffic (7d) |
| Resources | one row per type: count plus an aggregate — `Workers 24 · 6.4k req/24h ›` |
| Live sites | a ↗ button on every Worker, Pages project and zone that serves one |
| Create a token | dashboard shortcuts: account, user, R2/S3, AI Gateway, Turnstile |

"Needs attention" is absent when nothing is wrong, so its presence is the signal.

**Drill down** — `l` or Enter on a resource row opens that type's own view, listed
in order of significance: Workers by requests, R2 by size, zones by traffic,
Pages by last deploy. `h` or Escape comes back, and the cursor returns to where
you left it.

**Search** — `/` searches every resource of every type from anywhere, so you
never have to know which category something is in to reach it.

**Visit** — anything that serves a site gets a ↗ button at the right edge, and
`o` does the same from the keyboard. The row itself still opens the Cloudflare
dashboard; the button opens the site. Two destinations, two targets.

The address behind that button is resolved, not guessed. A custom domain wins
over the platform hostname, so a Worker shows `os.example.com` rather than its
`workers.dev` name and a Pages project shows its own domain rather than
`*.pages.dev`. `<name>.<subdomain>.workers.dev` is only offered when the account
confirms that script has the subdomain route enabled — a third of the Workers on
the account this was built against have it switched off, and offering those a
link would hand out a 404. Workers with neither simply have no button.

## Keys

| Key | Action |
|---|---|
| `j` / `k`, arrows | move the cursor |
| `l` / Enter | open a resource type; on a leaf row, open it in the dashboard |
| `o` | open the live site (rows that serve one) |
| `h` / Escape | back out one level, then close the panel |
| `/` | search every resource; Escape leaves search |
| `c` | copy the row's id |
| `u` | copy the live URL if the row has one, otherwise the dashboard link |
| `r` | refresh now |
| `t` | tail a Worker's logs in a floating terminal |
| `D` | deploy (Worker or Pages project with a local checkout) |
| `R` | roll back |
| `P` | purge a zone's cache |
| `Tab` | move to the next bar panel |

`D`, `R` and `P` are uppercase and go through a confirmation dialog. Deploy and
rollback run `wrangler` in a floating terminal rather than in the background, so
you see the output and can stop it.

Mouse: left click toggles the panel, right click refreshes, middle click opens
the Workers dashboard.

**Hover** carries what does not deserve permanent space. Over a usage figure it
shows the exact number and which setting turns that row into a meter; over a
deployment's `7h` it shows the absolute timestamp. The configuration hint used
to be a row of its own, which spent a line of every session explaining a
one-time setting.

## Settings

Edit the widget's entry in `~/.config/omarchy/shell.json`. Omarchy 4.0.0.alpha
parses `manifest.json`'s `schema` but ships no settings UI yet, so this is the
only way in for now.

```jsonc
{ "id": "mdick.cloudflare", "refreshIntervalSec": 60, "r2StorageGb": 500 }
```

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | 60 | resource and deployment poll |
| `analyticsIntervalSec` | 900 | GraphQL usage poll; analytics lag by minutes anyway |
| `projectsRoot` | `~/Projects` | scanned 3 deep for `wrangler.toml/jsonc/json` to map Workers to local directories |
| `deployRows` | 8 | deployments listed |
| `workerRequestsPerDay` | 0 | requests meter denominator |
| `r2StorageGb` | 0 | R2 meter denominator |
| `d1RowsReadPerDay` | 0 | D1 meter denominator |
| `errorRatePercent` | 1 | error rate that puts a warning badge on the bar icon |

**The three allowances default to 0, meaning "not set".** Those rows then show
the real figure with no percentage; hover one to see which setting turns it into
a meter. Set it to your plan's allowance and the row grows a bar. They are not pre-filled with free-tier numbers on purpose:
a paid account well past the free tier rendered as a red four-figure percentage
against a 10 GB limit that was never real. A percentage against a guessed denominator is worse
than no percentage.

## What does not work

**Cache purge is refused.** The wrangler OAuth grant carries `zone:read` and
there is no cache-purge scope in it, so Cloudflare answers `10000 Authentication
error`. The action is still there and says exactly that when it fails; `u` on a
zone row copies the link to the token page where you can mint a token with the
Cache Purge permission. Everything else works on the wrangler login alone.

**Deploy and rollback need a local checkout.** `wrangler deploy` runs inside a
project directory. The plugin scans `projectsRoot` for wrangler configs and maps
the `name` field to its directory; a Worker with no local checkout reports that
instead of failing halfway through.


## Marketplace

Listed via [omarchyplugins.com](https://omarchyplugins.com). Conformance:

- public repo with `manifest.json` at the root
- all eight required manifest fields: `schemaVersion`, `id`, `name`, `version`,
  `author`, `description`, `kinds`, `entryPoints`
- `README.md` and `LICENSE` present
- safe install and removal — a git checkout with no install hooks
- `preview.png` for the listing card
- passes `omarchy plugin validate`

The preview image is rendered from fabricated data, not a real account.

Category: **Developer Tools**. Tags: **Quickshell**, **Bar**, **System**.

## Development notes

Things that cost time here, recorded so they do not cost it twice:

- **Editing a `.js` file does not hot-reload.** Saving under
  `~/.config/omarchy/plugins/` logs `Local plugin changed, reloading` and
  reloads `.qml`, but an imported `.js` module keeps its old contents. Run
  `omarchy-restart-shell` after touching `Api.js` or `Model.js`.
- **QML load failures are silent on screen.** The widget just does not appear.
  `quickshell list --all` then `quickshell log -i <instance> -t 100`.
- **`qmllint` on this system is a stub** — it exits 0 on a deliberate syntax
  error, so it proves nothing. `qmlformat`'s exit code is also ambiguous
  (first-party files return 1 too). The real test is loading it.
- **The debug hatch is `omarchy-shell mdick.cloudflare diagnose`**, which dumps
  credentials state, per-type counts, cursor position and the last error as
  JSON. It is how every bug below was found.
- **curl config booleans are bare words.** `location = false` is rejected as
  "unsupported trailing garbage" and kills the whole request.
- **The Pages list endpoint rejects `per_page`**, unlike every other list
  endpoint. It must be requested bare.
- **Check Nerd Font codepoints before using them.** The first glyph set all
  rendered as `«`. Read the font's cmap rather than trusting a chart.
- **Wrangler's config path is not fixed.** This machine has both
  `~/.wrangler` and `~/.config/.wrangler`, and wrangler switched which one it
  wrote to mid-session. Watch every candidate and prefer the latest expiry;
  hardcoding one path reads as a broken login when it goes stale.
- **`expiration_time` in the wrangler config is a hint, not a gate.**
  `wrangler whoami` only rewrites that file when the API actually rejects the
  token, so refusing to send requests until the timestamp looks fresh leaves the
  widget frozen on stale data forever. Requests go out regardless and a real
  rejection triggers the refresh.

## Credentials

The token is written to curl's stdin as a config file (`curl -K -`), never into
argv. `/proc/<pid>/cmdline` is world-readable; a `-H "Authorization: Bearer …"`
argument would expose the token to every process on the machine. Verified: a
live request's argv is `curl -K -` and its environ holds no token.

Request bodies are not secret and do travel in argv, which avoids escaping JSON
into curl's config quoting rules.

## Layout

```
manifest.json        id, kind, entry point, settings schema
Panel.qml            bar icon, panel, cursor, row components
Service.qml          credentials, fetch pipeline, timers, actions
Api.js               URLs, curl config, GraphQL query, dashboard links
Model.js             row shaping and formatting
CloudflareIcon.qml   the mark, drawn from primitives
```

`qs.Ui` and `qs.Commons` are imported directly — `qs` is an engine-global import
path, so a third-party plugin resolves them exactly as a first-party one does.
Nothing is vendored.
