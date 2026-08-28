import { useEffect, useState } from "react";
import fs from "fs";
import {
  Action,
  ActionPanel,
  Alert,
  Color,
  Detail,
  Icon,
  List,
  Toast,
  confirmAlert,
  showToast,
  Keyboard,
} from "@raycast/api";
import {
  Task,
  TaskStatus,
  ageString,
  errorMessage,
  deleteTask,
  firstLine,
  readTasks,
  requeueTask,
  resolveDataDir,
  resolveQtPath,
  resumeTask,
  tailLines,
  taskLogPath,
  workspaceDir,
} from "./lib";

type StatusFilter = "all" | "blocked" | "running" | "done" | "failed";

function statusIcon(status: TaskStatus): { source: Icon; tintColor: Color } {
  switch (status) {
    case "done":
      return { source: Icon.CheckCircle, tintColor: Color.Green };
    case "failed":
      return { source: Icon.XMarkCircle, tintColor: Color.Red };
    case "timeout":
      return { source: Icon.Clock, tintColor: Color.Orange };
    case "running":
      return { source: Icon.CircleProgress, tintColor: Color.Blue };
    case "blocked":
      return { source: Icon.Lock, tintColor: Color.Red };
    case "queued":
    default:
      return { source: Icon.Circle, tintColor: Color.SecondaryText };
  }
}

function matchesFilter(task: Task, filter: StatusFilter): boolean {
  if (filter === "all") return true;
  if (filter === "failed")
    return task.status === "failed" || task.status === "timeout";
  return task.status === filter;
}

export default function Command() {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all");
  const dataDir = resolveDataDir();
  const qtPath = resolveQtPath();

  function refresh() {
    setIsLoading(true);
    try {
      setTasks(readTasks(dataDir, 50));
    } finally {
      setIsLoading(false);
    }
  }

  useEffect(() => {
    refresh();
  }, []);

  async function handleResume(task: Task) {
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Resuming…",
      message: task.id,
    });
    try {
      await resumeTask(qtPath, task.id);
      toast.style = Toast.Style.Success;
      toast.title = "Resumed";
      toast.message = task.id;
    } catch (err) {
      toast.style = Toast.Style.Failure;
      toast.title = "Resume failed";
      toast.message = errorMessage(err);
    }
  }

  async function handleRerun(task: Task) {
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Queuing…",
      message: task.prompt,
    });
    try {
      const defaultWorkspace = workspaceDir(dataDir);
      const dir =
        task.run_cwd && task.run_cwd !== defaultWorkspace
          ? task.run_cwd
          : undefined;
      const id = await requeueTask(qtPath, task.prompt, dir);
      toast.style = Toast.Style.Success;
      toast.title = "Queued";
      toast.message = id;
      refresh();
    } catch (err) {
      toast.style = Toast.Style.Failure;
      toast.title = "Queue failed";
      toast.message = errorMessage(err);
    }
  }

  async function handleDelete(task: Task) {
    const confirmed = await confirmAlert({
      title: "Delete this quicktask?",
      message: task.prompt,
      primaryAction: { title: "Delete", style: Alert.ActionStyle.Destructive },
    });
    if (!confirmed) return;
    try {
      deleteTask(dataDir, task.id);
      refresh();
      await showToast({
        style: Toast.Style.Success,
        title: "Deleted",
        message: task.id,
      });
    } catch (err) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Delete failed",
        message: errorMessage(err),
      });
    }
  }

  function renderItem(task: Task) {
    const icon = statusIcon(task.status);
    const logPath = taskLogPath(dataDir, task.id);
    const logExists = fs.existsSync(logPath);

    return (
      <List.Item
        key={task.id}
        icon={icon}
        title={firstLine(task.prompt) || task.id}
        subtitle={firstLine(task.result)}
        keywords={[task.id]}
        accessories={[{ text: ageString(task.created) }, { tag: task.id }]}
        actions={
          <ActionPanel>
            {task.session_id && (
              <Action
                title="Resume in Terminal"
                icon={Icon.Terminal}
                onAction={() => handleResume(task)}
              />
            )}
            <Action.Push
              title="View Log"
              icon={Icon.Text}
              shortcut={{ modifiers: ["cmd"], key: "l" }}
              target={<TaskDetail task={task} dataDir={dataDir} />}
            />
            {task.session_id && (
              <Action.CopyToClipboard
                title="Copy Resume Command"
                icon={Icon.Clipboard}
                content={`claude --resume ${task.session_id}`}
                shortcut={Keyboard.Shortcut.Common.Copy}
              />
            )}
            {task.session_id && (
              <Action.CopyToClipboard
                title="Copy Session ID"
                icon={Icon.Key}
                content={task.session_id}
                shortcut={Keyboard.Shortcut.Common.Duplicate}
              />
            )}
            <Action.CopyToClipboard
              title="Copy Task ID"
              icon={Icon.Hashtag}
              content={task.id}
              shortcut={{ modifiers: ["cmd", "shift"], key: "i" }}
            />
            {logExists && (
              <Action.Open
                title="Open Log File"
                icon={Icon.Finder}
                target={logPath}
                shortcut={Keyboard.Shortcut.Common.OpenWith}
              />
            )}
            <Action
              title="Re-Run Task"
              icon={Icon.ArrowClockwise}
              shortcut={{ modifiers: ["cmd", "shift"], key: "r" }}
              onAction={() => handleRerun(task)}
            />
            <Action
              title="Delete Task"
              icon={Icon.Trash}
              style={Action.Style.Destructive}
              shortcut={{ modifiers: ["ctrl"], key: "x" }}
              onAction={() => handleDelete(task)}
            />
          </ActionPanel>
        }
      />
    );
  }

  const filtered = tasks.filter((t) => matchesFilter(t, statusFilter));

  return (
    <List
      isLoading={isLoading}
      searchBarAccessory={
        <List.Dropdown
          tooltip="Filter by status"
          value={statusFilter}
          onChange={(v) => setStatusFilter(v as StatusFilter)}
        >
          <List.Dropdown.Item title="All" value="all" />
          <List.Dropdown.Item title="Blocked" value="blocked" />
          <List.Dropdown.Item title="Running" value="running" />
          <List.Dropdown.Item title="Done" value="done" />
          <List.Dropdown.Item title="Failed" value="failed" />
        </List.Dropdown>
      }
    >
      {tasks.length === 0 ? (
        <List.EmptyView
          icon={Icon.Bolt}
          title="No quicktasks yet"
          description='Fire one with "New Quick Task", or run qt "do a thing" in a terminal.'
        />
      ) : statusFilter === "all" ? (
        <>
          <List.Section
            title="Blocked"
            subtitle={String(
              filtered.filter((t) => t.status === "blocked").length,
            )}
          >
            {filtered.filter((t) => t.status === "blocked").map(renderItem)}
          </List.Section>
          <List.Section
            title="Recent"
            subtitle={String(
              filtered.filter((t) => t.status !== "blocked").length,
            )}
          >
            {filtered.filter((t) => t.status !== "blocked").map(renderItem)}
          </List.Section>
        </>
      ) : (
        <List.Section title="Tasks" subtitle={String(filtered.length)}>
          {filtered.map(renderItem)}
        </List.Section>
      )}
    </List>
  );
}

