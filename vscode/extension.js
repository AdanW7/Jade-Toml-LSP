const path = require("path");
const fs = require("fs");
const vscode = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

let client;
let outputChannel;

function resolveServerPath(context) {
  const platform = resolvePlatform();
  const arch = resolveArch();
  if (platform && arch) {
    const exe = platform === "windows" ? "jade_toml_lsp.exe" : "jade_toml_lsp";
    const bundled = path.join(
      context.extensionPath,
      "bin",
      platform,
      arch,
      exe
    );
    if (fs.existsSync(bundled)) {
      ensureExecutable(bundled);
      return bundled;
    }
  }

  return null;
}

function resolvePlatform() {
  switch (process.platform) {
    case "win32":
      return "windows";
    case "darwin":
      return "macos";
    case "linux":
      return "linux";
    default:
      return null;
  }
}

function ensureExecutable(p) {
  if (process.platform === "win32") {
    return;
  }
  try {
    fs.chmodSync(p, 0o755);
  } catch {
    // ignore
  }
}

function resolveArch() {
  switch (process.arch) {
    case "x64":
      return "x86_64";
    case "arm64":
      return "aarch64";
    default:
      return null;
  }
}

function startClient(context) {
  const serverPath = resolveServerPath(context);
  if (!serverPath) {
    vscode.window.showErrorMessage(
      "Jade TOML LSP: bundled server binary not found for this platform/arch."
    );
    return;
  }
  if (!outputChannel) {
    outputChannel = vscode.window.createOutputChannel("Jade TOML LSP");
    context.subscriptions.push(outputChannel);
  }
  outputChannel.appendLine(`Starting Jade TOML LSP: ${serverPath}`);

  const serverOptions = {
    command: serverPath,
    args: [],
    transport: TransportKind.stdio,
  };

  const clientOptions = {
    documentSelector: [
      { scheme: "file", language: "toml" }
    ],
    synchronize: {
      configurationSection: "jade_toml_lsp",
    },
    outputChannel,
  };

  client = new LanguageClient(
    "jade_toml_lsp",
    "Jade TOML Language Server",
    serverOptions,
    clientOptions
  );

  context.subscriptions.push(client.start());

  client.onDidChangeState((e) => {
    outputChannel.appendLine(`Client state: ${e.newState}`);
  });

  client.onReady().catch((err) => {
    outputChannel.appendLine(`Client failed to start: ${err}`);
    vscode.window.showErrorMessage(`Jade TOML LSP failed to start: ${err}`);
  });
}

function restartClient(context) {
  if (!client) {
    startClient(context);
    return;
  }
  client
    .stop()
    .then(() => startClient(context))
    .catch(() => startClient(context));
}

function activate(context) {
  startClient(context);
}

function deactivate() {
  if (!client) return undefined;
  return client.stop();
}

module.exports = {
  activate,
  deactivate,
};
