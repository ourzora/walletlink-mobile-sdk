// Copyright (c) 2017-2019 Coinbase Inc. See LICENSE

import BigInt
import CBCore
import CBCrypto
import CBDatabase
import RxSwift

final class LinkRepository {
    private let sessionDAO = SessionDAO()
    private let api = WalletLinkAPI()
    private let dappDAO = DappDAO(database: LinkRepository.createDatabase())

    /// Get list of session
    var sessions: [Session] { return sessionDAO.sessions }

    // MARK: - Session Management

    /// Get stored session for given sessionID and rpc URL
    ///
    /// - Parameters:
    ///     - id: Session ID
    ///     - url: URL to filter sessions
    ///
    /// - Returns: Sessions for given URL
    func getSession(id: String, url: URL) -> Session? {
        return sessionDAO.getSession(id: id, url: url)
    }

    /// Get stored sessions filtered by url
    ///
    /// - Parameters:
    ///     - url: URL to filter sessions
    ///
    /// - Returns: Sessions for given URL
    func getSessions(for url: URL) -> [Session] {
        return sessionDAO.getSessions(for: url)
    }

    /// Observe for distinct stored sessionIds update
    ///
    /// - Parameters:
    ///     - url: URL to filter sessions
    ///
    /// - Returns: Session observable for given URL
    func observeSessions(for url: URL) -> Observable<[Session]> {
        return sessionDAO.observeSessions(for: url)
    }

    /// Deletes sessionId from keychain
    ///
    /// - Parameters:
    ///     - url: WalletLink server websocket URL
    ///     - sessionId: Session ID generated by the host
    func delete(url: URL, sessionId: String) {
        return sessionDAO.delete(url: url, sessionId: sessionId)
    }

    /// Store session/secret to keychain
    ///
    /// - Parameters:
    ///     - url: WalletLink base URL
    ///     - sessionId: Session ID generated by the host
    ///     - secret: Secret generated by the host
    func saveSession(url: URL, sessionId: String, secret: String) {
        return sessionDAO.save(url: url, sessionId: sessionId, secret: secret)
    }

    // MARK: - Dapp managment

    /// Insert or update dapp
    ///
    /// - Parameters:
    ///     - dapp: Dapp model to store
    ///
    /// - Returns: A Single indicating the save operation success or an exception is thrown
    func saveDapp(_ dapp: Dapp) -> Single<Void> {
        return dappDAO.save(dapp: dapp)
    }

    // MARK: - Request management

    /// Mark requests as seen to prevent future presentation
    ///
    /// - Parameters:
    ///     - requestId: WalletLink host generated request ID
    ///     - url: The URL for the session
    ///
    /// - Returns: A single wrapping `Void` if operation was successful. Otherwise, an exception is thrown
    func markAsSeen(requestId: HostRequestId, url: URL) -> Single<Void> {
        guard let session = sessionDAO.getSession(id: requestId.sessionId, url: url) else { return .justVoid() }

        return api.markEventAsSeen(eventId: requestId.eventId, sessionId: session.id, secret: session.secret, url: url)
    }

    /// Get pending requests for given sessionID. Canceled requests will be filtered out
    ///
    /// - Parameters:
    ///     - sessionId: Session ID
    ///     - url: The URL of the session
    ///
    /// - Returns: List of pending requests
    func getPendingRequests(session: Session, url: URL) -> Single<[HostRequest]> {
        return api.getUnseenEvents(sessionId: session.id, secret: session.secret, url: url)
            .flatMap { requests -> Single<[HostRequest]> in
                requests
                    .map { self.getHostRequest(using: $0, url: url) }
                    .zip()
                    .map { requests in requests.compactMap { $0 } }
            }
            .map { requests -> [HostRequest] in
                // build list of cancelation requests
                let cancelationRequests = requests.filter { $0.hostRequestId.isCancelation }

                // build list of pending requests by filtering out canceled requests
                let pendingRequests = requests.filter { request in
                    guard
                        let cancelationRequest = cancelationRequests.first(where: {
                            $0.hostRequestId.canCancel(request.hostRequestId)
                        })
                    else { return true }

                    self.markCancelledEventAsSeen(
                        requestId: request.hostRequestId,
                        cancelationRequestId: cancelationRequest.hostRequestId,
                        url: url
                    )

                    return false
                }

                return pendingRequests
            }
            .catchErrorJustReturn([])
    }

    /// Convert `ServerRequestDTO` to `HostRequest` if possible
    ///
    /// - Parameters:
    ///     - dto: Instance of `ServerRequestDTO`
    ///     - url: WalletLink server URL
    ///
    /// - Returns: A single wrapping a `HostRequest` or nil if unable to convert
    func getHostRequest(using dto: ServerRequestDTO, url: URL) -> Single<HostRequest?> {
        guard
            let session = getSession(id: dto.sessionId, url: url),
            let decrypted = try? dto.data.decryptUsingAES256GCM(secret: session.secret),
            let json = try? JSONSerialization.jsonObject(with: decrypted, options: []) as? [String: Any]
        else {
            assertionFailure("Invalid request \(self)")
            return Single.just(nil)
        }

        switch dto.event {
        case .web3Request:
            guard
                let requestObject = json?["request"] as? [String: Any],
                let requestMethodString = requestObject["method"] as? String,
                let method = RequestMethod(rawValue: requestMethodString)
            else {
                assertionFailure("Invalid web3Request \(self)")
                return Single.just(nil)
            }

            return parseWeb3Request(serverRequest: dto, method: method, decrypted: decrypted, url: url)
        case .web3Response:
            return Single.just(nil)
        case .web3RequestCanceled:
            return parseWeb3Request(serverRequest: dto, method: .requestCanceled, decrypted: decrypted, url: url)
        }
    }

