import {generatePrivateKey, privateKeyToAccount} from 'viem/accounts';

import {Deployment, loadEnvironment} from 'rocketh';
import {context} from '../deploy/_context';
import {EIP1193ProviderWithoutEvents} from 'eip-1193';
import {fetchContract} from '../utils/connection';
import {formatEther, parseEther, parseUnits} from 'viem';
import hre from 'hardhat';
import fs from 'fs-extra';
import prompts from 'prompts';
import 'rocketh-deploy';

const args = process.argv.slice(2);
const num = (args[0] && parseInt(args[0])) || 100;

async function main() {
	const env = await loadEnvironment(
		{
			provider: hre.network.provider as EIP1193ProviderWithoutEvents,
			networkName: hre.network.name,
		},
		context,
	);

	const TestTokens = env.deployments.TestTokens as Deployment<typeof context.artifacts.TestTokens.abi>;
	const TestTokensContract = await fetchContract(TestTokens);
	const decimals = await TestTokensContract.read.decimals();

	fs.ensureDirSync('keys');
	const accounts: {address: `0x${string}`; key: `0x${string}`}[] = [];
	for (let i = 0; i < num; i++) {
		const key = generatePrivateKey();
		const account = privateKeyToAccount(key);
		accounts.push({address: account.address, key});
	}

	fs.writeFileSync(
		`.keys/${env.network.name}-list.csv`,
		accounts.map((v) => `${v.address},https://${env.network.name}.stratagems.world#tokenClaim=${v.key}`).join('\n'),
	);

	const addresses = accounts.map((v) => v.address);
	const value = parseEther('0.2') * BigInt(addresses.length);

	const prompt = await prompts({
		type: 'confirm',
		name: 'proceed',
		message: `proceed to send ${formatEther(value)} ETH`,
	});
	if (prompt.proceed) {
		const tx = await env.execute(TestTokens, {
			account: env.accounts.tokensBeneficiary,
			value,
			functionName: 'distributeAlongWithETH',
			args: [addresses, BigInt(addresses.length) * parseUnits('15', decimals)],
		});
		console.log(tx);
	}
}
main();
