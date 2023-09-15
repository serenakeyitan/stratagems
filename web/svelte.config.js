import preprocess from 'svelte-preprocess';
import adapter from '@sveltejs/adapter-static';
import {vitePreprocess} from '@sveltejs/kit/vite';
import {getVersion} from './version.js';

const VERSION = getVersion();

/** @type {import('@sveltejs/kit').Config} */
const config = {
	preprocess: [
		vitePreprocess(),
		preprocess({
			// postcss make use of tailwind
			// we ensure it get processed, see postcss.config.cjs
			postcss: true,
		}),
	],

	kit: {
		adapter: adapter(),
		version: {
			// we create a dertemrinistic building using a derterministic version (via git commit, see above)
			name: VERSION,
		},
		alias: {
			// alias for web-config
			'web-config': './src/web-config.json',
			$data: './src/data',
			$external: './src/external',
		},
		serviceWorker: {
			// we handle it ourselves here : src/service-worker-handler.ts
			register: false,
		},
		paths: {
			// this is to make it work on ipfs (on an unknown path)
			relative: true,
		},
	},
};

export default config;
