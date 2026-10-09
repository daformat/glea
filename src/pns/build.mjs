// Builds glea-pns.ts, with @daformat/point-and-shoot, into the one script
// the app evaluates in every page: src/resources/content-script.js.
import { build } from "esbuild";

await build({
  entryPoints: ["glea-pns.ts"],
  outfile: "../resources/content-script.js",
  bundle: true,
  format: "iife",
  target: "es2020",
  legalComments: "none",
  banner: {
    js: "// Generated from src/pns/glea-pns.ts by `pnpm build` there: edit that, not this.",
  },
});
