import { spawn } from "node:child_process";

export interface ScriptResult {
  code: number | null;
  stderr: string;
  stdout: string;
}

export type GateResult = { block: true; reason: string } | { block: false };

/**
 * Runs `bash <script>` with `input` as JSON on stdin. Never rejects: a failed spawn, a stdin error,
 * or the timeout resolves `{ code: null, stdout: "", stderr: "" }`. On timeout the script's whole
 * process group is killed.
 */
export function runScript(script: string, input: unknown, timeoutMs: number): Promise<ScriptResult> {
  return new Promise((resolve) => {
    const env: NodeJS.ProcessEnv = { ...process.env, GITHUB_MCP_HOST: "pi" };
    delete env.CLAUDE_PROJECT_DIR;
    // Own process group, so the timeout can kill grandchildren that hold the stdio pipes open
    // and would otherwise keep `close` from firing. `bash` comes from PATH, as it does for the hooks
    // on Claude Code and Codex.
    // eslint-disable-next-line sonarjs/no-os-command-from-path
    const child = spawn("bash", [script], { detached: true, env });
    let stdout = "";
    let stderr = "";
    let isSettled = false;

    const settle = (result: ScriptResult): void => {
      if (isSettled) {
        return;
      }
      isSettled = true;
      clearTimeout(timer);
      resolve(result);
    };
    const fail = (): void => {
      settle({ code: null, stderr: "", stdout: "" });
    };

    const timer = setTimeout(() => {
      try {
        // A failed spawn leaves `pid` undefined, but its `error` settles and clears this timer first.
        if (child.pid !== undefined) {
          process.kill(-child.pid, "SIGKILL");
        }
      } catch {
        // ESRCH: the group is already gone.
      }
      fail();
    }, timeoutMs);

    child.on("error", fail);
    child.stdin.on("error", fail);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.on("close", (code) => {
      settle({ code, stderr, stdout });
    });
    child.stdin.end(JSON.stringify(input));
  });
}

/**
 * Runs a hook gate script. Exit code 2 blocks with the trimmed stderr as the reason; any other
 * outcome, including a timeout or a failed spawn, does not block. Never rejects.
 */
export async function runGate(script: string, input: unknown, timeoutMs: number): Promise<GateResult> {
  const { code, stderr } = await runScript(script, input, timeoutMs);
  return code === 2 ? { block: true, reason: stderr.trim() } : { block: false };
}
