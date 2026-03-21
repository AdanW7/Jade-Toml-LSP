const esbuild = require("esbuild");
const path = require("path");

esbuild
  .build({
    entryPoints: [path.join(__dirname, "extension.js")],
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node18",
    outfile: path.join(__dirname, "dist", "extension.js"),
    external: ["vscode"],
  })
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
