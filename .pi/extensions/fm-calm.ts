// Firstmate's home-persistent Pi transcript presentation toggle.
//
// Verified against Pi 0.81.1, 0.82.0, and 0.84.4, which expose built-in ToolDefinitions, per-slot
// renderers, renderShell: "self", session_start replacement reasons, agent_start and
// agent_settled, ExtensionUIContext.setToolsExpanded(), setWorkingVisible(), setWidget()
// with a disposable component factory, and setHiddenThinkingLabel().
// ./lib/fm-calm-working-ship.ts owns the animated working presentation this file
// installs. The focused tests pin those assumptions but never reject a
// newer Pi solely for its version. The collapsed-thinking and operational-user
// presentation adapters probe the exact API they patch and degrade independently with a
// diagnostic (see installCalmPresentationAdapter below) if a future Pi removes it; Pi
// still exposes no global renderer for arbitrary built-in or custom rows.
// docs/configuration.md owns the home-local Calm preference contract.
//
// Pi has one first-registration-wins ToolDefinition per tool name, with no merge or
// unregister operation. Keep Calm-off registration empty; keep Calm-on load-time
// registration synchronous because restored rows capture the registry before
// session_start; and collision-check only the later first-activation path, when
// getAllTools() is reliable. docs/calm-mode-feasibility.md owns the Pi-source evidence
// and docs/calm.md owns the user-facing behavior and non-retroactive first-toggle bound.
import { randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ExtensionAPI,
  ExtensionUIContext,
  ToolDefinition,
  ToolInfo,
  ToolRenderResultOptions,
} from "@earendil-works/pi-coding-agent";
import {
  createBashToolDefinition,
  createEditToolDefinition,
  createFindToolDefinition,
  createGrepToolDefinition,
  createLsToolDefinition,
  createReadToolDefinition,
  createWriteToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { Box, Container, getKeybindings, type Component } from "@earendil-works/pi-tui";
import type { TSchema } from "typebox";
import { installCalmAssistantLayout } from "./lib/fm-calm-assistant-layout.ts";
import { installCalmOperationalUserLayout } from "./lib/fm-calm-operational-user-layout.ts";
import {
  CALM_WORKING_SHIP_WIDGET_KEY,
  createCalmWorkingShipAnimation,
  createCalmWorkingShipWidget,
} from "./lib/fm-calm-working-ship.ts";
import {
  calmPresentationHides,
  calmPresentationIsActive,
  FIRSTMATE_CALM_PRESENTATION_EVENT,
  registerFirstmateSyntheticPresentation,
  setCalmPresentation,
  setCalmStockExportRendering,
} from "./lib/fm-calm-visibility.ts";

type DefinitionFactory<TParams extends TSchema, TDetails, TState> = (
  cwd: string,
) => ToolDefinition<TParams, TDetails, TState>;

type RenderContext<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderCall"]>
>[2];

type RenderArgs<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderCall"]>
>[0];

type RenderTheme<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderCall"]>
>[1];

type RenderResult<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderResult"]>
>[0];

type StandardShellState = {
  shell?: Box;
  call?: Component;
  result?: Component;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");

// Resolves symlinks before comparing tool-ownership identity below: sourceInfo.path
// values come from independent path-resolution code paths (this module's own
// import.meta.url vs. Pi's extension loader), and macOS alone symlinks /tmp and /var
// to /private/..., so lexical string comparison alone spuriously reads a symlinked
// self-path as a foreign one. Falls back to the raw path for synthetic, non-file
// sourceInfo paths such as "<builtin:read>" or "<inline>", which realpathSync rejects.
const realpathOrSelf = (path: string): string => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};
const extensionRealFile = realpathOrSelf(extensionFile);

// Each presentation adapter probes the exact Pi API it patches. If a future Pi removes
// that API, only the affected adapter degrades; the rest of Calm keeps working.
function installCalmPresentationAdapter(name: string, install: () => void): void {
  try {
    install();
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    console.error(`Firstmate Calm: ${name} presentation adapter unavailable, skipping. ${reason}`);
  }
}

// Matches Pi's own interactive-mode getPathCommandArgument("/export") exactly, so a
// quoted or bare export path is parsed the same way Pi itself parses it.
const parseExportCommandPath = (input: string): string | undefined => {
  const command = "/export";
  if (input === command) return undefined;
  if (!input.startsWith(`${command} `)) return undefined;
  const argsString = input.slice(command.length + 1).trimStart();
  if (!argsString) return undefined;
  const firstChar = argsString[0];
  if (firstChar === '"' || firstChar === "'") {
    const closingQuoteIndex = argsString.indexOf(firstChar, 1);
    return closingQuoteIndex < 0 ? undefined : argsString.slice(1, closingQuoteIndex);
  }
  const firstWhitespaceIndex = argsString.search(/\s/);
  return firstWhitespaceIndex < 0 ? argsString : argsString.slice(0, firstWhitespaceIndex);
};

// Since Pi 0.99.1 the exported HTML's own client-side script keeps every custom_message
// entry in the "messages" panel, including one Firstmate marked display: false, showing
// it as CSS-hidden-but-present with a "Show hidden messages" toggle (H key) instead of
// omitting it as older Pi did. That toggle is a legitimate Pi feature, but it reopens the
// Calm conversation boundary for exported HTML: a viewer could reveal Firstmate's
// operational/synthetic envelopes that were never meant to leave the terminal.
// Firstmate keeps those entries in the exported session data on purpose (captured above,
// verified by the "did not persist synthetic provenance" check) so it cannot special-case
// Pi's inline renderer without depending on its exact source text, which is exactly the
// kind of internal-implementation-byte dependency that broke this file's Calm-off
// ToolExecutionComponent rendering in the same Pi upgrade. Instead this appends one small,
// self-contained script that runs after Pi's own inline script (script tags execute in
// document order) and removes any "#messages" descendant whose id matches a hidden
// custom_message entry's id, keyed only off the stable entry-id DOM convention
// (id="entry-${entry.id}") both the 0.87.1 and 0.99.1 templates already share. A
// MutationObserver keeps that guarantee across later in-page tree navigation, which
// rebuilds "#messages" from the same session data.
const CALM_EXPORT_BOUNDARY_MARKER = "FM_CALM_EXPORT_BOUNDARY";
const buildCalmExportBoundaryScript = (): string =>
  [
    `<script>`,
    `// ${CALM_EXPORT_BOUNDARY_MARKER}: restore the Calm conversation boundary Pi's own`,
    `// exporter no longer enforces for hidden custom messages (docs/calm.md).`,
    `(function () {`,
    `  try {`,
    `    var dataEl = document.getElementById("session-data");`,
    `    if (!dataEl) return;`,
    `    var raw = JSON.parse(atob(dataEl.textContent.trim()));`,
    `    var entries = (raw.session && raw.session.entries) || raw.entries || [];`,
    `    var hiddenIds = [];`,
    `    entries.forEach(function (entry) {`,
    `      if (entry && entry.type === "custom_message" && entry.display === false) {`,
    `        hiddenIds.push("entry-" + entry.id);`,
    `      }`,
    `    });`,
    `    if (hiddenIds.length === 0) return;`,
    `    function strip() {`,
    `      var messages = document.getElementById("messages");`,
    `      if (!messages) return;`,
    `      hiddenIds.forEach(function (id) {`,
    `        var node = document.getElementById(id);`,
    `        if (node && messages.contains(node)) node.remove();`,
    `      });`,
    `    }`,
    `    strip();`,
    `    var messages = document.getElementById("messages");`,
    `    if (messages) new MutationObserver(strip).observe(messages, { childList: true, subtree: true });`,
    `  } catch (e) {`,
    `    // Best-effort: a redaction failure must never block the export from rendering.`,
    `  }`,
    `})();`,
    `</script>`,
  ].join("\n");

// Pi writes the export asynchronously; poll briefly rather than assume it has already
// landed by the time the caller's setTimeout(0) repaint callback runs.
const waitForExportFile = async (filePath: string, attempts = 40, delayMs = 50): Promise<boolean> => {
  for (let attempt = 0; attempt < attempts; attempt++) {
    if (existsSync(filePath)) return true;
    await new Promise((resolveDelay) => setTimeout(resolveDelay, delayMs));
  }
  return existsSync(filePath);
};

const redactCalmExportBoundary = async (filePath: string): Promise<void> => {
  if (!(await waitForExportFile(filePath))) return;
  let html: string;
  try {
    html = readFileSync(filePath, "utf8");
  } catch {
    return;
  }
  if (!html.includes('id="messages"') || html.includes(CALM_EXPORT_BOUNDARY_MARKER) || !html.includes("</body>")) {
    return;
  }
  try {
    writeFileSync(filePath, html.replace("</body>", `${buildCalmExportBoundaryScript()}\n</body>`));
  } catch {
    // Best-effort: leave the export as Pi wrote it rather than fail the command.
  }
};

export default function (pi: ExtensionAPI) {
  installCalmPresentationAdapter("collapsed-thinking", installCalmAssistantLayout);
  installCalmPresentationAdapter("operational-user-row", installCalmOperationalUserLayout);

  let exportRendering = false;
  let removeTerminalInputHandler: (() => void) | undefined;
  // One logical agent run, tracked from agent_start through agent_settled rather than
  // from turns or tool calls, so the boat never flickers between tool calls, automatic
  // continuations, retries, or compaction that stay inside the same run.
  let agentRunActive = false;
  let workingShipShown = false;
  // One animation instance per extension lifetime. Hiding the working widget freezes
  // this state; the next working period resumes it. session_start resets it so a fresh
  // Pi session starts at the normal initial position. Never module-global.
  const workingShipAnimation = createCalmWorkingShipAnimation();

  // Single owner of Calm's working-row presentation choice. The widget is only created
  // or removed on a real transition, so repeated starts cannot duplicate its timer.
  const applyWorkingPresentation = (
    ui: ExtensionUIContext,
    forceStockVisibility = false,
  ): void => {
    const showShip = agentRunActive && calmPresentationIsActive();
    if (showShip !== workingShipShown) {
      workingShipShown = showShip;
      ui.setWidget(
        CALM_WORKING_SHIP_WIDGET_KEY,
        showShip
          ? (tui) => createCalmWorkingShipWidget(tui, workingShipAnimation)
          : undefined,
      );
      ui.setWorkingVisible(!showShip);
    } else if (forceStockVisibility && !showShip) {
      ui.setWorkingVisible(true);
    }
  };

  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const configDirectory = process.env.FM_CONFIG_OVERRIDE || resolve(fmHome, "config");
  const calmPreferencePath = resolve(configDirectory, "calm");
  // "max" is the legacy value written by the removed third presentation level, whose
  // behavior is now ordinary Calm; a home upgraded from it restores as on rather than
  // dropping to off. docs/configuration.md owns the persisted value schema.
  const loadCalmPreference = (): boolean => {
    let stored: string;
    try {
      stored = readFileSync(calmPreferencePath, "utf8").trim();
    } catch {
      return false;
    }
    return stored === "on" || stored === "max";
  };
  const persistCalmPreference = (active: boolean): void => {
    mkdirSync(dirname(calmPreferencePath), { recursive: true });
    const temporaryPath = `${calmPreferencePath}.${process.pid}.${randomUUID()}.tmp`;
    try {
      writeFileSync(temporaryPath, active ? "on\n" : "off\n", {
        encoding: "utf8",
        flag: "wx",
        mode: 0o600,
      });
      renameSync(temporaryPath, calmPreferencePath);
    } finally {
      rmSync(temporaryPath, { force: true });
    }
  };

  const publishPresentationState = (): void => {
    pi.events.emit(FIRSTMATE_CALM_PRESENTATION_EVENT, {
      active: calmPresentationIsActive(),
      stockExportRendering: exportRendering,
    });
  };

  registerFirstmateSyntheticPresentation(pi);

  // Every on-screen tool row Calm currently presents, keyed by the row-local state Pi
  // hands its render slots, so Calm can repaint exactly those rows without touching
  // Pi's transcript. Pi can re-render a row at any time - the built-in edit row
  // invalidates itself once its diff is ready - so a row can be redrawn during the
  // window where /export forces stock rendering and keep that stock content
  // afterwards. Rows Pi's exporter renders are excluded: those use throwaway state
  // and never appear on screen. Cleared per session lifetime, which rebuilds the rows.
  const calmToolRowRepaints = new Map<object, () => void>();
  const rememberCalmToolRow = (state: object, invalidate: unknown): void => {
    if (exportRendering || typeof invalidate !== "function") return;
    calmToolRowRepaints.set(state, invalidate as () => void);
  };
  const repaintCalmToolRows = (): void => {
    for (const invalidate of calmToolRowRepaints.values()) invalidate();
  };

  function wrapBuiltIn<TParams extends TSchema, TDetails, TState>(
    factory: DefinitionFactory<TParams, TDetails, TState>,
  ): ToolDefinition<TParams, TDetails, TState> {
    const definitions = new Map<string, ToolDefinition<TParams, TDetails, TState>>();
    const definitionFor = (cwd: string): ToolDefinition<TParams, TDetails, TState> => {
      let definition = definitions.get(cwd);
      if (!definition) {
        definition = factory(cwd);
        definitions.set(cwd, definition);
      }
      return definition;
    };

    const original = definitionFor(process.cwd());
    const originalRenderCall = original.renderCall;
    const originalRenderResult = original.renderResult;
    const originalSelfShell = original.renderShell === "self";
    const standardShells = new WeakMap<object, StandardShellState>();

    if (!originalRenderCall || !originalRenderResult) {
      throw new Error(`Firstmate calm mode requires both render slots for Pi built-in tool ${original.name}`);
    }

    const shellStateFor = (
      context: RenderContext<TParams, TDetails, TState>,
    ): StandardShellState => {
      const rowState = context.state as object;
      let shellState = standardShells.get(rowState);
      if (!shellState) {
        shellState = {};
        standardShells.set(rowState, shellState);
      }
      return shellState;
    };

    const refreshStandardShell = (
      state: StandardShellState,
      theme: RenderTheme<TParams, TDetails, TState>,
      context: RenderContext<TParams, TDetails, TState>,
    ): Box => {
      const background = context.isPartial
        ? (text: string) => theme.bg("toolPendingBg", text)
        : context.isError
          ? (text: string) => theme.bg("toolErrorBg", text)
          : (text: string) => theme.bg("toolSuccessBg", text);
      const shell = state.shell ?? new Box(1, 1, background);
      state.shell = shell;
      shell.setBgFn(background);
      shell.clear();
      if (state.call) shell.addChild(state.call);
      if (state.result) shell.addChild(state.result);
      return shell;
    };

    return {
      ...original,
      renderShell: "self",

      async execute(toolCallId, params, signal, onUpdate, ctx) {
        return definitionFor(ctx.cwd).execute(toolCallId, params, signal, onUpdate, ctx);
      },

      renderCall(
        args: RenderArgs<TParams, TDetails, TState>,
        theme: RenderTheme<TParams, TDetails, TState>,
        context: RenderContext<TParams, TDetails, TState>,
      ) {
        rememberCalmToolRow(context.state as object, context.invalidate);
        if (exportRendering) return originalRenderCall(args, theme, context);
        if (calmPresentationHides("assistant-tool-call")) return new Container();
        if (originalSelfShell) return originalRenderCall(args, theme, context);

        const state = shellStateFor(context);
        state.call = originalRenderCall(args, theme, {
          ...context,
          lastComponent: state.call,
        });
        return refreshStandardShell(state, theme, context);
      },

      renderResult(
        result: RenderResult<TParams, TDetails, TState>,
        options: ToolRenderResultOptions,
        theme: RenderTheme<TParams, TDetails, TState>,
        context: RenderContext<TParams, TDetails, TState>,
      ) {
        rememberCalmToolRow(context.state as object, context.invalidate);
        if (exportRendering) return originalRenderResult(result, options, theme, context);
        if (calmPresentationHides("tool-result")) return new Container();
        if (originalSelfShell) return originalRenderResult(result, options, theme, context);

        const state = shellStateFor(context);
        state.result = originalRenderResult(result, options, theme, {
          ...context,
          lastComponent: state.result,
        });
        refreshStandardShell(state, theme, context);
        return new Container();
      },
    };
  }

  // Each wrapBuiltIn() call below has its own concrete TParams/TDetails/TState; the
  // array holding all seven has no single sound instantiation, so it is typed the same
  // way Pi's own ToolDefinition consumers erase this (any, any, any).
  const wrappedBuiltIns: ToolDefinition<any, any, any>[] = [
    wrapBuiltIn(createReadToolDefinition),
    wrapBuiltIn(createBashToolDefinition),
    wrapBuiltIn(createEditToolDefinition),
    wrapBuiltIn(createWriteToolDefinition),
    wrapBuiltIn(createGrepToolDefinition),
    wrapBuiltIn(createFindToolDefinition),
    wrapBuiltIn(createLsToolDefinition),
  ];

  // True once this extension has handled built-in registration for its lifetime:
  // either all seven synchronously at load, or only the uncontested subset during
  // first activation.
  let builtInsRegistered = false;

  // Gate on Calm already being on at load time. This must stay synchronous and
  // unconditional here (see file header): a foreign-claim check is not reachable at
  // this point, while deferral would make restored rows capture the wrong definition.
  // A Calm-off session or reload registers nothing and creates no collision exposure.
  if (loadCalmPreference()) {
    for (const tool of wrappedBuiltIns) pi.registerTool(tool);
    builtInsRegistered = true;
  }

  // Which of the 7 built-ins are currently owned by a different, non-builtin
  // extension. Only safe to call once every extension has finished loading (see file
  // header); never call this during the factory's own synchronous execution above.
  function contestedBuiltIns(): ToolDefinition<any, any, any>[] {
    let registered: ToolInfo[];
    try {
      registered = pi.getAllTools();
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      console.error(`Firstmate Calm: built-in ownership check unavailable, claiming every built-in unconditionally. ${reason}`);
      return [];
    }
    return wrappedBuiltIns.filter((tool) => {
      const owner = registered.find((info) => info.name === tool.name)?.sourceInfo;
      return owner !== undefined && owner.source !== "builtin" && realpathOrSelf(owner.path) !== extensionRealFile;
    });
  }

  // The first time Calm turns on in a session that started off, claim every
  // uncontested built-in and leave each contested tool and its owning extension
  // untouched. Tell the user which built-in Calm could not take over, since Calm's
  // presentation does not apply to it.
  function activateBuiltInsIfNeeded(ui: ExtensionUIContext): void {
    if (builtInsRegistered) return;
    const contested = contestedBuiltIns();
    const contestedNames = new Set(contested.map((tool) => tool.name));
    for (const tool of wrappedBuiltIns) {
      if (!contestedNames.has(tool.name)) pi.registerTool(tool);
    }
    builtInsRegistered = true;
    if (contested.length === 0) return;
    const names = contested.map((tool) => `"${tool.name}"`).join(", ");
    const plural = contested.length > 1;
    ui.notify(
      `Firstmate Calm: the ${names} built-in tool${plural ? "s are" : " is"} already provided by another extension, so Calm may not fully function for ${plural ? "them" : "it"} this session.`,
      "warning",
    );
    for (const tool of contested) {
      console.error(`Firstmate Calm: skipped claiming built-in "${tool.name}" because another extension already owns it.`);
    }
  }

  // Backstop for the one case activateBuiltInsIfNeeded cannot reach: Calm registered
  // unconditionally at load time because it was already on, without any chance to
  // check for a foreign claim first, so it can still silently lose a name to an
  // earlier-loaded extension. Runs on every session_start reason because a reload
  // rebuilds every extension's registrations from scratch, so last session's clean
  // bill of health does not carry over.
  function reportBuiltInLosses(): void {
    if (!builtInsRegistered) return;
    let registered: ToolInfo[];
    try {
      registered = pi.getAllTools();
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      console.error(`Firstmate Calm: built-in ownership check unavailable. ${reason}`);
      return;
    }
    for (const tool of wrappedBuiltIns) {
      const owner = registered.find((info) => info.name === tool.name)?.sourceInfo;
      if (owner && owner.source !== "builtin" && realpathOrSelf(owner.path) !== extensionRealFile) {
        console.error(
          `Firstmate Calm: another extension (${owner.path}) also claimed the built-in "${tool.name}" tool and won; Calm's presentation for it is unavailable this session.`,
        );
      }
    }
  }

  pi.on("session_start", (_event, ctx) => {
    reportBuiltInLosses();
    calmToolRowRepaints.clear();
    exportRendering = false;
    setCalmPresentation(loadCalmPreference());
    setCalmStockExportRendering(false);
    publishPresentationState();
    agentRunActive = false;
    workingShipShown = false;
    // A genuine new session lifetime starts the boat at the normal initial position.
    workingShipAnimation.reset();
    applyWorkingPresentation(ctx.ui, true);
    ctx.ui.setHiddenThinkingLabel(calmPresentationIsActive() ? "" : undefined);
    ctx.ui.setStatus("firstmate-calm", undefined);
    removeTerminalInputHandler?.();
    removeTerminalInputHandler = ctx.ui.onTerminalInput((data) => {
      if (!getKeybindings().matches(data, "tui.input.submit")) return undefined;

      const input = ctx.ui.getEditorText().trim();
      if (
        input !== "/share" &&
        input !== "/export" &&
        !input.startsWith("/export ")
      ) {
        return undefined;
      }

      // Only a bare "/export <path>" writes a local file we can redact; "/export" with
      // no argument uses Pi's own default naming this extension does not replicate, and
      // "/share" and a ".jsonl" target do not produce the HTML DOM the boundary applies to.
      const exportPath = parseExportCommandPath(input);
      // Matches Pi's own resolution: a relative path is written under this process's
      // cwd (agent-session.js's exportSessionToHtml normalizes but never resolves a
      // relative outputPath, so writeFileSync falls through to process.cwd()).
      const htmlExportPath = exportPath && !exportPath.endsWith(".jsonl") ? resolve(process.cwd(), exportPath) : undefined;

      exportRendering = true;
      setCalmStockExportRendering(true);
      publishPresentationState();
      setTimeout(() => {
        exportRendering = false;
        setCalmStockExportRendering(false);
        publishPresentationState();
        // Repaint the rows Calm presents, never the whole transcript. Pi's export
        // prints "Session exported to: <path>" immediately before this runs, and
        // since Pi 0.83.0 setToolsExpanded() emits its own status line; consecutive
        // status lines coalesce, so a tools-expanded round-trip here silently
        // overwrote the confirmation and left the captain no record of where their
        // export landed. Invalidating the rows individually repaints the same
        // content with no status line of its own, and setStatus adds the redraw the
        // rows that consult Calm live in render(), such as operational user rows,
        // need without appending anything to the transcript.
        repaintCalmToolRows();
        ctx.ui.setStatus("firstmate-calm", undefined);
        if (htmlExportPath) void redactCalmExportBoundary(htmlExportPath);
      }, 0);
      return undefined;
    });
  });

  pi.on("agent_start", (_event, ctx) => {
    agentRunActive = true;
    applyWorkingPresentation(ctx.ui);
  });

  // agent_settled is emitted from a finally block, so it also covers abort and failure.
  pi.on("agent_settled", (_event, ctx) => {
    agentRunActive = false;
    applyWorkingPresentation(ctx.ui);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    agentRunActive = false;
    applyWorkingPresentation(ctx.ui);
  });

  pi.registerCommand("calm", {
    description: "Toggle Firstmate's supported conversation-only transcript presentation.",
    handler: async (_args, ctx) => {
      const active = !calmPresentationIsActive();
      persistCalmPreference(active);
      setCalmPresentation(active);
      if (active) activateBuiltInsIfNeeded(ctx.ui);
      publishPresentationState();
      applyWorkingPresentation(ctx.ui, true);
      // Pi re-runs every assistant row's layout from this call even when the label is
      // unchanged, which is what makes a toggle apply to rows already on screen.
      ctx.ui.setHiddenThinkingLabel(active ? "" : undefined);
      ctx.ui.setStatus("firstmate-calm", undefined);

      const expanded = ctx.ui.getToolsExpanded();
      ctx.ui.setToolsExpanded(!expanded);
      ctx.ui.setToolsExpanded(expanded);
    },
  });
}
