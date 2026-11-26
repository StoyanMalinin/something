import { Action, ActionPanel, Icon, List } from "@raycast/api";

const REPO_URL = "https://github.com/StoyanMalinin/something";
export const BREW_FORMULA = "StoyanMalinin/tap/something-daemon";

const SETUP_STEPS = [
  { title: "Start the daemon", command: `brew services start ${BREW_FORMULA}`, icon: Icon.Play },
  { title: "Install the daemon", command: `brew install ${BREW_FORMULA}`, icon: Icon.Download },
  { title: "Install, building from source", command: `brew install --build-from-source ${BREW_FORMULA}`, icon: Icon.Hammer },
];

export function SetupHelp() {
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
