import Foundation
@testable import Gleanary
import Synchronization
import Testing

private struct TransportResolver: HostResolving {
    func addresses(for host: String) async throws -> [String] {
        host == "127.0.0.1" ? [host] : ["93.184.216.34"]
    }
}

private final class FixtureURLProtocol: URLProtocol {
    static let requests = Mutex<[URLRequest]>([])
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        guard let url = request.url else { return }
        var headers = ["Content-Type": "text/plain; charset=utf-8"]
        let status: Int
        let data: Data
        switch url.path {
        case "/redirect":
            status = 302; headers["Location"] = "http://127.0.0.1/private"; data = Data()
        case "/loop":
            status = 302; headers["Location"] = "/loop"; data = Data()
        case "/forbidden": status = 403; data = Data("Denied".utf8)
        case "/declared-large":
            status = 200; headers["Content-Length"] = "100000"; data = Data(
                "Small body, excessive declared length"
                    .utf8
            )
        case "/stream-large": status = 200; data = Data(repeating: 65, count: 2048)
        default: status = 200; data = Data("Local transport fixture".utf8)
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct SourceFetcherTests {
    @Test func transportRejectsStatusSizeAndPrivateRedirects() async throws {
        FixtureURLProtocol.requests.withLock { $0 = [] }
        let fetcher = SourceFetcher(
            policy: URLPolicy(resolver: TransportResolver()),
            protocolClasses: [FixtureURLProtocol.self],
            maximumBytes: 1024
        )
        let base = try #require(URL(string: "https://fixture.example/"))
        let result = try await fetcher.fetch(base)
        #expect(String(decoding: result.data, as: UTF8.self) == "Local transport fixture")
        for path in ["forbidden", "declared-large", "stream-large", "redirect", "loop"] {
            await #expect(throws: CaptureError.self) {
                try await fetcher.fetch(base.appending(path: path))
            }
        }
        let requests = FixtureURLProtocol.requests.withLock { $0 }
        #expect(requests.allSatisfy { $0.url?.host == "fixture.example" })
        #expect(requests.filter { $0.url?.path == "/loop" }.count == 6)
        #expect(requests
            .allSatisfy {
                $0.value(forHTTPHeaderField: "Cookie") == nil && $0
                    .value(forHTTPHeaderField: "Authorization") == nil
            })
    }
}
