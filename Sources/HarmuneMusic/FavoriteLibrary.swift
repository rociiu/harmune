import Foundation
import HarmuneCore
import MusicKit

/// MusicKit's library models omit the REST API's inFavorites attribute.
enum FavoriteLibrary {
    private struct Response: Decodable {
        struct Item: Decodable {
            struct Attributes: Decodable {
                var inFavorites: Bool?
                var name: String
                var artistName: String?
                var albumName: String?
                var durationInMillis: Double?
                var trackCount: Int?
            }
            var id: String
            var attributes: Attributes?
        }
        var data: [Item]
        var next: String?
    }

    static func add(_ item: MusicID, kind: MediaKind) async throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.music.apple.com"
        components.path = "/v1/me/favorites"
        components.queryItems = [URLQueryItem(name: "ids[\(kind.rawValue)]", value: item.raw)]
        guard let url = components.url else { throw HarmuneError.invalid("Invalid favorite item") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try await MusicDataRequest(urlRequest: request).response()
    }

    static func load() async throws -> Favorites {
        async let songs = load("songs")
        async let albums = load("albums")
        return try await Favorites(
            songs: songs.map { id, a in
                Track(id: id, title: a.name, artist: a.artistName ?? "", album: a.albumName ?? "",
                      duration: (a.durationInMillis ?? 0) / 1000)
            },
            albums: albums.map { id, a in
                Album(id: id, title: a.name, artist: a.artistName ?? "", trackCount: a.trackCount ?? 0)
            }
        )
    }

    private static func load(_ kind: String) async throws -> [(String, Response.Item.Attributes)] {
        let path = "/v1/me/library/\(kind)"
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.music.apple.com"
        components.path = path
        components.queryItems = [URLQueryItem(name: "limit", value: "100"),
                                 URLQueryItem(name: "extend", value: "inFavorites")]
        guard let first = components.url else { throw HarmuneError.invalid("Invalid favorites request") }
        var url: URL? = first
        var visited = Set<URL>()
        var items: [(String, Response.Item.Attributes)] = []
        while let current = url {
            try Task.checkCancellation()
            guard current.scheme == first.scheme, current.host == first.host, current.path == path,
                  visited.insert(current).inserted else {
                throw HarmuneError(.internal, "Invalid favorites page")
            }
            let request = MusicDataRequest(urlRequest: URLRequest(url: current))
            let page = try await JSONDecoder().decode(Response.self, from: request.response().data)
            for item in page.data {
                if let attributes = item.attributes, attributes.inFavorites == true {
                    items.append((MusicID(source: .library, raw: item.id).description, attributes))
                }
            }
            url = page.next.flatMap { URL(string: $0, relativeTo: current)?.absoluteURL }
        }
        return items
    }
}
