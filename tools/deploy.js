// Sideloads out/squeeze-roku.zip to a Roku in developer mode.
// Usage: set ROKU_HOST (the TV's IP) and ROKU_PASSWORD (the developer mode password), then npm run deploy.
const path = require('path');
const fs = require('fs');
const rokuDeploy = require('roku-deploy');

const host = process.env.ROKU_HOST;
const password = process.env.ROKU_PASSWORD;
if (!host || !password) {
  console.error('Set ROKU_HOST to the TV\'s IP address and ROKU_PASSWORD to its developer mode password.');
  process.exit(1);
}

const zip = path.join(__dirname, '..', 'out', 'squeeze-roku.zip');
if (!fs.existsSync(zip)) {
  console.error('No package yet. Run npm run build first.');
  process.exit(1);
}

rokuDeploy
  .publish({ host, password, outDir: path.dirname(zip), outFile: path.basename(zip) })
  .then(() => console.log(`Installed on ${host}. The channel opens on the TV.`))
  .catch((err) => {
    console.error(`Install failed: ${err.message || err}`);
    process.exit(1);
  });
