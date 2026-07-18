import js from '@eslint/js';
import globals from 'globals';
import stylistic from '@stylistic/eslint-plugin';
import { readFileSync, readdirSync } from 'node:fs';

/* ESLint for the updater's browser JS (fs-update.js). Runs in CI and locally, never on the OpenWrt
 * buildbot: it has no node and needs none — luci.mk copies htdocs/ verbatim.
 *
 * THE NON-OBVIOUS BIT: `globalReturn`. A LuCI resource file is neither a script nor an ES module —
 * luci.js evaluates its body INSIDE a function wrapper, which is why fs-update.js ends in a bare
 * `return baseclass.extend({...})` and opens with `'require ui'` pragma strings. A stock parser
 * rejects a top-level `return`, so without this the file fails to parse and the lint is worthless.
 *
 * This package ships ONE browser file, but the config derives the require-aliases from the source
 * exactly as the theme's does — so a second module added here cannot silently drop its globals. */
const HTDOCS_GLOBS = [ 'luci-app-footstrap-updater/htdocs/**/*.js' ];
const RESOURCE_DIRS = [ 'luci-app-footstrap-updater/htdocs/luci-static/resources' ];
function resourceFiles() {
	return RESOURCE_DIRS.flatMap((dir) => readdirSync(dir, { recursive: true })
		.filter((f) => f.endsWith('.js'))
		.map((f) => {
			const file = `${dir}/${f}`.replace(/\\/g, '/');
			const src = readFileSync(file, 'utf8');
			const aliases = [...src.matchAll(/^'require\s+\S+\s+as\s+(\w+)'/gm)].map((m) => m[1]);
			return { file, aliases };
		}))
		.filter((e) => e.aliases.length);
}

export default [
	{ files: HTDOCS_GLOBS, ...js.configs.recommended },
	{
		files: HTDOCS_GLOBS,
		plugins: { '@stylistic': stylistic },
		languageOptions: {
			ecmaVersion: 2023,
			sourceType: 'script',
			parserOptions: {
				ecmaFeatures: { globalReturn: true },
			},
			globals: {
				...globals.browser,
				/* injected by luci.js into every resource file's scope */
				L: 'readonly',
				E: 'readonly',
				_: 'readonly',
				baseclass: 'readonly',
				ui: 'readonly',
				dom: 'readonly',
				fs: 'readonly',
				uci: 'readonly',
				rpc: 'readonly',
				form: 'readonly',
				network: 'readonly',
				poll: 'readonly',
				request: 'readonly',
				validation: 'readonly',
			},
		},
		rules: {
			/* An empty `catch {}` is the deliberate idiom: every localStorage access is wrapped in one,
			 * because a browser in private mode THROWS on getItem, and a preference that cannot be read
			 * is a default, not an error. Empty blocks anywhere ELSE stay an error. */
			'no-empty': ['error', { allowEmptyCatch: true }],

			/* correctness */
			'no-unused-vars': ['error', { args: 'none', caughtErrors: 'none' }],
			'no-undef': 'error',
			'no-implicit-globals': 'error',
			'no-shadow': 'warn',
			'no-var': 'error',
			'prefer-const': 'warn',
			eqeqeq: ['error', 'always', { null: 'ignore' }],
			'no-eval': 'error',
			'no-implied-eval': 'error',
			'no-new-func': 'error',
			'no-return-await': 'warn',
			'no-unsafe-optional-chaining': 'error',
			'no-constant-binary-expression': 'error',
			'no-self-compare': 'error',
			'no-template-curly-in-string': 'warn',
			'require-atomic-updates': 'warn',
			'no-alert': 'error',
			'no-console': ['warn', { allow: ['warn', 'error'] }],

			/* JSMIN SAFETY — correctness, not style. luci.mk minifies this file with jsmin, whose
			 * regex-vs-division test is a ONE-char lookback against a fixed allow-list: `n` (last letter
			 * of `return`) and `>` (from `=>`) are NOT on it, `(` is. So a regex literal straight after
			 * `return`/`=>` is read as a division, and if its body contains `//` jsmin swallows the rest
			 * of the file — exiting 0 while doing it (openwrt/luci#8299). `wrap-regex` forces
			 * `(/re/).test(x)`; tools/jsmin-verify.mjs (CI) is the backstop. */
			'wrap-regex': 'error',

			'@stylistic/arrow-parens': ['error', 'always'],
			'@stylistic/no-mixed-operators': 'error',
		},
	},

	/* `'require fs-prefs as prefs';` — luci.js resolves the module and passes it into this file's
	 * factory as a formal PARAMETER, so the alias is a real runtime binding with no declaration ESLint
	 * could see. DERIVED FROM THE PRAGMAS, per file, so a file USING `prefs.` without requiring it is
	 * still caught by no-undef (a ReferenceError at load). */
	...resourceFiles().map(({ file, aliases }) => ({
		files: [ file ],
		languageOptions: { globals: Object.fromEntries(aliases.map((a) => [ a, 'readonly' ])) },
	})),
];
