import {
	bytesToHex,
	ConsensusAggregationByFields,
	EVMClient,
	getHeader,
	HTTPClient,
	type EVMLog,
	getNetwork,
	handler,
	hexToBase64,
	identical,
	type HTTPSendRequester,
	Runner,
	type Runtime,
	TxStatus,
} from '@chainlink/cre-sdk'
import { decodeAbiParameters, encodeAbiParameters } from 'viem'
import { keccak256 } from 'viem'
import { z } from 'zod'

// ---------------------------------------------------------------------------
// Config schema
// ---------------------------------------------------------------------------

const configSchema = z.object({
	challengeManagerAddress: z.string(),
	chainSelectorName: z.string(),
	gasLimit: z.string(),
})

type Config = z.infer<typeof configSchema>

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface VerifyRequest {
	challengeId: string
	path: string
	method: string
	integrityHash: string // 0x-prefixed hex
}

interface VerifyResult {
	challengeId: string
	result: string // "1" = valid, "0" = invalid
}

// ---------------------------------------------------------------------------
// keccak256 hash computation (matches on-chain _computeIntegrityHash)
// Uses viem's keccak256 which works in CRE environment.
// ---------------------------------------------------------------------------

function computeIntegrityHash(metadata: {
	amount: string
	asset: string
	network: string
	payTo: string
	url: string
}): string {
	// Convert addresses to lowercase hex without 0x prefix (matches on-chain _toLowercaseHex)
	const normalizeAddr = (addr: string) => addr.replace(/^0x/i, '').toLowerCase()

	const normalized = {
		amount:  metadata.amount,
		asset:   normalizeAddr(metadata.asset),
		network: metadata.network,
		payTo:   normalizeAddr(metadata.payTo),
		url:     metadata.url,
	}

	const dataString = JSON.stringify(normalized, Object.keys(normalized).sort() as any)
	const hashBytes = keccak256(new TextEncoder().encode(dataString))
	return hashBytes
}

// ---------------------------------------------------------------------------
// Log trigger handler
// ---------------------------------------------------------------------------

