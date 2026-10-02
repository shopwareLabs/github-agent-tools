import assert from "node:assert/strict";
import { cpSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import type githubMcp from "../../../plugins/github-mcp/pi/index.ts";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type Handler = (event: unknown, ctx: unknown) => unknown;

const PLUGIN_DIR = fileURLToPath(new URL("../../../plugins/github-mcp", import.meta.url));

function makeTemporaryDirectory(t: TestContext): string {
  const dir = mkdtempSync(path.join(tmpdir(), "github-mcp-pi-index-"));
  t.after(() => {
    rmSync(dir, { force: true, recursive: true });
  });
  return dir;
}

function noop(): void {
  // The fake pi has nothing to unsubscribe and no server to start.
}

/**
 * Registers the extension on a fake pi that only records the event handlers.
 */
function register(extension: typeof githubMcp): Map<string, Handler> {
  const handlers = new Map<string, Handler>();
  const pi = {
    on: (name: string, handler: Handler) => {
      handlers.set(name, handler);
      return noop;
    },
    registerMcpServer: noop,
  };
  extension(pi as unknown as ExtensionAPI);
  return handlers;
}

function handler(handlers: Map<string, Handler>, name: string): Handler {
  const found = handlers.get(name);
  if (found === undefined) {
    throw new Error(`the extension registered no ${name} handler`);
  }
  return found;
}

/**
 * Loads a copy of the extension whose session-start.sh is replaced by `scriptBody`, starts a
 * session, and returns the system prompt sections the next agent start receives.
 */
async function sectionsAfterSessionStart(t: TestContext, scriptBody: string): Promise<Record<string, string>> {
  const dir = makeTemporaryDirectory(t);
  for (const part of ["pi", "hooks", "shared"]) {
    cpSync(path.join(PLUGIN_DIR, part), path.join(dir, "plugin", part), { recursive: true });
  }
  writeFileSync(path.join(dir, "plugin", "hooks", "scripts", "session-start.sh"), scriptBody);
  const indexUrl = pathToFileURL(path.join(dir, "plugin", "pi", "index.ts")).href;
  const { default: extension } = (await import(indexUrl)) as { default: typeof githubMcp };
  const handlers = register(extension);

  await handler(handlers, "session_start")({}, { cwd: dir });
  const sections: Record<string, string> = {};
  await handler(handlers, "before_agent_start")({ systemPromptOptions: { sections } }, { cwd: dir });
  return sections;
}

async function loadRealExtension(): Promise<Map<string, Handler>> {
  const { default: extension } = await import("../../../plugins/github-mcp/pi/index.ts");
  return register(extension);
}

test("the session-start directive becomes the github_mcp system prompt section", async (t) => {
  const sections = await sectionsAfterSessionStart(
    t,
    `printf '%s' '{"hookSpecificOutput":{"additionalContext":"Use the gh-tooling tools."}}'\n`,
  );

  assert.deepEqual(sections, { github_mcp: "Use the gh-tooling tools." });
});

for (const { output, problem } of [
  { output: "Use the gh-tooling tools.", problem: "is not JSON" },
  { output: '{"additionalContext":"Use the gh-tooling tools."}', problem: "has no hookSpecificOutput" },
  { output: '{"hookSpecificOutput":{"context":"Use the gh-tooling tools."}}', problem: "has no additionalContext" },
  {
    output: '{"hookSpecificOutput":{"additionalContext":["Use the gh-tooling tools."]}}',
    problem: "has a non-string additionalContext",
  },
]) {
  test(`no github_mcp section is added when the session-start output ${problem}`, async (t) => {
    const sections = await sectionsAfterSessionStart(t, `printf '%s' '${output}'\n`);

    assert.deepEqual(sections, {});
  });
}

test("no github_mcp section is added when session-start exits non-zero", async (t) => {
  const sections = await sectionsAfterSessionStart(
    t,
    `printf '%s' '{"hookSpecificOutput":{"additionalContext":"Use the gh-tooling tools."}}'\nexit 1\n`,
  );

  assert.deepEqual(sections, {});
});

test("a bash command without gh runs unblocked", async (t) => {
  const toolCall = handler(await loadRealExtension(), "tool_call");

  const result = await toolCall({ input: { command: "ls -la" }, toolName: "bash" }, { cwd: makeTemporaryDirectory(t) });

  assert.equal(result, undefined);
});

test("api_read on an endpoint without a dedicated tool runs unblocked when block_api_tool_read is set", async (t) => {
  const dir = makeTemporaryDirectory(t);
  writeFileSync(path.join(dir, ".mcp-gh-tooling.json"), '{"block_api_tool_read": true}\n');
  const toolCall = handler(await loadRealExtension(), "tool_call");

  const result = await toolCall(
    { input: { endpoint: "repos/octo/demo/branches" }, toolName: "mcp__gh_tooling__api_read" },
    { cwd: dir },
  );

  assert.equal(result, undefined);
});
