import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { runGate, runScript, type GateResult } from "./gate.ts";

const PLUGIN_ROOT = fileURLToPath(new URL("..", import.meta.url));
const SCRIPTS_DIR = join(PLUGIN_ROOT, "hooks", "scripts");
const SCRIPT_TIMEOUT_MS = 5000;
const API_TOOL_NAMES = new Set(["mcp__gh_tooling__api_read", "mcp__gh_tooling_write__api"]);

function readAdditionalContext(stdout: string): string {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return "";
  }
  if (typeof parsed !== "object" || parsed === null || !("hookSpecificOutput" in parsed)) return "";
  const output = parsed.hookSpecificOutput;
  if (typeof output !== "object" || output === null || !("additionalContext" in output)) return "";
  return typeof output.additionalContext === "string" ? output.additionalContext : "";
}

export default function githubMcp(pi: ExtensionAPI): void {
  pi.registerMcpServer("gh-tooling", {
    command: join(PLUGIN_ROOT, "mcp-server-gh", "server-read.sh"),
    env: { GITHUB_MCP_HOST: "pi" },
    exposure: "deferred",
    description:
      "GitHub via the gh CLI: pull requests, issues, CI runs and logs, commits, search, labels, projects, repository files.",
  });
  pi.registerMcpServer("gh-tooling-write", {
    command: join(PLUGIN_ROOT, "mcp-server-gh", "server-write.sh"),
    env: { GITHUB_MCP_HOST: "pi" },
    exposure: "deferred",
    description:
      "GitHub writes via the gh CLI: create and edit pull requests, issues, reviews, comments, labels, projects. Empty unless enable_write_server is set.",
  });

  let directive = "";

  pi.on("session_start", async (_event, ctx) => {
    const { code, stdout } = await runScript(join(SCRIPTS_DIR, "session-start.sh"), { cwd: ctx.cwd }, SCRIPT_TIMEOUT_MS);
    directive = code === 0 ? readAdditionalContext(stdout) : "";
  });

  pi.on("before_agent_start", (event) => {
    if (directive !== "") event.systemPromptOptions.sections.github_mcp = directive;
  });

  pi.on("tool_call", async (event, ctx) => {
    let result: GateResult;
    if (event.toolName === "bash") {
      result = await runGate(
        join(SCRIPTS_DIR, "check-gh-tools.sh"),
        { tool_input: event.input, cwd: ctx.cwd },
        SCRIPT_TIMEOUT_MS,
      );
    } else if (API_TOOL_NAMES.has(event.toolName)) {
      result = await runGate(
        join(SCRIPTS_DIR, "check-api-tools.sh"),
        { tool_name: event.toolName, tool_input: event.input, cwd: ctx.cwd },
        SCRIPT_TIMEOUT_MS,
      );
    } else {
      return undefined;
    }
    return result.block ? result : undefined;
  });
}
