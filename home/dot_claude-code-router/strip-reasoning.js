// CCR custom transformer: remove the OpenAI `reasoning` param before sending upstream.
// NVIDIA NIM's chat/completions rejects `reasoning` (400 Unsupported parameter) even for
// reasoning-capable models like deepseek-v4-pro, which gate thinking a different way.
// Claude Code (Opus "high") emits a thinking budget that CCR converts to `reasoning`;
// this drops it so the request validates. No built-in transformer deletes a key.
class StripReasoning {
  name = "strip-reasoning";

  async transformRequestIn(request) {
    if (request && typeof request === "object") {
      delete request.reasoning;
      delete request.thinking;
      delete request.enable_thinking;
    }
    return request;
  }
}

module.exports = StripReasoning;
