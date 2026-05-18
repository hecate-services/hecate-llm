# hecate-llm

**LLM serving over the mesh** for the Hecate realm.

Realm-bound service that gateways calls to Anthropic, OpenAI,
Google, and locally-hosted Ollama models. Other services and
plugins reach it via Macula RPC — they don't carry API keys, they
don't open outbound HTTPS, they just ask the local station for
`hecate-llm.chat` and the realm takes care of the rest.

## Why this exists

Extracted from `hecate-social/hecate-daemon`'s `serve_llm` umbrella
on 2026-05-18 as part of the four-tier reshape. The old location
mixed an always-on inference gateway (multi-tenant, holds API keys
+ Ollama state) with per-user chat UI plugins. Wrong layer.

Now:

```
Layer 4 — apps        (Martha, Scribe — call hecate-llm.* via mesh)
Layer 3 — session     hecate-daemon
Layer 2 — services    ▶ hecate-llm ◀ (this repo)
                       hecate-rag, hecate-dns, hecate-git, …
Layer 1 — identity    hecate-realm
Layer 0 — kernel      macula-station
```

Substrate: [`hecate-om`](https://codeberg.org/hecate-services/hecate-om).

## Capabilities

| Capability | Shape | Purpose |
|------------|-------|---------|
| `hecate-llm.chat` | unary RPC | single-turn completion |
| `hecate-llm.stream_chat` | server-stream RPC | token-streaming completion |
| `hecate-llm.list_available` | unary RPC | enumerate detected models |
| `hecate-llm.check_health` | unary RPC | provider liveness probe |
| `hecate-llm.report_status` | unary RPC | composite status snapshot |
| `hecate-llm.track_usage` | unary RPC | record a billed call into the usage aggregate |

## Umbrella

| App | Department | Role |
|-----|-----------|------|
| `llm` | shared | provider modules (anthropic / openai / google / ollama) + `llm_provider` behavior + `hecate_llm_http` |
| `chat_to_llm` | CMD | single-turn completion handler |
| `stream_chat_with_llm` | CMD | server-stream completion handler |
| `manage_providers` | CMD | provider registry (gen_server) |
| `detect_llms` | CMD | polls providers, emits `llm_detected_v1` / `llm_removed_v1` |
| `check_llm_health` | CMD | provider liveness probe |
| `get_available_llms_page` | QRY | list detected models |
| `report_llm_status` | CMD | composite status (gen_server, periodic) |
| `track_llm_usage` | CMD | event-sourced usage aggregate (`llm_call_tracked_v1`) |
| `project_llm_usage` | PRJ | projections: `llm_detected_v1_to_llms`, `llm_removed_v1_to_llms`, `llm_call_tracked_v1_to_llm_calls` |

## Providers

Four supported, all sharing the `llm_provider` behavior:

- `anthropic_provider` (Claude)
- `openai_provider` (GPT-*)
- `google_provider` (Gemini)
- `ollama_provider` (local models)

API keys live in `/etc/hecate/secrets/hecate-llm/providers.env`
mounted by the Quadlet, never in the realm-cert directory.

## Deps

- [`hecate-om`](https://codeberg.org/hecate-services/hecate-om) — service substrate
- `hackney` + `jsx` — outbound HTTPS to provider APIs
- `cowboy` — local HTTP (`/health` + `/api/v1/*` admin)
- `reckon_db` + `evoq` + `reckon_evoq` — event-sourced usage aggregate

## Status

**Scaffold extracted from the prior `serve_llm` umbrella.** The
business logic in each slice (chat_to_llm, detect_llms, providers,
…) is preserved verbatim. What changed:

- Drops `*_responder.erl` modules (they used hecate-daemon's
  `hecate_mesh_client` topic-subscribe pattern). The new
  `hecate_llm_mesh_rpc.erl` advertises every capability via
  `macula:advertise/5` instead.
- `stream_chat_with_llm` rewires its boot from
  `hecate_mesh_client:register_stream_advertisement` to
  `macula:advertise_stream/4`. The procedure name is now
  `hecate-llm.stream_chat` (was `app_hope/3`-derived).
- Per-slice `.app.src` / `_app.erl` / `_sup.erl` shells added
  (previously the whole umbrella shared one).

Remaining big TODOs surfaced in CHANGELOG.

## License

Apache-2.0.
