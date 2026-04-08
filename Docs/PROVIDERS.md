# Supported LLM Providers

KrillClaw supports **20+ LLM providers** through three protocol backends:

- **Anthropic Claude** — native support via `/v1/messages`
- **OpenAI** — native support via `/v1/chat/completions`
- **Ollama** — native support via `/api/chat` (local models)
- **17+ additional providers** — via OpenAI-compatible API using `--base-url`

## Usage

```bash
# Claude (default)
krillclaw --provider claude --model claude-sonnet-4-5-20250929 "hello"

# OpenAI
krillclaw --provider openai --model gpt-4o "hello"

# Ollama (local, free)
ollama serve  # in another terminal
krillclaw --provider ollama --model llama3.2 "hello"

# Any OpenAI-compatible provider via --base-url
KRILLCLAW_API_KEY=gsk_... krillclaw --provider openai \
  --base-url https://api.groq.com/openai \
  --model llama-3.3-70b-versatile "hello"
```

## Provider Reference

### Tier 1: Full Tool Calling + Streaming

These providers support the OpenAI chat completions format including tool/function calling, which is required for KrillClaw's agent loop.

| Provider | Base URL | Tool Calling | Models |
|----------|----------|:------------:|--------|
| **Anthropic Claude** | `https://api.anthropic.com` | Yes (native) | claude-sonnet-4-5-20250929, claude-3-5-haiku |
| **OpenAI** | `https://api.openai.com` | Yes (native) | gpt-4o, gpt-4-turbo, gpt-3.5-turbo |
| **Ollama** | `http://localhost:11434` | Yes (model-dependent) | llama3.2, codellama, mistral, qwen2.5 |
| **Groq** | `https://api.groq.com/openai` | Yes | llama-3.3-70b, mixtral-8x7b, gemma2-9b |
| **Together AI** | `https://api.together.xyz` | Yes | llama-3.1-405b, qwen-2.5-72b, deepseek-v3 |
| **Fireworks AI** | `https://api.fireworks.ai/inference` | Yes | llama-3.1-70b, mixtral, firefunction-v2 |
| **DeepSeek** | `https://api.deepseek.com` | Yes | deepseek-chat (V3), deepseek-reasoner (R1) |
| **Mistral AI** | `https://api.mistral.ai` | Yes | mistral-large, codestral, mistral-small |
| **NVIDIA NIM** | `https://integrate.api.nvidia.com` | Yes | llama-3.1-70b, nemotron, mixtral |
| **Cerebras** | `https://api.cerebras.ai` | Yes | llama-3.3-70b, llama-3.1-8b |
| **Google Gemini** | `https://generativelanguage.googleapis.com/v1beta/openai` | Yes | gemini-2.0-flash, gemini-1.5-pro |
| **xAI (Grok)** | `https://api.x.ai` | Yes | grok-2, grok-2-mini |
| **SambaNova** | `https://api.sambanova.ai` | Yes | llama-3.3-70b, llama-3.1-405b |
| **Azure OpenAI** | `https://{name}.openai.azure.com/openai/deployments/{id}` | Yes | gpt-4o, gpt-4-turbo (per-deployment) |
| **OpenRouter** | `https://openrouter.ai/api` | Yes | 200+ models across providers |
| **Perplexity AI** | `https://api.perplexity.ai` | Yes | sonar-pro, sonar, sonar-reasoning |
| **Cohere** | `https://api.cohere.com/v2` | Yes | command-r-plus, command-r, command |
| **AI21** | `https://api.ai21.com/studio/v1` | Yes | jamba-1.5-large, jamba-1.5-mini |
| **Hyperbolic** | `https://api.hyperbolic.xyz/v1` | Yes | llama-3.1-70b, deepseek-v3 |
| **Lepton AI** | `https://api.lepton.ai/v1` | Yes | llama-3.1-70b, mixtral-8x7b |

### Tier 2: Local / Self-Hosted

| Provider | Base URL | Tool Calling | Notes |
|----------|----------|:------------:|-------|
| **vLLM** | `http://localhost:8000` | Yes (with `--enable-auto-tool-choice`) | Self-hosted, any HuggingFace model |
| **LM Studio** | `http://localhost:1234` | Partial | Local GUI, any GGUF model |

## Configuration

### CLI
```bash
krillclaw --provider openai --base-url https://api.groq.com/openai --model llama-3.3-70b-versatile "prompt"
```

### Environment Variables
```bash
export KRILLCLAW_PROVIDER=openai
export KRILLCLAW_BASE_URL=https://api.groq.com/openai
export KRILLCLAW_API_KEY=gsk_your_key_here
```

### Config File (`.krillclaw.json`)
```json
{
  "provider": "openai",
  "base_url": "https://api.groq.com/openai",
  "model": "llama-3.3-70b-versatile"
}
```

## Notes

- All OpenAI-compatible providers use the same code path in `api.zig`. The `--base-url` flag overrides the default URL while keeping the `/v1/chat/completions` path and `Authorization: Bearer` header.
- **Tool calling is required** for KrillClaw's agent loop. Providers without tool calling support can only be used in single-turn mode.
- **Streaming** works with all Tier 1 providers (SSE format). Ollama streaming is currently disabled pending format compatibility work.
- Azure OpenAI requires an `api-version` query parameter — this is not yet supported in KrillClaw's HTTP client. Use OpenRouter as a proxy for Azure models.
