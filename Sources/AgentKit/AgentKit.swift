import ShipModel

// AgentKit: the agent engine (ARCHITECTURE §5–§6, §13).
//
// - Signals/      `AgentSignal` (tiered observations)
// - Reducer/      `AgentReducer` (pure state machine) + `SessionStore` (key resolution, merges)
// - Adapters/     Claude, Codex, OpenCode, Gemini (native) + manifest adapters for the long tail
// - Transcripts/  JSONL tailing, OpenCode SQLite (read-only), ingestion actor
// - Installers/   hook/plugin installers with backups and exact uninstall
// - Usage/        price table for cost estimates
// - Engine/       `AgentEngine` (implements `AgentEngineProtocol`), process scanner, summarizer
