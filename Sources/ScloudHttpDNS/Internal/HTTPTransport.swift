import Foundation
import Network

final class HTTPTransport {
    func request(
        host: String,
        pathWithQuery: String,
        connectIp: String?,
        portOverride: Int?,
        timeoutMillis: Int,
        enableHttps: Bool
    ) throws -> String {
        if let connectIp, !connectIp.isEmpty {
            return try requestByDirectConnection(
                host: host,
                pathWithQuery: pathWithQuery,
                connectIp: connectIp,
                portOverride: portOverride,
                timeoutMillis: timeoutMillis,
                enableHttps: enableHttps
            )
        }

        var components = URLComponents()
        components.scheme = enableHttps ? "https" : "http"
        components.host = host
        if let portOverride {
            components.port = portOverride
        }

        if let question = pathWithQuery.firstIndex(of: "?") {
            let path = String(pathWithQuery[..<question])
            let query = String(pathWithQuery[pathWithQuery.index(after: question)...])
            components.percentEncodedPath = path
            components.percentEncodedQuery = query
        } else {
            components.percentEncodedPath = pathWithQuery
        }

        guard let url = components.url else {
            throw ScloudError.network("invalid url")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(timeoutMillis) / 1000.0
        request.httpMethod = "GET"

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var statusCode: Int?
        var responseError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            statusCode = (response as? HTTPURLResponse)?.statusCode
            responseError = error
            semaphore.signal()
        }
        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + .milliseconds(timeoutMillis + 200))
        if waitResult == .timedOut {
            task.cancel()
            throw ScloudError.network("request timeout")
        }

        if let responseError {
            throw responseError
        }

        let code = statusCode ?? -1
        guard (200...299).contains(code) else {
            let body = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw ScloudError.network("HTTP \(code): \(body)")
        }

        guard let responseData, let body = String(data: responseData, encoding: .utf8), !body.isEmpty else {
            throw ScloudError.invalidResponse
        }
        return body
    }

    private func requestByDirectConnection(
        host: String,
        pathWithQuery: String,
        connectIp: String,
        portOverride: Int?,
        timeoutMillis: Int,
        enableHttps: Bool
    ) throws -> String {
        let port = NWEndpoint.Port(integerLiteral: UInt16(portOverride ?? (enableHttps ? 443 : 80)))
        let params: NWParameters
        if enableHttps {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            params = NWParameters(tls: tls)
        } else {
            params = NWParameters.tcp
        }

        let connection = NWConnection(host: NWEndpoint.Host(connectIp), port: port, using: params)
        let queue = DispatchQueue(label: "scloud.httpdns.transport.direct")
        let semaphore = DispatchSemaphore(value: 0)

        let receiveState = ReceiveState()
        var finished = false

        let timeoutWorkItem = DispatchWorkItem {
            if !finished {
                receiveState.failure = ScloudError.network("request timeout")
                connection.cancel()
                semaphore.signal()
            }
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMillis + 200), execute: timeoutWorkItem)

        connection.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .ready:
                let requestText = self.buildRawRequest(host: host, pathWithQuery: pathWithQuery)
                connection.send(content: Data(requestText.utf8), completion: .contentProcessed { sendError in
                    if let sendError {
                        receiveState.failure = sendError
                        if !finished {
                            finished = true
                            semaphore.signal()
                        }
                        return
                    }
                    self.receiveAll(connection: connection, state: receiveState) {
                        if !finished {
                            finished = true
                            semaphore.signal()
                        }
                    }
                })
            case .failed(let error):
                receiveState.failure = error
                if !finished {
                    finished = true
                    semaphore.signal()
                }
            case .cancelled:
                if !finished {
                    finished = true
                    semaphore.signal()
                }
            default:
                break
            }
        }

        connection.start(queue: queue)
        semaphore.wait()
        timeoutWorkItem.cancel()
        connection.cancel()

        if let failure = receiveState.failure {
            throw failure
        }
        return try parseHttpBody(from: receiveState.collected)
    }

    private func receiveAll(
        connection: NWConnection,
        state: ReceiveState,
        completion: @escaping () -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            if let error {
                state.failure = error
                completion()
                return
            }
            if let data, !data.isEmpty {
                state.collected.append(data)
            }
            if isComplete {
                completion()
                return
            }
            self.receiveAll(connection: connection, state: state, completion: completion)
        }
    }

    private func buildRawRequest(host: String, pathWithQuery: String) -> String {
        let path = pathWithQuery.isEmpty ? "/" : pathWithQuery
        return "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\nAccept: */*\r\n\r\n"
    }

    private func parseHttpBody(from data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ScloudError.invalidResponse
        }
        guard let separatorRange = text.range(of: "\r\n\r\n") else {
            throw ScloudError.invalidResponse
        }

        let header = String(text[..<separatorRange.lowerBound])
        let rawBody = String(text[separatorRange.upperBound...])
        let statusLine = header.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let statusCode = statusLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .dropFirst()
            .first
            .flatMap { Int($0) } ?? -1

        let isChunked = header.lowercased().contains("transfer-encoding: chunked")
        let body = isChunked ? decodeChunkedBody(rawBody) : rawBody

        guard (200...299).contains(statusCode) else {
            throw ScloudError.network("HTTP \(statusCode): \(body)")
        }
        return body
    }

    private func decodeChunkedBody(_ body: String) -> String {
        var result = ""
        var remaining = body[...]

        while true {
            guard let lineRange = remaining.range(of: "\r\n") else {
                break
            }
            let sizeLine = String(remaining[..<lineRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let sizeHex = sizeLine.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? sizeLine
            guard let chunkSize = Int(sizeHex, radix: 16) else {
                break
            }
            remaining = remaining[lineRange.upperBound...]
            if chunkSize == 0 {
                break
            }
            guard remaining.count >= chunkSize else {
                break
            }
            let chunkEnd = remaining.index(remaining.startIndex, offsetBy: chunkSize)
            result += String(remaining[..<chunkEnd])
            remaining = remaining[chunkEnd...]
            if remaining.hasPrefix("\r\n") {
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 2)...]
            }
        }

        return result
    }

    private final class ReceiveState {
        var collected = Data()
        var failure: Error?
    }
}
