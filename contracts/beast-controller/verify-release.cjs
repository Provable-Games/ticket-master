// Read-only check of the frozen declaration against a fresh Scarb build.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { hash } = require('starknet');

const target = process.argv[2];
if (!target) throw new Error('Usage: npm run verify:release -- /absolute/scarb/target/dev');
const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const base = path.join(target, 'beast_controller_trial_TrialController');
const sierra = read(`${base}.contract_class.json`);
const casm = read(`${base}.compiled_contract_class.json`);
const release = read(path.join(__dirname, 'release/controller.json'));
const frozen = read(path.join(__dirname, 'release/controller-class.json'));
const rpcClass = {
  sierra_program: sierra.sierra_program,
  contract_class_version: sierra.contract_class_version,
  entry_points_by_type: sierra.entry_points_by_type,
  abi: hash.formatSpaces(JSON.stringify(sierra.abi)),
};
assert.deepEqual(frozen, rpcClass, 'Frozen RPC class differs from fresh build');
assert.equal(hash.computeSierraContractClassHash(sierra), release.classHash);
// Starknet.js expects an ABI array here; the RPC artifact carries its JSON string.
assert.equal(hash.computeSierraContractClassHash({ ...frozen, abi: JSON.parse(frozen.abi) }), release.classHash);
assert.equal(hash.computeCompiledClassHash(casm), release.compiledClassHash);
console.log(JSON.stringify({ verified: true, ...release }, null, 2));
