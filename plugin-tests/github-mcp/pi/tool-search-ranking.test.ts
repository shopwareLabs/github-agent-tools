import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { registerOnFakePi } from "./fake-pi.ts";

const PLUGIN_DIR = fileURLToPath(new URL("../../../plugins/github-mcp", import.meta.url));

interface ToolDefinition {
  description: string;
  inputSchema: Record<string, unknown>;
  name: string;
}

interface ToolCatalog {
  tools: ToolDefinition[];
}

interface SearchDocument {
  name: string;
  text: string;
}

interface SearchNamespace {
  description?: string;
  instructions?: string;
  name: string;
}

interface ServerSpec {
  catalog: ToolCatalog;
  description: string;
  instructions: string;
  name: string;
}

interface Bm25Match {
  name: string;
  score: number;
}

interface Bm25RankerInstance {
  rank(query: string, documents: SearchDocument[], limit: number): Bm25Match[];
}

type Bm25RankerConstructor = new (options?: Record<string, unknown>) => Bm25RankerInstance;

interface ToolSearchModule {
  Bm25Ranker: Bm25RankerConstructor;
  createToolSearchDocument: (
    tool: { description: string; name: string; parameters: unknown },
    namespace?: SearchNamespace,
  ) => SearchDocument;
  tokenize: (text: string) => string[];
}

interface McpServersModule {
  mcpNamespace: (server: string) => string;
}

interface McpToolsModule {
  createMcpToolName: (server: string, tool: string, isTaken?: (name: string) => boolean) => string;
}

/**
 * These are pi internals loaded by file path because they are not in the package `exports` map. A
 * pi upgrade that moves, renames, or removes any of these exports fails this test instead of
 * silently losing the coverage.
 */
async function loadPiInternal<T>(relativePath: string, exportNames: readonly string[]): Promise<T> {
  const piPackageDirectory = path.dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent")));
  if (path.basename(piPackageDirectory) !== "dist" || path.basename(path.dirname(piPackageDirectory)) !== "pi-coding-agent") {
    throw new Error(`resolved pi package directory "${piPackageDirectory}" is not ".../pi-coding-agent/dist"`);
  }
  const absolute = path.join(piPackageDirectory, relativePath);
  const loaded = (await import(pathToFileURL(absolute).href)) as Record<string, unknown>;
  for (const exportName of exportNames) {
    if (typeof loaded[exportName] !== "function") {
      throw new TypeError(`pi internal "${relativePath}" has no function export "${exportName}"`);
    }
  }
  return loaded as unknown as T;
}

/**
 * Registers the real extension on a fake pi and returns both servers' descriptions, throwing if a
 * server or its description is missing.
 */
async function registeredDescriptions(): Promise<{ read: string; write: string }> {
  const { default: extension } = await import("../../../plugins/github-mcp/pi/index.ts");
  const { servers } = registerOnFakePi(extension);
  const read = servers.get("gh-tooling");
  if (read === undefined) {
    throw new Error('the extension registered no "gh-tooling" server');
  }
  const write = servers.get("gh-tooling-write");
  if (write === undefined) {
    throw new Error('the extension registered no "gh-tooling-write" server');
  }
  if (read.description === undefined) {
    throw new Error('gh-tooling server "gh-tooling" registered with no description');
  }
  if (write.description === undefined) {
    throw new Error('gh-tooling server "gh-tooling-write" registered with no description');
  }
  return { read: read.description, write: write.description };
}

/**
 * Reads a server config's `instructions`. The vendored SDK does not send this field to pi today
 * (see plugins/github-mcp/shared/mcpserver_core.sh), so this test includes it anyway: a future SDK
 * version that does send it must not be able to undo the ranking fix.
 */
function readInstructions(fileName: string): string {
  const raw = readFileSync(path.join(PLUGIN_DIR, "mcp-server-gh", fileName), "utf8");
  const config = JSON.parse(raw) as { instructions?: unknown };
  if (typeof config.instructions !== "string" || config.instructions.trim() === "") {
    throw new Error(`"${fileName}" has no non-empty "instructions" string`);
  }
  return config.instructions;
}

function loadCatalog(fileName: string): ToolCatalog {
  const raw = readFileSync(path.join(PLUGIN_DIR, "mcp-server-gh", fileName), "utf8");
  const catalog = JSON.parse(raw) as { tools: unknown };
  if (!Array.isArray(catalog.tools) || catalog.tools.length === 0) {
    throw new Error(`catalog "${fileName}" has no tools`);
  }
  for (const [index, tool] of catalog.tools.entries()) {
    const candidate = tool as Record<string, unknown>;
    const label = typeof candidate.name === "string" && candidate.name !== "" ? `"${candidate.name}"` : `index ${String(index)}`;
    if (typeof candidate.name !== "string" || candidate.name === "") {
      throw new TypeError(`catalog "${fileName}" tool at index ${String(index)} has no non-empty string "name"`);
    }
    if (typeof candidate.description !== "string") {
      throw new TypeError(`catalog "${fileName}" tool ${label} has no string "description"`);
    }
    if (typeof candidate.inputSchema !== "object" || candidate.inputSchema === null || Array.isArray(candidate.inputSchema)) {
      throw new TypeError(`catalog "${fileName}" tool ${label} has no object "inputSchema"`);
    }
  }
  return catalog as ToolCatalog;
}

