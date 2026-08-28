import { execFile } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import { promisify } from "util";
import { environment, getPreferenceValues } from "@raycast/api";

export const execFileAsync = promisify(execFile);

export interface Preferences {
  qtPath?: string;
  dataDir?: string;
}

export interface Denial {
  tool_name?: string;
  tool_input?: unknown;
}

export type TaskStatus =
  "queued" | "running" | "done" | "failed" | "timeout" | "blocked";

export interface Task {
  id: string;
  prompt: string;
  status: TaskStatus;
  created: string;
  started?: string;
  finished?: string;
  invoked_from?: string;
  run_cwd?: string;
  perm_mode?: string;
  model?: string | null;
  session_id?: string | null;
  result?: string | null;
  cost_usd?: number | null;
  denials?: Denial[];
}

export function expandHome(p: string): string {
  if (p === "~") return os.homedir();
  if (p.startsWith("~/")) return path.join(os.homedir(), p.slice(2));
  return p;
}

export function resolveQtPath(): string {
  const prefs = getPreferenceValues<Preferences>();
  const configured = prefs.qtPath?.trim();
  if (configured) return expandHome(configured);

  const defaultPath = expandHome("~/.local/bin/qt");
  if (fs.existsSync(defaultPath)) return defaultPath;

  const repoRelative = path.join(environment.assetsPath, "..", "..", "qt");
  if (fs.existsSync(repoRelative)) return repoRelative;

  return defaultPath;
}

export function resolveDataDir(): string {
  const prefs = getPreferenceValues<Preferences>();
  const configured = prefs.dataDir?.trim();
  return expandHome(configured || "~/.quicktasks");
}

export function tasksDir(dataDir: string): string {
  return path.join(dataDir, "tasks");
}

export function logsDir(dataDir: string): string {
  return path.join(dataDir, "logs");
}

export function workspaceDir(dataDir: string): string {
  return path.join(dataDir, "workspace");
}

export function taskLogPath(dataDir: string, id: string): string {
  return path.join(logsDir(dataDir), `${id}.log`);
}

export function taskJsonPath(dataDir: string, id: string): string {
  return path.join(tasksDir(dataDir), `${id}.json`);
}

export function readTasks(dataDir: string, limit = 50): Task[] {
  let files: string[];
  try {
    files = fs
      .readdirSync(tasksDir(dataDir))
      .filter((f) => f.endsWith(".json"));
  } catch {
    return [];
  }

  const tasks: Task[] = [];
  for (const f of files) {
    try {
      const raw = fs.readFileSync(path.join(tasksDir(dataDir), f), "utf8");
      const parsed = JSON.parse(raw) as Partial<Task>;
      if (
        parsed &&
        typeof parsed.id === "string" &&
        typeof parsed.prompt === "string" &&
        typeof parsed.status === "string"
      ) {
        tasks.push(parsed as Task);
      }
    } catch {
      continue;
    }
  }

  tasks.sort((a, b) =>
    a.created < b.created ? 1 : a.created > b.created ? -1 : 0,
  );
  return tasks.slice(0, limit);
}

export function deleteTask(dataDir: string, id: string): void {
  fs.rmSync(taskJsonPath(dataDir, id), { force: true });
  fs.rmSync(taskLogPath(dataDir, id), { force: true });
}

export function tailLines(filePath: string, n: number): string {
  try {
    const content = fs.readFileSync(filePath, "utf8");
    const lines = content.split("\n");
    return lines.slice(-n).join("\n").trim();
  } catch {
    return "";
  }
}

export function ageString(iso: string): string {
  const created = new Date(iso).getTime();
  if (Number.isNaN(created)) return "";
  const seconds = Math.max(0, Math.floor((Date.now() - created) / 1000));
  const units: Array<[string, number]> = [
    ["d", 86400],
    ["h", 3600],
    ["m", 60],
  ];
  for (const [unit, div] of units) {
    if (seconds >= div) return `${Math.floor(seconds / div)}${unit}`;
  }
  return `${seconds}s`;
}

export function errorMessage(err: unknown): string {
  if (err && typeof err === "object") {
    const e = err as { stderr?: unknown; message?: unknown };
    if (typeof e.stderr === "string" && e.stderr.trim()) return e.stderr.trim();
    if (typeof e.message === "string" && e.message.trim())
      return e.message.trim();
  }
  return String(err);
}

export function firstLine(text: string | null | undefined): string {
  if (!text) return "";
  return text.split("\n")[0].trim();
}

export async function resumeTask(qtPath: string, id: string): Promise<void> {
  await execFileAsync(qtPath, ["_resume-launch", id]);
}

export async function requeueTask(
  qtPath: string,
  prompt: string,
  dir?: string,
): Promise<string> {
  const args = dir ? ["--in", dir, prompt] : [prompt];
  const { stdout } = await execFileAsync(qtPath, args);
  const match = stdout.match(/queued (\S+)/);
  return match ? match[1] : stdout.trim();
}
