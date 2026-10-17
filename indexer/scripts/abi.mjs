import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
let root = dirname(fileURLToPath(import.meta.url));
while (!existsSync(resolve(root, "foundry.toml"))) {
  const parent = dirname(root);
  if (parent === root)
    throw new Error(
      "Run inside the existing Foundry repository after forge build",
    );
  root = parent;
}
for (const name of ["RentalEscrow", "MockPaymentToken"]) {
  const artifact = JSON.parse(
    readFileSync(resolve(root, `out/${name}.sol/${name}.json`), "utf8"),
  );
  const target = resolve(
    dirname(fileURLToPath(import.meta.url)),
    `../abis/${name}.ts`,
  );
  const expected = `// Generated from the existing Foundry artifact by npm run abi:generate.\nexport const ${name}Abi = ${JSON.stringify(artifact.abi, null, 2)} as const;\n`;
  if (process.argv.includes("--check")) {
    if (readFileSync(target, "utf8") !== expected)
      throw new Error(
        `${name} ABI drift; run forge build and npm run abi:generate`,
      );
  } else {
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, expected);
  }
}
console.log(
  process.argv.includes("--check") ? "ABI check passed" : "ABIs generated",
);
