// Scripted model for pi_e2e.bats. Registers the faux provider (model faux/faux-1), answers each
// model request with the next turn of the $SCENARIO script, and records what the package
// extension does: every request's messages go to $TRACE, and every tool call's view of the
// gh-tooling tools goes to $PROBE. Loaded with -e, so it sees each call before the package's gate.
import { appendFileSync } from "node:fs";
import {
  fauxAssistantMessage,
  fauxProvider,
  type FauxResponseFactory,
  fauxText,
  fauxToolCall,
  type ToolCall,
} from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function requiredEnvironmentVariable(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === "") {
    throw new Error(`driver.ts: ${name} must be set`);
  }
  return value;
}

const SCENARIO = requiredEnvironmentVariable("SCENARIO");
const TRACE = requiredEnvironmentVariable("TRACE");
const PROBE = requiredEnvironmentVariable("PROBE");

const REPO = "shopwareLabs/github-agent-tools";
const FILES_ENDPOINT = `repos/${REPO}/pulls/8/files`;

function prView(number: number): ToolCall {
  return fauxToolCall(
    "mcp__gh_tooling__pr_view",
    { fields: "number,title", number, repo: REPO },
    { id: `pr-view-${String(number)}` },
  );
}

const ghPrViewInBash = fauxToolCall("bash", { command: "gh pr view 8" }, { id: "bash-gh-pr-view" });

/**
 * One assistant turn per model request; the last turn ends the run with plain text.
 */
const SCENARIOS: Record<string, (ToolCall | ToolCall[] | string)[]> = {
  codemode: [
    fauxToolCall(
      "codemode",
      {
        code: `
const results = await Promise.all([11, 12, 13].map((number) =>
  tools.mcp__gh_tooling__pr_view({ repo: "${REPO}", number, fields: "number,title" })));
let caught = null;
try {
  await tools.mcp__gh_tooling__api_read({ endpoint: "${FILES_ENDPOINT}" });
} catch (error) {
  caught = error.message;
}
return JSON.stringify({ results, caught });
`,
      },
      { id: "codemode-script" },
    ),
    "done",
  ],
  deferred: [
    fauxToolCall("tool_search", { limit: 1, query: "pr_view" }, { id: "search-pr-view" }),
    fauxToolCall("tool_search", { limit: 1, query: "issue_view" }, { id: "search-issue-view" }),
    prView(8),
    ghPrViewInBash,
    fauxToolCall("tool_search", { query: "api_read" }, { id: "search-api-read" }),
    fauxToolCall("mcp__gh_tooling__api_read", { endpoint: FILES_ENDPOINT }, { id: "api-read-files" }),
    [prView(11), prView(12), prView(13)],
    "done",
  ],
  "environment-leak": [ghPrViewInBash, "done"],
  "mcp-override": [prView(8), ghPrViewInBash, "done"],
};

const turns = SCENARIOS[SCENARIO];
if (turns === undefined) {
  throw new Error(`driver.ts: unknown SCENARIO ${SCENARIO}`);
}

const responses: FauxResponseFactory[] = turns.map((turn) => (context) => {
  appendFileSync(TRACE, `${JSON.stringify(context.messages)}\n`);
  return fauxAssistantMessage(typeof turn === "string" ? fauxText(turn) : turn);
});

const isGhTooling = (name: string): boolean => name.startsWith("mcp__gh_tooling");

export default function driver(pi: ExtensionAPI): void {
  const faux = fauxProvider();
  faux.setResponses(responses);
  pi.registerProvider(faux.provider);

  pi.on("tool_call", (event) => {
    const ghTools = pi.getAllTools().filter((tool) => isGhTooling(tool.name));
    const exposures = [...new Set(ghTools.map((tool) => tool.exposure))];
    appendFileSync(
      PROBE,
      `${JSON.stringify({
        active: pi.getActiveTools().filter((name) => isGhTooling(name)).length,
        all: ghTools.length,
        exposures,
        tool: event.toolName,
      })}\n`,
    );
  });
}
