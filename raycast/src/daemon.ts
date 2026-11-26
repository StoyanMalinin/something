import { getPreferenceValues } from "@raycast/api";
import { readFileSync } from "node:fs";
import { createConnection } from "node:net";
import { homedir } from "node:os";

// The oldest daemon protocol this extension works with: below it we refuse to talk. Every
// daemon response, errors included, carries a "version"; raise this when the extension
// cannot do without something newer.
// 2: the config, setConfig and status commands
const MIN_PROTOCOL_VERSION = 2;
// The newest protocol this extension knows. A daemon between the two works, but misses
// features, so the UI asks the user to upgrade and restart it.
// 3: "issues" in search and status responses
export const NEWEST_PROTOCOL_VERSION = 3;

export function isOutdated(daemonVersion: number): boolean {
  return daemonVersion < NEWEST_PROTOCOL_VERSION;
}

export const home = homedir();

export function expandHome(p: string): string {
  return p === "~" || p.startsWith("~/") ? home + p.slice(1) : p;
}

export function tildify(p: string): string {
  return p === home || p.startsWith(home + "/") ? "~" + p.slice(home.length) : p;
}

interface Preferences {
  socketPath?: string;
  configPath?: string;
}

export function socketPath(): string {
  return expandHome(getPreferenceValues<Preferences>().socketPath || "~/Library/Caches/something/daemon.sock");
}

export function configPath(): string {
  return expandHome(
    getPreferenceValues<Preferences>().configPath || "~/Library/Application Support/something/config.json",
  );
}

/** What the daemon indexes and how many results a query gets. The daemon owns it. */
export interface DaemonConfig {
  /** Absolute folders to index */
  include: string[];
  /** Absolute paths to leave out, or bare names to leave out wherever they appear */
  exclude: string[];
  /** Results per query */
  limit: number;
}

export interface Match {
  score: number;
  path: string;
}

/** Parts of the tree the daemon could not cover. Absent from a response when all is well. */
export interface Issues {
  /** Folders it may not open, so their files are missing from results (on macOS: no Full Disk Access) */
  unreadable: number;
  /** Other errors that left the index incomplete or stale */
  failed: number;
  /** A few unreadable folders, shallowest first */
  samples: string[];
}

/** What every response says about the daemon itself */
export interface DaemonStatus {
  version: number;
  issues?: Issues;
}

interface Response {
  version?: number;
  error?: string;
  matches?: Match[];
  config?: DaemonConfig;
  indexing?: boolean;
  issues?: Issues;
}

function statusOf(response: Response): DaemonStatus {
  return { version: response.version ?? 0, issues: response.issues };
}

export class DaemonError extends Error {}

// One request per connection: send a JSON line with a "command", read one JSON line back.
function request(command: object, signal?: AbortSignal): Promise<Response> {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ path: socketPath() });
    let data = "";
    signal?.addEventListener("abort", () => socket.destroy());
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.end(JSON.stringify(command) + "\n"));
    socket.on("data", (chunk: string) => (data += chunk));
    socket.on("error", reject);
    socket.on("close", () => {
      if (signal?.aborted) return;
      try {
        const response = JSON.parse(data) as Response;
        if (typeof response.version !== "number") {
          throw new DaemonError("The daemon sent no protocol version; update something-daemon");
        }
        if (response.version < MIN_PROTOCOL_VERSION) {
          throw new DaemonError(
            `something-daemon speaks protocol v${response.version}, this extension needs v${MIN_PROTOCOL_VERSION} or newer; update it`,
          );
        }
        if (response.error !== undefined) throw new DaemonError(response.error);
        resolve(response);
      } catch (e) {
        reject(e);
      }
    });
  });
}

/** Matches for `text`, best first, and the daemon's status. How many is up to the daemon's config. */
export async function search(
  text: string,
  signal: AbortSignal,
): Promise<{ matches: Match[]; status: DaemonStatus }> {
  const response = await request({ command: "search", query: text }, signal);
  return { matches: response.matches ?? [], status: statusOf(response) };
}

/** The daemon's version and issues, without searching: for a screen that has no query yet. */
export async function getStatus(): Promise<DaemonStatus> {
  return statusOf(await request({ command: "status" }));
}

/**
 * Asks the daemon to change its config; fields left out stay as they are. The daemon checks,
 * saves and applies it, and a change to the includes or excludes makes it rebuild the index.
 * Rejects with the daemon's reason when it refuses.
 */
export async function setConfig(change: Partial<DaemonConfig>): Promise<DaemonConfig> {
  const response = await request({ command: "setConfig", config: change });
  if (!response.config) throw new DaemonError("The daemon did not say what it saved");
  return response.config;
}

/** Whether the daemon is rebuilding its index. */
export async function isIndexing(): Promise<boolean> {
  return (await request({ command: "status" })).indexing === true;
}

/**
 * The daemon's config file, or undefined if there is none: the daemon has never run. The file
 * is the daemon's alone; only read it.
 */
export function readConfig(): DaemonConfig | undefined {
  let text: string;
  try {
    text = readFileSync(configPath(), "utf8");
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw e;
  }
  const file = JSON.parse(text) as Partial<DaemonConfig>;
  return { include: file.include ?? [], exclude: file.exclude ?? [], limit: file.limit ?? 50 };
}

export function isConnectionError(error: unknown): boolean {
  const code = (error as NodeJS.ErrnoException)?.code;
  return code === "ENOENT" || code === "ECONNREFUSED";
}

export function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
