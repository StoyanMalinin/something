import { Action, ActionPanel, getPreferenceValues, Icon, List } from "@raycast/api";
import { createConnection } from "node:net";
import { homedir } from "node:os";
import { basename, dirname } from "node:path";
import { useEffect, useState } from "react";

interface Preferences {
  socketPath?: string;
  limit?: string;
}

interface Match {
  score: number;
  path: string;
}

const home = homedir();

const REPO_URL = "https://github.com/StoyanMalinin/something";
const BREW_FORMULA = "StoyanMalinin/tap/something-daemon";

const SETUP_STEPS = [
  { title: "Start the daemon", command: `brew services start ${BREW_FORMULA}`, icon: Icon.Play },
  { title: "Install the daemon", command: `brew install ${BREW_FORMULA}`, icon: Icon.Download },
  { title: "Install, building from source", command: `brew install --build-from-source ${BREW_FORMULA}`, icon: Icon.Hammer },
];

function expandHome(p: string): string {
  return p === "~" || p.startsWith("~/") ? home + p.slice(1) : p;
}

function tildify(p: string): string {
  return p === home || p.startsWith(home + "/") ? "~" + p.slice(home.length) : p;
}

// One query per connection: send "<limit>\t<query>\n", read JSON lines until the daemon closes.
function query(socketPath: string, limit: number, text: string, signal: AbortSignal): Promise<Match[]> {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ path: socketPath });
    let data = "";
    signal.addEventListener("abort", () => socket.destroy());
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.end(`${limit}\t${text.replace(/[\r\n]/g, " ")}\n`));
    socket.on("data", (chunk: string) => (data += chunk));
    socket.on("error", reject);
    socket.on("close", () => {
      if (signal.aborted) return;
      try {
        resolve(
          data
            .split("\n")
            .filter((line) => line.length > 0)
            .map((line) => JSON.parse(line) as Match),
        );
      } catch (e) {
        reject(e);
      }
    });
  });
}

function formatLatency(ms: number): string {
  return `${ms < 10 ? ms.toFixed(1) : Math.round(ms)} ms`;
}

function isConnectionError(error: unknown): boolean {
  const code = (error as NodeJS.ErrnoException)?.code;
  return code === "ENOENT" || code === "ECONNREFUSED";
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function SetupHelp() {
  return (
    <List.Section title="Can't reach something-daemon" subtitle="It isn't running, not installed, or still indexing">
      {SETUP_STEPS.map((step) => (
        <List.Item
          key={step.command}
          icon={step.icon}
          title={step.title}
          subtitle={step.command}
          actions={
            <ActionPanel>
              <Action.CopyToClipboard title="Copy Command" content={step.command} />
              <Action.OpenInBrowser title="View Source on Github" url={REPO_URL} />
            </ActionPanel>
          }
        />
      ))}
      <List.Item
        icon={Icon.Code}
        title="Inspect the code on GitHub"
        subtitle={REPO_URL}
        actions={
          <ActionPanel>
            <Action.OpenInBrowser title="Open Repository" url={REPO_URL} />
            <Action.CopyToClipboard title="Copy Link" content={REPO_URL} />
          </ActionPanel>
        }
      />
    </List.Section>
  );
}

export default function Command() {
  const prefs = getPreferenceValues<Preferences>();
  const socketPath = expandHome(prefs.socketPath || "~/Library/Caches/something/daemon.sock");
  const limit = Math.max(1, parseInt(prefs.limit || "50", 10) || 50);

  const [text, setText] = useState("");
  const [matches, setMatches] = useState<Match[]>([]);
  const [error, setError] = useState<string>();
  const [unreachable, setUnreachable] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  // Round trip of the query on screen: connect, search, and every result read back
  const [latencyMs, setLatencyMs] = useState<number>();

  useEffect(() => {
    if (text.trim() === "") {
      setMatches([]);
      setError(undefined);
      setUnreachable(false);
      setLatencyMs(undefined);
      return;
    }
    // A newer keystroke cancels the query still in flight
    const controller = new AbortController();
    setIsLoading(true);
    const start = performance.now();
    query(socketPath, limit, text, controller.signal)
      .then((m) => {
        setLatencyMs(performance.now() - start);
        setMatches(m);
        setError(undefined);
        setUnreachable(false);
      })
      .catch((e) => {
        if (controller.signal.aborted) return;
        setUnreachable(isConnectionError(e));
        setError(describe(e));
      })
      .finally(() => {
        if (!controller.signal.aborted) setIsLoading(false);
      });
    return () => controller.abort();
  }, [text, socketPath, limit]);

  return (
    <List
      isLoading={isLoading}
      filtering={false}
      onSearchTextChange={setText}
      searchBarPlaceholder="Fuzzy search files…"
    >
      {unreachable ? (
        <SetupHelp />
      ) : error ? (
        <List.EmptyView icon={Icon.ExclamationMark} title="Can't reach something-daemon" description={error} />
      ) : text.trim() === "" ? (
        <List.EmptyView icon={Icon.MagnifyingGlass} title="Type to search every indexed file" />
      ) : matches.length === 0 && latencyMs !== undefined ? (
        <List.EmptyView icon={Icon.MagnifyingGlass} title="No matches" description={formatLatency(latencyMs)} />
      ) : (
        <List.Section
          title={`${matches.length} ${matches.length === 1 ? "match" : "matches"}`}
          subtitle={latencyMs === undefined ? undefined : formatLatency(latencyMs)}
        >
          {matches.map((m) => (
            <MatchItem key={m.path} match={m} />
          ))}
        </List.Section>
      )}
    </List>
  );
}

function MatchItem({ match }: { match: Match }) {
  const isDir = match.path.endsWith("/");
  const path = isDir && match.path.length > 1 ? match.path.slice(0, -1) : match.path;
  return (
    <List.Item
      title={basename(path) || path}
      subtitle={tildify(dirname(path))}
      icon={{ fileIcon: path }}
      accessories={[{ text: String(match.score), tooltip: "Match score" }]}
      quickLook={{ path }}
      actions={
        <ActionPanel>
          <Action.Open title="Open" target={path} />
          <Action.ShowInFinder path={path} />
          <Action.OpenWith path={path} />
          <Action.ToggleQuickLook shortcut={{ modifiers: ["cmd"], key: "y" }} />
          <Action.CopyToClipboard title="Copy Path" content={path} shortcut={{ modifiers: ["cmd", "shift"], key: "c" }} />
          <Action.CopyToClipboard
            title="Copy Name"
            content={basename(path)}
            shortcut={{ modifiers: ["cmd", "shift"], key: "n" }}
          />
        </ActionPanel>
      }
    />
  );
}
