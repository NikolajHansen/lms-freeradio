# lms-freeradio

FreeRadio is a Lyrion Music Server (LMS) plugin that provides a free internet radio directory from:

- Icecast (`dir.xiph.org`)
- SHOUTcast (`api.shoutcast.com`)

## Features (v1)

- Raw provider indexing (no dedupe/curation)
- SQLite station store (`cachedir/freeradio.db`)
- Search by text (`name`, `description`, `country`, `genre`, `network`, `channel`, stream metadata)
- Browse by Genre/Country/Source
- Favorites stored locally
- Async initial sync + periodic refresh
- In-memory LRU+TTL cache for repeated browse/search queries

## Install from ZIP

1. Create a plugin zip with `install.xml` at archive root:

```bash
./scripts/package.sh
```

2. In LMS web UI: **Settings → Plugins → Additional Repositories**
3. Add your hosted `extensions.xml` URL
4. Apply and install **FreeRadio**
5. Configure SHOUTcast API key in:
   `Settings → Plugins → FreeRadio`

## Repository URL flow

- `extensions.xml` is included in this repository as a template.
- Replace `<url>` with your hosted plugin zip URL.
- Host both `extensions.xml` and the zip file over HTTPS.

## Runtime behavior

- Plugin starts sync asynchronously and keeps serving cached SQLite data when a provider fails.
- Refresh interval is configurable (min 30 minutes, default 180).
- SHOUTcast requires API key; if missing, Icecast data still works.

## Layout

- `install.xml` – LMS extension metadata
- `Plugins/FreeRadio/Plugin.pm` – plugin entry, menus, refresh orchestration
- `Plugins/FreeRadio/Settings.pm` – settings page
- `Plugins/FreeRadio/Store.pm` – SQLite schema/persistence
- `Plugins/FreeRadio/Index.pm` – normalization/indexing
- `Plugins/FreeRadio/Search.pm` – query/filter + cache integration
- `Plugins/FreeRadio/Cache.pm` – LRU+TTL cache
- `Plugins/FreeRadio/Provider/*` – provider modules
- `extensions.xml` – Additional Repositories feed entry