    // MARK: - Private

    private static func createDatabase() -> Database {
        guard
            let bundlePath = Bundle(for: LinkRepository.self).path(forResource: "CBWalletLink", ofType: "bundle"),
            let bundle = Bundle(path: bundlePath),
            let diskOptions = try? DiskDatabaseOptions(
                dbSchemaName: "WalletLink",
                dbStorageFilename: "WalletLink",
                versions: ["WalletLinkDB"],
                dataModelBundle: bundle
            ),
            let db = try? Database(disk: diskOptions)
        else { fatalError("Unable to create WalletLinkDB") }

        return db
    }

    private func markCancelledEventAsSeen(requestId: HostRequestId, cancelationRequestId: HostRequestId, url: URL) {
        _ = markAsSeen(requestId: requestId, url: url)
            .flatMap { _ in self.markAsSeen(requestId: cancelationRequestId, url: url) }
            .subscribe()
    }

    private func parseWeb3Request(
        serverRequest: ServerRequestDTO,
        method: RequestMethod,
        decrypted: Data,
        url: URL
    ) -> Single<HostRequest?> {
        switch method {
        // EIP 1102: Dapp permission
        case .requestEthereumAccounts:
            let paramType = RequestEthereumAccountsParams.self

            return hostRequestId(from: serverRequest, decrypted: decrypted, paramType: paramType, url: url)
                .map { requestId in requestId.map { .dappPermission(requestId: $0.1) } }

        case .signEthereumMessage:
            let paramType = SignEthereumMessageParams.self

            return hostRequestId(from: serverRequest, decrypted: decrypted, paramType: paramType, url: url)
                .map { response in
                    guard let web3Request = response?.0, let requestId = response?.1 else { return nil }

                    return .signMessage(
                        requestId: requestId,
                        address: web3Request.request.params.address,
                        message: web3Request.request.params.message,
                        isPrefixed: web3Request.request.params.addPrefix
                    )
                }

        // Sign/Submit transaction
        case .signEthereumTransaction:
            let paramType = SignEthereumTransactionParams.self

            return hostRequestId(from: serverRequest, decrypted: decrypted, paramType: paramType, url: url)
                .map { response in
                    guard
                        let web3Request = response?.0,
                        let requestId = response?.1,
                        let weiValue = web3Request.request.params.weiValue.asBigInt
                    else { return nil }

                    return .signAndSubmitTx(
                        requestId: requestId,
                        fromAddress: web3Request.request.params.fromAddress,
                        toAddress: web3Request.request.params.toAddress,
                        weiValue: weiValue,
                        data: web3Request.request.params.data.asHexEncodedData ?? Data(),
                        nonce: web3Request.request.params.nonce,
                        gasPrice: web3Request.request.params.gasPriceInWei.asBigInt,
                        gasLimit: web3Request.request.params.gasLimit.asBigInt,
                        chainId: web3Request.request.params.chainId,
                        shouldSubmit: web3Request.request.params.shouldSubmit
                    )
                }

        // Submit transaction
        case .submitEthereumTransaction:
            let paramType = SubmitEthereumTransactionParams.self

            return hostRequestId(from: serverRequest, decrypted: decrypted, paramType: paramType, url: url)
                .map { response in
                    guard
                        let web3Request = response?.0,
                        let requestId = response?.1,
                        let signedTx = web3Request.request.params.signedTransaction.asHexEncodedData
                    else { return nil }

                    return .submitSignedTx(
                        requestId: requestId,
                        signedTx: signedTx,
                        chainId: web3Request.request.params.chainId
                    )
                }

        // Cancel existing request
        case .requestCanceled:
            guard let dto = Web3RequestCanceledDTO.fromJSON(decrypted) else {
                assertionFailure("Invalid Web3RequestCanceled \(self)")
                return Single.just(nil)
            }

            return dappDAO.getDapp(url: dto.origin)
                .map { dapp in
                    let requestId = HostRequestId(
                        id: dto.id,
                        sessionId: serverRequest.sessionId,
                        eventId: serverRequest.eventId,
                        url: url,
                        dappURL: dto.origin,
                        dappImageURL: dapp?.logoURL,
                        dappName: dapp?.name,
                        method: .requestCanceled
                    )

                    print("[walletlink] web3RequestCancelation \(dto)")
                    return .requestCanceled(requestId: requestId)
                }
        }
    }

    private func hostRequestId<T: Codable>(
        from serverRequest: ServerRequestDTO,
        decrypted: Data,
        paramType: T.Type,
        url: URL
    ) -> Single<(Web3RequestDTO<T>, HostRequestId)?> {
        guard let web3Request = Web3RequestDTO<T>.fromJSON(decrypted) else {
            assertionFailure("Invalid web3Request \(paramType)")
            return Single.just(nil)
        }

        return dappDAO.getDapp(url: web3Request.origin)
            .map { dapp in
                var dappImageURL = dapp?.logoURL
                var dappName = dapp?.name

                if let web3Request = web3Request as? Web3RequestDTO<RequestEthereumAccountsParams> {
                    dappName = web3Request.request.params.appName
                    dappImageURL = web3Request.request.params.appLogoUrl
                }

                let requestId = HostRequestId(
                    id: web3Request.id,
                    sessionId: serverRequest.sessionId,
                    eventId: serverRequest.eventId,
                    url: url,
                    dappURL: web3Request.origin,
                    dappImageURL: dappImageURL,
                    dappName: dappName,
                    method: web3Request.request.method
                )

                return (web3Request, requestId)
            }
    }
}