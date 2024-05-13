import {task} from "hardhat/config";
import "@nomiclabs/hardhat-waffle";
import '@nomiclabs/hardhat-ethers';
import 'hardhat-deploy';
import '@typechain/hardhat';
import {HardhatUserConfig} from 'hardhat/types';
import "solidity-coverage";
import "@nomiclabs/hardhat-etherscan";
import "@matterlabs/hardhat-zksync-solc";
import "@matterlabs/hardhat-zksync-verify";
import 'hardhat-dependency-compiler';
import "hardhat-gas-reporter";

const secret = require("./secret.json");

task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
    const accounts = await hre.ethers.getSigners();

    for (const account of accounts) {
        console.log(account.address);
    }
});

const config: HardhatUserConfig = {
    solidity: {
        compilers: [
            {
                version: "0.8.17", // 19 will fail compile zk
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 1000
                    }
                }
            }
        ]

    },
    zksolc: {
        version: "1.3.5",
        compilerSource: "binary",
        settings: {
            optimizer: {
                enabled: true,
                mode: 'z'
            },
        },
    },
    namedAccounts: {
        owner: 0,
        user1: 1,
        user2: 2,
        user3: 3,
    },
    networks: {
        zksync_mainnet: {
            zksync: true,
            url: secret.url_zksync_mainnet,
            accounts: [secret.key_prd, secret.key_same_nonce],
            verifyURL: "https://zksync2-mainnet-explorer.zksync.io/contract_verification",
        },
        optimism: {
            url: secret.url_optimism,
            accounts: [secret.key_dev],
        },
        linea_mainnet: {
            url: secret.url_linea_mainnet,
            accounts: [secret.key_prd, secret.key_same_nonce],
        },
        base_mainnet: {
            url: secret.url_base_mainnet,
            accounts: [secret.key_prd, secret.key_same_nonce],
        },
        hardhat: {
        }
    },
    gasReporter: {
        currency: 'USD',
        // L2: "base",
        // coinmarketcap: secret.coinmarketcap_api_key,
        gasPrice: 0.001, // gwei
        enabled: false
    },
    dependencyCompiler: {
        paths: [
            '@pythnetwork/pyth-sdk-solidity/MockPyth.sol',
            '@layerzerolabs/solidity-examples/contracts/mocks/LZEndpointMock.sol',
            '@deri-labs/x-oracle/contracts/mock/MockXOracle.sol',
        ],
    },
    etherscan: {
        apiKey: {
            linea_mainnet: secret.api_key_linea,
            optimism_goerli: secret.api_key_optimism,
            georli: secret.api_key_eth,
        },
        customChains: [
            {
                network: "linea_mainnet",
                chainId: 59144,
                urls: {
                    apiURL: "https://api.lineascan.build",
                    browserURL: "https://lineascan.build/"
                }
            },
            {
                network: "base",
                chainId: 8453,
                urls: {
                    apiURL: "https://api.basescan.org",
                    browserURL: "https://basescan.org"
                }
            }
        ]
    },
    mocha: {
        timeout: 60000,
    },
}
export default config;

