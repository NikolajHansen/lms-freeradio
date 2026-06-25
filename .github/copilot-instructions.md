# Copilot instructions for `lms-freeradio`

## Build, test, and lint commands

- **Build/package plugin ZIP:** `bash scripts/package.sh`
  - Produces `lms-freeradio-<version>.zip` from `<version>` in `install.xml`.
  - ZIP layout must contain `Plugins/FreeRadio/...` at archive root.
- **Release build path (CI):** tag push `v*` triggers `.github/workflows/release.yml`, which:
  - renders `install.xml` and `extensions.xml` from templates,
  - computes ZIP SHA1,
  - updates metadata files.
- **Tests/lint:** no automated test suite or linter is configured in this repository.
- **Single-test command:** not available (no per-test harness exists).

## High-level architecture

- **Plugin entrypoint and UI flow** (`Plugins/FreeRadio/Plugin.pm`):
  - Initializes store/cache/index/search and provider instances.
  - Registers menu feed under LMS radios, search/browse/favorites handlers, and CLI sync command (`freeradio sync`).
  - Triggers startup sync asynchronously via timer.
- **Sync pipeline** (cross-file flow):
  - Providers fetch raw station payloads asynchronously (`Provider/Icecast.pm`, `Provider/Shoutcast.pm`, shared HTTP helpers in `Provider/Base.pm`).
  - `Index.pm` normalizes each station into canonical fields and computes stable `uid` (`sha1_hex` over provider+station identity fields).
  - `Store.pm` replaces one provider’s station set transactionally in SQLite (`cachedir/freeradio.db`) and tracks sync state.
  - `Search.pm` serves query + facet reads over `Store.pm` with an in-memory LRU+TTL cache from `Cache.pm`.
- **Scanner integration** (`Importer.pm` + `Plugin.pm`):
  - Registers `freeradio` scan type (`rescan freeradio`) and a post-importer hook.
  - Importer triggers the same plugin sync path so LMS scanner runs and plugin refresh stay aligned.
- **Distribution metadata model**:
  - `install.xml` is LMS extension metadata consumed inside the plugin ZIP.
  - `extensions.xml` is the Additional Repositories feed entry with release URL + SHA.
  - `*.template` files are source of truth for release-time version/SHA substitution.

## Key conventions in this codebase

- **Callback-first async style:** provider fetch methods always accept success/error callbacks (`$cb`, `$eb`) and never throw across async boundaries.
- **Provider contract:** provider modules return arrays of station hashes using canonical keys expected by `Index.pm` (`name`, `stream_url`, `source_id`, `country`, `genre`, `codec`, `bitrate`, `homepage`, `network`, `channel`, `description`).
- **Failure handling policy:** provider failures are logged and recorded (`sync_state`) but do not abort overall sync; remaining providers continue.
- **Persistence boundaries:** only `Store.pm` talks to SQLite directly; other modules go through store/search abstractions.
- **Localization pattern:** all user-facing labels go through `strings.txt` keys and `cstring(...)` lookups in UI handlers.
- **Settings binding:** plugin settings are persisted under `preferences('plugin.freeradio')`; current user-configurable key is `shoutcast_api_key` (`Settings.pm` + `HTML/.../settings/basic.html`).
- **Release metadata discipline:** when version changes, `install.xml`, `extensions.xml`, and packaged ZIP filename/version must stay in sync (CI expects this).
