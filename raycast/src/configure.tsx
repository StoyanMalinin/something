import {
  Action,
  ActionPanel,
  Color,
  Form,
  Icon,
  List,
  Toast,
  showToast,
  useNavigation,
} from "@raycast/api";
import { basename, dirname } from "node:path";
import { useCallback, useEffect, useState } from "react";
import {
  DaemonConfig,
  configPath,
  describe,
  expandHome,
  isConnectionError,
  isIndexing,
  readConfig,
  setConfig,
  tildify,
} from "./daemon";
import { SetupHelp } from "./setup-help";

const MAX_LIMIT = 1000;

/** A bare name has no slash: the daemon leaves out everything with that name. */
function isName(entry: string): boolean {
  return !entry.includes("/") && !entry.startsWith("~");
}

function unique(items: string[]): string[] {
  return [...new Set(items)];
}

export default function Command() {
  const [config, setConfigState] = useState<DaemonConfig>();
  const [loadError, setLoadError] = useState<string>();
  const [isLoading, setIsLoading] = useState(true);
  const [reindexing, setReindexing] = useState(false);

  // The daemon alone writes the file, so this is always what it saved last
  const reload = useCallback(() => {
    try {
      setConfigState(readConfig());
      setLoadError(undefined);
    } catch (e) {
      setLoadError(describe(e));
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(reload, [reload]);

  // After a change to what is indexed, watch the daemon rebuild it
  useEffect(() => {
    if (!reindexing) return;
    let cancelled = false;
    const timer = setInterval(async () => {
      try {
        if (await isIndexing()) return;
      } catch {
        // Gone, or restarting: nothing left to wait for
      }
      if (cancelled) return;
      setReindexing(false);
      showToast({ style: Toast.Style.Success, title: "Index is up to date" });
    }, 1000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [reindexing]);

  /** Sends `change` to the daemon. Resolves to whether it was accepted. */
  async function apply(change: Partial<DaemonConfig>, done: string): Promise<boolean> {
    const toast = await showToast({ style: Toast.Style.Animated, title: "Saving…" });
    try {
      const before = config;
      const saved = await setConfig(change);
      reload();
      const scopeChanged =
        before === undefined ||
        before.include.join("\n") !== saved.include.join("\n") ||
        before.exclude.join("\n") !== saved.exclude.join("\n");
      toast.style = Toast.Style.Success;
      toast.title = done;
      if (scopeChanged) {
        toast.message = "Reindexing…";
        setReindexing(true);
      }
      return true;
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = isConnectionError(e) ? "Can't reach something-daemon" : "Not saved";
      toast.message = isConnectionError(e) ? "Start it to change the config" : describe(e);
      return false;
    }
  }

  const addInclude = (paths: string[]) =>
    apply({ include: unique([...(config?.include ?? []), ...paths]) }, "Folder added");
  const addExclude = (entries: string[]) =>
    apply({ exclude: unique([...(config?.exclude ?? []), ...entries]) }, "Exclusion added");
  const removeInclude = (path: string) =>
    apply({ include: (config?.include ?? []).filter((p) => p !== path) }, "Folder removed");
  const removeExclude = (entry: string) =>
    apply({ exclude: (config?.exclude ?? []).filter((p) => p !== entry) }, "Exclusion removed");
  const setLimit = (limit: number) => apply({ limit }, "Results per query saved");

  // The first action is what Enter does, so each section leads with its own add action
  const sharedActions = (first: "include" | "exclude") => {
    const include = (
      <Action.Push
        key="include"
        title="Add Folder to Index…"
        icon={Icon.PlusCircle}
        shortcut={{ modifiers: ["cmd"], key: "n" }}
        target={<AddFolderForm onSubmit={addInclude} />}
      />
    );
    const exclude = (
      <Action.Push
        key="exclude"
        title="Exclude Path or Name…"
        icon={Icon.MinusCircle}
        shortcut={{ modifiers: ["cmd", "shift"], key: "n" }}
        target={<ExcludeForm onSubmit={addExclude} />}
      />
    );
    return (
      <>
        {first === "include" ? [include, exclude] : [exclude, include]}
        <Action.Push
          title="Set Results per Query…"
          icon={Icon.List}
          shortcut={{ modifiers: ["cmd"], key: "l" }}
          target={<LimitForm current={config?.limit ?? 50} onSubmit={setLimit} />}
        />
      </>
    );
  };

  if (!isLoading && config === undefined) {
    return (
      <List navigationTitle="Configure Search">
        {loadError ? (
          <List.EmptyView icon={Icon.ExclamationMark} title="Can't read the config" description={loadError} />
        ) : (
          <SetupHelp />
        )}
      </List>
    );
  }

  return (
    <List isLoading={isLoading || reindexing} navigationTitle="Configure Search" searchBarPlaceholder="Filter settings…">
      <List.Section title="Indexed Folders" subtitle={reindexing ? "Reindexing…" : undefined}>
        {config?.include.map((path) => (
          <List.Item
            key={path}
            icon={{ fileIcon: path }}
            title={basename(path) || path}
            subtitle={tildify(dirname(path))}
            accessories={[{ icon: Icon.CheckCircle, tooltip: "Indexed" }]}
            actions={
              <ActionPanel>
                <ActionPanel.Section>
                  <Action.ShowInFinder path={path} />
                  <Action.CopyToClipboard title="Copy Path" content={path} />
                  <Action
                    title="Stop Indexing This Folder"
                    icon={Icon.Trash}
                    style={Action.Style.Destructive}
                    shortcut={{ modifiers: ["ctrl"], key: "x" }}
                    onAction={() => removeInclude(path)}
                  />
                </ActionPanel.Section>
                <ActionPanel.Section>{sharedActions("include")}</ActionPanel.Section>
              </ActionPanel>
            }
          />
        ))}
        <List.Item
          icon={{ source: Icon.PlusCircle, tintColor: Color.Green }}
          title="Add Folder to Index…"
          actions={<ActionPanel>{sharedActions("include")}</ActionPanel>}
        />
      </List.Section>

      <List.Section title="Left Out" subtitle="Paths, or names anywhere">
        {config?.exclude.map((entry) => (
          <List.Item
            key={entry}
            icon={isName(entry) ? { source: Icon.Tag, tintColor: Color.Orange } : { fileIcon: entry }}
            title={isName(entry) ? entry : basename(entry) || entry}
            subtitle={isName(entry) ? "Any file or folder with this name" : tildify(dirname(entry))}
            accessories={[{ tag: isName(entry) ? "name" : "path" }]}
            actions={
              <ActionPanel>
                <ActionPanel.Section>
                  {!isName(entry) && <Action.ShowInFinder path={entry} />}
                  <Action.CopyToClipboard title="Copy" content={entry} />
                  <Action
                    title="Include Again"
                    icon={Icon.Trash}
                    style={Action.Style.Destructive}
                    shortcut={{ modifiers: ["ctrl"], key: "x" }}
                    onAction={() => removeExclude(entry)}
                  />
                </ActionPanel.Section>
                <ActionPanel.Section>{sharedActions("exclude")}</ActionPanel.Section>
              </ActionPanel>
            }
          />
        ))}
        <List.Item
          icon={{ source: Icon.PlusCircle, tintColor: Color.Red }}
          title="Exclude Path or Name…"
          actions={<ActionPanel>{sharedActions("exclude")}</ActionPanel>}
        />
      </List.Section>

      <List.Section title="Results">
        <List.Item
          icon={Icon.List}
          title="Results per query"
          accessories={[{ text: String(config?.limit ?? "…") }]}
          actions={
            <ActionPanel>
              <Action.Push
                title="Set Results per Query…"
                icon={Icon.Pencil}
                target={<LimitForm current={config?.limit ?? 50} onSubmit={setLimit} />}
              />
              <ActionPanel.Section>{sharedActions("include")}</ActionPanel.Section>
            </ActionPanel>
          }
        />
      </List.Section>

      <List.Section title="Config File">
        <List.Item
          icon={Icon.Document}
          title="Managed by the daemon"
          subtitle={tildify(configPath())}
          actions={
            <ActionPanel>
              <Action.ShowInFinder path={configPath()} />
              <Action.CopyToClipboard title="Copy Path" content={configPath()} />
            </ActionPanel>
          }
        />
      </List.Section>
    </List>
  );
}

/** Runs `submit`; the form closes when the daemon accepts, and stays open to be fixed when not. */
function useSubmit<T>(submit: (values: T) => Promise<boolean>) {
  const { pop } = useNavigation();
  return async (values: T) => {
    if (await submit(values)) pop();
  };
}

function AddFolderForm({ onSubmit }: { onSubmit: (paths: string[]) => Promise<boolean> }) {
  const [pathError, setPathError] = useState<string>();
  const handle = useSubmit(async (values: { folders: string[]; typed: string }) => {
    const paths = [...values.folders, ...(values.typed.trim() ? [expandHome(values.typed.trim())] : [])];
    if (paths.length === 0) {
      setPathError("Choose a folder or type a path");
      return false;
    }
    return onSubmit(paths);
  });

  return (
    <Form
      navigationTitle="Add Folder to Index"
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Index Folder" onSubmit={handle} />
        </ActionPanel>
      }
    >
      <Form.FilePicker
        id="folders"
        title="Folders"
        canChooseDirectories
        canChooseFiles={false}
        allowMultipleSelection
        error={pathError}
        onChange={() => setPathError(undefined)}
      />
      <Form.TextField
        id="typed"
        title="Or a Path"
        placeholder="~/code"
        info="Folders under it are indexed and watched for changes. Anything already indexed is kept."
        onChange={() => setPathError(undefined)}
      />
    </Form>
  );
}

function ExcludeForm({ onSubmit }: { onSubmit: (entries: string[]) => Promise<boolean> }) {
  const [error, setError] = useState<string>();
  const handle = useSubmit(async (values: { picked: string[]; typed: string }) => {
    const typed = values.typed.trim();
    const entries = [...values.picked, ...(typed ? [typed.includes("/") || typed.startsWith("~") ? expandHome(typed) : typed] : [])];
    if (entries.length === 0) {
      setError("Choose something, or type a path or name");
      return false;
    }
    return onSubmit(entries);
  });

  return (
    <Form
      navigationTitle="Exclude from the Index"
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Exclude" onSubmit={handle} />
        </ActionPanel>
      }
    >
      <Form.FilePicker
        id="picked"
        title="Files or Folders"
        allowMultipleSelection
        canChooseDirectories
        showHiddenFiles
        error={error}
        onChange={() => setError(undefined)}
      />
      <Form.TextField
        id="typed"
        title="Or a Name or Path"
        placeholder="node_modules"
        info="A name with no slash, like node_modules or .git, leaves out every file and folder called that. A path leaves out just that one, with everything under it."
        onChange={() => setError(undefined)}
      />
    </Form>
  );
}

function LimitForm({ current, onSubmit }: { current: number; onSubmit: (limit: number) => Promise<boolean> }) {
  const [error, setError] = useState<string>();
  const [value, setValue] = useState(String(current));

  const check = (text: string): number | undefined => {
    const n = Number(text.trim());
    if (!Number.isInteger(n) || n < 1 || n > MAX_LIMIT) {
      setError(`A whole number from 1 to ${MAX_LIMIT}`);
      return undefined;
    }
    setError(undefined);
    return n;
  };

  const handle = useSubmit(async () => {
    const n = check(value);
    return n === undefined ? false : onSubmit(n);
  });

  return (
    <Form
      navigationTitle="Results per Query"
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Save" onSubmit={handle} />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="limit"
        title="Results"
        value={value}
        error={error}
        info={`How many matches the daemon returns for a query, up to ${MAX_LIMIT}.`}
        onChange={(text) => {
          setValue(text);
          if (error) check(text);
        }}
        onBlur={(event) => check(event.target.value ?? "")}
      />
    </Form>
  );
}
