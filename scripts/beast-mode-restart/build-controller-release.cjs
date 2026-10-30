// Freeze the exact reviewed Sierra/CASM pair for the browser declaration flow.
const fs = require('node:fs'), path = require('node:path'), { hash } = require('starknet');
const dir = process.argv[2];
if (!dir) throw new Error('Usage: node build-controller-release.cjs /absolute/scarb/target/dev');
const base = path.join(dir, 'beast_controller_trial_TrialController');
const sierra = JSON.parse(fs.readFileSync(`${base}.contract_class.json`));
const casm = JSON.parse(fs.readFileSync(`${base}.compiled_contract_class.json`));
const release = path.join(__dirname, 'web/release');
fs.mkdirSync(release, { recursive: true });
fs.writeFileSync(path.join(release, 'controller.json'), JSON.stringify({ classHash: hash.computeSierraContractClassHash(sierra),
  compiledClassHash: hash.computeCompiledClassHash(casm) }, null, 2) + '\n');
fs.writeFileSync(path.join(release, 'controller-class.json'), JSON.stringify({ sierra_program: sierra.sierra_program,
  contract_class_version: sierra.contract_class_version, entry_points_by_type: sierra.entry_points_by_type,
  abi: hash.formatSpaces(JSON.stringify(sierra.abi)) }) + '\n');
console.log(fs.readFileSync(path.join(release, 'controller.json'), 'utf8'));
