// k6 read load against a host's DefraDB GraphQL endpoint. Driven by readload.sh,
// which runs one invocation per (phase, VUs) step and passes the env below.
//
//   GQL_URL     http://<host>:9181/api/v0/graphql
//   VUS         concurrent clients (closed loop: each sends its next query when the last returns)
//   DURATION    seconds
//   MIN_BLOCK   lowest block number the host holds
//   MAX_BLOCK   highest block number the host has attested when the step starts
//   HASHES      path to a JSON array of tx hashes sampled from the host
//
// The mix is weighted toward what an app does most: point reads by block number on the
// indexed fields. tx_by_hash is on an unindexed field (a scan), kept at low weight so its
// cost shows up per type without dominating the total.

import http from 'k6/http';
import { Trend, Rate } from 'k6/metrics';

const URL = __ENV.GQL_URL;
const MIN = parseInt(__ENV.MIN_BLOCK, 10);
const MAX = parseInt(__ENV.MAX_BLOCK, 10);
const HASHES = JSON.parse(open(__ENV.HASHES));
const P = 'Ethereum__Mainnet__';

const QUERIES = [
    ['block_by_number', 25, (n) => `{ ${P}Block(filter: {number: {_eq: ${n}}}) { number hash miner gasUsed timestamp } }`],
    ['latest_blocks', 10, () => `{ ${P}Block(order: {number: DESC}, limit: 10) { number hash } }`],
    ['txs_in_block', 20, (n) => `{ ${P}Transaction(filter: {blockNumber: {_eq: ${n}}}) { hash from to value } }`],
    ['logs_in_block', 15, (n) => `{ ${P}Log(filter: {blockNumber: {_eq: ${n}}}) { address topics } }`],
    ['block_with_txs', 10, (n) => `{ ${P}Block(filter: {number: {_eq: ${n}}}) { number transactions { hash from to } } }`],
    ['attestation_for_block', 15, (n) => `{ ${P}AttestationRecord(filter: {blockNumber: {_eq: ${n}}}) { attested_doc blockNumber } }`],
    ['tx_by_hash', 5, (n, h) => `{ ${P}Transaction(filter: {hash: {_eq: "${h}"}}) { blockNumber from to } }`],
].filter(([name]) => name !== 'tx_by_hash' || HASHES.length > 0);

const TOTAL = QUERIES.reduce((s, q) => s + q[1], 0);
const latency = Object.fromEntries(QUERIES.map(([name]) => [name, new Trend(`lat_${name}`, true)]));
const gqlErrors = new Rate('gql_errors');
const emptyResults = new Rate('empty_results');

export const options = {
    scenarios: {
        reads: { executor: 'constant-vus', vus: parseInt(__ENV.VUS, 10), duration: `${__ENV.DURATION}s` },
    },
};

function pick() {
    let r = Math.random() * TOTAL;
    for (const q of QUERIES) {
        if ((r -= q[1]) < 0) return q;
    }
    return QUERIES[QUERIES.length - 1];
}

export default function () {
    const [name, , build] = pick();
    const n = MIN + Math.floor(Math.random() * (MAX - MIN + 1));
    const h = HASHES[Math.floor(Math.random() * HASHES.length)];
    const res = http.post(URL, JSON.stringify({ query: build(n, h) }), {
        headers: { 'Content-Type': 'application/json' },
        tags: { q: name },
        timeout: '30s',
    });
    latency[name].add(res.timings.duration);

    let body = null;
    try { body = res.json(); } catch (e) { /* non-JSON body counts as an error */ }
    const failed = res.status !== 200 || !body || (body.errors && body.errors.length > 0);
    gqlErrors.add(failed);
    if (!failed) {
        const rows = body.data ? Object.values(body.data)[0] : null;
        emptyResults.add(!rows || rows.length === 0);
    }
}
