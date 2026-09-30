import Darwin
import Foundation

protocol HostResolving: Sendable {
    func addresses(for host: String) async throws -> [String]
}

actor SystemHostResolver: HostResolving {
    func addresses(for host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0,
              let first = result else { throw CaptureError.downloadFailed }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let entry = current {
            if let address = entry.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    address,
                    entry.pointee.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    addresses.append(String(
                        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                        as: UTF8.self
                    ))
                }
            }
            current = entry.pointee.ai_next
        }
        return addresses
    }
}

struct URLPolicy: Sendable {
    let resolver: any HostResolving
    init(resolver: any HostResolving = SystemHostResolver()) {
        self.resolver = resolver
    }

    func validate(_ url: URL) async throws {
        _ = try CaptureRequest.canonicalURL(url)
        guard let host = url.host?.lowercased(), !host.hasSuffix(".local"), host != "localhost",
              !host.hasSuffix(".localhost"),
              url.port == nil || url.port == 80 || url.port == 443
        else {
            throw CaptureError.unsafeURL
        }
        let hostname = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let addresses = try await resolver.addresses(for: hostname)
        guard !addresses.isEmpty,
              addresses.allSatisfy(Self.isPublicAddress) else { throw CaptureError.unsafeURL }
    }

    static func isPublicAddress(_ string: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, string, &ipv4) == 1 {
            let bits = UInt32(bigEndian: ipv4.s_addr)
            let a = bits >> 24, b = (bits >> 16) & 255, c = (bits >> 8) & 255
            return a != 0 && a != 10 && a != 127 && a < 224
                && !(a == 100 && (64 ... 127).contains(b))
                && !(a == 169 && b == 254) && !(a == 172 && (16 ... 31).contains(b))
                &&
                !(a == 192 &&
                    (b == 168 || (b == 0 && (c == 0 || c == 2)) || (b == 88 && c == 99)))
                && !(a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
                && !(a == 203 && b == 0 && c == 113)
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, string, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: &ipv6) { bytes in
            // Global unicast only; reject mapped/translation and documentation ranges too.
            bytes[0] & 0xE0 == 0x20 && !(bytes[0] == 0x20 && bytes[1] == 0x02)
                && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0D && bytes[3] == 0xB8)
                && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0 && bytes[3] == 0)
        }
    }
}

struct DownloadedContent: Sendable {
    let data: Data
    let url: URL
    let mime: String?
    let encoding: String?
}

protocol SourceFetching: Sendable {
    func fetch(_ url: URL) async throws -> DownloadedContent
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct SourceFetcher: SourceFetching {
    private let policy: URLPolicy
    private let protocolClasses: [AnyClass]?
    private let maximumBytes: Int
    private let timeout: TimeInterval

    init(
        policy: URLPolicy = URLPolicy(),
        protocolClasses: [AnyClass]? = nil,
        maximumBytes: Int = CaptureLimits.artifactBytes,
        timeout: TimeInterval = 120
    ) {
        self.policy = policy
        self.protocolClasses = protocolClasses
        self.maximumBytes = min(CaptureLimits.artifactBytes, max(1, maximumBytes))
        self.timeout = max(1, timeout)
    }

    func limitingBytes(to limit: Int) -> SourceFetcher {
        SourceFetcher(
            policy: policy,
            protocolClasses: protocolClasses,
            maximumBytes: limit,
            timeout: min(timeout, 5)
        )
    }

    func fetch(_ url: URL) async throws -> DownloadedContent {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = min(30, timeout)
        configuration.timeoutIntervalForResource = timeout
        configuration.protocolClasses = protocolClasses
        let session = URLSession(
            configuration: configuration,
            delegate: NoRedirects(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        do {
            var current = url
            for _ in 0 ..< 6 {
                try Task.checkCancellation()
                // Revalidate every hop. DNS preflight is defense in depth, not DNS pinning.
                try await policy.validate(current)
                var request = URLRequest(url: current)
                request.setValue(
                    "Sink/1.0 (local-first document capture)",
                    forHTTPHeaderField: "User-Agent"
                )
                request.setValue(
                    "text/html, application/pdf, image/*, text/plain;q=0.8",
                    forHTTPHeaderField: "Accept"
                )
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse
                else { throw CaptureError.downloadFailed }
                if [301, 302, 303, 307, 308].contains(response.statusCode) {
                    guard let location = response.value(forHTTPHeaderField: "Location"),
                          let next = URL(string: location, relativeTo: current)?.absoluteURL
                    else { throw CaptureError.downloadFailed }
                    bytes.task.cancel()
                    current = next
                    continue
                }
                guard (200 ..< 300).contains(response.statusCode)
                else { throw CaptureError.http(response.statusCode) }
                guard response.expectedContentLength <= maximumBytes
                else { throw CaptureError.tooLarge }
                let data = try await readBounded(bytes)
                return DownloadedContent(
                    data: data,
                    url: current,
                    mime: response.mimeType,
                    encoding: response.textEncodingName
                )
            }
            throw CaptureError.downloadFailed
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CaptureError {
            throw error
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw CaptureError.downloadFailed
        }
    }

    private func readBounded(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        var buffer = [UInt8]()
        buffer.reserveCapacity(16384)
        for try await byte in bytes {
            buffer.append(byte)
            guard data.count + buffer.count <= maximumBytes else { throw CaptureError.tooLarge }
            if buffer.count == 16384 {
                try Task.checkCancellation()
                data.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        data.append(contentsOf: buffer)
        return data
    }
}
