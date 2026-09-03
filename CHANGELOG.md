# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Fixed
- `hecate-llm.chat` answered `missing_model_or_messages` to every mesh
  caller: `hecate_llm_mesh_rpc:route/2` matched bare binary keys, and
  macula's decoder hands a responder atomized keys and `{text, Bin}`
  values (verified live 2026-09-03 from inside a spartan mind, with
  binary and with atom keys). Every payload is now folded to one shape
  before routing; regression test covers all three wire shapes.
- `hecate-llm.list_available` faulted on the wire ("tuple at payload
  cannot be encoded"): the route wrapped `list/0`'s own `{ok, Models}`
  in a second `{ok, _}`.
- Chat options were read atom-keyed by the providers and passed
  binary-keyed by the route, so `temperature`/`max_tokens`/`tools` from
  a mesh caller were silently ignored.

### Added
- A fallback provider for unary `chat` (`HECATE_LLM_FALLBACK_PROVIDER`,
  `HECATE_LLM_FALLBACK_MODEL`, default `deepseek`/`deepseek-chat`): when
  the model's own provider fails for a reason that is the provider's
  (429, 5xx, timeout, refused connection, stale key, unlisted model), the
  call is made once more against the fallback and the reply carries
  `served_by` and `requested_model`. The switch, and a fallback that is
  named but not keyed, are logged. NVIDIA's free endpoint answered 429 to
  everything for a day (2026-09-02/03) and this gateway, holding only an
  NVIDIA key, failed silently throughout.

### Changed
- `rebar3 lint` (elvis) wired up for the first time in this repo's history
  (`project_plugins`/`{elvis, ...}` in `rebar.config`, the same `macula_min`
  ruleset — `no_deep_nesting` level 2, `no_nested_try_catch`,
  `no_if_expression` — hecate-graph already uses), and the resulting 70
  pre-existing `no_deep_nesting` findings across all 16 flagged modules
  fixed in the same pass, not deferred to a separate cleanup. Every fix is
  a pure extraction of a nested `case`/`try`/inline `fun` into a named
  function (function clauses replacing the nested branch); no behavior
  change. Verified via a clean `warnings_as_errors` compile (catches any
  orphaned/unused extracted helper) and the full `hecate_llm_SUITE` after
  every batch, plus a final `rebar3 lint` run showing zero findings
  repo-wide.

### Fixed
- `hecate-llm.check_health` faulted every real mesh call —
  `macula_peering`/`macula_station_link` logged "tuple at payload.ollama
  cannot be encoded" and returned `unknown_error` to the caller.
  `check_llm_health:check_all/0`'s own contract is `ok | {error, term()}`
  per provider (a fine internal shape — see `llm_provider:health/1`'s
  `-callback`), but `route/2` returned that map verbatim as the RPC
  payload; `{error, Reason}` is a bare 2-tuple, which
  `macula_frame:check_value/2` rejects outright, and ollama (always
  present, per `manage_providers`' own default) is never running in
  this deploy, so every real call hit it. `wire_safe_health/1` now
  normalizes each provider's status to the same `status`/`reason` map
  shape `hecate_om_health_handler` already uses (`ok` stays the bare
  atom `<<"ok">>`). Found live: mesh advertisement and routing both
  worked correctly (six capabilities, correct realm, confirmed via the
  DHT's own `procedure_advertisement` records) — this was the first
  bug in the actual call path, not identity/advertise. New regression
  test (`check_health_wire_safe`, 6 total) asserts no value in the
  response map is ever a tuple; verified RED against the unfixed
  handler (a real, uncaught `is_tuple` failure, not just an
  `undef`/loading artifact) before confirming GREEN.

### Added
- NVIDIA's hosted catalog (build.nvidia.com / `integrate.api.nvidia.com`) as an
  auto-detected provider, same pattern as Groq: OpenAI-compatible, picked up
  from `NVIDIA_API_KEY` via `manage_providers:auto_detect_env_providers/1`.
  Verified live: `GET /v1/models` returns the expected `{"data": [...]}` shape
  against the account's own key, 83 models including several embedding models.
- DeepSeek (OpenAI-compatible) wired the identical way, from
  `DEEPSEEK_API_KEY` — the actual cost-driven default as of 2026-09-02
  (superseding NVIDIA below), for hecate-graph's `narrate_hecate_llm`.
  Same account/key already verified live elsewhere in this workspace
  (`deepseek-v4-pro`).
- Melious (EU-sovereign broker, OpenAI-compatible) wired the identical way,
  from `MELIOUS_API_KEY` — available for a caller that wants it specifically,
  but deliberately NOT provisioned with a key in this fleet's default deploy
  secrets. NVIDIA's free tier is the actual cost-driven default for anything
  routed through this gateway today.
- Initial scaffold extracted from
  `hecate-social/hecate-daemon/apps/serve_llm/` on 2026-05-18 (four-
  tier reshape).
- Implements `hecate_om_service`, advertises 6 capabilities
  via `macula:advertise/5` (`chat`, `stream_chat`, `list_available`,
  `check_health`, `report_status`, `track_usage`).
- `stream_chat_with_llm` migrated to `macula:advertise_stream/4`.

### Changed
- Bumped `hecate_om` `~> 0.10` -> `~> 0.16` -> `~> 0.22` (was locked at
  0.7.0, itself already below the stated constraint — the lock had drifted
  stale under the old constraint too). Pulls in, transitively: `macula`
  6.0.0 -> 10.16.0, and a new hard native dependency, `barrel_docdb`
  (RocksDB C++ build) from hecate_om 0.15.0's optional read-model support
  — unused by hecate-llm today, but present in every build from here on,
  same "everyone pays, only starts if declared" shape as the existing
  reckon_db/evoq wiring. `reckon_db`/`reckon_gater` were already current;
  `evoq`/`reckon_evoq` needed no change. Verified: clean `rebar3 compile`
  (`warnings_as_errors`), dialyzer clean, and all 4 `hecate_llm_SUITE`
  cases green against the new versions.

### Fixed
- `hecate_llm_service:capabilities/0` actually returned `[]`, contradicting
  this very changelog's claim of 6 advertised capabilities (and failing
  `hecate_llm_SUITE:capabilities_count/1`, which asserts 6) — silently,
  since nothing runs this suite in CI. Now returns the 6 capability
  discovery records (no `handler` key — actual serving stays with
  `hecate_llm_mesh_rpc`'s own `macula:advertise/5`/`advertise_stream/4`
  calls, per `hecate_om_service:capabilities/0`'s own doc for services that
  advertise "another mechanism serves").
- The `eaddrinuse` masking the above was NOT a stray local process (that
  diagnosis was wrong) — it's a real, three-layer, always-reproducible bug:
  (1) `hecate_llm_sup`'s own cowboy listener (`http_port`, 8470) already
  folds `hecate_om_health_handler:routes()` into its dispatch table
  alongside `/api/v1/*`, so `hecate_om`'s OWN separate `health_port`
  listener for the identical `/health` route is pure duplication, not a
  second necessary listener; (2) `hecate_om.app.src` bakes in
  `{health_port, 8470}` as the app's own packaged default, which its
  default just happening to equal this app's `http_port` default turns
  into a guaranteed same-port collision the moment both start — simply
  omitting the key from `config/sys.config` does NOT clear an app's own
  compiled-in default, only an explicit `{health_port, undefined}`
  override does; and (3) `rebar3 ct` was never loading
  `config/sys.config` at all — no `{ct_opts, [{sys_config, [...]}]}}` was
  configured, so every override attempted above was invisible to test
  runs regardless of correctness (relx DOES pick sys.config up by
  filename convention for the actual release build, so this specific gap
  never affected a real deployment — but it hid the real fix under two
  wrong diagnoses along the way). Fixed all three.
- Removed `quadlet/hecate-llm.container`. It targeted the beam cluster via
  Podman Quadlet reconciled from `hecate-gitops`, but the beam cluster runs
  docker + watchtower and `hecate-gitops` is archived/unreconciled — the
  file described a deployment path that does not exist. CI already builds
  and pushes `ghcr.io/hecate-services/hecate-llm:latest`/semver tags,
  matching the watchtower model; there's no docker-compose/env-file
  equivalent yet.
- `project_llm_usage.app.src` listed `serve_llm` in `applications` — a
  leftover from the pre-extraction umbrella; no code in the app has ever
  referenced it. Nothing caught this either, for the same reason: it only
  surfaces once `init_per_suite`'s `application:ensure_all_started(hecate_llm)`
  gets past `hecate_om`'s health-port bind, which the local port collision
  above was also hiding. Removed.

### Removed (compared to the prior `serve_llm` umbrella)
- `synthesize_speech`, `transcribe_audio`, `web_fetch`, `web_search`,
  `translate_output`, `run_agent_with_tools` — out of scope for the
  LLM gateway service; will resurface in a future
  `hecate-services/hecate-tools` daemon.
- `*_responder.erl` modules — replaced by `hecate_llm_mesh_rpc`.

### TODO (carried over from the extract; pre-existing)
- Wire `detect_llms`, `report_llm_status` against the new
  `manage_providers` boot order
- API key loading from `/etc/hecate/secrets/hecate-llm/providers.env`
  + secure handling (no logging, no echoing)
- `track_llm_usage` event store wiring (reckon_db namespace, evoq
  dispatcher)
- `report_llm_status` periodic publish to mesh (was topic-based;
  now should be `macula:publish` on `_mesh.cap.hecate-llm.status`)
- Per-call signature: caller identity propagation for billing

## [0.1.0] - YYYY-MM-DD

_Not yet released._