function TaskDetail({ task, dataDir }: { task: Task; dataDir: string }) {
  const logPath = taskLogPath(dataDir, task.id);
  const logTail = tailLines(logPath, 200);
  const markdown = [
    "## Result",
    "",
    task.result?.trim() || "_(no result)_",
    "",
    "## Log (tail)",
    "",
    "```",
    logTail || "(no log file)",
    "```",
  ].join("\n");

  const deniedTools = (task.denials ?? []).map((d) => d.tool_name || "?");

  return (
    <Detail
      markdown={markdown}
      navigationTitle={task.id}
      metadata={
        <Detail.Metadata>
          <Detail.Metadata.Label title="Status" text={task.status} />
          <Detail.Metadata.Label title="Created" text={task.created} />
          <Detail.Metadata.Label title="Started" text={task.started || "-"} />
          <Detail.Metadata.Label title="Finished" text={task.finished || "-"} />
          <Detail.Metadata.Label
            title="Run Directory"
            text={task.run_cwd || "-"}
          />
          <Detail.Metadata.Label title="Model" text={task.model || "default"} />
          <Detail.Metadata.Label
            title="Cost"
            text={
              typeof task.cost_usd === "number"
                ? `$${task.cost_usd.toFixed(4)}`
                : "-"
            }
          />
          <Detail.Metadata.Label
            title="Session ID"
            text={task.session_id || "none"}
          />
          {deniedTools.length > 0 && (
            <>
              <Detail.Metadata.Separator />
              <Detail.Metadata.TagList title="Denied Tools">
                {deniedTools.map((name, i) => (
                  <Detail.Metadata.TagList.Item
                    key={`${name}-${i}`}
                    text={name}
                    color={Color.Red}
                  />
                ))}
              </Detail.Metadata.TagList>
            </>
          )}
        </Detail.Metadata>
      }
    />
  );
}
