import { LaunchProps, showHUD, showToast, Toast } from "@raycast/api";
import { errorMessage, requeueTask, resolveQtPath } from "./lib";

interface Arguments {
  prompt: string;
  dir?: string;
}

export default async function Command(
  props: LaunchProps<{ arguments: Arguments }>,
) {
  const { prompt, dir } = props.arguments;
  const qtPath = resolveQtPath();
  try {
    const id = await requeueTask(qtPath, prompt, dir?.trim() || undefined);
    await showHUD(`Queued ${id}`);
  } catch (err) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Queue failed",
      message: errorMessage(err),
    });
  }
}
