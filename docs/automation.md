# Local scripts and extensions

Scripts and extensions run as local subprocesses with your user privileges. They can access files and the network. Process isolation protects launcher responsiveness; it does not sandbox code or enforce metadata permissions. Review every executable, argument and source file before enabling it. No marketplace or unattended installation is included.

## Scripts

In Settings, add a title, description and absolute executable/runtime path. Choose a local executable using the file picker. Enter one literal argument per line; quotes and shell operators are not parsed. For an interpreted script, choose its runtime (for example `/bin/sh`) and use the script's absolute path as the first argument. The [hello template](../examples/automation/hello-script.sh) accepts an optional greeting name as its next argument.

Scripts start disabled, including scripts imported with portable configuration. Enable each one after review. Run enabled scripts from the launcher or assign a command shortcut. Execution occurs off the UI thread. A separate output window shows bounded output and a Cancel button. Use ⌘K → Run with Input to append literal invocation arguments (one per line). The default timeout is 10 seconds, configurable up to 300 seconds. Combined stdout and stderr are limited to 256 KiB; exceeding a limit terminates the subprocess. Missing executables, exit statuses, timeouts and cancellation produce explicit errors. Disable or remove a running command to cancel it.

Arguments are passed directly to the subprocess, never interpolated into a shell command. Choosing a shell runtime is an explicit choice to run a script. Do not store secrets in descriptions, paths, arguments or configuration. The execution environment contains only a standard system PATH and UTF-8 LANG; it does not inherit environment credentials. Output is transient and never logged or written to configuration, but can contain anything a script emits. Cancellation, timeout and completion terminate the invocation’s dedicated process group, including ordinary child processes. Trusted code can deliberately detach children from this group; this lifecycle boundary is not a security sandbox.

## Extension runtime checkpoint

The initial runtime is an executable subprocess exchanging version 1 JSON over stdin/stdout, rather than a JavaScript or React runtime. It reuses the script execution boundary, has no in-process plugin loading, and renders lists and details using native SwiftUI controls. Each explicit search or action starts a fresh subprocess. Slow or crashed extensions return an error independently of built-in search. Each invocation has a five-second timeout, 256 KiB combined output limit, and at most 100 results with 20 actions per result.

Import an extension JSON manifest in Settings. Installation and updates always disable it for review. A manifest declares `id`, `name`, `description`, `apiVersion: 1`, absolute `executable`, literal `arguments`, non-secret `preferences`, and `enabled`. Each preference has `id`, `title` and `defaultValue` strings. Enable, disable and remove controls are available. Removal also removes preferences. Preferences are global plain-text settings and are excluded from portable exports. Credential storage and secret preferences are unsupported; an extension needing credentials must manage them outside Kebloop, such as its own Keychain integration. Do not enter credentials in Kebloop preferences.

The [example manifest](../examples/automation/greeting-manifest.json) runs the [greeting extension](../examples/automation/greeting-extension.swift) using the system Swift interpreter (requires developer tools). Replace the sample's absolute source path before importing. It supplies results, an action, a detail view and a greeting preference without modifying launcher code.

The complete request is one JSON document on stdin:

```json
{"apiVersion":1,"operation":"search","query":"Warsaw","resultID":null,"actionID":null,"preferences":{"prefix":"Hello"}}
```

`operation` is `search` or `action`. An action request includes the selected stable `resultID` and `actionID`; only actions present in the last response can be invoked. Preferences contain only declared fields. Write one JSON response to stdout, using stderr only for diagnostics:

```json
{"apiVersion":1,"results":[{"id":"greeting","title":"Hello, Warsaw!","subtitle":"Example","detail":"Native detail text","actions":[{"id":"greet","title":"Greet"}]}],"message":""}
```

`subtitle`, `detail` and `message` can be omitted. Each result and action needs a unique nonempty ID and title. Incompatible versions, malformed JSON and duplicate identifiers are rejected. Actions execute inside the same reviewed extension; Kebloop does not interpret response strings as commands or URLs. Extensions may return updated results and a message after an action. Lifecycle and output validation tests cover review gates, persistence, cancellation, argument handling, execution limits and response errors. Native VoiceOver and permission prompt checks remain manual release verification.
