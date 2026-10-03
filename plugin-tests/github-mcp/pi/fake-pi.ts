import type { ExtensionAPI, McpServerConfig } from "@earendil-works/pi-coding-agent";

export type Handler = (event: unknown, ctx: unknown) => unknown;

export type FakeMcpServerConfig = McpServerConfig;

export interface FakePi {
  handlers: Map<string, Handler>;
  servers: Map<string, FakeMcpServerConfig>;
}

function noop(): void {
  // The fake pi has nothing to unsubscribe and no server to start.
}

/**
 * Registers `extension` on a fake pi that records every event handler and MCP server
 * registration instead of running them.
 */
export function registerOnFakePi(extension: (pi: ExtensionAPI) => void): FakePi {
  const handlers = new Map<string, Handler>();
  const servers = new Map<string, FakeMcpServerConfig>();
  const pi = {
    on: (name: string, handler: Handler) => {
      handlers.set(name, handler);
      return noop;
    },
    registerMcpServer: (name: string, config: FakeMcpServerConfig) => {
      servers.set(name, config);
    },
  };
  extension(pi as unknown as ExtensionAPI);
  return { handlers, servers };
}