/**
 * Builds search documents the way pi does: one per tool, carrying its server's namespace.
 */
function buildDocuments(
  servers: ServerSpec[],
  hasInstructions: boolean,
  createToolSearchDocument: ToolSearchModule["createToolSearchDocument"],
  mcpNamespace: McpServersModule["mcpNamespace"],
  createMcpToolName: McpToolsModule["createMcpToolName"],
): SearchDocument[] {
  const documents: SearchDocument[] = [];
  for (const server of servers) {
    const namespace: SearchNamespace = {
      description: server.description,
      instructions: hasInstructions ? server.instructions : undefined,
      name: mcpNamespace(server.name),
    };
    for (const tool of server.catalog.tools) {
      documents.push(
        createToolSearchDocument(
          { description: tool.description, name: createMcpToolName(server.name, tool.name), parameters: tool.inputSchema },
          namespace,
        ),
      );
    }
  }
  return documents;
}

/**
 * Worst rank allowed for a tool whose name shares terms with another tool. Every tool not listed
 * here must rank first for its own bare name.
 */
const WORST_ALLOWED_RANK: Record<string, number> = {
  pr_comment: 3,
  pr_comments: 5,
  pr_reviews: 3,
  repo_file: 3,
  search: 3,
};

test("tool_search ranks every tool within its allowed worst rank, with and without instructions", async () => {
  const { read: readDescription, write: writeDescription } = await registeredDescriptions();

  const { Bm25Ranker: bmRanker, createToolSearchDocument } = await loadPiInternal<ToolSearchModule>(
    "extensions/tool-search/tool.js",
    ["Bm25Ranker", "createToolSearchDocument"],
  );
  const { mcpNamespace } = await loadPiInternal<McpServersModule>("core/mcp-servers.js", ["mcpNamespace"]);
  const { createMcpToolName } = await loadPiInternal<McpToolsModule>("extensions/mcp/tools.js", ["createMcpToolName"]);

  const readServer: ServerSpec = {
    catalog: loadCatalog("tools-read.json"),
    description: readDescription,
    instructions: readInstructions("config-read.json"),
    name: "gh-tooling",
  };
  const writeServer: ServerSpec = {
    catalog: loadCatalog("tools-write.json"),
    description: writeDescription,
    instructions: readInstructions("config-write.json"),
    name: "gh-tooling-write",
  };

  const scenarios: { hasInstructions: boolean; label: string; servers: ServerSpec[]; }[] = [
    { hasInstructions: false, label: "read server only, without instructions", servers: [readServer] },
    { hasInstructions: false, label: "read + write servers, without instructions", servers: [readServer, writeServer] },
    { hasInstructions: true, label: "read server only, with instructions", servers: [readServer] },
    { hasInstructions: true, label: "read + write servers, with instructions", servers: [readServer, writeServer] },
  ];

  for (const scenario of scenarios) {
    const documents = buildDocuments(
      scenario.servers,
      scenario.hasInstructions,
      createToolSearchDocument,
      mcpNamespace,
      createMcpToolName,
    );
    const ranker = new bmRanker();
    const violations: string[] = [];

    for (const server of scenario.servers) {
      for (const tool of server.catalog.tools) {
        const expected = createMcpToolName(server.name, tool.name);
        const matches = ranker.rank(tool.name, documents, documents.length);
        const index = matches.findIndex((match) => match.name === expected);

        if (index === -1) {
          violations.push(`"${tool.name}" (expected "${expected}") was not found among the ranked results`);
          continue;
        }

        const allowed = WORST_ALLOWED_RANK[tool.name] ?? 1;
        const rank = index + 1;
        if (rank > allowed) {
          violations.push(
            `"${tool.name}" ranked ${String(rank)}, allowed ${String(allowed)}, first ranked was "${matches[0]?.name ?? "none"}"`,
          );
        }
      }
    }

    assert.equal(violations.length, 0, `scenario "${scenario.label}": ${violations.join("; ")}`);
  }
});

test("server descriptions and instructions share no terms with tool names", async () => {
  const { read: readDescription, write: writeDescription } = await registeredDescriptions();

  const { tokenize } = await loadPiInternal<ToolSearchModule>("extensions/tool-search/tool.js", ["tokenize"]);

  const sources: { label: string; text: string }[] = [
    { label: "gh-tooling description", text: readDescription },
    { label: "gh-tooling instructions", text: readInstructions("config-read.json") },
    { label: "gh-tooling-write description", text: writeDescription },
    { label: "gh-tooling-write instructions", text: readInstructions("config-write.json") },
  ];

  const toolNameTerms = new Set<string>();
  for (const fileName of ["tools-read.json", "tools-write.json"]) {
    for (const tool of loadCatalog(fileName).tools) {
      for (const term of tokenize(tool.name)) {
        toolNameTerms.add(term);
      }
    }
  }

  const overlaps: string[] = [];
  for (const source of sources) {
    const terms = new Set(tokenize(source.text));
    for (const term of terms) {
      if (toolNameTerms.has(term)) {
        overlaps.push(`"${term}" in ${source.label}`);
      }
    }
  }

  assert.equal(overlaps.length, 0, `server text shares terms with tool names: ${overlaps.join(", ")}`);
});
