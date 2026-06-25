# xAI-assisted station classification (idea)

## Goal
Improve noisy/chaotic station metadata (especially genre) without making sync slow, expensive, or unstable.

## Proposed approach: hybrid local + xAI
1. Run deterministic local normalization first:
   - token split/cleanup
   - alias mapping
   - stopword/noise filtering
   - bitrate quality bucketing
2. Send only unresolved/ambiguous stations to xAI for categorization.
3. Store xAI output in a persistent cache and reuse it across rescans.

## Cache strategy
- Compute a stable fingerprint per station:
  - `sha1(name|genre|description|country|codec|bitrate|stream_url)`
- Cache key = fingerprint.
- Only call xAI if key is missing (new station) or changed (metadata changed).
- Keep cached classification otherwise.

## Suggested xAI output schema
Use strict JSON output and reject invalid responses:

```json
{
  "genre": "string",
  "country": "string",
  "mood": "string",
  "confidence": 0.0
}
```

Rules:
- Require valid JSON only.
- Apply a confidence threshold.
- Low-confidence results go to `Unsorted` (no destructive overwrite).

## Throughput policy by size
- `<= 5k` stations: classify all once, then incremental updates only.
- `5k–20k`: classify ambiguous stations only.
- `> 20k`: strict fallback-only mode + daily API cap.

## Why this is preferable
- Deterministic baseline stays local.
- xAI cost/latency is bounded.
- Results are stable across scanner runs.
- Classification quality improves where rules are weakest.

