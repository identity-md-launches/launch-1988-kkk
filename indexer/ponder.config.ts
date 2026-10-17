import { createConfig } from "ponder";
import { custom } from "viem";
import { readRpc } from "./shared/transport.ts";
import { RentalEscrowAbi } from "./abis/RentalEscrow.ts";
import { settings } from "./shared/config.ts";
const config = settings();
export default createConfig({
  database: { kind: "pglite", directory: `${config.databaseDirectory}/pglite` },
  chains: {
    anvil: {
      id: config.chainId,
      rpc: custom(
        {
          request: ({ method, params }) =>
            readRpc(config.rpcUrl, method, params as unknown[] | undefined),
        },
        { retryCount: 0 },
      ),
      pollingInterval: 250,
      reorgWindow: config.reorgWindow,
      cacheRpcRequests: false,
      ethGetLogsBlockRange: 20,
    },
  },
  contracts: {
    Rental: {
      chain: "anvil",
      abi: RentalEscrowAbi,
      address: config.contractAddress,
      startBlock: config.deploymentBlock,
    },
  },
  blocks: {
    Cursor: { chain: "anvil", startBlock: config.deploymentBlock, interval: 1 },
  },
});
