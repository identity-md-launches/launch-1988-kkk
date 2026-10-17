// Local, fixed-version Ponder bootstrap. Node 24 loads the application's TypeScript;
// the original Ponder modules perform validation, indexing, rollback and persistence.
// No Vite browser bundler or hot reload. Restart this process after source changes.
import { registerHooks } from "node:module";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { settings } from "../shared/config.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
process.chdir(root);
const config = settings();
const ponderRoot = resolve(root, "node_modules/ponder");
if (
  JSON.parse(readFileSync(resolve(ponderRoot, "package.json"))).version !==
  "0.18.2"
)
  throw new Error(
    "Compact runtime requires exactly Ponder 0.18.2; revalidate before upgrading",
  );
if (Number(process.versions.node.split(".")[0]) !== 24)
  throw new Error("Compact runtime requires Node.js 24.x");
const upstream = (path) =>
  import(pathToFileURL(resolve(ponderRoot, "dist/esm", path)).href);
const { buildOptions } = await upstream("internal/options.js");
const { createLogger } = await upstream("internal/logger.js");
const { MetricsService } = await upstream("internal/metrics.js");
const { createShutdown } = await upstream("internal/shutdown.js");
const { createExit } = await upstream("bin/utils/exit.js");
const { ShutdownError } = await upstream("internal/errors.js");
const { vitePluginPonder } = await upstream("build/plugin.js");
const options = buildOptions({
  cliOptions: {
    command: "dev",
    version: "0.18.2",
    root,
    config: "ponder.config.ts",
    logFormat: "pretty",
    logLevel: "info",
    hostname: "127.0.0.1",
    port: config.apiPort,
  },
});
// Do not let unrelated PORT environment settings change the configured endpoint.
options.port = config.apiPort;
const common = {
  options,
  logger: createLogger({ level: "info", mode: "pretty" }),
  metrics: new MetricsService(),
  shutdown: createShutdown(),
  apiShutdown: createShutdown(),
  buildShutdown: createShutdown(),
};
const exit = createExit({ common, options });
for (const event of ["uncaughtException", "unhandledRejection"])
  process.on(event, (error) => {
    if (error instanceof ShutdownError) return;
    common.logger.error({ msg: event, error });
    void exit({ code: 1 });
  });
const checked = (result) => {
  if (result.status === "error") throw result.error;
  for (const { level, ...log } of result.logs ?? []) common.logger[level](log);
  return result;
};

try {
  globalThis.PONDER_COMMON = common;
  const namespaceBuild = { schema: "public", viewsSchema: undefined };
  globalThis.PONDER_NAMESPACE_BUILD = namespaceBuild;
  // Use Ponder's own virtual-module source, without loading Vite. This hook only
  // handles its three exact aliases; every package import resolves normally.
  const plugin = vitePluginPonder(options);
  registerHooks({
    resolve(specifier, context, next) {
      if (plugin.resolveId(specifier))
        return { url: specifier, shortCircuit: true };
      if (context.parentURL?.startsWith("ponder:"))
        return next(specifier, {
          ...context,
          parentURL: pathToFileURL(options.configFile).href,
        });
      return next(specifier, context);
    },
    load(url, context, next) {
      const source = plugin.load(url);
      if (source !== null)
        return { format: "module", source, shortCircuit: true };
      return next(url, context);
    },
  });
  const { safeBuildPre } = await upstream("build/pre.js");
  const { safeBuildSchema } = await upstream("build/schema.js");
  const { safeBuildConfig, safeBuildIndexingFunctions } =
    await upstream("build/config.js");
  const { createDatabase } = await upstream("database/index.js");
  const { createServer } = await upstream("server/index.js");
  const { runMultichain } = await upstream("runtime/multichain.js");
  const { default: ponderConfig } = await import(
    pathToFileURL(options.configFile).href
  );
  const pre = checked(
    safeBuildPre({ config: ponderConfig, options, logger: common.logger }),
  );
  const preBuild = {
    databaseConfig: pre.databaseConfig,
    ordering: pre.ordering,
  };
  if (pre.ordering !== "multichain" || pre.databaseConfig.kind !== "pglite")
    throw new Error(
      "Compact local runtime supports only multichain ordering with PGlite",
    );
  const schema = await import(pathToFileURL(options.schemaFile).href);
  const builtSchema = checked(safeBuildSchema({ schema, preBuild }));
  const schemaBuild = { schema, statements: builtSchema.statements };
  const configBuild = checked(
    safeBuildConfig({ common, config: ponderConfig }),
  );
  const files = readdirSync(options.indexingDir, { recursive: true })
    .filter(
      (path) =>
        !path.startsWith("api/") &&
        !/\.(test|spec)\./.test(path) &&
        /\.(ts|mts|js|mjs)$/.test(path),
    )
    .sort();
  for (const path of files)
    await import(pathToFileURL(resolve(options.indexingDir, path)).href);
  const { ponder } = await import("ponder:registry");
  const builtIndexing = checked(
    await safeBuildIndexingFunctions({
      common,
      config: ponderConfig,
      indexingFunctions: ponder.fns,
      configBuild,
    }),
  );
  const hash = createHash("sha256").update("rental-node24-ponder-0.18.2-v1");
  for (const dir of ["scripts", "shared", "src", "abis"])
    for (const path of readdirSync(resolve(root, dir), {
      recursive: true,
    }).sort())
      if (/\.(ts|mjs)$/.test(path))
        hash.update(path).update(readFileSync(resolve(root, dir, path)));
  hash
    .update(readFileSync(options.configFile))
    .update(readFileSync(options.schemaFile));
  const indexingBuild = {
    ...builtIndexing,
    buildId: hash.digest("hex").slice(0, 10),
    indexingFunctions: ponder.fns,
  };
  const database = createDatabase({
    common,
    namespace: namespaceBuild,
    preBuild,
    schemaBuild,
  });
  const crashRecoveryCheckpoint = await database.migrate({
    buildId: indexingBuild.buildId,
    chains: indexingBuild.chains,
    finalizedBlocks: indexingBuild.finalizedBlocks,
  });
  await database.migrateSync();
  globalThis.PONDER_PRE_BUILD = preBuild;
  globalThis.PONDER_INDEXING_BUILD = configBuild;
  globalThis.PONDER_DATABASE = database;
  const { default: app } = await import(pathToFileURL(options.apiFile).href);
  const { Hono } = await import("hono");
  if (!(app instanceof Hono))
    throw new Error("API must export a Hono instance");
  for (const route of app.routes)
    if (
      ["/ready", "/status", "/metrics", "/health", "/client"].includes(
        route.path,
      )
    )
      throw new Error(`Reserved Ponder API route: ${route.path}`);
  const apiBuild = { app, hostname: "127.0.0.1", port: config.apiPort };
  common.metrics.ponder_settings_info.set(
    { ordering: preBuild.ordering, database: "pglite", command: "dev" },
    1,
  );
  common.metrics.initializeIndexingMetrics({ indexingBuild, schemaBuild });
  createServer({ common, database, apiBuild });
  common.logger.info({
    msg: "Compact local Ponder runtime; restart after source edits; dev projection rebuild semantics",
  });
  runMultichain({
    common,
    database,
    preBuild,
    namespaceBuild,
    schemaBuild,
    indexingBuild,
    crashRecoveryCheckpoint,
  });
} catch (error) {
  common.logger.error({ msg: "Compact runtime startup failed", error });
  await exit({ code: 1 });
}
