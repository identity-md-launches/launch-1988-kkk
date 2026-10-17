// Maintainer-only runtime coverage recording. Use --import with the real tests.
import { registerHooks } from "node:module";
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dir = resolve(root, ".data/module-trace");
mkdirSync(dir, { recursive: true });
registerHooks({
  load(url, context, next) {
    const result = next(url, context);
    if (url.startsWith("file:")) {
      const path = relative(root, fileURLToPath(url));
      if (path.startsWith("node_modules/"))
        appendFileSync(
          resolve(dir, `${process.pid}.jsonl`),
          JSON.stringify(path) + "\n",
        );
    }
    return result;
  },
});
