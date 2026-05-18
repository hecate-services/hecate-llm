# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added
- Initial scaffold extracted from
  `hecate-social/hecate-daemon/apps/serve_llm/` on 2026-05-18 (four-
  tier reshape).
- Implements `hecate_om_service`, advertises 6 capabilities
  via `macula:advertise/5` (`chat`, `stream_chat`, `list_available`,
  `check_health`, `report_status`, `track_usage`).
- `stream_chat_with_llm` migrated to `macula:advertise_stream/4`.

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
