const {loadEnv} = require('ldenv');
loadEnv();
require('@nomicfoundation/hardhat-network-helpers');
const {addForkConfiguration, addNetworksFromEnv} = require('hardhat-rocketh');
require('vitest-solidity-coverage/hardhat');

// console.log({
// 	BLOCK_TIME: process.env['BLOCK_TIME'],
// });

const defaultVersion = '0.8.20';
const defaultSettings = {
	optimizer: {
		enabled: true,
		runs: 999999,
	},
	outputSelection: {
		'*': {
			'*': ['evm.methodIdentifiers'],
		},
	},
};

module.exports = {
	solidity: {
		compilers: [
			{
				version: defaultVersion,
				settings: {...defaultSettings},
			},
		],
	},
	networks:
		// this setup forking for netwoirk if env var HARDHAT_FORK is set
		addForkConfiguration(
			// this add network for each respective env var found (ETH_NODE_URI_<network>)
			addNetworksFromEnv({
				hardhat: {
					initialBaseFeePerGas: 0,
					allowUnlimitedContractSize: true,
					mining: {
						auto: process.env['BLOCK_TIME'] ? true : false,
						interval: process.env['BLOCK_TIME'] ? parseInt(process.env['BLOCK_TIME']) : undefined,
					},
				},
			}),
		),
	paths: {
		sources: 'src',
	},
	docgen: {
		templates: 'docs_templates',
		pages: 'files',
	},
	mocha: {
		require: 'named-logs-console',
	},
};
