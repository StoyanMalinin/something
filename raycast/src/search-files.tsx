import { Action, ActionPanel, Icon, LaunchType, List, launchCommand } from "@raycast/api";
import { basename, dirname } from "node:path";
import { useEffect, useState } from "react";
import { Match, describe, isConnectionError, search, tildify } from "./daemon";
import { SetupHelp } from "./setup-help";

const configureAction = (
  <Action
    title="Configure Search…"
    icon={Icon.Gear}
    shortcut={{ modifiers: ["cmd"], key: "," }}
    onAction={() => launchCommand({ name: "configure", type: LaunchType.UserInitiated })}
  />
);

function formatLatency(ms: number): string {
  return `${ms < 10 ? ms.toFixed(1) : Math.round(ms)} ms`;
}

export default function Command() {
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
    search(text, controller.signal)
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
  }, [text]);

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
        <List.EmptyView
          icon={Icon.MagnifyingGlass}
          title="Type to search every indexed file"
          actions={<ActionPanel>{configureAction}</ActionPanel>}
        />
      ) : matches.length === 0 && latencyMs !== undefined ? (
        <List.EmptyView
          icon={Icon.MagnifyingGlass}
          title="No matches"
          description={formatLatency(latencyMs)}
          actions={<ActionPanel>{configureAction}</ActionPanel>}
        />
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
          {configureAction}
        </ActionPanel>
      }
    />
  );
}
