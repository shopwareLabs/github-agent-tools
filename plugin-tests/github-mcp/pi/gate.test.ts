import test, { type TestContext } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { runGate, runScript } from "../../../plugins/github-mcp/pi/gate.ts";

function makeTempDir(t: TestContext): string {
  const dir = mkdtempSync(join(tmpdir(), "github-mcp-pi-gate-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function writeScript(dir: string, body: string): string {
  const script = join(dir, "script.sh");
  writeFileSync(script, body);
  return script;
}

function processExists(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
    throw error;
  }
}

test("runScript returns the script's stdout and exit code 0 unchanged", async (t) => {
  const script = writeScript(makeTempDir(t), "printf '  {\"ok\": true}\\n'\nexit 0\n");

  const result = await runScript(script, {}, 5000);

  assert.deepEqual(result, { code: 0, stdout: '  {"ok": true}\n', stderr: "" });
});

test("a gate that exits 2 blocks with its trimmed stderr as the reason", async (t) => {
  const script = writeScript(makeTempDir(t), "printf '\\n  Use mcp__gh_tooling__pr_view instead.  \\n' >&2\nexit 2\n");

  const result = await runGate(script, { tool_input: { command: "gh pr view 8" } }, 5000);

  assert.deepEqual(result, { block: true, reason: "Use mcp__gh_tooling__pr_view instead." });
});

test("the script runs with GITHUB_MCP_HOST=pi and without the caller's CLAUDE_PROJECT_DIR", async (t) => {
  const previous = process.env.CLAUDE_PROJECT_DIR;
  process.env.CLAUDE_PROJECT_DIR = "/claude/project";
  t.after(() => {
    if (previous === undefined) delete process.env.CLAUDE_PROJECT_DIR;
    else process.env.CLAUDE_PROJECT_DIR = previous;
  });
  const script = writeScript(
    makeTempDir(t),
    'printf "host=%s claude=%s" "${GITHUB_MCP_HOST-unset}" "${CLAUDE_PROJECT_DIR-unset}"\n',
  );

  const { stdout } = await runScript(script, {}, 5000);

  assert.equal(stdout, "host=pi claude=unset");
});

test("a nonexistent gate script does not block", async (t) => {
  const script = join(makeTempDir(t), "missing.sh");

  const result = await runGate(script, {}, 5000);

  assert.deepEqual(result, { block: false });
});

test("a gate that closes its stdin before reading a 1 MB input does not block and raises no unhandled error", async (t) => {
  const unhandled: unknown[] = [];
  const record = (error: unknown): void => {
    unhandled.push(error);
  };
  process.on("uncaughtException", record);
  process.on("unhandledRejection", record);
  t.after(() => {
    process.off("uncaughtException", record);
    process.off("unhandledRejection", record);
  });
  const script = writeScript(makeTempDir(t), "exec 0<&-\nexit 0\n");

  const result = await runGate(script, { payload: "x".repeat(1024 * 1024) }, 5000);
  // A late EPIPE would surface after settling; give it a few event-loop turns to arrive.
  await delay(100);

  assert.deepEqual(result, { block: false });
  assert.deepEqual(unhandled, []);
});

test("a gate that outlives its timeout does not block and its background children are killed", { timeout: 10_000 }, async (t) => {
  const dir = makeTempDir(t);
  const pidFile = join(dir, "sleep.pid");
  const script = writeScript(dir, `sleep 37 &\nprintf '%s' "$!" > '${pidFile}'\nwait\n`);

  const result = await runGate(script, {}, 500);

  assert.deepEqual(result, { block: false });
  const sleepPid = Number(readFileSync(pidFile, "utf8"));
  // SIGKILL delivery and reaping of the orphaned sleep are asynchronous; poll briefly.
  for (let attempt = 0; attempt < 40 && processExists(sleepPid); attempt++) await delay(50);
  assert.equal(processExists(sleepPid), false);
});
