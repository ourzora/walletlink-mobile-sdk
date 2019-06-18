package com.coinbase.walletlink.models

import java.net.URL

/**
 * Represents a host initiated request UUID
 *
 * @property id Request ID generated by the host
 * @property sessionId Session ID generated by the host
 * @property eventId Event ID generated by the host
 * @property rpcUrl Host RPC URL
 * @property dappUrl The dapp URL
 * @property dappName The dapp name
 */
data class HostRequestId(
    val id: String,
    val sessionId: String,
    val eventId: String,
    val rpcUrl: URL,
    val dappUrl: URL,
    val dappName: String?
)