const onLogTrigger = async (runtime: Runtime<Config>, payload: EVMLog): Promise<string> => {
	runtime.log('ChallengeOpened event received')

	const { topics, data } = payload

	// ChallengeOpened event signature:
	//   event ChallengeOpened(
	//       uint256 indexed id,           // topics[1]
	//       bytes32 indexed endpointId,   // topics[2]
	//       address revenueSplitter,       // data (ABI-encoded)
	//       string  path,                  // data
	//       string  method,                // data
	//       bytes32 integrityHash          // data
	//   )
	if (topics.length < 3) {
		throw new Error(`Expected >=3 topics, got ${topics.length}`)
	}

	const challengeId = bytesToHex(topics[1]) as `0x${string}`
	// challengeId is a uint256 padded to 32 bytes in the topic — convert to decimal
	const challengeIdDecimal = BigInt(challengeId).toString()

	runtime.log(`challengeId=${challengeIdDecimal}`)

	// Decode non-indexed parameters: (address revenueSplitter, string path, string method, bytes32 integrityHash)
	const [revenueSplitter, path, method, integrityHash] = decodeAbiParameters(
		[{ type: 'address' }, { type: 'string' }, { type: 'string' }, { type: 'bytes32' }],
		bytesToHex(data),
	) as [`0x${string}`, string, string, `0x${string}`]

	runtime.log(`path=${path}  method=${method}  integrityHash=${integrityHash}`)

	const config = runtime.config

	// Extract endpointId from topics[2]
	const endpointIdHex = bytesToHex(topics[2])
	runtime.log(`endpointId=${endpointIdHex}`)

	// -------------------------------------------------------------------------
	// Extract revenueSplitter from event data (avoid extra RPC calls)
	// -------------------------------------------------------------------------

	const expectedPayTo = revenueSplitter.toLowerCase()
	runtime.log(`expectedPayTo=${expectedPayTo}`)

	// -------------------------------------------------------------------------
	// Each DON node independently fetches the endpoint and verifies the hash.
	// All nodes must agree on the result before the report is signed.
	// -------------------------------------------------------------------------

	const httpCapability = new HTTPClient()

	const verifyResult = httpCapability
		.sendRequest(
			runtime,
			(sendRequester: HTTPSendRequester, req: VerifyRequest): VerifyResult => {
				// Fetch the endpoint — expect a 402 with PAYMENT-REQUIRED header
				const resp = sendRequester
					.sendRequest({
						url: req.path,
						method: req.method,
						headers: { Accept: 'application/json' },
					})
					.result()

				runtime.log(`fetch status=${resp.statusCode}`)

				// Detect x402 v2 (PAYMENT-REQUIRED header) or v1 (body)
				const paymentHeader = getHeader(resp, 'payment-required') ?? null

				let paymentData: any

				if (paymentHeader) {
					// v2: base64-encoded JSON in header
					runtime.log('x402 v2 detected (PAYMENT-REQUIRED header)')
					paymentData = JSON.parse(Buffer.from(paymentHeader, 'base64').toString('utf-8'))
				} else if (resp.body && resp.body.length > 0) {
					// v1: JSON body
					runtime.log('x402 v1 detected (body)')
					const bodyText = Buffer.from(resp.body).toString('utf-8')
					try {
						paymentData = JSON.parse(bodyText)
					} catch {
						runtime.log('body is not JSON — returning invalid')
						return { challengeId: req.challengeId, result: '0' }
					}
				} else {
					runtime.log('no payment data — returning invalid')
					return { challengeId: req.challengeId, result: '0' }
				}

				const accepts = paymentData?.accepts
				if (!accepts || !accepts[0]) {
					runtime.log('missing accepts[0] — returning invalid')
					return { challengeId: req.challengeId, result: '0' }
				}

			const entry = accepts[0]
			const metadata = {
				amount:  String(entry.amount  ?? ''),
				asset:   String(entry.asset   ?? '').toLowerCase(),
				network: String(entry.network ?? ''),
				payTo:   String(entry.payTo   ?? '').toLowerCase(),
				url:     String(paymentData.resource?.url ?? ''),
			}

				runtime.log(`metadata=${JSON.stringify(metadata)}`)

				// Validate payTo matches the registered revenueSplitter
				if (expectedPayTo && metadata.payTo !== expectedPayTo) {
					runtime.log(`payTo mismatch: server=${metadata.payTo} expected=${expectedPayTo}`)
					return { challengeId: req.challengeId, result: '0' }
				}

				const computed = computeIntegrityHash(metadata)

				runtime.log(`computed=${computed}  expected=${req.integrityHash}`)

				const match = computed.toLowerCase() === req.integrityHash.toLowerCase()
				return {
					challengeId: req.challengeId,
					result: match ? '1' : '0',
				}
			},
			ConsensusAggregationByFields<VerifyResult>({
				challengeId: identical, // all nodes must agree on which challenge
				result: identical,      // all nodes must agree on pass/fail
			}),
		)({ challengeId: challengeIdDecimal, path, method, integrityHash })
		.result()

	runtime.log(`result=${verifyResult.result} for challengeId=${verifyResult.challengeId}`)

	// -------------------------------------------------------------------------
	// Build and submit the CRE report.
	//
	// ChallengeManager.onReport() decodes the report bytes as:
	//   abi.decode(report, (uint256, uint8))
	//   → (challengeId, result)   result: 1 = valid, 0 = invalid
	// -------------------------------------------------------------------------

	const reportPayload = encodeAbiParameters(
		[{ type: 'uint256' }, { type: 'uint8' }],
		[BigInt(verifyResult.challengeId), Number(verifyResult.result)],
	)

	runtime.log(`reportPayload=${reportPayload}`)

	const report = runtime
		.report({
			encodedPayload: hexToBase64(reportPayload),
			encoderName: 'evm',
			signingAlgo: 'ecdsa',
			hashingAlgo: 'keccak256',
		})
		.result()

	// -------------------------------------------------------------------------
	// Write the report to ChallengeManager.onReport() via the CRE forwarder.
	// -------------------------------------------------------------------------

	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: config.chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found for chainSelectorName: ${config.chainSelectorName}`)
	}

	const evmClient = new EVMClient(network.chainSelector.selector)

	const writeResult = evmClient
		.writeReport(runtime, {
			receiver: config.challengeManagerAddress,
			report,
			gasConfig: { gasLimit: config.gasLimit },
		})
		.result()

	if (writeResult.txStatus !== TxStatus.SUCCESS) {
		throw new Error(
			`writeReport failed: ${writeResult.errorMessage ?? String(writeResult.txStatus)}`,
		)
	}

	const txHash = writeResult.txHash ? bytesToHex(writeResult.txHash) : '(no hash)'
	runtime.log(`onReport settled — txHash=${txHash}`)

	return txHash
}

// ---------------------------------------------------------------------------
// Workflow initialisation
// ---------------------------------------------------------------------------

const initWorkflow = (config: Config) => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: config.chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found for chainSelectorName: ${config.chainSelectorName}`)
	}

	const evmClient = new EVMClient(network.chainSelector.selector)

	return [
		handler(
			// Listen for ChallengeOpened events from ChallengeManager
			evmClient.logTrigger({
				addresses: [config.challengeManagerAddress],
			}),
			onLogTrigger,
		),
	]
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

export async function main() {
	const runner = await Runner.newRunner<Config>({ configSchema })
	await runner.run(initWorkflow)
}
