/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** qt Binary Path - Path to the qt binary */
  "qtPath": string,
  /** Quicktasks Data Directory - Directory holding quicktasks state (tasks, logs) */
  "dataDir": string
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `quick-tasks` command */
  export type QuickTasks = ExtensionPreferences & {}
  /** Preferences accessible in the `new-quick-task` command */
  export type NewQuickTask = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `quick-tasks` command */
  export type QuickTasks = {}
  /** Arguments passed to the `new-quick-task` command */
  export type NewQuickTask = {
  /** what should claude do? */
  "prompt": string,
  /** run dir (optional) */
  "dir": string
}
}

