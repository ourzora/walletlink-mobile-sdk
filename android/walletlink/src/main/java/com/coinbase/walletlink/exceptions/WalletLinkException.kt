package com.coinbase.walletlink.exceptions

import java.net.URL

sealed class WalletLinkException {
    /**
     * Unable to encrypt message to send to host
     */
    object UnableToEncryptData : RuntimeException("Unable to encrypt data")

    /**
     * Unable to decrypt message from host
     */
    object UnableToDecryptData : RuntimeException("Unable to decrypt data")

    /**
     * Thrown when trying to conenct with an invalid session
     */
    object InvalidSession : RuntimeException("Unable to encrypt data")

    /**
     * Thrown if unable to find connection for given sessionId
     */
    class NoConnectionFound(val url: URL) : java.lang.RuntimeException("Unable to find for url $url")
}