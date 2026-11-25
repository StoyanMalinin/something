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

function describe(error: unknown): string {
  const code = (error as NodeJS.ErrnoException)?.code;
  if (code === "ENOENT" || code === "ECONNREFUSED") {
    return "The daemon is not running (or still indexing). Start it with: zig build run-daemon -Doptimize=ReleaseFast";
  }
  return error instanceof Error ? error.message : String(error);
}

export default function Command() {
  const prefs = getPreferenceValues<Preferences>();
  const socketPath = expandHome(prefs.socketPath || "~/Library/Caches/something/daemon.sock");
  const limit = Math.max(1, parseInt(prefs.limit || "50", 10) || 50);

  const [text, setText] = useState("");
  const [matches, setMatches] = useState<Match[]>([]);
  const [error, setError] = useState<string>();
  const [isLoading, setIsLoading] = useState(false);

  useEffect(() => {
    if (text.trim() === "") {
      setMatches([]);
      setError(undefined);
      return;
    }
    // A newer keystroke cancels the query still in flight
    const controller = new AbortController();
    setIsLoading(true);
    query(socketPath, limit, text, controller.signal)
      .then((m) => {
        setMatches(m);
        setError(undefined);
      })
      .catch((e) => {
        if (!controller.signal.aborted) setError(describe(e));
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
      {error ? (
        <List.EmptyView icon={Icon.ExclamationMark} title="Can't reach something-daemon" description={error} />
      ) : text.trim() === "" ? (
        <List.EmptyView icon={Icon.MagnifyingGlass} title="Type to search every indexed file" />
      ) : (
        matches.map((m) => <MatchItem key={m.path} match={m} />)
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
