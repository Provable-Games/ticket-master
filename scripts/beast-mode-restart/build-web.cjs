const fs = require('node:fs');
const path = require('node:path');
const esbuild = require('esbuild');
const output = path.resolve(process.env.BEAST_STAGING_DIST || '/workspace/.scratch/beast-mode-restart/web-dist');
fs.mkdirSync(output, { recursive: true });
for (const name of ['index.html', 'style.css']) fs.copyFileSync(path.join(__dirname, 'web', name), path.join(output, name));
esbuild.buildSync({ entryPoints: [path.join(__dirname, 'web/app.mjs')], outfile: path.join(output, 'app.js'),
  bundle: true, platform: 'browser', target: 'es2022', format: 'iife', minify: true, legalComments: 'none' });
console.log(output);
