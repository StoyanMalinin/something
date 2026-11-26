import { Action, ActionPanel, Color, Icon, List } from "@raycast/api";
import { DaemonStatus, NEWEST_PROTOCOL_VERSION, isOutdated, tildify } from "./daemon";
import { BREW_FORMULA } from "./setup-help";

const UPGRADE_COMMAND = `brew upgrade ${BREW_FORMULA} && brew services restart ${BREW_FORMULA}`;
const FULL_DISK_ACCESS_URL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles";

const warningIcon = { source: Icon.Warning, tintColor: Color.Yellow };

export function hasWarnings(status: DaemonStatus | undefined): boolean {
  return status !== undefined && (isOutdated(status.version) || status.issues !== undefined);
}

function plural(n: number, one: string, many: string): string {
  return `${n} ${n === 1 ? one : many}`;
}

/**
 * What the daemon is unhappy about, as rows above the results: an old daemon that should be
 * upgraded and restarted, and files it could not index (usually a missing Full Disk Access).
 * Renders nothing when all is well.
 */
export function WarningsSection({ status }: { status: DaemonStatus | undefined }) {
  if (!status || !hasWarnings(status)) return null;
  const { issues } = status;

  return (
    <List.Section title="Warnings">
      {isOutdated(status.version) && (
        <List.Item
          icon={warningIcon}
          title="something-daemon is out of date"
          subtitle="Upgrade and restart it to get the latest fixes and warnings"
          accessories={[{ tag: `v${status.version} → v${NEWEST_PROTOCOL_VERSION}` }]}
          actions={
            <ActionPanel>
              <Action.CopyToClipboard title="Copy Upgrade Command" content={UPGRADE_COMMAND} />
            </ActionPanel>
          }
        />
      )}
      {issues && issues.unreadable > 0 && (
        <List.Item
          icon={warningIcon}
          title={`${plural(issues.unreadable, "folder", "folders")} can't be read, so their files are missing`}
          subtitle={
            "Grant Full Disk Access to something-daemon" +
            (issues.samples.length > 0 ? `, e.g. ${tildify(issues.samples[0])}` : "")
          }
          actions={
            <ActionPanel>
              <Action.Open title="Open Full Disk Access Settings" target={FULL_DISK_ACCESS_URL} />
              {issues.samples.length > 0 && (
                <Action.CopyToClipboard title="Copy Unreadable Folders" content={issues.samples.join("\n")} />
              )}
            </ActionPanel>
          }
        />
      )}
      {issues && issues.failed > 0 && (
        <List.Item
          icon={warningIcon}
          title={`${plural(issues.failed, "error", "errors")} while indexing`}
          subtitle="Some results may be missing or out of date; see the daemon's log"
        />
      )}
    </List.Section>
  );
}
