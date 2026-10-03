import path from "node:path";
import { fileURLToPath } from "node:url";
import { type GateResult, runGate, runScript } from "./gate.ts";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PLUGIN_ROOT = fileURLToPath(new URL("..", import.meta.url));
const SCRIPTS_DIR = path.join(PLUGIN_ROOT, "hooks", "scripts");
const SCRIPT_TIMEOUT_MS = 5000;
const API_TOOL_NAMES = new Set(["mcp__gh_tooling__api_read", "mcp__gh_tooling_write__api"]);

function readAdditionalContext(stdout: string): string {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return "";
  }
  if (typeof parsed !== "object" || parsed === null || !("hookSpecificOutput" in parsed)) {
    return "";
  }
  const output = parsed.hookSpecificOutput;
  if (typeof output !== "object" || output === null || !("additionalContext" in output)) {
    return "";
  }
  return typeof output.additionalContext === "string" ? output.additionalContext : "";
}

export default function githubMcp(pi: ExtensionAPI): void {
  pi.registerMcpServer("gh-tooling", {
    command: path.join(PLUGIN_ROOT, "mcp-server-gh", "server-read.sh"),
    description: "Remote GitHub data through the gh CLI, not local git.",
    env: { GITHUB_MCP_HOST: "pi" },
    exposure: "deferred",
  });
  pi.registerMcpServer("gh-tooling-write", {
    command: path.join(PLUGIN_ROOT, "mcp-server-gh", "server-write.sh"),
    description:
      "Changes to remote GitHub data through the gh CLI, not local git. Empty unless enable_write_server is true.",
    env: { GITHUB_MCP_HOST: "pi" },
    exposure: "deferred",
  });

  let directive = "";

  pi.on("session_start", async (_event, ctx) => {
    const { code, stdout } = await runScript(path.join(SCRIPTS_DIR, "session-start.sh"), { cwd: ctx.cwd }, SCRIPT_TIMEOUT_MS);
    directive = code === 0 ? readAdditionalContext(stdout) : "";
  });

  pi.on("before_agent_start", (event) => {
    if (directive !== "") {
      event.systemPromptOptions.sections.github_mcp = directive;
    }
  });

  pi.on("tool_call", async (event, ctx) => {
    let result: GateResult;
    if (event.toolName === "bash") {
      result = await runGate(
        path.join(SCRIPTS_DIR, "check-gh-tools.sh"),
        { cwd: ctx.cwd, tool_input: event.input },
        SCRIPT_TIMEOUT_MS,
      );
    } else if (API_TOOL_NAMES.has(event.toolName)) {
      result = await runGate(
        path.join(SCRIPTS_DIR, "check-api-tools.sh"),
        { cwd: ctx.cwd, tool_input: event.input, tool_name: event.toolName },
        SCRIPT_TIMEOUT_MS,
      );
    } else {
      return;
    }
    return result.block ? result : undefined;
  });
}
